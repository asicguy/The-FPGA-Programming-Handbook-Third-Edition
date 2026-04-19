// tb.sv
// ------------------------------------
// Testbench for Project 2
// ------------------------------------
// Author : Frank Bruno
`timescale 1ns/ 100ps;

module tb;
  parameter  SELECTOR     = "UP_FOR";
  parameter  UNIQUE_CASE  = "FALSE";
  parameter  TEST_CASE    = "ALL";
  localparam BITS         = 8;
  localparam NUM_TEST     = 1000;

  logic [BITS-1:0]       PL_USER_SW;
  logic [BITS-1:0]       PL_USER_LED;
  logic [3:0]            PL_USER_PB;

  logic [$clog2(BITS):0] LO_LED;
  logic [$clog2(BITS):0] NO_LED;
  logic [BITS-1:0]       AS_LED;
  logic [BITS-1:0]       MULT_LED;
  logic [BITS-1:0]       LED_TB;

/*
  leading_ones #(.SELECTOR(SELECTOR), .BITS(BITS)) u_lo (.*, .PL_USER_LED(LO_LED));
  add_sub      #(.SELECTOR(SELECTOR), .BITS(BITS)) u_as (.*, .PL_USER_LED(AS_LED));
  num_ones     #(                     .BITS(BITS)) u_no (.*, .PL_USER_LED(NO_LED));
  mult         #(                     .BITS(BITS)) u_mt (.*, .PL_USER_LED(MULT_LED));
  project_2    #(.SELECTOR(SELECTOR), .BITS(BITS)) u_alu
  (
   .*
   );
   */
  leading_ones #(.SELECTOR(SELECTOR), .BITS(BITS)) u_lo (.PL_USER_SW, .PL_USER_LED(LO_LED));
  add_sub      #(.SELECTOR(SELECTOR), .BITS(BITS)) u_as (.PL_USER_SW, .PL_USER_LED(AS_LED));
  num_ones     #(                     .BITS(BITS)) u_no (.PL_USER_SW, .PL_USER_LED(NO_LED));
  mult         #(                     .BITS(BITS)) u_mt (.PL_USER_SW, .PL_USER_LED(MULT_LED));
  project_2    #(.SELECTOR(SELECTOR), .BITS(BITS)) u_alu
   (
    .PL_USER_SW, .PL_USER_PB, .PL_USER_LED
   );

  always_comb begin
    LED_TB = '0;
    if (TEST_CASE == "LEADING_ONES") begin
      LED_TB[$clog2(BITS):0]  = LO_LED;
    end else if (TEST_CASE == "NUM_ONES") begin
      LED_TB = NO_LED;
    end else if (TEST_CASE == "ADD" || TEST_CASE == "SUB") begin
      LED_TB = AS_LED;
    end else if (TEST_CASE == "MULT") begin
      LED_TB = MULT_LED;
    end else begin
      LED_TB = PL_USER_LED;
    end
  end

  logic                  set_zero;
  int                    button;

  // Stimulus
  initial begin
    $printtimescale(tb);
    //if ((TEST_CASE == "LEADING_ONES") || (TEST_CASE == "ALL")) begin
    for (int i = 0; i < NUM_TEST; i++) begin
      button = $urandom_range(0,4);
      PL_USER_PB = '0;
      PL_USER_PB[button] = '1;

      PL_USER_SW        = $random;
      set_zero  = '0;
      for (int j = BITS-1; j >= 0; j--) begin
        if (UNIQUE_CASE == "TRUE" &&
            !((TEST_CASE == "ADD") || (TEST_CASE == "SUB") ||
              (TEST_CASE == "MULT"))) begin
          // If we want to use unique values, execute this part of tb
          if (set_zero) PL_USER_SW[j] = '0;
          else if (PL_USER_SW[j] && j > 0) begin
            // if we find a 1 at a position other than in bit 0, set all lower
            // bits top 0. This ensures we will only have 1 bit at most set.
            set_zero = '1;
          end
        end
      end
      $display("Setting switches to %8b", PL_USER_SW);
      #100;
    end
    PL_USER_SW = '0;
    #100;
    $display("PASS: logic_ex test PASSED!");
    $stop;
    //end
  end

  int sw_pos;
  logic signed [7:0] sw_alu;

  // Checking
  always @(LED_TB) begin
    #1;
    $display("LED: %b", PL_USER_LED);
    sw_pos  = '0;
    if (TEST_CASE == "ALL") begin
      case (1'b1)
        PL_USER_PB[0]: begin
          sw_alu = signed'(PL_USER_SW[7:4]) + signed'(PL_USER_SW[3:0]);
          if (sw_alu != PL_USER_LED) begin
            $display("FAIL: LED != sum of PL_USER_SW[7:4] + PL_USER_SW[3:0]");
            $stop;
          end
        end
        PL_USER_PB[1]: begin
          if (no_func(PL_USER_SW) != PL_USER_LED) begin
            $display("FAIL: LED != number of ones represented by PL_USER_SW");
            $stop;
          end
        end
        PL_USER_PB[2]: begin
          if (lo_func(PL_USER_SW) != PL_USER_LED[$clog2(BITS):0]) begin
            $display("FAIL: LED != leading 1's position");
            $stop;
          end
        end
        PL_USER_PB[3]: begin
          sw_alu = signed'(PL_USER_SW[7:4]) * signed'(PL_USER_SW[3:0]);
          if (sw_alu != PL_USER_LED) begin
            $display("FAIL: LED != product of PL_USER_SW[7:4] * PL_USER_SW[3:0]");
            $stop;
          end
        end
        default: begin
          sw_alu = signed'(PL_USER_SW[7:4]) - signed'(PL_USER_SW[3:0]);
          if (sw_alu != PL_USER_LED) begin
            $display("FAIL: LED != difference of PL_USER_SW[7:4] - PL_USER_SW[3:0]");
            $stop;
          end
        end
      endcase
    end else if (TEST_CASE == "LEADING_ONES") begin
      if (lo_func(PL_USER_SW) != LED_TB[$clog2(BITS):0]) begin
        $display("FAIL: LED != leading 1's position, %d != %d", lo_func(PL_USER_SW), LED_TB[$clog2(BITS):0]);
        $stop;
      end
    end else if (TEST_CASE == "NUM_ONES") begin
      if (no_func(PL_USER_SW) != LED_TB) begin
        $display("FAIL: LED != number of ones represented by PL_USER_SW");
        $stop;
      end
    end else if (TEST_CASE == "ADD") begin
      sw_alu = signed'(PL_USER_SW[7:4]) + signed'(PL_USER_SW[3:0]);
      if (sw_alu != LED_TB) begin
        $display("FAIL: LED != sum of PL_USER_SW[7:4] + PL_USER_SW[3:0]");
        $stop;
      end
    end else if (TEST_CASE == "SUB") begin
      sw_alu = signed'(PL_USER_SW[7:4]) - signed'(PL_USER_SW[3:0]);
      if (sw_alu != LED_TB) begin
        $display("FAIL: LED != difference of PL_USER_SW[7:4] + PL_USER_SW[3:0]");
        $stop;
      end
    end else if (TEST_CASE == "MULT") begin
      sw_alu = signed'(PL_USER_SW[7:4]) * signed'(PL_USER_SW[3:0]);
      if (sw_alu != LED_TB) begin
        $display("FAIL: LED != product of PL_USER_SW[7:4] - PL_USER_SW[3:0]");
        $stop;
      end
    end // if ((TEST_CASE == "LEADING_ONES") || (TEST_CASE == "ALL"))
  end // always @ (LED_TB)

  function [$clog2(BITS):0] lo_func(input [BITS-1:0] PL_USER_SW);
    lo_func = '0;
    for (int i = $low(PL_USER_SW); i <= $high(PL_USER_SW); i++) begin
      if (PL_USER_SW[i]) begin
        lo_func  = i+1;
      end
    end
  endfunction

  function [$clog2(BITS):0] no_func(input [BITS-1:0] PL_USER_SW);
    no_func = '0;
    for (int i = $low(PL_USER_SW); i <= $high(PL_USER_SW); i++) begin
      no_func  += PL_USER_SW[i];
    end
  endfunction

endmodule // tb
