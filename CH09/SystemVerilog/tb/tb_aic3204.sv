module tb_aic3204;

  logic         s_axi_aclk = '0;
  logic         s_axi_aresetn;
  logic [21:0]  s_axi_awaddr;
  logic         s_axi_awvalid;
  logic         s_axi_awready = '0;
  logic [31:0]  s_axi_wdata;
  logic [3:0]   s_axi_wstrb = '1;
  logic         s_axi_wvalid;
  logic         s_axi_wready;
  logic [1:0]   s_axi_bresp;
  logic         s_axi_bvalid = '0;
  logic         s_axi_bready = '1;
  logic [21:0]  s_axi_araddr;
  logic         s_axi_arvalid;
  logic         s_axi_arready = '0;
  logic [31:0]  s_axi_rdata;
  logic [1:0]   s_axi_rresp = '0;
  logic         s_axi_rvalid = '0;
  logic         s_axi_rready;
  logic         interrupt_out;

  logic         AIC_mclk_o = '0;
  logic         AIC_lrclk_o;
  logic         AIC_sclk_o;
  logic         i2s_sdata_i;
  logic         i2s_sdata_o;
  logic [31:0]  test_reg, read_data;

  always AIC_mclk_o = #10 ~AIC_mclk_o;

  aic3204 u_aic3204
    (
     .*
     );

    // Write a register in the design
  task automatic cpu_wr_reg;
    input [11:0] addr;
    input [31:0] din;

    begin
      s_axi_awvalid  <= '1;
      s_axi_awaddr   <= addr;
      s_axi_wvalid   <= '1;
      s_axi_wdata    <= din;
      @(posedge s_axi_aclk);
      while (!s_axi_awready) @(posedge s_axi_aclk);
      // Cheating since we know our device will set both readies together
      s_axi_awvalid  <= '0;
      s_axi_wvalid   <= '0;
    end
  endtask // cpu_wr

  // Simple task to read a register. Data is stored in test_reg
  task automatic cpu_rd_reg;
    input [11:0] addr;
    begin
      s_axi_rready  <= '0;
      s_axi_arvalid <= '1;
      s_axi_araddr  <= addr;
      @(posedge s_axi_aclk);
      s_axi_arvalid  <= '0;
      s_axi_rready   <= '1;
      while (!s_axi_rvalid) @(posedge s_axi_aclk);
      s_axi_rready <= '0;
      //@(posedge s_axi_aclk);
      test_reg     = s_axi_rdata;
      $display("RD: REG %h: %h", addr, s_axi_rdata);
    end
  endtask // cpu_rd_reg

  task automatic cpu_rd_reg_verify;
    input [11:0] addr;
    input [31:0] exp_data;
    begin
      s_axi_rready  <= '0;
      s_axi_arvalid <= '1;
      s_axi_araddr  <= addr;
      @(posedge s_axi_aclk);
      s_axi_arvalid  <= '0;
      s_axi_rready   <= '1;
      while (!s_axi_rvalid) @(posedge s_axi_aclk);
      s_axi_rready  <= '0;
      //@(posedge s_axi_aclk);
      test_reg      = s_axi_rdata;
      if (test_reg != exp_data) begin
        $display("Comparison failed %h != %h", test_reg, exp_data);
        $stop;
      end
    end
  endtask // cpu_rd_reg

endmodule // aic3204
