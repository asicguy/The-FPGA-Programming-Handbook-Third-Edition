// num_ones.sv
// ------------------------------------
// Count the number of bits that are high in a vector
// ------------------------------------
// Author : Frank Bruno
// Count the number of bits that are high in a vector
`timescale 1ns/10ps
module num_ones
  #
  (
   parameter BITS      = 8
   )
  (
   input wire [BITS-1:0]         PL_USER_SW,
   output logic [$clog2(BITS):0] PL_USER_LED
   );

  always_comb begin
    PL_USER_LED = '0;
    for (int i = $low(PL_USER_SW); i <= $high(PL_USER_SW); i++) begin
      PL_USER_LED += PL_USER_SW[i];
    end
  end
endmodule
