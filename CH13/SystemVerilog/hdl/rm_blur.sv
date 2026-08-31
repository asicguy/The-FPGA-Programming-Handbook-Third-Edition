// rm_blur.sv
// ------------------------------------
// Reconfigurable module: 3x3 Gaussian, per colour channel
// ------------------------------------
// Author : Frank Bruno
//
// A reconfigurable module is a shell and a core, and this file is only the
// wiring between them. Everything that makes it a legal occupant of the
// socket -- the AXI4-Lite slave, the two AXI4 masters, ap_ctrl_hs, the burst
// engines and the FIFOs -- is in rm_shell.sv and is identical in every RM.
// What this one computes is in rm_blur_core.sv.
//
// Two things about this file are load-bearing:
//
//   * The PORT LIST must match every other RM exactly -- same ports, same
//     order, same widths. A DFX partition is a physical boundary: the static
//     region is routed to it once, and every partial that lands there has to
//     fit what was routed. A mismatch is not a compile error, it is a partial
//     that does not belong to this socket. So these files are GENERATED from
//     rm_shell.sv's port list rather than maintained by hand.
//
//   * The MODULE NAME must differ from every other RM. Vivado identifies a
//     reconfigurable module by its top module, and two RMs sharing a name is
//     how a partial silently ends up in the wrong configuration.
//
// KERNEL_ID is what software reads at register 0x3C to find out what is
// actually in the socket, rather than inferring it from which partial it
// believes it downloaded. The registry is sw/rm_ref.py.
`timescale 1ns/10ps
module rm_blur
  #
  (
   parameter C_S_AXI_CONTROL_ADDR_WIDTH = 6,
   parameter C_S_AXI_CONTROL_DATA_WIDTH = 32,
   parameter C_M_AXI_GMEM_ADDR_WIDTH    = 64,
   parameter C_M_AXI_GMEM_DATA_WIDTH    = 32,
   parameter C_M_AXI_GMEM_ID_WIDTH      = 1,
   parameter MAX_WIDTH                  = 1920,
   parameter FIFO_DEPTH                 = 512
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

   // ---- to the static region's status GPIO ----
   output wire                                 heartbeat
   );

  localparam [31:0] KERNEL_ID = 32'hA5A50002;

  wire        core_start, core_done;
  wire [15:0] core_img_width, core_img_height;
  wire [31:0] core_mode;
  wire        core_s_valid, core_s_ready;
  wire [31:0] core_s_data;
  wire        core_m_valid, core_m_ready;
  wire [31:0] core_m_data;

  rm_shell
    #(.C_S_AXI_CONTROL_ADDR_WIDTH (C_S_AXI_CONTROL_ADDR_WIDTH),
      .C_S_AXI_CONTROL_DATA_WIDTH (C_S_AXI_CONTROL_DATA_WIDTH),
      .C_M_AXI_GMEM_ADDR_WIDTH    (C_M_AXI_GMEM_ADDR_WIDTH),
      .C_M_AXI_GMEM_DATA_WIDTH    (C_M_AXI_GMEM_DATA_WIDTH),
      .C_M_AXI_GMEM_ID_WIDTH      (C_M_AXI_GMEM_ID_WIDTH),
      .FIFO_DEPTH                 (FIFO_DEPTH),
      .KERNEL_ID                  (KERNEL_ID))
  u_shell
    (
     .ap_clk                    (ap_clk),
     .ap_rst_n                  (ap_rst_n),
     .interrupt                 (interrupt),
     .s_axi_control_awaddr      (s_axi_control_awaddr),
     .s_axi_control_awvalid     (s_axi_control_awvalid),
     .s_axi_control_awready     (s_axi_control_awready),
     .s_axi_control_wdata       (s_axi_control_wdata),
     .s_axi_control_wstrb       (s_axi_control_wstrb),
     .s_axi_control_wvalid      (s_axi_control_wvalid),
     .s_axi_control_wready      (s_axi_control_wready),
     .s_axi_control_bresp       (s_axi_control_bresp),
     .s_axi_control_bvalid      (s_axi_control_bvalid),
     .s_axi_control_bready      (s_axi_control_bready),
     .s_axi_control_araddr      (s_axi_control_araddr),
     .s_axi_control_arvalid     (s_axi_control_arvalid),
     .s_axi_control_arready     (s_axi_control_arready),
     .s_axi_control_rdata       (s_axi_control_rdata),
     .s_axi_control_rresp       (s_axi_control_rresp),
     .s_axi_control_rvalid      (s_axi_control_rvalid),
     .s_axi_control_rready      (s_axi_control_rready),
     .m_axi_gmem0_awid          (m_axi_gmem0_awid),
     .m_axi_gmem0_awaddr        (m_axi_gmem0_awaddr),
     .m_axi_gmem0_awlen         (m_axi_gmem0_awlen),
     .m_axi_gmem0_awsize        (m_axi_gmem0_awsize),
     .m_axi_gmem0_awburst       (m_axi_gmem0_awburst),
     .m_axi_gmem0_awlock        (m_axi_gmem0_awlock),
     .m_axi_gmem0_awcache       (m_axi_gmem0_awcache),
     .m_axi_gmem0_awprot        (m_axi_gmem0_awprot),
     .m_axi_gmem0_awqos         (m_axi_gmem0_awqos),
     .m_axi_gmem0_awvalid       (m_axi_gmem0_awvalid),
     .m_axi_gmem0_awready       (m_axi_gmem0_awready),
     .m_axi_gmem0_wdata         (m_axi_gmem0_wdata),
     .m_axi_gmem0_wstrb         (m_axi_gmem0_wstrb),
     .m_axi_gmem0_wlast         (m_axi_gmem0_wlast),
     .m_axi_gmem0_wvalid        (m_axi_gmem0_wvalid),
     .m_axi_gmem0_wready        (m_axi_gmem0_wready),
     .m_axi_gmem0_bid           (m_axi_gmem0_bid),
     .m_axi_gmem0_bresp         (m_axi_gmem0_bresp),
     .m_axi_gmem0_bvalid        (m_axi_gmem0_bvalid),
     .m_axi_gmem0_bready        (m_axi_gmem0_bready),
     .m_axi_gmem0_arid          (m_axi_gmem0_arid),
     .m_axi_gmem0_araddr        (m_axi_gmem0_araddr),
     .m_axi_gmem0_arlen         (m_axi_gmem0_arlen),
     .m_axi_gmem0_arsize        (m_axi_gmem0_arsize),
     .m_axi_gmem0_arburst       (m_axi_gmem0_arburst),
     .m_axi_gmem0_arlock        (m_axi_gmem0_arlock),
     .m_axi_gmem0_arcache       (m_axi_gmem0_arcache),
     .m_axi_gmem0_arprot        (m_axi_gmem0_arprot),
     .m_axi_gmem0_arqos         (m_axi_gmem0_arqos),
     .m_axi_gmem0_arvalid       (m_axi_gmem0_arvalid),
     .m_axi_gmem0_arready       (m_axi_gmem0_arready),
     .m_axi_gmem0_rid           (m_axi_gmem0_rid),
     .m_axi_gmem0_rdata         (m_axi_gmem0_rdata),
     .m_axi_gmem0_rresp         (m_axi_gmem0_rresp),
     .m_axi_gmem0_rlast         (m_axi_gmem0_rlast),
     .m_axi_gmem0_rvalid        (m_axi_gmem0_rvalid),
     .m_axi_gmem0_rready        (m_axi_gmem0_rready),
     .m_axi_gmem1_awid          (m_axi_gmem1_awid),
     .m_axi_gmem1_awaddr        (m_axi_gmem1_awaddr),
     .m_axi_gmem1_awlen         (m_axi_gmem1_awlen),
     .m_axi_gmem1_awsize        (m_axi_gmem1_awsize),
     .m_axi_gmem1_awburst       (m_axi_gmem1_awburst),
     .m_axi_gmem1_awlock        (m_axi_gmem1_awlock),
     .m_axi_gmem1_awcache       (m_axi_gmem1_awcache),
     .m_axi_gmem1_awprot        (m_axi_gmem1_awprot),
     .m_axi_gmem1_awqos         (m_axi_gmem1_awqos),
     .m_axi_gmem1_awvalid       (m_axi_gmem1_awvalid),
     .m_axi_gmem1_awready       (m_axi_gmem1_awready),
     .m_axi_gmem1_wdata         (m_axi_gmem1_wdata),
     .m_axi_gmem1_wstrb         (m_axi_gmem1_wstrb),
     .m_axi_gmem1_wlast         (m_axi_gmem1_wlast),
     .m_axi_gmem1_wvalid        (m_axi_gmem1_wvalid),
     .m_axi_gmem1_wready        (m_axi_gmem1_wready),
     .m_axi_gmem1_bid           (m_axi_gmem1_bid),
     .m_axi_gmem1_bresp         (m_axi_gmem1_bresp),
     .m_axi_gmem1_bvalid        (m_axi_gmem1_bvalid),
     .m_axi_gmem1_bready        (m_axi_gmem1_bready),
     .m_axi_gmem1_arid          (m_axi_gmem1_arid),
     .m_axi_gmem1_araddr        (m_axi_gmem1_araddr),
     .m_axi_gmem1_arlen         (m_axi_gmem1_arlen),
     .m_axi_gmem1_arsize        (m_axi_gmem1_arsize),
     .m_axi_gmem1_arburst       (m_axi_gmem1_arburst),
     .m_axi_gmem1_arlock        (m_axi_gmem1_arlock),
     .m_axi_gmem1_arcache       (m_axi_gmem1_arcache),
     .m_axi_gmem1_arprot        (m_axi_gmem1_arprot),
     .m_axi_gmem1_arqos         (m_axi_gmem1_arqos),
     .m_axi_gmem1_arvalid       (m_axi_gmem1_arvalid),
     .m_axi_gmem1_arready       (m_axi_gmem1_arready),
     .m_axi_gmem1_rid           (m_axi_gmem1_rid),
     .m_axi_gmem1_rdata         (m_axi_gmem1_rdata),
     .m_axi_gmem1_rresp         (m_axi_gmem1_rresp),
     .m_axi_gmem1_rlast         (m_axi_gmem1_rlast),
     .m_axi_gmem1_rvalid        (m_axi_gmem1_rvalid),
     .m_axi_gmem1_rready        (m_axi_gmem1_rready),
     .heartbeat                  (heartbeat),
     .core_start                 (core_start),
     .core_img_width             (core_img_width),
     .core_img_height            (core_img_height),
     .core_mode                  (core_mode),
     .core_done                  (core_done),
     .core_s_valid               (core_s_valid),
     .core_s_data                (core_s_data),
     .core_s_ready               (core_s_ready),
     .core_m_valid               (core_m_valid),
     .core_m_data                (core_m_data),
     .core_m_ready               (core_m_ready));

  rm_blur_core
    #(.MAX_WIDTH (MAX_WIDTH))
  u_core
    (.clk        (ap_clk),
     .rst_n      (ap_rst_n),
     .start      (core_start),
     .img_width  (core_img_width),
     .img_height (core_img_height),
     .mode       (core_mode),
     .done       (core_done),
     .s_valid    (core_s_valid),
     .s_data     (core_s_data),
     .s_ready    (core_s_ready),
     .m_valid    (core_m_valid),
     .m_data     (core_m_data),
     .m_ready    (core_m_ready));

endmodule
