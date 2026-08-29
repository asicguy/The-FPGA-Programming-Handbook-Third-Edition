-- video_filter.vhd
-- ------------------------------------
-- BGRA gray / Sobel / invert / passthrough filter -- RTL equivalent of the
-- Vitis HLS kernel
-- ------------------------------------
-- Author : Frank Bruno
--
-- Same interfaces, same register map and bit-identical output to the HLS
-- version in CH12/HLS and to the SystemVerilog in CH12/SystemVerilog, so any of
-- the three drops into the same block design and the same notebook drives it:
--
--   s_axi_control   AXI4-Lite, 6-bit address, 32-bit data
--   m_axi_gmem0     AXI4 read,  64-bit address, 32-bit data (one pixel/beat)
--   m_axi_gmem1     AXI4 write, 64-bit address, 32-bit data
--
-- Dataflow, mirroring the three HLS stages:
--
--   gmem0 -> read master -> FIFO -> core -> FIFO -> write master -> gmem1
--
-- The difference from CH11's top level is what is in the FIFOs. CH11 converted
-- to luma between the read master and the FIFO, so both FIFOs were 8 bits wide
-- and the colour was gone before the core saw it. Colour passthrough needs that
-- colour, so here the FIFOs carry whole 32-bit pixels and the conversion moved
-- inside the core.
--
-- That is not free: at 512 deep, two 32-bit FIFOs are four times the
-- distributed RAM CH11's two 8-bit ones were, and it is the largest single cost
-- of MODE_COLOR. The depth is what it is so the read engine can keep a full
-- 256-beat burst of credit outstanding with room to spare.
--
-- Pixels are packed BGRA with blue in the low byte -- what the MIPI camera's
-- pixel_pack produces and what OpenCV hands you. See HLS/src/video_filter.hpp.

LIBRARY IEEE;
USE IEEE.std_logic_1164.all;
USE IEEE.numeric_std.all;
use IEEE.math_real.all;

