// tb_socket_ctrl.sv
// ------------------------------------
// A deliberately hostile AXI4-Lite master against the DFX socket's control
// block
// ------------------------------------
// Author : Frank Bruno
//
// This testbench exists before any reconfigurable module does, and that order
// is the point. The CH13 spike wedged the board four times; three of those
// were an AXI4-Lite slave or a driver with no testbench behind it, and one of
// them -- a slave that only completed a write when AW and W arrived in the
// SAME cycle -- hung the PS forever, because the PS routinely sends the
// address a cycle or more ahead of the data. On ZynqMP a PL slave that never
// responds is not an error: there is no bus timeout on the PL ports, so the
// CPU stops with no panic and no console output, and the only way out is a
// power cycle.
//
// So this master does the things a real one does and a lazy testbench does
// not:
//
//   * every AW/W skew from -8 to +8 cycles, address first AND data first
//   * bready and rready delayed independently, so the slave must hold bvalid
//     and rvalid, and must hold rdata stable, until the master is ready
//   * back-to-back transactions with no idle cycles, to catch a slave that
//     needs recovery time between them
//   * writes to a read-only register, which must be ignored rather than
//     corrupt a neighbour
//
// Run the negative control before believing any of it:
//
//   ./sim.sh --socket --negative     must FAIL
//   ./sim.sh --socket                must PASS
//
// The negative control is `socket_ctrl_broken`, which is the spike's bug
// preserved deliberately: it is correct except that it requires AW and W in
// the same cycle. A testbench that passes against that is not testing
// anything, and the only way to know is to run it.
`timescale 1ns/10ps
module tb_socket_ctrl;

  localparam int AW_BITS = 6;
  localparam int DW      = 32;

  // Must match hdl/socket_ctrl.sv.
  localparam [AW_BITS-1:0] ADDR_CTRL   = 6'h00;
  localparam [AW_BITS-1:0] ADDR_GIER   = 6'h04;
  localparam [AW_BITS-1:0] ADDR_IER    = 6'h08;
  localparam [AW_BITS-1:0] ADDR_ISR    = 6'h0C;
  localparam [AW_BITS-1:0] ADDR_SRC_LO = 6'h10;
  localparam [AW_BITS-1:0] ADDR_SRC_HI = 6'h14;
  localparam [AW_BITS-1:0] ADDR_DST_LO = 6'h1C;
  localparam [AW_BITS-1:0] ADDR_DST_HI = 6'h20;
  localparam [AW_BITS-1:0] ADDR_WIDTH_ = 6'h28;
  localparam [AW_BITS-1:0] ADDR_HEIGHT = 6'h30;
  localparam [AW_BITS-1:0] ADDR_MODE   = 6'h38;
  localparam [AW_BITS-1:0] ADDR_KERNEL = 6'h3C;

  // The identity this socket reports. Every RM has its own; the testbench
  // builds against one so it can check the value is actually wired out.
  localparam [31:0] KERNEL_ID = 32'hA5A5_0001;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #2.5 clk = ~clk;              // 200 MHz, a round number for 5 ns

  // ---- AXI4-Lite ----
  logic [AW_BITS-1:0] awaddr;
  logic               awvalid;
  logic               awready;
  logic [DW-1:0]      wdata;
  logic [DW/8-1:0]    wstrb;
  logic               wvalid;
  logic               wready;
  logic [1:0]         bresp;
  logic               bvalid;
  logic               bready;
  logic [AW_BITS-1:0] araddr;
  logic               arvalid;
  logic               arready;
  logic [DW-1:0]      rdata;
  logic [1:0]         rresp;
  logic               rvalid;
  logic               rready;

  logic        interrupt;
  logic        heartbeat;
  logic        ap_start;
  logic        ap_launch;
  logic        ap_done;
  logic [63:0] src_addr;
  logic [63:0] dst_addr;
  logic [31:0] img_width;
  logic [31:0] img_height;
  logic [31:0] mode;

`ifdef NEGATIVE_CONTROL
  socket_ctrl_broken
