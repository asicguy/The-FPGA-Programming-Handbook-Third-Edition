// ---------------------------------------------------------------------------
// sysmon_activity_wrapper -- plain Verilog around the SystemVerilog module
// ---------------------------------------------------------------------------
// IP Integrator refuses a .sv file as the top of a module reference:
//
//   ERROR [filemgmt 56-195] Reference 'sysmon_activity' contains top file
//   '.../sysmon_activity.sv' of type SystemVerilog. This type is not allowed
//   as the top file in the reference.
//
// so the block design references this instead. It adds no logic and exists
// only to present a Verilog-2001 boundary, the same pattern CH08 and CH09 use
// (calculator_wrapper.v, aic3104_dma_top.v).
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module sysmon_activity_wrapper (
    input  wire        clk,
    input  wire        rst,
    input  wire        eoc_in,
    input  wire        eos_in,
    input  wire        busy_in,
    input  wire [5:0]  channel_in,
    output wire [31:0] count_word,
    output wire [31:0] status_word
);

    sysmon_activity u_sysmon_activity (
        .clk         (clk),
        .rst         (rst),
        .eoc_in      (eoc_in),
        .eos_in      (eos_in),
        .busy_in     (busy_in),
        .channel_in  (channel_in),
        .count_word  (count_word),
        .status_word (status_word)
    );

endmodule
