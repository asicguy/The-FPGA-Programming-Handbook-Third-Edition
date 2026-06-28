-- aic3104_dma.vhd
-- ----------------------------------------------------------------------------
--  TLV320AIC3104 audio capture/playback DMA top level.
--
--  VHDL port of aic3104_dma.sv. Combines:
--    * an AXI4-Lite slave register block (control/status for both directions),
--    * an I2S clock generator + serializer/deserializer (left-justified, 32-bit
--      slots, top 16 bits used; one packed L/R word per LRCLK frame),
--    * two xpm_fifo_async CDC FIFOs (AIC mclk domain <-> AXI clock domain),
--    * axi_dma_writer  (S2MM, capture: ADC stream -> DDR), and
--    * axi_dma_reader  (MM2S, playback: DDR -> DAC stream).
--
--  The writer and reader share one AXI4 (full) master: the writer drives the
--  AW/W/B channels, the reader drives the AR/R channels, so a single PS HP/HPC
--  slave port carries both capture and playback traffic.
--
--  Register map (byte offsets, AXI-Lite):
--    0x000 TX_ADDR_LO   0x004 TX_ADDR_HI   0x008 TX_BYTES    0x00C TX_START
--    0x010 TX_BYTES_READ 0x014 TX_STAT     (playback / MM2S / reader)
--    0x100 RX_ADDR_LO   0x104 RX_ADDR_HI   0x108 RX_BYTES    0x10C RX_START
--    0x110 RX_BYTES_READ 0x114 RX_STAT     (capture / S2MM / writer)
--    0x200 DEV ("3104") 0x204 VER (2)      0x208 INT
--  STAT bits: [31]=done [3]=overflow/underflow [2]=busy [1:0]=last resp.
--
--  NOTE: this uses the Xilinx XPM macro library; compile with the xpm library
--  available (Vivado does this automatically). Add the .vhd files as VHDL-2008.
-- ----------------------------------------------------------------------------
-- Author : Frank Bruno

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity aic3104_dma is
  generic (
    AXI_ADDR_WIDTH : integer := 40;     -- match the PS HP/HPC port width
    AXI_DATA_WIDTH : integer := 32;     -- 32 = one packed L/R sample per beat
    AXI_ID_WIDTH   : integer := 6;      -- ZynqMP HP IDs are wider than ZC7000
    MAX_BURST_LEN  : integer := 16;     -- AMD recommends 16 on MPSoC HP ports
    FIFO_DEPTH     : integer := 1024    -- power of two recommended
  );
  port (
    -- AXI-Lite interface for register access
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;
    s_axi_awaddr  : in  std_logic_vector(21 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(21 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    -- AXI memory master write interface (audio capture)
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

    m_axi_wdata  : out std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
    m_axi_wstrb  : out std_logic_vector(AXI_DATA_WIDTH / 8 - 1 downto 0);
    m_axi_wlast  : out std_logic;
    m_axi_wvalid : out std_logic;
    m_axi_wready : in  std_logic;

    m_axi_bid    : in  std_logic_vector(AXI_ID_WIDTH - 1 downto 0);
    m_axi_bresp  : in  std_logic_vector(1 downto 0);
    m_axi_bvalid : in  std_logic;
    m_axi_bready : out std_logic;

    -- AXI memory master read interface (playback / MM2S)
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

    m_axi_rdata  : in  std_logic_vector(AXI_DATA_WIDTH - 1 downto 0);
    m_axi_rresp  : in  std_logic_vector(1 downto 0);
    m_axi_rlast  : in  std_logic;
    m_axi_rvalid : in  std_logic;
    m_axi_rready : out std_logic;

    interrupt_out : out std_logic;

    -- I2S / codec serial interface
    AIC_mclk_o  : in  std_logic;
    AIC_lrclk_o : out std_logic;
    AIC_sclk_o  : out std_logic;
    i2s_sdata_i : in  std_logic;
    i2s_sdata_o : out std_logic
  );
end entity aic3104_dma;

architecture rtl of aic3104_dma is

  -- Register byte offsets (low 12 bits decoded)
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
  constant REG_INT           : std_logic_vector(11 downto 0) := x"208";

  type axil_rd_cs_t is (RD_IDLE, RD_WAIT, RD_W4RREADY);
  type axil_cs_t is (WR_IDLE, WR_W4ADDR, WR_W4DATA, WR_RESP);

  signal axil_rd_cs : axil_rd_cs_t := RD_IDLE;
  signal axil_cs    : axil_cs_t    := WR_IDLE;

  -- AXI-Lite register-block working signals
  signal rd_addr   : std_logic_vector(15 downto 0) := (others => '0');
  signal read_data : std_logic_vector(31 downto 0) := (others => '0');
  signal axil_din  : std_logic_vector(31 downto 0) := (others => '0');
  signal axil_be   : std_logic_vector(3 downto 0)  := (others => '0');
  signal axil_we   : std_logic                     := '0';
  signal axil_addr : std_logic_vector(15 downto 0) := (others => '0');

  signal arready_i : std_logic                     := '0';
  signal rvalid_i  : std_logic                     := '0';
  signal rdata_i   : std_logic_vector(31 downto 0) := (others => '0');
  signal awready_i : std_logic                     := '0';
  signal wready_i  : std_logic                     := '0';
  signal bvalid_i  : std_logic                     := '0';

  constant set_int     : std_logic := '0';   -- interrupt set source (unused, tied 0)
  signal   interrupt_i : std_logic := '0';

  -- Buffer descriptors (written via the register block)
  signal buf_rd_addr  : std_logic_vector(63 downto 0) := (others => '0');
  signal buf_wr_addr  : std_logic_vector(63 downto 0) := (others => '0');
  signal buf_rd_count : std_logic_vector(31 downto 0) := (others => '0');
  signal buf_wr_count : std_logic_vector(31 downto 0) := (others => '0');

  signal rd_start : std_logic := '0';
  signal wr_start : std_logic := '0';

  -- Status from the DMA engines
  signal rd_busy         : std_logic;
  signal rd_done         : std_logic;
  signal rd_bytes_written : std_logic_vector(31 downto 0);
  signal rd_overflow     : std_logic;
  signal rd_bresp        : std_logic_vector(1 downto 0);
  signal wr_busy         : std_logic;
  signal wr_done         : std_logic;
  signal wr_bytes_read   : std_logic_vector(31 downto 0);
  signal wr_underflow    : std_logic;
  signal wr_bresp        : std_logic_vector(1 downto 0);
  signal rd_tready       : std_logic;

  -- I2S timing / serializer
  signal i2s_counter : unsigned(7 downto 0)         := (others => '0');
  signal tx_dout     : std_logic_vector(63 downto 0);
  signal tx_data     : std_logic_vector(31 downto 0);
  signal rx_din      : std_logic_vector(63 downto 0) := (others => '0');
  signal rx_push     : std_logic                     := '0';
  signal tx_pop      : std_logic;
  signal i2s_sdata_o_i : std_logic := '0';

  -- CDC reset / enable synchronizers (AIC mclk domain)
  signal rst_sync : std_logic_vector(1 downto 0) := (others => '0');
  signal rx_en    : std_logic_vector(1 downto 0) := (others => '0');

  -- FIFO fabric
  signal tx_din          : std_logic_vector(31 downto 0);
  signal tx_push         : std_logic;
  signal tx_full         : std_logic;
  signal tx_empty        : std_logic;
  signal tx_rd_en        : std_logic;
  signal tx_stream_valid : std_logic;
  signal tx_stream_ready : std_logic;

  signal rx_data    : std_logic_vector(31 downto 0);
  signal rx_empty   : std_logic;
  signal rx_pop     : std_logic;
  signal rx_wr_en   : std_logic;
  signal rx_fifo_din : std_logic_vector(31 downto 0);
  signal rx_not_empty : std_logic;

begin

  -- ======================================================================
  --  AXI-Lite read channel
  -- ======================================================================
  axil_read : process (s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      arready_i <= '1';
      rvalid_i  <= '0';

      case axil_rd_cs is
        when RD_IDLE =>
          if s_axi_arvalid = '1' then
            arready_i  <= '0';
            rd_addr    <= s_axi_araddr(15 downto 0);
            axil_rd_cs <= RD_WAIT;
          end if;
        when RD_WAIT =>
          arready_i  <= '0';
          axil_rd_cs <= RD_W4RREADY;
        when RD_W4RREADY =>
          arready_i <= '0';
          rdata_i   <= read_data;
          rvalid_i  <= '1';
          if s_axi_rready = '1' and rvalid_i = '1' then
            arready_i  <= '1';
            rvalid_i   <= '0';
            axil_rd_cs <= RD_IDLE;
          end if;
      end case;

      if s_axi_aresetn = '0' then
        axil_rd_cs <= RD_IDLE;
      end if;
    end if;
  end process;

  s_axi_arready <= arready_i;
  s_axi_rvalid  <= rvalid_i;
  s_axi_rdata   <= rdata_i;
  s_axi_rresp   <= "00";

  -- ======================================================================
  --  AXI-Lite write channel
  -- ======================================================================
  axil_write : process (s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      axil_we  <= '0';
      bvalid_i <= '0';

      case axil_cs is
        when WR_IDLE =>
          awready_i <= '1';
          wready_i  <= '1';
          if s_axi_awvalid = '1' and s_axi_wvalid = '1' then
            awready_i <= '0';
            wready_i  <= '0';
            axil_addr <= s_axi_awaddr(15 downto 0);
            axil_we   <= '1';
            bvalid_i  <= '1';
            axil_din  <= s_axi_wdata;
            axil_be   <= s_axi_wstrb;
            axil_cs   <= WR_RESP;
          elsif s_axi_awvalid = '1' and s_axi_wvalid = '0' then
            -- Address only
            awready_i <= '0';
            axil_addr <= s_axi_awaddr(15 downto 0);
            axil_cs   <= WR_W4DATA;
          elsif s_axi_awvalid = '0' and s_axi_wvalid = '1' then
            wready_i <= '0';
            axil_we  <= '1';
            axil_din <= s_axi_wdata;
            axil_be  <= s_axi_wstrb;
            axil_cs  <= WR_W4ADDR;
          end if;

        when WR_W4DATA =>
          if s_axi_wvalid = '1' then
            wready_i <= '0';
            axil_we  <= '1';
            bvalid_i <= '1';
            axil_din <= s_axi_wdata;
            axil_be  <= s_axi_wstrb;
            axil_cs  <= WR_RESP;
          end if;

        when WR_W4ADDR =>
          if s_axi_awvalid = '1' then
            awready_i <= '0';
            bvalid_i  <= '1';
            axil_addr <= s_axi_awaddr(15 downto 0);
            axil_cs   <= WR_RESP;
          end if;

        when WR_RESP =>
          awready_i <= '0';
          wready_i  <= '0';
          bvalid_i  <= '1';
          if s_axi_bready = '1' then
            awready_i <= '1';
            wready_i  <= '1';
            bvalid_i  <= '0';
            axil_cs   <= WR_IDLE;
          end if;
      end case;

      if s_axi_aresetn = '0' then
        axil_cs <= WR_IDLE;
      end if;
    end if;
  end process;

  s_axi_awready <= awready_i;
  s_axi_wready  <= wready_i;
  s_axi_bvalid  <= bvalid_i;
  s_axi_bresp   <= "00";   -- always OKAY

  -- ======================================================================
  --  Register write decode
  -- ======================================================================
  reg_write : process (s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      rd_start <= '0';
      wr_start <= '0';
      if set_int = '1' then
        interrupt_i <= '1';
      end if;

      if axil_we = '1' then
        case axil_addr(11 downto 0) is
          when REG_TX_ADDR_LO =>
            for i in 0 to 3 loop
              if axil_be(i) = '1' then
                buf_rd_addr(i * 8 + 7 downto i * 8) <= axil_din(i * 8 + 7 downto i * 8);
              end if;
            end loop;
          when REG_TX_ADDR_HI =>
            for i in 0 to 3 loop
              if axil_be(i) = '1' then
                buf_rd_addr((i + 4) * 8 + 7 downto (i + 4) * 8) <= axil_din(i * 8 + 7 downto i * 8);
              end if;
            end loop;
          when REG_TX_BYTES =>
            for i in 0 to 3 loop
              if axil_be(i) = '1' then
                buf_rd_count(i * 8 + 7 downto i * 8) <= axil_din(i * 8 + 7 downto i * 8);
              end if;
            end loop;
          when REG_TX_START =>
            if axil_be(0) = '1' then
              rd_start <= '1';
            end if;
          when REG_RX_ADDR_LO =>
            for i in 0 to 3 loop
              if axil_be(i) = '1' then
                buf_wr_addr(i * 8 + 7 downto i * 8) <= axil_din(i * 8 + 7 downto i * 8);
              end if;
            end loop;
          when REG_RX_ADDR_HI =>
            for i in 0 to 3 loop
              if axil_be(i) = '1' then
                buf_wr_addr((i + 4) * 8 + 7 downto (i + 4) * 8) <= axil_din(i * 8 + 7 downto i * 8);
              end if;
            end loop;
          when REG_RX_BYTES =>
            for i in 0 to 3 loop
              if axil_be(i) = '1' then
                buf_wr_count(i * 8 + 7 downto i * 8) <= axil_din(i * 8 + 7 downto i * 8);
              end if;
            end loop;
          when REG_RX_START =>
            if axil_be(0) = '1' then
              wr_start <= '1';
            end if;
          when REG_INT =>
            if interrupt_i = '1' and axil_din(0) = '1' and axil_be(0) = '1' then
              interrupt_i <= '0';
            end if;
          when others =>
            null;
        end case;
      end if;
    end if;
  end process;

  interrupt_out <= interrupt_i;

  -- ======================================================================
  --  Register read mux
  -- ======================================================================
  reg_read : process (s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      read_data <= (others => '0');
      case rd_addr(11 downto 0) is
        when REG_TX_ADDR_LO =>
          read_data <= buf_rd_addr(31 downto 0);
        when REG_TX_ADDR_HI =>
          read_data(AXI_ADDR_WIDTH - 33 downto 0) <= buf_rd_addr(AXI_ADDR_WIDTH - 1 downto 32);
        when REG_TX_BYTES =>
          read_data <= buf_rd_count;
        when REG_TX_BYTES_READ =>
          read_data <= rd_bytes_written;
        when REG_TX_STAT =>
          read_data(31)         <= rd_done;
          read_data(1 downto 0) <= rd_bresp;
          read_data(2)          <= rd_busy;
          read_data(3)          <= rd_overflow;
        when REG_RX_ADDR_LO =>
          read_data <= buf_wr_addr(31 downto 0);
        when REG_RX_ADDR_HI =>
          read_data(AXI_ADDR_WIDTH - 33 downto 0) <= buf_wr_addr(AXI_ADDR_WIDTH - 1 downto 32);
        when REG_RX_BYTES =>
          read_data <= buf_wr_count;
        when REG_RX_BYTES_READ =>
          read_data <= wr_bytes_read;
        when REG_RX_STAT =>
          read_data(31)         <= wr_done;
          read_data(1 downto 0) <= wr_bresp;
          read_data(2)          <= wr_busy;
          read_data(3)          <= wr_underflow;
        when REG_DEV =>
          read_data <= x"33313034";   -- "3104"
        when REG_VER =>
          read_data <= x"00000002";
        when REG_INT =>
          read_data(0) <= interrupt_i;
        when others =>
          null;
      end case;
    end if;
  end process;

  -- ======================================================================
  --  I2S timing generation + serializer / deserializer
  --  Left-justified framing: 32-bit slots, MSB-first, top 16 bits carry the
  --  sample. tx_dout lays the L and R 16-bit samples into bit-reversed slot
  --  positions so a descending counter walks them out MSB-first.
  -- ======================================================================
  tx_dout <= tx_data(31 downto 16) & x"0000" & tx_data(15 downto 0) & x"0000";

  i2s : process (AIC_mclk_o)
    variable base : integer range 0 to 32;
    variable idx  : integer range 0 to 63;
  begin
    if rising_edge(AIC_mclk_o) then
      i2s_counter <= i2s_counter + 1;   -- free running counter for clock gen

      if i2s_counter = x"FF" then        -- &i2s_counter : push one frame
        rx_push <= '1';
      else
        rx_push <= '0';
      end if;

      if i2s_counter(1 downto 0) = "10" then
        if i2s_counter(7) = '1' then
          base := 32;
        else
          base := 0;
        end if;
        idx := base + (31 - to_integer(i2s_counter(6 downto 2)));
        i2s_sdata_o_i <= tx_dout(idx);
        rx_din(idx)   <= i2s_sdata_i;
      end if;
    end if;
  end process;

  i2s_sdata_o <= i2s_sdata_o_i;
  tx_pop      <= rx_push;
  AIC_lrclk_o <= i2s_counter(7);         -- $left(i2s_counter)
  AIC_sclk_o  <= std_logic(i2s_counter(1));

  -- Reset / busy synchronizers into the AIC mclk domain
  sync_proc : process (AIC_mclk_o)
  begin
    if rising_edge(AIC_mclk_o) then
      rst_sync <= rst_sync(0) & s_axi_aresetn;
      rx_en    <= rx_en(0) & wr_busy;
    end if;
  end process;

  -- ======================================================================
  --  TX FIFO (AXI clock -> AIC mclk): playback samples to the serializer
  -- ======================================================================
  tx_stream_ready <= not tx_full;
  tx_push         <= tx_stream_valid and tx_stream_ready;
  tx_rd_en        <= tx_pop and (not tx_empty);

  tx_fifo : xpm_fifo_async
    generic map (
      FIFO_WRITE_DEPTH  => 128,
      WRITE_DATA_WIDTH  => 32,
      READ_DATA_WIDTH   => 32,
      READ_MODE         => "fwft",
      FIFO_READ_LATENCY => 0
    )
    port map (
      sleep         => '0',
      rst           => not s_axi_aresetn,
      wr_clk        => s_axi_aclk,
      wr_en         => tx_push,
      din           => tx_din,
      full          => tx_full,
      prog_full     => open,
      wr_data_count => open,
      overflow      => open,
      wr_rst_busy   => open,
      almost_full   => open,
      wr_ack        => open,
      rd_clk        => AIC_mclk_o,
      rd_en         => tx_rd_en,
      dout          => tx_data,
      empty         => tx_empty,
      prog_empty    => open,
      rd_data_count => open,
      underflow     => open,
      rd_rst_busy   => open,
      almost_empty  => open,
      data_valid    => open,
      injectsbiterr => '0',
      injectdbiterr => '0',
      sbiterr       => open,
      dbiterr       => open
    );

  -- ======================================================================
  --  RX FIFO (AIC mclk -> AXI clock): captured samples to the writer
  -- ======================================================================
  rx_wr_en    <= rx_en(1) and rx_push;
  rx_fifo_din <= rx_din(63 downto 48) & rx_din(31 downto 16);
  rx_pop      <= (not rx_empty) and rd_tready;
  rx_not_empty <= not rx_empty;

  rx_fifo : xpm_fifo_async
    generic map (
      FIFO_WRITE_DEPTH  => 128,
      WRITE_DATA_WIDTH  => 32,
      READ_DATA_WIDTH   => 32,
      READ_MODE         => "fwft",
      FIFO_READ_LATENCY => 0
    )
    port map (
      sleep         => '0',
      rst           => not rst_sync(1),
      wr_clk        => AIC_mclk_o,
      wr_en         => rx_wr_en,
      din           => rx_fifo_din,
      full          => open,
      prog_full     => open,
      wr_data_count => open,
      overflow      => open,
      wr_rst_busy   => open,
      almost_full   => open,
      wr_ack        => open,
      rd_clk        => s_axi_aclk,
      rd_en         => rx_pop,
      dout          => rx_data,
      empty         => rx_empty,
      prog_empty    => open,
      rd_data_count => open,
      underflow     => open,
      rd_rst_busy   => open,
      almost_empty  => open,
      data_valid    => open,
      injectsbiterr => '0',
      injectdbiterr => '0',
      sbiterr       => open,
      dbiterr       => open
    );

  -- ======================================================================
  --  Capture engine (S2MM): RX FIFO stream -> DDR
  -- ======================================================================
  u_axi_dma_writer : entity work.axi_dma_writer
    generic map (
      AXI_ADDR_WIDTH => AXI_ADDR_WIDTH,
      AXI_DATA_WIDTH => AXI_DATA_WIDTH,
      AXI_ID_WIDTH   => AXI_ID_WIDTH,
      MAX_BURST_LEN  => MAX_BURST_LEN,
      FIFO_DEPTH     => FIFO_DEPTH
    )
    port map (
      clk    => s_axi_aclk,
      resetn => s_axi_aresetn,

      cfg_buf_addr      => buf_wr_addr(AXI_ADDR_WIDTH - 1 downto 0),
      cfg_buf_len       => buf_wr_count,
      cfg_start         => wr_start,
      sts_busy          => wr_busy,
      sts_done          => wr_done,
      sts_bytes_written => wr_bytes_read,
      sts_overflow      => wr_underflow,
      sts_bresp         => wr_bresp,

      s_axis_tdata  => rx_data,
      s_axis_tvalid => rx_not_empty,
      s_axis_tready => rd_tready,

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

      m_axi_wdata  => m_axi_wdata,
      m_axi_wstrb  => m_axi_wstrb,
      m_axi_wlast  => m_axi_wlast,
      m_axi_wvalid => m_axi_wvalid,
      m_axi_wready => m_axi_wready,

      m_axi_bid    => m_axi_bid,
      m_axi_bresp  => m_axi_bresp,
      m_axi_bvalid => m_axi_bvalid,
      m_axi_bready => m_axi_bready
    );

  -- ======================================================================
  --  Playback engine (MM2S): DDR -> TX FIFO stream
  --  Same 32-bit packing as capture. The reader drives AR/R; the writer
  --  drives AW/W/B; together they share one HP/HPC slave port.
  -- ======================================================================
  u_axi_dma_reader : entity work.axi_dma_reader
    generic map (
      AXI_ADDR_WIDTH  => AXI_ADDR_WIDTH,
      AXI_DATA_WIDTH  => AXI_DATA_WIDTH,
      AXI_ID_WIDTH    => AXI_ID_WIDTH,
      MAX_BURST_LEN   => MAX_BURST_LEN,
      FIFO_DEPTH      => FIFO_DEPTH,
      PRIME_THRESHOLD => FIFO_DEPTH / 2
    )
    port map (
      clk    => s_axi_aclk,
      resetn => s_axi_aresetn,

      cfg_buf_addr   => buf_rd_addr(AXI_ADDR_WIDTH - 1 downto 0),
      cfg_buf_len    => buf_rd_count,
      cfg_start      => rd_start,
      sts_busy       => rd_busy,
      sts_done       => rd_done,
      sts_bytes_read => rd_bytes_written,
      sts_underflow  => rd_overflow,
      sts_rresp      => rd_bresp,

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

      m_axi_rdata  => m_axi_rdata,
      m_axi_rresp  => m_axi_rresp,
      m_axi_rlast  => m_axi_rlast,
      m_axi_rvalid => m_axi_rvalid,
      m_axi_rready => m_axi_rready,

      m_axis_tdata  => tx_din,
      m_axis_tvalid => tx_stream_valid,
      m_axis_tready => tx_stream_ready,
      m_axis_tlast  => open
    );

end architecture rtl;
