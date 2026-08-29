// video_filter_wr.sv
// ------------------------------------
// AXI4 write master: streams 32-bit words out to memory
// ------------------------------------
// Author : Frank Bruno
//
// Same burst rules as the read master: INCR, up to 256 beats, never crossing a
// 4KB boundary. One burst is in flight on AW/W at a time; B responses are
// counted asynchronously and must all have returned before the engine reports
// done, otherwise the PS could observe ap_done while writes are still in the
// interconnect.
//
// That last point matters more in CH12 than it did in CH11. Here the
// destination is often the DisplayPort's own frame buffer, and the notebook
// hands that frame to the display the instant ap_done comes back -- so a write
// still sitting in the interconnect would be a tear on the screen rather than
// a stale byte nobody looks at.
//
// An AW is only issued once the upstream FIFO already holds the whole burst, so
// W never stalls mid-burst.
`timescale 1ns/10ps
module video_filter_wr
  #
  (
   parameter ADDR_WIDTH = 64,
   parameter DATA_WIDTH = 32,
   parameter ID_WIDTH   = 1,
   parameter CNT_WIDTH  = 12
   )
  (
   input wire                     clk,
   input wire                     rst_n,

   input wire                     start,
   input wire [ADDR_WIDTH-1:0]    base_addr,
   input wire [31:0]              total_words,
   output logic                   done,          // one-cycle pulse

   // AXI4 write address channel
   output logic [ID_WIDTH-1:0]    awid,
   output logic [ADDR_WIDTH-1:0]  awaddr,
   output logic [7:0]             awlen,
   output logic [2:0]             awsize,
   output logic [1:0]             awburst,
   output logic                   awvalid,
   input wire                     awready,

   // AXI4 write data channel
   output logic [DATA_WIDTH-1:0]  wdata,
   output logic [DATA_WIDTH/8-1:0] wstrb,
   output logic                   wlast,
   output logic                   wvalid,
   input wire                     wready,

   // AXI4 write response channel
   input wire [1:0]               bresp,
   input wire                     bvalid,
   output logic                   bready,

   // streaming input
   input wire                     s_valid,
   input wire [DATA_WIDTH-1:0]    s_data,
   output logic                   s_ready,
   input wire [CNT_WIDTH-1:0]     s_count
   );

  localparam MAX_BURST = 256;
  localparam BYTES     = DATA_WIDTH/8;

  typedef enum logic [1:0] {IDLE, REQ, DATA, WAIT_B} state_t;
  state_t state;

  logic [ADDR_WIDTH-1:0] addr_cur;
  logic [31:0]           words_left;
  logic [8:0]            beats_left;
  logic [7:0]            b_pending;

  logic [10:0] to_4k;
  assign to_4k = 11'd1024 - {1'b0, addr_cur[11:2]};

  logic [31:0] burst_len;
  always_comb begin
    burst_len = (words_left > MAX_BURST) ? MAX_BURST : words_left;
    if (burst_len > {21'd0, to_4k}) burst_len = {21'd0, to_4k};
  end

  assign awid    = '0;
  assign awaddr  = addr_cur;
  assign awlen   = burst_len[7:0] - 8'd1;
  assign awsize  = (DATA_WIDTH == 32) ? 3'b010 :
                   (DATA_WIDTH == 64) ? 3'b011 : 3'b100;
  assign awburst = 2'b01;
  assign awvalid = (state == REQ) && (32'(s_count) >= burst_len);

  assign wdata   = s_data;
  assign wstrb   = '1;
  assign wvalid  = (state == DATA) && s_valid;
  assign wlast   = (state == DATA) && (beats_left == 9'd1);
  // pop only on a real W beat, never merely because WREADY happens to be high
  assign s_ready = wvalid && wready;

  assign bready  = 1'b1;

  // The engine does not act on BRESP. Neither does the RTL Vitis HLS generates
  // for the same kernel: on this design a SLVERR would mean the accelerator was
  // pointed at an address the interconnect does not decode, which is a software
  // bug that the notebook's own address checks catch first.
  wire _unused_wr = &{1'b0, bresp};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state      <= IDLE;
      addr_cur   <= '0;
      words_left <= '0;
      beats_left <= '0;
      b_pending  <= '0;
      done       <= 1'b0;
    end else begin
      done <= 1'b0;

      // B responses are tracked independently of the AW/W state machine
      case ({(awvalid && awready), (bvalid && bready)})
        2'b10:   b_pending <= b_pending + 1'b1;
        2'b01:   b_pending <= b_pending - 1'b1;
        default: ;
      endcase

      case (state)
        IDLE: begin
          if (start && (total_words != 0)) begin
            addr_cur   <= base_addr;
            words_left <= total_words;
            state      <= REQ;
          end
        end

        REQ: begin
          if (awvalid && awready) begin
            beats_left <= burst_len[8:0];
            addr_cur   <= addr_cur + (burst_len * BYTES);
            words_left <= words_left - burst_len;
            state      <= DATA;
          end
        end

        DATA: begin
          if (wvalid && wready) begin
            beats_left <= beats_left - 1'b1;
            if (beats_left == 9'd1)
              state <= (words_left == 0) ? WAIT_B : REQ;
          end
        end

        WAIT_B: begin
          // account for a response arriving in this same cycle
          if ((b_pending == 8'd0) ||
              ((b_pending == 8'd1) && bvalid && bready)) begin
            done  <= 1'b1;
            state <= IDLE;
          end
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
