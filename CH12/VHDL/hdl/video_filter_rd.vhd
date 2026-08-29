-- video_filter_rd.vhd
-- ------------------------------------
-- AXI4 read master: streams 32-bit words from memory
-- ------------------------------------
-- Author : Frank Bruno
--
-- Issues INCR bursts of up to 256 beats, never crossing a 4KB boundary (an AXI4
-- requirement, not a preference). Multiple bursts may be outstanding; all share
-- ID 0, so the interconnect must return their data in order.
--
-- Flow control is credit based. An AR is only issued when the downstream FIFO
-- has room for the whole burst, counting space already promised to bursts still
-- in flight, so R data never has to be back-pressured for lack of room.
--
-- Unchanged from CH11's read engine. It moves words and does not care what is
-- in them, which is why it needed no change when the pixel format did.

LIBRARY IEEE;
USE IEEE.std_logic_1164.all;
USE IEEE.numeric_std.all;

entity video_filter_rd is
  generic (
    ADDR_WIDTH : integer := 64;
    DATA_WIDTH : integer := 32;
    ID_WIDTH   : integer := 1;
    CNT_WIDTH  : integer := 12
  );
  port (
    clk         : in  std_logic;
    rst_n       : in  std_logic;

    start       : in  std_logic;
    base_addr   : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    total_words : in  std_logic_vector(31 downto 0);

    arid        : out std_logic_vector(ID_WIDTH-1 downto 0);
    araddr      : out std_logic_vector(ADDR_WIDTH-1 downto 0);
    arlen       : out std_logic_vector(7 downto 0);
    arsize      : out std_logic_vector(2 downto 0);
    arburst     : out std_logic_vector(1 downto 0);
    arvalid     : out std_logic;
    arready     : in  std_logic;

    rdata       : in  std_logic_vector(DATA_WIDTH-1 downto 0);
    rresp       : in  std_logic_vector(1 downto 0);
    rlast       : in  std_logic;
    rvalid      : in  std_logic;
    rready      : out std_logic;

    m_valid     : out std_logic;
    m_data      : out std_logic_vector(DATA_WIDTH-1 downto 0);
    m_ready     : in  std_logic;
    m_free      : in  std_logic_vector(CNT_WIDTH-1 downto 0)
  );
end entity video_filter_rd;

architecture rtl of video_filter_rd is

  constant MAX_BURST : integer := 256;
  constant BYTES     : integer := DATA_WIDTH/8;

  type state_t is (IDLE, RUN);
  signal state : state_t := IDLE;

  signal addr_cur   : unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
  signal words_left : unsigned(31 downto 0) := (others => '0');
  signal rx_left    : unsigned(31 downto 0) := (others => '0');
  signal reserved   : unsigned(CNT_WIDTH downto 0) := (others => '0');

  signal to_4k      : unsigned(10 downto 0);
  signal burst_len  : unsigned(31 downto 0);
  signal can_issue  : std_logic;
  signal arvalid_i  : std_logic;

begin

  -- words remaining before the next 4KB boundary
  to_4k <= to_unsigned(1024, 11) - ("0" & addr_cur(11 downto 2));

  process (words_left, to_4k)
    variable b : unsigned(31 downto 0);
  begin
    if words_left > to_unsigned(MAX_BURST, 32) then
      b := to_unsigned(MAX_BURST, 32);
    else
      b := words_left;
    end if;
    if b > resize(to_4k, 32) then
      b := resize(to_4k, 32);
    end if;
    burst_len <= b;
  end process;

  -- free space not already promised to a burst in flight
  can_issue <= '1' when (state = RUN and words_left /= 0 and
                         (resize(unsigned(m_free), CNT_WIDTH+2) >=
                          resize(reserved, CNT_WIDTH+2) +
                          resize(burst_len(CNT_WIDTH-1 downto 0), CNT_WIDTH+2)))
               else '0';

  arvalid_i <= can_issue;
  arvalid   <= arvalid_i;
  arid      <= (others => '0');
  araddr    <= std_logic_vector(addr_cur);
  arlen     <= std_logic_vector(burst_len(7 downto 0) - 1);
  arsize    <= "010" when DATA_WIDTH = 32 else
               "011" when DATA_WIDTH = 64 else "100";
  arburst   <= "01";

  rready  <= m_ready;
  m_valid <= rvalid;
  m_data  <= rdata;

  process (clk) begin
    if rising_edge(clk) then
      if rst_n = '0' then
        state      <= IDLE;
        addr_cur   <= (others => '0');
        words_left <= (others => '0');
        rx_left    <= (others => '0');
        reserved   <= (others => '0');
      else
        case state is
          when IDLE =>
            if start = '1' and unsigned(total_words) /= 0 then
              addr_cur   <= unsigned(base_addr);
              words_left <= unsigned(total_words);
              rx_left    <= unsigned(total_words);
              reserved   <= (others => '0');
              state      <= RUN;
            end if;

          when RUN =>
            if arvalid_i = '1' and arready = '1' then
              addr_cur   <= addr_cur + resize(burst_len * BYTES, ADDR_WIDTH);
              words_left <= words_left - burst_len;
            end if;

            if rvalid = '1' and m_ready = '1' then
              rx_left <= rx_left - 1;
              if arvalid_i = '1' and arready = '1' then
                reserved <= reserved + resize(burst_len, CNT_WIDTH+1) - 1;
              else
                reserved <= reserved - 1;
              end if;
              if rx_left = 1 then
                state <= IDLE;
              end if;
            elsif arvalid_i = '1' and arready = '1' then
              reserved <= reserved + resize(burst_len, CNT_WIDTH+1);
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
