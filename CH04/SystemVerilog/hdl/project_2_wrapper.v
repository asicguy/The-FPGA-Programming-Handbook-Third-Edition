// project_2.sv
// ------------------------------------
// Chapter two project
// ------------------------------------
// Author : Frank Bruno
// Combine the chapters functions together into a selectable operation
`timescale 1ns/10ps
module project_2_wrapper
  #
  (
   parameter SELECTOR  = "UNIQUE_CASE",
   parameter BITS      = 8
   )
  (
   input [BITS-1:0]          PL_USER_SW,
   input [3:0]               PL_USER_PB,

   output signed [BITS-1:0] PL_USER_LED
   );

  project_2
    #
    (
     .SELECTOR   (SELECTOR),
     .BITS       (BITS)
     )
  project_2
    (
     .PL_USER_SW (PL_USER_SW),
     .PL_USER_PB (PL_USER_PB),
     .PL_USER_LED(PL_USER_LED)
     );
endmodule
