-- tb_aic3104_poll.vhd
-- ----------------------------------------------------------------------------
--  Native VHDL self-checking testbench for aic3104_poll.
--
--  A small inline "loopback codec" model captures the DUT's I2S serial output
--  (TX) and echoes it back onto the serial input (RX) with the correct
--  half-bit-period timing. So a CPU-written TX sample is serialized out,
--  looped through the codec model, deserialized by the RX path, and read back
--  via REG_RX_DATA -- exercising both the TX and RX datapaths and proving the
--  32-bit slot framing is self-consistent.
--
--  The codec model mirrors the DUT's framing: 32-bit slots, top 16 bits carry
--  the sample, bit index = {counter[7], 31-counter[6:2]}. It samples/drives on
--  the 2'b00 counter phase (mid-bit), opposite the DUT's 2'b10 phase.
-- ----------------------------------------------------------------------------
-- Author : Frank Bruno

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_aic3104_poll is
end entity tb_aic3104_poll;

architecture sim of tb_aic3104_poll is

  -- Register byte offsets
  constant REG_TX_CTRL  : std_logic_vector(11 downto 0) := x"000";
  constant REG_TX_DATA  : std_logic_vector(11 downto 0) := x"008";
  constant REG_TX_STAT  : std_logic_vector(11 downto 0) := x"00C";
  constant REG_RX_CTRL  : std_logic_vector(11 downto 0) := x"110";
  constant REG_RX_DATA  : std_logic_vector(11 downto 0) := x"118";
  constant REG_RX_STAT  : std_logic_vector(11 downto 0) := x"11C";
  constant REG_DEV      : std_logic_vector(11 downto 0) := x"200";
  constant REG_VER      : std_logic_vector(11 downto 0) := x"204";

  -- Clocks / reset
  signal s_axi_aclk    : std_logic := '0';
  signal s_axi_aresetn : std_logic := '1';
  signal AIC_mclk_o    : std_logic := '0';

  -- AXI4-Lite
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

  -- I2S
  signal interrupt_out : std_logic;
  signal AIC_lrclk_o   : std_logic;
  signal AIC_sclk_o    : std_logic;
  signal i2s_sdata_i   : std_logic := '0';
  signal i2s_sdata_o   : std_logic;

  -- loopback codec model state
  signal tb_counter : unsigned(7 downto 0) := (others => '0');
  signal cap_word   : std_logic_vector(63 downto 0) := (others => '0');

  -- DUT serializer bit index for a given counter value
  function idxf(x : unsigned(7 downto 0)) return integer is
    variable b : integer;
  begin
    if x(7) = '1' then b := 32; else b := 0; end if;
    return b + (31 - to_integer(x(6 downto 2)));
  end function;

