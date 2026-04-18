// project_2.sv
// ------------------------------------
// Chapter two project
// ------------------------------------
// Author : Frank Bruno
// Combine the chapters functions together into a selectable operation
`timescale 1ns/10ps
module project_2
  #
  (
   parameter SELECTOR,
   parameter BITS      = 8
   )
  (
   input wire [BITS-1:0]          PL_USER_SW,
   input wire [3:0]               PL_USER_PB,

   output logic signed [BITS-1:0] PL_USER_LED
   );

  logic [$clog2(BITS):0] LO_LED;
  logic [$clog2(BITS):0] NO_LED;
  logic [BITS-1:0]       AD_LED;
  logic [BITS-1:0]       SB_LED;
  logic [BITS-1:0]       MULT_LED;

  leading_ones #(.SELECTOR(SELECTOR), .BITS(BITS)) u_lo (.*, .PL_USER_LED(LO_LED));
  add_sub      #(.SELECTOR("ADD"),    .BITS(BITS)) u_ad (.*, .PL_USER_LED(AD_LED));
  add_sub      #(.SELECTOR("SUB"),    .BITS(BITS)) u_sb (.*, .PL_USER_LED(SB_LED));
  num_ones     #(                     .BITS(BITS)) u_no (.*, .PL_USER_LED(NO_LED));
  mult         #(                     .BITS(BITS)) u_mt (.*, .PL_USER_LED(MULT_LED));

  //always_latch begin
  always_comb begin
    PL_USER_LED = '0;
    case (1'b1)
      PL_USER_PB[3]: PL_USER_LED  = MULT_LED;
      PL_USER_PB[2]: PL_USER_LED  = LO_LED;
      PL_USER_PB[1]: PL_USER_LED  = NO_LED;
      PL_USER_PB[0]: PL_USER_LED  = AD_LED;
      default:       PL_USER_LED  = SB_LED;
    endcase
  end
endmodule
