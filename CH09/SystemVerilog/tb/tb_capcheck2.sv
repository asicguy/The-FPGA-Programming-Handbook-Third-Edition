// ============================================================================
//  tb_capcheck2.sv
//
//  Like tb_capcheck, but drives i2s_sdata_i with an IDEAL left-justified source
//  (no synchronizer latency) carrying a KNOWN per-frame ramp that sweeps through
//  negative values. This isolates whether the captured-sign-bit loss is a real
//  deserializer bug or a timing artifact of the i2s_sine_gen model.
//
//  Left  sample for frame f = (f * 2531) as signed 16-bit (wraps -> goes negative)
//  Right sample for frame f = ~left
// ============================================================================
`timescale 1ns / 1ps
module tb_capcheck2;
  parameter int AXI_ADDR_WIDTH = 40, AXI_DATA_WIDTH = 32, AXI_ID_WIDTH = 6;
  localparam REG_RX_ADDR_LO=12'h100, REG_RX_ADDR_HI=12'h104, REG_RX_BYTES=12'h108,
             REG_RX_START=12'h10c, REG_RX_STAT=12'h114;
  localparam int NFRAMES = 64;

  logic s_axi_aclk='0, s_axi_aresetn;
  logic [21:0] s_axi_awaddr; logic s_axi_awvalid; wire s_axi_awready;
  logic [31:0] s_axi_wdata; logic [3:0] s_axi_wstrb='1; logic s_axi_wvalid; wire s_axi_wready;
  wire [1:0] s_axi_bresp; wire s_axi_bvalid; logic s_axi_bready='1;
  logic [21:0] s_axi_araddr; logic s_axi_arvalid; wire s_axi_arready;
  wire [31:0] s_axi_rdata; wire [1:0] s_axi_rresp; wire s_axi_rvalid; logic s_axi_rready='1;
  wire interrupt_out;
  logic [AXI_ID_WIDTH-1:0] m_axi_awid; logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
  logic [7:0] m_axi_awlen; logic [2:0] m_axi_awsize; logic [1:0] m_axi_awburst;
  logic m_axi_awlock; logic [3:0] m_axi_awcache; logic [2:0] m_axi_awprot; logic m_axi_awvalid, m_axi_awready;
  logic [AXI_DATA_WIDTH-1:0] m_axi_wdata; logic [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb;
  logic m_axi_wlast, m_axi_wvalid, m_axi_wready;
  logic [AXI_ID_WIDTH-1:0] m_axi_bid; logic [1:0] m_axi_bresp; logic m_axi_bvalid, m_axi_bready;
  logic [AXI_ID_WIDTH-1:0] m_axi_arid; logic [AXI_ADDR_WIDTH-1:0] m_axi_araddr;
  logic [7:0] m_axi_arlen; logic [2:0] m_axi_arsize; logic [1:0] m_axi_arburst;
  logic m_axi_arlock; logic [3:0] m_axi_arcache; logic [2:0] m_axi_arprot; logic m_axi_arvalid, m_axi_arready;
  logic [AXI_DATA_WIDTH-1:0] m_axi_rdata; logic [1:0] m_axi_rresp; logic m_axi_rlast, m_axi_rvalid, m_axi_rready;
  logic AIC_mclk_o='0; wire AIC_lrclk_o, AIC_sclk_o; logic i2s_sdata_i; wire i2s_sdata_o;
  logic [31:0] test_reg;

  always AIC_mclk_o = #(83/2) ~AIC_mclk_o;
  always s_axi_aclk = #10 ~s_axi_aclk;

  // ---- Ideal left-justified I2S source -----------------------------------
  // Drive a new bit on each BCLK falling edge; MSB coincides with the WS edge.
  shortint left_q[$], right_q[$];          // record what we send, per channel
  logic ws_prev; logic [4:0] bitcnt; logic [15:0] cur;
  int frame;
  function automatic shortint lsamp(int f); return shortint'(f*2531); endfunction
  initial begin ws_prev='0; bitcnt='0; cur='0; frame=0; i2s_sdata_i='0; end
  always @(negedge AIC_sclk_o) begin
    if (AIC_lrclk_o !== ws_prev) begin            // WS edge -> new channel word
      ws_prev <= AIC_lrclk_o;
      if (AIC_lrclk_o == 1'b0) begin              // WS low -> LEFT, new frame
        cur = lsamp(frame); left_q.push_back(cur);
      end else begin                              // WS high -> RIGHT
        cur = ~lsamp(frame); right_q.push_back(cur); frame = frame + 1;
      end
      bitcnt <= 5'd1;
      i2s_sdata_i <= cur[15];                      // MSB on the WS edge
    end else begin
      i2s_sdata_i <= (bitcnt <= 15) ? cur[15-bitcnt] : 1'b0;
      bitcnt <= bitcnt + 5'd1;
    end
  end

  initial begin
    s_axi_aresetn='1;
    @(posedge AIC_mclk_o);
    repeat (100) @(posedge AIC_mclk_o);
    @(posedge s_axi_aclk); s_axi_aresetn='0;
    repeat (100) @(posedge s_axi_aclk); s_axi_aresetn='1;
    repeat (200) @(posedge s_axi_aclk);
    cpu_wr_reg(REG_RX_ADDR_LO,0); cpu_wr_reg(REG_RX_ADDR_HI,0);
    cpu_wr_reg(REG_RX_BYTES,32'(NFRAMES*4)); cpu_wr_reg(REG_RX_START,1);
    do cpu_rd_reg(REG_RX_STAT); while (~test_reg[31]);

    $display("Captured vs sent (lo half = left channel). Aligning by first match...");
    $display(" beat |  cap_lo | matches a sent-left?");
    begin
      automatic int bad = 0;
      // Beat 0 is the start-up frame (capture armed mid-frame), so skip it.
      for (int i = 1; i < NFRAMES; i++) begin
        automatic shortint cap = axi_ram.mem[i][15:0];
        automatic bit found = 0;
        foreach (left_q[j]) if (left_q[j] === cap) found = 1;
        if (i < 24) $display(" %4d | %7d | %s", i, cap, found ? "yes" : "NO  <-- corrupted");
        if (!found) bad++;
      end
      $display("corrupted beats (excluding start-up beat 0): %0d / %0d", bad, NFRAMES-1);
      if (bad == 0) $display("RESULT: PASS -- capture is bit-exact (sign bit preserved)");
      else          $display("RESULT: FAIL -- capture corrupts samples");
    end
    $finish;
  end

  aic3104_dma u_dut (.*);
  axi_ram #(.DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(AXI_ADDR_WIDTH), .ID_WIDTH(AXI_ID_WIDTH), .RANDOM_READY(0))
  axi_ram (.clk(s_axi_aclk), .rst(~s_axi_aresetn),
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

  task automatic cpu_wr_reg(input [11:0] addr, input [31:0] din);
    begin s_axi_awvalid<='1; s_axi_awaddr<=addr; s_axi_wvalid<='1; s_axi_wdata<=din;
      @(posedge s_axi_aclk); while (!s_axi_awready) @(posedge s_axi_aclk);
      s_axi_awvalid<='0; s_axi_wvalid<='0; end
  endtask
  task automatic cpu_rd_reg(input [11:0] addr);
    begin s_axi_rready<='0; s_axi_arvalid<='1; s_axi_araddr<=addr;
      @(posedge s_axi_aclk); s_axi_arvalid<='0; s_axi_rready<='1;
      while (!s_axi_rvalid) @(posedge s_axi_aclk); s_axi_rready<='0; test_reg=s_axi_rdata; end
  endtask
endmodule
