-- axi_dma_reader.vhd
-- ----------------------------------------------------------------------------
--  Memory-map-to-stream (MM2S) DMA read engine with read-ahead.
--
--  VHDL port of axi_dma_reader.sv (see that file for the full commentary).
--
--  Purpose:
--    Given a DDR buffer base address and a length in bytes, read that buffer
--    over an AXI4 (full) master read interface and emit it as an AXI4-Stream.
--    The mirror image of axi_dma_writer -- use it to play a captured buffer
--    back out (e.g. into an I2S transmitter) at hardware rate.
--
--  Read-ahead (keeping the output FIFO from going empty):
--    1. Credit-based outstanding bursts. The engine tracks "reserved" FIFO
--       space = (beats in the FIFO) + (beats requested on AR but not yet
--       returned on R), and issues a new burst whenever
--       reserved + next_burst <= FIFO_DEPTH. Many bursts can be in flight.
--    2. Prime threshold. The stream output (tvalid) is held off at the start of
--       a transfer until the FIFO has filled to PRIME_THRESHOLD beats (or the
--       whole buffer has been fetched), hiding the initial AXI read latency.
--    sts_underflow latches high if the consumer asserts tready while the FIFO
--    is empty mid-stream -- i.e. read-ahead failed to keep up.
--
--  Caveats:
--    - cfg_buf_len must be a whole multiple of (AXI_DATA_WIDTH/8) bytes.
--    - resetn is active-low (AXI convention).
--    - PRIME_THRESHOLD must be <= FIFO_DEPTH.
--    - Set AXI_ADDR_WIDTH to match the PS HP/HPC port (40 or 49 on MPSoC).
-- ----------------------------------------------------------------------------
-- Author : Frank Bruno

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity axi_dma_reader is
  generic (
    AXI_ADDR_WIDTH  : integer := 40;    -- match the PS HP/HPC port width
    AXI_DATA_WIDTH  : integer := 32;    -- 32 = one packed L/R sample per beat
    AXI_ID_WIDTH    : integer := 6;
    MAX_BURST_LEN   : integer := 16;    -- AMD recommends 16 on MPSoC HP ports
    FIFO_DEPTH      : integer := 1024;  -- power of two recommended
    PRIME_THRESHOLD : integer := 512    -- fill cushion before streaming starts
  );
  port (
    clk    : in std_logic;
    resetn : in std_logic;              -- active-low

    -- Control / status (drive from AXI-Lite slave or register block)
    cfg_buf_addr   : in  std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
    cfg_buf_len    : in  std_logic_vector(31 downto 0);   -- buffer size in BYTES
    cfg_start      : in  std_logic;                       -- 1-cycle pulse to begin
    sts_busy       : out std_logic;
    sts_done       : out std_logic;                       -- held high once buffer streamed
    sts_bytes_read : out std_logic_vector(31 downto 0);
    sts_underflow  : out std_logic;                       -- sticky: FIFO went empty mid-stream
    sts_rresp      : out std_logic_vector(1 downto 0);    -- last read response captured

    -- AXI4 master: read address channel
    m_axi_arid    : out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
    m_axi_araddr  : out std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
    m_axi_arlen   : out std_logic_vector(7 downto 0);
    m_axi_arsize  : out std_logic_vector(2 downto 0);
    m_axi_arburst : out std_logic_vector(1 downto 0);
    m_axi_arlock  : out std_logic;
    m_axi_arcache : out std_logic_vector(3 downto 0);
    m_axi_arprot  : out std_logic_vector(2 downto 0);
    m_axi_arvalid : out std_logic;
    m_axi_arready : in  std_logic;

    -- AXI4 master: read data channel
    m_axi_rdata  : in  std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
    m_axi_rresp  : in  std_logic_vector(1 downto 0);
    m_axi_rlast  : in  std_logic;
    m_axi_rvalid : in  std_logic;
    m_axi_rready : out std_logic;

    -- AXI4-Stream master output
    m_axis_tdata  : out std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic
  );
