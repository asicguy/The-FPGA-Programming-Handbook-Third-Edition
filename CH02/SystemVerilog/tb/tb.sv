// tb.vhd
// ------------------------------------
// Testbench for logic_ex
// ------------------------------------
// Author : Frank Bruno
// Exhaustively test all combinations for the logic_ex module
`timescale 1ns/ 100ps;

module tb;

  logic [1:0] PL_USER_SW;
  logic [3:0] PL_USER_LED;

  logic_ex u_logic_ex (.*);

  // Stimulus
  initial begin
    $printtimescale(tb);
    PL_USER_SW = '0;
    for (int i = 0; i < 4; i++) begin
      $display("Setting switches to %2b", i[1:0]);
      PL_USER_SW  = i[1:0];
      #100;
    end
    $info("PASS: logic_ex test PASSED!");
    $finish;
  end

  // Checking
  always @(PL_USER_LED) begin
    assert (!PL_USER_SW[0] === PL_USER_LED[0]) else begin
      $fatal("FAIL: NOT Gate mismatch");
      $stop;
    end
    assert (&PL_USER_SW[1:0] === PL_USER_LED[1]) else begin
      $fatal("FAIL: AND Gate mismatch");
      $stop;
    end
    assert (|PL_USER_SW[1:0] === PL_USER_LED[2]) else begin
      $fatal("FAIL: OR Gate mismatch");
      $stop;
    end
    assert (^PL_USER_SW[1:0] === PL_USER_LED[3]) else begin
      $fatal("FAIL: XOR Gate mismatch");
      $stop;
    end
  end
endmodule // tb
