-- logic_ex.vhd
-- ------------------------------------
-- Example file to show combinational functions
-- ------------------------------------
-- Author : Frank Bruno
-- This file demonstrates combinational LED outputs based upon switch inputs.
-- There are multiple ways of accomplishing each function, uncomment to try them

library IEEE;
use IEEE.std_logic_1164.all;

entity logic_ex is
  port(
    PL_USER_SW  : in  std_logic_vector(1 downto 0);
    PL_USER_LED : out std_logic_vector(3 downto 0)
  );
end entity logic_ex;

architecture rtl of logic_ex is
begin

  PL_USER_LED(0) <= not PL_USER_SW(0);

  PL_USER_LED(1) <= PL_USER_SW(1) and PL_USER_SW(0);
  --PL_USER_LED(1)  <= and(PL_USER_SW); -- VHDL 2008

  PL_USER_LED(2) <= PL_USER_SW(1) or PL_USER_SW(0);
  --PL_USER_LED(2)  <= or(PL_USER_SW); -- VHDL 2008

  PL_USER_LED(3) <= PL_USER_SW(1) xor PL_USER_SW(0);
  --PL_USER_LED(3)  <= xor(PL_USER_SW); -- VHDL 2008

end architecture rtl;
