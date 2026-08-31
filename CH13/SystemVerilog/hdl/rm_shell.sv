// rm_shell.sv
// ------------------------------------
// Everything in a reconfigurable module except the filter itself
// ------------------------------------
// Author : Frank Bruno
//
// The socket contract has a lot of surface -- an AXI4-Lite slave, two AXI4
// masters, the ap_ctrl_hs handshake, two FIFOs and the burst engines -- and
// none of it varies between kernels. Only the core does. So the shell is
// written once and each RM is a thin top that pairs it with one core:
//
//     rm_blur.sv  =  rm_shell (KERNEL_ID = ...)  +  rm_blur_core
//
// The core hangs off the shell as an ordinary ready/valid stream, which is why
// the shell can be shared: it never needs to know what the core computes, only
// how many pixels go in and come out.
//
// Every RM must present EXACTLY these ports, in this order, with these widths.
// A DFX partition is a physical boundary: the static region is routed to it
// once, and every partial that lands there has to match what was routed. A
// mismatched port list is not a compile error, it is a partial that does not
// fit the socket -- so this port list is generated from CH12's video_filter.sv
// rather than retyped, and the socket's own interface is the same contract
// CH11 and CH12 present. See docs/ch13-plan.md 2.1.
//
// Module names, by contrast, MUST differ between RMs. Vivado identifies a
// reconfigurable module by its top module, and two RMs sharing a name is how
// you get a partial that silently belongs to the wrong configuration.
`timescale 1ns/10ps
module rm_shell
  #
  (
   parameter C_S_AXI_CONTROL_ADDR_WIDTH = 6,
   parameter C_S_AXI_CONTROL_DATA_WIDTH = 32,
   parameter C_M_AXI_GMEM_ADDR_WIDTH    = 64,
   parameter C_M_AXI_GMEM_DATA_WIDTH    = 32,
   parameter C_M_AXI_GMEM_ID_WIDTH      = 1,
   parameter FIFO_DEPTH                 = 512,
   // The identity this RM reports at register 0x3C. See sw/rm_ref.py.
   parameter [31:0] KERNEL_ID           = 32'hA5A5_0000,
   parameter HB_BITS                    = 24
   )
  (
   input wire                                  ap_clk,
   input wire                                  ap_rst_n,
   /* verilator lint_off SYMRSVDWORD */
   // Named `interrupt` because Vitis HLS names it that and the block design
   // connects it by name. It is a reserved word to some tools; renaming it
   // would break drop-in compatibility with the HLS IP, which is the whole
   // point of this module.
   output wire                                 interrupt,
   /* verilator lint_on SYMRSVDWORD */

   // ---- AXI4-Lite control ----
   input wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0] s_axi_control_awaddr,
   input wire                                  s_axi_control_awvalid,
   output wire                                 s_axi_control_awready,
   input wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0] s_axi_control_wdata,
   input wire [C_S_AXI_CONTROL_DATA_WIDTH/8-1:0] s_axi_control_wstrb,
   input wire                                  s_axi_control_wvalid,
   output wire                                 s_axi_control_wready,
   output wire [1:0]                           s_axi_control_bresp,
   output wire                                 s_axi_control_bvalid,
   input wire                                  s_axi_control_bready,
   input wire [C_S_AXI_CONTROL_ADDR_WIDTH-1:0] s_axi_control_araddr,
   input wire                                  s_axi_control_arvalid,
   output wire                                 s_axi_control_arready,
   output wire [C_S_AXI_CONTROL_DATA_WIDTH-1:0] s_axi_control_rdata,
   output wire [1:0]                           s_axi_control_rresp,
   output wire                                 s_axi_control_rvalid,
   input wire                                  s_axi_control_rready,

   // ---- AXI4 master, source ----
   output wire [C_M_AXI_GMEM_ID_WIDTH-1:0]     m_axi_gmem0_awid,
   output wire [C_M_AXI_GMEM_ADDR_WIDTH-1:0]   m_axi_gmem0_awaddr,
   output wire [7:0]                           m_axi_gmem0_awlen,
   output wire [2:0]                           m_axi_gmem0_awsize,
   output wire [1:0]                           m_axi_gmem0_awburst,
   output wire [1:0]                           m_axi_gmem0_awlock,
   output wire [3:0]                           m_axi_gmem0_awcache,
   output wire [2:0]                           m_axi_gmem0_awprot,
   output wire [3:0]                           m_axi_gmem0_awqos,
   output wire                                 m_axi_gmem0_awvalid,
   input wire                                  m_axi_gmem0_awready,
   output wire [C_M_AXI_GMEM_DATA_WIDTH-1:0]   m_axi_gmem0_wdata,
   output wire [C_M_AXI_GMEM_DATA_WIDTH/8-1:0] m_axi_gmem0_wstrb,
   output wire                                 m_axi_gmem0_wlast,
   output wire                                 m_axi_gmem0_wvalid,
   input wire                                  m_axi_gmem0_wready,
   input wire [C_M_AXI_GMEM_ID_WIDTH-1:0]      m_axi_gmem0_bid,
   input wire [1:0]                            m_axi_gmem0_bresp,
   input wire                                  m_axi_gmem0_bvalid,
   output wire                                 m_axi_gmem0_bready,
   output wire [C_M_AXI_GMEM_ID_WIDTH-1:0]     m_axi_gmem0_arid,
   output wire [C_M_AXI_GMEM_ADDR_WIDTH-1:0]   m_axi_gmem0_araddr,
   output wire [7:0]                           m_axi_gmem0_arlen,
   output wire [2:0]                           m_axi_gmem0_arsize,
   output wire [1:0]                           m_axi_gmem0_arburst,
   output wire [1:0]                           m_axi_gmem0_arlock,
   output wire [3:0]                           m_axi_gmem0_arcache,
   output wire [2:0]                           m_axi_gmem0_arprot,
   output wire [3:0]                           m_axi_gmem0_arqos,
   output wire                                 m_axi_gmem0_arvalid,
   input wire                                  m_axi_gmem0_arready,
   input wire [C_M_AXI_GMEM_ID_WIDTH-1:0]      m_axi_gmem0_rid,
   input wire [C_M_AXI_GMEM_DATA_WIDTH-1:0]    m_axi_gmem0_rdata,
   input wire [1:0]                            m_axi_gmem0_rresp,
   input wire                                  m_axi_gmem0_rlast,
   input wire                                  m_axi_gmem0_rvalid,
   output wire                                 m_axi_gmem0_rready,

   // ---- AXI4 master, destination ----
   output wire [C_M_AXI_GMEM_ID_WIDTH-1:0]     m_axi_gmem1_awid,
   output wire [C_M_AXI_GMEM_ADDR_WIDTH-1:0]   m_axi_gmem1_awaddr,
   output wire [7:0]                           m_axi_gmem1_awlen,
   output wire [2:0]                           m_axi_gmem1_awsize,
   output wire [1:0]                           m_axi_gmem1_awburst,
   output wire [1:0]                           m_axi_gmem1_awlock,
   output wire [3:0]                           m_axi_gmem1_awcache,
   output wire [2:0]                           m_axi_gmem1_awprot,
   output wire [3:0]                           m_axi_gmem1_awqos,
   output wire                                 m_axi_gmem1_awvalid,
   input wire                                  m_axi_gmem1_awready,
   output wire [C_M_AXI_GMEM_DATA_WIDTH-1:0]   m_axi_gmem1_wdata,
   output wire [C_M_AXI_GMEM_DATA_WIDTH/8-1:0] m_axi_gmem1_wstrb,
   output wire                                 m_axi_gmem1_wlast,
   output wire                                 m_axi_gmem1_wvalid,
   input wire                                  m_axi_gmem1_wready,
   input wire [C_M_AXI_GMEM_ID_WIDTH-1:0]      m_axi_gmem1_bid,
   input wire [1:0]                            m_axi_gmem1_bresp,
   input wire                                  m_axi_gmem1_bvalid,
   output wire                                 m_axi_gmem1_bready,
   output wire [C_M_AXI_GMEM_ID_WIDTH-1:0]     m_axi_gmem1_arid,
   output wire [C_M_AXI_GMEM_ADDR_WIDTH-1:0]   m_axi_gmem1_araddr,
   output wire [7:0]                           m_axi_gmem1_arlen,
   output wire [2:0]                           m_axi_gmem1_arsize,
   output wire [1:0]                           m_axi_gmem1_arburst,
   output wire [1:0]                           m_axi_gmem1_arlock,
   output wire [3:0]                           m_axi_gmem1_arcache,
   output wire [2:0]                           m_axi_gmem1_arprot,
   output wire [3:0]                           m_axi_gmem1_arqos,
   output wire                                 m_axi_gmem1_arvalid,
   input wire                                  m_axi_gmem1_arready,
   input wire [C_M_AXI_GMEM_ID_WIDTH-1:0]      m_axi_gmem1_rid,
   input wire [C_M_AXI_GMEM_DATA_WIDTH-1:0]    m_axi_gmem1_rdata,
   input wire [1:0]                            m_axi_gmem1_rresp,
   input wire                                  m_axi_gmem1_rlast,
   input wire                                  m_axi_gmem1_rvalid,
   output wire                                 m_axi_gmem1_rready,
   // ---- the core, as an ordinary stream ----
   // The shell counts pixels and moves them; the core decides what they become.
   output wire                                 core_start,
   output wire [15:0]                          core_img_width,
   output wire [15:0]                          core_img_height,
   output wire [31:0]                          core_mode,
   input  wire                                 core_done,
   output wire                                 core_s_valid,
   output wire [31:0]                          core_s_data,
   input  wire                                 core_s_ready,
   input  wire                                 core_m_valid,
   input  wire [31:0]                          core_m_data,
   output wire                                 core_m_ready,

   // ---- to the static region's status GPIO ----
   output wire                                 heartbeat
   );

  localparam CNT_W = $clog2(FIFO_DEPTH) + 1;

  wire        ap_start;
  wire        launch;
  wire        ap_done;
  wire [63:0] src_addr, dst_addr;
  wire [31:0] img_width, img_height, mode;

  // total pixels = words on both masters
  wire [31:0] total_words = img_width * img_height;

  // ------------------------------------------------------------------
  // Control
  // ------------------------------------------------------------------
  socket_ctrl
    #(.ADDR_WIDTH (C_S_AXI_CONTROL_ADDR_WIDTH),
      .DATA_WIDTH (C_S_AXI_CONTROL_DATA_WIDTH),
      .KERNEL_ID  (KERNEL_ID),
      .HB_BITS    (HB_BITS))
  u_ctrl
    (.clk        (ap_clk),
     .rst_n      (ap_rst_n),
     .awaddr     (s_axi_control_awaddr),
     .awvalid    (s_axi_control_awvalid),
     .awready    (s_axi_control_awready),
     .wdata      (s_axi_control_wdata),
     .wstrb      (s_axi_control_wstrb),
     .wvalid     (s_axi_control_wvalid),
     .wready     (s_axi_control_wready),
     .bresp      (s_axi_control_bresp),
     .bvalid     (s_axi_control_bvalid),
     .bready     (s_axi_control_bready),
     .araddr     (s_axi_control_araddr),
     .arvalid    (s_axi_control_arvalid),
     .arready    (s_axi_control_arready),
     .rdata      (s_axi_control_rdata),
     .rresp      (s_axi_control_rresp),
     .rvalid     (s_axi_control_rvalid),
     .rready     (s_axi_control_rready),
     .interrupt  (interrupt),
     .heartbeat  (heartbeat),
     .ap_start   (ap_start),
     .ap_launch  (launch),
     .ap_done    (ap_done),
     .src_addr   (src_addr),
     .dst_addr   (dst_addr),
     .img_width  (img_width),
     .img_height (img_height),
     .mode       (mode));

  // The control block emits the launch strobe directly. It used to be derived
  // here as an edge on ap_start, which cannot express a start queued behind a
  // running frame: re-arming an already-set bit produces no edge, and the
  // frame is lost. See video_filter_ctrl.sv.

  // ------------------------------------------------------------------
  // Read path: gmem0 -> input FIFO
  // ------------------------------------------------------------------
  // core_s_ready / core_m_valid / core_m_data / core_m_ready are ports now.
  wire        rd_valid, rd_ready;
  wire [31:0] rd_data;
  wire [CNT_W-1:0] in_count;
  wire        in_full, in_empty;
  wire [31:0] in_dout;

  wire [CNT_W-1:0] in_free = FIFO_DEPTH[CNT_W-1:0] - in_count;

  rm_axi_rd
    #(.ADDR_WIDTH (C_M_AXI_GMEM_ADDR_WIDTH),
      .DATA_WIDTH (C_M_AXI_GMEM_DATA_WIDTH),
      .ID_WIDTH   (C_M_AXI_GMEM_ID_WIDTH),
      .CNT_WIDTH  (CNT_W))
  u_rd
    (.clk         (ap_clk),
     .rst_n       (ap_rst_n),
     .start       (launch),
     .base_addr   (src_addr),
     .total_words (total_words),
     .arid        (m_axi_gmem0_arid),
     .araddr      (m_axi_gmem0_araddr),
     .arlen       (m_axi_gmem0_arlen),
     .arsize      (m_axi_gmem0_arsize),
     .arburst     (m_axi_gmem0_arburst),
     .arvalid     (m_axi_gmem0_arvalid),
     .arready     (m_axi_gmem0_arready),
     .rdata       (m_axi_gmem0_rdata),
     .rresp       (m_axi_gmem0_rresp),
     .rlast       (m_axi_gmem0_rlast),
     .rvalid      (m_axi_gmem0_rvalid),
     .rready      (m_axi_gmem0_rready),
     .m_valid     (rd_valid),
     .m_data      (rd_data),
     .m_ready     (rd_ready),
     .m_free      (in_free));

  assign rd_ready = !in_full;

  sync_fifo #(.WIDTH (32), .DEPTH (FIFO_DEPTH))
  u_fifo_in
    (.clk    (ap_clk),
     .rst_n  (ap_rst_n),
     .wr_en  (rd_valid && rd_ready),
     .din    (rd_data),
     .rd_en  (core_s_ready),
     .dout   (in_dout),
     .empty  (in_empty),
     .full   (in_full),
     .count  (in_count));

  // ------------------------------------------------------------------
  // The core, brought out as ports
  //
  // This is the whole reason the shell exists. Everything above and below is
  // identical in every RM; only what happens between core_s_* and core_m_* is
  // the kernel. The shell never learns what that is.
  // ------------------------------------------------------------------
  assign core_start      = launch;
  assign core_img_width  = img_width[15:0];
  assign core_img_height = img_height[15:0];
  assign core_mode       = mode;
  assign core_s_valid    = !in_empty;
  assign core_s_data     = in_dout;

  // ------------------------------------------------------------------
  // Write path: output FIFO -> gmem1
  // ------------------------------------------------------------------
  wire        out_full, out_empty;
  wire [31:0] out_dout;
  wire [CNT_W-1:0] out_count;
  wire        wr_s_ready;

  assign core_m_ready = !out_full;

  sync_fifo #(.WIDTH (32), .DEPTH (FIFO_DEPTH))
  u_fifo_out
    (.clk    (ap_clk),
     .rst_n  (ap_rst_n),
     .wr_en  (core_m_valid && core_m_ready),
     .din    (core_m_data),
     .rd_en  (wr_s_ready),
     .dout   (out_dout),
     .empty  (out_empty),
     .full   (out_full),
     .count  (out_count));

  wire wr_done;

  rm_axi_wr
    #(.ADDR_WIDTH (C_M_AXI_GMEM_ADDR_WIDTH),
      .DATA_WIDTH (C_M_AXI_GMEM_DATA_WIDTH),
      .ID_WIDTH   (C_M_AXI_GMEM_ID_WIDTH),
      .CNT_WIDTH  (CNT_W))
  u_wr
    (.clk         (ap_clk),
     .rst_n       (ap_rst_n),
     .start       (launch),
     .base_addr   (dst_addr),
     .total_words (total_words),
     .done        (wr_done),
     .awid        (m_axi_gmem1_awid),
     .awaddr      (m_axi_gmem1_awaddr),
     .awlen       (m_axi_gmem1_awlen),
     .awsize      (m_axi_gmem1_awsize),
     .awburst     (m_axi_gmem1_awburst),
     .awvalid     (m_axi_gmem1_awvalid),
     .awready     (m_axi_gmem1_awready),
     .wdata       (m_axi_gmem1_wdata),
     .wstrb       (m_axi_gmem1_wstrb),
     .wlast       (m_axi_gmem1_wlast),
     .wvalid      (m_axi_gmem1_wvalid),
     .wready      (m_axi_gmem1_wready),
     .bresp       (m_axi_gmem1_bresp),
     .bvalid      (m_axi_gmem1_bvalid),
     .bready      (m_axi_gmem1_bready),
     .s_valid     (!out_empty),
     .s_data      (out_dout),
     .s_ready     (wr_s_ready),
     .s_count     (out_count));

  // The kernel is finished when the last write response has come back. A
  // zero-sized image never starts an engine, so complete it off the core.
  wire zero_sized = (total_words == 32'd0);
  assign ap_done = wr_done | (zero_sized & core_done);

  // ------------------------------------------------------------------
  // Unused master signals -- gmem0 never writes, gmem1 never reads
  //
  // The ports have to exist even so. Vivado's ipx::infer_bus_interfaces
  // recognises m_axi_gmem0/1 as AXI4 masters by matching the complete port
  // set; leave half a channel off and the packaged IP has no bus interface at
  // all, which shows up as a block design that will not connect rather than as
  // anything a simulation would catch.
  // ------------------------------------------------------------------
  assign m_axi_gmem0_awid    = '0;
  assign m_axi_gmem0_awaddr  = '0;
  assign m_axi_gmem0_awlen   = '0;
  assign m_axi_gmem0_awsize  = 3'b010;
  assign m_axi_gmem0_awburst = 2'b01;
  assign m_axi_gmem0_awvalid = 1'b0;
  assign m_axi_gmem0_wdata   = '0;
  assign m_axi_gmem0_wstrb   = '0;
  assign m_axi_gmem0_wlast   = 1'b0;
  assign m_axi_gmem0_wvalid  = 1'b0;
  assign m_axi_gmem0_bready  = 1'b1;
  assign m_axi_gmem0_awlock  = 2'b00;
  assign m_axi_gmem0_awcache = 4'b0011;
  assign m_axi_gmem0_awprot  = 3'b000;
  assign m_axi_gmem0_awqos   = 4'b0000;
  assign m_axi_gmem0_arlock  = 2'b00;
  assign m_axi_gmem0_arcache = 4'b0011;
  assign m_axi_gmem0_arprot  = 3'b000;
  assign m_axi_gmem0_arqos   = 4'b0000;

  assign m_axi_gmem1_arid    = '0;
  assign m_axi_gmem1_araddr  = '0;
  assign m_axi_gmem1_arlen   = '0;
  assign m_axi_gmem1_arsize  = 3'b010;
  assign m_axi_gmem1_arburst = 2'b01;
  assign m_axi_gmem1_arvalid = 1'b0;
  assign m_axi_gmem1_rready  = 1'b1;
  assign m_axi_gmem1_awlock  = 2'b00;
  assign m_axi_gmem1_awcache = 4'b0011;
  assign m_axi_gmem1_awprot  = 3'b000;
  assign m_axi_gmem1_awqos   = 4'b0000;
  assign m_axi_gmem1_arlock  = 2'b00;
  assign m_axi_gmem1_arcache = 4'b0011;
  assign m_axi_gmem1_arprot  = 3'b000;
  assign m_axi_gmem1_arqos   = 4'b0000;

  // ap_start is still the readable CTRL bit and still means "armed or
  // running", but the engines are launched by the strobe now, so the top level
  // has no use for it.
  wire _unused_ctrl = &{1'b0, ap_start};

  wire _unused_ports = &{1'b0,
                         m_axi_gmem0_awready, m_axi_gmem0_wready,
                         m_axi_gmem0_bid, m_axi_gmem0_bresp, m_axi_gmem0_bvalid,
                         m_axi_gmem0_rid,
                         m_axi_gmem1_arready,
                         m_axi_gmem1_rid, m_axi_gmem1_rdata, m_axi_gmem1_rresp,
                         m_axi_gmem1_rlast, m_axi_gmem1_rvalid,
                         m_axi_gmem1_bid};

endmodule
