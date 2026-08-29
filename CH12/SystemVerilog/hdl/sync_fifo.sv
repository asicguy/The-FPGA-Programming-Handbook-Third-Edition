// sync_fifo.sv
// ------------------------------------
// Synchronous first-word-fall-through FIFO
// ------------------------------------
// Author : Frank Bruno
//
// Distributed-RAM style: the read is asynchronous, so dout is valid the moment
// the FIFO is non-empty. That is what makes it first-word-fall-through, and it
// keeps the surrounding handshake logic simple -- no output skid stage, no
// "data valid next cycle" bookkeeping.
//
// Depth must be a power of two.
`timescale 1ns/10ps
module sync_fifo
  #
  (
   parameter WIDTH = 32,
   parameter DEPTH = 512
   )
  (
   input wire              clk,
   input wire              rst_n,

   input wire              wr_en,
   input wire [WIDTH-1:0]  din,

   input wire              rd_en,
   output wire [WIDTH-1:0] dout,

   output wire             empty,
   output wire             full,
   // Occupancy, 0 .. DEPTH. The AXI engines use this to size bursts.
   output wire [$clog2(DEPTH):0] count
   );

  localparam AW = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [AW-1:0]    wptr;
  logic [AW-1:0]    rptr;
  logic [AW:0]      cnt;

  assign dout  = mem[rptr];
  assign empty = (cnt == 0);
  assign full  = (cnt == DEPTH[AW:0]);
  assign count = cnt;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr <= '0;
      rptr <= '0;
      cnt  <= '0;
    end else begin
      if (wr_en && !full) begin
        mem[wptr] <= din;
        wptr      <= wptr + 1'b1;
      end
      if (rd_en && !empty) begin
        rptr <= rptr + 1'b1;
      end

      case ({wr_en && !full, rd_en && !empty})
        2'b10:   cnt <= cnt + 1'b1;
        2'b01:   cnt <= cnt - 1'b1;
        default: cnt <= cnt;
      endcase
    end
  end

endmodule