end entity axi_dma_reader;

architecture rtl of axi_dma_reader is

  -- Derived constants
  constant BYTES_PER_BEAT : integer := AXI_DATA_WIDTH / 8;
  constant ARSIZE_VAL     : integer := integer(ceil(log2(real(BYTES_PER_BEAT))));
  constant PTR_W          : integer := integer(ceil(log2(real(FIFO_DEPTH))));

  -- Output sample FIFO
  type mem_t is array (0 to FIFO_DEPTH - 1) of std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
  signal fifo_mem   : mem_t;
  signal wr_ptr     : unsigned(PTR_W - 1 downto 0) := (others => '0');
  signal rd_ptr     : unsigned(PTR_W - 1 downto 0) := (others => '0');
  signal fifo_count : unsigned(PTR_W downto 0)     := (others => '0');

  signal fifo_push  : std_logic;
  signal fifo_pop   : std_logic;
  signal fifo_full  : std_logic;
  signal fifo_empty : std_logic;

  -- Control / counters
  type state_t is (S_IDLE, S_RUN, S_DONE);
  signal state : state_t := S_IDLE;
  signal run   : std_logic;

  signal base_addr      : unsigned(AXI_ADDR_WIDTH - 1 downto 0) := (others => '0');
  signal total_bytes    : unsigned(31 downto 0)                 := (others => '0');
  signal total_beats    : unsigned(31 downto 0)                 := (others => '0');
  signal bytes_issued   : unsigned(31 downto 0)                 := (others => '0');
  signal beats_streamed : unsigned(31 downto 0)                 := (others => '0');
  signal inflight_beats : unsigned(15 downto 0)                 := (others => '0');
  signal primed         : std_logic                             := '0';

  -- AR-issue sub-FSM
  type ar_state_t is (AR_IDLE, AR_REQ);
  signal ar_state      : ar_state_t                 := AR_IDLE;
  signal burst_beats_q : unsigned(8 downto 0)       := (others => '0');

  -- Combinational next-burst sizing
  signal remaining_bytes : unsigned(31 downto 0);
  signal remaining_beats : unsigned(31 downto 0);
  signal addr_low_12     : unsigned(11 downto 0);
  signal bytes_to_4k     : unsigned(31 downto 0);
  signal beats_to_4k     : unsigned(31 downto 0);
  signal chosen_beats    : unsigned(31 downto 0);
  signal reserved        : unsigned(31 downto 0);
  signal can_issue       : std_logic;
  signal ar_commit       : std_logic;
  signal r_beat          : std_logic;
  signal all_fetched     : std_logic;

  -- Registered AXI master outputs / status
  signal araddr_r    : unsigned(AXI_ADDR_WIDTH - 1 downto 0) := (others => '0');
  signal arlen_r     : unsigned(7 downto 0)                  := (others => '0');
  signal arvalid_r   : std_logic                             := '0';
  signal busy_r      : std_logic                             := '0';
  signal done_r      : std_logic                             := '0';
  signal underflow_r : std_logic                             := '0';
  signal rresp_r     : std_logic_vector(1 downto 0)          := "00";

  signal tvalid_i : std_logic;

