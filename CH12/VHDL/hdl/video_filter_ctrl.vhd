-- video_filter_ctrl.vhd
-- ------------------------------------
-- AXI4-Lite control/status register file for the video filter
-- ------------------------------------
-- Author : Frank Bruno
--
-- Register map -- byte-for-byte identical to what Vitis HLS generates for this
-- kernel, so the same PYNQ notebook drives either implementation:
--
--   0x00 CTRL    bit0 ap_start, bit1 ap_done (clear-on-read),
--                bit2 ap_idle, bit3 ap_ready (clear-on-read),
--                bit7 auto_restart, bit9 interrupt
--   0x04 GIER    bit0 global interrupt enable
--   0x08 IP_IER  bit0 ap_done enable, bit1 ap_ready enable
--   0x0C IP_ISR  bit0/bit1 status, toggle-on-write
--   0x10 / 0x14  src  low / high
--   0x1C / 0x20  dst  low / high
--   0x28 img_width
--   0x30 img_height
--   0x38 mode      0 gray, 1 sobel, 2 invert, 3 colour passthrough
--
-- This entity is CH11's control block unchanged apart from its name. That is
-- the point of keeping the register map: PYNQ's register_map, the notebook,
-- sw/filter_driver.py and the testbench all carry over to CH12 untouched.
--
-- NOTE the argument names: img_width / img_height, never width / height. PYNQ
-- builds register_map by making a Python property per register field on its
-- Register class, and Register.__init__ assigns self.width -- a field named
-- "width" shadows that attribute and recurses to death on first access.

LIBRARY IEEE;
USE IEEE.std_logic_1164.all;
USE IEEE.numeric_std.all;

entity video_filter_ctrl is
  generic (
    ADDR_WIDTH : integer := 6;
    DATA_WIDTH : integer := 32
  );
  port (
    clk        : in  std_logic;
    rst_n      : in  std_logic;

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

    interrupt  : out std_logic;

    ap_start   : out std_logic;
    ap_done    : in  std_logic;
    src_addr   : out std_logic_vector(63 downto 0);
    dst_addr   : out std_logic_vector(63 downto 0);
    img_width  : out std_logic_vector(31 downto 0);
    img_height : out std_logic_vector(31 downto 0);
    mode       : out std_logic_vector(31 downto 0)
  );
end entity video_filter_ctrl;

