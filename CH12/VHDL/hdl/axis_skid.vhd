-- axis_skid.vhd
-- ------------------------------------
-- Two-entry output buffer for an AXI4-Stream master port
-- ------------------------------------
-- Author : Frank Bruno
--
-- The filter core decides whether to advance its pipeline partly from whether
-- the consumer can take a result, so its output valid depends combinationally
-- on the downstream ready. Inside CH11 that was harmless -- the consumer was an
-- internal FIFO. Here the consumer is an AXI4-Stream port on the edge of the
-- IP, and the protocol is explicit that TVALID must not depend on TREADY.
--
-- So the core writes into this instead. TVALID comes out of a register and
-- depends on nothing outside, while the core sees `full`, which is allowed to
-- depend on TREADY.
--
-- Two entries, not one: `full` deasserts on the same cycle the consumer takes a
-- beat, so a stalled-then-released stream resumes at full rate rather than
-- leaving a bubble behind every stall.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity axis_skid is
  generic (
    WIDTH : integer := 50
  );
  port (
    clk     : in  std_logic;
    rst_n   : in  std_logic;

    -- producer side
    wr      : in  std_logic;
    din     : in  std_logic_vector(WIDTH-1 downto 0);
    full    : out std_logic;

    -- AXI4-Stream master side
    m_valid : out std_logic;
    m_data  : out std_logic_vector(WIDTH-1 downto 0);
    m_ready : in  std_logic
  );
end entity axis_skid;

architecture rtl of axis_skid is

  type mem_t is array (0 to 1) of std_logic_vector(WIDTH-1 downto 0);
  signal mem       : mem_t;
  signal cnt       : unsigned(1 downto 0);
  signal wptr      : std_logic;
  signal rptr      : std_logic;
  signal rd        : std_logic;
  signal m_valid_i : std_logic;
  signal full_i    : std_logic;
  signal push      : std_logic;

begin

  m_valid_i <= '0' when cnt = 0 else '1';
  m_valid   <= m_valid_i;
  m_data    <= mem(0) when rptr = '0' else mem(1);
  rd        <= m_valid_i and m_ready;

  -- Room for a write if a slot is free, or if one is being freed this cycle.
  full_i    <= '1' when (cnt = 2 and rd = '0') else '0';
  full      <= full_i;
  push      <= wr and not full_i;

  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        cnt  <= (others => '0');
        wptr <= '0';
        rptr <= '0';
      else
        if push = '1' then
          if wptr = '0' then
            mem(0) <= din;
          else
            mem(1) <= din;
          end if;
          wptr <= not wptr;
        end if;

        if rd = '1' then
          rptr <= not rptr;
        end if;

        if push = '1' and rd = '0' then
          cnt <= cnt + 1;
        elsif push = '0' and rd = '1' then
          cnt <= cnt - 1;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