entity video_filter is
  generic (
    C_S_AXI_CONTROL_ADDR_WIDTH : integer := 6;
    C_S_AXI_CONTROL_DATA_WIDTH : integer := 32;
    C_M_AXI_GMEM_ADDR_WIDTH    : integer := 64;
    C_M_AXI_GMEM_DATA_WIDTH    : integer := 32;
    C_M_AXI_GMEM_ID_WIDTH      : integer := 1;
    MAX_WIDTH                  : integer := 1920;
    FIFO_DEPTH                 : integer := 512
  );
  port (
    ap_clk    : in  std_logic;
    ap_rst_n  : in  std_logic;
    interrupt : out std_logic;

    s_axi_control_awaddr  : in  std_logic_vector(C_S_AXI_CONTROL_ADDR_WIDTH-1 downto 0);
    s_axi_control_awvalid : in  std_logic;
    s_axi_control_awready : out std_logic;
    s_axi_control_wdata   : in  std_logic_vector(C_S_AXI_CONTROL_DATA_WIDTH-1 downto 0);
    s_axi_control_wstrb   : in  std_logic_vector(C_S_AXI_CONTROL_DATA_WIDTH/8-1 downto 0);
    s_axi_control_wvalid  : in  std_logic;
    s_axi_control_wready  : out std_logic;
    s_axi_control_bresp   : out std_logic_vector(1 downto 0);
    s_axi_control_bvalid  : out std_logic;
    s_axi_control_bready  : in  std_logic;
    s_axi_control_araddr  : in  std_logic_vector(C_S_AXI_CONTROL_ADDR_WIDTH-1 downto 0);
    s_axi_control_arvalid : in  std_logic;
    s_axi_control_arready : out std_logic;
    s_axi_control_rdata   : out std_logic_vector(C_S_AXI_CONTROL_DATA_WIDTH-1 downto 0);
    s_axi_control_rresp   : out std_logic_vector(1 downto 0);
    s_axi_control_rvalid  : out std_logic;
    s_axi_control_rready  : in  std_logic;

    m_axi_gmem0_awid    : out std_logic_vector(C_M_AXI_GMEM_ID_WIDTH-1 downto 0);
    m_axi_gmem0_awaddr  : out std_logic_vector(C_M_AXI_GMEM_ADDR_WIDTH-1 downto 0);
    m_axi_gmem0_awlen   : out std_logic_vector(7 downto 0);
    m_axi_gmem0_awsize  : out std_logic_vector(2 downto 0);
    m_axi_gmem0_awburst : out std_logic_vector(1 downto 0);
    m_axi_gmem0_awlock  : out std_logic_vector(1 downto 0);
    m_axi_gmem0_awcache : out std_logic_vector(3 downto 0);
    m_axi_gmem0_awprot  : out std_logic_vector(2 downto 0);
    m_axi_gmem0_awqos   : out std_logic_vector(3 downto 0);
    m_axi_gmem0_awvalid : out std_logic;
    m_axi_gmem0_awready : in  std_logic;
    m_axi_gmem0_wdata   : out std_logic_vector(C_M_AXI_GMEM_DATA_WIDTH-1 downto 0);
    m_axi_gmem0_wstrb   : out std_logic_vector(C_M_AXI_GMEM_DATA_WIDTH/8-1 downto 0);
    m_axi_gmem0_wlast   : out std_logic;
    m_axi_gmem0_wvalid  : out std_logic;
    m_axi_gmem0_wready  : in  std_logic;
    m_axi_gmem0_bid     : in  std_logic_vector(C_M_AXI_GMEM_ID_WIDTH-1 downto 0);
    m_axi_gmem0_bresp   : in  std_logic_vector(1 downto 0);
    m_axi_gmem0_bvalid  : in  std_logic;
    m_axi_gmem0_bready  : out std_logic;
    m_axi_gmem0_arid    : out std_logic_vector(C_M_AXI_GMEM_ID_WIDTH-1 downto 0);
    m_axi_gmem0_araddr  : out std_logic_vector(C_M_AXI_GMEM_ADDR_WIDTH-1 downto 0);
    m_axi_gmem0_arlen   : out std_logic_vector(7 downto 0);
    m_axi_gmem0_arsize  : out std_logic_vector(2 downto 0);
    m_axi_gmem0_arburst : out std_logic_vector(1 downto 0);
    m_axi_gmem0_arlock  : out std_logic_vector(1 downto 0);
    m_axi_gmem0_arcache : out std_logic_vector(3 downto 0);
    m_axi_gmem0_arprot  : out std_logic_vector(2 downto 0);
    m_axi_gmem0_arqos   : out std_logic_vector(3 downto 0);
    m_axi_gmem0_arvalid : out std_logic;
    m_axi_gmem0_arready : in  std_logic;
    m_axi_gmem0_rid     : in  std_logic_vector(C_M_AXI_GMEM_ID_WIDTH-1 downto 0);
    m_axi_gmem0_rdata   : in  std_logic_vector(C_M_AXI_GMEM_DATA_WIDTH-1 downto 0);
    m_axi_gmem0_rresp   : in  std_logic_vector(1 downto 0);
    m_axi_gmem0_rlast   : in  std_logic;
    m_axi_gmem0_rvalid  : in  std_logic;
    m_axi_gmem0_rready  : out std_logic;

    m_axi_gmem1_awid    : out std_logic_vector(C_M_AXI_GMEM_ID_WIDTH-1 downto 0);
    m_axi_gmem1_awaddr  : out std_logic_vector(C_M_AXI_GMEM_ADDR_WIDTH-1 downto 0);
    m_axi_gmem1_awlen   : out std_logic_vector(7 downto 0);
    m_axi_gmem1_awsize  : out std_logic_vector(2 downto 0);
    m_axi_gmem1_awburst : out std_logic_vector(1 downto 0);
    m_axi_gmem1_awlock  : out std_logic_vector(1 downto 0);
    m_axi_gmem1_awcache : out std_logic_vector(3 downto 0);
    m_axi_gmem1_awprot  : out std_logic_vector(2 downto 0);
    m_axi_gmem1_awqos   : out std_logic_vector(3 downto 0);
    m_axi_gmem1_awvalid : out std_logic;
    m_axi_gmem1_awready : in  std_logic;
    m_axi_gmem1_wdata   : out std_logic_vector(C_M_AXI_GMEM_DATA_WIDTH-1 downto 0);
    m_axi_gmem1_wstrb   : out std_logic_vector(C_M_AXI_GMEM_DATA_WIDTH/8-1 downto 0);
    m_axi_gmem1_wlast   : out std_logic;
    m_axi_gmem1_wvalid  : out std_logic;
    m_axi_gmem1_wready  : in  std_logic;
    m_axi_gmem1_bid     : in  std_logic_vector(C_M_AXI_GMEM_ID_WIDTH-1 downto 0);
    m_axi_gmem1_bresp   : in  std_logic_vector(1 downto 0);
    m_axi_gmem1_bvalid  : in  std_logic;
    m_axi_gmem1_bready  : out std_logic;
    m_axi_gmem1_arid    : out std_logic_vector(C_M_AXI_GMEM_ID_WIDTH-1 downto 0);
    m_axi_gmem1_araddr  : out std_logic_vector(C_M_AXI_GMEM_ADDR_WIDTH-1 downto 0);
    m_axi_gmem1_arlen   : out std_logic_vector(7 downto 0);
    m_axi_gmem1_arsize  : out std_logic_vector(2 downto 0);
    m_axi_gmem1_arburst : out std_logic_vector(1 downto 0);
    m_axi_gmem1_arlock  : out std_logic_vector(1 downto 0);
    m_axi_gmem1_arcache : out std_logic_vector(3 downto 0);
    m_axi_gmem1_arprot  : out std_logic_vector(2 downto 0);
    m_axi_gmem1_arqos   : out std_logic_vector(3 downto 0);
    m_axi_gmem1_arvalid : out std_logic;
    m_axi_gmem1_arready : in  std_logic;
    m_axi_gmem1_rid     : in  std_logic_vector(C_M_AXI_GMEM_ID_WIDTH-1 downto 0);
    m_axi_gmem1_rdata   : in  std_logic_vector(C_M_AXI_GMEM_DATA_WIDTH-1 downto 0);
    m_axi_gmem1_rresp   : in  std_logic_vector(1 downto 0);
    m_axi_gmem1_rlast   : in  std_logic;
    m_axi_gmem1_rvalid  : in  std_logic;
    m_axi_gmem1_rready  : out std_logic
  );
