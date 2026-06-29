-- tb_aic3104.vhd
-- ----------------------------------------------------------------------------
--  Native VHDL self-checking testbench for the VHDL aic3104_dma.
--
--  Mirrors the SystemVerilog tb_aic3104.sv flow, all in VHDL:
--    * i2s_sine_gen (VHDL) drives the capture serial-data input,
--    * axi_ram (VHDL) is the DDR stand-in for the AXI full master,
--    * the stimulus process drives the AXI4-Lite registers.
--
--  Test sequence:
--    1. Reset both clock domains.
--    2. Capture 128 bytes (32 frames) from the I2S source into DDR (S2MM).
--    3. Pass 1: play that buffer back (MM2S) and check the read-back beats
--       equal the captured beats (byte-exact loopback through both FIFOs).
--    4. Pass 2: backdoor-preload a 1536-beat pattern, play it back under
--       backpressure, and check no underflow + every beat matches.
--
--  Completion uses wait_done(): it waits for the sticky done bit to drop then
--  rise, so it cannot fall through on a previous transfer's completion.
-- ----------------------------------------------------------------------------
-- Author : Frank Bruno

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_aic3104 is
end entity tb_aic3104;

architecture sim of tb_aic3104 is

  -- DUT configuration
  constant AXI_ADDR_WIDTH : integer := 40;
  constant AXI_DATA_WIDTH : integer := 32;
  constant AXI_ID_WIDTH   : integer := 6;
  constant MAX_BURST_LEN  : integer := 16;
  constant FIFO_DEPTH     : integer := 1024;
  constant MEM_AW         : integer := 16;
  constant BIG_BEATS      : integer := 1536;   -- > FIFO depths: exercises backpressure

  -- Register byte offsets
  constant REG_TX_ADDR_LO    : std_logic_vector(11 downto 0) := x"000";
  constant REG_TX_ADDR_HI    : std_logic_vector(11 downto 0) := x"004";
  constant REG_TX_BYTES      : std_logic_vector(11 downto 0) := x"008";
  constant REG_TX_START      : std_logic_vector(11 downto 0) := x"00C";
  constant REG_TX_BYTES_READ : std_logic_vector(11 downto 0) := x"010";
  constant REG_TX_STAT       : std_logic_vector(11 downto 0) := x"014";
  constant REG_RX_ADDR_LO    : std_logic_vector(11 downto 0) := x"100";
  constant REG_RX_ADDR_HI    : std_logic_vector(11 downto 0) := x"104";
  constant REG_RX_BYTES      : std_logic_vector(11 downto 0) := x"108";
  constant REG_RX_START      : std_logic_vector(11 downto 0) := x"10C";
  constant REG_RX_BYTES_READ : std_logic_vector(11 downto 0) := x"110";
  constant REG_RX_STAT       : std_logic_vector(11 downto 0) := x"114";
  constant REG_DEV           : std_logic_vector(11 downto 0) := x"200";
  constant REG_VER           : std_logic_vector(11 downto 0) := x"204";

  -- Beat-recording queues (monitor)
  constant MAXBEATS : integer := 2048;
  type word_arr_t is array (0 to MAXBEATS - 1) of std_logic_vector(31 downto 0);

  -- Clocks / resets
  signal s_axi_aclk    : std_logic := '0';
  signal s_axi_aresetn : std_logic := '1';
  signal AIC_mclk_o    : std_logic := '0';
  signal rst_n         : std_logic := '1';

  -- AXI4-Lite register interface
  signal s_axi_awaddr  : std_logic_vector(21 downto 0) := (others => '0');
  signal s_axi_awvalid : std_logic := '0';
  signal s_axi_awready : std_logic;
  signal s_axi_wdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal s_axi_wstrb   : std_logic_vector(3 downto 0)  := "1111";
  signal s_axi_wvalid  : std_logic := '0';
  signal s_axi_wready  : std_logic;
  signal s_axi_bresp   : std_logic_vector(1 downto 0);
  signal s_axi_bvalid  : std_logic;
  signal s_axi_bready  : std_logic := '1';
  signal s_axi_araddr  : std_logic_vector(21 downto 0) := (others => '0');
  signal s_axi_arvalid : std_logic := '0';
  signal s_axi_arready : std_logic;
  signal s_axi_rdata   : std_logic_vector(31 downto 0);
  signal s_axi_rresp   : std_logic_vector(1 downto 0);
  signal s_axi_rvalid  : std_logic;
  signal s_axi_rready  : std_logic := '0';

  -- AXI4 full master (DUT) <-> axi_ram
  signal m_axi_awid    : std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
  signal m_axi_awaddr  : std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
  signal m_axi_awlen   : std_logic_vector(7 downto 0);
  signal m_axi_awsize  : std_logic_vector(2 downto 0);
  signal m_axi_awburst : std_logic_vector(1 downto 0);
  signal m_axi_awlock  : std_logic;
  signal m_axi_awcache : std_logic_vector(3 downto 0);
  signal m_axi_awprot  : std_logic_vector(2 downto 0);
  signal m_axi_awvalid : std_logic;
  signal m_axi_awready : std_logic;
  signal m_axi_wdata   : std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
  signal m_axi_wstrb   : std_logic_vector(AXI_DATA_WIDTH / 8 - 1 downto 0);
  signal m_axi_wlast   : std_logic;
  signal m_axi_wvalid  : std_logic;
  signal m_axi_wready  : std_logic;
  signal m_axi_bid     : std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
  signal m_axi_bresp   : std_logic_vector(1 downto 0);
  signal m_axi_bvalid  : std_logic;
  signal m_axi_bready  : std_logic;
  signal m_axi_arid    : std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
  signal m_axi_araddr  : std_logic_vector(AXI_ADDR_WIDTH - 1 downto 0);
  signal m_axi_arlen   : std_logic_vector(7 downto 0);
  signal m_axi_arsize  : std_logic_vector(2 downto 0);
  signal m_axi_arburst : std_logic_vector(1 downto 0);
  signal m_axi_arlock  : std_logic;
  signal m_axi_arcache : std_logic_vector(3 downto 0);
  signal m_axi_arprot  : std_logic_vector(2 downto 0);
  signal m_axi_arvalid : std_logic;
  signal m_axi_arready : std_logic;
  signal m_axi_rdata   : std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
  signal m_axi_rresp   : std_logic_vector(1 downto 0);
  signal m_axi_rlast   : std_logic;
  signal m_axi_rvalid  : std_logic;
  signal m_axi_rready  : std_logic;
  signal ram_rid       : std_logic_vector(AXI_ID_WIDTH - 1 downto 0);  -- DUT has no rid

  -- I2S / codec serial
  signal interrupt_out : std_logic;
  signal AIC_lrclk_o   : std_logic;
  signal AIC_sclk_o    : std_logic;
  signal i2s_sdata_i   : std_logic;
  signal i2s_sdata_o   : std_logic;

  -- Backdoor preload port
  signal bd_we    : std_logic := '0';
  signal bd_addr  : std_logic_vector(MEM_AW - 1 downto 0) := (others => '0');
  signal bd_wdata : std_logic_vector(31 downto 0)         := (others => '0');

  -- Monitor state
  signal wr_q     : word_arr_t;
  signal rd_q     : word_arr_t;
  signal wr_cnt   : natural := 0;
  signal rd_cnt   : natural := 0;
  signal rd_clear : std_logic := '0';

