// counting_buttons_wrapper.v
// ------------------------------------
// Count the number of button presses
// ------------------------------------
// Author : Frank Bruno
// Count the number of center button presses and display the count in decimal
// or hexidecimal on the 7 segment display
`timescale 1ns/10ps
module counting_buttons_wrapper
  #
  (
   parameter MODE         = "HEX", // or "DEC"
   parameter NUM_SEGMENTS = 8,     // Easier for using GPIO
   parameter ASYNC_BUTTON = "SAFE" // "CLOCK", "NOCLOCK", "SAFE", "DEBOUNCE"
   )
  (
   input                       clk,
   input [0:0]                 PL_USER_PB,
   input                       CPU_RESETN,

   output [NUM_SEGMENTS*4-1:0] ext_counter
   );

 counting_buttons
  #
  (
   .MODE         (MODE), // or "DEC"
   .NUM_SEGMENTS (NUM_SEGMENTS),     // Easier for using GPIO
   .ASYNC_BUTTON (ASYNC_BUTTON) // "CLOCK", "NOCLOCK", "SAFE", "DEBOUNCE"
   )
  (
   .clk          (clk),
   .PL_USER_PB   (PL_USER_PB),
   .CPU_RESETN   (CPU_RESETN),

   .ext_counter  (ext_counter)
   );
endmodule // counting_buttons_wrapper
