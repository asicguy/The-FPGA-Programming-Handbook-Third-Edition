-- tb_capcheck.vhd
-- ----------------------------------------------------------------------------
--  Capture-fidelity check for the VHDL aic3104_dma (S2MM deserialization).
--
--  The shipped tb_aic3104.vhd only proves the DMA loops bytes through DDR; it
--  never checks that the I2S deserializer turns the known sine input into clean
--  samples. This bench captures a few hundred frames, snoops every AXI write
--  beat, decodes the low 16 bits as a signed sample, and reports the largest
--  step between consecutive samples. A clean ~1 kHz sine at 48 kHz steps by only
--  a few thousand; a step near 32768 means the sign bit folded -> the
--  clipping/static caused by sampling the codec data one MCLK too early.
-- ----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_capcheck is
end entity tb_capcheck;

architecture sim of tb_capcheck is
  constant AXI_ADDR_WIDTH : integer := 40;
  constant AXI_DATA_WIDTH : integer := 32;
  constant AXI_ID_WIDTH   : integer := 6;
  constant MAX_BURST_LEN  : integer := 16;
  constant FIFO_DEPTH     : integer := 1024;
  constant MEM_AW         : integer := 16;
  constant NFRAMES        : integer := 240;

  constant REG_RX_ADDR_LO : std_logic_vector(11 downto 0) := x"100";
  constant REG_RX_ADDR_HI : std_logic_vector(11 downto 0) := x"104";
  constant REG_RX_BYTES   : std_logic_vector(11 downto 0) := x"108";
  constant REG_RX_START   : std_logic_vector(11 downto 0) := x"10C";
  constant REG_RX_STAT    : std_logic_vector(11 downto 0) := x"114";

  type word_arr_t is array (0 to 511) of std_logic_vector(31 downto 0);

  signal s_axi_aclk    : std_logic := '0';
  signal s_axi_aresetn : std_logic := '1';
  signal AIC_mclk_o    : std_logic := '0';
  signal rst_n         : std_logic := '1';

  signal s_axi_awaddr  : std_logic_vector(21 downto 0) := (others => '0');
  signal s_axi_awvalid : std_logic := '0';  signal s_axi_awready : std_logic;
  signal s_axi_wdata   : std_logic_vector(31 downto 0) := (others => '0');
  signal s_axi_wstrb   : std_logic_vector(3 downto 0)  := "1111";
  signal s_axi_wvalid  : std_logic := '0';  signal s_axi_wready : std_logic;
  signal s_axi_bresp   : std_logic_vector(1 downto 0);  signal s_axi_bvalid : std_logic;
  signal s_axi_bready  : std_logic := '1';
  signal s_axi_araddr  : std_logic_vector(21 downto 0) := (others => '0');
  signal s_axi_arvalid : std_logic := '0';  signal s_axi_arready : std_logic;
  signal s_axi_rdata   : std_logic_vector(31 downto 0);
  signal s_axi_rresp   : std_logic_vector(1 downto 0);
  signal s_axi_rvalid  : std_logic;  signal s_axi_rready : std_logic := '0';

  signal m_axi_awid    : std_logic_vector(AXI_ID_WIDTH-1 downto 0);
  signal m_axi_awaddr  : std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
  signal m_axi_awlen   : std_logic_vector(7 downto 0);
  signal m_axi_awsize  : std_logic_vector(2 downto 0);
  signal m_axi_awburst : std_logic_vector(1 downto 0);
  signal m_axi_awlock  : std_logic;
  signal m_axi_awcache : std_logic_vector(3 downto 0);
  signal m_axi_awprot  : std_logic_vector(2 downto 0);
  signal m_axi_awvalid : std_logic;  signal m_axi_awready : std_logic;
  signal m_axi_wdata   : std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
  signal m_axi_wstrb   : std_logic_vector(AXI_DATA_WIDTH/8-1 downto 0);
  signal m_axi_wlast   : std_logic;
  signal m_axi_wvalid  : std_logic;  signal m_axi_wready : std_logic;
  signal m_axi_bid     : std_logic_vector(AXI_ID_WIDTH-1 downto 0);
  signal m_axi_bresp   : std_logic_vector(1 downto 0);
  signal m_axi_bvalid  : std_logic;  signal m_axi_bready : std_logic;
  signal m_axi_arid    : std_logic_vector(AXI_ID_WIDTH-1 downto 0);
  signal m_axi_araddr  : std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
  signal m_axi_arlen   : std_logic_vector(7 downto 0);
  signal m_axi_arsize  : std_logic_vector(2 downto 0);
  signal m_axi_arburst : std_logic_vector(1 downto 0);
  signal m_axi_arlock  : std_logic;
  signal m_axi_arcache : std_logic_vector(3 downto 0);
  signal m_axi_arprot  : std_logic_vector(2 downto 0);
  signal m_axi_arvalid : std_logic;  signal m_axi_arready : std_logic;
  signal m_axi_rdata   : std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
  signal m_axi_rresp   : std_logic_vector(1 downto 0);
  signal m_axi_rlast   : std_logic;
  signal m_axi_rvalid  : std_logic;  signal m_axi_rready : std_logic;
  signal ram_rid       : std_logic_vector(AXI_ID_WIDTH-1 downto 0);

  signal interrupt_out : std_logic;
  signal AIC_lrclk_o   : std_logic;
  signal AIC_sclk_o    : std_logic;
  signal i2s_sdata_i   : std_logic;
  signal i2s_sdata_o   : std_logic;

  signal wr_q   : word_arr_t;
  signal wr_cnt : natural := 0;
