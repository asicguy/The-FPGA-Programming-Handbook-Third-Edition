// ============================================================================
//  tb_capcheck.sv
//
//  Focused check of the DMA *capture* (S2MM) deserialization. The shipped
//  tb_aic3104.sv only proves the DMA loops bytes through DDR; it never checks
//  that the I2S deserializer turns the known sine input into clean samples.
//  This bench captures a few hundred frames into the AXI RAM model, then
//  decodes each 32-bit beat into L/R 16-bit samples and prints them so we can
//  see whether the result is a smooth sine or garbage (bit-misaligned static).
// ============================================================================
`timescale 1ns / 1ps
module tb_capcheck;
  parameter int AXI_ADDR_WIDTH = 40;
  parameter int AXI_DATA_WIDTH = 32;
  parameter int AXI_ID_WIDTH   = 6;

  localparam REG_RX_ADDR_LO = 12'h100;
  localparam REG_RX_ADDR_HI = 12'h104;
  localparam REG_RX_BYTES   = 12'h108;
  localparam REG_RX_START   = 12'h10c;
  localparam REG_RX_STAT    = 12'h114;

  localparam int NFRAMES = 240;             // frames (32-bit beats) to capture

  logic         s_axi_aclk = '0;
  logic         s_axi_aresetn;
  logic [21:0]  s_axi_awaddr;  logic s_axi_awvalid; wire s_axi_awready;
  logic [31:0]  s_axi_wdata;   logic [3:0] s_axi_wstrb = '1; logic s_axi_wvalid; wire s_axi_wready;
  wire  [1:0]   s_axi_bresp;   wire s_axi_bvalid;  logic s_axi_bready = '1;
  logic [21:0]  s_axi_araddr;  logic s_axi_arvalid; wire s_axi_arready;
  wire  [31:0]  s_axi_rdata;   wire [1:0] s_axi_rresp; wire s_axi_rvalid; logic s_axi_rready = '1;
  wire          interrupt_out;

  logic [AXI_ID_WIDTH-1:0]   m_axi_awid;   logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
  logic [7:0] m_axi_awlen;  logic [2:0] m_axi_awsize; logic [1:0] m_axi_awburst;
  logic m_axi_awlock; logic [3:0] m_axi_awcache; logic [2:0] m_axi_awprot;
  logic m_axi_awvalid; logic m_axi_awready;
  logic [AXI_DATA_WIDTH-1:0] m_axi_wdata; logic [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb;
  logic m_axi_wlast; logic m_axi_wvalid; logic m_axi_wready;
  logic [AXI_ID_WIDTH-1:0] m_axi_bid; logic [1:0] m_axi_bresp; logic m_axi_bvalid; logic m_axi_bready;
  logic [AXI_ID_WIDTH-1:0] m_axi_arid; logic [AXI_ADDR_WIDTH-1:0] m_axi_araddr;
  logic [7:0] m_axi_arlen; logic [2:0] m_axi_arsize; logic [1:0] m_axi_arburst;
  logic m_axi_arlock; logic [3:0] m_axi_arcache; logic [2:0] m_axi_arprot;
  logic m_axi_arvalid; logic m_axi_arready;
  logic [AXI_DATA_WIDTH-1:0] m_axi_rdata; logic [1:0] m_axi_rresp; logic m_axi_rlast;
  logic m_axi_rvalid; logic m_axi_rready;

  logic AIC_mclk_o = '0; wire AIC_lrclk_o; wire AIC_sclk_o; logic i2s_sdata_i; wire i2s_sdata_o;
  logic [31:0] test_reg; logic rst_n = '1;

  always AIC_mclk_o = #(83/2) ~AIC_mclk_o;
  always s_axi_aclk = #10 ~s_axi_aclk;

  initial begin
    s_axi_aresetn = '1; rst_n = '1;
    @(posedge AIC_mclk_o); rst_n = '0;
    repeat (100) @(posedge AIC_mclk_o); rst_n = '1;
    @(posedge s_axi_aclk); s_axi_aresetn = '0;
    repeat (100) @(posedge s_axi_aclk); s_axi_aresetn = '1;
    repeat (100) @(posedge s_axi_aclk);

    cpu_wr_reg(REG_RX_ADDR_LO, 32'h0);
    cpu_wr_reg(REG_RX_ADDR_HI, 32'h0);
    cpu_wr_reg(REG_RX_BYTES,   32'(NFRAMES*4));
    cpu_wr_reg(REG_RX_START,   32'h1);

    // wait for capture done (bit 31)
    do cpu_rd_reg(REG_RX_STAT); while (~test_reg[31]);
    $display("Capture complete. Decoding captured beats (word[31:16]=ch packed by HW):");
    $display(" idx |   raw32   |  hi(s16) |  lo(s16)");
    for (int i = 0; i < NFRAMES; i++) begin
      automatic logic [31:0] w  = axi_ram.mem[i];
      automatic shortint     hi = w[31:16];   // HW packs {rx_din[63:48], rx_din[31:16]}
      automatic shortint     lo = w[15:0];
      if (i < 80)
        $display(" %3d | %08h | %7d | %7d", i, w, hi, lo);
    end

    // crude sanity: report max absolute sample-to-sample delta on the lo channel
    begin
      automatic int maxd = 0;
      automatic shortint prev = axi_ram.mem[0][15:0];
      for (int i = 1; i < NFRAMES; i++) begin
        automatic shortint cur = axi_ram.mem[i][15:0];
        automatic int d = cur - prev; if (d < 0) d = -d;
        if (d > maxd) maxd = d;
        prev = cur;
      end
      $display("lo-channel max |delta| between consecutive samples = %0d", maxd);
      $display("(a clean ~1 kHz sine @48 kHz should step by only a few thousand; ");
      $display(" a value near 32768 means sign flips -> bit-misaligned static)");
    end
    $finish;
  end

  aic3104_dma u_dut (.*);

  axi_ram #(.DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(AXI_ADDR_WIDTH),
            .ID_WIDTH(AXI_ID_WIDTH), .RANDOM_READY(0))
  axi_ram (
     .clk(s_axi_aclk), .rst(~s_axi_aresetn),
     .s_axi_awid(m_axi_awid), .s_axi_awaddr(m_axi_awaddr), .s_axi_awlen(m_axi_awlen),
     .s_axi_awsize(m_axi_awsize), .s_axi_awburst(m_axi_awburst), .s_axi_awlock(m_axi_awlock),
     .s_axi_awcache(m_axi_awcache), .s_axi_awprot(m_axi_awprot), .s_axi_awvalid(m_axi_awvalid),
     .s_axi_awready(m_axi_awready), .s_axi_wdata(m_axi_wdata), .s_axi_wstrb(m_axi_wstrb),
     .s_axi_wlast(m_axi_wlast), .s_axi_wvalid(m_axi_wvalid), .s_axi_wready(m_axi_wready),
     .s_axi_bid(m_axi_bid), .s_axi_bresp(m_axi_bresp), .s_axi_bvalid(m_axi_bvalid),
     .s_axi_bready(m_axi_bready), .s_axi_arid(m_axi_arid), .s_axi_araddr(m_axi_araddr),
     .s_axi_arlen(m_axi_arlen), .s_axi_arsize(m_axi_arsize), .s_axi_arburst(m_axi_arburst),
     .s_axi_arlock(m_axi_arlock), .s_axi_arcache(m_axi_arcache), .s_axi_arprot(m_axi_arprot),
     .s_axi_arvalid(m_axi_arvalid), .s_axi_arready(m_axi_arready), .s_axi_rid(),
     .s_axi_rdata(m_axi_rdata), .s_axi_rresp(m_axi_rresp), .s_axi_rlast(m_axi_rlast),
     .s_axi_rvalid(m_axi_rvalid), .s_axi_rready(m_axi_rready));

  // Known stimulus: left-justified I2S sine source (same model the shipped tb uses).
  i2s_sine_gen #(.I2S_DELAY(1'b0)) src
    (.sclk(AIC_mclk_o), .rst_n(rst_n), .bclk(AIC_sclk_o), .lrclk(AIC_lrclk_o), .sdata(i2s_sdata_i));

  task automatic cpu_wr_reg(input [11:0] addr, input [31:0] din);
    begin
      s_axi_awvalid <= '1; s_axi_awaddr <= addr; s_axi_wvalid <= '1; s_axi_wdata <= din;
      @(posedge s_axi_aclk); while (!s_axi_awready) @(posedge s_axi_aclk);
      s_axi_awvalid <= '0; s_axi_wvalid <= '0;
    end
  endtask
  task automatic cpu_rd_reg(input [11:0] addr);
    begin
      s_axi_rready <= '0; s_axi_arvalid <= '1; s_axi_araddr <= addr;
      @(posedge s_axi_aclk); s_axi_arvalid <= '0; s_axi_rready <= '1;
      while (!s_axi_rvalid) @(posedge s_axi_aclk);
      s_axi_rready <= '0; test_reg = s_axi_rdata;
    end
  endtask
endmodule
