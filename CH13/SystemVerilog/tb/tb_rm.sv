// tb_rm.sv
// ------------------------------------
// One testbench, every reconfigurable module, against the golden model
// ------------------------------------
// Author : Frank Bruno
//
// docs/ch13-plan.md 6 step 3: one RTL testbench, every RM. It binds to
// `rm_dut` (tb/rm_dut.sv), which selects the RM at elaboration:
//
//     ./sim.sh --rm passthrough | sobel | blur | threshold
//
// Each RM is checked the way software will drive it -- writing the argument
// registers over AXI4-Lite, polling CTRL for ap_done, and comparing the frame
// the RM actually wrote into a behavioural memory against a golden model
// transcribed from sw/rm_ref.py. There is no hierarchical peeking into the
// DUT, which is what lets one testbench serve four different pieces of
// hardware.
//
// The destination is POISONED with 0xDEADBEEF before every case, and the word
// one past the frame is poisoned too. An accelerator that writes too few words
// leaves poison behind and fails the compare; one that writes too many is
// equally fatal downstream and would otherwise pass, so the guard word is
// checked separately.
//
// Odd and degenerate frame sizes are not padding. The windowed RMs iterate
// (H+1) x (W+1) and produce on a different condition from the one they consume
// on, so an off-by-one in the iteration space does not make a wrong picture --
// it unbalances the shell's two FIFOs and DEADLOCKS. 1x1, 2x2, 3x3, 1x16 and
// 16x1 are where that shows up.
//
// The memory model and the AXI4-Lite master tasks below are CH12's, unchanged.
`timescale 1ns/10ps
module tb_rm;

  localparam CLK_PERIOD = 5.0;      // 200 MHz
  // The model masks addresses down to MEMW words, so SRC and DST must not
  // alias once masked. With too small a model DST wraps onto the source and a
  // large frame quietly overwrites its own input as it runs.
  localparam MEMW       = 1 << 22;  // 4M 32-bit words
  localparam SRC_BASE   = 64'h0000_0000_0001_0000;
  localparam DST_BASE   = 64'h0000_0000_0080_0000;

  // The sobel RM's modes. The other RMs read `mode` differently or not at all,
  // which is the chapter's point: the register map does not change across a
  // swap, but its MEANING does.
  localparam MODE_GRAY   = 0;
  localparam MODE_SOBEL  = 1;
  localparam MODE_INVERT = 2;
  localparam MODE_COLOR  = 3;

  // Which RM is in the socket, and what it must report at 0x3C.
`ifdef RM_PASSTHROUGH
  localparam [31:0] KERNEL_ID = 32'hA5A5_0000;
  localparam string RM_NAME   = "passthrough";
`elsif RM_SOBEL
  localparam [31:0] KERNEL_ID = 32'hA5A5_0001;
  localparam string RM_NAME   = "sobel";
`elsif RM_BLUR
  localparam [31:0] KERNEL_ID = 32'hA5A5_0002;
  localparam string RM_NAME   = "blur";
`elsif RM_THRESHOLD
  localparam [31:0] KERNEL_ID = 32'hA5A5_0003;
  localparam string RM_NAME   = "threshold";
`else
  localparam [31:0] KERNEL_ID = 32'hDEAD_DEAD;
  localparam string RM_NAME   = "UNDEFINED";
