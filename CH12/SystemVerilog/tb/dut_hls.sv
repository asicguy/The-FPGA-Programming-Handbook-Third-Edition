// dut_hls.sv
// ------------------------------------
// Testbench wrapper for the Vitis HLS implementation
// ------------------------------------
// Author : Frank Bruno
//
// Same port list as tb/dut_rtl.sv, so the same testbench drives either. The
// whole reason this file exists is the case of the AXI signal names: Vitis HLS
// emits s_axi_control_AWVALID and m_axi_gmem0_ARADDR, the hand-written RTL uses
// lower case, and Verilog is case sensitive. The hardware is interchangeable;
// the identifiers are not.
//
// HLS also brings out ports the hand-written RTL does not have -- AWREGION,
// AWUSER, WID, WUSER, RUSER, BUSER -- because it generates the full AXI4 port
// set whether or not the design uses it. They are tied off here.
//
// `./sim.sh --hls` compiles this file instead of dut_rtl.sv. That stands in for
// C/RTL co-simulation, which is worth having as well but proves a different
// thing: cosim checks HLS against its own C, and this checks it against the
// same stimulus and the same golden model the other two implementations face.
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

     .s_axi_control_AWADDR  (s_axi_control_awaddr),
     .s_axi_control_AWVALID (s_axi_control_awvalid),
     .s_axi_control_AWREADY (s_axi_control_awready),
     .s_axi_control_WDATA   (s_axi_control_wdata),
     .s_axi_control_WSTRB   (s_axi_control_wstrb),
     .s_axi_control_WVALID  (s_axi_control_wvalid),
     .s_axi_control_WREADY  (s_axi_control_wready),
     .s_axi_control_BRESP   (s_axi_control_bresp),
     .s_axi_control_BVALID  (s_axi_control_bvalid),
     .s_axi_control_BREADY  (s_axi_control_bready),
     .s_axi_control_ARADDR  (s_axi_control_araddr),
     .s_axi_control_ARVALID (s_axi_control_arvalid),
     .s_axi_control_ARREADY (s_axi_control_arready),
     .s_axi_control_RDATA   (s_axi_control_rdata),
     .s_axi_control_RRESP   (s_axi_control_rresp),
     .s_axi_control_RVALID  (s_axi_control_rvalid),
     .s_axi_control_RREADY  (s_axi_control_rready),

     .m_axi_gmem0_AWVALID (), .m_axi_gmem0_AWREADY (1'b1),
     .m_axi_gmem0_AWADDR (), .m_axi_gmem0_AWID (), .m_axi_gmem0_AWLEN (),
     .m_axi_gmem0_AWSIZE (), .m_axi_gmem0_AWBURST (), .m_axi_gmem0_AWLOCK (),
     .m_axi_gmem0_AWCACHE (), .m_axi_gmem0_AWPROT (), .m_axi_gmem0_AWQOS (),
     .m_axi_gmem0_AWREGION (), .m_axi_gmem0_AWUSER (),
     .m_axi_gmem0_WVALID (), .m_axi_gmem0_WREADY (1'b1),
     .m_axi_gmem0_WDATA (), .m_axi_gmem0_WSTRB (), .m_axi_gmem0_WLAST (),
     .m_axi_gmem0_WID (), .m_axi_gmem0_WUSER (),
     .m_axi_gmem0_ARVALID (m_axi_gmem0_arvalid),
     .m_axi_gmem0_ARREADY (m_axi_gmem0_arready),
     .m_axi_gmem0_ARADDR  (m_axi_gmem0_araddr),
     .m_axi_gmem0_ARID (),
     .m_axi_gmem0_ARLEN   (m_axi_gmem0_arlen),
     .m_axi_gmem0_ARSIZE  (m_axi_gmem0_arsize),
     .m_axi_gmem0_ARBURST (m_axi_gmem0_arburst),
     .m_axi_gmem0_ARLOCK (), .m_axi_gmem0_ARCACHE (), .m_axi_gmem0_ARPROT (),
     .m_axi_gmem0_ARQOS (), .m_axi_gmem0_ARREGION (), .m_axi_gmem0_ARUSER (),
     .m_axi_gmem0_RVALID  (m_axi_gmem0_rvalid),
     .m_axi_gmem0_RREADY  (m_axi_gmem0_rready),
     .m_axi_gmem0_RDATA   (m_axi_gmem0_rdata),
     .m_axi_gmem0_RLAST   (m_axi_gmem0_rlast),
     .m_axi_gmem0_RID     (1'b0), .m_axi_gmem0_RUSER (1'b0),
     .m_axi_gmem0_RRESP   (m_axi_gmem0_rresp),
     .m_axi_gmem0_BVALID  (1'b0), .m_axi_gmem0_BREADY (),
     .m_axi_gmem0_BRESP   (2'b00), .m_axi_gmem0_BID (1'b0),
     .m_axi_gmem0_BUSER   (1'b0),

     .m_axi_gmem1_AWVALID (m_axi_gmem1_awvalid),
     .m_axi_gmem1_AWREADY (m_axi_gmem1_awready),
     .m_axi_gmem1_AWADDR  (m_axi_gmem1_awaddr),
     .m_axi_gmem1_AWID (),
     .m_axi_gmem1_AWLEN   (m_axi_gmem1_awlen),
     .m_axi_gmem1_AWSIZE  (m_axi_gmem1_awsize),
     .m_axi_gmem1_AWBURST (m_axi_gmem1_awburst),
     .m_axi_gmem1_AWLOCK (), .m_axi_gmem1_AWCACHE (), .m_axi_gmem1_AWPROT (),
     .m_axi_gmem1_AWQOS (), .m_axi_gmem1_AWREGION (), .m_axi_gmem1_AWUSER (),
     .m_axi_gmem1_WVALID  (m_axi_gmem1_wvalid),
     .m_axi_gmem1_WREADY  (m_axi_gmem1_wready),
     .m_axi_gmem1_WDATA   (m_axi_gmem1_wdata),
     .m_axi_gmem1_WSTRB   (m_axi_gmem1_wstrb),
     .m_axi_gmem1_WLAST   (m_axi_gmem1_wlast),
     .m_axi_gmem1_WID (), .m_axi_gmem1_WUSER (),
     .m_axi_gmem1_ARVALID (), .m_axi_gmem1_ARREADY (1'b1),
     .m_axi_gmem1_ARADDR (), .m_axi_gmem1_ARID (), .m_axi_gmem1_ARLEN (),
     .m_axi_gmem1_ARSIZE (), .m_axi_gmem1_ARBURST (), .m_axi_gmem1_ARLOCK (),
     .m_axi_gmem1_ARCACHE (), .m_axi_gmem1_ARPROT (), .m_axi_gmem1_ARQOS (),
     .m_axi_gmem1_ARREGION (), .m_axi_gmem1_ARUSER (),
     .m_axi_gmem1_RVALID  (1'b0), .m_axi_gmem1_RREADY (),
     .m_axi_gmem1_RDATA   (32'd0), .m_axi_gmem1_RLAST (1'b0),
     .m_axi_gmem1_RID     (1'b0), .m_axi_gmem1_RUSER (1'b0),
     .m_axi_gmem1_RRESP   (2'b00),
     .m_axi_gmem1_BVALID  (m_axi_gmem1_bvalid),
     .m_axi_gmem1_BREADY  (m_axi_gmem1_bready),
     .m_axi_gmem1_BRESP   (m_axi_gmem1_bresp),
     .m_axi_gmem1_BID     (1'b0), .m_axi_gmem1_BUSER (1'b0));

endmodule