begin

  -- Clocks
  s_axi_aclk <= not s_axi_aclk after 10 ns;   -- 50 MHz AXI
  AIC_mclk_o <= not AIC_mclk_o after 41 ns;   -- ~12.2 MHz codec MCLK

  -- DUT
  dut : entity work.aic3104_poll
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
      interrupt_out => interrupt_out,
      AIC_mclk_o    => AIC_mclk_o,
      AIC_lrclk_o   => AIC_lrclk_o,
      AIC_sclk_o    => AIC_sclk_o,
      AIC_sdata_i   => i2s_sdata_i,
      AIC_sdata_o   => i2s_sdata_o
    );

  -- ----------------------------------------------------------------------
  --  Loopback codec model: free-running counter in lockstep with the DUT's
  --  i2s_counter (both start at 0 and tick every MCLK). On the mid-bit phase
  --  it captures the TX serial bit and re-drives it (one tick ahead) on RX.
  -- ----------------------------------------------------------------------
  codec : process (AIC_mclk_o)
  begin
    if rising_edge(AIC_mclk_o) then
      tb_counter <= tb_counter + 1;
      if tb_counter(1 downto 0) = "00" then
        -- capture TX bit (the bit driven for the previous 2'b10 tick)
        cap_word(idxf(tb_counter - 2)) <= i2s_sdata_o;
        -- drive RX bit for the upcoming 2'b10 tick (echo what we captured)
        i2s_sdata_i <= cap_word(idxf(tb_counter + 2));
      end if;
    end if;
  end process;

  -- Watchdog
  watchdog : process
  begin
    wait for 20 ms;
    report "TIMEOUT: testbench did not finish" severity error;
    finish;
  end process;

  -- ----------------------------------------------------------------------
  --  Stimulus
  -- ----------------------------------------------------------------------
  stim : process
    variable test_reg : std_logic_vector(31 downto 0);
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

    procedure wait_frames(n : integer) is
    begin
      for i in 0 to n * 256 - 1 loop
        wait until rising_edge(AIC_mclk_o);
      end loop;
    end procedure;

    -- Read one RX sample, waiting until the RX FIFO is non-empty.
    procedure get_rx is
    begin
      loop
        cpu_rd_reg(REG_RX_STAT);
        exit when test_reg(0) = '0';   -- bit0 = empty
      end loop;
      cpu_rd_reg(REG_RX_DATA);
    end procedure;

    -- Drain whatever is currently in the RX FIFO.
    procedure drain_rx is
    begin
      loop
        cpu_rd_reg(REG_RX_STAT);
        exit when test_reg(0) = '1';   -- empty
        cpu_rd_reg(REG_RX_DATA);
      end loop;
    end procedure;

    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then
        report msg severity error;
        errs := errs + 1;
      end if;
    end procedure;

    -- Fill the TX FIFO with a steady sample, then capture it back through the
    -- codec loopback and confirm REG_RX_DATA returns it.
    procedure run_loopback(sample : std_logic_vector(31 downto 0); tag : string) is
    begin
      cpu_wr_reg(REG_RX_CTRL, x"00000001");           -- enable RX capture
      for i in 0 to 119 loop                          -- fill TX FIFO (depth 128)
        cpu_wr_reg(REG_TX_DATA, sample);
      end loop;
      wait_frames(30);                                -- let the loopback settle
      drain_rx;                                        -- flush transitional frames
      wait_frames(4);
      for i in 0 to 3 loop                            -- check several fresh reads
        get_rx;
        check(test_reg = sample,
              tag & ": RX readback " & integer'image(i) & " = "
              & to_hstring(test_reg) & ", expected " & to_hstring(sample));
      end loop;
      cpu_wr_reg(REG_RX_CTRL, x"00000000");           -- disable RX capture
      drain_rx;
      wait_frames(130);                                -- let the TX FIFO drain out
      if errs = 0 then
        report tag & " loopback PASSED: 0x" & to_hstring(sample)
               & " round-tripped TX->RX";
      end if;
    end procedure;

  begin
    -- reset
    s_axi_aresetn <= '1';
    wait until rising_edge(s_axi_aclk);
    s_axi_aresetn <= '0';
    for i in 0 to 99 loop wait until rising_edge(s_axi_aclk); end loop;
    s_axi_aresetn <= '1';
    for i in 0 to 99 loop wait until rising_edge(s_axi_aclk); end loop;

    -- identity registers
    cpu_rd_reg(REG_DEV);
    check(test_reg = x"33313034", "REG_DEV should read '3104'");
    cpu_rd_reg(REG_VER);
    check(test_reg = x"00000001", "REG_VER should read 1");

    -- both paths, two distinct samples (proves data-dependence, not stuck-at)
    run_loopback(x"1234_5678", "Pass 1 (TX+RX)");
    run_loopback(x"ABCD_4321", "Pass 2 (TX+RX)");

    if errs = 0 then
      report "==== ALL TESTS PASSED ====" severity note;
    else
      report "==== TESTS FAILED: " & integer'image(errs) & " error(s) ====" severity error;
    end if;
    finish;
  end process;

end architecture sim;
