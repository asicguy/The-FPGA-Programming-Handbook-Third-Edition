-- calculator.vhd
-- ------------------------------------
-- Moore version of the Calculator state machine
-- ------------------------------------
-- Author : Frank Bruno

LIBRARY IEEE;
USE IEEE.std_logic_1164.all;
USE IEEE.numeric_std.all;
use IEEE.math_real.all;

entity calculator is
  generic(
    DIVIDE : string := "false";
    BITS   : integer := 32
  );
  port(
   s_axi_aclk    : in     std_logic;
   s_axi_aresetn : in     std_logic;
   s_axi_awaddr  : in     std_logic_vector(15 downto 0);
   s_axi_awvalid : in     std_logic;
   s_axi_awready : out    std_logic;
   s_axi_wdata   : in     std_logic_vector(31 downto 0);
   s_axi_wstrb   : in     std_logic_vector(3 downto 0);
   s_axi_wvalid  : in     std_logic;
   s_axi_wready  : out    std_logic;
   s_axi_bresp   : out    std_logic_vector(11 downto 0);
   s_axi_bvalid  : out    std_logic;
   s_axi_bready  : in     std_logic;
   s_axi_araddr  : in     std_logic_vector(15 downto 0);
   s_axi_arvalid : in     std_logic;
   s_axi_arready : out    std_logic;
   s_axi_rdata   : out    std_logic_vector(31 downto 0);
   s_axi_rresp   : out    std_logic_vector(1 downto 0);
   s_axi_rvalid  : out    std_logic;
   s_axi_rready  : in     std_logic;
   interrupt_out : out    std_logic
  );
end entity calculator;

architecture rtl of calculator is

  constant BC : natural := natural(ceil(log2(real(BITS))));
  constant REG_A   : std_logic_vector(7 downto 0) := x"0";
  constant REG_B   : std_logic_vector(7 downto 0) := x"4";
  constant REG_C   : std_logic_vector(7 downto 0) := x"8";
  constant REG_REM : std_logic_vector(7 downto 0) := x"C";
  constant REG_OP  : std_logic_vector(7 downto 0) := x"10";
  constant REG_INT : std_logic_vector(7 downto 0) := x"14";

  type axil_rd_cs_t is (RD_IDLE, RD_WAIT, RD_W4RREADY);
  type axil_cs_t is    (WR_IDLE, WR_W4ADDR, WR_W4DATA, WR_BRESP);
  type state_t is      (IDLE, INTERRUPT, DIVIDE0);
  type operator_t is   (ADD, SUB, MUL, DIV);

  signal state       : state_t      := IDLE;
  signal axil_rd_cs  : axil_rd_cs_t := RD_IDLE;
  signal axil_cs     : axil_cs_t    := WR_IDLE;
  signal operator    : operator_t;

  signal start       : std_logic;
  signal set_int     : std_logic;
  signal a_in        : std_logic_vector(BITS - 1 downto 0);
  signal b_in        : std_logic_vector(BITS - 1 downto 0);
  signal c_out       : std_logic_vector(BITS - 1 downto 0);
  signal rem_out     : std_logic_vector(BITS - 1 downto 0);
  signal dividend    : std_logic_vector(BITS - 1 downto 0);
  signal divisor     : std_logic_vector(BITS - 1 downto 0);
  signal start_div   : std_logic;
  signal done        : std_logic;
  signal quotient    : unsigned(BITS - 1 downto 0);
  signal remainder   : unsigned(BITS - 1 downto 0);
  signal rd_addr     : std_logic_vector(15 downto 0);
  signal read_data   : std_logic_vector(31 downto 0);
  signal axil_din    : std_logic_vector(31 downto 0);
  signal axil_be     : std_logic_vector(3 downto 0);
  signal axil_we     : std_logic;
  signal axil_addr   : std_logic_vector(15 downto 0);
  signal op_store    : std_logic_vector(1 downto 0);
  signal s_axi_rvalid_reg  : std_logic;
  signal interrupt_out_reg : std_logic;
