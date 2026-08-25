// sobel_stream_core.sv
// ------------------------------------
// Two-pixel-per-clock 3x3 window filter over two line buffers
// ------------------------------------
// Author : Frank Bruno
//
// A direct RTL transcription of the HLS kernel, including its iteration space,
// which is what makes the two implementations bit-identical.
//
// Geometry
// --------
// Two pixels arrive per beat, so a line is B = img_width/2 beats. Filtered
// pixel (r, c) needs input rows r-1, r, r+1 and columns c-1, c, c+1, so output
// beat b of row r cannot be computed until input beat b+1 of row r+1 has
// arrived. The loop therefore runs over (H+1) x (B+1) steps:
//
//     consume input beat b of row r        when  r < H && b < B
//     produce output beat b-1 of row r-1   when  r >= 1 && b >= 1
//
// Both come to exactly B*H, so the block is transparent to the rest of the
// pipeline: one beat out for every beat in, no frame ever short or long. Get
// this wrong and the symptom is not a wrong picture, it is a VDMA that never
// completes a frame.
//
// The extra row (r == H) consumes nothing. The input frame is over and the
// camera is in vertical blanking; the row exists purely to flush the last
// output line out of the line buffers, so a frame is finished before the next
// start-of-frame arrives.
//
// The window
// ----------
// Per row the core keeps the last three columns it has seen -- q0, q1, q2 --
// and combines them with the left-hand pixel of the beat arriving now:
//
//     step b:  q0 = col 2b-3   q1 = col 2b-2   q2 = col 2b-1   new = col 2b
//              output pixels are cols 2b-2 (centre q1) and 2b-1 (centre q2)
//
// The two Sobel windows in a beat share two of their three columns, so four
// columns of context cover both. Three rows of that is the 3x4 window below; a
// one-pixel-per-clock filter would need 3x3, and that difference is most of
// what two pixels per clock costs.
//
// Rows come from two line buffers holding whole beats: lb0 is row r-2, lb1 is
// row r-1, rotated forward one row per step.
//
// Pipeline, one step per cycle when not stalled:
//
//   S0  counters; present the beat address to the line buffers; pop input
//   S1  line-buffer data arrives; shift the window; write the buffers back
//   S2  the four Sobel partial sums, two per output pixel
//   S3  absolute value, clamp, mode select, push the output beat
//
// All four share one enable, so they advance together or stall together.
`timescale 1ns/10ps
module sobel_stream_core
  #
  (
   parameter int MAX_WIDTH = 1920
   )
  (
   input  wire         clk,
   input  wire         rst_n,

   // configuration, latched at start of frame
   input  wire [31:0]  img_width,
   input  wire [31:0]  img_height,
   input  wire [31:0]  mode,

   // input video stream
   input  wire         s_valid,
   input  wire [47:0]  s_data,
   input  wire         s_user,      // start of frame
   input  wire         s_last,      // end of line
   output logic        s_ready,

   // output beat, into the skid buffer
   output logic        m_wr,
   output logic [47:0] m_data,
   output logic        m_user,
   output logic        m_last,
   input  wire         m_full
   );

  localparam int MAX_BEATS = MAX_WIDTH / 2;
  localparam int AW        = $clog2(MAX_BEATS);

  localparam [31:0] MODE_GRAY   = 32'd0;
  localparam [31:0] MODE_INVERT = 32'd2;
  localparam [31:0] MODE_COLOR  = 32'd3;

  localparam [1:0] ST_SYNC = 2'd0;   // waiting for a start-of-frame
  localparam [1:0] ST_RUN  = 2'd1;   // filtering a frame
  localparam [1:0] ST_PASS = 2'd2;   // forwarding a frame untouched

  logic [1:0] state;

  // ------------------------------------------------------------------
  // Configuration, and what counts as usable
  // ------------------------------------------------------------------
  // An odd width has no representation on a two-pixel bus, and a width beyond
  // the line buffers cannot be filtered. Rather than quietly truncating, the
  // core stays in ST_SYNC and drains: pixels are dropped until a notebook
  // writes a geometry that works. Dropping is deliberate -- a block that stops
  // reading backs the CSI-2 subsystem up until it overflows, and recovering
  // from that needs a reset of the whole video pipeline.
  logic [31:0] cfg_beats;
  logic        cfg_ok;

  assign cfg_beats = img_width >> 1;
  assign cfg_ok    = (img_width[0] == 1'b0) &&
                     (cfg_beats != 32'd0) && (cfg_beats <= MAX_BEATS) &&
                     (img_height != 32'd0);

  logic [15:0] b_r, h_r;      // beats per line, lines per frame
  logic [31:0] mode_r;

  // ------------------------------------------------------------------
  // Line buffers. Two luma values per word, one word per beat.
  // ------------------------------------------------------------------
  (* ram_style = "block" *) logic [15:0] lb0 [MAX_BEATS];   // row r-2
  (* ram_style = "block" *) logic [15:0] lb1 [MAX_BEATS];   // row r-1
  logic [15:0] lb0_dout, lb1_dout;

  // ------------------------------------------------------------------
  // Stage valids and payloads
  // ------------------------------------------------------------------
  logic        s0_v, s1_v, s2_v, s3_v;
  logic [15:0] r_cnt, b_cnt;

  logic        s0_consume, s0_lbrw, s0_prod;
  assign s0_consume = (r_cnt < h_r) && (b_cnt < b_r);
  assign s0_lbrw    = (b_cnt < b_r);
  assign s0_prod    = (r_cnt >= 16'd1) && (b_cnt >= 16'd1);

  logic          s1_lbrw, s1_prod, s1_bord0, s1_bord1, s1_user, s1_last;
  logic [7:0]    s1_new2l, s1_new2r;
  logic [AW-1:0] s1_b;         // only ever a line-buffer address

  logic        s2_prod, s2_bord0, s2_bord1, s2_user, s2_last;
  logic [7:0]  s2_gray0, s2_gray1;
  logic signed [12:0] s2_gx0, s2_gy0, s2_gx1, s2_gy1;

  logic        s3_prod, s3_user, s3_last;
  logic [47:0] s3_data;

  // ------------------------------------------------------------------
  // Pipeline enable
  // ------------------------------------------------------------------
  logic en;
  assign en = (!(s0_v && s0_consume) || s_valid) &&
              (!(s3_v && s3_prod)    || !m_full);

  // ------------------------------------------------------------------
  // Stream handshake
  // ------------------------------------------------------------------
  // In ST_SYNC the core accepts and discards everything except a start-of-frame
  // it can actually use -- that beat is left on the bus for the pipeline (or
  // the passthrough) to consume as its first. TREADY is allowed to depend on
  // TVALID and TUSER; it is TVALID that must not depend on TREADY, which is
  // what the skid buffer on the output is for.
  always_comb begin
    case (state)
      ST_RUN:  s_ready = en && s0_v && s0_consume;
      ST_PASS: s_ready = !m_full;
      default: s_ready = !(s_user && cfg_ok);
    endcase
  end

  // ------------------------------------------------------------------
  // Luma. BT.601 in Q8: 0.299/0.587/0.114 -> 77/150/29, on B,G,R from the LSB
  // up, which is the byte order axis_channel_swap hands us.
  // ------------------------------------------------------------------
  // The sum reaches 255*256 = 65280, so sixteen bits hold it exactly and the
  // Q8 result is the top byte. Written as one expression rather than through a
  // named intermediate: the discarded low byte of a named one reads to a linter
  // as a signal nobody uses.
  function automatic logic [7:0] luma8(input logic [23:0] px);
    begin
      luma8 = 8'((16'd29  * {8'd0, px[7:0]}   +
                  16'd150 * {8'd0, px[15:8]}  +
                  16'd77  * {8'd0, px[23:16]}) >> 8);
    end
  endfunction

  // ------------------------------------------------------------------
  // Window registers
  // ------------------------------------------------------------------
  logic [7:0] q00, q01, q02;   // row r-2
  logic [7:0] q10, q11, q12;   // row r-1
  logic [7:0] q20, q21, q22;   // row r

  logic [7:0] new0l, new0r, new1l, new1r, new2l, new2r;

  // Past the right-hand edge and on the flush row there is no data. Zero is
  // safe rather than merely convenient: every output pixel those values could
  // reach is a frame border, and the border is black in Sobel and centre-only
  // in the pointwise modes, so they are never observable. The HLS C does the
  // same thing for the same reason.
  always_comb begin
    new0l = s1_lbrw ? lb0_dout[7:0]  : 8'd0;
    new0r = s1_lbrw ? lb0_dout[15:8] : 8'd0;
    new1l = s1_lbrw ? lb1_dout[7:0]  : 8'd0;
    new1r = s1_lbrw ? lb1_dout[15:8] : 8'd0;
    new2l = s1_new2l;
    new2r = s1_new2r;
  end

  // ------------------------------------------------------------------
  // State machine and S0 counters
  // ------------------------------------------------------------------
  logic last_step;
  assign last_step = (r_cnt == h_r) && (b_cnt == b_r);

  logic [15:0] line_cnt;      // ST_PASS line counter

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state    <= ST_SYNC;
      s0_v     <= 1'b0;
      r_cnt    <= '0;
      b_cnt    <= '0;
      b_r      <= '0;
      h_r      <= '0;
      mode_r   <= '0;
      line_cnt <= '0;
    end else begin
      case (state)
        ST_SYNC: begin
          if (s_valid && s_user && cfg_ok) begin
            b_r      <= cfg_beats[15:0];
            h_r      <= img_height[15:0];
            mode_r   <= mode;
            r_cnt    <= '0;
            b_cnt    <= '0;
            line_cnt <= '0;
            if (mode == MODE_COLOR) begin
              state <= ST_PASS;
            end else begin
              state <= ST_RUN;
              s0_v  <= 1'b1;
            end
          end
        end

        ST_RUN: begin
          if (en && s0_v) begin
            if (last_step) begin
              s0_v <= 1'b0;
            end else if (b_cnt == b_r) begin
              b_cnt <= '0;
              r_cnt <= r_cnt + 16'd1;
            end else begin
              b_cnt <= b_cnt + 16'd1;
            end
          end
          // back to hunting for a start-of-frame once the last step has drained
          if (!s0_v && !s1_v && !s2_v && !s3_v) state <= ST_SYNC;
        end

        ST_PASS: begin
          // Lines are counted from TLAST rather than from the beat counter, so
          // a passthrough frame stays aligned with the stream even if the
          // registers disagree with what the camera is actually sending.
          if (s_valid && !m_full && s_last) begin
            if (line_cnt == h_r - 16'd1) state    <= ST_SYNC;
            else                         line_cnt <= line_cnt + 16'd1;
          end
        end

        default: state <= ST_SYNC;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // Line-buffer read, S0 -> S1
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (en) begin
      lb0_dout <= lb0[b_cnt[AW-1:0]];
      lb1_dout <= lb1[b_cnt[AW-1:0]];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s1_v <= 1'b0;
    end else if (en) begin
      s1_v     <= s0_v && (state == ST_RUN);
      s1_lbrw  <= s0_lbrw;
      s1_prod  <= s0_prod;
      s1_b     <= b_cnt[AW-1:0];
      s1_new2l <= s0_consume ? luma8(s_data[23:0])  : 8'd0;
      s1_new2r <= s0_consume ? luma8(s_data[47:24]) : 8'd0;
      // Output pixel (r-1, 2b-2) and (r-1, 2b-1). Sobel is undefined on the
      // one-pixel frame border, where the C emits black:
      //   row    r-1 == 0        -> r == 1        r-1 == H-1 -> r == H
      //   col  2b-2 == 0         -> b == 1        2b-1 == W-1 -> b == B
      // 2b-2 can never be W-1 and 2b-1 can never be 0, so those two cases do
      // not appear -- a consequence of the pixels being paired.
      s1_bord0 <= (r_cnt == 16'd1) || (r_cnt == h_r) || (b_cnt == 16'd1);
      s1_bord1 <= (r_cnt == 16'd1) || (r_cnt == h_r) || (b_cnt == b_r);
      s1_user  <= (r_cnt == 16'd1) && (b_cnt == 16'd1);
      s1_last  <= (b_cnt == b_r);
    end
  end

  // ------------------------------------------------------------------
  // S1: window shift and line-buffer writeback
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      {q00, q01, q02} <= '0;
      {q10, q11, q12} <= '0;
      {q20, q21, q22} <= '0;
    end else if (en && s1_v) begin
      q00 <= q02;  q01 <= new0l;  q02 <= new0r;
      q10 <= q12;  q11 <= new1l;  q12 <= new1r;
      q20 <= q22;  q21 <= new2l;  q22 <= new2r;
    end
  end

  // The write address trails the read address by one step, so a line buffer is
  // never read and written at the same location in the same cycle.
  always_ff @(posedge clk) begin
    if (en && s1_v && s1_lbrw) begin
      lb0[s1_b] <= lb1_dout;                  // row r-1 becomes row r-2
      lb1[s1_b] <= {s1_new2r, s1_new2l};      // row r becomes row r-1
    end
  end

  // ------------------------------------------------------------------
  // S1 -> S2: the four Sobel partial sums, from the pre-shift window
  // ------------------------------------------------------------------
  logic [11:0] l_col0, l_col2, l_top, l_bot;      // left-hand output pixel
  logic [11:0] r_col1, r_col3, r_top, r_bot;      // right-hand output pixel

  // a + 2b + c, the weighting every Sobel row and column tap uses. The
  // widening is written out rather than left to implicit extension: three
  // 8-bit pixels reach 1020, so twelve bits, and saying so keeps the lint
  // clean and the intent visible.
  function automatic logic [11:0] tap3(input logic [7:0] a,
                                       input logic [7:0] b,
                                       input logic [7:0] c);
    begin
      tap3 = {4'd0, a} + {3'd0, b, 1'b0} + {4'd0, c};
    end
  endfunction

  always_comb begin
    // centred on q1: columns q0, q1, q2
    l_col0 = tap3(q00, q10, q20);
    l_col2 = tap3(q02, q12, q22);
    l_top  = tap3(q00, q01, q02);
    l_bot  = tap3(q20, q21, q22);
    // centred on q2: columns q1, q2, new
    r_col1 = tap3(q01,   q11,   q21);
    r_col3 = tap3(new0l, new1l, new2l);
    r_top  = tap3(q01,   q02,   new0l);
    r_bot  = tap3(q21,   q22,   new2l);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s2_v <= 1'b0;
    end else if (en) begin
      s2_v     <= s1_v;
      s2_prod  <= s1_prod;
      s2_bord0 <= s1_bord0;
      s2_bord1 <= s1_bord1;
      s2_user  <= s1_user;
      s2_last  <= s1_last;
      s2_gray0 <= q11;
      s2_gray1 <= q12;
      s2_gx0   <= $signed({1'b0, l_col2}) - $signed({1'b0, l_col0});
      s2_gy0   <= $signed({1'b0, l_bot})  - $signed({1'b0, l_top});
      s2_gx1   <= $signed({1'b0, r_col3}) - $signed({1'b0, r_col1});
      s2_gy1   <= $signed({1'b0, r_bot})  - $signed({1'b0, r_top});
    end
  end

  // ------------------------------------------------------------------
  // S2 -> S3: absolute value, clamp, mode select
  // ------------------------------------------------------------------
  function automatic logic [7:0] magnitude(input logic signed [12:0] gx,
                                           input logic signed [12:0] gy);
    logic [12:0] ax, ay;
    logic [13:0] m;
    begin
      ax        = gx[12] ? (~gx + 13'd1) : gx;
      ay        = gy[12] ? (~gy + 13'd1) : gy;
      m         = {1'b0, ax} + {1'b0, ay};
      magnitude = (|m[13:8]) ? 8'd255 : m[7:0];
    end
  endfunction

  logic [7:0] sel0, sel1;

  always_comb begin
    // Compare the whole word, not just the low bits: the C tests == MODE_GRAY,
    // == MODE_INVERT and == MODE_COLOR and falls through to Sobel for every
    // other value, so mode 7 must give Sobel rather than something else.
    case (mode_r)
      MODE_GRAY: begin
        sel0 = s2_gray0;
        sel1 = s2_gray1;
      end
      MODE_INVERT: begin
        sel0 = 8'd255 - s2_gray0;
        sel1 = 8'd255 - s2_gray1;
      end
      default: begin
        sel0 = s2_bord0 ? 8'd0 : magnitude(s2_gx0, s2_gy0);
        sel1 = s2_bord1 ? 8'd0 : magnitude(s2_gx1, s2_gy1);
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s3_v <= 1'b0;
    end else if (en) begin
      s3_v    <= s2_v;
      s3_prod <= s2_prod;
      s3_user <= s2_user;
      s3_last <= s2_last;
      // luma replicated across B, G and R for both pixels of the beat
      s3_data <= {sel1, sel1, sel1, sel0, sel0, sel0};
    end
  end

  // ------------------------------------------------------------------
  // Output
  // ------------------------------------------------------------------
  // The write strobe is qualified by `en` rather than held: the pipeline can
  // stall for a reason that has nothing to do with the consumer -- S0 waiting
  // on an input beat -- and a held strobe would push the same beat again on
  // every stalled cycle.
  always_comb begin
    if (state == ST_PASS) begin
      m_wr   = s_valid && !m_full;
      m_data = s_data;
      m_user = s_user;
      m_last = s_last;
    end else begin
      m_wr   = en && s3_v && s3_prod;
      m_data = s3_data;
      m_user = s3_user;
      m_last = s3_last;
    end
  end

endmodule
