// tb_sobel_stream.sv
// ------------------------------------
// Self-checking testbench for the streaming Sobel video filter
// ------------------------------------
// Author : Frank Bruno
//
// One testbench, three DUTs. It instantiates a module called `sobel_stream`
// with the port names Vitis HLS generates, and sim.sh binds it in turn against
// the SystemVerilog RTL, the VHDL RTL and the HLS-generated Verilog. A pass on
// all three is the practical statement of drop-in compatibility: same stream
// interface, same register map, same pixels.
//
// It replaces C/RTL co-simulation for the HLS build, which Vitis refuses to run
// on this design -- cosim supports ap_ctrl_none only for a top level that is a
// single II=1 pipeline, and this one has a synchronisation phase, a mode branch
// and a nested loop. Driving the generated RTL from here checks the same thing
// and checks it against the same stimulus as the hand-written versions.
//
// What is checked, per case:
//   * every output pixel against a golden model transcribed from the C
//   * the beat count: exactly img_width/2 * img_height beats per frame, and
//     nothing afterwards. A streaming filter that emits one beat too few does
//     not produce a wrong picture, it wedges the VDMA.
//   * TUSER on exactly the first beat of a frame, TLAST on the last beat of
//     every line
//   * that the frame completes with no further input, which is what the flush
//     row exists for
//   * that a mode written mid-frame takes effect at the next frame, not this one
//   * that the filter re-synchronises on TUSER after arriving mid-frame
//
// Backpressure on the output and gaps on the input are randomised, so the
// design is exercised stalled rather than only at full throughput.
`timescale 1ns/10ps
module tb_sobel_stream;

  localparam real CLK_PERIOD = 5.0;      // 200 MHz, the video_aclk of the pipeline

  // Frame sizes used here are small; cosim-scale, not camera-scale.
  localparam int MAXW     = 320;
  localparam int MAXH     = 48;
  localparam int MAXBEATS = (MAXW/2) * MAXH;
  localparam int MONDEPTH = 4 * MAXBEATS;

  // Register map, byte for byte what Vitis HLS generates for this kernel.
  localparam [5:0] ADDR_WIDTH_R  = 6'h10;
  localparam [5:0] ADDR_HEIGHT_R = 6'h18;
  localparam [5:0] ADDR_MODE_R   = 6'h20;

  localparam int MODE_GRAY   = 0;
  localparam int MODE_SOBEL  = 1;
  localparam int MODE_INVERT = 2;
  localparam int MODE_COLOR  = 3;

  logic ap_clk   = 1'b0;
  logic ap_rst_n = 1'b0;
  always #(CLK_PERIOD/2.0) ap_clk = ~ap_clk;

  // ------------------------------------------------------------------
  // DUT signals
  // ------------------------------------------------------------------
  logic [5:0]  ctrl_awaddr;  logic ctrl_awvalid; wire ctrl_awready;
  logic [31:0] ctrl_wdata;   logic [3:0] ctrl_wstrb;
  logic        ctrl_wvalid;  wire  ctrl_wready;
  wire  [1:0]  ctrl_bresp;   wire  ctrl_bvalid;  logic ctrl_bready;
  logic [5:0]  ctrl_araddr;  logic ctrl_arvalid; wire  ctrl_arready;
  wire  [31:0] ctrl_rdata;   wire  [1:0] ctrl_rresp;
  wire         ctrl_rvalid;  logic ctrl_rready;

  logic [47:0] in_tdata;  logic in_tvalid; wire in_tready;
  logic        in_tuser;  logic in_tlast;

  wire  [47:0] out_tdata; wire  out_tvalid; logic out_tready;
  wire         out_tuser; wire  out_tlast;
  wire  [5:0]  out_tkeep, out_tstrb;

  sobel_stream dut
    (.ap_clk                (ap_clk),
     .ap_rst_n              (ap_rst_n),

     .stream_in_TDATA       (in_tdata),
     .stream_in_TVALID      (in_tvalid),
     .stream_in_TREADY      (in_tready),
     .stream_in_TKEEP       (6'h3F),
     .stream_in_TSTRB       (6'h3F),
     .stream_in_TUSER       (in_tuser),
     .stream_in_TLAST       (in_tlast),

     .stream_out_TDATA      (out_tdata),
     .stream_out_TVALID     (out_tvalid),
     .stream_out_TREADY     (out_tready),
     .stream_out_TKEEP      (out_tkeep),
     .stream_out_TSTRB      (out_tstrb),
     .stream_out_TUSER      (out_tuser),
     .stream_out_TLAST      (out_tlast),

     .s_axi_control_AWVALID (ctrl_awvalid),
     .s_axi_control_AWREADY (ctrl_awready),
     .s_axi_control_AWADDR  (ctrl_awaddr),
     .s_axi_control_WVALID  (ctrl_wvalid),
     .s_axi_control_WREADY  (ctrl_wready),
     .s_axi_control_WDATA   (ctrl_wdata),
     .s_axi_control_WSTRB   (ctrl_wstrb),
     .s_axi_control_ARVALID (ctrl_arvalid),
     .s_axi_control_ARREADY (ctrl_arready),
     .s_axi_control_ARADDR  (ctrl_araddr),
     .s_axi_control_RVALID  (ctrl_rvalid),
     .s_axi_control_RREADY  (ctrl_rready),
     .s_axi_control_RDATA   (ctrl_rdata),
     .s_axi_control_RRESP   (ctrl_rresp),
     .s_axi_control_BVALID  (ctrl_bvalid),
     .s_axi_control_BREADY  (ctrl_bready),
     .s_axi_control_BRESP   (ctrl_bresp));

  // ------------------------------------------------------------------
  // Output monitor and randomised backpressure
  // ------------------------------------------------------------------
  logic [47:0] mon_data [MONDEPTH];
  logic        mon_user [MONDEPTH];
  logic        mon_last [MONDEPTH];
  int          mon_cnt = 0;

  int          bp_pct  = 0;      // percent of cycles TREADY is deasserted

  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      out_tready <= 1'b1;
    end else begin
      out_tready <= ($urandom_range(0, 99) >= bp_pct);
    end
  end

  always_ff @(posedge ap_clk) begin
    if (ap_rst_n && out_tvalid && out_tready && (mon_cnt < MONDEPTH)) begin
      mon_data[mon_cnt] <= out_tdata;
      mon_user[mon_cnt] <= out_tuser;
      mon_last[mon_cnt] <= out_tlast;
      mon_cnt           <= mon_cnt + 1;
    end
  end

  // ------------------------------------------------------------------
  // AXI4-Lite master
  // ------------------------------------------------------------------
  task automatic axil_write(input [5:0] addr, input [31:0] data);
    begin
      @(posedge ap_clk);
      ctrl_awaddr <= addr;  ctrl_awvalid <= 1'b1;
      ctrl_wdata  <= data;  ctrl_wstrb   <= 4'hF;  ctrl_wvalid <= 1'b1;
      ctrl_bready <= 1'b1;
      @(posedge ap_clk);
      while (ctrl_awvalid || ctrl_wvalid) begin
        if (ctrl_awvalid && ctrl_awready) ctrl_awvalid <= 1'b0;
        if (ctrl_wvalid  && ctrl_wready ) ctrl_wvalid  <= 1'b0;
        @(posedge ap_clk);
      end
      while (!(ctrl_bvalid && ctrl_bready)) @(posedge ap_clk);
      @(posedge ap_clk);
      ctrl_bready <= 1'b0;
    end
  endtask

  // Result of the most recent axil_read. An `output` argument on an automatic
  // task takes the xsim kernel down, so the value comes back this way.
  logic [31:0] axil_rd_data;

  task automatic axil_read(input [5:0] addr);
    begin
      @(posedge ap_clk);
      ctrl_araddr <= addr; ctrl_arvalid <= 1'b1; ctrl_rready <= 1'b1;
      @(posedge ap_clk);
      while (!(ctrl_arvalid && ctrl_arready)) @(posedge ap_clk);
      ctrl_arvalid <= 1'b0;
      while (!(ctrl_rvalid && ctrl_rready)) @(posedge ap_clk);
      axil_rd_data = ctrl_rdata;
      ctrl_rready <= 1'b0;
      @(posedge ap_clk);
    end
  endtask

  // ------------------------------------------------------------------
  // Stimulus and golden model
  // ------------------------------------------------------------------
  // Fixed-size rather than dynamic: re-allocating a dynamic array per test
  // case is what the xsim kernel could not survive in CH11.
  logic [23:0] src_px [MAXH][MAXW];   // B in the low byte, then G, then R
  logic [23:0] ref_px [MAXH][MAXW];
  logic [7:0]  gray   [MAXH][MAXW];

  function automatic logic [7:0] luma8(input [23:0] px);
    logic [17:0] s;
    begin
      // BT.601 in Q8: 0.299/0.587/0.114 -> 77/150/29, on B,G,R from the LSB up
      s = 18'd29 * px[7:0] + 18'd150 * px[15:8] + 18'd77 * px[23:16];
      luma8 = s[15:8];
    end
  endfunction

  // A gradient with a hard-edged bright square, plus a deterministic speckle so
  // that neighbouring pixels differ everywhere -- a filter that is one column
  // out on a smooth gradient still looks almost right.
  task automatic build_source(input int W, input int H, input int seed);
    int r, c;
    int lfsr;
    logic [7:0] R, G, B;
    logic [7:0] n;
    begin
      lfsr = seed | 1;
      for (r = 0; r < H; r++) begin
        for (c = 0; c < W; c++) begin
          lfsr = lfsr * 1103515245 + 12345;
          n = (lfsr >> 16) & 8'h1F;
          B = (W > 1) ? ((c * 200) / (W-1)) : 8'd0;
          G = (H > 1) ? ((r * 200) / (H-1)) : 8'd0;
          R = ((W + H) > 2) ? (((r + c) * 200) / (W + H - 2)) : 8'd0;
          if (r > H/4 && r < 3*H/4 && c > W/4 && c < 3*W/4) begin
            B = 8'd240; G = 8'd240; R = 8'd240;
          end
          src_px[r][c] = {(R + n), (G + n), (B + n)};
        end
      end
    end
  endtask

  // Transcription of the C golden model in tb_sobel_stream.cpp.
  task automatic build_golden(input int W, input int H, input int md);
    int r, c;
    int p00, p01, p02, p10, p12, p20, p21, p22, gx, gy, m;
    logic [7:0] v;
    begin
      if (md == MODE_COLOR) begin
        for (r = 0; r < H; r++)
          for (c = 0; c < W; c++)
            ref_px[r][c] = src_px[r][c];
      end else begin
        for (r = 0; r < H; r++)
          for (c = 0; c < W; c++)
            gray[r][c] = luma8(src_px[r][c]);

        for (r = 0; r < H; r++) begin
          for (c = 0; c < W; c++) begin
            if (md == MODE_GRAY) begin
              v = gray[r][c];
            end else if (md == MODE_INVERT) begin
              v = 8'd255 - gray[r][c];
            end else begin
              if (r == 0 || r == H-1 || c == 0 || c == W-1) begin
                v = 8'd0;
              end else begin
                p00 = gray[r-1][c-1]; p01 = gray[r-1][c]; p02 = gray[r-1][c+1];
                p10 = gray[ r ][c-1];                     p12 = gray[ r ][c+1];
                p20 = gray[r+1][c-1]; p21 = gray[r+1][c]; p22 = gray[r+1][c+1];
                gx  = (p02 + 2*p12 + p22) - (p00 + 2*p10 + p20);
                gy  = (p20 + 2*p21 + p22) - (p00 + 2*p01 + p02);
                m   = (gx < 0 ? -gx : gx) + (gy < 0 ? -gy : gy);
                v   = (m > 255) ? 8'd255 : m[7:0];
              end
            end
            ref_px[r][c] = {v, v, v};
          end
        end
      end
    end
  endtask

  // ------------------------------------------------------------------
  // Frame driver
  // ------------------------------------------------------------------
  // gap_pct is the chance per beat of inserting an idle cycle, so the input is
  // bursty rather than a solid stream. sof selects whether the frame is marked
  // with TUSER -- driving one without is how the re-synchronisation test makes
  // the filter arrive in the middle of a frame.
  task automatic drive_frame(input int W, input int H,
                             input int gap_pct, input bit sof);
    int r, b, nb;
    begin
      nb = W/2;
      for (r = 0; r < H; r++) begin
        for (b = 0; b < nb; b++) begin
          while ($urandom_range(0, 99) < gap_pct) begin
            in_tvalid <= 1'b0;
            @(posedge ap_clk);
          end
          in_tdata  <= {src_px[r][2*b+1], src_px[r][2*b]};
          in_tuser  <= (sof && (r == 0) && (b == 0)) ? 1'b1 : 1'b0;
          in_tlast  <= (b == nb-1) ? 1'b1 : 1'b0;
          in_tvalid <= 1'b1;
          @(posedge ap_clk);
          while (!in_tready) @(posedge ap_clk);
        end
      end
      in_tvalid <= 1'b0;
      in_tuser  <= 1'b0;
      in_tlast  <= 1'b0;
    end
  endtask

  // Same, but writes the mode register partway through the frame. Used to show
  // that the change lands at the next frame boundary rather than tearing this
  // one in half.
  task automatic drive_frame_switching(input int W, input int H,
                                       input int at_row, input int new_mode);
    int r, b, nb;
    begin
      nb = W/2;
      for (r = 0; r < H; r++) begin
        if (r == at_row) begin
          // TVALID has to come down first. Holding it asserted across the
          // register write would leave the previous beat on the bus for the
          // whole transaction, and the DUT would be quite right to accept that
          // beat again on every cycle of it.
          in_tvalid <= 1'b0;
          @(posedge ap_clk);
          axil_write(ADDR_MODE_R, new_mode);
        end
        for (b = 0; b < nb; b++) begin
          in_tdata  <= {src_px[r][2*b+1], src_px[r][2*b]};
          in_tuser  <= ((r == 0) && (b == 0)) ? 1'b1 : 1'b0;
          in_tlast  <= (b == nb-1) ? 1'b1 : 1'b0;
          in_tvalid <= 1'b1;
          @(posedge ap_clk);
          while (!in_tready) @(posedge ap_clk);
        end
      end
      in_tvalid <= 1'b0;
      in_tuser  <= 1'b0;
      in_tlast  <= 1'b0;
    end
  endtask

  // ------------------------------------------------------------------
  // Checking
  // ------------------------------------------------------------------
  int errors_total = 0;

  // Wait for `want` beats to have been collected, or give up.
  int wait_timeout;

  task automatic wait_for_beats(input int want);
    int guard;
    begin
      guard        = 0;
      wait_timeout = 0;
      while ((mon_cnt < want) && (guard < 2000000)) begin
        @(posedge ap_clk);
        guard = guard + 1;
      end
      if (mon_cnt < want) wait_timeout = 1;
    end
  endtask

  // Compare the frame that starts at monitor index `base` against ref_px.
  int frame_errors;

  task automatic check_frame(input int base, input int W, input int H,
                             input string name);
    int r, b, nb, i;
    logic [23:0] got0, got1;
    bit want_user, want_last;
    begin
      frame_errors = 0;
      nb = W/2;
      for (r = 0; r < H; r++) begin
        for (b = 0; b < nb; b++) begin
          i    = base + r*nb + b;
          got0 = mon_data[i][23:0];
          got1 = mon_data[i][47:24];

          if (got0 !== ref_px[r][2*b] || got1 !== ref_px[r][2*b+1]) begin
            if (frame_errors < 5)
              $display("    MISMATCH @ (%0d,%0d): exp %06x %06x got %06x %06x",
                       r, 2*b, ref_px[r][2*b], ref_px[r][2*b+1], got0, got1);
            frame_errors = frame_errors + 1;
          end

          want_user = ((r == 0) && (b == 0));
          want_last = (b == nb-1);
          if (mon_user[i] !== want_user) begin
            if (frame_errors < 5)
              $display("    TUSER @ (%0d,%0d): expected %0d got %0d",
                       r, 2*b, want_user, mon_user[i]);
            frame_errors = frame_errors + 1;
          end
          if (mon_last[i] !== want_last) begin
            if (frame_errors < 5)
              $display("    TLAST @ (%0d,%0d): expected %0d got %0d",
                       r, 2*b, want_last, mon_last[i]);
            frame_errors = frame_errors + 1;
          end
        end
      end
      errors_total = errors_total + frame_errors;
      if (frame_errors != 0)
        $display("  [%-18s] frame at beat %0d: %0d errors", name, base, frame_errors);
    end
  endtask

  // ------------------------------------------------------------------
  // Cases
  // ------------------------------------------------------------------
  // Two identical frames back to back. The second is what proves the filter
  // ends a frame cleanly: if the flush row were missing, or the line buffers
  // left in the wrong state, frame 2 is where it shows.
  task automatic run_case(input int W, input int H, input int md,
                          input int gap_pct, input int bpp,
                          input string name);
    int nb, want;
    int err_mark;
    begin
      nb   = W/2;
      want = nb * H * 2;

      if (W > MAXW || H > MAXH || want > MONDEPTH) begin
        $display("  [%-18s] SKIPPED: %0dx%0d exceeds testbench limits", name, W, H);
        errors_total = errors_total + 1;
        return;
      end

      reset_dut();
      bp_pct = bpp;

      build_source(W, H, W*7919 + H*104729 + md);
      build_golden(W, H, md);

      axil_write(ADDR_WIDTH_R,  W);
      axil_write(ADDR_HEIGHT_R, H);
      axil_write(ADDR_MODE_R,   md);

      drive_frame(W, H, gap_pct, 1'b1);
      drive_frame(W, H, gap_pct, 1'b1);

      wait_for_beats(want);
      if (wait_timeout) begin
        $display("  [%-18s] %4d x %-4d  TIMEOUT: %0d of %0d beats",
                 name, W, H, mon_cnt, want);
        errors_total = errors_total + 1;
        return;
      end

      // Nothing may follow the last beat of the second frame: an extra beat is
      // just as fatal downstream as a missing one.
      err_mark = mon_cnt;
      repeat (500) @(posedge ap_clk);
      if (mon_cnt != err_mark) begin
        $display("  [%-18s] %0d extra beats after the frame", name, mon_cnt - err_mark);
        errors_total = errors_total + 1;
      end

      err_mark = errors_total;
      check_frame(0,      W, H, name);
      check_frame(want/2, W, H, name);

      if (errors_total == err_mark)
        $display("  [%-18s] %4d x %-4d  %6d beats x2  gap %2d%%  bp %2d%%  PASS",
                 name, W, H, nb*H, gap_pct, bpp);
      else
        $display("  [%-18s] %4d x %-4d  FAIL", name, W, H);
    end
  endtask

  // The filter powers up mid-frame -- which is exactly what happens on the
  // board, where the camera is already streaming when the overlay is loaded.
  // The beats preceding the first TUSER must be discarded, not filtered.
  task automatic run_resync_case(input int W, input int H, input int md,
                                 input string name);
    int nb, want;
    begin
      nb   = W/2;
      want = nb * H;

      reset_dut();
      bp_pct = 0;

      build_source(W, H, 12345);
      build_golden(W, H, md);

      axil_write(ADDR_WIDTH_R,  W);
      axil_write(ADDR_HEIGHT_R, H);
      axil_write(ADDR_MODE_R,   md);

      drive_frame(W, H, 0, 1'b0);      // no TUSER: the tail of a frame in flight
      drive_frame(W, H, 0, 1'b1);      // a real frame

      wait_for_beats(want);
      if (wait_timeout) begin
        $display("  [%-18s] TIMEOUT: %0d of %0d beats", name, mon_cnt, want);
        errors_total = errors_total + 1;
        return;
      end

      if (mon_cnt != want) begin
        $display("  [%-18s] expected exactly %0d beats, got %0d",
                 name, want, mon_cnt);
        errors_total = errors_total + 1;
      end

      check_frame(0, W, H, name);
      if (frame_errors == 0)
        $display("  [%-18s] %4d x %-4d  unsynced frame discarded  PASS", name, W, H);
      else
        $display("  [%-18s] %4d x %-4d  FAIL", name, W, H);
    end
  endtask

  // A geometry the filter cannot honour -- an odd width, which has no
  // representation on a two-pixel bus -- must be drained rather than filtered
  // or, worse, left unread. A block that stops reading backs the CSI-2
  // subsystem up until it overflows.
  task automatic run_drain_case(input int W, input int H, input string name);
    begin
      reset_dut();
      bp_pct = 0;

      build_source(W - 1, H, 777);          // even-width source, odd-width config

      axil_write(ADDR_WIDTH_R,  W);         // odd
      axil_write(ADDR_HEIGHT_R, H);
      axil_write(ADDR_MODE_R,   MODE_SOBEL);

      drive_frame(W - 1, H, 0, 1'b1);
      repeat (500) @(posedge ap_clk);

      if (mon_cnt != 0) begin
        $display("  [%-18s] emitted %0d beats for an odd width", name, mon_cnt);
        errors_total = errors_total + 1;
      end else begin
        $display("  [%-18s] width %0d drained, nothing emitted  PASS", name, W);
      end
    end
  endtask

  // A mode written while frame 1 is in flight must not change frame 1.
  task automatic run_mode_switch_case(input int W, input int H,
                                      input int md0, input int md1,
                                      input string name);
    int nb, want, err_mark;
    begin
      nb   = W/2;
      want = nb * H * 2;

      reset_dut();
      bp_pct = 0;

      build_source(W, H, 4242);

      axil_write(ADDR_WIDTH_R,  W);
      axil_write(ADDR_HEIGHT_R, H);
      axil_write(ADDR_MODE_R,   md0);

      drive_frame_switching(W, H, H/2, md1);   // switch halfway down frame 1
      drive_frame(W, H, 0, 1'b1);

      wait_for_beats(want);
      if (wait_timeout) begin
        $display("  [%-18s] TIMEOUT: %0d of %0d beats", name, mon_cnt, want);
        errors_total = errors_total + 1;
        return;
      end

      err_mark = errors_total;

      build_golden(W, H, md0);
      check_frame(0, W, H, name);
      if (frame_errors != 0)
        $display("  [%-18s] frame 1 did not stay in mode %0d", name, md0);

      build_golden(W, H, md1);
      check_frame(want/2, W, H, name);

      if (errors_total == err_mark)
        $display("  [%-18s] %4d x %-4d  mode %0d then %0d  PASS", name, W, H, md0, md1);
      else
        $display("  [%-18s] %4d x %-4d  FAIL", name, W, H);
    end
  endtask

  task automatic reset_dut();
    begin
      ap_rst_n  <= 1'b0;
      in_tvalid <= 1'b0;
      in_tuser  <= 1'b0;
      in_tlast  <= 1'b0;
      mon_cnt    = 0;
      repeat (8) @(posedge ap_clk);
      ap_rst_n <= 1'b1;
      repeat (4) @(posedge ap_clk);
    end
  endtask

  // ------------------------------------------------------------------
  // Test sequence
  // ------------------------------------------------------------------
  initial begin
    ctrl_awvalid = 0; ctrl_wvalid = 0; ctrl_bready = 0;
    ctrl_arvalid = 0; ctrl_rready = 0; ctrl_wstrb  = 4'hF;
    ctrl_awaddr  = 0; ctrl_araddr = 0; ctrl_wdata  = 0;
    in_tdata     = 0; in_tvalid   = 0; in_tuser    = 0; in_tlast = 0;

    repeat (10) @(posedge ap_clk);

    $display("========================================================");
    $display(" Streaming Sobel filter -- checking against the golden model");
    $display("========================================================");

    run_case( 64, 48, MODE_GRAY,   0,  0, "GRAY 64x48");
    run_case( 64, 48, MODE_SOBEL,  0,  0, "SOBEL 64x48");
    run_case( 64, 48, MODE_INVERT, 0,  0, "INVERT 64x48");
    run_case( 64, 48, MODE_COLOR,  0,  0, "COLOR 64x48");

    // The same geometry under stalls, from both directions at once.
    run_case( 64, 48, MODE_SOBEL, 30, 30, "SOBEL stalled");
    run_case( 64, 48, MODE_COLOR, 30, 30, "COLOR stalled");

    // Degenerate geometries. A window filter breaks on these long err_mark it
    // breaks on a real frame: one line means every output row is a border row,
    // and one beat per line means both windows in a beat sit against an edge.
    run_case(  2,  2, MODE_SOBEL, 0,  0, "SOBEL 2x2");
    run_case(  2, 16, MODE_SOBEL, 0,  0, "SOBEL 2x16");
    run_case( 16,  1, MODE_SOBEL, 0,  0, "SOBEL 16x1");
    run_case( 16,  3, MODE_SOBEL, 0,  0, "SOBEL 16x3");
    run_case(  6,  5, MODE_GRAY,  0, 20, "GRAY 6x5");

    // Mode 7 is not a defined mode. The C tests == GRAY, == INVERT, == COLOR
    // and falls through to Sobel, so the RTL has to compare the whole 32-bit
    // word rather than the low bits.
    run_case( 32, 24, 7,          0,  0, "MODE7->SOBEL");

    // Wide enough to exercise the line buffers at a realistic depth.
    run_case(320,  8, MODE_SOBEL, 0, 15, "SOBEL 320x8");

    // Narrow enough that the line-buffer write for a row has not landed before
    // the row below reads it back, unless the design accounts for it. This is
    // the case that caught the HLS false-dependence pragma.
    run_case(  6,  5, MODE_SOBEL, 0,  0, "SOBEL 6x5");
    run_case( 12,  6, MODE_GRAY,  0,  0, "GRAY 12x6");

    run_resync_case(32, 12, MODE_SOBEL, "RESYNC");
    run_drain_case(15, 4, "ODD WIDTH");
    run_mode_switch_case(32, 12, MODE_SOBEL, MODE_GRAY,  "SWITCH sobel->gray");
    run_mode_switch_case(32, 12, MODE_GRAY,  MODE_COLOR, "SWITCH gray->color");

    // The register file has to read back, or a notebook cannot tell what the
    // hardware thinks it is configured for.
    axil_write(ADDR_WIDTH_R, 32'd1280);
    axil_read(ADDR_WIDTH_R);
    if (axil_rd_data !== 32'd1280) begin
      $display("  [%-18s] img_width read back as %0d, expected 1280",
               "REGISTERS", axil_rd_data);
      errors_total = errors_total + 1;
    end
    axil_write(ADDR_HEIGHT_R, 32'd720);
    axil_read(ADDR_HEIGHT_R);
    if (axil_rd_data !== 32'd720) begin
      $display("  [%-18s] img_height read back as %0d, expected 720",
               "REGISTERS", axil_rd_data);
      errors_total = errors_total + 1;
    end
    axil_read(ADDR_MODE_R);
    $display("  [%-18s] readback ok (mode = %0d)", "REGISTERS", axil_rd_data);

    $display("========================================================");
    if (errors_total == 0) $display(" TEST PASSED");
    else                   $display(" TEST FAILED -- %0d errors", errors_total);
    $display("========================================================");
    $finish;
  end

  initial begin
    #200ms;
    $display("GLOBAL TIMEOUT");
    $finish;
  end

endmodule