`endif

  logic ap_clk = 1'b0;
  logic ap_rst_n = 1'b0;
  always #(CLK_PERIOD/2.0) ap_clk = ~ap_clk;

  // ------------------------------------------------------------------
  // DUT signals
  // ------------------------------------------------------------------
  logic [5:0]  ctrl_awaddr;  logic ctrl_awvalid, ctrl_awready;
  logic [31:0] ctrl_wdata;   logic [3:0] ctrl_wstrb;
  logic        ctrl_wvalid,  ctrl_wready;
  logic [1:0]  ctrl_bresp;   logic ctrl_bvalid, ctrl_bready;
  logic [5:0]  ctrl_araddr;  logic ctrl_arvalid, ctrl_arready;
  logic [31:0] ctrl_rdata;   logic [1:0] ctrl_rresp;
  logic        ctrl_rvalid,  ctrl_rready;
  logic        interrupt;
  logic        heartbeat;

  logic [63:0] g0_araddr; logic [7:0] g0_arlen;
  logic [2:0]  g0_arsize; logic [1:0] g0_arburst;
  logic        g0_arvalid, g0_arready;
  logic [31:0] g0_rdata;  logic [1:0] g0_rresp;
  logic        g0_rlast,  g0_rvalid,  g0_rready;

  logic [63:0] g1_awaddr; logic [7:0] g1_awlen;
  logic [2:0]  g1_awsize; logic [1:0] g1_awburst;
  logic        g1_awvalid, g1_awready;
  logic [31:0] g1_wdata;  logic [3:0] g1_wstrb;
  logic        g1_wlast,  g1_wvalid,  g1_wready;
  logic [1:0]  g1_bresp;
  logic        g1_bvalid, g1_bready;

  rm_dut dut
    (.ap_clk (ap_clk), .ap_rst_n (ap_rst_n), .interrupt (interrupt),
     .heartbeat (heartbeat),
     .s_axi_control_awaddr (ctrl_awaddr), .s_axi_control_awvalid (ctrl_awvalid),
     .s_axi_control_awready (ctrl_awready), .s_axi_control_wdata (ctrl_wdata),
     .s_axi_control_wstrb (ctrl_wstrb), .s_axi_control_wvalid (ctrl_wvalid),
     .s_axi_control_wready (ctrl_wready), .s_axi_control_bresp (ctrl_bresp),
     .s_axi_control_bvalid (ctrl_bvalid), .s_axi_control_bready (ctrl_bready),
     .s_axi_control_araddr (ctrl_araddr), .s_axi_control_arvalid (ctrl_arvalid),
     .s_axi_control_arready (ctrl_arready), .s_axi_control_rdata (ctrl_rdata),
     .s_axi_control_rresp (ctrl_rresp), .s_axi_control_rvalid (ctrl_rvalid),
     .s_axi_control_rready (ctrl_rready),
     .m_axi_gmem0_araddr (g0_araddr), .m_axi_gmem0_arlen (g0_arlen),
     .m_axi_gmem0_arsize (g0_arsize), .m_axi_gmem0_arburst (g0_arburst),
     .m_axi_gmem0_arvalid (g0_arvalid), .m_axi_gmem0_arready (g0_arready),
     .m_axi_gmem0_rdata (g0_rdata), .m_axi_gmem0_rresp (g0_rresp),
     .m_axi_gmem0_rlast (g0_rlast), .m_axi_gmem0_rvalid (g0_rvalid),
     .m_axi_gmem0_rready (g0_rready),
     .m_axi_gmem1_awaddr (g1_awaddr), .m_axi_gmem1_awlen (g1_awlen),
     .m_axi_gmem1_awsize (g1_awsize), .m_axi_gmem1_awburst (g1_awburst),
     .m_axi_gmem1_awvalid (g1_awvalid), .m_axi_gmem1_awready (g1_awready),
     .m_axi_gmem1_wdata (g1_wdata), .m_axi_gmem1_wstrb (g1_wstrb),
     .m_axi_gmem1_wlast (g1_wlast), .m_axi_gmem1_wvalid (g1_wvalid),
     .m_axi_gmem1_wready (g1_wready), .m_axi_gmem1_bresp (g1_bresp),
     .m_axi_gmem1_bvalid (g1_bvalid), .m_axi_gmem1_bready (g1_bready));

  // ------------------------------------------------------------------
  // Shared behavioural memory
  // ------------------------------------------------------------------
  logic [31:0] mem [MEMW];

  function automatic int unsigned waddr(input logic [63:0] byte_addr);
    waddr = int'((byte_addr >> 2) & (MEMW-1));
  endfunction

  // ---- gmem0: read slave ----
  // Everything is declared at module scope. Declarations inside a forever
  // block upset the xsim kernel here, so keep the process bodies flat.
  integer g0_seed = 32'h1234_5678;
  reg [63:0] g0_a;
  integer    g0_len;
  integer    g0_i;

  initial begin
    g0_arready = 1'b0;
    g0_rvalid  = 1'b0;
    g0_rlast   = 1'b0;
    g0_rresp   = 2'b00;
    g0_rdata   = 32'd0;
    @(posedge ap_rst_n);
    forever begin
      g0_arready <= 1'b1;
      @(posedge ap_clk);
      while (!(g0_arvalid && g0_arready)) @(posedge ap_clk);
      g0_a   = g0_araddr;
      g0_len = g0_arlen + 1;
      g0_arready <= 1'b0;
      for (g0_i = 0; g0_i < g0_len; g0_i = g0_i + 1) begin
        while (($random(g0_seed) % 5) == 0) @(posedge ap_clk);
        g0_rdata  <= mem[waddr(g0_a) + g0_i];
        g0_rvalid <= 1'b1;
        g0_rlast  <= (g0_i == g0_len-1);
        @(posedge ap_clk);
        while (!g0_rready) @(posedge ap_clk);
        g0_rvalid <= 1'b0;
        g0_rlast  <= 1'b0;
      end
    end
  end

  // ---- gmem1: write slave ----
  integer g1_seed = 32'h89ab_cdef;
  reg [63:0] g1_a;
  integer    g1_i;
  reg        g1_last_seen;

  initial begin
    g1_awready = 1'b0;
    g1_wready  = 1'b0;
    g1_bvalid  = 1'b0;
    g1_bresp   = 2'b00;
    @(posedge ap_rst_n);
    forever begin
      g1_awready <= 1'b1;
      @(posedge ap_clk);
      while (!(g1_awvalid && g1_awready)) @(posedge ap_clk);
      g1_a = g1_awaddr;
      g1_awready <= 1'b0;
      g1_i = 0;
      g1_last_seen = 1'b0;
      while (!g1_last_seen) begin
        g1_wready <= (($random(g1_seed) % 4) != 0);
        @(posedge ap_clk);
        if (g1_wvalid && g1_wready) begin
          mem[waddr(g1_a) + g1_i] = g1_wdata;
          g1_i = g1_i + 1;
          if (g1_wlast) g1_last_seen = 1'b1;
        end
      end
      g1_wready <= 1'b0;
      g1_bvalid <= 1'b1;
      @(posedge ap_clk);
      while (!g1_bready) @(posedge ap_clk);
      g1_bvalid <= 1'b0;
    end
  end

  // ------------------------------------------------------------------
  // AXI4-Lite master tasks
  // ------------------------------------------------------------------
  task automatic axil_write(input [5:0] addr, input [31:0] data);
    begin
      @(posedge ap_clk);
      ctrl_awaddr  <= addr; ctrl_awvalid <= 1'b1;
      ctrl_wdata   <= data; ctrl_wstrb   <= 4'hF; ctrl_wvalid <= 1'b1;
      ctrl_bready  <= 1'b1;
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
  // task takes the xsim kernel down here, so the value comes back this way.
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
  // Golden model -- a transcription of sw/rm_ref.py, which is the definition
  // of what each kernel computes.
  // ------------------------------------------------------------------
  // Fixed-size rather than dynamic: repeatedly re-allocating a dynamic array
  // per test case is what the xsim kernel could not survive.
  localparam MAXPX = 1 << 16;          // 65536 pixels, covers every case below
  logic [31:0] src_img [MAXPX];
  logic [31:0] ref_img [MAXPX];
  logic [7:0]  gray_img [MAXPX];

  // Pixels are B,G,R,A from the LSB up, so the weights are ordered to match.
  function automatic logic [7:0] luma8(input [31:0] px);
    logic [17:0] s;
    begin
      s = 18'd29 * px[7:0] + 18'd150 * px[15:8] + 18'd77 * px[23:16];
      luma8 = s[15:8];
    end
  endfunction

  // One 3x3 Gaussian tap on one channel. `sh` picks the byte: 0 = B, 8 = G,
  // 16 = R. Weights [1 2 1; 2 4 2; 1 2 1], divisor 16, truncating -- and
  // truncating on purpose, because rm_ref.py truncates and rounding here would
  // disagree by one LSB on most pixels.
  function automatic logic [7:0] gauss_tap(input int W, input int r, input int c,
                                           input int sh);
    int acc;
    begin
      acc = ((src_img[(r-1)*W + c-1] >> sh) & 32'hFF)
          + ((src_img[(r-1)*W + c  ] >> sh) & 32'hFF) * 2
          + ((src_img[(r-1)*W + c+1] >> sh) & 32'hFF)
          + ((src_img[( r )*W + c-1] >> sh) & 32'hFF) * 2
          + ((src_img[( r )*W + c  ] >> sh) & 32'hFF) * 4
          + ((src_img[( r )*W + c+1] >> sh) & 32'hFF) * 2
          + ((src_img[(r+1)*W + c-1] >> sh) & 32'hFF)
          + ((src_img[(r+1)*W + c  ] >> sh) & 32'hFF) * 2
          + ((src_img[(r+1)*W + c+1] >> sh) & 32'hFF);
      gauss_tap = 8'((acc >> 4) & 32'hFF);
    end
  endfunction

  task automatic build_golden(input int W, input int H, input int md);
    int r, c, i;
    int p00,p01,p02,p10,p12,p20,p21,p22, gx, gy, m;
    logic [7:0] v, bb, gg, rr;
    begin
`ifdef RM_PASSTHROUGH
      // The identity function, alpha included: this is a copy, not a filter.
      for (i = 0; i < W*H; i++) ref_img[i] = src_img[i];

