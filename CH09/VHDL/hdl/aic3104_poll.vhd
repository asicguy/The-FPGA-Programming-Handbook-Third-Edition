-- aic3104_poll.vhd
-- ----------------------------------------------------------------------------
--  TLV320AIC3104 audio capture/playback with CPU polling (no DMA).
--
--  VHDL port of aic3104_poll.sv. The CPU streams playback samples in by writing
--  REG_TX_DATA and reads captured samples out via REG_RX_DATA, polling the
--  TX_STAT (FIFO full) / RX_STAT (FIFO empty) flags -- no AXI master / DDR.
--
--  The I2S datapath is identical to aic3104_dma: 32-bit left-justified slots
--  (top 16 bits carry the sample), bclk = mclk/4, one packed L/R word per LRCLK
--  frame, so it is compatible with the same codec configuration.
--
--  Register map (byte offsets, AXI-Lite):
--    0x000 TX_CTRL   0x004 TX_COUNT  0x008 TX_DATA (W: push)  0x00C TX_STAT[0]=full
--    0x110 RX_CTRL[0]=enable  0x114 RX_COUNT  0x118 RX_DATA (R: pop)  0x11C RX_STAT[0]=empty
--    0x200 DEV ("3104")  0x204 VER (1)  0x208 INT
--
--  NOTE: uses the Xilinx XPM macro library; add as VHDL-2008.
-- ----------------------------------------------------------------------------
-- Author : Frank Bruno

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library xpm;
use xpm.vcomponents.all;

entity aic3104_poll is
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

    interrupt_out : out std_logic;

    -- I2S / codec serial interface
    AIC_mclk_o  : in  std_logic;
    AIC_lrclk_o : out std_logic;
    AIC_sclk_o  : out std_logic;
    AIC_sdata_i : in  std_logic;
    AIC_sdata_o : out std_logic
  );
end entity aic3104_poll;

architecture rtl of aic3104_poll is

  -- Register byte offsets (low 12 bits decoded)
  constant REG_TX_CTRL  : std_logic_vector(11 downto 0) := x"000";
  constant REG_TX_COUNT : std_logic_vector(11 downto 0) := x"004";
  constant REG_TX_DATA  : std_logic_vector(11 downto 0) := x"008";
  constant REG_TX_STAT  : std_logic_vector(11 downto 0) := x"00C";
  constant REG_RX_CTRL  : std_logic_vector(11 downto 0) := x"110";
  constant REG_RX_COUNT : std_logic_vector(11 downto 0) := x"114";
  constant REG_RX_DATA  : std_logic_vector(11 downto 0) := x"118";
  constant REG_RX_STAT  : std_logic_vector(11 downto 0) := x"11C";
  constant REG_DEV      : std_logic_vector(11 downto 0) := x"200";
  constant REG_VER      : std_logic_vector(11 downto 0) := x"204";
  constant REG_INT      : std_logic_vector(11 downto 0) := x"208";
  constant REG_CFG      : std_logic_vector(11 downto 0) := x"20C";  -- [2:0]=rx sample delay

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

  -- Control / status registers
  signal tx_ctrl  : std_logic_vector(7 downto 0)  := (others => '0');
  signal rx_ctrl  : std_logic_vector(7 downto 0)  := (others => '0');
  signal tx_count : std_logic_vector(15 downto 0) := (others => '0');
  signal rx_count : std_logic_vector(15 downto 0) := (others => '0');

  -- FIFO fabric
  signal tx_data  : std_logic_vector(31 downto 0);
  signal rx_data  : std_logic_vector(31 downto 0);
  signal tx_din   : std_logic_vector(31 downto 0) := (others => '0');
  signal tx_push  : std_logic := '0';
  signal tx_pop   : std_logic;
  signal tx_full  : std_logic;
  signal tx_empty : std_logic;
  signal tx_rd_en : std_logic;
  signal rx_push  : std_logic := '0';
  signal rx_pop   : std_logic := '0';
  signal rx_empty : std_logic;
  signal rx_push_gate : std_logic;

  -- I2S timing / serializer
  signal i2s_counter   : unsigned(7 downto 0)          := (others => '0');
  signal tx_dout       : std_logic_vector(63 downto 0);
  signal rx_din        : std_logic_vector(63 downto 0) := (others => '0');
  signal i2s_sdata_o_i : std_logic                     := '0';

  -- CDC synchronizers into the AIC mclk domain
  signal rst_sync     : std_logic_vector(1 downto 0) := (others => '0');
  signal rx_ctrl_sync : std_logic_vector(1 downto 0) := (others => '0');

  -- RX capture sample-delay (board-specific codec DOUT round-trip alignment),
  -- set via REG_CFG in the AXI domain and double-flopped into the mclk domain.
  signal rx_dly      : std_logic_vector(2 downto 0) := "000";
  signal rx_dly_meta : std_logic_vector(2 downto 0) := "000";
  signal rx_dly_sync : std_logic_vector(2 downto 0) := "000";

