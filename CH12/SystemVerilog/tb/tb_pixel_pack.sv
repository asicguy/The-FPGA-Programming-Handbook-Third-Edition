// tb_pixel_pack.sv
// ------------------------------------
// Self-checking testbench for the CH12 pixel packer
// ------------------------------------
// Author : Frank Bruno
//
// One testbench, two DUTs. It instantiates `pixel_pack` by name, so the
// SystemVerilog module and the VHDL entity both bind to it directly -- xsim
// matches VHDL port names case-insensitively, which is the same trick
// VHDL/sim.sh already uses for the filter. No wrapper is needed here because,
// unlike the filter, there is no HLS variant to normalise against: project 3's
// `hls` build keeps PYNQ's prebuilt IP and never sees this file.
//
// The golden model is the 32bpp branch of PYNQ's HLS source, transcribed:
//
//     AUP-ZU3/pynq/boards/ip/hls/pixel_pack_2/pixel_pack.cpp, case V_32
//
//         data(23, 0)  = in.data(23, 0);     data(31, 24) = alpha;
//         data(55, 32) = in.data(47, 24);    data(63, 56) = alpha;
//         out.last = in.last;  out.user = in.user;
//
// One beat in, one beat out. That is the whole function, and the reason it is
// worth a testbench anyway is the two things around it: TUSER marks
// start-of-frame and TLAST marks end-of-line, and the VDMA tears the picture
// if either lands on the wrong beat. Backpressure is randomised on both
// streams so a skid buffer that drops or duplicates a beat under stall is
// caught here rather than as a sheared frame on a monitor.
`timescale 1ns/10ps
module tb_pixel_pack;

  localparam CLK_PERIOD = 5.0;

  localparam [4:0] ADDR_MODE  = 5'h10;
  localparam [4:0] ADDR_ALPHA = 5'h18;
  localparam [31:0] MODE_32BPP = 32'd1;

  logic ap_clk = 1'b0;
  logic ap_rst_n = 1'b0;
  always #(CLK_PERIOD/2.0) ap_clk = ~ap_clk;

  // ------------------------------------------------------------------
  // DUT signals
  // ------------------------------------------------------------------
  logic [4:0]  ctrl_awaddr;  logic ctrl_awvalid, ctrl_awready;
  logic [31:0] ctrl_wdata;   logic [3:0] ctrl_wstrb;
  logic        ctrl_wvalid,  ctrl_wready;
  logic [1:0]  ctrl_bresp;   logic ctrl_bvalid, ctrl_bready;
  logic [4:0]  ctrl_araddr;  logic ctrl_arvalid, ctrl_arready;
  logic [31:0] ctrl_rdata;   logic [1:0] ctrl_rresp;
  logic        ctrl_rvalid,  ctrl_rready;

  logic [47:0] in_tdata;  logic in_tvalid, in_tready;
  logic [5:0]  in_tkeep,  in_tstrb;
  logic [0:0]  in_tuser,  in_tlast;

  logic [63:0] out_tdata; logic out_tvalid, out_tready;
  logic [7:0]  out_tkeep, out_tstrb;
  logic [0:0]  out_tuser, out_tlast;

  pixel_pack dut
    (.ap_clk (ap_clk), .ap_rst_n (ap_rst_n),
     .s_axi_control_awaddr (ctrl_awaddr), .s_axi_control_awvalid (ctrl_awvalid),
     .s_axi_control_awready (ctrl_awready), .s_axi_control_wdata (ctrl_wdata),
     .s_axi_control_wstrb (ctrl_wstrb), .s_axi_control_wvalid (ctrl_wvalid),
     .s_axi_control_wready (ctrl_wready), .s_axi_control_bresp (ctrl_bresp),
     .s_axi_control_bvalid (ctrl_bvalid), .s_axi_control_bready (ctrl_bready),
     .s_axi_control_araddr (ctrl_araddr), .s_axi_control_arvalid (ctrl_arvalid),
     .s_axi_control_arready (ctrl_arready), .s_axi_control_rdata (ctrl_rdata),
     .s_axi_control_rresp (ctrl_rresp), .s_axi_control_rvalid (ctrl_rvalid),
     .s_axi_control_rready (ctrl_rready),
     .stream_in_48_tdata (in_tdata),   .stream_in_48_tvalid (in_tvalid),
     .stream_in_48_tready (in_tready), .stream_in_48_tkeep (in_tkeep),
     .stream_in_48_tstrb (in_tstrb),   .stream_in_48_tuser (in_tuser),
     .stream_in_48_tlast (in_tlast),
     .stream_out_64_tdata (out_tdata),   .stream_out_64_tvalid (out_tvalid),
     .stream_out_64_tready (out_tready), .stream_out_64_tkeep (out_tkeep),
     .stream_out_64_tstrb (out_tstrb),   .stream_out_64_tuser (out_tuser),
     .stream_out_64_tlast (out_tlast));

  // ------------------------------------------------------------------
  // Scoreboard
  // ------------------------------------------------------------------
  logic [63:0] exp_data [$];
  logic        exp_user [$];
  logic        exp_last [$];

  // Counters are split by owner. The streaming checker runs in an always_ff
  // and the register checks run in tasks, so sharing one counter between them
  // would be two processes writing the same variable -- a race that shows up
  // as a test that passes for the wrong reason.
  // The three the checker owns are initialised where they are declared: an
  // initial block clearing them would be a second procedural driver, which
  // xelab rejects outright.
  int beats_out = 0;
  int stream_errors = 0;
  int stream_checks = 0;
  int beats_in;
  int reg_errors, reg_checks;
  int backpressure;                 // percent chance the consumer stalls
  bit draining;
  logic out_tready_r;

  // The alpha the model expects, mirrored from what was written over AXI4-Lite.
  logic [7:0] alpha_model;

  function automatic [23:0] pix(input int idx);
    // Deterministic and cheap: adjacent indices differ in every byte, so a
    // swapped pixel pair or an off-by-one beat shows up as a data mismatch
    // rather than as a passing test.
    pix = 24'(idx) ^ 24'h5A_5A_5A;
  endfunction

  // Scratch for the checker. Declared here rather than as automatics inside
  // the always_ff so the counters can use blocking assignment throughout.
  logic [63:0] want_data;
  logic        want_user, want_last;

  // ------------------------------------------------------------------
  // Consumer: checks every beat as it leaves
  // ------------------------------------------------------------------
  // Registered, so the stall pattern is one stable decision per cycle rather
  // than a continuous assign re-rolling $urandom on every input transition.
  assign out_tready = out_tready_r;

  always_ff @(posedge ap_clk) begin
    if (!ap_rst_n)
      out_tready_r <= 1'b0;
    else
      out_tready_r <= draining &&
                      ((backpressure == 0) || (($urandom % 100) >= backpressure));
  end

  always_ff @(posedge ap_clk) begin
    if (ap_rst_n && out_tvalid && out_tready) begin
      beats_out = beats_out + 1;
      if (exp_data.size() == 0) begin
        $display("  ERROR beat %0d: an output beat with nothing expected",
                 beats_out);
        stream_errors = stream_errors + 1;
      end else begin
        want_data = exp_data.pop_front();
        want_user = exp_user.pop_front();
        want_last = exp_last.pop_front();
        stream_checks = stream_checks + 1;
        if (out_tdata !== want_data) begin
          $display("  ERROR beat %0d: TDATA %016h, expected %016h",
                   beats_out, out_tdata, want_data);
          stream_errors = stream_errors + 1;
        end
        if (out_tuser !== want_user) begin
          $display("  ERROR beat %0d: TUSER %0b, expected %0b (start of frame)",
                   beats_out, out_tuser, want_user);
          stream_errors = stream_errors + 1;
        end
        if (out_tlast !== want_last) begin
          $display("  ERROR beat %0d: TLAST %0b, expected %0b (end of line)",
                   beats_out, out_tlast, want_last);
          stream_errors = stream_errors + 1;
        end
        if (out_tkeep !== 8'hFF) begin
          $display("  ERROR beat %0d: TKEEP %02h, expected ff",
                   beats_out, out_tkeep);
          stream_errors = stream_errors + 1;
        end
        if (out_tstrb !== 8'hFF) begin
          $display("  ERROR beat %0d: TSTRB %02h, expected ff",
                   beats_out, out_tstrb);
          stream_errors = stream_errors + 1;
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // AXI4-Lite
  // ------------------------------------------------------------------
  task automatic axil_write(input [4:0] addr, input [31:0] data);
    begin
      @(posedge ap_clk);
      ctrl_awaddr <= addr; ctrl_awvalid <= 1'b1;
      ctrl_wdata  <= data; ctrl_wstrb   <= 4'hF; ctrl_wvalid <= 1'b1;
      ctrl_bready <= 1'b1;
      forever begin
        @(posedge ap_clk);
        if (ctrl_awvalid && ctrl_awready) ctrl_awvalid <= 1'b0;
        if (ctrl_wvalid  && ctrl_wready)  ctrl_wvalid  <= 1'b0;
        if (ctrl_bvalid  && ctrl_bready)  break;
      end
      @(posedge ap_clk);
      ctrl_bready <= 1'b0;
    end
  endtask

  logic [31:0] read_data;
  task automatic axil_read(input [4:0] addr);
    begin
      @(posedge ap_clk);
      ctrl_araddr <= addr; ctrl_arvalid <= 1'b1; ctrl_rready <= 1'b1;
      forever begin
        @(posedge ap_clk);
        if (ctrl_arvalid && ctrl_arready) ctrl_arvalid <= 1'b0;
        if (ctrl_rvalid && ctrl_rready) begin
          read_data = ctrl_rdata;
          break;
        end
      end
      @(posedge ap_clk);
      ctrl_rready <= 1'b0;
    end
  endtask

  task automatic check_reg(input string name, input [31:0] got,
                           input [31:0] want);
    begin
      reg_checks++;
      if (got !== want) begin
        $display("  ERROR %s reads %08h, expected %08h", name, got, want);
        reg_errors++;
      end
    end
  endtask

  // ------------------------------------------------------------------
  // One frame, driven the way the camera hierarchy drives it: two pixels per
  // beat, TUSER on the first beat of the frame, TLAST on the last beat of
  // every line.
  // ------------------------------------------------------------------
  task automatic run_frame(input int W, input int H, input [7:0] alpha,
                           input int bp, input string label);
    automatic int beats_per_line = W / 2;
    automatic int idx = 0;
    automatic int r, c;
    automatic int base_out = beats_out;
    automatic logic [23:0] p0, p1;
    begin
      backpressure = bp;
      beats_in = 0;
      alpha_model = alpha;
      axil_write(ADDR_ALPHA, {24'd0, alpha});
      draining = 1'b1;

      for (r = 0; r < H; r++) begin
        for (c = 0; c < beats_per_line; c++) begin
          p0 = pix(idx * 2);
          p1 = pix(idx * 2 + 1);
          // expectation first, so a beat the DUT emits early is still checked
          exp_data.push_back({alpha_model, p1, alpha_model, p0});
          exp_user.push_back((r == 0) && (c == 0));
          exp_last.push_back(c == beats_per_line - 1);

          // Idle gaps on the producer as well: the camera's upstream stalls
          // whenever the CSI-2 receiver has nothing, and a packer that only
          // works back to back would pass a test that never pauses.
          while (bp != 0 && ($urandom % 100) < bp) begin
            in_tvalid <= 1'b0;
            @(posedge ap_clk);
          end

          in_tdata  <= {p1, p0};
          in_tuser  <= (r == 0) && (c == 0);
          in_tlast  <= (c == beats_per_line - 1);
          in_tkeep  <= 6'h3F;
          in_tstrb  <= 6'h3F;
          in_tvalid <= 1'b1;
          @(posedge ap_clk);
          while (!in_tready) @(posedge ap_clk);
          beats_in++;
          idx++;
        end
      end
      in_tvalid <= 1'b0;

      // Let the pipeline drain before judging the beat count.
      repeat (200) @(posedge ap_clk);
      while (exp_data.size() != 0) @(posedge ap_clk);
      repeat (20) @(posedge ap_clk);

      reg_checks++;
      if ((beats_out - base_out) != beats_in) begin
        $display("  ERROR %s: %0d beats in, %0d beats out", label,
                 beats_in, beats_out - base_out);
        reg_errors++;
      end
      $display("  [%-22s] %0dx%0d  alpha=%02h  bp=%0d%%  %0d beats",
               label, W, H, alpha, bp, beats_out - base_out);
      draining = 1'b0;
    end
  endtask

  // ------------------------------------------------------------------
  initial begin
    ctrl_awvalid = 0; ctrl_wvalid = 0; ctrl_bready = 0;
    ctrl_arvalid = 0; ctrl_rready = 0;
    ctrl_awaddr = 0; ctrl_wdata = 0; ctrl_wstrb = 0; ctrl_araddr = 0;
    in_tvalid = 0; in_tdata = 0; in_tuser = 0; in_tlast = 0;
    in_tkeep = 6'h3F; in_tstrb = 6'h3F;
    beats_in = 0;
    reg_errors = 0; reg_checks = 0;
    backpressure = 0; draining = 0; alpha_model = 8'h00;

    repeat (10) @(posedge ap_clk);
    ap_rst_n = 1'b1;
    repeat (5) @(posedge ap_clk);

    $display("tb_pixel_pack");

    // The reset value matters: sw/pixel_packer.py reads this register back and
    // treats anything but 1 as proof it is bound to the wrong IP, so a packer
    // that has never been written to has to already report 32bpp.
    axil_read(ADDR_MODE);
    check_reg("mode at reset", read_data, MODE_32BPP);
    axil_read(ADDR_ALPHA);
    check_reg("alpha at reset", read_data, 32'd0);

    axil_write(ADDR_ALPHA, 32'h0000_00FF);
    axil_read(ADDR_ALPHA);
    check_reg("alpha after write", read_data, 32'h0000_00FF);

    axil_write(ADDR_MODE, MODE_32BPP);
    axil_read(ADDR_MODE);
    check_reg("mode after write", read_data, MODE_32BPP);

    // alpha = 0 is what the camera actually runs with, since PYNQ's driver
    // never writes the register and the RTL resets it to zero.
    run_frame(64, 48, 8'h00, 0,  "64x48 no stall");
    run_frame(64, 48, 8'hFF, 30, "64x48 stalled");
    run_frame(64, 48, 8'h80, 60, "64x48 heavy stall");
    // Odd geometry: one beat per line, so TLAST is set on every beat and a
    // packer that only marks the last beat of a burst gets it wrong.
    run_frame(2, 8, 8'h00, 30, "2x8 one beat a line");
    // The real thing.
    run_frame(1280, 720, 8'h00, 0, "1280x720 no stall");
    run_frame(1280, 720, 8'h00, 20, "1280x720 stalled");

    $display("");
    if (stream_errors + reg_errors == 0)
      $display("PASS -- %0d beat checks, %0d register checks, 0 errors",
               stream_checks, reg_checks);
    else
      $display("FAIL -- %0d errors", stream_errors + reg_errors);
    $finish;
  end

  initial begin
    #50ms;
    $display("FAIL -- testbench timed out");
    $finish;
  end

endmodule
