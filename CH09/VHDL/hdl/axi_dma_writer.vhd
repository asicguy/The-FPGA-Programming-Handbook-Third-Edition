-- axi_dma_writer.vhd
-- ----------------------------------------------------------------------------
--  Simple stream-to-memory-map (S2MM) DMA write engine.
--
--  VHDL port of axi_dma_writer.sv (see that file for the full commentary).
--
--  Purpose:
--    Given a DDR buffer base address and a length in bytes, consume samples
--    arriving on an AXI4-Stream slave port and burst them into that buffer over
--    an AXI4 (full) master write interface. Intended to sit downstream of an
--    I2S deserializer so audio capture happens at hardware rate with the CPU
--    out of the per-sample path.
--
--  Behaviour:
--    - On a cfg_start pulse it latches cfg_buf_addr / cfg_buf_len and writes
--      exactly cfg_buf_len bytes, then asserts sts_done and returns to idle.
--    - Data is buffered in an internal FIFO. A burst is only launched once the
--      FIFO holds a full burst's worth of beats, so the AXI W channel never
--      stalls mid-burst waiting for the audio clock.
--    - Bursts are sized to never cross a 4 KB boundary and capped at
--      MAX_BURST_LEN beats. Single outstanding burst at a time.
--
--  Caveats:
--    - cfg_buf_len must be a whole multiple of (AXI_DATA_WIDTH/8) bytes.
--    - wstrb is all-ones (full-width beats only).
--    - resetn is active-low (AXI convention).
--    - Set AXI_ADDR_WIDTH to match the PS HP/HPC slave port (40 or 49 on MPSoC).
-- ----------------------------------------------------------------------------
-- Author : Frank Bruno

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity axi_dma_writer is
  generic (
    AXI_ADDR_WIDTH : integer := 40;     -- match the PS HP/HPC port width
    AXI_DATA_WIDTH : integer := 32;     -- 32 = one packed L/R sample per beat
    AXI_ID_WIDTH   : integer := 6;      -- ZynqMP HP IDs are wider than ZC7000
    MAX_BURST_LEN  : integer := 16;     -- AMD recommends 16 on MPSoC HP ports
    FIFO_DEPTH     : integer := 1024    -- power of two recommended
  );
  port (
    clk    : in std_logic;
    resetn : in std_logic;              -- active-low

    -- Control / status (drive from AXI-Lite slave or register block)
    cfg_buf_addr      : in  std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
    cfg_buf_len       : in  std_logic_vector(31 downto 0);   -- buffer size in BYTES
    cfg_start         : in  std_logic;                       -- 1-cycle pulse to begin
    sts_busy          : out std_logic;
    sts_done          : out std_logic;                       -- held high once buffer filled
    sts_bytes_written : out std_logic_vector(31 downto 0);
    sts_overflow      : out std_logic;                       -- sticky: a sample was dropped
    sts_bresp         : out std_logic_vector(1 downto 0);    -- last write response captured

    -- Audio sample input: AXI4-Stream slave
    s_axis_tdata  : in  std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;

    -- AXI4 master: write address channel
    m_axi_awid    : out std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
    m_axi_awaddr  : out std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
    m_axi_awlen   : out std_logic_vector(7 downto 0);
    m_axi_awsize  : out std_logic_vector(2 downto 0);
    m_axi_awburst : out std_logic_vector(1 downto 0);
    m_axi_awlock  : out std_logic;
    m_axi_awcache : out std_logic_vector(3 downto 0);
    m_axi_awprot  : out std_logic_vector(2 downto 0);
    m_axi_awvalid : out std_logic;
    m_axi_awready : in  std_logic;

    -- AXI4 master: write data channel
    m_axi_wdata  : out std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
    m_axi_wstrb  : out std_logic_vector(AXI_DATA_WIDTH / 8 - 1 downto 0);
    m_axi_wlast  : out std_logic;
    m_axi_wvalid : out std_logic;
    m_axi_wready : in  std_logic;

    -- AXI4 master: write response channel
    m_axi_bid    : in  std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
    m_axi_bresp  : in  std_logic_vector(1 downto 0);
    m_axi_bvalid : in  std_logic;
    m_axi_bready : out std_logic
  );
end entity axi_dma_writer;

