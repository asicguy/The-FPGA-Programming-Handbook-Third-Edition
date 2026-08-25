// axis_skid.sv
// ------------------------------------
// Two-entry output buffer for an AXI4-Stream master port
// ------------------------------------
// Author : Frank Bruno
//
// The filter core decides whether to advance its pipeline partly from whether
// the consumer can take a result, so its output valid depends combinationally
// on the downstream ready. Inside CH11 that was harmless -- the consumer was an
// internal FIFO. Here the consumer is an AXI4-Stream port on the edge of the
// IP, and the protocol is explicit that TVALID must not depend on TREADY. A
// master that waits for TREADY before asserting TVALID deadlocks against a
// slave that waits for TVALID before asserting TREADY, and the AXI SmartConnect
// downstream is entitled to be that slave.
//
// So the core writes into this instead. TVALID comes out of a register and
// depends on nothing outside, while the core sees `full`, which is allowed to
// depend on TREADY.
//
// Two entries, not one: `full` deasserts on the same cycle the consumer takes a
// beat, so a stalled-then-released stream resumes at full rate rather than
// leaving a bubble behind every stall.
`timescale 1ns/10ps
module axis_skid
  #
  (
   parameter int WIDTH = 50
   )
  (
   input  wire              clk,
   input  wire              rst_n,

   // producer side
   input  wire              wr,
   input  wire [WIDTH-1:0]  din,
   output logic             full,

   // AXI4-Stream master side
   output logic             m_valid,
   output logic [WIDTH-1:0] m_data,
   input  wire              m_ready
   );

  logic [WIDTH-1:0] mem [2];
  logic [1:0]       cnt;
  logic             wptr, rptr;
  logic             rd;

  assign m_valid = (cnt != 2'd0);
  assign m_data  = mem[rptr];
  assign rd      = m_valid && m_ready;

  // Room for a write if a slot is free, or if one is being freed this cycle.
  assign full    = (cnt == 2'd2) && !rd;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cnt  <= 2'd0;
      wptr <= 1'b0;
      rptr <= 1'b0;
    end else begin
      if (wr && !full) begin
        mem[wptr] <= din;
        wptr      <= ~wptr;
      end
      if (rd) rptr <= ~rptr;

      case ({(wr && !full), rd})
        2'b10:   cnt <= cnt + 2'd1;
        2'b01:   cnt <= cnt - 2'd1;
        default: cnt <= cnt;
      endcase
    end
  end

endmodule
