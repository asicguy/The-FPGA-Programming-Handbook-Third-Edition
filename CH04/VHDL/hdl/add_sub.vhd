-- add_sub.vhd
-- ------------------------------------
-- Simple combinational adder subtractor block
-- ------------------------------------
-- Author : Frank Bruno
-- Take in a number of bits, split into two halves and add.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity add_sub is
  generic(
    SELECTOR : string  := "";
    BITS     : integer := 8
  );
  port(
    PL_USER_SW  : in  std_logic_vector(BITS - 1 downto 0);
    PL_USER_LED : out std_logic_vector(BITS - 1 downto 0)
  );
end entity add_sub;

architecture rtl of add_sub is
begin

  adder : process(all)
    variable a_in   : signed(BITS - 1 downto 0);
    variable b_in   : signed(BITS - 1 downto 0);
    variable result : signed(BITS - 1 downto 0);
  begin
    a_in := resize(signed(PL_USER_SW(BITS - 1 downto BITS / 2)), BITS);
    b_in := resize(signed(PL_USER_SW(BITS / 2 - 1 downto 0)), BITS);

    if (SELECTOR = "ADD") then
      result := a_in + b_in;
    else
      result := a_in - b_in;
    end if;
    PL_USER_LED <= std_logic_vector(result);
  end process adder;

end architecture rtl;
