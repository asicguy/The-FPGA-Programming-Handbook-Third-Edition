// socket_ctrl.sv
// ------------------------------------
// AXI4-Lite control/status register file for the CH13 reconfigurable socket
// ------------------------------------
// Author : Frank Bruno
//
// This is CH12's video_filter_ctrl with two additions the socket contract
// requires, and it lives inside the reconfigurable partition -- every RM
// carries its own copy, which is why the identity register can be a
// per-instance parameter rather than a register somebody has to remember to
// write.
//
// Register map. The first eleven entries are byte-for-byte what Vitis HLS
// generates for an ap_ctrl_hs kernel, and what CH11 and CH12 present, so
// PYNQ's register_map, CH12's sw/filter_driver.py and CH12's notebooks all
// work against this socket without a line of change:
//
//   0x00 CTRL    bit0 ap_start (R/W, self-clearing on completion)
//                bit1 ap_done  (R, clear-on-read)
//                bit2 ap_idle  (R)
//                bit3 ap_ready (R, clear-on-read)
//                bit7 auto_restart (R/W)
//                bit9 interrupt (R)
//   0x04 GIER    bit0 global interrupt enable
//   0x08 IP_IER  bit0 ap_done interrupt enable, bit1 ap_ready
//   0x0C IP_ISR  bit0/bit1 interrupt status, toggle-on-write
//   0x10 src     [31:0]
//   0x14 src     [63:32]
//   0x1C dst     [31:0]
//   0x20 dst     [63:32]
//   0x28 img_width
//   0x30 img_height
//   0x38 mode
//   0x3C kernel_id   READ-ONLY, new in CH13
//
// kernel_id is the socket contract's answer to a question DFX makes
// unavoidable: what is actually in the partition right now? Inferring it from
// which partial you believe you downloaded is how a swap that silently did not
// happen goes unnoticed for an afternoon. 0x3C is the last word inside the
// 6-bit address space, so adding it costs no address width.
//
// heartbeat is not a register. It is a wire out of the partition into the
// static region's AXI GPIO, driven by a free-running counter, and it answers a
// different question: is the partition clocked and out of reset AT ALL? That
// cannot be a register, because reading a register is the thing you must not
// do until you know the answer -- a read of a partition held in reset never
// returns, ZynqMP has no bus timeout on the PL ports, and the CPU stops with
// no panic and no console. Static logic always answers; the partition may not.
// See docs/ch13-plan.md §2.2.
//
// HB_BITS picks the toggle rate, and it is not a free parameter: it sets the
// FLOOR on how long a swap takes.
//
// Liveness is decided by watching the heartbeat CHANGE, so detecting it cannot
// be faster than half a period. At 24 bits that is 2^23 cycles -- 44.7 ms at
// 187.5 MHz -- and the first hardware measurement showed exactly that: a 138 ms
// swap of which 87 ms was the actual PCAP transfer and 50 ms was the driver
// waiting for a toggle it had been made to wait for.
//
// 20 bits gives 2.8 ms, which software polling at millisecond granularity still
// catches easily, and hands the third of the swap back. The testbench overrides
// it to 8, because even 2.8 ms is not a simulation.
`timescale 1ns/10ps
module socket_ctrl
  #
  (
   parameter ADDR_WIDTH = 6,
   parameter DATA_WIDTH = 32,
   // Set per reconfigurable module. See sw/kernel_ids.py for the registry.
   parameter [31:0] KERNEL_ID = 32'hA5A5_0000,
   parameter HB_BITS = 20
   )
  (
   input wire                    clk,
   input wire                    rst_n,

   // ---- AXI4-Lite slave ----
   input wire [ADDR_WIDTH-1:0]   awaddr,
   input wire                    awvalid,
   output logic                  awready,
   input wire [DATA_WIDTH-1:0]   wdata,
   input wire [DATA_WIDTH/8-1:0] wstrb,
   input wire                    wvalid,
   output logic                  wready,
   output logic [1:0]            bresp,
   output logic                  bvalid,
   input wire                    bready,
   input wire [ADDR_WIDTH-1:0]   araddr,
   input wire                    arvalid,
   output logic                  arready,
   output logic [DATA_WIDTH-1:0] rdata,
   output logic [1:0]            rresp,
   output logic                  rvalid,
   input wire                    rready,

   /* verilator lint_off SYMRSVDWORD */
   // Named `interrupt` because Vitis HLS names it that and the block design
   // connects it by name. Verilator flags it as a C++ reserved word; renaming
   // it would break drop-in compatibility with the HLS control interface,
   // which is the socket contract's whole purpose, so the warning is scoped
   // off here rather than the signal renamed.
   output logic                  interrupt,
   /* verilator lint_on SYMRSVDWORD */
   // to the static region's status GPIO, NOT through the AXI4-Lite port
   output logic                  heartbeat,

   // ---- to/from the datapath ----
   output logic                  ap_start,
   // Single-cycle launch strobe. The engines cannot use an edge on ap_start:
   // a start queued behind a running frame re-arms a bit that is already set,
   // which produces no edge and silently loses the frame. See start_pending.
   output logic                  ap_launch,
   input wire                    ap_done,
   output logic [63:0]           src_addr,
   output logic [63:0]           dst_addr,
   output logic [31:0]           img_width,
   output logic [31:0]           img_height,
   output logic [31:0]           mode
   );

  localparam [ADDR_WIDTH-1:0] ADDR_CTRL   = 6'h00;
  localparam [ADDR_WIDTH-1:0] ADDR_GIER   = 6'h04;
  localparam [ADDR_WIDTH-1:0] ADDR_IER    = 6'h08;
  localparam [ADDR_WIDTH-1:0] ADDR_ISR    = 6'h0C;
  localparam [ADDR_WIDTH-1:0] ADDR_SRC_LO = 6'h10;
  localparam [ADDR_WIDTH-1:0] ADDR_SRC_HI = 6'h14;
  localparam [ADDR_WIDTH-1:0] ADDR_DST_LO = 6'h1C;
  localparam [ADDR_WIDTH-1:0] ADDR_DST_HI = 6'h20;
  localparam [ADDR_WIDTH-1:0] ADDR_WIDTH_ = 6'h28;
  localparam [ADDR_WIDTH-1:0] ADDR_HEIGHT = 6'h30;
  localparam [ADDR_WIDTH-1:0] ADDR_MODE   = 6'h38;
  localparam [ADDR_WIDTH-1:0] ADDR_KERNEL = 6'h3C;

  logic               ap_idle;
  // A start that arrived while a frame was running, waiting its turn.
  // Discarding it turns any momentary disagreement between software and
  // hardware into a permanent hang: nothing running, ap_idle set, and a poll
  // that can never be satisfied. CH12 measured that at about one frame in a
  // thousand before the queue was added.
  logic               start_pending;
  logic               ap_done_r;
  logic               ap_ready_r;
  logic               auto_restart;
  logic               gie;
  logic [1:0]         ier;
  logic [1:0]         isr;
  logic [HB_BITS-1:0] hb_cnt;

  // ---------------------------------------------------------------------
  // Write channel
  //
  // AW and W are latched INDEPENDENTLY and the write commits when both are
  // present. Requiring them in the same cycle is legal-looking, simulates
  // fine against a lazy testbench, and hangs the PS on hardware -- the PS
  // routinely sends the address ahead of the data. tb/socket_ctrl_broken.sv
  // is that bug, kept so the testbench can be shown to catch it.
  // ---------------------------------------------------------------------
  logic                    aw_hs;
  logic                    w_hs;
  logic [ADDR_WIDTH-1:0]   awaddr_r;
  logic                    awaddr_v;
  logic [DATA_WIDTH-1:0]   wdata_r;
  logic [DATA_WIDTH/8-1:0] wstrb_r;
  logic                    wdata_v;
  logic                    do_write;

  assign aw_hs = awvalid && awready;
  assign w_hs  = wvalid  && wready;

  assign awready  = !awaddr_v;
  assign wready   = !wdata_v;
  assign do_write = awaddr_v && wdata_v && (!bvalid || bready);

  function automatic [DATA_WIDTH-1:0] wr_mask
    (input [DATA_WIDTH-1:0] old_v,
     input [DATA_WIDTH-1:0] new_v,
     input [DATA_WIDTH/8-1:0] strb);
    integer b;
    begin
      wr_mask = old_v;
      for (b = 0; b < DATA_WIDTH/8; b = b + 1)
        if (strb[b]) wr_mask[b*8 +: 8] = new_v[b*8 +: 8];
    end
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      awaddr_v <= 1'b0;
      wdata_v  <= 1'b0;
      bvalid   <= 1'b0;
      bresp    <= 2'b00;
    end else begin
      if (aw_hs) begin
        awaddr_r <= awaddr;
        awaddr_v <= 1'b1;
      end
      if (w_hs) begin
        wdata_r <= wdata;
        wstrb_r <= wstrb;
        wdata_v <= 1'b1;
      end
      if (do_write) begin
        awaddr_v <= 1'b0;
        wdata_v  <= 1'b0;
        bvalid   <= 1'b1;
        bresp    <= 2'b00;
      end else if (bvalid && bready) begin
        bvalid <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Read channel
  // ---------------------------------------------------------------------
  logic [ADDR_WIDTH-1:0] araddr_r;
  logic                  do_read;

  assign arready = !rvalid;
  assign do_read = arvalid && arready;

  always_comb begin
    case (araddr_r)
      ADDR_CTRL:   rdata = {22'd0, interrupt, 1'b0, auto_restart, 3'd0,
                            ap_ready_r, ap_idle, ap_done_r, ap_start};
      ADDR_GIER:   rdata = {31'd0, gie};
      ADDR_IER:    rdata = {30'd0, ier};
      ADDR_ISR:    rdata = {30'd0, isr};
      ADDR_SRC_LO: rdata = src_addr[31:0];
      ADDR_SRC_HI: rdata = src_addr[63:32];
      ADDR_DST_LO: rdata = dst_addr[31:0];
      ADDR_DST_HI: rdata = dst_addr[63:32];
      ADDR_WIDTH_: rdata = img_width;
      ADDR_HEIGHT: rdata = img_height;
      ADDR_MODE:   rdata = mode;
      ADDR_KERNEL: rdata = KERNEL_ID;
      default:     rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rvalid   <= 1'b0;
      rresp    <= 2'b00;
      araddr_r <= '0;
    end else begin
      if (do_read) begin
        araddr_r <= araddr;
        rvalid   <= 1'b1;
        rresp    <= 2'b00;
      end else if (rvalid && rready) begin
        rvalid <= 1'b0;
      end
    end
  end

  // A CTRL read that is actually handed to the master clears ap_done/ap_ready.
  // "Actually handed to" is the whole subtlety: CH12 lost about one completion
  // in a thousand to a read that was acknowledged at the accelerator and never
  // delivered to the PS, and because ap_done is clear-on-read the
  // acknowledgement destroyed the completion rather than delaying it. The
  // architectural answer is in the block design -- the socket's control path
  // gets its own PS master and crosses no clock domain, see
  // docs/ch13-plan.md §2.3 -- but the register file must still be exactly
  // this careful about which read counts.
  logic ctrl_read_ack;
  assign ctrl_read_ack = rvalid && rready && (araddr_r == ADDR_CTRL);

  // The engine is free and a start is armed. One cycle, because ap_idle drops
  // on the next edge.
  logic do_launch;
  assign do_launch = ap_start && ap_idle && !ap_done;
  assign ap_launch = do_launch;

  // ---------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ap_start      <= 1'b0;
      start_pending <= 1'b0;
      ap_idle       <= 1'b1;
      ap_done_r     <= 1'b0;
      ap_ready_r    <= 1'b0;
      auto_restart  <= 1'b0;
      gie           <= 1'b0;
      ier           <= 2'd0;
      isr           <= 2'd0;
      src_addr      <= 64'd0;
      dst_addr      <= 64'd0;
      img_width     <= 32'd0;
      img_height    <= 32'd0;
      mode          <= 32'd0;
      hb_cnt        <= '0;
    end else begin
      hb_cnt <= hb_cnt + 1'b1;

      // Completion. The set MUST take priority over the clear-on-read: a
      // polling master reads CTRL continuously, so sooner or later a read
      // handshake lands in the same cycle as the done pulse. If the clear won
      // there, the completion would be lost and the master would poll forever.
      // With the set winning, that read simply returns 0 and the next one
      // returns 1.
      if (ap_done) begin
        ap_done_r     <= 1'b1;
        ap_ready_r    <= 1'b1;
        ap_idle       <= 1'b1;
        // A queued start is armed here instead of being thrown away.
        ap_start      <= start_pending ? 1'b1 : auto_restart;
        start_pending <= 1'b0;
        if (ier[0]) isr[0] <= 1'b1;
        if (ier[1]) isr[1] <= 1'b1;
      end else if (ctrl_read_ack) begin
        ap_done_r  <= 1'b0;
        ap_ready_r <= 1'b0;
      end

      if (do_launch) begin
        ap_idle <= 1'b0;
      end

      if (do_write) begin
        case (awaddr_r)
          ADDR_CTRL: begin
            if (wstrb_r[0]) begin
              if (wdata_r[0]) begin
                // Free now -- arm it. Busy, or being consumed this very
                // cycle -- queue it. Never discard it.
                if (ap_idle && !do_launch) ap_start      <= 1'b1;
                else                       start_pending <= 1'b1;
              end
              auto_restart <= wdata_r[7];
            end
          end
          ADDR_GIER:   if (wstrb_r[0]) gie <= wdata_r[0];
          ADDR_IER:    if (wstrb_r[0]) ier <= wdata_r[1:0];
          // toggle-on-write
          ADDR_ISR:    if (wstrb_r[0]) isr <= isr ^ wdata_r[1:0];
          ADDR_SRC_LO: src_addr[31:0]  <= wr_mask(src_addr[31:0],  wdata_r, wstrb_r);
          ADDR_SRC_HI: src_addr[63:32] <= wr_mask(src_addr[63:32], wdata_r, wstrb_r);
          ADDR_DST_LO: dst_addr[31:0]  <= wr_mask(dst_addr[31:0],  wdata_r, wstrb_r);
          ADDR_DST_HI: dst_addr[63:32] <= wr_mask(dst_addr[63:32], wdata_r, wstrb_r);
          ADDR_WIDTH_: img_width  <= wr_mask(img_width,  wdata_r, wstrb_r);
          ADDR_HEIGHT: img_height <= wr_mask(img_height, wdata_r, wstrb_r);
          ADDR_MODE:   mode       <= wr_mask(mode,       wdata_r, wstrb_r);
          // ADDR_KERNEL is read-only: a write to it must land nowhere at all,
          // not on the neighbouring mode register.
          default: ;
        endcase
      end
    end
  end

  assign interrupt = gie & (|isr);
  assign heartbeat = hb_cnt[HB_BITS-1];

endmodule