end entity video_filter;

architecture rtl of video_filter is

  constant CNT_W : integer := integer(ceil(log2(real(FIFO_DEPTH)))) + 1;

  signal ap_start   : std_logic;
  signal ap_start_d : std_logic := '0';
  signal launch     : std_logic;
  signal ap_done    : std_logic;

  signal src_addr, dst_addr : std_logic_vector(63 downto 0);
  signal img_width, img_height, mode : std_logic_vector(31 downto 0);
  signal total_words : std_logic_vector(31 downto 0);

  signal rd_valid, rd_ready : std_logic;
  signal rd_data  : std_logic_vector(31 downto 0);
  signal in_count : std_logic_vector(CNT_W-1 downto 0);
  signal in_free  : std_logic_vector(CNT_W-1 downto 0);
  signal in_full, in_empty : std_logic;
  signal in_dout  : std_logic_vector(31 downto 0);
  signal in_wr    : std_logic;

  signal core_s_ready, core_m_valid, core_m_ready, core_done : std_logic;
  -- VHDL will not take an expression as a port actual, so these get names
  signal core_s_valid : std_logic;
  signal wr_s_valid   : std_logic;
  signal core_m_data : std_logic_vector(31 downto 0);

  signal out_full, out_empty : std_logic;
  signal out_dout  : std_logic_vector(31 downto 0);
  signal out_count : std_logic_vector(CNT_W-1 downto 0);
  signal wr_s_ready, wr_done : std_logic;
  signal out_wr : std_logic;

  signal zero_sized : std_logic;

