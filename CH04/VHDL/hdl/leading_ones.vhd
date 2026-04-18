-- leading_ones.vhd
-- ------------------------------------
-- Leading ones detector module
-- ------------------------------------
-- Author : Frank Bruno, Guy Eschemann
-- Find the leading ones (highest bit set) in a vector.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.math_real.all;

entity leading_ones is
  generic(
    SELECTOR : string  := "CASE";
    BITS     : integer := 8
  );
  port(
    PL_USER_SW  : in  std_logic_vector(BITS - 1 downto 0);
    PL_USER_LED : out std_logic_vector(natural(ceil(log2(real(BITS)))) downto 0)
  );
end entity leading_ones;

architecture rtl of leading_ones is
begin

  proc : process(all)
    variable lo : natural range 0 to BITS;
  begin
    lo  := 0;
    -- Using CASE with variable sized input doesn't seem to easily be possible.
    if SELECTOR = "DOWN_FOR" then
      for i in PL_USER_SW'high downto PL_USER_SW'low loop
        if PL_USER_SW(i) then
          lo := i + 1;
          exit;
        end if;
      end loop;
    else
      for i in PL_USER_SW'low to PL_USER_SW'high loop
        if PL_USER_SW(i) then
          lo := i + 1;
        end if;
      end loop;
    end if;
    PL_USER_LED <= std_logic_vector(to_unsigned(lo, PL_USER_LED'length));
  end process proc;

end architecture rtl;
