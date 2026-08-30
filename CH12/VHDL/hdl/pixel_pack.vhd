-- pixel_pack.vhd
-- ------------------------------------
-- 24-bit pixel pairs to 32-bit pixel pairs, for the camera hierarchy
-- ------------------------------------
-- Author : Frank Bruno
--
-- The VHDL twin of SystemVerilog/hdl/pixel_pack.sv, and a replacement for
-- PYNQ's prebuilt xilinx.com:hls:pixel_pack_2:1.0 in project 3's `vhdl` build.
-- Projects 0 and 1 keep PYNQ's, and so does project 3's `hls` build: the point
-- is that a build called "VHDL" should not have an HLS block in its datapath.
--
-- Behaviour is transcribed from the 32bpp branch of the HLS source
-- (AUP-ZU3/pynq/boards/ip/hls/pixel_pack_2/pixel_pack.cpp, case V_32):
--
--     data(23, 0)  = in.data(23, 0);     data(31, 24) = alpha;
--     data(55, 32) = in.data(47, 24);    data(63, 56) = alpha;
--     out.last = in.last;  out.user = in.user;
--
-- One beat in, one beat out. TUSER is start-of-frame and TLAST end-of-line;
-- the VDMA tears the picture if either moves, so both travel with the beat
-- they arrived on.
--
-- 32 bits per pixel only -- see the SystemVerilog header for why, and for why
-- the mode register exists anyway. Reset value is 1 (32bpp) and alpha resets
-- to zero, which is what the camera has always produced.
--
-- ap_ctrl_none, like the HLS original: nothing to arm. The control aperture is
-- five address bits, which is what the HLS IP declared; widening it would move
-- the hierarchy's address map out from under PYNQ.
--
-- Entity and port names are lower case and identical to the SystemVerilog, so
-- SystemVerilog/tb/tb_pixel_pack.sv binds to this entity directly -- xsim
-- matches VHDL port names case-insensitively. One testbench, two DUTs.

LIBRARY IEEE;
USE IEEE.std_logic_1164.all;
USE IEEE.numeric_std.all;

entity pixel_pack is
  generic (
    ADDR_WIDTH : integer := 5;
    DATA_WIDTH : integer := 32
  );
  port (
    ap_clk                : in  std_logic;
    ap_rst_n              : in  std_logic;

    -- AXI4-Lite control
    s_axi_control_awaddr  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    s_axi_control_awvalid : in  std_logic;
    s_axi_control_awready : out std_logic;
    s_axi_control_wdata   : in  std_logic_vector(DATA_WIDTH-1 downto 0);
    s_axi_control_wstrb   : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
    s_axi_control_wvalid  : in  std_logic;
    s_axi_control_wready  : out std_logic;
    s_axi_control_bresp   : out std_logic_vector(1 downto 0);
    s_axi_control_bvalid  : out std_logic;
    s_axi_control_bready  : in  std_logic;
    s_axi_control_araddr  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    s_axi_control_arvalid : in  std_logic;
    s_axi_control_arready : out std_logic;
    s_axi_control_rdata   : out std_logic_vector(DATA_WIDTH-1 downto 0);
    s_axi_control_rresp   : out std_logic_vector(1 downto 0);
    s_axi_control_rvalid  : out std_logic;
    s_axi_control_rready  : in  std_logic;

    -- AXI4-Stream in: two 24-bit pixels per beat
    stream_in_48_tdata    : in  std_logic_vector(47 downto 0);
    stream_in_48_tvalid   : in  std_logic;
    stream_in_48_tready   : out std_logic;
    stream_in_48_tkeep    : in  std_logic_vector(5 downto 0);
    stream_in_48_tstrb    : in  std_logic_vector(5 downto 0);
    stream_in_48_tuser    : in  std_logic_vector(0 downto 0);
    stream_in_48_tlast    : in  std_logic_vector(0 downto 0);

    -- AXI4-Stream out: two 32-bit pixels per beat
    stream_out_64_tdata   : out std_logic_vector(63 downto 0);
    stream_out_64_tvalid  : out std_logic;
    stream_out_64_tready  : in  std_logic;
    stream_out_64_tkeep   : out std_logic_vector(7 downto 0);
    stream_out_64_tstrb   : out std_logic_vector(7 downto 0);
    stream_out_64_tuser   : out std_logic_vector(0 downto 0);
    stream_out_64_tlast   : out std_logic_vector(0 downto 0)
  );