begin

  -- Static AXI master signal values
  m_axi_arid    <= (others => '0');
  m_axi_arsize  <= std_logic_vector(to_unsigned(ARSIZE_VAL, 3));
  m_axi_arburst <= "01";                -- INCR
  m_axi_arlock  <= '0';
  m_axi_arcache <= "0011";              -- Normal, non-cacheable, bufferable
  m_axi_arprot  <= "000";

  run        <= '1' when state = S_RUN else '0';
  fifo_full  <= '1' when fifo_count = to_unsigned(FIFO_DEPTH, fifo_count'length) else '0';
  fifo_empty <= '1' when fifo_count = 0 else '0';

  -- R-data capture (always accept when FIFO has room)
  m_axi_rready <= not fifo_full;
  r_beat       <= m_axi_rvalid and (not fifo_full);
  fifo_push    <= r_beat;

  -- Stream output (gated by the prime cushion)
  all_fetched <= '1' when (bytes_issued >= total_bytes and inflight_beats = 0) else '0';
  m_axis_tdata <= fifo_mem(to_integer(rd_ptr));
  tvalid_i     <= run and primed and (not fifo_empty);
  m_axis_tvalid <= tvalid_i;
  m_axis_tlast  <= '1' when (tvalid_i = '1' and beats_streamed = total_beats - 1) else '0';
  fifo_pop      <= tvalid_i and m_axis_tready;

  -- AR-issue handshake commit
  ar_commit <= '1' when (ar_state = AR_REQ and arvalid_r = '1' and m_axi_arready = '1') else '0';

  -- Output wiring
  m_axi_araddr   <= std_logic_vector(araddr_r);
  m_axi_arlen    <= std_logic_vector(arlen_r);
  m_axi_arvalid  <= arvalid_r;
  sts_busy       <= busy_r;
  sts_done       <= done_r;
  sts_underflow  <= underflow_r;
  sts_rresp      <= rresp_r;
  sts_bytes_read <= std_logic_vector(bytes_issued);

  -- ----------------------------------------------------------------------
  --  Combinational next-burst sizing + read-ahead credit
  -- ----------------------------------------------------------------------
  remaining_bytes <= total_bytes - bytes_issued;
  remaining_beats <= shift_right(remaining_bytes, ARSIZE_VAL);
  addr_low_12     <= base_addr(11 downto 0) + bytes_issued(11 downto 0);
  bytes_to_4k     <= to_unsigned(4096, 32) - resize(addr_low_12, 32);
  beats_to_4k     <= shift_right(bytes_to_4k, ARSIZE_VAL);
  -- reserved = in-FIFO beats + in-flight beats
  reserved        <= resize(fifo_count, 32) + resize(inflight_beats, 32);

  sizing : process (remaining_beats, beats_to_4k, run, bytes_issued, total_bytes,
                    reserved)
    variable cb : unsigned(31 downto 0);
  begin
    -- next burst = min(MAX_BURST_LEN, remaining_beats, beats_to_4k)
    cb := to_unsigned(MAX_BURST_LEN, 32);
    if remaining_beats < cb then
      cb := remaining_beats;
    end if;
    if beats_to_4k < cb then
      cb := beats_to_4k;
    end if;
    chosen_beats <= cb;

    -- Only issue if the returning data is guaranteed a home in the FIFO.
    if run = '1' and bytes_issued < total_bytes and cb /= 0
       and (reserved + cb) <= to_unsigned(FIFO_DEPTH, 32) then
      can_issue <= '1';
    else
      can_issue <= '0';
    end if;
  end process;

  -- ----------------------------------------------------------------------
  --  AR-issue sub-FSM
  -- ----------------------------------------------------------------------
  ar_fsm : process (clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        ar_state      <= AR_IDLE;
        arvalid_r     <= '0';
        araddr_r      <= (others => '0');
        arlen_r       <= (others => '0');
        burst_beats_q <= (others => '0');
      else
        case ar_state is
          when AR_IDLE =>
            if can_issue = '1' then
              araddr_r      <= base_addr + resize(bytes_issued, AXI_ADDR_WIDTH);
              arlen_r       <= chosen_beats(7 downto 0) - 1;     -- arlen = beats-1
              burst_beats_q <= chosen_beats(8 downto 0);
              arvalid_r     <= '1';
              ar_state      <= AR_REQ;
            end if;
          when AR_REQ =>
            if m_axi_arready = '1' then
              arvalid_r <= '0';
              ar_state  <= AR_IDLE;
            end if;
          when others =>
            ar_state <= AR_IDLE;
        end case;
      end if;
    end if;
  end process;

  -- ----------------------------------------------------------------------
  --  FIFO storage + count
  -- ----------------------------------------------------------------------
  fifo_proc : process (clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        wr_ptr     <= (others => '0');
        rd_ptr     <= (others => '0');
        fifo_count <= (others => '0');
      else
        if fifo_push = '1' then
          fifo_mem(to_integer(wr_ptr)) <= m_axi_rdata;
          wr_ptr                       <= wr_ptr + 1;
        end if;
        if fifo_pop = '1' then
          rd_ptr <= rd_ptr + 1;
        end if;
        if fifo_push = '1' and fifo_pop = '0' then
          fifo_count <= fifo_count + 1;
        elsif fifo_push = '0' and fifo_pop = '1' then
          fifo_count <= fifo_count - 1;
        end if;
      end if;
    end if;
  end process;

  -- ----------------------------------------------------------------------
  --  Main control: counters, priming, completion, status
  -- ----------------------------------------------------------------------
  main : process (clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        state          <= S_IDLE;
        base_addr      <= (others => '0');
        total_bytes    <= (others => '0');
        total_beats    <= (others => '0');
        bytes_issued   <= (others => '0');
        beats_streamed <= (others => '0');
        inflight_beats <= (others => '0');
        primed         <= '0';
        busy_r         <= '0';
        done_r         <= '0';
        underflow_r    <= '0';
        rresp_r        <= "00";
      else
        -- in-flight beat accounting (commit adds, each R beat removes)
        if ar_commit = '1' and r_beat = '0' then
          inflight_beats <= inflight_beats + resize(burst_beats_q, 16);
        elsif ar_commit = '0' and r_beat = '1' then
          inflight_beats <= inflight_beats - 1;
        elsif ar_commit = '1' and r_beat = '1' then
          inflight_beats <= inflight_beats + resize(burst_beats_q, 16) - 1;
        end if;

        -- bytes issued advances when an AR is accepted
        if ar_commit = '1' then
          bytes_issued <= bytes_issued
                          + resize(shift_left(resize(burst_beats_q, 32), ARSIZE_VAL), 32);
        end if;

        -- capture read response (sticky on error)
        if r_beat = '1' and m_axi_rresp /= "00" then
          rresp_r <= m_axi_rresp;
        end if;

        -- beats streamed out
        if fifo_pop = '1' then
          beats_streamed <= beats_streamed + 1;
        end if;

        -- prime: latch high once the cushion is met (or all data is in)
        if primed = '0'
           and (fifo_count >= to_unsigned(PRIME_THRESHOLD, fifo_count'length)
                or all_fetched = '1') then
          primed <= '1';
        end if;

        -- underflow: consumer wanted data but FIFO was empty mid-stream
        if run = '1' and primed = '1' and m_axis_tready = '1' and fifo_empty = '1'
           and beats_streamed < total_beats then
          underflow_r <= '1';
        end if;

        -- top-level state machine
        case state is
          when S_IDLE =>
            busy_r <= '0';
            if cfg_start = '1' and cfg_buf_len /= x"00000000" then
              base_addr      <= unsigned(cfg_buf_addr);
              total_bytes    <= unsigned(cfg_buf_len);
              total_beats    <= shift_right(unsigned(cfg_buf_len), ARSIZE_VAL);
              bytes_issued   <= (others => '0');
              beats_streamed <= (others => '0');
              inflight_beats <= (others => '0');
              primed         <= '0';
              underflow_r    <= '0';
              busy_r         <= '1';
              done_r         <= '0';
              state          <= S_RUN;
            end if;

          when S_RUN =>
            if beats_streamed = total_beats then
              busy_r <= '0';
              done_r <= '1';
              state  <= S_DONE;
            end if;

          when S_DONE =>
            if cfg_start = '0' then
              state <= S_IDLE;
            end if;

          when others =>
            state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;
