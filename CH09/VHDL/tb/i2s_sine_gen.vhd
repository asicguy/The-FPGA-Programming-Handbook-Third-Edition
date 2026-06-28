-- i2s_sine_gen.vhd
-- ----------------------------------------------------------------------------
--  I2S transmitter with an internal sine-wave (DDS) source.  VHDL port of
--  i2s_sine_gen.sv -- a clock-follower (all I2S clocks are inputs) that drives
--  the codec serial-data line the DUT captures.
--
--    sclk  : master clock (MCLK), drives all logic (must be >> bclk)
--    bclk  : bit clock   (input); serial data updates on its falling edge
--    lrclk : word clock  (input); selects L vs R, frequency = fs
--    sdata : serial audio out, MSB-first, two's complement
--
--  bclk/lrclk are treated as asynchronous: double-flop synchronized into sclk
--  and sampled on synchronized bclk falling edges, so the block is fully
--  synchronous to sclk.
-- ----------------------------------------------------------------------------
-- Author : Frank Bruno

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity i2s_sine_gen is
  generic (
    DATA_WIDTH     : integer := 16;          -- sample width (bits)
    PHASE_WIDTH    : integer := 32;          -- phase accumulator width
    LUT_ADDR_WIDTH : integer := 8;           -- sine ROM has 2^N entries
    -- PHASE_INC = round(f_tone / fs * 2^PHASE_WIDTH); ~1 kHz @ 48 kHz, 2^32.
    PHASE_INC      : natural   := 89478485;
    R_PHASE_OFFSET : natural   := 0;         -- right-channel phase offset
    -- I2S_DELAY = '1' : standard Philips I2S (MSB delayed 1 bclk after WS)
    --           = '0' : left-justified       (MSB on the WS edge)
    I2S_DELAY      : std_logic := '1';
    WS_LEFT_LVL    : std_logic := '0'        -- lrclk level that selects LEFT
  );
  port (
    sclk  : in  std_logic;                   -- master clock (fast)
    rst_n : in  std_logic;                   -- async active-low reset
    bclk  : in  std_logic;                   -- I2S bit clock   (input)
    lrclk : in  std_logic;                   -- I2S word select (input)
    sdata : out std_logic                    -- I2S serial data (output)
  );
end entity i2s_sine_gen;

architecture rtl of i2s_sine_gen is

  constant LUT_SIZE : integer := 2 ** LUT_ADDR_WIDTH;

  -- Sine ROM, filled at elaboration time.
  type rom_t is array (0 to LUT_SIZE - 1) of signed(DATA_WIDTH - 1 downto 0);

  function init_rom return rom_t is
    variable r : rom_t;
    variable s : real;
  begin
    for i in 0 to LUT_SIZE - 1 loop
      s    := sin(2.0 * MATH_PI * real(i) / real(LUT_SIZE));
      r(i) := to_signed(integer(s * (2.0 ** (DATA_WIDTH - 1) - 1.0)), DATA_WIDTH);
    end loop;
    return r;
  end function;

  constant sine_rom : rom_t := init_rom;

  -- bclk / lrclk synchronizers + bclk falling-edge detect
  signal bclk_sync  : std_logic_vector(1 downto 0) := "00";
  signal lrclk_sync : std_logic_vector(1 downto 0) := "00";
  signal bclk_s_d   : std_logic                    := '0';
  signal bclk_s     : std_logic;
  signal lrclk_s    : std_logic;
  signal bclk_fall  : std_logic;

  -- DDS phase accumulator + combinational ROM lookups
  signal phase_acc    : unsigned(PHASE_WIDTH - 1 downto 0) := (others => '0');
  signal phase_next   : unsigned(PHASE_WIDTH - 1 downto 0);
  signal phase_next_r : unsigned(PHASE_WIDTH - 1 downto 0);
  signal idx_l        : unsigned(LUT_ADDR_WIDTH - 1 downto 0);
  signal idx_r        : unsigned(LUT_ADDR_WIDTH - 1 downto 0);
  signal sine_l_next  : signed(DATA_WIDTH - 1 downto 0);
  signal sine_r_next  : signed(DATA_WIDTH - 1 downto 0);

  -- I2S transmit engine state
  signal sample_r : signed(DATA_WIDTH - 1 downto 0)          := (others => '0');
  signal shifter  : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
  signal bit_cnt  : integer range 0 to DATA_WIDTH             := 0;
  signal ws_prev  : std_logic                                 := WS_LEFT_LVL;
  signal sdata_i  : std_logic                                 := '0';

begin

  -- Synchronizers
  sync : process (sclk, rst_n)
  begin
    if rst_n = '0' then
      bclk_sync  <= "00";
      lrclk_sync <= "00";
      bclk_s_d   <= '0';
    elsif rising_edge(sclk) then
      bclk_sync  <= bclk_sync(0) & bclk;
      lrclk_sync <= lrclk_sync(0) & lrclk;
      bclk_s_d   <= bclk_sync(1);
    end if;
  end process;

  bclk_s    <= bclk_sync(1);
  lrclk_s   <= lrclk_sync(1);
  bclk_fall <= bclk_s_d and (not bclk_s);

  -- DDS combinational network
  phase_next   <= phase_acc + to_unsigned(PHASE_INC, PHASE_WIDTH);
  phase_next_r <= phase_next + to_unsigned(R_PHASE_OFFSET, PHASE_WIDTH);
  idx_l        <= phase_next(PHASE_WIDTH - 1 downto PHASE_WIDTH - LUT_ADDR_WIDTH);
  idx_r        <= phase_next_r(PHASE_WIDTH - 1 downto PHASE_WIDTH - LUT_ADDR_WIDTH);
  sine_l_next  <= sine_rom(to_integer(idx_l));
  sine_r_next  <= sine_rom(to_integer(idx_r));

  -- I2S transmit engine: advances only on synchronized bclk falling edges.
  tx : process (sclk, rst_n)
    variable ws_changed : boolean;
    variable now_left   : boolean;
    variable new_word   : signed(DATA_WIDTH - 1 downto 0);
  begin
    if rst_n = '0' then
      phase_acc <= (others => '0');
      sample_r  <= (others => '0');
      shifter   <= (others => '0');
      bit_cnt   <= 0;
      ws_prev   <= WS_LEFT_LVL;
      sdata_i   <= '0';
    elsif rising_edge(sclk) then
      if bclk_fall = '1' then
        ws_changed := (lrclk_s /= ws_prev);
        now_left   := (lrclk_s = WS_LEFT_LVL);
        ws_prev    <= lrclk_s;

        if ws_changed then
          -- start of a new channel word
          if now_left then
            -- new audio frame: advance DDS, latch L and R samples
            new_word  := sine_l_next;
            phase_acc <= phase_next;
            sample_r  <= sine_r_next;
          else
            new_word := sample_r;
          end if;

          if I2S_DELAY = '1' then
            sdata_i <= '0';                                 -- 1-bclk delay slot
            shifter <= std_logic_vector(new_word);
            bit_cnt <= 0;
          else
            sdata_i <= new_word(DATA_WIDTH - 1);            -- MSB now
            shifter <= std_logic_vector(new_word(DATA_WIDTH - 2 downto 0)) & '0';
            bit_cnt <= 1;
          end if;
        else
          -- mid-word: stream remaining bits, then pad with 0
          if bit_cnt < DATA_WIDTH then
            sdata_i <= shifter(DATA_WIDTH - 1);
            shifter <= shifter(DATA_WIDTH - 2 downto 0) & '0';
            bit_cnt <= bit_cnt + 1;
          else
            sdata_i <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  sdata <= sdata_i;

end architecture rtl;
