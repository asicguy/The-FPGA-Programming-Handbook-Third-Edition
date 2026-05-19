// traffic_light.sv
// ------------------------------------
// Traffic light controller
// ------------------------------------
// Author : Frank Bruno
`timescale 1ns/10ps
module traffic_light_mealy
  #
  (
   parameter CLK_PER = 10
   )
  (
   input wire                        clk,
   input wire [1:0]                  SW,

   output logic [1:0]                R,
   output logic [1:0]                G,
   output logic [1:0]                B
   );

  localparam COUNT_1S    = int'(100000000 / CLK_PER);
  localparam COUNT_10S   = 10 * int'(100000000 / CLK_PER);
  localparam COUNT_500US = int'(COUNT_1S / 2000); // 500 us x 2 gives a 1 kHz PWM base frequency

  bit [$clog2(COUNT_10S)-1:0]        counter;

  typedef enum bit [1:0]
               {
                RED,
                YELLOW,
                GREEN
                }light_t;

  light_t up_down;
  light_t left_right;

  typedef enum bit [1:0]
               {
                INIT,
                W4BUTTON,
                YELLOW2RED
                } state_t;

  state_t state;

  logic [$clog2(COUNT_500US)-1:0] pwm_count;
  logic [2:0]                     lr_reg;
  logic [2:0]                     ud_reg;
  logic                           enable_count;
  logic                           light_count;

  initial begin
    up_down    = RED;
    left_right = GREEN;
    state      = INIT;
    counter    = '0;
  end

  always @(posedge clk) begin
    lr_reg         <= lr_reg << 1 | SW[0];
    ud_reg         <= ud_reg << 1 | SW[1];
    enable_count   <= '0;

    if (enable_count) begin
      counter <= counter + 1'b1;
    end else begin
      counter <= '0;
    end

    case (state)
      INIT: begin
        up_down      <= GREEN;
        left_right   <= RED;
        enable_count <= '1;
        if (counter == COUNT_10S) begin
          up_down    <= GREEN;
          left_right <= RED;
          state      <= W4BUTTON;
        end
      end
      W4BUTTON: begin
        case (up_down)
          GREEN: begin
            if (lr_reg[2]) begin
              up_down    <= YELLOW;
              left_right <= RED;
              state      <= YELLOW2RED;
            end
          end
          RED: begin
            if (ud_reg[2]) begin
              up_down    <= RED;
              left_right <= YELLOW;
              state      <= YELLOW2RED;
            end
          end
        endcase
      end
      YELLOW2RED: begin
        enable_count <= '1;
        if (counter == COUNT_10S) begin
          if (up_down == YELLOW) begin
            up_down    <= RED;
            left_right <= GREEN;
          end else begin
            up_down    <= GREEN;
            left_right <= RED;
          end
          state      <= W4BUTTON;
        end
      end
    endcase // case INIT_UD_GREEN
  end // always @ (posedge CLK)

  initial begin
    light_count = '0;
  end

  always @(posedge clk) begin
    if (pwm_count == COUNT_500US - 1) begin
      pwm_count   <= '0;
      light_count <= ~light_count;
    end else begin
      pwm_count   <= pwm_count + 1;
    end

    R           <= '0;
    G           <= '0;
    B           <= '0;

    if (light_count) begin
      case (left_right)
        GREEN: begin
          G[0] <= '1;
        end
        YELLOW: begin
          R[0] <= '1;
          G[0] <= '1;
        end
        RED: begin
          R[0] <= '1;
        end
      endcase // case (left_right)
      case (up_down)
        GREEN: begin
          G[1] <= '1;
        end
        YELLOW: begin
          R[1] <= '1;
          G[1] <= '1;
        end
        RED: begin
          R[1] <= '1;
        end
      endcase // case (left_right)
    end
  end
endmodule // calculator_top
