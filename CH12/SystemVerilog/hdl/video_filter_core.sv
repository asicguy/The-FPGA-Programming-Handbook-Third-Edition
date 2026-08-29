// video_filter_core.sv
// ------------------------------------
// 3x3 sliding-window filter over two line buffers
// ------------------------------------
// Author : Frank Bruno
//
// A direct RTL transcription of the HLS window_filter stage, including its
// iteration space, which is what makes the two implementations bit-identical.
//
// The loop runs (height+1) x (width+1) times. A pixel is consumed whenever
// (r < height && c < width). In the three filtered modes one is produced
// whenever (r >= 1 && c >= 1), because the window centre win11 at step (r,c)
// holds input pixel (r-1, c-1) and cannot be filtered until the row below it
// has arrived. Both totals come to exactly width*height, which is what keeps
// the input and output FIFOs balanced -- get it wrong and the symptom is a
// deadlock, not a wrong picture.
//
// MODE_COLOR produces on the *consume* condition instead: it has no window, so
// it owes no delay. The totals still come to width*height either way, so the
// FIFOs stay balanced whichever branch is taken.
//
// This is where CH12 differs from CH11. CH11's core took 8-bit luma in and put
// 8-bit luma out, because luma was computed before the FIFO and colour was
// discarded there. Colour passthrough needs the original pixel to survive as
// far as the output, so here the whole 32-bit pixel travels the pipeline and
// luma is computed on the way in. The line buffers stay 8 bits wide -- the
// window only ever needs neighbouring *luma* -- so the extra cost is registers
// and FIFO width, not another BRAM.
//
// Pipeline, one step per cycle when not stalled:
//
//   S0  counters; present column address to the line buffers; pop input
//   S1  line-buffer data arrives; luma of the new pixel; shift the window;
//       write the line buffers back
//   S2  compute the Sobel partial sums gx / gy
//   S3  absolute value, clamp, mode select, push output
//
// All four stages share a single enable, so they advance together or not at
// all. The enable is held low when S0 needs an input pixel that has not
// arrived, or when S3 has an output pixel the downstream FIFO cannot take.
`timescale 1ns/10ps
module video_filter_core
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

  // Must match HLS/src/video_filter.hpp.
  localparam [31:0] MODE_GRAY   = 32'd0;
  localparam [31:0] MODE_SOBEL  = 32'd1;
  localparam [31:0] MODE_INVERT = 32'd2;
  localparam [31:0] MODE_COLOR  = 32'd3;

  // ITU-R BT.601 luma in Q8, ordered B,G,R to match the pixel layout.
  localparam [7:0] LUMA_B = 8'd29;
  localparam [7:0] LUMA_G = 8'd150;
  localparam [7:0] LUMA_R = 8'd77;

  localparam AW = $clog2(MAX_WIDTH);

  // latched arguments
  logic [15:0] w_r, h_r;
  logic [31:0] mode_r;
  logic        color_mode;
  assign color_mode = (mode_r == MODE_COLOR);

  // ------------------------------------------------------------------
  // Line buffers. lb0 holds row r-2, lb1 holds row r-1. Luma only: the
  // window never needs a neighbour's colour, only its brightness.
  // Simple dual port: read at the S0 column, write back at the S1 column.
  // ------------------------------------------------------------------
  (* ram_style = "block" *) logic [7:0] lb0 [MAX_WIDTH];
  (* ram_style = "block" *) logic [7:0] lb1 [MAX_WIDTH];
  logic [7:0] lb0_dout, lb1_dout;

  // ------------------------------------------------------------------
  // Stage valids and payloads
  // ------------------------------------------------------------------
  logic        running;
  logic        s0_v, s1_v, s2_v, s3_v;
  logic [15:0] r_cnt, c_cnt;

  logic        s0_need_in, s0_rd, s0_prod;
  assign s0_need_in = (r_cnt < h_r) && (c_cnt < w_r);
  assign s0_rd      = (c_cnt < w_r);
  // The one mode-dependent piece of the iteration space. Colour passthrough
  // emits the pixel it just took; everything else emits the pixel a row and a
  // column behind, because that is where the window centre is.
  assign s0_prod    = color_mode ? s0_need_in
                                 : ((r_cnt >= 16'd1) && (c_cnt >= 16'd1));

  logic        s1_rd, s1_prod, s1_border;
  logic [7:0]  s1_newpx;
  logic [31:0] s1_pix;
  logic [AW-1:0] s1_c;   // only ever a line-buffer index

  logic        s2_prod, s2_border;
  logic [7:0]  s2_gray;
  logic [31:0] s2_pix;

  logic        s3_prod;
  logic signed [12:0] s2_gx, s2_gy;

  // ------------------------------------------------------------------
  // Pipeline enable
  // ------------------------------------------------------------------
  logic en;
  assign en = (!(s0_v && s0_need_in) || s_valid) &&
              (!(s3_v && s3_prod)    || m_ready);

  // Both of these are single-cycle strobes qualified by `en`, not held AXI-style
  // valid/ready. That matters: the pipeline can stall for a reason that has
  // nothing to do with the consumer -- S0 waiting on an input pixel -- and a
  // held m_valid would make the downstream FIFO latch the same output pixel
  // again on every stalled cycle. Gating on `en` means exactly one strobe per
  // advanced step. Safe against combinational loops because m_ready is just
  // "output FIFO not full", which is registered.
  assign s_ready = en && s0_v && s0_need_in;
  assign m_valid = en && s3_v && s3_prod;

  // ------------------------------------------------------------------
  // Luma of the pixel arriving at S0, computed combinationally on the way
  // into S1. The weights sum to 256, so white lands on exactly 255 and no
  // clamp is needed.
  // ------------------------------------------------------------------
  logic [17:0] luma_sum;
  logic [7:0]  luma_in;
  always_comb begin
    luma_sum = (18'(LUMA_B) * 18'(s_data[7:0]))
             + (18'(LUMA_G) * 18'(s_data[15:8]))
             + (18'(LUMA_R) * 18'(s_data[23:16]));
    luma_in  = luma_sum[15:8];
  end

  // luma_sum[7:0] is the fractional part the Q8 shift throws away, and
  // [17:16] can never be set because the weights sum to exactly 256. Both are
  // ignored on purpose; say so, so that lint does not have to guess.
  wire _unused_luma = &{1'b0, luma_sum[17:16], luma_sum[7:0]};

  // ------------------------------------------------------------------
  // Window registers and their next values
  // ------------------------------------------------------------------
  // The C keeps a win[3][3]. The RTL needs only two of its three columns as
  // registers: n00..n22 below *are* the window at the current step, and win**
  // is the previous step's copy of it, shifted left. Column 0 of that copy is
  // never read back -- the current step's column 0 comes from the previous
  // step's column 1 -- so those three registers would be dead silicon. Six
  // registers, not nine.
  logic [7:0] win01, win02;
  logic [7:0] win11, win12;
  logic [7:0] win21, win22;

  logic [7:0] n00, n01, n02, n10, n11, n12, n20, n21, n22;

  // The C shifts the window left first, then fills column 2. With non-blocking
  // assignments every right-hand side already sees the pre-shift values, so the
  // "else" branch (past the right edge) reduces to holding column 2.
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
      mode_r  <= '0;
      done    <= 1'b0;
    end else begin
      done <= 1'b0;

      if (start && !running) begin
        w_r    <= img_width;
        h_r    <= img_height;
        mode_r <= mode;
        r_cnt  <= '0;
        c_cnt  <= '0;
        // a zero-sized image has nothing to do
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
        // finished once the last step has drained past S3
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
      s1_newpx  <= s0_need_in ? luma_in : 8'd0;
      s1_pix    <= s0_need_in ? s_data  : 32'd0;
      // Sobel is undefined on the 1px frame border; the C emits black there.
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
  // S1 -> S2: Sobel partial sums, computed from the post-shift window
  // ------------------------------------------------------------------
  logic [11:0] col_l, col_r_, row_t, row_b;
  always_comb begin
    col_l  = 12'(n00) + (12'(n10) << 1) + 12'(n20);   // left column
    col_r_ = 12'(n02) + (12'(n12) << 1) + 12'(n22);   // right column
    row_t  = 12'(n00) + (12'(n01) << 1) + 12'(n02);   // top row
    row_b  = 12'(n20) + (12'(n21) << 1) + 12'(n22);   // bottom row
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s2_v <= 1'b0;
    end else if (en) begin
      s2_v      <= s1_v;
      s2_prod   <= s1_prod;
      s2_border <= s1_border;
      s2_gray   <= n11;
      s2_pix    <= s1_pix;
      s2_gx     <= $signed({1'b0, col_r_}) - $signed({1'b0, col_l});
      s2_gy     <= $signed({1'b0, row_b})  - $signed({1'b0, row_t});
    end
  end

  // ------------------------------------------------------------------
  // S2 -> S3: absolute value, clamp, mode select
  // ------------------------------------------------------------------
  logic [12:0] abs_gx, abs_gy;
  logic [13:0] mag;
  logic [7:0]  sobel_v, sel_v;

  always_comb begin
    abs_gx  = s2_gx[12] ? (~s2_gx + 1'b1) : s2_gx;
    abs_gy  = s2_gy[12] ? (~s2_gy + 1'b1) : s2_gy;
    mag     = {1'b0, abs_gx} + {1'b0, abs_gy};
    sobel_v = s2_border ? 8'd0 : (|mag[13:8] ? 8'd255 : mag[7:0]);

    // Compare the whole word, not just the low bits: the C tests
    // "== MODE_COLOR", "== MODE_GRAY" then "== MODE_INVERT" and falls through
    // to Sobel for every other value, so mode 7 must give Sobel.
    case (mode_r)
      MODE_GRAY:   sel_v = s2_gray;
      MODE_INVERT: sel_v = 8'd255 - s2_gray;
      MODE_SOBEL:  sel_v = sobel_v;
      default:     sel_v = sobel_v;      // any undefined mode, e.g. 7
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s3_v <= 1'b0;
    end else if (en) begin
      s3_v    <= s2_v;
      s3_prod <= s2_prod;
      // Colour passthrough hands back the pixel untouched, alpha included.
      // Every other mode replicates the result across B, G and R and forces
      // alpha opaque -- a frame going to the DisplayPort with a transparent
      // alpha byte is a black screen, not a subtle bug.
      m_data  <= color_mode ? s2_pix : {8'hFF, sel_v, sel_v, sel_v};
    end
  end

endmodule
