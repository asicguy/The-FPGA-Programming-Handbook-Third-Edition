-- sobel_stream_ctrl.vhd
-- ------------------------------------
-- AXI4-Lite register file for the streaming Sobel filter
-- ------------------------------------
-- Author : Frank Bruno
--
-- Register map -- byte for byte what Vitis HLS generates for this kernel, so
-- the same notebook drives either implementation:
--
--   0x10 img_width    [31:0]
--   0x18 img_height   [31:0]
--   0x20 mode         [31:0]
--
-- There is no CTRL register, no GIER, no ISR and no interrupt. CH11's kernel
-- was ap_ctrl_hs: PYNQ wrote the arguments, set ap_start and polled ap_done for
-- each frame. This one is ap_ctrl_none -- it free-runs off the video stream the
-- way every other IP in the MIPI pipeline does, and 0x00 through 0x0C read back
-- as zero because HLS does not implement them for a free-running block.
--
-- NOTE the argument names: img_width / img_height, never width / height. PYNQ
-- builds register_map by making a Python property per register field on its
-- Register class, and Register.__init__ assigns self.width -- a field named
-- "width" shadows that attribute and recurses to death on first access.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity sobel_stream_ctrl is
  generic (
    ADDR_WIDTH : integer := 6;
    DATA_WIDTH : integer := 32
  );
  port (
    clk        : in  std_logic;
    rst_n      : in  std_logic;

    -- AXI4-Lite slave
    awaddr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    awvalid    : in  std_logic;
    awready    : out std_logic;
    wdata      : in  std_logic_vector(DATA_WIDTH-1 downto 0);
    wstrb      : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
    wvalid     : in  std_logic;
    wready     : out std_logic;
    bresp      : out std_logic_vector(1 downto 0);
    bvalid     : out std_logic;
    bready     : in  std_logic;
    araddr     : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    arvalid    : in  std_logic;
    arready    : out std_logic;
    rdata      : out std_logic_vector(DATA_WIDTH-1 downto 0);
    rresp      : out std_logic_vector(1 downto 0);
    rvalid     : out std_logic;
    rready     : in  std_logic;

    -- to the datapath
    img_width  : out std_logic_vector(31 downto 0);
    img_height : out std_logic_vector(31 downto 0);
    mode       : out std_logic_vector(31 downto 0)
  );
end entity sobel_stream_ctrl;

architecture rtl of sobel_stream_ctrl is

  constant ADDR_WIDTH_R  : std_logic_vector(ADDR_WIDTH-1 downto 0) := "010000";  -- 0x10
  constant ADDR_HEIGHT_R : std_logic_vector(ADDR_WIDTH-1 downto 0) := "011000";  -- 0x18
  constant ADDR_MODE_R   : std_logic_vector(ADDR_WIDTH-1 downto 0) := "100000";  -- 0x20

  signal awready_i  : std_logic;
  signal wready_i   : std_logic;
  signal bvalid_i   : std_logic;
  signal arready_i  : std_logic;
  signal rvalid_i   : std_logic;

  signal awaddr_r   : std_logic_vector(ADDR_WIDTH-1 downto 0);
  signal awaddr_v   : std_logic;
  signal wdata_r    : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal wstrb_r    : std_logic_vector(DATA_WIDTH/8-1 downto 0);
  signal wdata_v    : std_logic;
  signal do_write   : std_logic;

  signal araddr_r   : std_logic_vector(ADDR_WIDTH-1 downto 0);
  signal do_read    : std_logic;

  signal img_width_r  : std_logic_vector(31 downto 0);
  signal img_height_r : std_logic_vector(31 downto 0);
  signal mode_r       : std_logic_vector(31 downto 0);

  -- Byte strobes, honoured the way the generated slave honours them.
  function wr_mask (old_v : std_logic_vector(DATA_WIDTH-1 downto 0);
                    new_v : std_logic_vector(DATA_WIDTH-1 downto 0);
                    strb  : std_logic_vector(DATA_WIDTH/8-1 downto 0))
    return std_logic_vector is
    variable v : std_logic_vector(DATA_WIDTH-1 downto 0);
  begin
    v := old_v;
    for b in 0 to DATA_WIDTH/8-1 loop
      if strb(b) = '1' then
        v(b*8+7 downto b*8) := new_v(b*8+7 downto b*8);
      end if;
    end loop;
    return v;
  end function;

begin

  awready    <= awready_i;
  wready     <= wready_i;
  bvalid     <= bvalid_i;
  arready    <= arready_i;
  rvalid     <= rvalid_i;
  img_width  <= img_width_r;
  img_height <= img_height_r;
  mode       <= mode_r;

  -- ---------------------------------------------------------------------
  -- Write channel
  -- ---------------------------------------------------------------------
  awready_i <= not awaddr_v;
  wready_i  <= not wdata_v;
  do_write  <= '1' when (awaddr_v = '1' and wdata_v = '1' and
                         (bvalid_i = '0' or bready = '1')) else '0';

  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        awaddr_v <= '0';
        wdata_v  <= '0';
        bvalid_i <= '0';
        bresp    <= "00";
      else
        if awvalid = '1' and awready_i = '1' then
          awaddr_r <= awaddr;
          awaddr_v <= '1';
        end if;
        if wvalid = '1' and wready_i = '1' then
          wdata_r <= wdata;
          wstrb_r <= wstrb;
          wdata_v <= '1';
        end if;
        if do_write = '1' then
          awaddr_v <= '0';
          wdata_v  <= '0';
          bvalid_i <= '1';
          bresp    <= "00";
        elsif bvalid_i = '1' and bready = '1' then
          bvalid_i <= '0';
        end if;
      end if;
    end if;
  end process;

  -- ---------------------------------------------------------------------
  -- Read channel
  -- ---------------------------------------------------------------------
  arready_i <= not rvalid_i;
  do_read   <= arvalid and arready_i;

  process (araddr_r, img_width_r, img_height_r, mode_r)
  begin
    case araddr_r is
      when ADDR_WIDTH_R  => rdata <= img_width_r;
      when ADDR_HEIGHT_R => rdata <= img_height_r;
      when ADDR_MODE_R   => rdata <= mode_r;
      when others        => rdata <= (others => '0');
    end case;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        rvalid_i <= '0';
        rresp    <= "00";
        araddr_r <= (others => '0');
      else
        if do_read = '1' then
          araddr_r <= araddr;
          rvalid_i <= '1';
          rresp    <= "00";
        elsif rvalid_i = '1' and rready = '1' then
          rvalid_i <= '0';
        end if;
      end if;
    end if;
  end process;

  -- ---------------------------------------------------------------------
  -- Registers
  -- ---------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        img_width_r  <= (others => '0');
        img_height_r <= (others => '0');
        mode_r       <= (others => '0');
      elsif do_write = '1' then
        case awaddr_r is
          when ADDR_WIDTH_R  => img_width_r  <= wr_mask(img_width_r,  wdata_r, wstrb_r);
          when ADDR_HEIGHT_R => img_height_r <= wr_mask(img_height_r, wdata_r, wstrb_r);
          when ADDR_MODE_R   => mode_r       <= wr_mask(mode_r,       wdata_r, wstrb_r);
          when others        => null;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;
