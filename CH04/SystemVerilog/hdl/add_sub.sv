// add_sub.sv
// ------------------------------------
// Simple combinational adder subtractor block
// ------------------------------------
// Author : Frank Bruno
// Take in a number of bits, split into two halves and add.
`timescale 1ns/10ps
module add_sub
  #
  (
   parameter SELECTOR,
   parameter BITS      = 8
   )
  (
   input  wire  [BITS-1:0]        PL_USER_SW,
   output logic signed [BITS-1:0] PL_USER_LED
   );

  logic signed [BITS/2-1:0]       a_in;
  logic signed [BITS/2-1:0]       b_in;

  always_comb begin
    {a_in, b_in} = PL_USER_SW;
    if (SELECTOR == "ADD") PL_USER_LED = a_in + b_in;
    else                   PL_USER_LED = a_in - b_in;
  end
endmodule
