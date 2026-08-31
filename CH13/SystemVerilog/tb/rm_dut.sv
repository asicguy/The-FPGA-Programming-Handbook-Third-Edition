// rm_dut.sv
// ------------------------------------
// Testbench wrapper: binds one reconfigurable module under a fixed name
// ------------------------------------
// Author : Frank Bruno
//
// tb_rm.sv binds to `rm_dut`, never to an RM directly, so ONE testbench checks
// every RM against the golden model. Which RM is inside is chosen at
// elaboration:
//
//     ./sim.sh --rm blur        ->  -d RM_BLUR
//
// This is CH12's dut_rtl.sv pattern with two differences: the choice is a
// define rather than a separate file per implementation, and `heartbeat` comes
// out, because in CH13 it is part of the socket contract.
//
// The RMs' unused master signals are tied off here rather than in the
// testbench. They have to EXIST on the RM -- Vivado's ipx::infer_bus_interfaces
// recognises m_axi_gmem0/1 as AXI4 masters by matching the complete port set,
// and half a channel means a packaged IP with no bus interface at all -- but
// the testbench has no use for a write channel on the read master.
`timescale 1ns/10ps
module rm_dut
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
   output wire        m_axi_gmem1_bready,

   // Part of the socket contract in CH13: a free-running toggle the static
   // region watches to answer "is the partition clocked and out of reset?"
   // without touching the AXI4-Lite slave. See hdl/socket_ctrl.sv.
   output wire        heartbeat
   );

`ifdef RM_PASSTHROUGH
  rm_passthrough
`elsif RM_SOBEL
  rm_sobel
`elsif RM_BLUR
  rm_blur
`elsif RM_THRESHOLD
  rm_threshold
`else
  // Deliberately no default. A testbench that silently picks an RM when the
  // build forgot to say which one is a testbench that reports a pass for the
  // wrong hardware.
  $error("define one of RM_PASSTHROUGH / RM_SOBEL / RM_BLUR / RM_THRESHOLD");
`endif
  u_dut
    (.ap_clk (ap_clk), .ap_rst_n (ap_rst_n), .interrupt (interrupt),
     .heartbeat (heartbeat),

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
