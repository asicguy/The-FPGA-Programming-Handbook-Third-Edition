// ---------------------------------------------------------------------------
// pot_bar -- a 16-bit level as an eight-LED thermometer bar
// ---------------------------------------------------------------------------
// The potentiometer's position, shown on the board's white LEDs so the pot can
// be seen working without a browser open.
//
// WHY THE VALUE ARRIVES FROM SOFTWARE RATHER THAN FROM THE SYSMON DIRECTLY
//
// The System Management Wizard is configured with INTERFACE_SELECTION
// Enable_AXI, which gives the wizard's AXI4-Lite bridge ownership of the
// SYSMONE4's single DRP port. There is only one, so fabric logic cannot also
// read conversions out of the macro. The alternatives were to write a DRP
// master in RTL and give up the AXI register interface, or to let software
// read VP/VN and hand the value back through an output GPIO. This takes the
// second: the decode stays in hardware, the transport does not.
//
// `level` is the raw left-justified SYSMON reading, so the full 0..65535 range
// maps to the channel's full scale whatever the ADC's actual resolution is --
// 10 bits here on SYSMONE4, 12 on a 7-series XADC.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module pot_bar (
    input  logic        clk,
    input  logic        rst,      // synchronous, active high
    input  logic [15:0] level,
    output logic [7:0]  leds
);

    // 65536 / 8 = 8192 counts per LED.
    //
    // The count is rounded UP so that one count above zero lights the first
    // LED and full scale lights all eight. Truncating instead would leave the
    // bar dark until the pot was well off its stop and would never reach
    // eight at the top, both of which look like a broken pot rather than a
    // rounding choice.
    localparam int COUNTS_PER_SHIFT = 13;   // 8192 == 1 << 13

    logic [16:0] rounded;
    logic [16:0] scaled;
    logic [3:0]  lit;

    always_comb begin
        // +8191 is the round-up. The sum needs 17 bits so full scale does not
        // wrap: 65535 + 8191 = 73726.
        rounded = {1'b0, level} + 17'd8191;
        scaled  = rounded >> COUNTS_PER_SHIFT;

        // Both arms of the conditional are 4 bits wide, and the slice is safe
        // because it is only reached when scaled <= 8. Writing this as a
        // comparison against a 17-bit expression instead makes Verilator
        // (correctly) report WIDTHEXPAND and WIDTHTRUNC.
        lit = (scaled > 17'd8) ? 4'd8 : scaled[3:0];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            leds <= 8'h00;
        end else begin
            for (int i = 0; i < 8; i++) begin
                leds[i] <= (i < int'(lit));
            end
        end
    end

endmodule