architecture rtl of axi_dma_writer is

  -- Derived constants
  constant BYTES_PER_BEAT : integer := AXI_DATA_WIDTH / 8;
  constant AWSIZE_VAL     : integer := integer(ceil(log2(real(BYTES_PER_BEAT))));
  constant PTR_W          : integer := integer(ceil(log2(real(FIFO_DEPTH))));
  -- fifo_count is PTR_W+1 bits wide so it can represent the value FIFO_DEPTH.

  type state_t is (S_IDLE, S_DECIDE, S_ADDR, S_DATA, S_RESP, S_DONE);
  signal state : state_t := S_IDLE;

  -- Internal sample FIFO (simple synchronous FIFO)
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
  signal base_addr       : unsigned(AXI_ADDR_WIDTH - 1 downto 0) := (others => '0');
  signal total_bytes     : unsigned(31 downto 0)                 := (others => '0');
  signal bytes_committed : unsigned(31 downto 0)                 := (others => '0');
  signal burst_beats     : unsigned(8 downto 0)                  := (others => '0');
  signal beat_idx        : unsigned(8 downto 0)                  := (others => '0');

  -- Combinational burst-length computation (used in S_DECIDE)
  signal remaining_bytes  : unsigned(31 downto 0);
  signal remaining_beats  : unsigned(31 downto 0);
  signal addr_low_12      : unsigned(11 downto 0);
  signal bytes_to_4k      : unsigned(31 downto 0);
  signal beats_to_4k      : unsigned(31 downto 0);
  signal chosen_beats     : unsigned(31 downto 0);
  signal beats_this_burst : unsigned(8 downto 0);

  -- Registered AXI master outputs / status
  signal awaddr_r   : unsigned(AXI_ADDR_WIDTH - 1 downto 0) := (others => '0');
  signal awlen_r    : unsigned(7 downto 0)                  := (others => '0');
  signal awvalid_r  : std_logic                             := '0';
  signal wvalid_r   : std_logic                             := '0';
  signal bready_r   : std_logic                             := '0';
  signal busy_r     : std_logic                             := '0';
  signal done_r     : std_logic                             := '0';
  signal overflow_r : std_logic                             := '0';
  signal bresp_r    : std_logic_vector(1 downto 0)          := "00";

