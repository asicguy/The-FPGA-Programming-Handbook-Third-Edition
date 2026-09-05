// ---------------------------------------------------------------------------
// sysmon_activity -- is the SYSMONE4 converting, asked without using the DRP
// ---------------------------------------------------------------------------
// The System Management Wizard brings the macro's own status pins out to
// fabric: eoc_out, eos_out, busy_out and channel_out. Those come straight off
// the SYSMONE4 and go through NEITHER the DRP register path NOR the PS AMS
// block, which are the two paths already known to report nothing on this
// board. So they can answer a question neither of those can: is the converter
// running at all?
//
// WHY THIS COUNTS RATHER THAN SAMPLES
//
// eoc_out and eos_out are single-cycle pulses at 100 MHz. Software polling an
// AXI GPIO manages a few thousand reads a second at best, so it would miss
// essentially every pulse and report a dead converter whether or not one was
// running. Counting edges in fabric turns a signal too fast to observe into a
// number that only has to be read twice.
//
// Everything here is in the DCLK domain -- the wizard's s_axi_aclk, which is
// also the SYSMONE4's DCLK -- so these inputs are synchronous to clk and need
// no synchroniser. That is worth stating explicitly given how much trouble
// clock crossings have caused elsewhere in this chapter and in CH12.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module sysmon_activity (
    input  logic        clk,
    input  logic        rst,          // synchronous, active high

    // straight off the SYSMONE4, via the wizard's fabric outputs
    input  logic        eoc_in,       // end of conversion, one cycle
    input  logic        eos_in,       // end of sequence, one cycle
    input  logic        busy_in,
    input  logic [5:0]  channel_in,

    // to an AXI GPIO, so software can read them
    output logic [31:0] count_word,   // eoc_count, full width for rate work
    output logic [31:0] status_word
);

    // ----------------------------------------------------------------------
    // status_word packing. Software in sw/sysmon.py decodes exactly this, and
    // tb/tb_sysmon_activity.sv pins it down, so the two cannot drift apart.
    //
    //   [31:16] eos_count       wraps at 65536
    //   [15:8]  chan_changes    wraps at 256
    //   [7]     busy
    //   [6]     reserved, always 0
    //   [5:0]   channel
    //
    // The narrow counters wrap quickly, which is fine: they answer "did this
    // change between two reads", not "at what rate". eoc_count is the wide one
    // and is the only counter a rate should ever be computed from.
    // ----------------------------------------------------------------------
    logic [31:0] eoc_count;
    logic [15:0] eos_count;
    logic [7:0]  chan_changes;
    logic [5:0]  channel_q;
    logic        busy_q;

    // Previous values, for edge detection. A level that stays high must count
    // once, not once per cycle -- otherwise a signal stuck high reads as a
    // very healthy converter, which is the exact failure this module exists
    // to rule out.
    logic        eoc_q;
    logic        eos_q;
    logic [5:0]  channel_prev;

    always_ff @(posedge clk) begin
        if (rst) begin
            eoc_count    <= 32'd0;
            eos_count    <= 16'd0;
            chan_changes <= 8'd0;
            channel_q    <= 6'd0;
            busy_q       <= 1'b0;
            eoc_q        <= 1'b0;
            eos_q        <= 1'b0;
            channel_prev <= 6'd0;
        end else begin
            eoc_q        <= eoc_in;
            eos_q        <= eos_in;
            channel_prev <= channel_in;
            channel_q    <= channel_in;
            busy_q       <= busy_in;

            if (eoc_in && !eoc_q) begin
                eoc_count <= eoc_count + 32'd1;
            end

            if (eos_in && !eos_q) begin
                eos_count <= eos_count + 16'd1;
            end

            if (channel_in != channel_prev) begin
                chan_changes <= chan_changes + 8'd1;
            end
        end
    end

    assign count_word  = eoc_count;
    assign status_word = {eos_count, chan_changes, busy_q, 1'b0, channel_q};

endmodule
