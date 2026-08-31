// socket_ctrl_broken.sv
// ------------------------------------
// The negative control: the CH13 spike's AXI4-Lite bug, kept on purpose
// ------------------------------------
// Author : Frank Bruno
//
// This is socket_ctrl with exactly one thing wrong. It completes a write only
// when AW and W arrive in the SAME cycle:
//
//     assign do_write = aw_hs && w_hs;          // wrong
//     assign do_write = awaddr_v && wdata_v;    // right, see socket_ctrl.sv
//
// AXI4-Lite makes no ordering guarantee between the two channels, and the
// ZynqMP PS routinely issues the address a cycle or more ahead of the data.
// So on hardware this slave accepts a write, never asserts bvalid, and the CPU
// waits for a response that will not come. There is no bus timeout on the PL
// ports, so it does not fault -- it stops, with no panic and no console, and
// only a power cycle recovers it. That is what this cost during the spike.
//
// It is here so `./sim.sh --socket --negative` can prove tb_socket_ctrl
// detects it. A testbench nobody has watched fail is a testbench with no
// demonstrated power to fail, and this chapter's whole argument is that the
// components with testbenches cost nothing and the ones without cost board
// time.
//
// NOT SYNTHESISED, NOT INSTANTIATED anywhere in a build. Testbench only.
`timescale 1ns/10ps
module socket_ctrl_broken
  #
  (
   parameter ADDR_WIDTH = 6,
   parameter DATA_WIDTH = 32,
   parameter [31:0] KERNEL_ID = 32'hA5A5_0001,
   parameter HB_BITS = 24
   )
  (
   input wire                    clk,
   input wire                    rst_n,

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

   output logic                  interrupt,
   output logic                  heartbeat,

   output logic                  ap_start,
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

  logic       ap_idle;
  logic       start_pending;
  logic       ap_done_r;
  logic       ap_ready_r;
  logic       auto_restart;
  logic       gie;
  logic [1:0] ier;
  logic [1:0] isr;
  logic [HB_BITS-1:0] hb_cnt;

  // ---- the bug ----
  logic aw_hs, w_hs, do_write;
  assign awready  = 1'b1;
  assign wready   = 1'b1;
  assign aw_hs    = awvalid && awready;
  assign w_hs     = wvalid  && wready;
  assign do_write = aw_hs && w_hs;      // <-- requires the same cycle
  // ------------------

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
      bvalid <= 1'b0;
      bresp  <= 2'b00;
    end else begin
      if (do_write) begin
        bvalid <= 1'b1;
        bresp  <= 2'b00;
      end else if (bvalid && bready) begin
        bvalid <= 1'b0;
      end
    end
  end

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

  logic ctrl_read_ack;
  assign ctrl_read_ack = rvalid && rready && (araddr_r == ADDR_CTRL);

  logic do_launch;
  assign do_launch = ap_start && ap_idle && !ap_done;
  assign ap_launch = do_launch;

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
      if (ap_done) begin
        ap_done_r     <= 1'b1;
        ap_ready_r    <= 1'b1;
        ap_idle       <= 1'b1;
        ap_start      <= start_pending ? 1'b1 : auto_restart;
        start_pending <= 1'b0;
        if (ier[0]) isr[0] <= 1'b1;
        if (ier[1]) isr[1] <= 1'b1;
      end else if (ctrl_read_ack) begin
        ap_done_r  <= 1'b0;
        ap_ready_r <= 1'b0;
      end

      if (do_launch) ap_idle <= 1'b0;

      if (do_write) begin
        case (awaddr)
          ADDR_CTRL: begin
            if (wstrb[0]) begin
              if (wdata[0]) begin
                if (ap_idle && !do_launch) ap_start      <= 1'b1;
                else                       start_pending <= 1'b1;
              end
              auto_restart <= wdata[7];
            end
          end
          ADDR_GIER:   if (wstrb[0]) gie <= wdata[0];
          ADDR_IER:    if (wstrb[0]) ier <= wdata[1:0];
          ADDR_ISR:    if (wstrb[0]) isr <= isr ^ wdata[1:0];
          ADDR_SRC_LO: src_addr[31:0]  <= wr_mask(src_addr[31:0],  wdata, wstrb);
          ADDR_SRC_HI: src_addr[63:32] <= wr_mask(src_addr[63:32], wdata, wstrb);
          ADDR_DST_LO: dst_addr[31:0]  <= wr_mask(dst_addr[31:0],  wdata, wstrb);
          ADDR_DST_HI: dst_addr[63:32] <= wr_mask(dst_addr[63:32], wdata, wstrb);
          ADDR_WIDTH_: img_width  <= wr_mask(img_width,  wdata, wstrb);
          ADDR_HEIGHT: img_height <= wr_mask(img_height, wdata, wstrb);
          ADDR_MODE:   mode       <= wr_mask(mode,       wdata, wstrb);
          default: ;
        endcase
      end
    end
  end

  assign interrupt = gie & (|isr);
  assign heartbeat = hb_cnt[HB_BITS-1];

endmodule
