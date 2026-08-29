-- sync_fifo.vhd
-- ------------------------------------
-- Synchronous first-word-fall-through FIFO
-- ------------------------------------
-- Author : Frank Bruno
--
-- Distributed-RAM style: the read is asynchronous, so dout is valid the moment
-- the FIFO is non-empty. That is what makes it first-word-fall-through, and it
-- keeps the surrounding handshake logic simple.
--
-- DEPTH must be a power of two.

LIBRARY IEEE;
USE IEEE.std_logic_1164.all;
USE IEEE.numeric_std.all;
use IEEE.math_real.all;

entity sync_fifo is
  generic (
    WIDTH : integer := 32;
    DEPTH : integer := 512
  );
  port (
    clk   : in  std_logic;
    rst_n : in  std_logic;

    wr_en : in  std_logic;
    din   : in  std_logic_vector(WIDTH-1 downto 0);

    rd_en : in  std_logic;
    dout  : out std_logic_vector(WIDTH-1 downto 0);

    empty : out std_logic;
    full  : out std_logic;
    count : out std_logic_vector(integer(ceil(log2(real(DEPTH)))) downto 0)
  );
end entity sync_fifo;

architecture rtl of sync_fifo is

  constant AW : integer := integer(ceil(log2(real(DEPTH))));

  type mem_t is array (0 to DEPTH-1) of std_logic_vector(WIDTH-1 downto 0);
  signal mem  : mem_t := (others => (others => '0'));

  signal wptr : unsigned(AW-1 downto 0) := (others => '0');
  signal rptr : unsigned(AW-1 downto 0) := (others => '0');
  signal cnt  : unsigned(AW downto 0)   := (others => '0');

  signal empty_i : std_logic;
  signal full_i  : std_logic;

begin

  dout    <= mem(to_integer(rptr));
  empty_i <= '1' when cnt = 0 else '0';
  full_i  <= '1' when cnt = to_unsigned(DEPTH, AW+1) else '0';
  empty   <= empty_i;
  full    <= full_i;
  count   <= std_logic_vector(cnt);

  process (clk) begin
    if rising_edge(clk) then
      if rst_n = '0' then
        wptr <= (others => '0');
        rptr <= (others => '0');
        cnt  <= (others => '0');
      else
        if wr_en = '1' and full_i = '0' then
          mem(to_integer(wptr)) <= din;
          wptr <= wptr + 1;
        end if;
        if rd_en = '1' and empty_i = '0' then
          rptr <= rptr + 1;
        end if;

        if (wr_en = '1' and full_i = '0') and not (rd_en = '1' and empty_i = '0') then
          cnt <= cnt + 1;
        elsif not (wr_en = '1' and full_i = '0') and (rd_en = '1' and empty_i = '0') then
          cnt <= cnt - 1;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
