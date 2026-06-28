// tb_aic3104_poll.sv
// ---------------------------------------------------------------------------
//  Self-checking testbench for aic3104_poll.
//
//  A small "loopback codec" model captures the DUT's I2S serial output (TX) and
//  echoes it back onto the serial input (RX) with the correct half-bit timing.
//  So a CPU-written TX sample is serialized out, looped through the codec, and
//  read back via REG_RX_DATA -- exercising both TX and RX datapaths and proving
//  the 32-bit slot framing is self-consistent.
// ---------------------------------------------------------------------------
`timescale 1ns/10ps

module tb_aic3104_poll;
  localparam REG_TX_DATA = 12'h008;
  localparam REG_TX_STAT = 12'h00C;
  localparam REG_RX_CTRL = 12'h110;
  localparam REG_RX_DATA = 12'h118;
  localparam REG_RX_STAT = 12'h11C;
  localparam REG_DEV     = 12'h200;
  localparam REG_VER     = 12'h204;

  logic        s_axi_aclk = '0;
  logic        s_axi_aresetn = '1;
  logic [21:0] s_axi_awaddr = '0;
  logic        s_axi_awvalid = '0;
  wire         s_axi_awready;
  logic [31:0] s_axi_wdata = '0;
  logic [3:0]  s_axi_wstrb = '1;
  logic        s_axi_wvalid = '0;
  wire         s_axi_wready;
  wire [1:0]   s_axi_bresp;
  wire         s_axi_bvalid;
  logic        s_axi_bready = '1;
  logic [21:0] s_axi_araddr = '0;
  logic        s_axi_arvalid = '0;
  wire         s_axi_arready;
  wire [31:0]  s_axi_rdata;
  wire [1:0]   s_axi_rresp;
  wire         s_axi_rvalid;
  logic        s_axi_rready = '0;
  wire         interrupt_out;

  logic        AIC_mclk_o = '0;
  wire         AIC_lrclk_o, AIC_sclk_o;
  logic        i2s_sdata_i = '0;
  wire         i2s_sdata_o;

  logic [31:0] test_reg;
  int          errs = 0;

  always s_axi_aclk = #10 ~s_axi_aclk;
  always AIC_mclk_o = #(83/2) ~AIC_mclk_o;

  aic3104_poll dut (.*);

  // ---- loopback codec model (lockstep counter with the DUT) ----
  function automatic int idxf(input logic [7:0] x);
    return (x[7] ? 32 : 0) + (31 - x[6:2]);
  endfunction

  logic [7:0]  tb_counter = '0;
  logic [63:0] cap_word   = '0;
  always @(posedge AIC_mclk_o) begin
    tb_counter <= tb_counter + 1;
    if (tb_counter[1:0] == 2'b00) begin
      cap_word[idxf(tb_counter - 8'd2)] <= i2s_sdata_o;     // capture TX
      i2s_sdata_i <= cap_word[idxf(tb_counter + 8'd2)];     // echo to RX
    end
  end

  task automatic cpu_wr_reg(input [11:0] addr, input [31:0] data);
    s_axi_awvalid <= '1; s_axi_awaddr <= 22'(addr);
    s_axi_wvalid  <= '1; s_axi_wdata  <= data;
    @(posedge s_axi_aclk);
    while (!s_axi_awready) @(posedge s_axi_aclk);
    s_axi_awvalid <= '0; s_axi_wvalid <= '0;
  endtask

  task automatic cpu_rd_reg(input [11:0] addr);
    s_axi_rready  <= '0;
    s_axi_arvalid <= '1; s_axi_araddr <= 22'(addr);
    @(posedge s_axi_aclk);
    s_axi_arvalid <= '0; s_axi_rready <= '1;
    do @(posedge s_axi_aclk); while (!s_axi_rvalid);
    s_axi_rready <= '0;
    test_reg = s_axi_rdata;
  endtask

  task automatic wait_frames(input int n);
    repeat (n * 256) @(posedge AIC_mclk_o);
  endtask

  task automatic get_rx;
    do cpu_rd_reg(REG_RX_STAT); while (test_reg[0]);  // wait !empty
    cpu_rd_reg(REG_RX_DATA);
  endtask

  task automatic drain_rx;
    forever begin
      cpu_rd_reg(REG_RX_STAT);
      if (test_reg[0]) break;                          // empty
      cpu_rd_reg(REG_RX_DATA);
    end
  endtask

  task automatic run_loopback(input [31:0] sample, input string tag);
    cpu_wr_reg(REG_RX_CTRL, 32'h1);                    // enable RX
    repeat (120) cpu_wr_reg(REG_TX_DATA, sample);      // fill TX FIFO
    wait_frames(30);
    drain_rx;                                           // flush transitional frames
    wait_frames(4);
    for (int i = 0; i < 4; i++) begin
      get_rx;
      if (test_reg !== sample) begin
        $error("%s: RX readback %0d = %h, expected %h", tag, i, test_reg, sample);
        errs++;
      end
    end
    cpu_wr_reg(REG_RX_CTRL, 32'h0);                    // disable RX
    drain_rx;
    wait_frames(130);                                   // let TX FIFO drain
    if (errs == 0) $display("%s loopback PASSED: %h round-tripped TX->RX", tag, sample);
  endtask

  initial begin
    s_axi_aresetn <= '1;
    @(posedge s_axi_aclk);
    s_axi_aresetn <= '0;
    repeat (100) @(posedge s_axi_aclk);
    s_axi_aresetn <= '1;
    repeat (100) @(posedge s_axi_aclk);

    cpu_rd_reg(REG_DEV);
    if (test_reg !== "3104") begin $error("REG_DEV != 3104"); errs++; end
    cpu_rd_reg(REG_VER);
    if (test_reg !== 32'd1) begin $error("REG_VER != 1"); errs++; end

    run_loopback(32'h1234_5678, "Pass 1 (TX+RX)");
    run_loopback(32'hABCD_4321, "Pass 2 (TX+RX)");

    if (errs == 0) $display("==== ALL TESTS PASSED ====");
    else           $display("==== TESTS FAILED: %0d error(s) ====", errs);
    $finish;
  end

  initial begin
    #20ms;
    $error("TIMEOUT: testbench did not finish");
    $finish;
  end
endmodule