`else
  socket_ctrl
`endif
    // HB_BITS is 24 in a build -- ~45 ms a toggle at 187.5 MHz, which is what
    // software can poll. Eight here, so the heartbeat check costs 256 cycles
    // rather than 8.4 million.
    #(.ADDR_WIDTH(AW_BITS), .DATA_WIDTH(DW), .KERNEL_ID(KERNEL_ID), .HB_BITS(8)) dut
    (.clk(clk), .rst_n(rst_n),
     .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
     .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
     .bresp(bresp), .bvalid(bvalid), .bready(bready),
     .araddr(araddr), .arvalid(arvalid), .arready(arready),
     .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
     .interrupt(interrupt), .heartbeat(heartbeat),
     .ap_start(ap_start), .ap_launch(ap_launch), .ap_done(ap_done),
     .src_addr(src_addr), .dst_addr(dst_addr),
     .img_width(img_width), .img_height(img_height), .mode(mode));

  int errors = 0;
  int checks = 0;

  task automatic expect_eq(input [63:0] got, input [63:0] exp, input string what);
    begin
      checks++;
      if (got !== exp) begin
        errors++;
        $display("FAIL %-46s got %h expected %h", what, got, exp);
      end
    end
  endtask

  // ------------------------------------------------------------------
  // The hostile master.
  //
  // aw_delay and w_delay are applied independently from the same start
  // instant, so a positive difference means the address leads and a negative
  // one means the data leads. A slave that assumes either ordering fails here.
  // ------------------------------------------------------------------
  task automatic axi_write(input [AW_BITS-1:0] addr,
                           input [DW-1:0]      data,
                           input [DW/8-1:0]    strb,
                           input int           aw_delay,
                           input int           w_delay,
                           input int           b_delay);
    int unsigned guard;
    begin
      fork
        begin : drive_aw
          repeat (aw_delay) @(posedge clk);
          awaddr  <= addr;
          awvalid <= 1'b1;
          @(posedge clk);
          while (!awready) @(posedge clk);
          awvalid <= 1'b0;
        end
        begin : drive_w
          repeat (w_delay) @(posedge clk);
          wdata  <= data;
          wstrb  <= strb;
          wvalid <= 1'b1;
          @(posedge clk);
          while (!wready) @(posedge clk);
          wvalid <= 1'b0;
        end
      join

      // B channel. Holding bready low for b_delay cycles checks that the slave
      // keeps bvalid asserted rather than pulsing it and losing the response.
      repeat (b_delay) @(posedge clk);
      bready <= 1'b1;
      guard = 0;
      @(posedge clk);
      while (!bvalid) begin
        @(posedge clk);
        guard++;
        if (guard > 200) begin
          errors++;
          $display("FAIL write to %h never produced bvalid (aw_delay=%0d w_delay=%0d)",
                   addr, aw_delay, w_delay);
          disable axi_write;
        end
      end
      checks++;
      if (bresp !== 2'b00) begin
        errors++;
        $display("FAIL write to %h returned bresp=%b", addr, bresp);
      end
      bready <= 1'b0;
    end
  endtask

  task automatic axi_read(input  [AW_BITS-1:0] addr,
                          output [DW-1:0]      data,
                          input  int           ar_delay,
                          input  int           r_delay);
    int unsigned guard;
    logic [DW-1:0] first_seen;
    begin
      repeat (ar_delay) @(posedge clk);
      araddr  <= addr;
      arvalid <= 1'b1;
      @(posedge clk);
      while (!arready) @(posedge clk);
      arvalid <= 1'b0;

      // Wait for rvalid with rready LOW, then hold it low for r_delay more
      // cycles and confirm rdata does not move underneath us. A slave that
      // recomputes rdata combinationally from a changing source fails here,
      // and that is a real bug: the master samples on the handshake, not on
      // the first cycle rvalid happens to be high.
      guard = 0;
      while (!rvalid) begin
        @(posedge clk);
        guard++;
        if (guard > 200) begin
          errors++;
          $display("FAIL read of %h never produced rvalid", addr);
          data = 'x;
          disable axi_read;
        end
      end
      first_seen = rdata;
      repeat (r_delay) begin
        @(posedge clk);
        checks++;
        if (rdata !== first_seen) begin
          errors++;
          $display("FAIL read of %h changed rdata while rready was low: %h -> %h",
                   addr, first_seen, rdata);
        end
        if (!rvalid) begin
          errors++;
          $display("FAIL read of %h dropped rvalid before rready", addr);
        end
      end
      rready <= 1'b1;
      @(posedge clk);
      data = rdata;
      checks++;
      if (rresp !== 2'b00) begin
        errors++;
        $display("FAIL read of %h returned rresp=%b", addr, rresp);
      end
      rready <= 1'b0;
    end
  endtask

  // The datapath side: acknowledge a launch after `frame_cycles`, the way a
  // real engine would, so CTRL's ap_done/ap_idle behaviour can be exercised.
  int  frame_cycles = 20;
  bit  engine_enabled = 1'b1;
  always @(posedge clk) begin
    if (!rst_n) begin
      ap_done <= 1'b0;
    end else begin
      ap_done <= 1'b0;
      if (ap_launch && engine_enabled) begin
        repeat (frame_cycles) @(posedge clk);
        ap_done <= 1'b1;
      end
    end
  end

  // Free-running, so a test checks a DELTA rather than trying to open an
  // observation window around the pulse it wants to see. The first version of
  // test 9 started counting after the write that caused the first launch, and
  // then blamed the DUT for the launch it had already missed.
  int launch_count = 0;
  always @(posedge clk) if (rst_n && ap_launch) launch_count++;

  logic [DW-1:0] rd;
  int aw_d, w_d;

  initial begin
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    awaddr = 0; wdata = 0; wstrb = 4'hF; araddr = 0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    // ------------------------------------------------------------------
    // 1. Every AW/W skew, both orderings. This is the test the spike needed.
    // ------------------------------------------------------------------
    for (aw_d = 0; aw_d <= 8; aw_d++) begin
      for (w_d = 0; w_d <= 8; w_d++) begin
        axi_write(ADDR_SRC_LO, 32'hDEAD_0000 | (aw_d << 8) | w_d, 4'hF, aw_d, w_d, 0);
        axi_read(ADDR_SRC_LO, rd, 0, 0);
        expect_eq(rd, 32'hDEAD_0000 | (aw_d << 8) | w_d,
                  $sformatf("src_lo after skew aw=%0d w=%0d", aw_d, w_d));
      end
    end

    // ------------------------------------------------------------------
    // 2. Delayed bready and rready, including zero-delay back-to-back.
    // ------------------------------------------------------------------
    for (int bd = 0; bd <= 6; bd++) begin
      axi_write(ADDR_DST_LO, 32'hBEEF_0000 | bd, 4'hF, 0, 0, bd);
      axi_read(ADDR_DST_LO, rd, 0, bd);
      expect_eq(rd, 32'hBEEF_0000 | bd, $sformatf("dst_lo with b/r delay %0d", bd));
    end

    // ------------------------------------------------------------------
    // 3. Every register round-trips, and the 64-bit pairs are independent.
    // ------------------------------------------------------------------
    axi_write(ADDR_SRC_LO, 32'h1111_2222, 4'hF, 0, 0, 0);
    axi_write(ADDR_SRC_HI, 32'h3333_4444, 4'hF, 0, 0, 0);
    axi_write(ADDR_DST_LO, 32'h5555_6666, 4'hF, 0, 0, 0);
    axi_write(ADDR_DST_HI, 32'h7777_8888, 4'hF, 0, 0, 0);
    axi_write(ADDR_WIDTH_, 32'd1280,      4'hF, 0, 0, 0);
    axi_write(ADDR_HEIGHT, 32'd720,       4'hF, 0, 0, 0);
    axi_write(ADDR_MODE,   32'd3,         4'hF, 0, 0, 0);
    expect_eq(src_addr,   64'h3333_4444_1111_2222, "src_addr as seen by the datapath");
    expect_eq(dst_addr,   64'h7777_8888_5555_6666, "dst_addr as seen by the datapath");
    expect_eq(img_width,  32'd1280, "img_width");
    expect_eq(img_height, 32'd720,  "img_height");
    expect_eq(mode,       32'd3,    "mode");

    // ------------------------------------------------------------------
    // 4. Byte strobes. A slave that ignores wstrb corrupts the other three
    //    bytes, and PYNQ's 32-bit writes would never reveal it.
    // ------------------------------------------------------------------
    axi_write(ADDR_WIDTH_, 32'hFFFF_FFFF, 4'b0001, 0, 0, 0);
    expect_eq(img_width, 32'h0000_05FF, "img_width after a byte-0-only write");

    // ------------------------------------------------------------------
    // 5. kernel_id: reads the constant, and is read-only.
    // ------------------------------------------------------------------
    axi_read(ADDR_KERNEL, rd, 0, 0);
    expect_eq(rd, KERNEL_ID, "kernel_id");
    axi_write(ADDR_KERNEL, 32'h0000_0000, 4'hF, 0, 0, 0);
    axi_read(ADDR_KERNEL, rd, 0, 0);
    expect_eq(rd, KERNEL_ID, "kernel_id still reads the constant after a write");
    axi_read(ADDR_MODE, rd, 0, 0);
    expect_eq(rd, 32'd3, "the write to kernel_id did not land on a neighbour");

    // ------------------------------------------------------------------
    // 6. heartbeat toggles while the partition is clocked and out of reset.
    //    This is what the static region's GPIO watches, so it has to move.
    // ------------------------------------------------------------------
    begin
      logic hb0;
      bit   moved;
      hb0 = heartbeat;
      moved = 1'b0;
      for (int i = 0; i < 1000; i++) begin
        @(posedge clk);
        if (heartbeat !== hb0) moved = 1'b1;
      end
      checks++;
      if (!moved) begin
        errors++;
        $display("FAIL heartbeat never toggled in 1000 cycles");
      end
    end

    // ------------------------------------------------------------------
    // 7. ap_start / ap_done, including the clear-on-read that cost CH12 a
    //    long hunt. A CTRL read that is ACKNOWLEDGED clears ap_done; a read
    //    that is presented but not acknowledged must not.
    // ------------------------------------------------------------------
    axi_write(ADDR_CTRL, 32'h1, 4'hF, 0, 0, 0);      // ap_start
    repeat (frame_cycles + 8) @(posedge clk);
    axi_read(ADDR_CTRL, rd, 0, 0);
    expect_eq(rd[1], 1'b1, "ap_done set after a frame");
    axi_read(ADDR_CTRL, rd, 0, 0);
    expect_eq(rd[1], 1'b0, "ap_done cleared by the read that reported it");

    // A read held off by rready must not clear it early: the value the master
    // finally samples has to be the one that reported done.
    axi_write(ADDR_CTRL, 32'h1, 4'hF, 0, 0, 0);
    repeat (frame_cycles + 8) @(posedge clk);
    axi_read(ADDR_CTRL, rd, 0, 5);
    expect_eq(rd[1], 1'b1, "ap_done survives a read stalled by rready");

    // ------------------------------------------------------------------
    // 8. IP_ISR is toggle-on-write and sticky, which is what makes it a
    //    trustworthy record of a completion. IER gates the latch.
    // ------------------------------------------------------------------
    axi_read(ADDR_CTRL, rd, 0, 0);                    // drain ap_done
    axi_write(ADDR_IER, 32'h1, 4'hF, 0, 0, 0);
    // Toggle-on-write: to CLEAR, write back exactly the bits that are set.
    // Writing 32'h3 at a clear ISR would SET both bits, which is what the
    // first version of this test did before blaming the DUT for the result.
    axi_read(ADDR_ISR, rd, 0, 0);
    axi_write(ADDR_ISR, rd, 4'hF, 0, 0, 0);
    axi_read(ADDR_ISR, rd, 0, 0);
    expect_eq(rd[0], 1'b0, "ISR starts clear");
    axi_write(ADDR_CTRL, 32'h1, 4'hF, 0, 0, 0);
    repeat (frame_cycles + 8) @(posedge clk);
    axi_read(ADDR_ISR, rd, 0, 0);
    expect_eq(rd[0], 1'b1, "ISR latched ap_done");
    axi_read(ADDR_ISR, rd, 0, 0);
    expect_eq(rd[0], 1'b1, "ISR is sticky -- a read does not clear it");
    axi_write(ADDR_ISR, 32'h1, 4'hF, 0, 0, 0);        // toggle it away
    axi_read(ADDR_ISR, rd, 0, 0);
    expect_eq(rd[0], 1'b0, "ISR cleared by writing 1");

    // ------------------------------------------------------------------
    // 9. A start that arrives while the engine is busy is QUEUED, not
    //    discarded. CH12 measured the discard as a hang about once in a
    //    thousand frames.
    // ------------------------------------------------------------------
    axi_read(ADDR_CTRL, rd, 0, 0);
    begin
      int launch0;
      frame_cycles = 200;
      launch0 = launch_count;
      axi_write(ADDR_CTRL, 32'h1, 4'hF, 0, 0, 0);
      repeat (20) @(posedge clk);
      axi_write(ADDR_CTRL, 32'h1, 4'hF, 0, 0, 0);     // while busy
      repeat (2000) @(posedge clk);
      checks++;
      if (launch_count - launch0 != 2) begin
        errors++;
        $display("FAIL two starts, the second while busy, produced %0d launches, expected 2",
                 launch_count - launch0);
      end
    end

    repeat (20) @(posedge clk);
    $display("");
    $display("tb_socket_ctrl: %0d checks, %0d errors", checks, errors);
    if (errors == 0) $display("PASS");
    else             $display("FAIL");
    $finish;
  end

  // A global watchdog. Without one, a slave that never responds hangs the
  // simulation the same way it hangs the board, and the run has to be killed
  // by hand -- which is exactly the failure mode this chapter is about.
  initial begin
    #20_000_000;
    $display("FAIL tb_socket_ctrl timed out -- the slave stopped responding");
    $display("FAIL");
    $finish;
  end

endmodule