architecture rtl of video_filter_ctrl is

  constant ADDR_CTRL   : std_logic_vector(5 downto 0) := "000000";  -- 0x00
  constant ADDR_GIER   : std_logic_vector(5 downto 0) := "000100";  -- 0x04
  constant ADDR_IER    : std_logic_vector(5 downto 0) := "001000";  -- 0x08
  constant ADDR_ISR    : std_logic_vector(5 downto 0) := "001100";  -- 0x0C
  constant ADDR_SRC_LO : std_logic_vector(5 downto 0) := "010000";  -- 0x10
  constant ADDR_SRC_HI : std_logic_vector(5 downto 0) := "010100";  -- 0x14
  constant ADDR_DST_LO : std_logic_vector(5 downto 0) := "011100";  -- 0x1C
  constant ADDR_DST_HI : std_logic_vector(5 downto 0) := "100000";  -- 0x20
  constant ADDR_IMG_W : std_logic_vector(5 downto 0) := "101000";  -- 0x28
  constant ADDR_HEIGHT : std_logic_vector(5 downto 0) := "110000";  -- 0x30
  constant ADDR_MODE   : std_logic_vector(5 downto 0) := "111000";  -- 0x38

  signal ap_start_i    : std_logic := '0';
  signal ap_idle       : std_logic := '1';
  signal ap_done_r     : std_logic := '0';
  signal ap_ready_r    : std_logic := '0';
  signal auto_restart  : std_logic := '0';
  signal gie           : std_logic := '0';
  signal ier           : std_logic_vector(1 downto 0) := (others => '0');
  signal isr           : std_logic_vector(1 downto 0) := (others => '0');

  signal src_addr_i    : std_logic_vector(63 downto 0) := (others => '0');
  signal dst_addr_i    : std_logic_vector(63 downto 0) := (others => '0');
  signal img_width_i   : std_logic_vector(31 downto 0) := (others => '0');
  signal img_height_i  : std_logic_vector(31 downto 0) := (others => '0');
  signal mode_i        : std_logic_vector(31 downto 0) := (others => '0');

  signal awaddr_r      : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
  signal awaddr_v      : std_logic := '0';
  signal wdata_r       : std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
  signal wstrb_r       : std_logic_vector(DATA_WIDTH/8-1 downto 0) := (others => '0');
  signal wdata_v       : std_logic := '0';
  signal bvalid_i      : std_logic := '0';
  signal rvalid_i      : std_logic := '0';
  signal araddr_r      : std_logic_vector(ADDR_WIDTH-1 downto 0) := (others => '0');
  signal do_write      : std_logic;
  signal do_read       : std_logic;
  signal ctrl_read_ack : std_logic;
  signal rdata_i       : std_logic_vector(DATA_WIDTH-1 downto 0);
  signal interrupt_i   : std_logic;

  -- Note the 0-based normalisation. Called with src_addr_i(63 downto 32) the
  -- argument's own 'range is 63 downto 32, and indexing that by byte lane
  -- (b*8+7 downto b*8) runs straight off the bottom of the vector.
  function wr_mask (old_v : std_logic_vector;
                    new_v : std_logic_vector;
                    strb  : std_logic_vector) return std_logic_vector is
    variable ov  : std_logic_vector(old_v'length-1 downto 0) := old_v;
    variable nv  : std_logic_vector(new_v'length-1 downto 0) := new_v;
    variable sv  : std_logic_vector(strb'length-1 downto 0)  := strb;
    variable res : std_logic_vector(old_v'length-1 downto 0);
  begin
    res := ov;
    for b in 0 to sv'length-1 loop
      if sv(b) = '1' then
        res(b*8+7 downto b*8) := nv(b*8+7 downto b*8);
      end if;
    end loop;
    return res;
  end function;

begin

  ap_start   <= ap_start_i;
  src_addr   <= src_addr_i;
  dst_addr   <= dst_addr_i;
  img_width  <= img_width_i;
  img_height <= img_height_i;
  mode       <= mode_i;

  awready  <= not awaddr_v;
  wready   <= not wdata_v;
  bvalid   <= bvalid_i;
  rvalid   <= rvalid_i;
  bresp    <= "00";
  rresp    <= "00";
  rdata    <= rdata_i;

  do_write <= '1' when (awaddr_v = '1' and wdata_v = '1' and
                        (bvalid_i = '0' or bready = '1')) else '0';
  arready  <= not rvalid_i;
  do_read  <= arvalid and (not rvalid_i);

  ctrl_read_ack <= '1' when (rvalid_i = '1' and rready = '1' and
                             araddr_r = ADDR_CTRL) else '0';

  interrupt_i <= gie and (isr(0) or isr(1));
  interrupt   <= interrupt_i;

  -- read data mux
  process (araddr_r, ap_start_i, ap_done_r, ap_idle, ap_ready_r, auto_restart,
           interrupt_i, gie, ier, isr, src_addr_i, dst_addr_i,
           img_width_i, img_height_i, mode_i)
  begin
    case araddr_r is
      when ADDR_CTRL =>
        rdata_i <= (31 downto 10 => '0') & interrupt_i & '0' & auto_restart &
                   "000" & ap_ready_r & ap_idle & ap_done_r & ap_start_i;
      when ADDR_GIER   => rdata_i <= (31 downto 1 => '0') & gie;
      when ADDR_IER    => rdata_i <= (31 downto 2 => '0') & ier;
      when ADDR_ISR    => rdata_i <= (31 downto 2 => '0') & isr;
      when ADDR_SRC_LO => rdata_i <= src_addr_i(31 downto 0);
      when ADDR_SRC_HI => rdata_i <= src_addr_i(63 downto 32);
      when ADDR_DST_LO => rdata_i <= dst_addr_i(31 downto 0);
      when ADDR_DST_HI => rdata_i <= dst_addr_i(63 downto 32);
      when ADDR_IMG_W => rdata_i <= img_width_i;
      when ADDR_HEIGHT => rdata_i <= img_height_i;
      when ADDR_MODE   => rdata_i <= mode_i;
      when others      => rdata_i <= (others => '0');
    end case;
  end process;

  -- write / read channel handshaking
  process (clk) begin
    if rising_edge(clk) then
      if rst_n = '0' then
        awaddr_v <= '0';
        wdata_v  <= '0';
        bvalid_i <= '0';
        rvalid_i <= '0';
        araddr_r <= (others => '0');
      else
        if awvalid = '1' and awaddr_v = '0' then
          awaddr_r <= awaddr;
          awaddr_v <= '1';
        end if;
        if wvalid = '1' and wdata_v = '0' then
          wdata_r <= wdata;
          wstrb_r <= wstrb;
          wdata_v <= '1';
        end if;
        if do_write = '1' then
          awaddr_v <= '0';
          wdata_v  <= '0';
          bvalid_i <= '1';
        elsif bvalid_i = '1' and bready = '1' then
          bvalid_i <= '0';
        end if;

        if do_read = '1' then
          araddr_r <= araddr;
          rvalid_i <= '1';
        elsif rvalid_i = '1' and rready = '1' then
          rvalid_i <= '0';
        end if;
      end if;
    end if;
  end process;

  -- registers
  process (clk) begin
    if rising_edge(clk) then
      if rst_n = '0' then
        ap_start_i   <= '0';
        ap_idle      <= '1';
        ap_done_r    <= '0';
        ap_ready_r   <= '0';
        auto_restart <= '0';
        gie          <= '0';
        ier          <= (others => '0');
        isr          <= (others => '0');
        src_addr_i   <= (others => '0');
        dst_addr_i   <= (others => '0');
        img_width_i  <= (others => '0');
        img_height_i <= (others => '0');
        mode_i       <= (others => '0');
      else
        -- Completion. The set MUST take priority over the clear-on-read: a
        -- polling master reads CTRL continuously, so a read handshake will
        -- eventually land in the same cycle as the done pulse. If the clear
        -- won there the completion would be lost and the master would poll
        -- forever. With the set winning, that read returns 0 and the next
        -- one returns 1.
        if ap_done = '1' then
          ap_done_r  <= '1';
          ap_ready_r <= '1';
          ap_idle    <= '1';
          ap_start_i <= auto_restart;
          if ier(0) = '1' then isr(0) <= '1'; end if;
          if ier(1) = '1' then isr(1) <= '1'; end if;
        elsif ctrl_read_ack = '1' then
          ap_done_r  <= '0';
          ap_ready_r <= '0';
        end if;

        if ap_start_i = '1' and ap_idle = '1' and ap_done = '0' then
          ap_idle <= '0';
        end if;

        if do_write = '1' then
          case awaddr_r is
            when ADDR_CTRL =>
              if wstrb_r(0) = '1' then
                if wdata_r(0) = '1' and ap_idle = '1' then
                  ap_start_i <= '1';
                end if;
                auto_restart <= wdata_r(7);
              end if;
            when ADDR_GIER =>
              if wstrb_r(0) = '1' then gie <= wdata_r(0); end if;
            when ADDR_IER =>
              if wstrb_r(0) = '1' then ier <= wdata_r(1 downto 0); end if;
            when ADDR_ISR =>     -- toggle on write
              if wstrb_r(0) = '1' then isr <= isr xor wdata_r(1 downto 0); end if;
            when ADDR_SRC_LO =>
              src_addr_i(31 downto 0)  <= wr_mask(src_addr_i(31 downto 0),  wdata_r, wstrb_r);
            when ADDR_SRC_HI =>
              src_addr_i(63 downto 32) <= wr_mask(src_addr_i(63 downto 32), wdata_r, wstrb_r);
            when ADDR_DST_LO =>
              dst_addr_i(31 downto 0)  <= wr_mask(dst_addr_i(31 downto 0),  wdata_r, wstrb_r);
            when ADDR_DST_HI =>
              dst_addr_i(63 downto 32) <= wr_mask(dst_addr_i(63 downto 32), wdata_r, wstrb_r);
            when ADDR_IMG_W =>
              img_width_i  <= wr_mask(img_width_i,  wdata_r, wstrb_r);
            when ADDR_HEIGHT =>
              img_height_i <= wr_mask(img_height_i, wdata_r, wstrb_r);
            when ADDR_MODE =>
              mode_i       <= wr_mask(mode_i,       wdata_r, wstrb_r);
            when others => null;
          end case;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
