// leading_ones.sv
// ------------------------------------
// Leading ones detector module
// ------------------------------------
// Author : Frank Bruno
// Find the leading ones (highest bit set) in a vector.
`timescale 1ns/10ps
module leading_ones
  #
  (
   parameter SELECTOR,
   parameter BITS      = 8
   )
  (
   input wire [BITS-1:0]         PL_USER_SW,
   output logic [$clog2(BITS):0] PL_USER_LED
   );

  generate
    if (SELECTOR == "UNIQUE_CASE") begin : g_UNIQUE_CASE
      always_comb begin
        PL_USER_LED           = '0; // Default to an output of 0
        unique case (1'b1)
          PL_USER_SW[7]:   PL_USER_LED  = 8;
          PL_USER_SW[6]:   PL_USER_LED  = 7;
          PL_USER_SW[5]:   PL_USER_LED  = 6;
          PL_USER_SW[4]:   PL_USER_LED  = 5;
          PL_USER_SW[3]:   PL_USER_LED  = 4;
          PL_USER_SW[2]:   PL_USER_LED  = 3;
          PL_USER_SW[1]:   PL_USER_LED  = 2;
          PL_USER_SW[0]:   PL_USER_LED  = 1;
          default: PL_USER_LED  = 0;
        endcase
      end // always_comb
    end else if (SELECTOR == "CASE") begin : g_CASE // block: g_UNIQUE_CASE
      always_comb begin
        PL_USER_LED           = '0; // Default to an output of 0
        case (1'b1)
          PL_USER_SW[7]:   PL_USER_LED  = 8;
          PL_USER_SW[6]:   PL_USER_LED  = 7;
          PL_USER_SW[5]:   PL_USER_LED  = 6;
          PL_USER_SW[4]:   PL_USER_LED  = 5;
          PL_USER_SW[3]:   PL_USER_LED  = 4;
          PL_USER_SW[2]:   PL_USER_LED  = 3;
          PL_USER_SW[1]:   PL_USER_LED  = 2;
          PL_USER_SW[0]:   PL_USER_LED  = 1;
          default: PL_USER_LED  = 0;
        endcase
      end // always_comb
    end else if (SELECTOR == "DOWN_FOR") begin : g_UP_IF
      always_comb begin
        PL_USER_LED = '0;
        for (int i = $high(PL_USER_SW); i >= $low(PL_USER_SW); i--) begin
          if (PL_USER_SW[i]) begin
            PL_USER_LED = i + 1;
            break;
          end
        end
      end
    end else if (SELECTOR == "UP_FOR") begin : g_DOWN_IF
      always_comb begin
        PL_USER_LED = '0;
        for (int i = $low(PL_USER_SW); i <= $high(PL_USER_SW); i++) begin
          if (PL_USER_SW[i]) begin
            PL_USER_LED = i + 1;
          end
        end
      end
    end
  endgenerate
endmodule
