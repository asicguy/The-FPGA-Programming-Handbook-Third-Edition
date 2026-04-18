// logic_ex.sv
// ------------------------------------
// Multiplier
// ------------------------------------
// Author : Frank Bruno
// Take a vector, split in half and multiply the two halves together.
`timescale 1ns/10ps
module mult
  #
  (
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
    PL_USER_LED = a_in * b_in;
  end
endmodule
