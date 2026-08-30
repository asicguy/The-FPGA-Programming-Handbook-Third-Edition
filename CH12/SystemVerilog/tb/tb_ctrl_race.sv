// tb_ctrl_race.sv
// ------------------------------------
// Can a completion be lost between ap_done and a polling master?
// ------------------------------------
// Author : Frank Bruno
//
// On hardware, about one frame in a thousand, the accelerator finishes and the
// polling master never sees AP_DONE. Measured, not supposed: a probe read one
// transaction after arming shows the kernel launched, IP_ISR latches the same
// ap_done, and CTRL comes back with ap_idle set and AP_DONE clear. Something
// consumes CTRL's clear-on-read copy before the poll observes it.
//
// The main testbench never reproduces it, because its AXI4-Lite model answers
// with zero latency and always lands the read in the same phase relative to the
// done pulse. This one does the opposite: it holds a master polling CTRL
// exactly the way sw/filter_driver.py does, and sweeps the ap_done pulse
// through every cycle offset relative to that poll, with every AR/R latency the
// interconnect could plausibly impose.
//
// The invariant, for every phase: the master must observe AP_DONE exactly once.
// Never zero -- that is the hang. Never twice -- that would be a completion
// reported for a frame that had not run.
`timescale 1ns/10ps
module tb_ctrl_race;

  localparam CLK = 5.0;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #(CLK/2.0) clk = ~clk;

  logic [5:0]  awaddr;  logic awvalid, awready;
  logic [31:0] wdata;   logic [3:0] wstrb;
  logic        wvalid,  wready;
  logic [1:0]  bresp;   logic bvalid, bready;
  logic [5:0]  araddr;  logic arvalid, arready;
  logic [31:0] rdata;   logic [1:0] rresp;
  logic        rvalid,  rready;
  logic        interrupt;

  logic        ap_start, ap_done, ap_launch;
  logic [63:0] src_addr, dst_addr;
  logic [31:0] img_width, img_height, mode;

  video_filter_ctrl u_dut
    (.clk (clk), .rst_n (rst_n),
     .awaddr (awaddr), .awvalid (awvalid), .awready (awready),
     .wdata (wdata), .wstrb (wstrb), .wvalid (wvalid), .wready (wready),
     .bresp (bresp), .bvalid (bvalid), .bready (bready),
     .araddr (araddr), .arvalid (arvalid), .arready (arready),
     .rdata (rdata), .rresp (rresp), .rvalid (rvalid), .rready (rready),
     .interrupt (interrupt),
     .ap_start (ap_start), .ap_launch (ap_launch), .ap_done (ap_done),
     .src_addr (src_addr), .dst_addr (dst_addr),
     .img_width (img_width), .img_height (img_height), .mode (mode));

  localparam [5:0] ADDR_CTRL = 6'h00;
  localparam       BIT_DONE  = 1;

  int  seen_done;          // how many reads came back with AP_DONE set
  int  errors, cases;
  bit  polling;
  int  rready_gap;         // cycles the master holds RREADY low

  // ------------------------------------------------------------------
  // The master: polls CTRL back to back, exactly like wait() does.
  // ------------------------------------------------------------------
  task automatic axil_write(input [5:0] a, input [31:0] d);
    begin
      @(posedge clk);
      awaddr <= a; awvalid <= 1'b1;
      wdata  <= d; wstrb <= 4'hF; wvalid <= 1'b1; bready <= 1'b1;
      forever begin
        @(posedge clk);
        if (awvalid && awready) awvalid <= 1'b0;
        if (wvalid  && wready)  wvalid  <= 1'b0;
        if (bvalid  && bready)  break;
      end
      @(posedge clk); bready <= 1'b0;
    end
  endtask

  // One CTRL read. Returns through `last_read`.
  logic [31:0] last_read;
  task automatic axil_read_ctrl(input int gap);
    begin
      @(posedge clk);
      araddr <= ADDR_CTRL; arvalid <= 1'b1; rready <= 1'b0;
      forever begin
        @(posedge clk);
        if (arvalid && arready) arvalid <= 1'b0;
        if (rvalid) break;
      end
      // The interconnect does not necessarily accept read data immediately.
      repeat (gap) @(posedge clk);
      rready <= 1'b1;
      forever begin
        @(posedge clk);
        if (rvalid && rready) begin
          last_read = rdata;
          break;
        end
      end
      rready <= 1'b0;
      if (last_read[BIT_DONE]) seen_done++;
    end
  endtask

  // ------------------------------------------------------------------
  // One case: arm, let the master poll, pulse ap_done at `phase`.
  // ------------------------------------------------------------------
  task automatic run_case(input int phase, input int gap);
    begin
      cases++;
      // reset between cases so nothing carries over
      rst_n = 1'b0;
      arvalid <= 1'b0; rready <= 1'b0; awvalid <= 1'b0; wvalid <= 1'b0;
      repeat (4) @(posedge clk);
      rst_n = 1'b1;
      repeat (2) @(posedge clk);

      seen_done = 0;
      axil_write(ADDR_CTRL, 32'h1);          // ap_start

      polling = 1'b1;
      fork
        begin : poller
          while (polling) axil_read_ctrl(gap);
        end
        begin : doner
          repeat (phase) @(posedge clk);
          ap_done <= 1'b1;
          @(posedge clk);
          ap_done <= 1'b0;
          // give the master plenty of chances to observe it
          repeat (60) @(posedge clk);
          polling = 1'b0;
        end
      join_any
      wait (!polling);
      repeat (20) @(posedge clk);

      if (seen_done != 1) begin
        $display("  LOST  phase=%0d rready_gap=%0d : master observed AP_DONE %0d times",
                 phase, gap, seen_done);
        errors++;
      end
    end
  endtask

  // ------------------------------------------------------------------
  // Does a CTRL write survive arriving while the kernel is busy?
  //
  // `if (wdata_r[0] && ap_idle) ap_start <= 1'b1;` discards the write when
  // ap_idle is low. Vitis HLS has no such guard. If software and hardware ever
  // disagree about whether a frame is running -- and a duplicate ap_done is
  // one way to make that happen -- the next start vanishes with no error, and
  // what is left afterwards is exactly the hardware signature: ap_idle set,
  // ap_start clear, no completion coming.
  // ------------------------------------------------------------------
  // Count launch pulses, so "did the frame actually start" is observable
  // rather than inferred from ap_start, which is high for the whole run and
  // therefore proves nothing.
  int launches;
  always_ff @(posedge clk) if (rst_n && ap_launch) launches <= launches + 1;

  task automatic case_start_while_busy;
    begin
      cases++;
      rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1;
      repeat (2) @(posedge clk);
      launches = 0;

      axil_write(ADDR_CTRL, 32'h1);            // frame N
      repeat (6) @(posedge clk);
      if (launches != 1) begin
        $display("  ERROR: frame N produced %0d launches, expected 1", launches);
        errors++;
      end

      axil_write(ADDR_CTRL, 32'h1);            // frame N+1, arriving while busy
      repeat (4) @(posedge clk);

      ap_done <= 1'b1; @(posedge clk); ap_done <= 1'b0;   // frame N ends
      repeat (8) @(posedge clk);

      // The queued start must now run. Dropping it silently is the fault this
      // whole exercise is about: it leaves ap_idle=1, ap_start=0 and a poll
      // that will never be satisfied.
      if (launches != 2) begin
        $display("  DROPPED: a start written while busy never ran (%0d launches, expected 2)",
                 launches);
        errors++;
      end
      if (u_dut.ap_idle !== 1'b0) begin
        $display("  DROPPED: after the queued start, ap_idle=%0b (expected 0, running)",
                 u_dut.ap_idle);
        errors++;
      end
    end
  endtask

  // A start arriving when idle must run immediately, and exactly once -- a
  // queue that fires twice would be as bad as one that drops.
  task automatic case_start_when_idle_runs_once;
    begin
      cases++;
      rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1;
      repeat (2) @(posedge clk);
      launches = 0;
      axil_write(ADDR_CTRL, 32'h1);
      repeat (10) @(posedge clk);
      if (launches != 1) begin
        $display("  ERROR: an idle start produced %0d launches, expected 1", launches);
        errors++;
      end
      ap_done <= 1'b1; @(posedge clk); ap_done <= 1'b0;
      repeat (10) @(posedge clk);
      if (launches != 1) begin
        $display("  ERROR: %0d launches after completion, expected no re-launch",
                 launches);
        errors++;
      end
    end
  endtask

  // A second ap_done for one start desynchronises software from hardware: the
  // stale completion satisfies the next frame's first poll, so software starts
  // a frame while the previous one is still running.
  task automatic case_duplicate_done;
    begin
      cases++;
      rst_n = 1'b0; repeat (4) @(posedge clk); rst_n = 1'b1;
      repeat (2) @(posedge clk);
      seen_done = 0;

      axil_write(ADDR_CTRL, 32'h1);
      repeat (3) @(posedge clk);
      ap_done <= 1'b1; @(posedge clk); ap_done <= 1'b0;
      repeat (3) @(posedge clk);
      ap_done <= 1'b1; @(posedge clk); ap_done <= 1'b0;   // spurious second
      repeat (3) @(posedge clk);

      axil_read_ctrl(0);
      axil_read_ctrl(0);
      if (seen_done > 1) begin
        $display("  STALE: one start produced %0d observable completions",
                 seen_done);
        errors++;
      end
    end
  endtask

  initial begin
    ap_done = 1'b0; arvalid = 1'b0; rready = 1'b0;
    awvalid = 1'b0; wvalid = 1'b0; bready = 1'b0;
    araddr = 0; awaddr = 0; wdata = 0; wstrb = 0;
    errors = 0; cases = 0; polling = 0;

    repeat (6) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    $display("tb_ctrl_race -- sweeping the ap_done pulse against a polling master");

    for (int gap = 0; gap <= 3; gap++)
      for (int phase = 0; phase < 24; phase++)
        run_case(phase, gap);

    $display("");
    $display("-- a start written while the kernel is busy --");
    case_start_while_busy();
    $display("-- a start written while idle --");
    case_start_when_idle_runs_once();
    $display("-- a duplicate ap_done for one start --");
    case_duplicate_done();

    $display("");
    if (errors == 0)
      $display("PASS -- %0d phase/latency combinations, AP_DONE observed exactly once in each",
               cases);
    else
      $display("FAIL -- %0d of %0d combinations lost or duplicated the completion",
               errors, cases);
    $finish;
  end

  initial begin
    #20ms;
    $display("FAIL -- testbench timed out");
    $finish;
  end

endmodule
