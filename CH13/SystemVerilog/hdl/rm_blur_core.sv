// rm_blur_core.sv
// ------------------------------------
// 3x3 Gaussian blur over two colour line buffers
// ------------------------------------
// Author : Frank Bruno
//
// The same skeleton as rm_sobel_core -- and it has to be. The shell counts
// pixels in and pixels out through two FIFOs, so a core that consumed or
// produced on a different schedule would not compute the wrong picture, it
// would DEADLOCK. The iteration space below is therefore identical to the
// sobel core's windowed path, cycle for cycle:
//
//   the loop runs (height+1) x (width+1) times
//   a pixel is consumed when (r < height && c < width)
//   a pixel is produced when (r >= 1 && c >= 1)
//
// Both totals come to exactly width*height.
//
// What differs is the data, and that is the point of the RM:
//
//   sobel core   line buffers 8 bits wide, luma only. The window needs a
//                neighbour's BRIGHTNESS, and colour is carried around the
//                window in s1_pix/s2_pix for passthrough.
//   this core    line buffers 24 bits wide, B/G/R. A blur needs a
//                neighbour's COLOUR, so the colour has to go through the
//                window rather than around it, and the line buffers cost
//                three bytes a pixel instead of one.
//
// That is the whole architectural difference, and it is why this RM is the one
// that sizes the partition -- see docs/ch13-plan.md 5.
//
// The kernel is [1 2 1; 2 4 2; 1 2 1] and the divisor is its weight sum, 16,
// which is a right shift. A 3x3 box average would divide by 9 and cost a
// divider or a multiply-and-shift approximation, for a result that looks
// worse. Maximum weighted sum is 255*16 = 4080, so >>4 lands on exactly 255
// and no clamp is needed.
//
// `mode` is not used. The socket contract carries it because the sobel RM
// needs it and the register map does not change across a swap; a blur has
// nothing to select. See sw/rm_ref.py for what mode means per kernel.
`timescale 1ns/10ps
module rm_blur_core
  #
  (
   parameter MAX_WIDTH = 1920
   )
  (
   input wire          clk,
   input wire          rst_n,

   input wire          start,
   input wire [15:0]   img_width,
   input wire [15:0]   img_height,
   input wire [31:0]   mode,
   output logic        done,

   // 32-bit BGRA pixel in
   input wire          s_valid,
   input wire [31:0]   s_data,
   output logic        s_ready,

   // 32-bit BGRA pixel out
   output logic        m_valid,
   output logic [31:0] m_data,
   input wire          m_ready
   );

  localparam AW = $clog2(MAX_WIDTH);

  // latched arguments
  logic [15:0] w_r, h_r;

  // ------------------------------------------------------------------
  // Line buffers. lb0 holds row r-2, lb1 holds row r-1. Colour, not luma:
  // 24 bits a pixel, B/G/R with alpha dropped -- alpha is forced opaque on
  // the way out, so carrying it through the window would be three BRAMs
  // spent on a constant.
  // ------------------------------------------------------------------
  (* ram_style = "block" *) logic [23:0] lb0 [MAX_WIDTH];
  (* ram_style = "block" *) logic [23:0] lb1 [MAX_WIDTH];
  logic [23:0] lb0_dout, lb1_dout;

  // ------------------------------------------------------------------
  // Stage valids and payloads
  // ------------------------------------------------------------------
  logic        running;
  logic        s0_v, s1_v, s2_v, s3_v;
  logic [15:0] r_cnt, c_cnt;

  logic        s0_need_in, s0_rd, s0_prod;
  assign s0_need_in = (r_cnt < h_r) && (c_cnt < w_r);
  assign s0_rd      = (c_cnt < w_r);
  assign s0_prod    = (r_cnt >= 16'd1) && (c_cnt >= 16'd1);

  logic          s1_rd, s1_prod, s1_border;
  logic [23:0]   s1_newpx;
  logic [AW-1:0] s1_c;

  logic        s2_prod, s2_border;
  logic [11:0] s2_b, s2_g, s2_r;

  logic        s3_prod;

  // ------------------------------------------------------------------
  // Pipeline enable -- one enable for all four stages, as in the sobel core.
  // ------------------------------------------------------------------
  logic en;
  assign en = (!(s0_v && s0_need_in) || s_valid) &&
              (!(s3_v && s3_prod)    || m_ready);

  // Single-cycle strobes qualified by `en`, not held AXI-style valid/ready:
  // the pipeline can stall for a reason unrelated to the consumer, and a held
  // m_valid would make the downstream FIFO latch the same pixel again on
  // every stalled cycle.
  assign s_ready = en && s0_v && s0_need_in;
  assign m_valid = en && s3_v && s3_prod;

  // ------------------------------------------------------------------
  // Window registers. Six, not nine: column 0 of the previous step's copy is
  // never read back, because the current step's column 0 comes from the
  // previous step's column 1.
  // ------------------------------------------------------------------
  logic [23:0] win01, win02;
  logic [23:0] win11, win12;
  logic [23:0] win21, win22;

  logic [23:0] n00, n01, n02, n10, n11, n12, n20, n21, n22;

  always_comb begin
    n00 = win01;  n01 = win02;  n02 = s1_rd ? lb0_dout : win02;
    n10 = win11;  n11 = win12;  n12 = s1_rd ? lb1_dout : win12;
    n20 = win21;  n21 = win22;  n22 = s1_rd ? s1_newpx : win22;
  end

  // ------------------------------------------------------------------
  // S0: counters and line-buffer read
  // ------------------------------------------------------------------
  wire last_step = (r_cnt == h_r) && (c_cnt == w_r);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      running <= 1'b0;
      s0_v    <= 1'b0;
      r_cnt   <= '0;
      c_cnt   <= '0;
      w_r     <= '0;
      h_r     <= '0;
      done    <= 1'b0;
    end else begin
      done <= 1'b0;

      if (start && !running) begin
        w_r     <= img_width;
        h_r     <= img_height;
        r_cnt   <= '0;
        c_cnt   <= '0;
        s0_v    <= (img_width != 0) && (img_height != 0);
        running <= 1'b1;
      end else if (running) begin
        if (en && s0_v) begin
          if (last_step) begin
            s0_v <= 1'b0;
          end else if (c_cnt == w_r) begin
            c_cnt <= '0;
            r_cnt <= r_cnt + 1'b1;
          end else begin
            c_cnt <= c_cnt + 1'b1;
          end
        end
        if (!s0_v && !s1_v && !s2_v && !s3_v) begin
          running <= 1'b0;
          done    <= 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (en) begin
      lb0_dout <= lb0[c_cnt[AW-1:0]];
      lb1_dout <= lb1[c_cnt[AW-1:0]];
    end
  end

  // ------------------------------------------------------------------
  // S0 -> S1
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s1_v <= 1'b0;
    end else if (en) begin
      s1_v      <= s0_v;
      s1_rd     <= s0_rd;
      s1_prod   <= s0_prod;
      s1_c      <= c_cnt[AW-1:0];
      s1_newpx  <= s0_need_in ? s_data[23:0] : 24'd0;
      // A 3x3 window is not defined on the 1px frame border; emit black
      // there, which is the convention every windowed kernel in this book
      // shares. See sw/rm_ref.py.
      s1_border <= (r_cnt == 16'd1) || (r_cnt == h_r) ||
                   (c_cnt == 16'd1) || (c_cnt == w_r);
    end
  end

  // ------------------------------------------------------------------
  // S1: window shift and line-buffer writeback
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      {win01, win02} <= '0;
      {win11, win12} <= '0;
      {win21, win22} <= '0;
    end else if (en && s1_v) begin
      win01 <= n01; win02 <= n02;
      win11 <= n11; win12 <= n12;
      win21 <= n21; win22 <= n22;
    end
  end

  always_ff @(posedge clk) begin
    if (en && s1_v && s1_rd) begin
      lb0[s1_c] <= lb1_dout;   // row r-1 becomes row r-2
      lb1[s1_c] <= s1_newpx;   // row r becomes row r-1
    end
  end

  // ------------------------------------------------------------------
  // S1 -> S2: the weighted sum, one channel at a time.
  //
  //   1 2 1
  //   2 4 2      centre<<2, edges<<1, corners as they are
  //   1 2 1
  //
  // Maximum 255*16 = 4080, so 12 bits holds it exactly and the >>4 at S3
  // needs no clamp.
  // ------------------------------------------------------------------
  function automatic [11:0] gauss
    (input [7:0] p00, input [7:0] p01, input [7:0] p02,
     input [7:0] p10, input [7:0] p11, input [7:0] p12,
     input [7:0] p20, input [7:0] p21, input [7:0] p22);
    begin
      gauss = 12'(p00) + (12'(p01) << 1) + 12'(p02)
            + (12'(p10) << 1) + (12'(p11) << 2) + (12'(p12) << 1)
            + 12'(p20) + (12'(p21) << 1) + 12'(p22);
    end
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s2_v <= 1'b0;
    end else if (en) begin
      s2_v      <= s1_v;
      s2_prod   <= s1_prod;
      s2_border <= s1_border;
      s2_b <= gauss(n00[7:0],   n01[7:0],   n02[7:0],
                    n10[7:0],   n11[7:0],   n12[7:0],
                    n20[7:0],   n21[7:0],   n22[7:0]);
      s2_g <= gauss(n00[15:8],  n01[15:8],  n02[15:8],
                    n10[15:8],  n11[15:8],  n12[15:8],
                    n20[15:8],  n21[15:8],  n22[15:8]);
      s2_r <= gauss(n00[23:16], n01[23:16], n02[23:16],
                    n10[23:16], n11[23:16], n12[23:16],
                    n20[23:16], n21[23:16], n22[23:16]);
    end
  end

  // ------------------------------------------------------------------
  // S2 -> S3: divide by 16 and force alpha opaque.
  //
  // Opaque even on the border, where the pixel is black. A frame reaching the
  // DisplayPort with a transparent alpha byte is a black screen rather than a
  // subtle bug, and the border must match sw/rm_ref.py, which emits opaque
  // black there.
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s3_v <= 1'b0;
    end else if (en) begin
      s3_v    <= s2_v;
      s3_prod <= s2_prod;
      m_data  <= s2_border ? {8'hFF, 24'd0}
                           : {8'hFF, s2_r[11:4], s2_g[11:4], s2_b[11:4]};
    end
  end

  // Deliberate discards, named rather than suppressed so that lint stays at
  // zero warnings and the next reader can see they were decisions:
  //
  //   mode          the blur has no modes; the socket contract carries the
  //                 register because the sobel RM needs it
  //   s_data[31:24] the incoming alpha, dropped because the output is forced
  //                 opaque -- carrying it through the window would spend
  //                 three BRAMs on a constant
  //   s2_*[3:0]     the fractional part the divide-by-16 truncates. rm_ref.py
  //                 truncates too; rounding here would be a one-LSB
  //                 disagreement with the golden model on most pixels.
  wire _unused_mode  = &{1'b0, mode};
  wire _unused_alpha = &{1'b0, s_data[31:24]};
  wire _unused_frac  = &{1'b0, s2_b[3:0], s2_g[3:0], s2_r[3:0]};

endmodule
