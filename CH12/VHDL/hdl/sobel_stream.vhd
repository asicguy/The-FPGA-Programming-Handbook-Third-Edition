-- sobel_stream.vhd
-- ------------------------------------
-- Streaming Sobel video filter -- top level
-- ------------------------------------
-- Author : Frank Bruno
--
-- Sits inside the MIPI pipeline between axis_channel_swap and pixel_pack:
--
--   csi2_rx -> subset -> demosaic -> gamma_lut -> v_proc_ss (CSC)
--           -> axis_channel_swap -> [ sobel_stream ] -> pixel_pack -> VDMA
--
-- The port names, their widths and the register offsets are all copied from
-- what Vitis HLS generates for the C version, so any of the three can be
-- dropped into that slot and driven by the same notebook. The single
-- testbench in ../../SystemVerilog/tb binds against all three.
--
-- The port names are spelled in the mixed case Vitis HLS emits. VHDL does not
-- care, but the SystemVerilog testbench does, and xsim matches the two by name
-- when it binds a VHDL entity into a Verilog instantiation.
--
-- 48 bits of TDATA carry two pixels: pixel 0 in [23:0] and pixel 1 in [47:24],
-- each B,G,R from the LSB up. TUSER bit 0 is start-of-frame, TLAST is
-- end-of-line. TKEEP and TSTRB are all-ones in and ignored; a video stream has
-- no partial beats.
--
-- Free-running: there is no ap_start to write and no ap_done to poll, and the
-- AXI4-Lite slave has no CTRL register. The block is driven by the stream.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity sobel_stream is
  generic (
    MAX_WIDTH : integer := 1920
  );
  port (
    ap_clk                : in  std_logic;
    ap_rst_n              : in  std_logic;

    -- AXI4-Stream slave: pixels from the colour-space converter
    stream_in_TDATA       : in  std_logic_vector(47 downto 0);
    stream_in_TVALID      : in  std_logic;
    stream_in_TREADY      : out std_logic;
    stream_in_TKEEP       : in  std_logic_vector(5 downto 0);
    stream_in_TSTRB       : in  std_logic_vector(5 downto 0);
    stream_in_TUSER       : in  std_logic_vector(0 downto 0);
    stream_in_TLAST       : in  std_logic_vector(0 downto 0);

    -- AXI4-Stream master: pixels to the packer
    stream_out_TDATA      : out std_logic_vector(47 downto 0);
    stream_out_TVALID     : out std_logic;
    stream_out_TREADY     : in  std_logic;
    stream_out_TKEEP      : out std_logic_vector(5 downto 0);
    stream_out_TSTRB      : out std_logic_vector(5 downto 0);
    stream_out_TUSER      : out std_logic_vector(0 downto 0);
    stream_out_TLAST      : out std_logic_vector(0 downto 0);

    -- AXI4-Lite control
    s_axi_control_AWVALID : in  std_logic;
    s_axi_control_AWREADY : out std_logic;
    s_axi_control_AWADDR  : in  std_logic_vector(5 downto 0);
    s_axi_control_WVALID  : in  std_logic;
    s_axi_control_WREADY  : out std_logic;
    s_axi_control_WDATA   : in  std_logic_vector(31 downto 0);
    s_axi_control_WSTRB   : in  std_logic_vector(3 downto 0);
    s_axi_control_ARVALID : in  std_logic;
    s_axi_control_ARREADY : out std_logic;
    s_axi_control_ARADDR  : in  std_logic_vector(5 downto 0);
    s_axi_control_RVALID  : out std_logic;
    s_axi_control_RREADY   : in  std_logic;
    s_axi_control_RDATA   : out std_logic_vector(31 downto 0);
    s_axi_control_RRESP   : out std_logic_vector(1 downto 0);
    s_axi_control_BVALID  : out std_logic;
    s_axi_control_BREADY  : in  std_logic;
    s_axi_control_BRESP   : out std_logic_vector(1 downto 0)
  );
end entity sobel_stream;

architecture rtl of sobel_stream is

  signal img_width  : std_logic_vector(31 downto 0);
  signal img_height : std_logic_vector(31 downto 0);
  signal mode       : std_logic_vector(31 downto 0);

  signal core_wr   : std_logic;
  signal core_data : std_logic_vector(47 downto 0);
  signal core_user : std_logic;
  signal core_last : std_logic;
  signal skid_full : std_logic;
  signal skid_din  : std_logic_vector(49 downto 0);
  signal skid_dout : std_logic_vector(49 downto 0);

  -- stream_in_TKEEP and stream_in_TSTRB are deliberately unconnected below.
  -- They carry no information on a video stream -- every beat is two whole
  -- pixels -- but the ports exist because the upstream IP drives them and
  -- because the HLS-generated interface has them. They are regenerated as
  -- all-ones on the way out.

begin

  u_ctrl : entity work.sobel_stream_ctrl
    generic map (
      ADDR_WIDTH => 6,
      DATA_WIDTH => 32
    )
    port map (
      clk        => ap_clk,
      rst_n      => ap_rst_n,
      awaddr     => s_axi_control_AWADDR,
      awvalid    => s_axi_control_AWVALID,
      awready    => s_axi_control_AWREADY,
      wdata      => s_axi_control_WDATA,
      wstrb      => s_axi_control_WSTRB,
      wvalid     => s_axi_control_WVALID,
      wready     => s_axi_control_WREADY,
      bresp      => s_axi_control_BRESP,
      bvalid     => s_axi_control_BVALID,
      bready     => s_axi_control_BREADY,
      araddr     => s_axi_control_ARADDR,
      arvalid    => s_axi_control_ARVALID,
      arready    => s_axi_control_ARREADY,
      rdata      => s_axi_control_RDATA,
      rresp      => s_axi_control_RRESP,
      rvalid     => s_axi_control_RVALID,
      rready     => s_axi_control_RREADY,
      img_width  => img_width,
      img_height => img_height,
      mode       => mode
    );

  u_core : entity work.sobel_stream_core
    generic map (
      MAX_WIDTH => MAX_WIDTH
    )
    port map (
      clk        => ap_clk,
      rst_n      => ap_rst_n,
      img_width  => img_width,
      img_height => img_height,
      mode       => mode,
      s_valid    => stream_in_TVALID,
      s_data     => stream_in_TDATA,
      s_user     => stream_in_TUSER(0),
      s_last     => stream_in_TLAST(0),
      s_ready    => stream_in_TREADY,
      m_wr       => core_wr,
      m_data     => core_data,
      m_user     => core_user,
      m_last     => core_last,
      m_full     => skid_full
    );

  skid_din <= core_user & core_last & core_data;

  u_skid : entity work.axis_skid
    generic map (
      WIDTH => 50
    )
    port map (
      clk     => ap_clk,
      rst_n   => ap_rst_n,
      wr      => core_wr,
      din     => skid_din,
      full    => skid_full,
      m_valid => stream_out_TVALID,
      m_data  => skid_dout,
      m_ready => stream_out_TREADY
    );

  stream_out_TDATA    <= skid_dout(47 downto 0);
  stream_out_TLAST(0) <= skid_dout(48);
  stream_out_TUSER(0) <= skid_dout(49);
  stream_out_TKEEP    <= (others => '1');
  stream_out_TSTRB    <= (others => '1');

end architecture rtl;
