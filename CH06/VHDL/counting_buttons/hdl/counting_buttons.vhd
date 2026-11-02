-- counting_buttons.vhd
-- ------------------------------------
-- Count the number of button presses
-- ------------------------------------
-- Author : Frank Bruno
-- Count the number of center button presses and display the count in decimal
-- or hexidecimal on the 7 segment display

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity counting_buttons is
  generic(
    MODE         : string  := "HEX";    -- "HEX"
    NUM_SEGMENTS : integer := 8;
    ASYNC_BUTTON : string  := "SAFE" -- "CLOCK", "NOCLOCK", "SAFE", "DEBOUNCE"
  );
  port(
    clk         : in  std_logic;
    PL_USER_PB  : in  std_logic_vector(0 downto 0);
    CPU_RESETN  : in  std_logic;
    ext_counter : out std_logic_vector(NUM_SEGMENTS*4 - 1 downto 0)
  );
end entity counting_buttons;

architecture rtl of counting_buttons is

  -- Array of 4 bit digits. The element is constrained for VHDL-2002, which
  -- does not allow arrays of unconstrained std_logic_vector.
  type nibble_array_t is array (natural range <>) of std_logic_vector(3 downto 0);
  subtype encoded_t is nibble_array_t(NUM_SEGMENTS - 1 downto 0);

  -- Decimal increment function
  function dec_inc(din : in encoded_t)
  return encoded_t is
    variable int_val  : encoded_t;
    variable next_val : integer range 0 to 16;
    variable carry_in : integer range 0 to 1;
  begin
    carry_in := 1;
    for i in 0 to NUM_SEGMENTS - 1 loop
      next_val := to_integer(unsigned(din(i))) + carry_in;
      if next_val > 9 then
        int_val(i) := (others => '0');
        carry_in   := 1;
      else
        int_val(i) := std_logic_vector(to_unsigned(next_val, 4));
        carry_in   := 0;
      end if;
    end loop;
    return int_val;
  end function;

  -- Hexadecimal increment function
  function hex_inc(din : in encoded_t)
  return encoded_t is

    variable hex_val  : encoded_t;
    variable next_val : integer range 0 to 16;
    variable carry_in : integer range 0 to 1;
  begin
    carry_in := 1;
    for i in 0 to NUM_SEGMENTS - 1 loop
      next_val := to_integer(unsigned(din(i))) + carry_in;
      if next_val = 16 then
        hex_val(i) := (others => '0');
        carry_in   := 1;
      else
        hex_val(i) := std_logic_vector(to_unsigned(next_val, 4));
        carry_in   := 0;
      end if;
    end loop;
    return hex_val;
  end function;

  attribute MARK_DEBUG : string;
  attribute ASYNC_REG  : string;
  signal encoded       : encoded_t                                   := (others => (others => '0'));
  signal reset_sync    : std_logic_vector(1 downto 0)                := (others => '1');
  attribute ASYNC_REG of reset_sync : signal is "TRUE";
  signal reset         : std_logic;
  signal last_button   : std_logic                                   := '0';
  signal button        : std_logic                                   := '0';
  signal button_down   : std_logic                                   := '0';
  attribute MARK_DEBUG of button_down : signal is "TRUE";

begin

  process (encoded)
  begin
    for i in 0 to NUM_SEGMENTS - 1 loop
      ext_counter(i*4 + 3 downto i*4) <= encoded(i);
    end loop;
  end process;

  -- Reset Synchronizer
  process(clk)
  begin
    if rising_edge(clk) then
      reset_sync <= reset_sync(0) & not CPU_RESETN;
    end if;
  end process;

  reset <= reset_sync(1);

  -- Capture the rising edge of button press
  g_SAFE : if ASYNC_BUTTON = "SAFE" generate
    signal button_sync : std_logic_vector(2 downto 0);
    attribute ASYNC_REG of button_sync : signal is "TRUE";
    attribute MARK_DEBUG of button_sync : signal is "TRUE";
  begin
    process(clk)
    begin
      if rising_edge(clk) then
        button_down <= '0';
        button_sync <= button_sync(1 downto 0) & PL_USER_PB(0);
        if button_sync(2 downto 1) = "01" then
          button_down <= '1';
        else
          button_down <= '0';
        end if;
      end if;
    end process;
  end generate g_SAFE;

  g_DEBOUNCE : if ASYNC_BUTTON = "DEBOUNCE" generate
    signal button_sync : std_logic_vector(2 downto 0);
    attribute ASYNC_REG of button_sync : signal is "TRUE";
    attribute MARK_DEBUG of button_sync : signal is "TRUE";
    signal counter_en  : std_logic              := '0';
    attribute MARK_DEBUG of counter_en : signal is "TRUE";
    signal counter     : integer range 0 to 255 := 0;
    attribute MARK_DEBUG of counter : signal is "TRUE";
  begin
    process(clk)
    begin
      if rising_edge(clk) then
        button_down <= '0';
        button_sync <= button_sync(1 downto 0) & PL_USER_PB(0);
        if button_sync(2 downto 1) = "01" then
          counter_en <= '1';
        elsif button_sync(1) = '0' then
          counter_en <= '0';
          counter    <= 0;
        end if;
        if counter_en = '1' then
          if counter = 255 then
            counter_en  <= '0';
            counter     <= 0;
            button_down <= '1';
          else
            counter <= counter + 1;
          end if;
        end if;
        if reset = '1' then
          counter_en  <= '0';
          counter     <= 0;
          button_down <= '0';
        end if;
      end if;
    end process;
  end generate g_DEBOUNCE;

  g_NOCLOCK : if ASYNC_BUTTON /= "SAFE" and ASYNC_BUTTON /= "DEBOUNCE" generate
    process(clk)
    begin
      if rising_edge(clk) then
        last_button <= button;
        button      <= PL_USER_PB(0);
        if PL_USER_PB(0) = '1' and button = '0' then
          button_down <= '1';
        else
          button_down <= '0';
        end if;
      end if;
    end process;
  end generate g_NOCLOCK;

  process(clk)
  begin
    if rising_edge(clk) then
      if button_down = '1' then
        if MODE = "HEX" then
          encoded <= hex_inc(encoded);
        else
          encoded <= dec_inc(encoded);
        end if;
      end if;
      if reset = '1' then
        for i in 0 to NUM_SEGMENTS - 1 loop
          encoded(i) <= (others => '0');
        end loop;
        --encoded     <= ((others => '0')(others => '0'));
      end if;
    end if;
  end process;
end architecture;
