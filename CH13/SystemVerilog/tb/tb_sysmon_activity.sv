// ---------------------------------------------------------------------------
// tb_sysmon_activity -- does the SYSMONE4 actually convert?
// ---------------------------------------------------------------------------
// The DUT exists to answer that question on hardware, and the reason it has to
// COUNT rather than sample is the whole point: eoc_out and eos_out are
// single-cycle pulses at 100 MHz. Software polling an AXI GPIO at a few kHz
// would miss essentially every one of them and conclude the macro was dead
// whether it was or not. Counting edges in fabric is the only honest way to
// ask.
//
//   xvlog -sv tb/tb_sysmon_activity.sv hdl/sysmon_activity.sv
//   xelab -debug typical tb_sysmon_activity -s tb && xsim tb -runall
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_sysmon_activity;

    logic        clk = 1'b0;
    logic        rst;
    logic        eoc_in;
    logic        eos_in;
    logic        busy_in;
    logic [5:0]  channel_in;
    logic [31:0] count_word;
    logic [31:0] status_word;

    int errors = 0;

    always #5 clk = ~clk;   // 100 MHz, the design's DCLK

    sysmon_activity dut (
        .clk         (clk),
        .rst         (rst),
        .eoc_in      (eoc_in),
        .eos_in      (eos_in),
        .busy_in     (busy_in),
        .channel_in  (channel_in),
        .count_word  (count_word),
        .status_word (status_word)
    );

    // status_word packing, fixed here so software and RTL cannot drift apart
    function automatic logic [15:0] eos_count_of(logic [31:0] w);
        return w[31:16];
    endfunction
    function automatic logic [7:0] chan_changes_of(logic [31:0] w);
        return w[15:8];
    endfunction
    function automatic logic busy_of(logic [31:0] w);
        return w[7];
    endfunction
    function automatic logic [5:0] channel_of(logic [31:0] w);
        return w[5:0];
    endfunction

    task automatic check(string what, int unsigned got, int unsigned want);
        if (got !== want) begin
            $error("%s: got %0d, want %0d", what, got, want);
            errors++;
        end
    endtask

    // One clock of eoc_in high -- exactly what the macro emits.
    task automatic pulse_eoc(int n);
        for (int i = 0; i < n; i++) begin
            @(negedge clk) eoc_in = 1'b1;
            @(negedge clk) eoc_in = 1'b0;
        end
    endtask

    task automatic pulse_eos(int n);
        for (int i = 0; i < n; i++) begin
            @(negedge clk) eos_in = 1'b1;
            @(negedge clk) eos_in = 1'b0;
        end
    endtask

    initial begin
        rst        = 1'b1;
        eoc_in     = 1'b0;
        eos_in     = 1'b0;
        busy_in    = 1'b0;
        channel_in = 6'd0;
        repeat (4) @(negedge clk);

        // --- reset clears every counter --------------------------------
        check("count_word out of reset",   count_word,                 0);
        check("eos count out of reset",    eos_count_of(status_word),  0);
        check("chan changes out of reset", chan_changes_of(status_word), 0);

        rst = 1'b0;
        @(negedge clk);

        // --- eoc pulses are counted ------------------------------------
        pulse_eoc(3);
        @(negedge clk);
        check("eoc pulses counted", count_word, 3);

        // --- a level held high counts ONCE, not once per cycle ---------
        // The macro pulses for one cycle, but a driver that counted levels
        // would over-report by orders of magnitude and make a stuck-high
        // signal look like a healthy converter.
        @(negedge clk) eoc_in = 1'b1;
        repeat (10) @(negedge clk);
        eoc_in = 1'b0;
        @(negedge clk);
        check("held-high eoc counts once", count_word, 4);

        // --- eos is counted separately ---------------------------------
        pulse_eos(2);
        @(negedge clk);
        check("eos pulses counted", eos_count_of(status_word), 2);
        check("eos does not disturb eoc", count_word, 4);

        // --- channel changes are counted -------------------------------
        @(negedge clk) channel_in = 6'd1;
        @(negedge clk) channel_in = 6'd3;
        @(negedge clk) channel_in = 6'd3;   // no change, must not count
        @(negedge clk) channel_in = 6'd8;
        repeat (2) @(negedge clk);
        check("channel changes counted", chan_changes_of(status_word), 3);
        check("current channel visible", channel_of(status_word), 8);

        // --- busy is registered through ---------------------------------
        @(negedge clk) busy_in = 1'b1;
        repeat (2) @(negedge clk);
        check("busy observed high", busy_of(status_word), 1);
        @(negedge clk) busy_in = 1'b0;
        repeat (2) @(negedge clk);
        check("busy observed low", busy_of(status_word), 0);

        // --- reset is synchronous and active high -----------------------
        @(negedge clk) rst = 1'b1;
        repeat (2) @(negedge clk);
        check("reset clears eoc count", count_word, 0);
        check("reset clears eos count", eos_count_of(status_word), 0);

        if (errors == 0)
            $display("\n[PASS] tb_sysmon_activity: all checks passed\n");
        else
            $display("\n[FAIL] tb_sysmon_activity: %0d error(s)\n", errors);
        $finish;
    end

endmodule
