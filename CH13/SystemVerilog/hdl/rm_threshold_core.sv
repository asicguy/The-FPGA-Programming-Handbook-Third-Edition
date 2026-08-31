// rm_threshold_core.sv
// ------------------------------------
// Binary threshold on luma, the level taken from the mode register
// ------------------------------------
// Author : Frank Bruno
//
// A POINT operation: every output pixel depends only on the input pixel at the
// same position. That makes it the cheapest RM by a wide margin -- no line
// buffers, no window, no BRAM at all -- and it is in the chapter partly to
// show what the partition costs when the kernel does not need the room.
//
// It also has no border. A 3x3 window is undefined at the frame edge, so the
// windowed kernels emit black there; a point operation has nothing undefined
// anywhere, so it produces a real result on every pixel including the edge.
// The golden model says the same thing, and a test pins it:
// test_threshold_has_no_border_because_it_needs_no_window.
//
// Because it produces on the same schedule it consumes -- one pixel out per
// pixel in, immediately -- its iteration space is the sobel core's COLOUR
// path, not its windowed path:
//
//   the loop runs width x height times
//   a pixel is consumed and produced on every step
//
// The total is width*height either way, which is what keeps the shell's two
// FIFOs balanced. Getting that wrong deadlocks rather than producing a wrong
// picture, which is a hard failure to read on hardware and an easy one in
// simulation -- see tb/tb_rm.sv.
//
// `mode` is the threshold LEVEL, 0..255, not a menu selection. This is the
// chapter's point in miniature: the socket contract does not change across a
// swap, but the MEANING of a register does, and the only honest way to know
// which reading applies is to ask the hardware its kernel_id.
`timescale 1ns/10ps
module rm_threshold_core
  (
   input wire          clk,
   input wire          rst_n,

   input wire          start,
   input wire [15:0]   img_width,
   input wire [15:0]   img_height,
   input wire [31:0]   mode,
   output logic        done,

   input wire          s_valid,
   input wire [31:0]   s_data,
   output logic        s_ready,

   output logic        m_valid,
   output logic [31:0] m_data,
   input wire          m_ready
   );

  // ITU-R BT.601 luma in Q8, ordered B,G,R to match the pixel layout. The
  // weights sum to 256, so white lands on exactly 255 and no clamp is needed.
  localparam [7:0] LUMA_B = 8'd29;
  localparam [7:0] LUMA_G = 8'd150;
  localparam [7:0] LUMA_R = 8'd77;

  logic [7:0]  level_r;
  // Row and column counters rather than a pixel count, deliberately. Counting
  // to width*height needs a 32x32 multiply, and out-of-context synthesis
  // showed that costing a DSP the windowed cores do not spend -- rm_shell
  // already computes the same product for the burst engines, so the core was
  // paying for it twice. Nested counters cost an adder.
  logic [15:0] w_r, h_r;
  logic [15:0] r_cnt, c_cnt;
  logic        running;
  logic        s0_v, s1_v;

  wire last_step = (r_cnt == h_r - 16'd1) && (c_cnt == w_r - 16'd1);

  logic en;
  assign en = (!s0_v || s_valid) && (!s1_v || m_ready);

  assign s_ready = en && s0_v;
  assign m_valid = en && s1_v;

  logic [17:0] luma_sum;
  logic [7:0]  luma_in;
  always_comb begin
    luma_sum = (18'(LUMA_B) * 18'(s_data[7:0]))
             + (18'(LUMA_G) * 18'(s_data[15:8]))
             + (18'(LUMA_R) * 18'(s_data[23:16]));
    luma_in  = luma_sum[15:8];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      running <= 1'b0;
      s0_v    <= 1'b0;
      s1_v    <= 1'b0;
      w_r     <= '0;
      h_r     <= '0;
      r_cnt   <= '0;
      c_cnt   <= '0;
      level_r <= '0;
      done    <= 1'b0;
    end else begin
      done <= 1'b0;

      if (start && !running) begin
        // Only the low byte can matter: a level above 255 would threshold
        // every pixel to black, and sw/rm_ref.py refuses to ask for one.
        level_r <= mode[7:0];
        w_r     <= img_width;
        h_r     <= img_height;
        r_cnt   <= '0;
        c_cnt   <= '0;
        s0_v    <= (img_width != 0) && (img_height != 0);
        running <= 1'b1;
      end else if (running) begin
        if (en) begin
          if (s0_v) begin
            if (last_step) begin
              s0_v <= 1'b0;
            end else if (c_cnt == w_r - 16'd1) begin
              c_cnt <= '0;
              r_cnt <= r_cnt + 1'b1;
            end else begin
              c_cnt <= c_cnt + 1'b1;
            end
          end
          s1_v <= s0_v;
        end
        if (!s0_v && !s1_v) begin
          running <= 1'b0;
          done    <= 1'b1;
        end
      end
    end
  end

  // Threshold is >=, matching np.where(y >= level) in the golden model. The
  // boundary case is a real one: a test asserts that a pixel exactly AT the
  // level comes out white.
  always_ff @(posedge clk) begin
    if (en) begin
      m_data <= (luma_in >= level_r) ? {8'hFF, 24'hFF_FFFF} : {8'hFF, 24'd0};
    end
  end

  // Named discards -- see rm_blur_core.sv for why these are written out
  // rather than suppressed.
  wire _unused_luma  = &{1'b0, luma_sum[17:16], luma_sum[7:0]};
  wire _unused_mode  = &{1'b0, mode[31:8]};
  wire _unused_alpha = &{1'b0, s_data[31:24]};

endmodule
