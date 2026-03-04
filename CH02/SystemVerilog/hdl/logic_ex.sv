// logic_ex.sv
// ------------------------------------
// Example file to show combinational functions
// ------------------------------------
// Author : Frank Bruno
// This file demonstrates combinational LED outputs based upon switch inputs.
// There are multiple ways of accomplishing each function, uncomment to try them
`timescale 1ns/10ps
module logic_ex
  (
   input  wire  [1:0]    PL_USER_SW,
   output logic [3:0]    PL_USER_LED
   );

  assign PL_USER_LED[0]  = !PL_USER_SW[0];
  assign PL_USER_LED[1]  = PL_USER_SW[1] && PL_USER_SW[0];
  //assign PL_USER_LED[1]  = PL_USER_SW[1] & PL_USER_SW[0];
  //assign PL_USER_LED[1]  = (PL_USER_SW[1] == 1'b1) & (PL_USER_SW[0] == 1'b1);
  //assign PL_USER_LED[1]  = (PL_USER_SW[1] === 1'b1) & (PL_USER_SW[0] === 1'b1);
  //assign PL_USER_LED[1]  = &PL_USER_SW[1:0];
  assign PL_USER_LED[2]  = PL_USER_SW[1] || PL_USER_SW[0];
  //assign PL_USER_LED[2]  = PL_USER_SW[1] | PL_USER_SW[0];
  //assign PL_USER_LED[2]  = (PL_USER_SW[1] == 1'b1) | (PL_USER_SW[0] == 1'b1);
  //assign PL_USER_LED[2]  = (PL_USER_SW[1] === 1'b1) | (PL_USER_SW[0] === 1'b1);
  //assign PL_USER_LED[2]  = |PL_USER_SW[1:0];
  assign PL_USER_LED[3]  = PL_USER_SW[1] ^ PL_USER_SW[0];
  //assign PL_USER_LED[3]  = (PL_USER_SW[1] == 1'b1) ^ (PL_USER_SW[0] == 1'b1);
  //assign PL_USER_LED[3]  = (PL_USER_SW[1] === 1'b1) ^ (PL_USER_SW[0] === 1'b1);
  //assign PL_USER_LED[3]  = ^PL_USER_SW[1:0];
endmodule // logic_ex