begin

  -- Static AXI master signal values
  m_axi_awid    <= (others => '0');
  m_axi_awsize  <= std_logic_vector(to_unsigned(AWSIZE_VAL, 3));
  m_axi_awburst <= "01";                -- INCR
  m_axi_awlock  <= '0';
  m_axi_awcache <= "0011";              -- Normal, non-cacheable, bufferable
  m_axi_awprot  <= "000";
  m_axi_wstrb   <= (others => '1');

  -- FIFO status / stream accept
  fifo_full  <= '1' when fifo_count = to_unsigned(FIFO_DEPTH, fifo_count'length) else '0';
  fifo_empty <= '1' when fifo_count = 0 else '0';
  s_axis_tready <= not fifo_full;
  fifo_push  <= s_axis_tvalid and (not fifo_full);

  -- FIFO read data drives the W channel; pop on accepted W beat.
  m_axi_wdata <= fifo_mem(to_integer(rd_ptr));
  fifo_pop    <= '1' when (state = S_DATA and wvalid_r = '1' and m_axi_wready = '1') else '0';

  -- Output wiring
  m_axi_awaddr      <= std_logic_vector(awaddr_r);
  m_axi_awlen       <= std_logic_vector(awlen_r);
  m_axi_awvalid     <= awvalid_r;
  m_axi_wvalid      <= wvalid_r;
  -- wlast tracks the beat currently being presented, so it is asserted on the
  -- same cycle as the last beat's data (while wvalid is still high) rather than
  -- one cycle late. burst_beats >= 1 whenever wvalid_r is high in S_DATA.
  m_axi_wlast       <= '1' when (state = S_DATA and wvalid_r = '1'
                                 and beat_idx = burst_beats - 1) else '0';
  m_axi_bready      <= bready_r;
  sts_busy          <= busy_r;
  sts_done          <= done_r;
  sts_overflow      <= overflow_r;
  sts_bresp         <= bresp_r;
  sts_bytes_written <= std_logic_vector(bytes_committed);

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
          fifo_mem(to_integer(wr_ptr)) <= s_axis_tdata;
          wr_ptr                       <= wr_ptr + 1;
        end if;
        if fifo_pop = '1' then
          rd_ptr <= rd_ptr + 1;
        end if;
        -- Net count update (push and pop can occur in the same cycle)
        if fifo_push = '1' and fifo_pop = '0' then
          fifo_count <= fifo_count + 1;
        elsif fifo_push = '0' and fifo_pop = '1' then
          fifo_count <= fifo_count - 1;
        end if;
      end if;
    end if;
  end process;

  -- ----------------------------------------------------------------------
  --  Combinational next-burst sizing
  -- ----------------------------------------------------------------------
  remaining_bytes <= total_bytes - bytes_committed;
  remaining_beats <= shift_right(remaining_bytes, AWSIZE_VAL);
  -- Low 12 bits of this burst's start address -> distance to the 4 KB edge.
  -- Discarding the carry gives (addr mod 4096) for free.
  addr_low_12 <= base_addr(11 downto 0) + bytes_committed(11 downto 0);
  bytes_to_4k <= to_unsigned(4096, 32) - resize(addr_low_12, 32);
  beats_to_4k <= shift_right(bytes_to_4k, AWSIZE_VAL);

  burst_size : process (remaining_beats, beats_to_4k)
    variable cb : unsigned(31 downto 0);
  begin
    -- burst = min(MAX_BURST_LEN, remaining_beats, beats_to_4k)
    cb := to_unsigned(MAX_BURST_LEN, 32);
    if remaining_beats < cb then
      cb := remaining_beats;
    end if;
    if beats_to_4k < cb then
      cb := beats_to_4k;
    end if;
    chosen_beats <= cb;
  end process;
  beats_this_burst <= chosen_beats(8 downto 0);

  -- ----------------------------------------------------------------------
  --  DMA write FSM
  -- ----------------------------------------------------------------------
  fsm : process (clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        state           <= S_IDLE;
        base_addr       <= (others => '0');
        total_bytes     <= (others => '0');
        bytes_committed <= (others => '0');
        burst_beats     <= (others => '0');
        beat_idx        <= (others => '0');
        awaddr_r        <= (others => '0');
        awlen_r         <= (others => '0');
        awvalid_r       <= '0';
        wvalid_r        <= '0';
        bready_r        <= '0';
        busy_r          <= '0';
        done_r          <= '0';
        overflow_r      <= '0';
        bresp_r         <= "00";
      else
        -- Sticky overflow: a sample was offered but the FIFO was full.
        if s_axis_tvalid = '1' and fifo_full = '1' then
          overflow_r <= '1';
        end if;

        case state is
          when S_IDLE =>
            busy_r <= '0';
            if cfg_start = '1' and cfg_buf_len /= x"00000000" then
              base_addr       <= unsigned(cfg_buf_addr);
              total_bytes     <= unsigned(cfg_buf_len);
              bytes_committed <= (others => '0');
              busy_r          <= '1';
              done_r          <= '0';
              overflow_r      <= '0';
              state           <= S_DECIDE;
            end if;

          -- Work out the next burst length and wait until the FIFO holds
          -- enough beats that the W channel won't stall mid-burst.
          when S_DECIDE =>
            if bytes_committed >= total_bytes then
              state <= S_DONE;
            elsif resize(fifo_count, 32) >= chosen_beats then
              base_addr   <= base_addr;
              burst_beats <= beats_this_burst;
              beat_idx    <= (others => '0');
              awaddr_r    <= base_addr + resize(bytes_committed, AXI_ADDR_WIDTH);
              awlen_r     <= beats_this_burst(7 downto 0) - 1;   -- awlen = beats-1
              awvalid_r   <= '1';
              state       <= S_ADDR;
            end if;

          when S_ADDR =>
            if m_axi_awready = '1' and awvalid_r = '1' then
              awvalid_r <= '0';
              wvalid_r  <= '1';
              state     <= S_DATA;
            end if;

          when S_DATA =>
            -- Gate wvalid on FIFO occupancy as a safety net; by construction
            -- the FIFO already holds >= burst_beats beats. wlast is driven
            -- combinationally (see above) so it lines up with the last beat.
            wvalid_r <= not fifo_empty;

            if wvalid_r = '1' and m_axi_wready = '1' then
              if beat_idx = burst_beats - 1 then
                -- Last beat accepted -> close out the W channel.
                wvalid_r <= '0';
                bready_r <= '1';
                state    <= S_RESP;
              else
                beat_idx <= beat_idx + 1;
              end if;
            end if;

          when S_RESP =>
            if m_axi_bvalid = '1' and bready_r = '1' then
              bready_r        <= '0';
              bresp_r         <= m_axi_bresp;
              bytes_committed <= bytes_committed
                                 + resize(shift_left(resize(burst_beats, 32), AWSIZE_VAL), 32);
              state           <= S_DECIDE;
            end if;

          when S_DONE =>
            busy_r <= '0';
            done_r <= '1';
            -- Wait for start to be deasserted before allowing re-arm.
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