begin

  -- ======================================================================
  --  AXI-Lite read channel (with single-pop of REG_RX_DATA on completion)
  -- ======================================================================
  axil_read : process (s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      arready_i <= '1';
      rvalid_i  <= '0';
      rx_pop    <= '0';

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
            -- Pop exactly one RX sample when a REG_RX_DATA read completes.
            if rd_addr(11 downto 0) = REG_RX_DATA then
              rx_pop <= not rx_empty;
            end if;
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
  s_axi_bresp   <= "00";

  -- ======================================================================
  --  Register write decode
  -- ======================================================================
  reg_write : process (s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      tx_push <= '0';
      if set_int = '1' then
        interrupt_i <= '1';
      end if;

      if axil_we = '1' then
        case axil_addr(11 downto 0) is
          when REG_TX_CTRL =>
            if axil_be(0) = '1' then
              tx_ctrl <= axil_din(7 downto 0);
            end if;
          when REG_TX_COUNT =>
            if axil_be(0) = '1' then tx_count(7 downto 0)  <= axil_din(7 downto 0);  end if;
            if axil_be(1) = '1' then tx_count(15 downto 8) <= axil_din(15 downto 8); end if;
          when REG_TX_DATA =>
            if axil_be /= "0000" then
              tx_push <= '1';
            end if;
            for i in 0 to 3 loop
              if axil_be(i) = '1' then
                tx_din(i * 8 + 7 downto i * 8) <= axil_din(i * 8 + 7 downto i * 8);
              end if;
            end loop;
          when REG_RX_CTRL =>
            if axil_be(0) = '1' then
              rx_ctrl <= axil_din(7 downto 0);
            end if;
          when REG_RX_COUNT =>
            if axil_be(0) = '1' then rx_count(7 downto 0)  <= axil_din(7 downto 0);  end if;
            if axil_be(1) = '1' then rx_count(15 downto 8) <= axil_din(15 downto 8); end if;
          when REG_INT =>
            if interrupt_i = '1' and axil_din(0) = '1' and axil_be(0) = '1' then
              interrupt_i <= '0';
            end if;
          when REG_CFG =>
            if axil_be(0) = '1' then
              rx_dly <= axil_din(2 downto 0);
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
        when REG_TX_CTRL  => read_data(7 downto 0)  <= tx_ctrl;
        when REG_TX_COUNT => read_data(15 downto 0) <= tx_count;
        when REG_TX_STAT  => read_data(0)           <= tx_full;
        when REG_RX_CTRL  => read_data(7 downto 0)  <= rx_ctrl;
        when REG_RX_COUNT => read_data(15 downto 0) <= rx_count;
        when REG_RX_DATA  => read_data              <= rx_data;
        when REG_RX_STAT  => read_data(0)           <= rx_empty;
        when REG_DEV      => read_data              <= x"33313034";   -- "3104"
        when REG_VER      => read_data              <= x"00000001";
        when REG_INT      => read_data(0)           <= interrupt_i;
        when REG_CFG      => read_data(2 downto 0)  <= rx_dly;
        when others       => null;
      end case;
    end if;
  end process;

  -- ======================================================================
  --  I2S timing generation + serializer / deserializer (DMA-consistent)
  -- ======================================================================
  tx_dout <= tx_data(31 downto 16) & x"0000" & tx_data(15 downto 0) & x"0000";

  i2s : process (AIC_mclk_o)
    variable base : integer range 0 to 32;
    variable idx  : integer range 0 to 63;
    variable csel : unsigned(7 downto 0);
  begin
    if rising_edge(AIC_mclk_o) then
      rst_sync     <= rst_sync(0) & s_axi_aresetn;
      rx_ctrl_sync <= rx_ctrl_sync(0) & rx_ctrl(0);
      rx_dly_meta  <= rx_dly;          -- double-flop quasi-static rx_dly into mclk
      rx_dly_sync  <= rx_dly_meta;
      i2s_counter  <= i2s_counter + 1;

      if i2s_counter = x"FF" then
        rx_push <= '1';
      else
        rx_push <= '0';
      end if;

      -- Drive TX (codec DIN) in the SCLK-high phase so the data is stable
      -- before the codec latches it on the next SCLK rising edge.
      if i2s_counter(1 downto 0) = "10" then
        if i2s_counter(7) = '1' then
          base := 32;
        else
          base := 0;
        end if;
        idx := base + (31 - to_integer(i2s_counter(6 downto 2)));
        i2s_sdata_o_i <= tx_dout(idx);
      end if;
      -- Sample RX (codec DOUT). The codec's DOUT arrives delayed by the BCLK
      -- round-trip + codec output (Tco) delay, which is board-specific and
      -- cannot be fixed in the RTL/sim. rx_dly (REG_CFG[2:0], in MCLK ticks)
      -- slides the whole sampling grid later -- both the phase and the bit-slot
      -- index move together, so the captured 16-bit sample stays aligned. Sweep
      -- rx_dly 0..7 on hardware and keep the value that gives clean audio
      -- (rx_dly = 0 reproduces the original "sample at SCLK-high" timing).
      csel := i2s_counter - resize(unsigned(rx_dly_sync), 8);
      if csel(1 downto 0) = "10" then
        if csel(7) = '1' then
          base := 32;
        else
          base := 0;
        end if;
        idx := base + (31 - to_integer(csel(6 downto 2)));
        rx_din(idx) <= AIC_sdata_i;
      end if;
    end if;
  end process;

  AIC_sdata_o  <= i2s_sdata_o_i;
  rx_push_gate <= rx_push and rx_ctrl_sync(1);
  tx_pop       <= rx_push;
  AIC_lrclk_o  <= i2s_counter(7);
  AIC_sclk_o   <= i2s_counter(1);

  -- ======================================================================
  --  TX FIFO (AXI clock -> AIC mclk): CPU-written samples to the serializer
  -- ======================================================================
  tx_rd_en <= tx_pop and (not tx_empty);

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
  --  RX FIFO (AIC mclk -> AXI clock): captured samples to the CPU
  -- ======================================================================
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
      wr_en         => rx_push_gate,
      din           => rx_din(63 downto 48) & rx_din(31 downto 16),
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

end architecture rtl;