begin

  total_words <= std_logic_vector(resize(unsigned(img_width) * unsigned(img_height), 32));

  u_ctrl : entity work.video_filter_ctrl
    generic map (ADDR_WIDTH => C_S_AXI_CONTROL_ADDR_WIDTH,
                 DATA_WIDTH => C_S_AXI_CONTROL_DATA_WIDTH)
    port map (
      clk => ap_clk, rst_n => ap_rst_n,
      awaddr => s_axi_control_awaddr, awvalid => s_axi_control_awvalid,
      awready => s_axi_control_awready, wdata => s_axi_control_wdata,
      wstrb => s_axi_control_wstrb, wvalid => s_axi_control_wvalid,
      wready => s_axi_control_wready, bresp => s_axi_control_bresp,
      bvalid => s_axi_control_bvalid, bready => s_axi_control_bready,
      araddr => s_axi_control_araddr, arvalid => s_axi_control_arvalid,
      arready => s_axi_control_arready, rdata => s_axi_control_rdata,
      rresp => s_axi_control_rresp, rvalid => s_axi_control_rvalid,
      rready => s_axi_control_rready,
      interrupt => interrupt,
      ap_start => ap_start, ap_done => ap_done,
      src_addr => src_addr, dst_addr => dst_addr,
      img_width => img_width, img_height => img_height, mode => mode);

  -- ap_start is a level; the engines want a single-cycle launch pulse
  process (ap_clk) begin
    if rising_edge(ap_clk) then
      if ap_rst_n = '0' then
        ap_start_d <= '0';
      else
        ap_start_d <= ap_start;
      end if;
    end if;
  end process;
  launch <= ap_start and (not ap_start_d);

  -- ---------------- read path ----------------
  in_free <= std_logic_vector(to_unsigned(FIFO_DEPTH, CNT_W) - unsigned(in_count));

  u_rd : entity work.video_filter_rd
    generic map (ADDR_WIDTH => C_M_AXI_GMEM_ADDR_WIDTH,
                 DATA_WIDTH => C_M_AXI_GMEM_DATA_WIDTH,
                 ID_WIDTH   => C_M_AXI_GMEM_ID_WIDTH,
                 CNT_WIDTH  => CNT_W)
    port map (
      clk => ap_clk, rst_n => ap_rst_n,
      start => launch, base_addr => src_addr, total_words => total_words,
      arid => m_axi_gmem0_arid, araddr => m_axi_gmem0_araddr,
      arlen => m_axi_gmem0_arlen, arsize => m_axi_gmem0_arsize,
      arburst => m_axi_gmem0_arburst, arvalid => m_axi_gmem0_arvalid,
      arready => m_axi_gmem0_arready,
      rdata => m_axi_gmem0_rdata, rresp => m_axi_gmem0_rresp,
      rlast => m_axi_gmem0_rlast, rvalid => m_axi_gmem0_rvalid,
      rready => m_axi_gmem0_rready,
      m_valid => rd_valid, m_data => rd_data, m_ready => rd_ready,
      m_free => in_free);

  rd_ready <= not in_full;

  in_wr <= rd_valid and rd_ready;

  u_fifo_in : entity work.sync_fifo
    generic map (WIDTH => 32, DEPTH => FIFO_DEPTH)
    port map (clk => ap_clk, rst_n => ap_rst_n,
              wr_en => in_wr, din => rd_data,
              rd_en => core_s_ready, dout => in_dout,
              empty => in_empty, full => in_full, count => in_count);

  -- ---------------- core ----------------
  u_core : entity work.video_filter_core
    generic map (MAX_WIDTH => MAX_WIDTH)
    port map (clk => ap_clk, rst_n => ap_rst_n,
              start => launch,
              img_width  => img_width(15 downto 0),
              img_height => img_height(15 downto 0),
              mode => mode, done => core_done,
              s_valid => core_s_valid, s_data => in_dout, s_ready => core_s_ready,
              m_valid => core_m_valid, m_data => core_m_data, m_ready => core_m_ready);

  core_s_valid <= not in_empty;
  wr_s_valid   <= not out_empty;
  core_m_ready <= not out_full;
  out_wr       <= core_m_valid and core_m_ready;

  u_fifo_out : entity work.sync_fifo
    generic map (WIDTH => 32, DEPTH => FIFO_DEPTH)
    port map (clk => ap_clk, rst_n => ap_rst_n,
              wr_en => out_wr, din => core_m_data,
              rd_en => wr_s_ready, dout => out_dout,
              empty => out_empty, full => out_full, count => out_count);

  u_wr : entity work.video_filter_wr
    generic map (ADDR_WIDTH => C_M_AXI_GMEM_ADDR_WIDTH,
                 DATA_WIDTH => C_M_AXI_GMEM_DATA_WIDTH,
                 ID_WIDTH   => C_M_AXI_GMEM_ID_WIDTH,
                 CNT_WIDTH  => CNT_W)
    port map (
      clk => ap_clk, rst_n => ap_rst_n,
      start => launch, base_addr => dst_addr, total_words => total_words,
      done => wr_done,
      awid => m_axi_gmem1_awid, awaddr => m_axi_gmem1_awaddr,
      awlen => m_axi_gmem1_awlen, awsize => m_axi_gmem1_awsize,
      awburst => m_axi_gmem1_awburst, awvalid => m_axi_gmem1_awvalid,
      awready => m_axi_gmem1_awready,
      wdata => m_axi_gmem1_wdata, wstrb => m_axi_gmem1_wstrb,
      wlast => m_axi_gmem1_wlast, wvalid => m_axi_gmem1_wvalid,
      wready => m_axi_gmem1_wready,
      bresp => m_axi_gmem1_bresp, bvalid => m_axi_gmem1_bvalid,
      bready => m_axi_gmem1_bready,
      s_valid => wr_s_valid, s_data => out_dout,
      s_ready => wr_s_ready, s_count => out_count);

  -- The kernel is finished when the last write response has come back. A
  -- zero-sized image never starts an engine, so complete it off the core.
  zero_sized <= '1' when unsigned(total_words) = 0 else '0';
  ap_done    <= wr_done or (zero_sized and core_done);

  -- ---------------- unused master signals ----------------
  m_axi_gmem0_awid    <= (others => '0');
  m_axi_gmem0_awaddr  <= (others => '0');
  m_axi_gmem0_awlen   <= (others => '0');
  m_axi_gmem0_awsize  <= "010";
  m_axi_gmem0_awburst <= "01";
  m_axi_gmem0_awvalid <= '0';
  m_axi_gmem0_wdata   <= (others => '0');
  m_axi_gmem0_wstrb   <= (others => '0');
  m_axi_gmem0_wlast   <= '0';
  m_axi_gmem0_wvalid  <= '0';
  m_axi_gmem0_bready  <= '1';
  m_axi_gmem0_awlock  <= "00";
  m_axi_gmem0_awcache <= "0011";
  m_axi_gmem0_awprot  <= "000";
  m_axi_gmem0_awqos   <= "0000";
  m_axi_gmem0_arlock  <= "00";
  m_axi_gmem0_arcache <= "0011";
  m_axi_gmem0_arprot  <= "000";
  m_axi_gmem0_arqos   <= "0000";

  m_axi_gmem1_arid    <= (others => '0');
  m_axi_gmem1_araddr  <= (others => '0');
  m_axi_gmem1_arlen   <= (others => '0');
  m_axi_gmem1_arsize  <= "010";
  m_axi_gmem1_arburst <= "01";
  m_axi_gmem1_arvalid <= '0';
  m_axi_gmem1_rready  <= '1';
  m_axi_gmem1_awlock  <= "00";
  m_axi_gmem1_awcache <= "0011";
  m_axi_gmem1_awprot  <= "000";
  m_axi_gmem1_awqos   <= "0000";
  m_axi_gmem1_arlock  <= "00";
  m_axi_gmem1_arcache <= "0011";
  m_axi_gmem1_arprot  <= "000";
  m_axi_gmem1_arqos   <= "0000";

end architecture rtl;