begin

  s_axi_rvalid  <= s_axi_rvalid_reg;
  interrupt_out <= interrupt_out_reg;

  process(s_axi_aclk)
    variable product : signed(BITS * 2 - 1 downto 0);
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        state   <= IDLE;
        c_out   <= (others => '0');
        set_int <= '0';
      else
        set_int <= '0';
        case state is
          when IDLE =>
            -- Wait for data to be operated on to be entered. Then the user presses
            -- The operation, add, sub, multiply or divide
            if start = '1' then
              if operator = ADD then
                c_out <= std_logic_vector(signed(a_in) + signed(b_in));
                state <= INTERRUPT;
              elsif operator = SUB then
                c_out <= std_logic_vector(signed(a_in) - signed(b_in));
                state <= INTERRUPT;
              elsif operator = MUL then
                product := signed(a_in) * signed(b_in);
                c_out   <= std_logic_vector(product(c_out'range));
                state   <= INTERRUPT;
              else
                if DIVIDE = "true" then
                  start_div <= '1';
                  dividend  <= a_in;
                  divisor   <= b_in;
                  state     <= DIVIDE0;
                end if;
              end if;
            end if;

          when DIVIDE0 =>
            if done = '1' then
              c_out   <= std_logic_vector(quotient);
              rem_out <= std_logic_vector(remainder);
              state   <= INTERRUPT;
            end if;

          when INTERRUPT =>
            set_int <= '1';
            state   <= IDLE;

        end case;
      end if;
    end if;
  end process;

  u_divider_nr : entity work.divider_nr
    generic map (
      BITS      => BITS
    )
    port map (
      clk       => s_axi_aclk,
      reset     => s_axi_aresetn,
      start     => start_div,
      dividend  => unsigned(dividend),
      divisor   => unsigned(divisor),
      done      => done,
      quotient  => quotient,
      remainder => remainder
    );

  -- AXI Read Channel
  process(s_axi_aclk) begin
    s_axi_arready <= '1';
    s_axi_rvalid  <= '0';
    s_axi_rresp   <= "00";

    case axil_rd_cs is
      when RD_IDLE =>
        if s_axi_arvalid = '1' then
          s_axi_arready <= '0';
          rd_addr       <= s_axi_araddr(15 downto 0);
          axil_rd_cs    <= RD_WAIT;
        end if;
      when RD_WAIT =>
        s_axi_arready <= '0';
        axil_rd_cs    <= RD_W4RREADY;
      when RD_W4RREADY =>
        s_axi_arready <= '0';
        s_axi_rdata   <= read_data;
        s_axi_rvalid  <= '1';
        if s_axi_rready = '1' and s_axi_rvalid_reg = '1' then
          s_axi_arready <= '1';
          s_axi_rvalid  <= '0';
          axil_rd_cs    <= RD_IDLE;
        end if;
    end case;

    if s_axi_aresetn = '0' then
      axil_rd_cs <= RD_IDLE;
    end if;
  end process;

  -- AXI Write Channel
  process (s_axi_aclk) begin
    axil_we       <= '0';
    s_axi_bvalid  <= '0';
    s_axi_bresp   <= "00"; -- OKAY

    case axil_cs is
      when WR_IDLE =>
        s_axi_awready <= '1';
        s_axi_wready  <= '1';
        if s_axi_awvalid = '1' and s_axi_wvalid = '1' then
          s_axi_awready <= '0';
          s_axi_wready  <= '0';
          axil_addr     <= s_axi_awaddr(15 downto 0);
          axil_we       <= '1';
          s_axi_bvalid  <= '1';
          axil_cs       <= WR_BRESP;
          axil_din      <= s_axi_wdata;
          axil_be       <= s_axi_wstrb;
        elsif s_axi_awvalid = '1' and s_axi_wvalid = '0' then
          -- Address only
          s_axi_awready <= '0';
          axil_addr     <= s_axi_awaddr(15 downto 0);
          axil_cs       <= WR_W4DATA;
        elsif s_axi_awvalid = '0' and s_axi_wvalid = '1' then
          s_axi_wready <= '0';
          axil_we      <= '1';
          axil_din     <= s_axi_wdata;
          axil_be      <= s_axi_wstrb;
          axil_cs      <= WR_W4ADDR;
        end if;
      when WR_W4DATA =>
        if s_axi_wvalid = '1' then
          s_axi_wready <= '0';
          axil_we      <= '1';
          s_axi_bvalid <= '1';
          axil_din     <= s_axi_wdata;
          axil_be      <= s_axi_wstrb;
          axil_cs      <= WR_BRESP;
        end if;
      when WR_W4ADDR =>
        if s_axi_awvalid = '1' then
          s_axi_awready <= '0';
          s_axi_bvalid  <= '1';
          axil_addr     <= s_axi_awaddr(15 downto 0);
          axil_cs       <= WR_BRESP;
        end if;
      when WR_BRESP =>
        s_axi_awready <= '0';
        s_axi_wready  <= '0';
        s_axi_bvalid  <= '1';
        if s_axi_bready = '1' then
          s_axi_awready <= '1';
          s_axi_wready  <= '1';
          s_axi_bvalid  <= '0';
          axil_cs       <= WR_IDLE;
        end if;
    end case;
    if s_axi_aresetn = '0' then
      axil_cs <= WR_IDLE;
    end if;
  end process;

  process (s_axi_aclk) begin
    start <= '0';
    if set_int = '1' then
      interrupt_out <= '1';
    end if;
    if axil_we = '1' then
      case axil_addr(7 downto 0) is
        when REG_A =>
          for i in 0 to 3 loop
            if axil_be(i) = '1' then
              a_in((8*i) + 7 downto 8*i) <= axil_din((8*i) + 7 downto 8*i);
            end if;
          end loop;
        when REG_B =>
          for i in 0 to 3 loop
            if axil_be(i) = '1' then
              b_in((8*i) + 7 downto 8*i) <= axil_din((8*i) + 7 downto 8*i);
            end if;
          end loop;
        when REG_OP =>
          start <= '1';
          if axil_be(0) = '1' then
            op_store <= axil_din(1 downto 0);
          end if;
        when REG_INT =>
          if interrupt_out_reg = '1' and axil_din(0) = '1' and axil_be(0) = '1' then
            interrupt_out <= '0';
          end if;
      end case;
    end if;
  end process;

  operator <= operator_t'val(to_integer(unsigned(axil_din(1 downto 0))));

  process(s_axi_aclk) begin
    read_data <= (others => '0');
    case rd_addr(7 downto 0) is
      when REG_A   => read_data             <= a_in;
      when REG_B   => read_data             <= b_in;
      when REG_C   => read_data             <= c_out;
      when REG_REM => read_data             <= rem_out;
      when REG_OP  => read_data(1 downto 0) <= op_store;
      when REG_INT => read_data(0)          <= interrupt_out_reg;
    end case;
  end process;

end;
