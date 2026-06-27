module aic3104_wrapper
  (
   input         s_axi_aclk,
   input         s_axi_aresetn,
   input [21:0]  s_axi_awaddr,
   input         s_axi_awvalid,
   output        s_axi_awready,
   input [31:0]  s_axi_wdata,
   input [3:0]   s_axi_wstrb,
   input         s_axi_wvalid,
   output        s_axi_wready,
   output [1:0]  s_axi_bresp,
   output        s_axi_bvalid,
   input         s_axi_bready,
   input [21:0]  s_axi_araddr,
   input         s_axi_arvalid,
   output        s_axi_arready,
   output [31:0] s_axi_rdata,
   output [1:0]  s_axi_rresp,
   output        s_axi_rvalid,
   input         s_axi_rready,
   output        interrupt_out,

   input         AIC_mclk_o,
   output        AIC_lrclk_o,
   output        AIC_sclk_o,
   input         i2s_sdata_i,
   output        i2s_sdata_o
   );

  aic3104 aic3104
    (
     .s_axi_aclk     (s_axi_aclk),
     .s_axi_aresetn  (s_axi_aresetn),
     .s_axi_awaddr   (s_axi_awaddr),
     .s_axi_awvalid  (s_axi_awvalid),
     .s_axi_awready  (s_axi_awready),
     .s_axi_wdata    (s_axi_wdata),
     .s_axi_wstrb    (s_axi_wstrb),
     .s_axi_wvalid   (s_axi_wvalid),
     .s_axi_wready   (s_axi_wready),
     .s_axi_bresp    (s_axi_bresp),
     .s_axi_bvalid   (s_axi_bvalid),
     .s_axi_bready   (s_axi_bready),
     .s_axi_araddr   (s_axi_araddr),
     .s_axi_arvalid  (s_axi_arvalid),
     .s_axi_arready  (s_axi_arready),
     .s_axi_rdata    (s_axi_rdata),
     .s_axi_rresp    (s_axi_rresp),
     .s_axi_rvalid   (s_axi_rvalid),
     .s_axi_rready   (s_axi_rready),
     .interrupt_out  (interrupt_out),

     .AIC_mclk_o     (AIC_mclk_o),
     .AIC_lrclk_o    (AIC_lrclk_o),
     .AIC_sclk_o     (AIC_sclk_o),
     .i2s_sdata_i    (i2s_sdata_i),
     .i2s_sdata_o    (i2s_sdata_o)
     );

endmodule // aic3104
