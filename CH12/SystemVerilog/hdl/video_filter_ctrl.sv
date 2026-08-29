// video_filter_ctrl.sv
// ------------------------------------
// AXI4-Lite control/status register file for the video filter
// ------------------------------------
// Author : Frank Bruno
//
// Register map -- deliberately byte-for-byte identical to what Vitis HLS
// generates for this kernel, and to CH11's, so one notebook and one driver
// (sw/filter_driver.py) work against any of them without modification:
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
//   0x38 mode      0 gray, 1 sobel, 2 invert, 3 colour passthrough
//
// This module is CH11's control block unchanged apart from its name. That is
// the point of keeping the register map: everything that talks to the
// accelerator -- PYNQ's register_map, sw/filter_driver.py, the testbench --
// carries over to CH12 without a line of change, and the two chapters'
// accelerators are interchangeable at this interface.
//
// NOTE the argument names: img_width / img_height, never width / height. PYNQ
// builds register_map by making a Python property per register field on its
// Register class, and Register.__init__ assigns self.width -- a field named
// "width" shadows that attribute and recurses to death on the first access.
`timescale 1ns/10ps
module video_filter_ctrl
  #
  (
   parameter ADDR_WIDTH = 6,
   parameter DATA_WIDTH = 32
   )
  (
   input wire                   clk,
   input wire                   rst_n,

   // AXI4-Lite slave
   input wire [ADDR_WIDTH-1:0]  awaddr,
   input wire                   awvalid,
   output logic                 awready,
   input wire [DATA_WIDTH-1:0]  wdata,
   input wire [DATA_WIDTH/8-1:0] wstrb,
   input wire                   wvalid,
   output logic                 wready,
   output logic [1:0]           bresp,
   output logic                 bvalid,
   input wire                   bready,
   input wire [ADDR_WIDTH-1:0]  araddr,
   input wire                   arvalid,
   output logic                 arready,
   output logic [DATA_WIDTH-1:0] rdata,
   output logic [1:0]           rresp,
   output logic                 rvalid,
   input wire                   rready,

   output logic                 interrupt,

   // to/from the datapath
   output logic                 ap_start,
   input wire                   ap_done,
   output logic [63:0]          src_addr,
   output logic [63:0]          dst_addr,
   output logic [31:0]          img_width,
   output logic [31:0]          img_height,
   output logic [31:0]          mode
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

  logic                  ap_idle;
  logic                  ap_done_r;
  logic                  ap_ready_r;
  logic                  auto_restart;
  logic                  gie;
  logic [1:0]            ier;
  logic [1:0]            isr;

  // ---------------------------------------------------------------------
  // Write channel
  // ---------------------------------------------------------------------
  logic                  aw_hs;
  logic                  w_hs;
  logic [ADDR_WIDTH-1:0] awaddr_r;
  logic                  awaddr_v;
  logic [DATA_WIDTH-1:0] wdata_r;
  logic [DATA_WIDTH/8-1:0] wstrb_r;
  logic                  wdata_v;
  logic                  do_write;

  assign aw_hs = awvalid && awready;
  assign w_hs  = wvalid  && wready;

  assign awready = !awaddr_v;
  assign wready  = !wdata_v;
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
  logic ctrl_read_ack;
  assign ctrl_read_ack = rvalid && rready && (araddr_r == ADDR_CTRL);

  // ---------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ap_start     <= 1'b0;
      ap_idle      <= 1'b1;
      ap_done_r    <= 1'b0;
      ap_ready_r   <= 1'b0;
      auto_restart <= 1'b0;
      gie          <= 1'b0;
      ier          <= 2'd0;
      isr          <= 2'd0;
      src_addr     <= 64'd0;
      dst_addr     <= 64'd0;
      img_width    <= 32'd0;
      img_height   <= 32'd0;
      mode         <= 32'd0;
    end else begin
      // Completion. The set MUST take priority over the clear-on-read: a
      // polling master reads CTRL continuously, so sooner or later a read
      // handshake lands in the same cycle as the done pulse. If the clear won
      // there, the completion would be lost and the master would poll forever.
      // With the set winning, that read simply returns 0 and the next one
      // returns 1.
      if (ap_done) begin
        ap_done_r  <= 1'b1;
        ap_ready_r <= 1'b1;
        ap_idle    <= 1'b1;
        ap_start   <= auto_restart;
        if (ier[0]) isr[0] <= 1'b1;
        if (ier[1]) isr[1] <= 1'b1;
      end else if (ctrl_read_ack) begin
        ap_done_r  <= 1'b0;
        ap_ready_r <= 1'b0;
      end

      // launch
      if (ap_start && ap_idle && !ap_done) begin
        ap_idle <= 1'b0;
      end

      if (do_write) begin
        case (awaddr_r)
          ADDR_CTRL: begin
            if (wstrb_r[0]) begin
              if (wdata_r[0] && ap_idle) ap_start <= 1'b1;
            end
            if (wstrb_r[0]) auto_restart <= wdata_r[7];
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
          default: ;
        endcase
      end
    end
  end

  assign interrupt = gie & (|isr);

endmodule