`elsif RM_THRESHOLD
      // A point operation, so there is no border: every pixel including the
      // frame edge gets a real result. `mode` is the LEVEL, not a menu.
      for (i = 0; i < W*H; i++) begin
        v = (luma8(src_img[i]) >= md[7:0]) ? 8'd255 : 8'd0;
        ref_img[i] = {8'hFF, v, v, v};
      end

`elsif RM_BLUR
      // Windowed, so the border is opaque black -- the convention every
      // windowed kernel in this book shares. Note ALPHA IS OPAQUE on the
      // border too: leaving it transparent would be a black screen on the
      // DisplayPort rather than a subtle bug.
      for (r = 0; r < H; r++) begin
        for (c = 0; c < W; c++) begin
          if (r == 0 || r == H-1 || c == 0 || c == W-1)
            ref_img[r*W + c] = {8'hFF, 24'd0};
          else begin
            bb = gauss_tap(W, r, c, 0);
            gg = gauss_tap(W, r, c, 8);
            rr = gauss_tap(W, r, c, 16);
            ref_img[r*W + c] = {8'hFF, rr, gg, bb};
          end
        end
      end

`else
      // RM_SOBEL -- CH12's filter unchanged.
      if (md == MODE_COLOR) begin
        for (i = 0; i < W*H; i++) ref_img[i] = src_img[i];
        return;
      end
      for (i = 0; i < W*H; i++) gray_img[i] = luma8(src_img[i]);
      for (r = 0; r < H; r++) begin
        for (c = 0; c < W; c++) begin
          if (md == MODE_GRAY) v = gray_img[r*W + c];
          else if (md == MODE_INVERT) v = 8'd255 - gray_img[r*W + c];
          else begin
            if (r == 0 || r == H-1 || c == 0 || c == W-1) v = 8'd0;
            else begin
              p00 = gray_img[(r-1)*W + c-1]; p01 = gray_img[(r-1)*W + c]; p02 = gray_img[(r-1)*W + c+1];
              p10 = gray_img[( r )*W + c-1];                 p12 = gray_img[( r )*W + c+1];
              p20 = gray_img[(r+1)*W + c-1]; p21 = gray_img[(r+1)*W + c]; p22 = gray_img[(r+1)*W + c+1];
              gx  = (p02 + 2*p12 + p22) - (p00 + 2*p10 + p20);
              gy  = (p20 + 2*p21 + p22) - (p00 + 2*p01 + p02);
              m   = (gx < 0 ? -gx : gx) + (gy < 0 ? -gy : gy);
              v   = (m > 255) ? 8'd255 : m[7:0];
            end
          end
          ref_img[r*W + c] = {8'hFF, v, v, v};
        end
      end
`endif
    end
  endtask

  // ------------------------------------------------------------------
  // Test sequence
  // ------------------------------------------------------------------
  int errors_total = 0;

  task automatic run_case(input int W, input int H, input int md,
                          input string name);
    int r, c, i, bad;
    logic [31:0] rd;
    logic [7:0] R, G, B;
    int timed_out;
    int cycles;
    int src_w, dst_w;
    begin
      if (W*H > MAXPX) begin
        $display("  [%-18s] SKIPPED: %0d px exceeds MAXPX %0d", name, W*H, MAXPX);
        errors_total++;
        return;
      end
      // resolve the model addresses once; calling an automatic function inside
      // the compare loop is what the xsim kernel choked on
      src_w = waddr(SRC_BASE);
      dst_w = waddr(DST_BASE);

      // The same synthetic scene the C testbench builds: a two-axis gradient
      // with a hard-edged bright square, flat red, so a swapped B and R would
      // change the answer rather than going unnoticed.
      for (r = 0; r < H; r++) begin
        for (c = 0; c < W; c++) begin
          B = (W > 1) ? ((c * 255) / (W-1)) : 8'd0;
          G = (H > 1) ? ((r * 255) / (H-1)) : 8'd0;
          R = 8'd64;
          if (r > H/4 && r < 3*H/4 && c > W/4 && c < 3*W/4) begin
            B = 8'd240; G = 8'd240; R = 8'd240;
          end
          src_img[r*W + c] = {8'hFF, R, G, B};
        end
      end

      for (i = 0; i < W*H; i++) begin
        mem[src_w + i] = src_img[i];
        mem[dst_w + i] = 32'hDEAD_BEEF;   // poison
      end
      // One word beyond the frame, poisoned too: it is the guard the overrun
      // check below reads. Without poisoning it that check would be looking at
      // whatever the previous case happened to leave there.
      mem[dst_w + W*H] = 32'hDEAD_BEEF;

      build_golden(W, H, md);

      axil_write(6'h10, SRC_BASE[31:0]);
      axil_write(6'h14, SRC_BASE[63:32]);
      axil_write(6'h1C, DST_BASE[31:0]);
      axil_write(6'h20, DST_BASE[63:32]);
      axil_write(6'h28, W);
      axil_write(6'h30, H);
      axil_write(6'h38, md);

      axil_write(6'h00, 32'h1);          // ap_start

      // Poll CTRL for ap_done exactly the way the PYNQ driver does. No
      // hierarchical peeking into the DUT, so this same testbench binds
      // against the SystemVerilog, the VHDL or the HLS implementation.
      timed_out = 0;
      cycles    = 0;
      rd        = 32'd0;
      while (!rd[1] && (cycles < 200000)) begin
        axil_read(6'h00);
        rd     = axil_rd_data;
        cycles = cycles + 1;
      end
      if (!rd[1]) begin
        $display("  [%-18s] TIMEOUT waiting for ap_done after %0d polls",
                 name, cycles);
        timed_out = 1;
      end else begin
        // ap_done is clear-on-read, so a second read must come back clear
        axil_read(6'h00);
        if (axil_rd_data[1]) begin
          $display("  [%-18s] AP_DONE did not clear on read (rd=%08x)",
                   name, axil_rd_data);
          errors_total++;
        end
      end

      bad = 0;
      if (timed_out) begin
        $display("  [%-18s] %4d x %-4d  ABORTED", name, W, H);
        errors_total++;
      end else begin
        for (i = 0; i < W*H; i++) begin
          if (mem[dst_w + i] !== ref_img[i]) begin
            if (bad < 5)
              $display("    MISMATCH @ (%0d,%0d): ref=%08x got=%08x",
                       i / W, i % W, ref_img[i], mem[dst_w + i]);
            bad = bad + 1;
          end
        end
        // An accelerator that writes fewer words than it owes leaves poison
        // behind and is caught above. One that writes MORE is just as fatal
        // downstream and would not be, so check the word after the frame.
        if (mem[dst_w + W*H] !== 32'hDEAD_BEEF) begin
          $display("    OVERRUN: wrote past the end of the frame (%08x)",
                   mem[dst_w + W*H]);
          bad = bad + 1;
        end
        errors_total += bad;
        if (bad == 0)
          $display("  [%-18s] %4d x %-4d  %7d px  PASS        %0d polls",
                   name, W, H, W*H, cycles);
        else
          $display("  [%-18s] %4d x %-4d  %7d px  FAIL %6d  %0d polls",
                   name, W, H, W*H, bad, cycles);
      end
    end
  endtask

  // Every argument register must read back what was written. Getting an offset
  // wrong does not make a wrong picture, it makes an accelerator that never
  // finishes -- so check the map itself, not only its effect.
  task automatic check_registers;
    begin
      axil_write(6'h10, 32'h1234_5678);
      axil_write(6'h14, 32'h0000_0009);
      axil_write(6'h1C, 32'h8765_4321);
      axil_write(6'h20, 32'h0000_000A);
      axil_write(6'h28, 32'd640);
      axil_write(6'h30, 32'd480);
      axil_write(6'h38, 32'd2);

      axil_read(6'h10);
      if (axil_rd_data !== 32'h1234_5678) begin
        $display("    REG src_lo  readback %08x", axil_rd_data); errors_total++; end
      axil_read(6'h14);
      if (axil_rd_data !== 32'h0000_0009) begin
        $display("    REG src_hi  readback %08x", axil_rd_data); errors_total++; end
      axil_read(6'h1C);
      if (axil_rd_data !== 32'h8765_4321) begin
        $display("    REG dst_lo  readback %08x", axil_rd_data); errors_total++; end
      axil_read(6'h20);
      if (axil_rd_data !== 32'h0000_000A) begin
        $display("    REG dst_hi  readback %08x", axil_rd_data); errors_total++; end
      axil_read(6'h28);
      if (axil_rd_data !== 32'd640) begin
        $display("    REG width   readback %08x", axil_rd_data); errors_total++; end
      axil_read(6'h30);
      if (axil_rd_data !== 32'd480) begin
        $display("    REG height  readback %08x", axil_rd_data); errors_total++; end
      axil_read(6'h38);
      if (axil_rd_data !== 32'd2) begin
        $display("    REG mode    readback %08x", axil_rd_data); errors_total++; end

      // ap_idle must be set between runs, or PYNQ's start would be ignored
      axil_read(6'h00);
      if (!axil_rd_data[2]) begin
        $display("    CTRL ap_idle not set between runs (%08x)", axil_rd_data);
        errors_total++;
      end
      $display("  [%-18s] argument registers read back correctly", "REGISTERS");
    end
  endtask


  // The socket contract's two CH13 additions, checked directly.
  task automatic check_kernel_id;
    begin
      axil_read(6'h3C);
      if (axil_rd_data !== KERNEL_ID) begin
        $display("    KERNEL_ID readback %08x, expected %08x -- the socket does not contain the RM this testbench was built for",
                 axil_rd_data, KERNEL_ID);
        errors_total++;
      end else
        $display("  [%-18s] kernel_id reads %08x", "IDENTITY", axil_rd_data);

      // Read-only. A write must land nowhere -- not on the neighbouring mode
      // register, which is what a decoder that falls through would do.
      axil_write(6'h38, 32'd1);
      axil_write(6'h3C, 32'h0);
      axil_read(6'h3C);
      if (axil_rd_data !== KERNEL_ID) begin
        $display("    KERNEL_ID is writable (%08x)", axil_rd_data);
        errors_total++;
      end
      axil_read(6'h38);
      if (axil_rd_data !== 32'd1) begin
        $display("    a write to kernel_id landed on mode (%08x)", axil_rd_data);
        errors_total++;
      end
    end
  endtask

  // The heartbeat is what the static region's GPIO watches to decide whether
  // the partition is alive, BEFORE anything touches the AXI4-Lite slave. If it
  // never toggles, software has no safe way to ask the socket anything -- and
  // on ZynqMP asking a socket that cannot answer stops the CPU outright.
  task automatic check_heartbeat;
    logic hb0;
    bit   moved;
    int   i;
    begin
      hb0 = heartbeat;
      moved = 1'b0;
      // HB_BITS is 24 in a build, so a toggle takes 8.4M cycles. The RM tops
      // leave it at its default, so watch for a level rather than an edge:
      // what matters here is that it is driven at all, not how fast.
      for (i = 0; i < 2000; i++) begin
        @(posedge ap_clk);
        if (heartbeat !== hb0) moved = 1'b1;
      end
      if (heartbeat === 1'bx || heartbeat === 1'bz) begin
        $display("    heartbeat is %b -- not driven", heartbeat);
        errors_total++;
      end else
        $display("  [%-18s] heartbeat driven (%b, toggled=%0d)",
                 "HEARTBEAT", heartbeat, moved);
    end
  endtask

  initial begin
    ctrl_awvalid = 0; ctrl_wvalid = 0; ctrl_bready = 0;
    ctrl_arvalid = 0; ctrl_rready = 0; ctrl_wstrb = 4'hF;
    ctrl_awaddr = 0; ctrl_araddr = 0; ctrl_wdata = 0;

    repeat (10) @(posedge ap_clk);
    ap_rst_n = 1'b1;
    repeat (5) @(posedge ap_clk);

    $display("========================================================");
    $display(" CH13 RM '%s' -- checking against the golden model", RM_NAME);
    $display("========================================================");

    check_kernel_id();
    check_heartbeat();

`ifdef RM_SOBEL
    run_case( 64, 48, MODE_GRAY,   "GRAY 64x48");
    run_case( 64, 48, MODE_SOBEL,  "SOBEL 64x48");
    run_case( 64, 48, MODE_INVERT, "INVERT 64x48");
    run_case( 64, 48, MODE_COLOR,  "COLOR 64x48");
    run_case( 37, 23, MODE_SOBEL,  "SOBEL 37x23");
    run_case(  3,  3, MODE_SOBEL,  "SOBEL 3x3");
    run_case(  2,  2, MODE_SOBEL,  "SOBEL 2x2");
    run_case(  1,  1, MODE_SOBEL,  "SOBEL 1x1");
    run_case(  1, 16, MODE_SOBEL,  "SOBEL 1x16");
    run_case( 16,  1, MODE_SOBEL,  "SOBEL 16x1");
    run_case(160,120, MODE_SOBEL,  "SOBEL 160x120");
    run_case( 32, 24, 7,           "MODE7->SOBEL");
    run_case( 32, 24, MODE_GRAY,   "GRAY after SOBEL");
`endif

`ifdef RM_BLUR
    // The blur ignores mode, so every case passes 0 and any other value must
    // give the same answer -- which the last case checks.
    run_case( 64, 48, 0, "BLUR 64x48");
    run_case( 37, 23, 0, "BLUR 37x23");
    run_case(  3,  3, 0, "BLUR 3x3");
    run_case(  2,  2, 0, "BLUR 2x2");
    run_case(  1,  1, 0, "BLUR 1x1");
    run_case(  1, 16, 0, "BLUR 1x16");
    run_case( 16,  1, 0, "BLUR 16x1");
    run_case(160,120, 0, "BLUR 160x120");
    run_case( 32, 24, 0, "BLUR again");
    run_case( 32, 24, 32'hFFFF_FFFF, "BLUR ignores mode");
`endif

`ifdef RM_THRESHOLD
    // The level is the mode register. 0 makes everything white, 255 makes
    // almost everything black, and the interesting values are in between.
    run_case( 64, 48, 128, "THRESH 128");
    run_case( 64, 48,   0, "THRESH 0 (all white)");
    run_case( 64, 48, 255, "THRESH 255");
    run_case( 64, 48,  64, "THRESH 64");
    run_case( 37, 23, 128, "THRESH 37x23");
    run_case(  1,  1, 128, "THRESH 1x1");
    run_case(  3,  3, 128, "THRESH 3x3");
    run_case(160,120, 100, "THRESH 160x120");
    run_case( 32, 24, 200, "THRESH again");
`endif

`ifdef RM_PASSTHROUGH
    run_case( 64, 48, 0, "COPY 64x48");
    run_case( 37, 23, 0, "COPY 37x23");
    run_case(  1,  1, 0, "COPY 1x1");
    run_case(  3,  3, 0, "COPY 3x3");
    run_case(160,120, 0, "COPY 160x120");
    run_case( 32, 24, 32'hDEAD_BEEF, "COPY ignores mode");
`endif

    check_registers();

    $display("========================================================");
    if (errors_total == 0) $display(" TEST PASSED");
    else                   $display(" TEST FAILED -- %0d mismatching pixels", errors_total);
    $display("========================================================");
    $finish;
  end

  initial begin
    #200ms;
    $display("GLOBAL TIMEOUT");
    $display(" TEST FAILED -- global timeout");
    $finish;
  end

endmodule
