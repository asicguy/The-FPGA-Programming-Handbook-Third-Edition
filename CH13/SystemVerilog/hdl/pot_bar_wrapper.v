// ---------------------------------------------------------------------------
// pot_bar_wrapper -- plain Verilog around pot_bar, for IP Integrator
// ---------------------------------------------------------------------------
// IPI rejects a .sv file as the top of a module reference (filemgmt 56-195),
// so the block design references this. It adds no logic. Same pattern as
// sysmon_activity_wrapper.v, and as CH08's calculator_wrapper.v.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module pot_bar_wrapper (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] level,
    output wire [7:0]  leds
);

    pot_bar u_pot_bar (
        .clk   (clk),
        .rst   (rst),
        .level (level),
        .leds  (leds)
    );

endmodule
