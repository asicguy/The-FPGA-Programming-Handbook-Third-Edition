-- axi_ram.vhd
-- ----------------------------------------------------------------------------
--  Simple AXI4 (full) slave memory model for simulation.
--
--  A clean, deterministic stand-in for a DDR controller: it accepts INCR write
--  and read bursts (one outstanding burst per direction at a time) and stores
--  data in a flat array. Enough to exercise the aic3104_dma master.
--
--  The backing store is capped at 2**MEM_AW words and indexed by the low word
--  address bits, so a wide (40-bit) address bus does not blow up the array.
--
--  A small synchronous backdoor port (bd_we/bd_addr/bd_wdata) lets a testbench
--  preload a known pattern without going through the AXI write channel.
-- ----------------------------------------------------------------------------
-- Author : Frank Bruno

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_ram is
  generic (
    DATA_WIDTH : integer := 32;
    ADDR_WIDTH : integer := 40;
    ID_WIDTH   : integer := 6;
    MEM_AW     : integer := 16          -- backing store = 2**MEM_AW words
  );
  port (
    clk : in std_logic;
    rst : in std_logic;                 -- active-high

    -- write address channel
    s_axi_awid    : in  std_logic_vector(ID_WIDTH - 1 downto 0);
    s_axi_awaddr  : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
    s_axi_awlen   : in  std_logic_vector(7 downto 0);
    s_axi_awsize  : in  std_logic_vector(2 downto 0);
    s_axi_awburst : in  std_logic_vector(1 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    -- write data channel
    s_axi_wdata   : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
    s_axi_wstrb   : in  std_logic_vector(DATA_WIDTH / 8 - 1 downto 0);
    s_axi_wlast   : in  std_logic;
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    -- write response channel
    s_axi_bid     : out std_logic_vector(ID_WIDTH - 1 downto 0);
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    -- read address channel
    s_axi_arid    : in  std_logic_vector(ID_WIDTH - 1 downto 0);
    s_axi_araddr  : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
    s_axi_arlen   : in  std_logic_vector(7 downto 0);
    s_axi_arsize  : in  std_logic_vector(2 downto 0);
    s_axi_arburst : in  std_logic_vector(1 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    -- read data channel
    s_axi_rid     : out std_logic_vector(ID_WIDTH - 1 downto 0);
    s_axi_rdata   : out std_logic_vector(DATA_WIDTH - 1 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rlast   : out std_logic;
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    -- synchronous backdoor write port (preload)
    bd_we    : in std_logic                                  := '0';
    bd_addr  : in std_logic_vector(MEM_AW - 1 downto 0)      := (others => '0');
    bd_wdata : in std_logic_vector(DATA_WIDTH - 1 downto 0)  := (others => '0')
  );
end entity axi_ram;

architecture rtl of axi_ram is

  constant STRB_WIDTH : integer := DATA_WIDTH / 8;
  constant ADDR_LSB   : integer := 2;   -- log2(4 bytes/word); design is 32-bit

  type mem_t is array (0 to 2 ** MEM_AW - 1) of std_logic_vector(DATA_WIDTH - 1 downto 0);
  signal mem : mem_t;

  -- low MEM_AW word-address bits of a byte address
  function widx(a : unsigned) return integer is
  begin
    return to_integer(a(MEM_AW + ADDR_LSB - 1 downto ADDR_LSB));
  end function;

  -- write side
  type wstate_t is (W_IDLE, W_DATA, W_RESP);
  signal wstate    : wstate_t := W_IDLE;
  signal w_addr    : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');
  signal w_size    : unsigned(2 downto 0)              := (others => '0');
  signal w_len     : unsigned(7 downto 0)              := (others => '0');
  signal awready_i : std_logic                         := '0';
  signal wready_i  : std_logic                         := '0';
  signal bvalid_i  : std_logic                         := '0';
  signal bid_i     : std_logic_vector(ID_WIDTH - 1 downto 0) := (others => '0');

  -- read side
  type rstate_t is (R_IDLE, R_BURST);
  signal rstate    : rstate_t := R_IDLE;
  signal r_addr    : unsigned(ADDR_WIDTH - 1 downto 0) := (others => '0');
  signal r_size    : unsigned(2 downto 0)              := (others => '0');
  signal r_cnt     : unsigned(7 downto 0)              := (others => '0');
  signal arready_i : std_logic                         := '0';
  signal rvalid_i  : std_logic                         := '0';
  signal rid_i     : std_logic_vector(ID_WIDTH - 1 downto 0) := (others => '0');

begin

  s_axi_awready <= awready_i;
  s_axi_wready  <= wready_i;
  s_axi_bvalid  <= bvalid_i;
  s_axi_bid     <= bid_i;
  s_axi_bresp   <= "00";

  s_axi_arready <= arready_i;
  s_axi_rvalid  <= rvalid_i;
  s_axi_rid     <= rid_i;
  s_axi_rresp   <= "00";
  s_axi_rdata   <= mem(widx(r_addr));
  s_axi_rlast   <= '1' when (rstate = R_BURST and r_cnt = 0) else '0';

  -- ----------------------------------------------------------------------
  --  Write channel (AW / W / B) + backdoor preload
  -- ----------------------------------------------------------------------
  write_proc : process (clk)
    variable incr : unsigned(ADDR_WIDTH - 1 downto 0);
  begin
    if rising_edge(clk) then
      -- Synchronous backdoor preload (independent of the AXI write FSM)
      if bd_we = '1' then
        mem(to_integer(unsigned(bd_addr))) <= bd_wdata;
      end if;

      if rst = '1' then
        wstate    <= W_IDLE;
        awready_i <= '0';
        wready_i  <= '0';
        bvalid_i  <= '0';
      else
        case wstate is
          when W_IDLE =>
            bvalid_i  <= '0';
            awready_i <= '1';
            if s_axi_awvalid = '1' and awready_i = '1' then
              awready_i <= '0';
              w_addr    <= unsigned(s_axi_awaddr);
              w_size    <= unsigned(s_axi_awsize);
              w_len     <= unsigned(s_axi_awlen);   -- beats - 1
              bid_i     <= s_axi_awid;
              wready_i  <= '1';
              wstate    <= W_DATA;
            end if;

          when W_DATA =>
            -- Terminate the burst by counting AWLEN+1 beats. wlast must line up
            -- with that final beat; flag it if it does not (this also guards the
            -- writer's wlast-alignment fix against regression).
            if s_axi_wvalid = '1' and wready_i = '1' then
              assert (s_axi_wlast = '1') = (w_len = 0)
                report "axi_ram: wlast not aligned with the last burst beat"
                severity error;
              for b in 0 to STRB_WIDTH - 1 loop
                if s_axi_wstrb(b) = '1' then
                  mem(widx(w_addr))(b * 8 + 7 downto b * 8) <= s_axi_wdata(b * 8 + 7 downto b * 8);
                end if;
              end loop;
              incr   := shift_left(to_unsigned(1, ADDR_WIDTH), to_integer(w_size));
              w_addr <= w_addr + incr;
              if w_len = 0 then
                wready_i <= '0';
                bvalid_i <= '1';
                wstate   <= W_RESP;
              else
                w_len <= w_len - 1;
              end if;
            end if;

          when W_RESP =>
            if s_axi_bready = '1' then
              bvalid_i <= '0';
              wstate   <= W_IDLE;
            end if;
        end case;
      end if;
    end if;
  end process;

  -- ----------------------------------------------------------------------
  --  Read channel (AR / R)
  -- ----------------------------------------------------------------------
  read_proc : process (clk)
    variable incr : unsigned(ADDR_WIDTH - 1 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        rstate    <= R_IDLE;
        arready_i <= '0';
        rvalid_i  <= '0';
      else
        case rstate is
          when R_IDLE =>
            rvalid_i  <= '0';
            arready_i <= '1';
            if s_axi_arvalid = '1' and arready_i = '1' then
              arready_i <= '0';
              r_addr    <= unsigned(s_axi_araddr);
              r_size    <= unsigned(s_axi_arsize);
              r_cnt     <= unsigned(s_axi_arlen);   -- beats - 1
              rid_i     <= s_axi_arid;
              rstate    <= R_BURST;
            end if;

          when R_BURST =>
            rvalid_i <= '1';                        -- s_axi_rdata is combinational
            if rvalid_i = '1' and s_axi_rready = '1' then
              if r_cnt = 0 then
                rvalid_i  <= '0';
                arready_i <= '1';
                rstate    <= R_IDLE;
              else
                incr   := shift_left(to_unsigned(1, ADDR_WIDTH), to_integer(r_size));
                r_addr <= r_addr + incr;
                r_cnt  <= r_cnt - 1;
              end if;
            end if;
        end case;
      end if;
    end if;
  end process;

end architecture rtl;
