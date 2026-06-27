module tb_aic3104;
  parameter int AXI_ADDR_WIDTH = 40; // match the PS HP/HPC port width
  parameter int AXI_DATA_WIDTH = 32; // 32 = one packed L/R sample per beat
  parameter int AXI_ID_WIDTH = 6; // ZynqMP HP IDs are wider than ZC7000
  parameter int MAX_BURST_LEN = 16; // AMD recommends 16 on MPSoC HP ports
  parameter int FIFO_DEPTH = 1024;  // power of two recommended
  localparam            REG_TX_ADDR_LO    = 12'h0;
  localparam            REG_TX_ADDR_HI    = 12'h4;
  localparam            REG_TX_BYTES      = 12'h8;
  localparam            REG_TX_START      = 12'hc;
  localparam            REG_TX_BYTES_READ = 12'h10;
  localparam            REG_TX_STAT       = 12'h14;
  localparam            REG_RX_ADDR_LO    = 12'h100;
  localparam            REG_RX_ADDR_HI    = 12'h104;
  localparam            REG_RX_BYTES      = 12'h108;
  localparam            REG_RX_START      = 12'h10c;
  localparam            REG_RX_BYTES_READ = 12'h110;
  localparam            REG_RX_STAT       = 12'h114;
  localparam            REG_DEV           = 12'h200;
  localparam            REG_VER           = 12'h204;
  localparam            REG_INT           = 12'h208;

  logic         s_axi_aclk = '0;
  logic         s_axi_aresetn;
  logic [21:0]  s_axi_awaddr;
  logic         s_axi_awvalid;
  wire          s_axi_awready;
  logic [31:0]  s_axi_wdata;
  logic [3:0]   s_axi_wstrb = '1;
  logic         s_axi_wvalid;
  wire          s_axi_wready;
  wire [1:0]    s_axi_bresp;
  wire          s_axi_bvalid;
  logic         s_axi_bready = '1;
  logic [21:0]  s_axi_araddr;
  logic         s_axi_arvalid;
  wire          s_axi_arready;
  wire [31:0]   s_axi_rdata;
  wire [1:0]    s_axi_rresp;
  wire          s_axi_rvalid;
  logic         s_axi_rready = '1;
  wire          interrupt_out;
  logic [AXI_ID_WIDTH-1:0] m_axi_awid;
  logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
  logic [7:0]                m_axi_awlen;
  logic [2:0]                m_axi_awsize;
  logic [1:0]                m_axi_awburst;
  logic                      m_axi_awlock;
  logic [3:0]                m_axi_awcache;
  logic [2:0]                m_axi_awprot;
  logic                      m_axi_awvalid;
  logic                      m_axi_awready;
  logic [AXI_DATA_WIDTH-1:0] m_axi_wdata;
  logic [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb;
  logic                        m_axi_wlast;
  logic                        m_axi_wvalid;
  logic                        m_axi_wready;
  logic [AXI_ID_WIDTH-1:0]     m_axi_bid;
  logic [1:0]                  m_axi_bresp;
  logic                        m_axi_bvalid;
  logic                        m_axi_bready;

  logic         AIC_mclk_o = '0;
  wire          AIC_lrclk_o;
  wire          AIC_sclk_o;
  logic         i2s_sdata_i;
  wire          i2s_sdata_o;
  logic [31:0]  test_reg, read_data;
  logic         rst_n = '1;

  always AIC_mclk_o = #(83/2) ~AIC_mclk_o;
  always s_axi_aclk = #10 ~s_axi_aclk;

  initial begin
    rst_n = '1;
    s_axi_aresetn = '1;
    @(posedge AIC_mclk_o);
    rst_n = '0;
    repeat (100) @(posedge AIC_mclk_o);
    rst_n = '1;
    @(posedge s_axi_aclk);
    s_axi_aresetn = '0;
    repeat (100) @(posedge s_axi_aclk);
    s_axi_aresetn = '1;
    repeat (100) @(posedge s_axi_aclk);
    cpu_wr_reg(REG_RX_ADDR_LO, 32'h0);
    cpu_wr_reg(REG_RX_ADDR_HI, 32'h0);
    cpu_wr_reg(REG_RX_BYTES, 32'(128));
    cpu_wr_reg(REG_RX_START, 32'h1);
    repeat (10000) @(posedge AIC_mclk_o);
    repeat (100) @(posedge s_axi_aclk);
    do begin
      cpu_rd_reg(REG_RX_STAT);
    end while (~test_reg[31]);

    $stop;
  end

  aic3104_dma u_aic3104
    (
     .*
     );

  axi_ram
    #
    (
     // Width of data bus in bits
     .DATA_WIDTH (AXI_DATA_WIDTH),
     // Width of address bus in bits
     .ADDR_WIDTH (AXI_ADDR_WIDTH),
     // Width of ID signal
     .ID_WIDTH   (AXI_ID_WIDTH),
     .RANDOM_READY (0)
   )
  axi_ram
    (
     .clk (s_axi_aclk),
     .rst (~s_axi_aresetn),

     .s_axi_awid   (m_axi_awid),
     .s_axi_awaddr (m_axi_awaddr),
     .s_axi_awlen  (m_axi_awlen),
     .s_axi_awsize (m_axi_awsize),
     .s_axi_awburst(m_axi_awburst),
     .s_axi_awlock (m_axi_awlock),
     .s_axi_awcache(m_axi_awcache),
     .s_axi_awprot(m_axi_awprot),
     .s_axi_awvalid(m_axi_awvalid),
     .s_axi_awready(m_axi_awready),
     .s_axi_wdata(m_axi_wdata),
     .s_axi_wstrb(m_axi_wstrb),
     .s_axi_wlast(m_axi_wlast),
     .s_axi_wvalid(m_axi_wvalid),
     .s_axi_wready(m_axi_wready),
     .s_axi_bid(m_axi_bid),
     .s_axi_bresp(m_axi_bresp),
     .s_axi_bvalid(m_axi_bvalid),
     .s_axi_bready(m_axi_bready),
     .s_axi_arid(),
     .s_axi_araddr(),
     .s_axi_arlen(),
     .s_axi_arsize(),
     .s_axi_arburst(),
     .s_axi_arlock(),
     .s_axi_arcache(),
     .s_axi_arprot(),
     .s_axi_arvalid(),
     .s_axi_arready(),
     .s_axi_rid(),
     .s_axi_rdata(),
     .s_axi_rresp(),
     .s_axi_rlast(),
     .s_axi_rvalid(),
     .s_axi_rready()
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

  i2s_sine_gen
    #
    (
     .I2S_DELAY  (1'b0)
     )
  dut
    (
     .sclk       (AIC_mclk_o),
     .rst_n      (rst_n),
     .bclk       (AIC_sclk_o),
     .lrclk      (AIC_lrclk_o),
     .sdata      (i2s_sdata_i)
    );
endmodule // aic3204
