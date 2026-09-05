// ---------------------------------------------------------------------------
// tb_pot_bar -- the potentiometer as an eight-LED thermometer bar
// ---------------------------------------------------------------------------
//   xvlog -sv tb/tb_pot_bar.sv hdl/pot_bar.sv
//   xelab -debug typical tb_pot_bar -s tb && xsim tb -runall
//
// The interesting cases are the ends. A bar that never reaches 8 at full
// scale, or lights one LED at zero, looks plausible on a bench and is wrong.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_pot_bar;

    logic        clk = 1'b0;
    logic        rst;
    logic [15:0] level;
    logic [7:0]  leds;

    int errors = 0;

    always #5 clk = ~clk;

    pot_bar dut (
        .clk   (clk),
        .rst   (rst),
        .level (level),
        .leds  (leds)
    );

    task automatic expect_leds(string what, logic [15:0] value, logic [7:0] want);
        @(negedge clk) level = value;
        repeat (2) @(negedge clk);
        if (leds !== want) begin
            $error("%s: level=0x%04X gave %b, want %b", what, value, leds, want);
            errors++;
        end
    endtask

    initial begin
        rst   = 1'b1;
        level = 16'h0000;
        repeat (4) @(negedge clk);

        if (leds !== 8'h00) begin
            $error("reset should clear the bar, got %b", leds);
            errors++;
        end

        rst = 1'b0;
        @(negedge clk);

        // --- the ends ---------------------------------------------------
        expect_leds("zero is dark",           16'h0000, 8'b0000_0000);
        expect_leds("full scale is all lit",  16'hFFFF, 8'b1111_1111);

        // --- one count above zero must light exactly one ----------------
        // A bar that stays dark until the pot is well off its stop reads as
        // a broken pot.
        expect_leds("one count lights one",   16'h0001, 8'b0000_0001);

        // --- the bar fills from the bottom ------------------------------
        // 8192 counts per LED: 65536 / 8.
        expect_leds("exactly one LED",        16'd8192,  8'b0000_0001);
        expect_leds("just into the second",   16'd8193,  8'b0000_0011);
        expect_leds("half scale is four",     16'd32768, 8'b0000_1111);
        expect_leds("seven eighths",          16'd57344, 8'b0111_1111);
        expect_leds("just into the eighth",   16'd57345, 8'b1111_1111);

        // --- it is a thermometer, not a binary display ------------------
        // Every lit pattern must be contiguous from bit 0. This catches a
        // decoder that accidentally shows the value in binary, which looks
        // superficially reasonable while the pot moves.
        for (int v = 0; v < 65536; v += 251) begin
            @(negedge clk) level = v[15:0];
            repeat (2) @(negedge clk);
            for (int i = 1; i < 8; i++) begin
                if (leds[i] && !leds[i-1]) begin
                    $error("gap in the bar at level 0x%04X: %b", v[15:0], leds);
                    errors++;
                end
            end
        end

        // --- reset clears it again --------------------------------------
        @(negedge clk) level = 16'hFFFF;
        repeat (2) @(negedge clk);
        @(negedge clk) rst = 1'b1;
        repeat (2) @(negedge clk);
        if (leds !== 8'h00) begin
            $error("reset should clear the bar, got %b", leds);
            errors++;
        end

        if (errors == 0)
            $display("\n[PASS] tb_pot_bar: all checks passed\n");
        else
            $display("\n[FAIL] tb_pot_bar: %0d error(s)\n", errors);
        $finish;
    end

endmodule
