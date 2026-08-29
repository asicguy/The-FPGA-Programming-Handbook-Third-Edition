-- video_filter_wr.vhd
-- ------------------------------------
-- AXI4 write master: streams 32-bit words out to memory
-- ------------------------------------
-- Author : Frank Bruno
--
-- Same burst rules as the read master: INCR, up to 256 beats, never crossing a
-- 4KB boundary. One burst is in flight on AW/W at a time; B responses are
-- counted separately and must all have returned before done is reported,
-- otherwise the PS could observe ap_done while writes are still in the
-- interconnect.
--
-- An AW is only issued once the upstream FIFO already holds the whole burst,
-- so W never stalls mid-burst.
--
-- Unchanged from CH11's write engine apart from the dropped `busy` output.
--
-- The B-response accounting matters more in CH12 than it did in CH11: here the
-- destination is often the DisplayPort's own frame buffer, and the notebook
-- shows that frame the instant ap_done comes back -- so a write still sitting
-- in the interconnect would be a visible tear rather than a stale byte nobody
-- looks at.

LIBRARY IEEE;
USE IEEE.std_logic_1164.all;
USE IEEE.numeric_std.all;

entity video_filter_wr is
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
    done        : out std_logic;

    awid        : out std_logic_vector(ID_WIDTH-1 downto 0);
    awaddr      : out std_logic_vector(ADDR_WIDTH-1 downto 0);
    awlen       : out std_logic_vector(7 downto 0);
    awsize      : out std_logic_vector(2 downto 0);
    awburst     : out std_logic_vector(1 downto 0);
    awvalid     : out std_logic;
    awready     : in  std_logic;

    wdata       : out std_logic_vector(DATA_WIDTH-1 downto 0);
    wstrb       : out std_logic_vector(DATA_WIDTH/8-1 downto 0);
    wlast       : out std_logic;
    wvalid      : out std_logic;
    wready      : in  std_logic;

    bresp       : in  std_logic_vector(1 downto 0);
    bvalid      : in  std_logic;
    bready      : out std_logic;

    s_valid     : in  std_logic;
    s_data      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
    s_ready     : out std_logic;
    s_count     : in  std_logic_vector(CNT_WIDTH-1 downto 0)
  );
end entity video_filter_wr;

architecture rtl of video_filter_wr is

  constant MAX_BURST : integer := 256;
  constant BYTES     : integer := DATA_WIDTH/8;

  type state_t is (IDLE, REQ, DATA_ST, WAIT_B);
  signal state : state_t := IDLE;

  signal addr_cur   : unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');
  signal words_left : unsigned(31 downto 0) := (others => '0');
  signal beats_left : unsigned(8 downto 0)  := (others => '0');
  signal b_pending  : unsigned(7 downto 0)  := (others => '0');

  signal to_4k      : unsigned(10 downto 0);
  signal burst_len  : unsigned(31 downto 0);
  signal awvalid_i  : std_logic;
  signal wvalid_i   : std_logic;
  signal bready_i   : std_logic;

begin

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

  awvalid_i <= '1' when (state = REQ and
                         resize(unsigned(s_count), 32) >= burst_len) else '0';
  wvalid_i  <= '1' when (state = DATA_ST and s_valid = '1') else '0';
  bready_i  <= '1';

  awid    <= (others => '0');
  awaddr  <= std_logic_vector(addr_cur);
  awlen   <= std_logic_vector(burst_len(7 downto 0) - 1);
  awsize  <= "010" when DATA_WIDTH = 32 else
             "011" when DATA_WIDTH = 64 else "100";
  awburst <= "01";
  awvalid <= awvalid_i;

  wdata   <= s_data;
  wstrb   <= (others => '1');
  wvalid  <= wvalid_i;
  wlast   <= '1' when (state = DATA_ST and beats_left = 1) else '0';
  -- pop only on a real W beat, never merely because WREADY happens to be high
  s_ready <= wvalid_i and wready;

  bready  <= bready_i;

  process (clk) begin
    if rising_edge(clk) then
      if rst_n = '0' then
        state      <= IDLE;
        addr_cur   <= (others => '0');
        words_left <= (others => '0');
        beats_left <= (others => '0');
        b_pending  <= (others => '0');
        done       <= '0';
      else
        done <= '0';

        -- B responses tracked independently of the AW/W state machine
        if (awvalid_i = '1' and awready = '1') and
           not (bvalid = '1' and bready_i = '1') then
          b_pending <= b_pending + 1;
        elsif not (awvalid_i = '1' and awready = '1') and
              (bvalid = '1' and bready_i = '1') then
          b_pending <= b_pending - 1;
        end if;

        case state is
          when IDLE =>
            if start = '1' and unsigned(total_words) /= 0 then
              addr_cur   <= unsigned(base_addr);
              words_left <= unsigned(total_words);
              state      <= REQ;
            end if;

          when REQ =>
            if awvalid_i = '1' and awready = '1' then
              beats_left <= burst_len(8 downto 0);
              addr_cur   <= addr_cur + resize(burst_len * BYTES, ADDR_WIDTH);
              words_left <= words_left - burst_len;
              state      <= DATA_ST;
            end if;

          when DATA_ST =>
            if wvalid_i = '1' and wready = '1' then
              beats_left <= beats_left - 1;
              if beats_left = 1 then
                if words_left = 0 then
                  state <= WAIT_B;
                else
                  state <= REQ;
                end if;
              end if;
            end if;

          when WAIT_B =>
            -- account for a response arriving in this same cycle
            if (b_pending = 0) or
               (b_pending = 1 and bvalid = '1' and bready_i = '1') then
              done  <= '1';
              state <= IDLE;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture rtl;
