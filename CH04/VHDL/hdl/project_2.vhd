-- project_2.vhd
-- ------------------------------------
-- Chapter two project
-- ------------------------------------
-- Author : Frank Bruno, Guy Eschemann
-- Combine the chapters functions together into a selectable operation

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.math_real.all;

entity project_2 is
  generic(
    SELECTOR : string;
    BITS     : integer := 8
  );
  port(
    PL_USER_SW   : in  std_logic_vector(BITS - 1 downto 0);
    PL_USER_PB   : in  std_logic_vector(3 downto 0);
    PL_USER_LED  : out std_logic_vector(BITS - 1 downto 0)
  );
end entity project_2;

architecture rtl of project_2 is

  signal LO_LED   : std_logic_vector(natural(ceil(log2(real(BITS)))) downto 0);
  signal NO_LED   : std_logic_vector(natural(ceil(log2(real(BITS)))) downto 0);
  signal AD_LED   : std_logic_vector(BITS - 1 downto 0);
  signal SB_LED   : std_logic_vector(BITS - 1 downto 0);
  signal MULT_LED : std_logic_vector(BITS - 1 downto 0);

begin

  u_lo : entity work.leading_ones
    generic map(SELECTOR => SELECTOR, BITS => BITS)
    port map(PL_USER_SW => PL_USER_SW, PL_USER_LED => LO_LED);

  u_ad : entity work.add_sub
    generic map(SELECTOR => "ADD", BITS => BITS)
    port map(PL_USER_SW => PL_USER_SW, PL_USER_LED => AD_LED);

  u_sb : entity work.add_sub
    generic map(SELECTOR => "SUB", BITS => BITS)
    port map(PL_USER_SW => PL_USER_SW, PL_USER_LED => SB_LED);

  u_no : entity work.num_ones
    generic map(BITS => BITS)
    port map(PL_USER_SW => PL_USER_SW, PL_USER_LED => NO_LED);

  u_mt : entity work.mult
    generic map(BITS => BITS)
    port map(PL_USER_SW => PL_USER_SW, PL_USER_LED => MULT_LED);

  btn_sel : process(all)
    variable sel : std_logic_vector(3 downto 0);
  begin
    sel := PL_USER_PB;
    PL_USER_LED <= (others => '0');
    case? sel is
      when "1---" => PL_USER_LED <= MULT_LED;
      when "01--" => PL_USER_LED(LO_LED'range) <= LO_LED;
      when "001-" => PL_USER_LED(NO_LED'range) <= NO_LED;
      when "0001" => PL_USER_LED <= AD_LED;
      when "0000" => PL_USER_LED <= SB_LED;
    end case?;
  end process btn_sel;

end architecture rtl;
