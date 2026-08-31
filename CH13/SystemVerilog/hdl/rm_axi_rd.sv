// ------------------------------------------------------------------
// Taken unchanged from CH12 (SystemVerilog/hdl/video_filter_rd.sv), apart from the module name and this
// note. It is inside the reconfigurable partition, so every RM carries its
// own copy -- that is what a partition is. It is reproduced here rather than
// referenced across chapters so CH13 builds on its own, and it is NOT
// re-verified here: CH12's testbenches cover it, and changing it in one
// chapter and not the other is the failure this note exists to make visible.
// ------------------------------------------------------------------
// rm_axi_rd.sv
// ------------------------------------
// AXI4 read master: streams 32-bit words from memory
// ------------------------------------
// Author : Frank Bruno
//
// Issues INCR bursts of up to 256 beats, never crossing a 4KB boundary (an AXI4
// requirement, not a preference). Multiple bursts may be outstanding; all share
// ID 0, so the interconnect must return their data in order.
//
// Flow control is credit based. An AR is only issued when the downstream FIFO
// has enough free space for the whole burst, counting space already promised to
// bursts still in flight. That way R data never has to be back-pressured for
// lack of room, and the burst can never stall midway.
//
// Unchanged from CH11's read engine. It moves words and does not care what is
// in them, which is the whole reason it did not need touching when the pixel
// format changed.
`timescale 1ns/10ps
module rm_axi_rd
  #
  (
   parameter ADDR_WIDTH = 64,
   parameter DATA_WIDTH = 32,
   parameter ID_WIDTH   = 1,
   parameter CNT_WIDTH  = 12       // width of the free/reserve counters
   )
  (
   input wire                    clk,
   input wire                    rst_n,

   input wire                    start,
   input wire [ADDR_WIDTH-1:0]   base_addr,
   input wire [31:0]             total_words,

   // AXI4 read address channel
   output logic [ID_WIDTH-1:0]   arid,
   output logic [ADDR_WIDTH-1:0] araddr,
   output logic [7:0]            arlen,
   output logic [2:0]            arsize,
   output logic [1:0]            arburst,
   output logic                  arvalid,
   input wire                    arready,

   // AXI4 read data channel
   input wire [DATA_WIDTH-1:0]   rdata,
   input wire [1:0]              rresp,
   input wire                    rlast,
   input wire                    rvalid,
   output logic                  rready,

   // streaming output
   output logic                  m_valid,
   output logic [DATA_WIDTH-1:0] m_data,
   input wire                    m_ready,
   // free entries downstream, used for the credit calculation
   input wire [CNT_WIDTH-1:0]    m_free
   );

  localparam MAX_BURST = 256;
  localparam BYTES     = DATA_WIDTH/8;

  typedef enum logic [1:0] {IDLE, RUN} state_t;
  state_t state;

  logic [ADDR_WIDTH-1:0] addr_cur;
  logic [31:0]           words_left;   // still to request
  logic [31:0]           rx_left;      // still to receive
  logic [CNT_WIDTH:0]    reserved;     // promised to in-flight bursts

  // Words remaining before the next 4KB boundary.
  logic [10:0] to_4k;
  assign to_4k = 11'd1024 - {1'b0, addr_cur[11:2]};

  // Burst length = min(MAX_BURST, words_left, to_4k)
  logic [31:0] burst_len;
  always_comb begin
    burst_len = (words_left > MAX_BURST) ? MAX_BURST : words_left;
    if (burst_len > {21'd0, to_4k}) burst_len = {21'd0, to_4k};
  end

  // Free space not already promised to a burst in flight.
  logic [CNT_WIDTH+1:0] credit;
  assign credit = {2'b0, m_free} - {1'b0, reserved};

  logic can_issue;
  assign can_issue = (state == RUN) && (words_left != 0) &&
                     ($signed(credit) >= $signed({2'b0, burst_len[CNT_WIDTH-1:0]}));

  assign arid    = '0;
  assign araddr  = addr_cur;
  assign arlen   = burst_len[7:0] - 8'd1;
  assign arsize  = (DATA_WIDTH == 32) ? 3'b010 :
                   (DATA_WIDTH == 64) ? 3'b011 : 3'b100;
  assign arburst = 2'b01;                 // INCR
  assign arvalid = can_issue;

  assign rready  = m_ready;
  assign m_valid = rvalid;
  assign m_data  = rdata;

  // RRESP is not acted on, and RLAST is not needed: the engine counts beats
  // itself, because it has to know how many are outstanding for the credit
  // calculation anyway. Same reasoning as the write engine on BRESP.
  wire _unused_rd = &{1'b0, rresp, rlast};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state      <= IDLE;
      addr_cur   <= '0;
      words_left <= '0;
      rx_left    <= '0;
      reserved   <= '0;
    end else begin
      case (state)
        IDLE: begin
          if (start && (total_words != 0)) begin
            addr_cur   <= base_addr;
            words_left <= total_words;
            rx_left    <= total_words;
            reserved   <= '0;
            state      <= RUN;
          end
        end

        RUN: begin
          if (arvalid && arready) begin
            addr_cur   <= addr_cur + (burst_len * BYTES);
            words_left <= words_left - burst_len;
            reserved   <= reserved + burst_len[CNT_WIDTH:0];
          end

          if (rvalid && rready) begin
            rx_left  <= rx_left - 1'b1;
            // the AR handshake above may land in the same cycle
            if (!(arvalid && arready))
              reserved <= reserved - 1'b1;
            else
              reserved <= reserved + burst_len[CNT_WIDTH:0] - 1'b1;
            if (rx_left == 32'd1) state <= IDLE;
          end
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
