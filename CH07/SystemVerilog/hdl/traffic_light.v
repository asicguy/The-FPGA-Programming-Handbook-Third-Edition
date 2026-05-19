module traffic_light
  #
  (
   parameter CLK_PER = 10,
   parameter STATE = "MEALY"
   )
  (
   input                       clk,
   input [1:0]                 PL_USER_SW,

   output [2:0]                PL_LEDRGB0,
   output [2:0]                PL_LEDRGB1
   );

  generate
    if (STATE == "MEALY") begin : g_MEALY
      traffic_light_mealy
        #
        (
         .CLK_PER (CLK_PER)
         )
      traffic_light
        (
         .clk     (clk),
         .SW      (PL_USER_SW),

         .R       ({PL_LEDRGB1[0], PL_LEDRGB0[0]}),
         .G       ({PL_LEDRGB1[1], PL_LEDRGB0[1]}),
         .B       ({PL_LEDRGB1[2], PL_LEDRGB0[2]})
         );
    end else begin : g_MOORE
      traffic_light_moore
        #
        (
         .CLK_PER (CLK_PER)
         )
      traffic_light
        (
         .clk     (clk),
         .SW      (PL_USER_SW),

         .R       ({PL_LEDRGB1[0], PL_LEDRGB0[0]}),
         .G       ({PL_LEDRGB1[1], PL_LEDRGB0[1]}),
         .B       ({PL_LEDRGB1[2], PL_LEDRGB0[2]})
         );
    end // block: g_MOORE
  endgenerate
endmodule // traffic_light
