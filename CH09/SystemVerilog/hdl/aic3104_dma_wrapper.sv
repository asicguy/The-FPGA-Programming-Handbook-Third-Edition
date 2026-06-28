module aic3104_dma_wrapper
  #
  (
   parameter int AXI_ADDR_WIDTH = 40, // match the PS HP/HPC port width
   parameter int AXI_DATA_WIDTH = 32, // 32 = one packed L/R sample per beat
   parameter int AXI_ID_WIDTH = 6, // ZynqMP HP IDs are wider than ZC7000
   parameter int MAX_BURST_LEN = 16, // AMD recommends 16 on MPSoC HP ports
   parameter int FIFO_DEPTH = 1024  // power of two recommended
   )
  (
   // AXI lite interface for register acceess
   input                         s_axi_aclk,
   input                         s_axi_aresetn,
   input [21:0]                  s_axi_awaddr,
   input                         s_axi_awvalid,
   output                        s_axi_awready,
   input [31:0]                  s_axi_wdata,
   input [3:0]                   s_axi_wstrb,
   input                         s_axi_wvalid,
   output                        s_axi_wready,
   output [1:0]                  s_axi_bresp,
   output                        s_axi_bvalid,
   input                         s_axi_bready,
   input [21:0]                  s_axi_araddr,
   input                         s_axi_arvalid,
   output                        s_axi_arready,
   output [31:0]                 s_axi_rdata,
   output [1:0]                  s_axi_rresp,
   output                        s_axi_rvalid,
   input                         s_axi_rready,

   // AXI Memory Master Write interface for Audio capture
   output [AXI_ID_WIDTH-1:0]     m_axi_awid,
   output [AXI_ADDR_WIDTH-1:0]   m_axi_awaddr,
   output [7:0]                  m_axi_awlen,
   output [2:0]                  m_axi_awsize,
   output [1:0]                  m_axi_awburst,
   output                        m_axi_awlock,
   output [3:0]                  m_axi_awcache,
   output [2:0]                  m_axi_awprot,
   output                        m_axi_awvalid,
   input                         m_axi_awready,

    // ---- AXI4 master: write data channel ----
   output [AXI_DATA_WIDTH-1:0]   m_axi_wdata,
   output [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
   output                        m_axi_wlast,
   output                        m_axi_wvalid,
   input                         m_axi_wready,

    // ---- AXI4 master: write response channel ----
   input [AXI_ID_WIDTH-1:0]      m_axi_bid,
   input [1:0]                   m_axi_bresp,
   input                         m_axi_bvalid,
   output                        m_axi_bready,

    // ---- AXI4 master: read address channel (playback / MM2S) ----
   output [AXI_ID_WIDTH-1:0]     m_axi_arid,
   output [AXI_ADDR_WIDTH-1:0]   m_axi_araddr,
   output [7:0]                  m_axi_arlen,
   output [2:0]                  m_axi_arsize,
   output [1:0]                  m_axi_arburst,
   output                        m_axi_arlock,
   output [3:0]                  m_axi_arcache,
   output [2:0]                  m_axi_arprot,
   output                        m_axi_arvalid,
   input                         m_axi_arready,

    // ---- AXI4 master: read data channel ----
   input [AXI_DATA_WIDTH-1:0]    m_axi_rdata,
   input [1:0]                   m_axi_rresp,
   input                         m_axi_rlast,
   input                         m_axi_rvalid,
   output                        m_axi_rready,

   output                        interrupt_out,

   input                         AIC_mclk_o,
   (* mark_debug = "true" *)output AIC_lrclk_o,
   (* mark_debug = "true" *)output AIC_sclk_o,
   (* mark_debug = "true" *)input i2s_sdata_i,
   (* mark_debug = "true" *)output i2s_sdata_o
   );

  aic3104_dma
    #
    (
     .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH), // match the PS HP/HPC port width
     .AXI_DATA_WIDTH (AXI_DATA_WIDTH), // 32 = one packed L/R sample per beat
     .AXI_ID_WIDTH (AXI_ID_WIDTH), // ZynqMP HP IDs are wider than ZC7000
     .MAX_BURST_LEN (MAX_BURST_LEN), // AMD recommends 16 on MPSoC HP ports
     .FIFO_DEPTH (FIFO_DEPTH)  // power of two recommended
     )
  aic3104_dma
    (
     // AXI lite interface for register acceess
   .s_axi_aclk(s_axi_aclk),
   .s_axi_aresetn(s_axi_aresetn),
   .s_axi_awaddr(s_axi_awaddr),
   .s_axi_awvalid(s_axi_awvalid),
   .s_axi_awready(s_axi_awready),
   .s_axi_wdata(s_axi_wdata),
   .s_axi_wstrb(s_axi_wstrb),
   .s_axi_wvalid(s_axi_wvalid),
   .s_axi_wready(s_axi_wready),
   .s_axi_bresp(s_axi_bresp),
   .s_axi_bvalid(s_axi_bvalid),
   .s_axi_bready(s_axi_bready),
   .s_axi_araddr(s_axi_araddr),
   .s_axi_arvalid(s_axi_arvalid),
   .s_axi_arready(s_axi_arready),
   .s_axi_rdata(s_axi_rdata),
   .s_axi_rresp(s_axi_rresp),
   .s_axi_rvalid(s_axi_rvalid),
   .s_axi_rready(s_axi_rready),

   // AXI Memory Master Write interface for Audio capture
   .m_axi_awid(m_axi_awid),
   .m_axi_awaddr(m_axi_awaddr),
   .m_axi_awlen(m_axi_awlen),
   .m_axi_awsize(m_axi_awsize),
   .m_axi_awburst(m_axi_awburst),
   .m_axi_awlock(m_axi_awlock),
   .m_axi_awcache(m_axi_awcache),
   .m_axi_awprot(m_axi_awprot),
   .m_axi_awvalid(m_axi_awvalid),
   .m_axi_awready(m_axi_awready),

    // ---- AXI4 master: write data channel ----
   .m_axi_wdata(m_axi_wdata),
   .m_axi_wstrb(m_axi_wstrb),
   .m_axi_wlast(m_axi_wlast),
   .m_axi_wvalid(m_axi_wvalid),
   .m_axi_wready(m_axi_wready),

    // ---- AXI4 master: write response channel ----
  .m_axi_bid(m_axi_bid),
   .m_axi_bresp(m_axi_bresp),
   .m_axi_bvalid(m_axi_bvalid),
   .m_axi_bready(m_axi_bready),

    // ---- AXI4 master: read address channel (playback / MM2S) ----
   .m_axi_arid(m_axi_arid),
   .m_axi_araddr(m_axi_araddr),
   .m_axi_arlen(m_axi_arlen),
   .m_axi_arsize(m_axi_arsize),
   .m_axi_arburst(m_axi_arburst),
   .m_axi_arlock(m_axi_arlock),
   .m_axi_arcache(m_axi_arcache),
   .m_axi_arprot(m_axi_arprot),
   .m_axi_arvalid(m_axi_arvalid),
   .m_axi_arready(m_axi_arready),

    // ---- AXI4 master: read data channel ----
   .m_axi_rdata(m_axi_rdata),
   .m_axi_rresp(m_axi_rresp),
   .m_axi_rlast(m_axi_rlast),
   .m_axi_rvalid(m_axi_rvalid),
   .m_axi_rready(m_axi_rready),

   .interrupt_out(interrupt_out),

   .AIC_mclk_o(AIC_mclk_o),
     .AIC_lrclk_o(AIC_lrclk_o),
    .AIC_sclk_o(AIC_sclk_o),
   .i2s_sdata_i(i2s_sdata_i),
    .i2s_sdata_o(i2s_sdata_o)
   );
endmodule // aic3204