end entity pixel_pack;

architecture rtl of pixel_pack is

  constant ADDR_MODE  : std_logic_vector(ADDR_WIDTH-1 downto 0) := "10000";  -- 0x10
  constant ADDR_ALPHA : std_logic_vector(ADDR_WIDTH-1 downto 0) := "11000";  -- 0x18

  constant MODE_32BPP : std_logic_vector(31 downto 0) := x"00000001";

  signal mode_r  : std_logic_vector(31 downto 0);
  signal alpha_r : std_logic_vector(7 downto 0);

  -- write channel
  signal awaddr_r  : std_logic_vector(ADDR_WIDTH-1 downto 0);
  signal awaddr_v  : std_logic;
  signal wdata_r   : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal wstrb_r   : std_logic_vector(DATA_WIDTH/8-1 downto 0);
  signal wdata_v   : std_logic;
  signal bvalid_i  : std_logic;
  signal awready_i : std_logic;
  signal wready_i  : std_logic;
  signal aw_hs     : std_logic;
  signal w_hs      : std_logic;
  signal do_write  : std_logic;

  -- read channel
  signal araddr_r  : std_logic_vector(ADDR_WIDTH-1 downto 0);
  signal rvalid_i  : std_logic;
  signal arready_i : std_logic;
  signal do_read   : std_logic;

  -- datapath
  signal packed_data   : std_logic_vector(63 downto 0);
  signal out_data_r    : std_logic_vector(63 downto 0);
  signal skid_data_r   : std_logic_vector(63 downto 0);
  signal out_user_r    : std_logic;
  signal out_last_r    : std_logic;
  signal skid_user_r   : std_logic;
  signal skid_last_r   : std_logic;
  signal out_valid_r   : std_logic;
  signal skid_valid_r  : std_logic;

  function wr_mask (old_v : std_logic_vector;
                    new_v : std_logic_vector;
                    strb  : std_logic_vector) return std_logic_vector is
    variable r : std_logic_vector(old_v'range) := old_v;
  begin
    for b in strb'range loop
      if strb(b) = '1' then
        r(b*8 + 7 downto b*8) := new_v(b*8 + 7 downto b*8);
      end if;
    end loop;
    return r;
  end function;

begin

  -- ---------------------------------------------------------------------
  -- AXI4-Lite write channel
  -- ---------------------------------------------------------------------
  awready_i <= not awaddr_v;
  wready_i  <= not wdata_v;
  aw_hs     <= s_axi_control_awvalid and awready_i;
  w_hs      <= s_axi_control_wvalid  and wready_i;

  s_axi_control_awready <= awready_i;
  s_axi_control_wready  <= wready_i;
  s_axi_control_bvalid  <= bvalid_i;

  do_write <= '1' when (awaddr_v = '1' and wdata_v = '1' and
                        (bvalid_i = '0' or s_axi_control_bready = '1'))
              else '0';

  write_channel : process (ap_clk)
  begin
    if rising_edge(ap_clk) then
      if ap_rst_n = '0' then
        awaddr_v            <= '0';
        wdata_v             <= '0';
        bvalid_i            <= '0';
        s_axi_control_bresp <= "00";
      else
        if aw_hs = '1' then
          awaddr_r <= s_axi_control_awaddr;
          awaddr_v <= '1';
        end if;
        if w_hs = '1' then
          wdata_r <= s_axi_control_wdata;
          wstrb_r <= s_axi_control_wstrb;
          wdata_v <= '1';
        end if;
        if do_write = '1' then
          awaddr_v            <= '0';
          wdata_v             <= '0';
          bvalid_i            <= '1';
          s_axi_control_bresp <= "00";
        elsif bvalid_i = '1' and s_axi_control_bready = '1' then
          bvalid_i <= '0';
        end if;
      end if;
    end if;
  end process write_channel;

  -- ---------------------------------------------------------------------
  -- AXI4-Lite read channel
  -- ---------------------------------------------------------------------
  arready_i <= not rvalid_i;
  do_read   <= s_axi_control_arvalid and arready_i;

  s_axi_control_arready <= arready_i;
  s_axi_control_rvalid  <= rvalid_i;

  s_axi_control_rdata <= mode_r                    when araddr_r = ADDR_MODE  else
                         x"000000" & alpha_r       when araddr_r = ADDR_ALPHA else
                         (others => '0');

  read_channel : process (ap_clk)
  begin
    if rising_edge(ap_clk) then
      if ap_rst_n = '0' then
        rvalid_i            <= '0';
        s_axi_control_rresp <= "00";
        araddr_r            <= (others => '0');
      else
        if do_read = '1' then
          araddr_r            <= s_axi_control_araddr;
          rvalid_i            <= '1';
          s_axi_control_rresp <= "00";
        elsif rvalid_i = '1' and s_axi_control_rready = '1' then
          rvalid_i <= '0';
        end if;
      end if;
    end if;
  end process read_channel;

  -- ---------------------------------------------------------------------
  -- Registers
  -- ---------------------------------------------------------------------
  registers : process (ap_clk)
  begin
    if rising_edge(ap_clk) then
      if ap_rst_n = '0' then
        -- 32bpp and a transparent alpha: what the camera has always produced,
        -- because PYNQ's driver writes the mode on every configure() and never
        -- writes alpha at all.
        mode_r  <= MODE_32BPP;
        alpha_r <= (others => '0');
      elsif do_write = '1' then
        if awaddr_r = ADDR_MODE then
          mode_r <= wr_mask(mode_r, wdata_r, wstrb_r);
        elsif awaddr_r = ADDR_ALPHA then
          if wstrb_r(0) = '1' then
            alpha_r <= wdata_r(7 downto 0);
          end if;
        end if;
      end if;
    end if;
  end process registers;

  -- ---------------------------------------------------------------------
  -- The packing itself, and a skid buffer
  -- ---------------------------------------------------------------------
  -- A skid buffer rather than a plain register, so TREADY is a register output
  -- and does not run combinationally from the VDMA back to the CSI-2 receiver.
  packed_data <= alpha_r & stream_in_48_tdata(47 downto 24) &
                 alpha_r & stream_in_48_tdata(23 downto 0);

  stream_in_48_tready <= not skid_valid_r;

  stream_out_64_tvalid   <= out_valid_r;
  stream_out_64_tdata    <= out_data_r;
  stream_out_64_tuser(0) <= out_user_r;
  stream_out_64_tlast(0) <= out_last_r;
  -- Every byte of a packed beat is a real byte. The HLS IP says the same.
  stream_out_64_tkeep    <= (others => '1');
  stream_out_64_tstrb    <= (others => '1');

  skid : process (ap_clk)
  begin
    if rising_edge(ap_clk) then
      if ap_rst_n = '0' then
        out_valid_r  <= '0';
        skid_valid_r <= '0';
      elsif skid_valid_r = '0' then
        if out_valid_r = '0' or stream_out_64_tready = '1' then
          out_valid_r <= stream_in_48_tvalid;
          if stream_in_48_tvalid = '1' then
            out_data_r <= packed_data;
            out_user_r <= stream_in_48_tuser(0);
            out_last_r <= stream_in_48_tlast(0);
          end if;
        elsif stream_in_48_tvalid = '1' then
          -- The output is stalled and a beat arrived anyway -- TREADY was
          -- high, so it is ours now and has to be parked, not dropped.
          skid_valid_r <= '1';
          skid_data_r  <= packed_data;
          skid_user_r  <= stream_in_48_tuser(0);
          skid_last_r  <= stream_in_48_tlast(0);
        end if;
      elsif stream_out_64_tready = '1' then
        out_data_r   <= skid_data_r;
        out_user_r   <= skid_user_r;
        out_last_r   <= skid_last_r;
        out_valid_r  <= '1';
        skid_valid_r <= '0';
      end if;
    end if;
  end process skid;

  -- TKEEP and TSTRB in are ignored on purpose: the upstream converter drives
  -- them all ones on every beat, and a packer that acted on a null byte would
  -- have to decide what half a pixel means.

end architecture rtl;
