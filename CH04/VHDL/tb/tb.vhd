-- tb.vhd
-- ------------------------------------
-- Testbench for Project 2
-- ------------------------------------
-- Author : Frank Bruno, Guy Eschemann
-- Exhaustively test project_2

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.math_real.all;

entity tb is
  generic(
  SELECTOR    : string;
  UNIQUE_CASE : string;
  TEST_CASE   : string
);
end entity tb;

architecture tb of tb is

  --constant SELECTOR : string  := "UP_FOR"; -- or "DOWN_FOR"
  constant BITS     : integer := 8;
  constant NUM_TEST : integer := 1000;

  -- Count number of bits set in the SW vector
  function no_func(SW : std_logic_vector) return natural is
    variable no : natural;
  begin
    no := 0;
    for i in SW'range loop
      if SW(i) then
        no := no + 1;
      end if;
    end loop;
    return no;
  end function no_func;

  -- Return one-based index of the leading one in the SW vector
  function lo_func(SW : std_logic_vector) return natural is
    variable lo : natural;
  begin
    lo := 0;
    for i in SW'high downto SW'low loop
      if SW(i) then
        lo := i + 1;
        exit;
      end if;
    end loop;
    return lo;
  end function lo_func;

  signal PL_USER_SW   : std_logic_vector(BITS - 1 downto 0);
  signal PL_USER_LED  : std_logic_vector(BITS - 1 downto 0);
  signal PL_USER_PB   : std_logic_vector(3 downto 0);
begin

  -- Unit under test
  u_alu : entity work.project_2
    generic map(
      SELECTOR => SELECTOR,
      BITS     => BITS
    )
    port map(
      PL_USER_SW   => PL_USER_SW,
      PL_USER_PB   => PL_USER_PB,
      PL_USER_LED  => PL_USER_LED
    );

  -- Stimulus
  stimulus : process
    variable seed1, seed2 : positive;   -- seed values for random number generator
    variable rand_val     : real;       -- random real value 0 to 1.0
    variable button       : integer range 0 to 4;
  begin
    seed1 := 1;
    seed2 := 1;
    for i in 0 to NUM_TEST - 1 loop
      uniform(seed1, seed2, rand_val);  -- generate random number in range (0.0, 1.0)
      button := integer(trunc(rand_val * 5.0));
      PL_USER_PB <= (others => '0');

      case button is
        when 0 => PL_USER_PB(0) <= '1';
        when 1 => PL_USER_PB(1) <= '1';
        when 2 => PL_USER_PB(2) <= '1';
        when 3 => PL_USER_PB(3) <= '1';
      end case;

      uniform(seed1, seed2, rand_val);  -- generate random number
      PL_USER_SW <= std_logic_vector(to_unsigned(integer(trunc(rand_val * 65636.0)), PL_USER_SW'length));
      wait for 0 ps;                    -- wait for PL_USER_SW assignment to take effect
      report "setting PL_USER_SW to " & to_string(PL_USER_SW);
      wait for 100 ns;
    end loop;
    PL_USER_SW <= (others => '0');
    report "PASS: project_2 PASSED!";
    std.env.stop;
  end process stimulus;

  checker : process
    variable sw_add : signed(BITS - 1 downto 0);
    variable sw_sub : signed(BITS - 1 downto 0);
    variable sw_mul : signed(BITS - 1 downto 0);
  begin
    wait on PL_USER_SW;
    wait for 1 ps;
    if PL_USER_PB(0) then
      if lo_func(PL_USER_SW) /= unsigned(PL_USER_LED) then
        report "FAIL: PL_USER_LED != leading 1's position" severity failure;
      end if;
    end if;
    if PL_USER_PB(1) then
      if no_func(PL_USER_SW) /= unsigned(PL_USER_LED) then
        report "FAIL: PL_USER_LED != number of ones represented by PL_USER_SW" severity failure;
      end if;
    end if;
    if PL_USER_PB(2) then
      sw_add := resize(signed(PL_USER_SW(7 downto 4)), sw_add'length) + resize(signed(PL_USER_SW(3 downto 0)), sw_add'length);
      if sw_add /= signed(PL_USER_LED) then
        report "FAIL: PL_USER_LED != sum of PL_USER_SW[7:4] + PL_USER_SW[3:0] " & to_string(sw_add) & " != " & to_string(signed(PL_USER_LED)) severity failure;
      end if;
    end if;
    if PL_USER_PB(3) then
      sw_sub := resize(signed(PL_USER_SW(7 downto 4)), sw_sub'length) - resize(signed(PL_USER_SW(3 downto 0)), sw_sub'length);
      if sw_sub /= signed(PL_USER_LED) then
        report "FAIL: PL_USER_LED != diff of PL_USER_SW[7:4] - PL_USER_SW[3:0] " & to_string(sw_sub) & " != " & to_string(signed(PL_USER_LED)) severity failure;
      end if;
    end if;
    if PL_USER_PB = "0000" then
      sw_mul := signed(PL_USER_SW(7 downto 4)) * signed(PL_USER_SW(3 downto 0));
      if sw_mul /= signed(PL_USER_LED) then
        report "FAIL: PL_USER_LED != prod of PL_USER_SW[7:4] * PL_USER_SW[3:0]" severity failure;
      end if;
    end if;
  end process checker;
end architecture tb;
