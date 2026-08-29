// dut_rtl.sv
// ------------------------------------
// Testbench wrapper for the hand-written RTL (SystemVerilog or VHDL)
// ------------------------------------
// Author : Frank Bruno
//
// The testbench binds to `video_filter_dut`, never to an implementation
// directly, because the three implementations do not agree on port *names*.
// Vitis HLS spells its AXI signals in upper case -- s_axi_control_AWVALID,
// m_axi_gmem0_ARADDR -- and Verilog is case sensitive, so a testbench written
// against one will not elaborate against the other however identical the
// hardware is.
//
// One wrapper per implementation, one lower-case port list between them, and
// the testbench stops caring. This file is the trivial one: the hand-written
// RTL already uses the lower-case names, and the VHDL implementation is bound
// by the same wrapper because xsim maps VHDL entity ports case-insensitively.
`timescale 1ns/10ps
module video_filter_dut
  (
   input wire         ap_clk,
   input wire         ap_rst_n,
   output wire        interrupt,

   input wire [5:0]   s_axi_control_awaddr,
   input wire         s_axi_control_awvalid,
   output wire        s_axi_control_awready,
   input wire [31:0]  s_axi_control_wdata,
   input wire [3:0]   s_axi_control_wstrb,
   input wire         s_axi_control_wvalid,
   output wire        s_axi_control_wready,
   output wire [1:0]  s_axi_control_bresp,
   output wire        s_axi_control_bvalid,
   input wire         s_axi_control_bready,
   input wire [5:0]   s_axi_control_araddr,
   input wire         s_axi_control_arvalid,
   output wire        s_axi_control_arready,
   output wire [31:0] s_axi_control_rdata,
   output wire [1:0]  s_axi_control_rresp,
   output wire        s_axi_control_rvalid,
   input wire         s_axi_control_rready,

   output wire [63:0] m_axi_gmem0_araddr,
   output wire [7:0]  m_axi_gmem0_arlen,
   output wire [2:0]  m_axi_gmem0_arsize,
   output wire [1:0]  m_axi_gmem0_arburst,
   output wire        m_axi_gmem0_arvalid,
   input wire         m_axi_gmem0_arready,
   input wire [31:0]  m_axi_gmem0_rdata,
   input wire [1:0]   m_axi_gmem0_rresp,
   input wire         m_axi_gmem0_rlast,
   input wire         m_axi_gmem0_rvalid,
   output wire        m_axi_gmem0_rready,

   output wire [63:0] m_axi_gmem1_awaddr,
   output wire [7:0]  m_axi_gmem1_awlen,
   output wire [2:0]  m_axi_gmem1_awsize,
   output wire [1:0]  m_axi_gmem1_awburst,
   output wire        m_axi_gmem1_awvalid,
   input wire         m_axi_gmem1_awready,
   output wire [31:0] m_axi_gmem1_wdata,
   output wire [3:0]  m_axi_gmem1_wstrb,
   output wire        m_axi_gmem1_wlast,
   output wire        m_axi_gmem1_wvalid,
   input wire         m_axi_gmem1_wready,
   input wire [1:0]   m_axi_gmem1_bresp,
   input wire         m_axi_gmem1_bvalid,
   output wire        m_axi_gmem1_bready
   );

  video_filter u_dut
    (.ap_clk (ap_clk), .ap_rst_n (ap_rst_n), .interrupt (interrupt),

     .s_axi_control_awaddr  (s_axi_control_awaddr),
     .s_axi_control_awvalid (s_axi_control_awvalid),
     .s_axi_control_awready (s_axi_control_awready),
     .s_axi_control_wdata   (s_axi_control_wdata),
     .s_axi_control_wstrb   (s_axi_control_wstrb),
     .s_axi_control_wvalid  (s_axi_control_wvalid),
     .s_axi_control_wready  (s_axi_control_wready),
     .s_axi_control_bresp   (s_axi_control_bresp),
     .s_axi_control_bvalid  (s_axi_control_bvalid),
     .s_axi_control_bready  (s_axi_control_bready),
     .s_axi_control_araddr  (s_axi_control_araddr),
     .s_axi_control_arvalid (s_axi_control_arvalid),
     .s_axi_control_arready (s_axi_control_arready),
     .s_axi_control_rdata   (s_axi_control_rdata),
     .s_axi_control_rresp   (s_axi_control_rresp),
     .s_axi_control_rvalid  (s_axi_control_rvalid),
     .s_axi_control_rready  (s_axi_control_rready),

     .m_axi_gmem0_awid (), .m_axi_gmem0_awaddr (), .m_axi_gmem0_awlen (),
     .m_axi_gmem0_awsize (), .m_axi_gmem0_awburst (), .m_axi_gmem0_awlock (),
     .m_axi_gmem0_awcache (), .m_axi_gmem0_awprot (), .m_axi_gmem0_awqos (),
     .m_axi_gmem0_awvalid (), .m_axi_gmem0_awready (1'b1),
     .m_axi_gmem0_wdata (), .m_axi_gmem0_wstrb (), .m_axi_gmem0_wlast (),
     .m_axi_gmem0_wvalid (), .m_axi_gmem0_wready (1'b1),
     .m_axi_gmem0_bid (1'b0), .m_axi_gmem0_bresp (2'b00),
     .m_axi_gmem0_bvalid (1'b0), .m_axi_gmem0_bready (),
     .m_axi_gmem0_arid (),
     .m_axi_gmem0_araddr  (m_axi_gmem0_araddr),
     .m_axi_gmem0_arlen   (m_axi_gmem0_arlen),
     .m_axi_gmem0_arsize  (m_axi_gmem0_arsize),
     .m_axi_gmem0_arburst (m_axi_gmem0_arburst),
     .m_axi_gmem0_arlock (), .m_axi_gmem0_arcache (), .m_axi_gmem0_arprot (),
     .m_axi_gmem0_arqos (),
     .m_axi_gmem0_arvalid (m_axi_gmem0_arvalid),
     .m_axi_gmem0_arready (m_axi_gmem0_arready),
     .m_axi_gmem0_rid     (1'b0),
     .m_axi_gmem0_rdata   (m_axi_gmem0_rdata),
     .m_axi_gmem0_rresp   (m_axi_gmem0_rresp),
     .m_axi_gmem0_rlast   (m_axi_gmem0_rlast),
     .m_axi_gmem0_rvalid  (m_axi_gmem0_rvalid),
     .m_axi_gmem0_rready  (m_axi_gmem0_rready),

     .m_axi_gmem1_awid (),
     .m_axi_gmem1_awaddr  (m_axi_gmem1_awaddr),
     .m_axi_gmem1_awlen   (m_axi_gmem1_awlen),
     .m_axi_gmem1_awsize  (m_axi_gmem1_awsize),
     .m_axi_gmem1_awburst (m_axi_gmem1_awburst),
     .m_axi_gmem1_awlock (), .m_axi_gmem1_awcache (), .m_axi_gmem1_awprot (),
     .m_axi_gmem1_awqos (),
     .m_axi_gmem1_awvalid (m_axi_gmem1_awvalid),
     .m_axi_gmem1_awready (m_axi_gmem1_awready),
     .m_axi_gmem1_wdata   (m_axi_gmem1_wdata),
     .m_axi_gmem1_wstrb   (m_axi_gmem1_wstrb),
     .m_axi_gmem1_wlast   (m_axi_gmem1_wlast),
     .m_axi_gmem1_wvalid  (m_axi_gmem1_wvalid),
     .m_axi_gmem1_wready  (m_axi_gmem1_wready),
     .m_axi_gmem1_bid     (1'b0),
     .m_axi_gmem1_bresp   (m_axi_gmem1_bresp),
     .m_axi_gmem1_bvalid  (m_axi_gmem1_bvalid),
     .m_axi_gmem1_bready  (m_axi_gmem1_bready),
     .m_axi_gmem1_arid (), .m_axi_gmem1_araddr (), .m_axi_gmem1_arlen (),
     .m_axi_gmem1_arsize (), .m_axi_gmem1_arburst (), .m_axi_gmem1_arlock (),
     .m_axi_gmem1_arcache (), .m_axi_gmem1_arprot (), .m_axi_gmem1_arqos (),
     .m_axi_gmem1_arvalid (), .m_axi_gmem1_arready (1'b1),
     .m_axi_gmem1_rid (1'b0), .m_axi_gmem1_rdata (32'd0),
     .m_axi_gmem1_rresp (2'b00), .m_axi_gmem1_rlast (1'b0),
     .m_axi_gmem1_rvalid (1'b0), .m_axi_gmem1_rready ());

endmodule