begin

  -- ----------------------------------------------------------------------
  --  Clocks
  -- ----------------------------------------------------------------------
  s_axi_aclk <= not s_axi_aclk after 10 ns;   -- 50 MHz AXI clock
  AIC_mclk_o <= not AIC_mclk_o after 41 ns;   -- ~12.2 MHz codec MCLK (256*fs)

  -- ----------------------------------------------------------------------
  --  DUT
  -- ----------------------------------------------------------------------
  dut : entity work.aic3104_dma
    generic map (
      AXI_ADDR_WIDTH => AXI_ADDR_WIDTH,
      AXI_DATA_WIDTH => AXI_DATA_WIDTH,
      AXI_ID_WIDTH   => AXI_ID_WIDTH,
      MAX_BURST_LEN  => MAX_BURST_LEN,
      FIFO_DEPTH     => FIFO_DEPTH
    )
    port map (
      s_axi_aclk    => s_axi_aclk,
      s_axi_aresetn => s_axi_aresetn,
      s_axi_awaddr  => s_axi_awaddr,
      s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => s_axi_awready,
      s_axi_wdata   => s_axi_wdata,
      s_axi_wstrb   => s_axi_wstrb,
      s_axi_wvalid  => s_axi_wvalid,
      s_axi_wready  => s_axi_wready,
      s_axi_bresp   => s_axi_bresp,
      s_axi_bvalid  => s_axi_bvalid,
      s_axi_bready  => s_axi_bready,
      s_axi_araddr  => s_axi_araddr,
      s_axi_arvalid => s_axi_arvalid,
      s_axi_arready => s_axi_arready,
      s_axi_rdata   => s_axi_rdata,
      s_axi_rresp   => s_axi_rresp,
      s_axi_rvalid  => s_axi_rvalid,
      s_axi_rready  => s_axi_rready,

      m_axi_awid    => m_axi_awid,
      m_axi_awaddr  => m_axi_awaddr,
      m_axi_awlen   => m_axi_awlen,
      m_axi_awsize  => m_axi_awsize,
      m_axi_awburst => m_axi_awburst,
      m_axi_awlock  => m_axi_awlock,
      m_axi_awcache => m_axi_awcache,
      m_axi_awprot  => m_axi_awprot,
      m_axi_awvalid => m_axi_awvalid,
      m_axi_awready => m_axi_awready,
      m_axi_wdata   => m_axi_wdata,
      m_axi_wstrb   => m_axi_wstrb,
      m_axi_wlast   => m_axi_wlast,
      m_axi_wvalid  => m_axi_wvalid,
      m_axi_wready  => m_axi_wready,
      m_axi_bid     => m_axi_bid,
      m_axi_bresp   => m_axi_bresp,
      m_axi_bvalid  => m_axi_bvalid,
      m_axi_bready  => m_axi_bready,

      m_axi_arid    => m_axi_arid,
      m_axi_araddr  => m_axi_araddr,
      m_axi_arlen   => m_axi_arlen,
      m_axi_arsize  => m_axi_arsize,
      m_axi_arburst => m_axi_arburst,
      m_axi_arlock  => m_axi_arlock,
      m_axi_arcache => m_axi_arcache,
      m_axi_arprot  => m_axi_arprot,
      m_axi_arvalid => m_axi_arvalid,
      m_axi_arready => m_axi_arready,
      m_axi_rdata   => m_axi_rdata,
      m_axi_rresp   => m_axi_rresp,
      m_axi_rlast   => m_axi_rlast,
      m_axi_rvalid  => m_axi_rvalid,
      m_axi_rready  => m_axi_rready,

      interrupt_out => interrupt_out,
      AIC_mclk_o    => AIC_mclk_o,
      AIC_lrclk_o   => AIC_lrclk_o,
      AIC_sclk_o    => AIC_sclk_o,
      AIC_sdata_i   => i2s_sdata_i,
      AIC_sdata_o   => i2s_sdata_o
    );

  -- ----------------------------------------------------------------------
  --  AXI memory slave (DDR stand-in)
  -- ----------------------------------------------------------------------
  axi_ram_i : entity work.axi_ram
    generic map (
      DATA_WIDTH => AXI_DATA_WIDTH,
      ADDR_WIDTH => AXI_ADDR_WIDTH,
      ID_WIDTH   => AXI_ID_WIDTH,
      MEM_AW     => MEM_AW
    )
    port map (
      clk => s_axi_aclk,
      rst => not s_axi_aresetn,

      s_axi_awid    => m_axi_awid,
      s_axi_awaddr  => m_axi_awaddr,
      s_axi_awlen   => m_axi_awlen,
      s_axi_awsize  => m_axi_awsize,
      s_axi_awburst => m_axi_awburst,
      s_axi_awvalid => m_axi_awvalid,
      s_axi_awready => m_axi_awready,
      s_axi_wdata   => m_axi_wdata,
      s_axi_wstrb   => m_axi_wstrb,
      s_axi_wlast   => m_axi_wlast,
      s_axi_wvalid  => m_axi_wvalid,
      s_axi_wready  => m_axi_wready,
      s_axi_bid     => m_axi_bid,
      s_axi_bresp   => m_axi_bresp,
      s_axi_bvalid  => m_axi_bvalid,
      s_axi_bready  => m_axi_bready,
      s_axi_arid    => m_axi_arid,
      s_axi_araddr  => m_axi_araddr,
      s_axi_arlen   => m_axi_arlen,
      s_axi_arsize  => m_axi_arsize,
      s_axi_arburst => m_axi_arburst,
      s_axi_arvalid => m_axi_arvalid,
      s_axi_arready => m_axi_arready,
      s_axi_rid     => ram_rid,
      s_axi_rdata   => m_axi_rdata,
      s_axi_rresp   => m_axi_rresp,
      s_axi_rlast   => m_axi_rlast,
      s_axi_rvalid  => m_axi_rvalid,
      s_axi_rready  => m_axi_rready,

      bd_we    => bd_we,
      bd_addr  => bd_addr,
      bd_wdata => bd_wdata
    );

  -- ----------------------------------------------------------------------
  --  I2S source feeding the capture input. Left-justified (I2S_DELAY='0')
  --  to match the DUT framing.
  -- ----------------------------------------------------------------------
  src : entity work.i2s_sine_gen
    generic map (
      I2S_DELAY => '0'
    )
    port map (
      sclk  => AIC_mclk_o,
      rst_n => rst_n,
      bclk  => AIC_sclk_o,
      lrclk => AIC_lrclk_o,
      sdata => i2s_sdata_i
    );

  -- ----------------------------------------------------------------------
  --  Loopback monitor: record every AXI write beat (capture) and read beat
  --  (playback). rd_clear restarts the read window between passes.
  -- ----------------------------------------------------------------------
  monitor : process (s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        wr_cnt <= 0;
        rd_cnt <= 0;
      else
        if m_axi_wvalid = '1' and m_axi_wready = '1' then
          wr_q(wr_cnt) <= m_axi_wdata;
          wr_cnt       <= wr_cnt + 1;
        end if;
        if rd_clear = '1' then
          rd_cnt <= 0;
        elsif m_axi_rvalid = '1' and m_axi_rready = '1' then
          rd_q(rd_cnt) <= m_axi_rdata;
          rd_cnt       <= rd_cnt + 1;
        end if;
      end if;
    end if;
  end process;

  -- ----------------------------------------------------------------------
  --  Watchdog: fail loudly rather than hang forever.
  -- ----------------------------------------------------------------------
  watchdog : process
  begin
    wait for 100 ms;
    report "TIMEOUT: testbench did not finish" severity error;
    finish;
  end process;

  -- ----------------------------------------------------------------------
  --  Stimulus
  -- ----------------------------------------------------------------------
  stim : process
    variable test_reg : std_logic_vector(31 downto 0);
    variable expw     : std_logic_vector(31 downto 0);
    variable errs     : integer := 0;

    procedure cpu_wr_reg(addr : std_logic_vector(11 downto 0);
                         data : std_logic_vector(31 downto 0)) is
    begin
      s_axi_awvalid <= '1';
      s_axi_awaddr  <= std_logic_vector(resize(unsigned(addr), 22));
      s_axi_wvalid  <= '1';
      s_axi_wdata   <= data;
      wait until rising_edge(s_axi_aclk);
      while s_axi_awready /= '1' loop
        wait until rising_edge(s_axi_aclk);
      end loop;
      s_axi_awvalid <= '0';
      s_axi_wvalid  <= '0';
    end procedure;

    procedure cpu_rd_reg(addr : std_logic_vector(11 downto 0)) is
    begin
      s_axi_rready  <= '0';
      s_axi_arvalid <= '1';
      s_axi_araddr  <= std_logic_vector(resize(unsigned(addr), 22));
      wait until rising_edge(s_axi_aclk);
      s_axi_arvalid <= '0';
      s_axi_rready  <= '1';
      loop
        wait until rising_edge(s_axi_aclk);
        exit when s_axi_rvalid = '1';
      end loop;
      s_axi_rready <= '0';
      test_reg     := s_axi_rdata;
    end procedure;

    -- Wait for completion using the two-edge done poll: the sticky done bit is
    -- still set from the previous transfer, so wait for it to drop (this
    -- transfer accepted) then rise (this transfer complete).
    procedure wait_done(stat : std_logic_vector(11 downto 0)) is
    begin
      loop cpu_rd_reg(stat); exit when test_reg(31) = '0'; end loop;
      loop cpu_rd_reg(stat); exit when test_reg(31) = '1'; end loop;
    end procedure;

    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then
        report msg severity error;
        errs := errs + 1;
      end if;
    end procedure;
  begin
    -- ---- reset both domains ----
    rst_n         <= '1';
    s_axi_aresetn <= '1';
    wait until rising_edge(AIC_mclk_o);
    rst_n <= '0';
    for i in 0 to 99 loop wait until rising_edge(AIC_mclk_o); end loop;
    rst_n <= '1';
    wait until rising_edge(s_axi_aclk);
    s_axi_aresetn <= '0';
    for i in 0 to 99 loop wait until rising_edge(s_axi_aclk); end loop;
    s_axi_aresetn <= '1';
    for i in 0 to 99 loop wait until rising_edge(s_axi_aclk); end loop;

    -- ---- sanity: identity registers ----
    cpu_rd_reg(REG_DEV);
    check(test_reg = x"33313034", "REG_DEV should read '3104'");
    cpu_rd_reg(REG_VER);
    check(test_reg = x"00000002", "REG_VER should read 2");

    -- ---- capture 128 bytes (32 frames) ----
    cpu_wr_reg(REG_RX_ADDR_LO, x"00000000");
    cpu_wr_reg(REG_RX_ADDR_HI, x"00000000");
    cpu_wr_reg(REG_RX_BYTES,   std_logic_vector(to_unsigned(128, 32)));
    cpu_wr_reg(REG_RX_START,   x"00000001");
    for i in 0 to 9999 loop wait until rising_edge(AIC_mclk_o); end loop;
    for i in 0 to 99 loop wait until rising_edge(s_axi_aclk); end loop;
    -- first RX transfer: done starts low, simple poll for done is correct here
    loop cpu_rd_reg(REG_RX_STAT); exit when test_reg(31) = '1'; end loop;
    report "Capture complete: " & integer'image(wr_cnt) & " write beats recorded";
    check(wr_cnt = 32, "capture should record 32 write beats");

    -- ---- Pass 1: small loopback ----
    cpu_wr_reg(REG_TX_ADDR_LO, x"00000000");
    cpu_wr_reg(REG_TX_ADDR_HI, x"00000000");
    cpu_wr_reg(REG_TX_BYTES,   std_logic_vector(to_unsigned(128, 32)));
    cpu_wr_reg(REG_TX_START,   x"00000001");
    wait_done(REG_TX_STAT);
    check(test_reg(3) = '0', "Pass 1: MM2S underflow - TX FIFO starved");
    cpu_rd_reg(REG_TX_BYTES_READ);
    check(test_reg = std_logic_vector(to_unsigned(128, 32)), "Pass 1: TX_BYTES_READ /= 128");

    report "Playback done: " & integer'image(rd_cnt) & " read beats recorded";
    check(rd_cnt = wr_cnt, "Pass 1: beat-count mismatch capture vs playback");
    for i in 0 to wr_cnt - 1 loop
      check(rd_q(i) = wr_q(i),
            "Pass 1: beat " & integer'image(i) & " mismatch");
    end loop;
    if errs = 0 then
      report "Pass 1 (small) loopback PASSED: " & integer'image(wr_cnt) & " beats matched";
    end if;

    -- ---- Pass 2: large-buffer backpressure ----
    -- Backdoor-preload a unique L/R word per beat: {~k[15:0], k[15:0]}.
    for k in 0 to BIG_BEATS - 1 loop
      bd_addr  <= std_logic_vector(to_unsigned(k, MEM_AW));
      bd_wdata <= (not std_logic_vector(to_unsigned(k, 16))) & std_logic_vector(to_unsigned(k, 16));
      bd_we    <= '1';
      wait until rising_edge(s_axi_aclk);
    end loop;
    bd_we <= '0';
    wait until rising_edge(s_axi_aclk);

    -- watch only this pass's reads
    rd_clear <= '1';
    wait until rising_edge(s_axi_aclk);
    rd_clear <= '0';
    wait until rising_edge(s_axi_aclk);

    cpu_wr_reg(REG_TX_ADDR_LO, x"00000000");
    cpu_wr_reg(REG_TX_ADDR_HI, x"00000000");
    cpu_wr_reg(REG_TX_BYTES,   std_logic_vector(to_unsigned(BIG_BEATS * 4, 32)));
    cpu_wr_reg(REG_TX_START,   x"00000001");
    wait_done(REG_TX_STAT);
    check(test_reg(3) = '0', "Pass 2: backpressure underflow - read-ahead fell behind");
    cpu_rd_reg(REG_TX_BYTES_READ);
    check(test_reg = std_logic_vector(to_unsigned(BIG_BEATS * 4, 32)),
          "Pass 2: TX_BYTES_READ /= BIG_BEATS*4");

    check(rd_cnt = BIG_BEATS, "Pass 2: beat-count mismatch");
    for i in 0 to BIG_BEATS - 1 loop
      expw := (not std_logic_vector(to_unsigned(i, 16))) & std_logic_vector(to_unsigned(i, 16));
      check(rd_q(i) = expw, "Pass 2: beat " & integer'image(i) & " mismatch");
    end loop;
    if errs = 0 then
      report "Pass 2 (backpressure) PASSED: " & integer'image(BIG_BEATS)
             & " beats matched, no underflow";
    end if;

    -- let the TX FIFO drain the serializer before ending
    for i in 0 to 19999 loop wait until rising_edge(AIC_mclk_o); end loop;

    if errs = 0 then
      report "==== ALL TESTS PASSED ====" severity note;
    else
      report "==== TESTS FAILED: " & integer'image(errs) & " error(s) ====" severity error;
    end if;
    finish;
  end process;

end architecture sim;