begin
  s_axi_aclk <= not s_axi_aclk after 10 ns;
  AIC_mclk_o <= not AIC_mclk_o after 41 ns;

  dut : entity work.aic3104_dma
    generic map (AXI_ADDR_WIDTH => AXI_ADDR_WIDTH, AXI_DATA_WIDTH => AXI_DATA_WIDTH,
                 AXI_ID_WIDTH => AXI_ID_WIDTH, MAX_BURST_LEN => MAX_BURST_LEN,
                 FIFO_DEPTH => FIFO_DEPTH)
    port map (
      s_axi_aclk=>s_axi_aclk, s_axi_aresetn=>s_axi_aresetn,
      s_axi_awaddr=>s_axi_awaddr, s_axi_awvalid=>s_axi_awvalid, s_axi_awready=>s_axi_awready,
      s_axi_wdata=>s_axi_wdata, s_axi_wstrb=>s_axi_wstrb, s_axi_wvalid=>s_axi_wvalid, s_axi_wready=>s_axi_wready,
      s_axi_bresp=>s_axi_bresp, s_axi_bvalid=>s_axi_bvalid, s_axi_bready=>s_axi_bready,
      s_axi_araddr=>s_axi_araddr, s_axi_arvalid=>s_axi_arvalid, s_axi_arready=>s_axi_arready,
      s_axi_rdata=>s_axi_rdata, s_axi_rresp=>s_axi_rresp, s_axi_rvalid=>s_axi_rvalid, s_axi_rready=>s_axi_rready,
      m_axi_awid=>m_axi_awid, m_axi_awaddr=>m_axi_awaddr, m_axi_awlen=>m_axi_awlen, m_axi_awsize=>m_axi_awsize,
      m_axi_awburst=>m_axi_awburst, m_axi_awlock=>m_axi_awlock, m_axi_awcache=>m_axi_awcache, m_axi_awprot=>m_axi_awprot,
      m_axi_awvalid=>m_axi_awvalid, m_axi_awready=>m_axi_awready,
      m_axi_wdata=>m_axi_wdata, m_axi_wstrb=>m_axi_wstrb, m_axi_wlast=>m_axi_wlast,
      m_axi_wvalid=>m_axi_wvalid, m_axi_wready=>m_axi_wready,
      m_axi_bid=>m_axi_bid, m_axi_bresp=>m_axi_bresp, m_axi_bvalid=>m_axi_bvalid, m_axi_bready=>m_axi_bready,
      m_axi_arid=>m_axi_arid, m_axi_araddr=>m_axi_araddr, m_axi_arlen=>m_axi_arlen, m_axi_arsize=>m_axi_arsize,
      m_axi_arburst=>m_axi_arburst, m_axi_arlock=>m_axi_arlock, m_axi_arcache=>m_axi_arcache, m_axi_arprot=>m_axi_arprot,
      m_axi_arvalid=>m_axi_arvalid, m_axi_arready=>m_axi_arready,
      m_axi_rdata=>m_axi_rdata, m_axi_rresp=>m_axi_rresp, m_axi_rlast=>m_axi_rlast,
      m_axi_rvalid=>m_axi_rvalid, m_axi_rready=>m_axi_rready,
      interrupt_out=>interrupt_out, AIC_mclk_o=>AIC_mclk_o, AIC_lrclk_o=>AIC_lrclk_o,
      AIC_sclk_o=>AIC_sclk_o, i2s_sdata_i=>i2s_sdata_i, i2s_sdata_o=>i2s_sdata_o);

  axi_ram_i : entity work.axi_ram
    generic map (DATA_WIDTH=>AXI_DATA_WIDTH, ADDR_WIDTH=>AXI_ADDR_WIDTH, ID_WIDTH=>AXI_ID_WIDTH, MEM_AW=>MEM_AW)
    port map (clk=>s_axi_aclk, rst=>not s_axi_aresetn,
      s_axi_awid=>m_axi_awid, s_axi_awaddr=>m_axi_awaddr, s_axi_awlen=>m_axi_awlen, s_axi_awsize=>m_axi_awsize,
      s_axi_awburst=>m_axi_awburst, s_axi_awvalid=>m_axi_awvalid, s_axi_awready=>m_axi_awready,
      s_axi_wdata=>m_axi_wdata, s_axi_wstrb=>m_axi_wstrb, s_axi_wlast=>m_axi_wlast,
      s_axi_wvalid=>m_axi_wvalid, s_axi_wready=>m_axi_wready,
      s_axi_bid=>m_axi_bid, s_axi_bresp=>m_axi_bresp, s_axi_bvalid=>m_axi_bvalid, s_axi_bready=>m_axi_bready,
      s_axi_arid=>m_axi_arid, s_axi_araddr=>m_axi_araddr, s_axi_arlen=>m_axi_arlen, s_axi_arsize=>m_axi_arsize,
      s_axi_arburst=>m_axi_arburst, s_axi_arvalid=>m_axi_arvalid, s_axi_arready=>m_axi_arready,
      s_axi_rid=>ram_rid, s_axi_rdata=>m_axi_rdata, s_axi_rresp=>m_axi_rresp, s_axi_rlast=>m_axi_rlast,
      s_axi_rvalid=>m_axi_rvalid, s_axi_rready=>m_axi_rready);

  src : entity work.i2s_sine_gen
    generic map (I2S_DELAY => '0')
    port map (sclk=>AIC_mclk_o, rst_n=>rst_n, bclk=>AIC_sclk_o, lrclk=>AIC_lrclk_o, sdata=>i2s_sdata_i);

  -- snoop every captured write beat
  monitor : process (s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        wr_cnt <= 0;
      elsif m_axi_wvalid = '1' and m_axi_wready = '1' and wr_cnt < NFRAMES then
        wr_q(wr_cnt) <= m_axi_wdata;
        wr_cnt       <= wr_cnt + 1;
      end if;
    end if;
  end process;

  watchdog : process begin
    wait for 100 ms; report "TIMEOUT" severity error; finish;
  end process;

  stim : process
    variable test_reg : std_logic_vector(31 downto 0);
    variable cur, prev, d, maxd : integer;
    procedure cpu_wr_reg(addr : std_logic_vector(11 downto 0); data : std_logic_vector(31 downto 0)) is
    begin
      s_axi_awvalid <= '1'; s_axi_awaddr <= std_logic_vector(resize(unsigned(addr),22));
      s_axi_wvalid <= '1'; s_axi_wdata <= data;
      wait until rising_edge(s_axi_aclk);
      while s_axi_awready /= '1' loop wait until rising_edge(s_axi_aclk); end loop;
      s_axi_awvalid <= '0'; s_axi_wvalid <= '0';
    end procedure;
    procedure cpu_rd_reg(addr : std_logic_vector(11 downto 0)) is
    begin
      s_axi_rready <= '0'; s_axi_arvalid <= '1'; s_axi_araddr <= std_logic_vector(resize(unsigned(addr),22));
      wait until rising_edge(s_axi_aclk); s_axi_arvalid <= '0'; s_axi_rready <= '1';
      loop wait until rising_edge(s_axi_aclk); exit when s_axi_rvalid = '1'; end loop;
      s_axi_rready <= '0'; test_reg := s_axi_rdata;
    end procedure;
  begin
    rst_n <= '1'; s_axi_aresetn <= '1';
    wait until rising_edge(AIC_mclk_o); rst_n <= '0';
    for i in 0 to 99 loop wait until rising_edge(AIC_mclk_o); end loop;
    rst_n <= '1';
    wait until rising_edge(s_axi_aclk); s_axi_aresetn <= '0';
    for i in 0 to 99 loop wait until rising_edge(s_axi_aclk); end loop;
    s_axi_aresetn <= '1';
    for i in 0 to 99 loop wait until rising_edge(s_axi_aclk); end loop;

    cpu_wr_reg(REG_RX_ADDR_LO, x"00000000");
    cpu_wr_reg(REG_RX_ADDR_HI, x"00000000");
    cpu_wr_reg(REG_RX_BYTES,   std_logic_vector(to_unsigned(NFRAMES*4, 32)));
    cpu_wr_reg(REG_RX_START,   x"00000001");
    loop cpu_rd_reg(REG_RX_STAT); exit when test_reg(31) = '1'; end loop;
    for i in 0 to 99 loop wait until rising_edge(s_axi_aclk); end loop;  -- let last beats land

    -- decode low 16 bits (LEFT channel) and find the biggest step.
    -- Skip beat 0 (capture armed mid-frame).
    maxd := 0;
    prev := to_integer(signed(wr_q(1)(15 downto 0)));
    for i in 2 to NFRAMES-1 loop
      cur := to_integer(signed(wr_q(i)(15 downto 0)));
      d := cur - prev; if d < 0 then d := -d; end if;
      if d > maxd then maxd := d; end if;
      prev := cur;
    end loop;
    report "captured " & integer'image(wr_cnt) & " beats; sample[1..5] = "
      & integer'image(to_integer(signed(wr_q(1)(15 downto 0)))) & " "
      & integer'image(to_integer(signed(wr_q(2)(15 downto 0)))) & " "
      & integer'image(to_integer(signed(wr_q(3)(15 downto 0)))) & " "
      & integer'image(to_integer(signed(wr_q(4)(15 downto 0)))) & " "
      & integer'image(to_integer(signed(wr_q(5)(15 downto 0))));
    report "LEFT-channel max |delta| between consecutive samples = " & integer'image(maxd);
    if maxd < 8000 then
      report "RESULT: PASS -- capture is a clean sine (sign bit preserved)";
    else
      report "RESULT: FAIL -- sign folds at zero crossings (clipping/static)" severity error;
    end if;
    finish;
  end process;
end architecture sim;
