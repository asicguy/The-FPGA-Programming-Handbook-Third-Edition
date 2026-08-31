// rm_passthrough_core.sv
// ------------------------------------
// The empty RM: it computes nothing, and answers the bus
// ------------------------------------
// Author : Frank Bruno
//
// "Empty" is the wrong word for what a DFX design actually needs, and the
// distinction is worth the module. A genuinely empty partition -- one with no
// logic driving the socket's outputs -- does not answer the AXI4-Lite slave,
// and on ZynqMP a PL slave that does not answer does not fault: there is no
// bus timeout on the PL ports, so the CPU stops with no panic and no console,
// and only a power cycle recovers it. An empty partition is therefore not a
// safe default, it is a trap.
//
// So the empty RM is this: the full socket contract, correctly implemented,
// computing the identity function. It is the thing to load when you want the
// partition to hold nothing in particular -- after a failed swap, or at boot
// before software has chosen a kernel -- and it is the smallest useful
// measurement of what the socket itself costs, since everything it contains is
// shell.
//
// It is also the RM that proves the swap machinery independently of any
// filter: passthrough in, passthrough out, bit-exact against a memcpy. If that
// fails, the problem is the socket rather than the kernel.
//
// Point operation, so it consumes and produces on the same step and has no
// border. See rm_threshold_core.sv for what that means for the FIFO balance.
`timescale 1ns/10ps
module rm_passthrough_core
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

  logic [31:0] total_r, count_r;
  logic        running;
  logic        s0_v, s1_v;

  logic en;
  assign en = (!s0_v || s_valid) && (!s1_v || m_ready);

  assign s_ready = en && s0_v;
  assign m_valid = en && s1_v;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      running <= 1'b0;
      s0_v    <= 1'b0;
      s1_v    <= 1'b0;
      count_r <= '0;
      total_r <= '0;
      done    <= 1'b0;
    end else begin
      done <= 1'b0;

      if (start && !running) begin
        total_r <= 32'(img_width) * 32'(img_height);
        count_r <= '0;
        s0_v    <= (img_width != 0) && (img_height != 0);
        running <= 1'b1;
      end else if (running) begin
        if (en) begin
          if (s0_v) begin
            count_r <= count_r + 1'b1;
            if (count_r + 1'b1 == total_r) s0_v <= 1'b0;
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

  // Alpha included: this is a copy, not a filter, so nothing is forced.
  always_ff @(posedge clk) begin
    if (en) m_data <= s_data;
  end

  wire _unused_mode = &{1'b0, mode};

endmodule
