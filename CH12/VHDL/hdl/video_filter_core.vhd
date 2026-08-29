-- video_filter_core.vhd
-- ------------------------------------
-- 3x3 sliding-window filter over two line buffers
-- ------------------------------------
-- Author : Frank Bruno
--
-- A direct RTL transcription of the HLS window_filter stage, including its
-- iteration space, which is what makes the two implementations bit-identical.
--
-- The loop runs (height+1) x (width+1) times. A pixel is consumed whenever
-- (r < height and c < width). In the three filtered modes one is produced
-- whenever (r >= 1 and c >= 1), because the window centre win11 at step (r,c)
-- holds input pixel (r-1,c-1) and cannot be filtered until the row below it
-- has arrived. Both totals come to exactly width*height, which keeps the input
-- and output FIFOs balanced -- get it wrong and the symptom is a deadlock, not
-- a wrong picture.
--
-- MODE_COLOR produces on the *consume* condition instead: it has no window, so
-- it owes no delay. The totals still come to width*height either way.
--
-- This is where CH12 differs from CH11. CH11's core took 8-bit luma in and put
-- 8-bit luma out, because luma was computed before the FIFO and the colour was
-- discarded there. Colour passthrough needs the original pixel to survive as
-- far as the output, so here the whole 32-bit pixel travels the pipeline and
-- luma is computed on the way in. The line buffers stay 8 bits wide -- the
-- window only ever needs a neighbour's brightness -- so the extra cost is
-- registers and FIFO width, not another BRAM.
--
-- Pipeline, one step per cycle when not stalled:
--   S0  counters; present column address to the line buffers; pop input
--   S1  line-buffer data arrives; luma of the new pixel; shift the window;
--       write the buffers back
--   S2  compute the Sobel partial sums gx / gy
--   S3  absolute value, clamp, mode select, push output
--
-- All four stages share one enable, so they advance together or not at all.

LIBRARY IEEE;
USE IEEE.std_logic_1164.all;
USE IEEE.numeric_std.all;

entity video_filter_core is
  generic (
    MAX_WIDTH : integer := 1920
  );
  port (
    clk        : in  std_logic;
    rst_n      : in  std_logic;

    start      : in  std_logic;
    img_width  : in  std_logic_vector(15 downto 0);
    img_height : in  std_logic_vector(15 downto 0);
    mode       : in  std_logic_vector(31 downto 0);
    done       : out std_logic;

    -- 32-bit BGRA pixel in
    s_valid    : in  std_logic;
    s_data     : in  std_logic_vector(31 downto 0);
    s_ready    : out std_logic;

    -- 32-bit BGRA pixel out
    m_valid    : out std_logic;
    m_data     : out std_logic_vector(31 downto 0);
    m_ready    : in  std_logic
  );
end entity video_filter_core;

architecture rtl of video_filter_core is

  -- Must match HLS/src/video_filter.hpp.
  constant MODE_GRAY   : std_logic_vector(31 downto 0) := x"00000000";
  constant MODE_SOBEL  : std_logic_vector(31 downto 0) := x"00000001";
  constant MODE_INVERT : std_logic_vector(31 downto 0) := x"00000002";
  constant MODE_COLOR  : std_logic_vector(31 downto 0) := x"00000003";

  -- ITU-R BT.601 luma in Q8, ordered B,G,R to match the pixel layout.
  constant LUMA_B : integer := 29;
  constant LUMA_G : integer := 150;
  constant LUMA_R : integer := 77;

  -- Line buffers, luma only: the window never needs a neighbour's colour.
  type lb_t is array (0 to MAX_WIDTH-1) of std_logic_vector(7 downto 0);
  signal lb0 : lb_t := (others => (others => '0'));
  signal lb1 : lb_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of lb0 : signal is "block";
  attribute ram_style of lb1 : signal is "block";

  signal lb0_dout, lb1_dout : std_logic_vector(7 downto 0) := (others => '0');

  signal w_r, h_r  : unsigned(15 downto 0) := (others => '0');
  signal mode_r    : std_logic_vector(31 downto 0) := (others => '0');
  signal color_mode : std_logic;

  signal running   : std_logic := '0';
  signal s0_v, s1_v, s2_v, s3_v : std_logic := '0';
  signal r_cnt, c_cnt : unsigned(15 downto 0) := (others => '0');

  signal s0_need_in, s0_rd, s0_prod : std_logic;
  signal s1_rd, s1_prod, s1_border  : std_logic := '0';
  signal s1_newpx : std_logic_vector(7 downto 0)  := (others => '0');
  signal s1_pix   : std_logic_vector(31 downto 0) := (others => '0');
  signal s1_c     : unsigned(15 downto 0) := (others => '0');

  signal s2_prod, s2_border : std_logic := '0';
  signal s2_gray  : std_logic_vector(7 downto 0)  := (others => '0');
  signal s2_pix   : std_logic_vector(31 downto 0) := (others => '0');
  signal s2_gx, s2_gy : signed(12 downto 0) := (others => '0');

  signal s3_prod  : std_logic := '0';

  signal en        : std_logic;
  signal last_step : std_logic;

  signal luma_sum : unsigned(17 downto 0);
  signal luma_in  : std_logic_vector(7 downto 0);

  -- The C keeps a win[3][3]. The RTL needs only two of its three columns as
  -- registers: n00..n22 below *are* the window at the current step, and win**
  -- is the previous step's copy of it, shifted left. Column 0 of that copy is
  -- never read back, so those three registers would be dead silicon.
  signal win01, win02 : std_logic_vector(7 downto 0) := (others => '0');
  signal win11, win12 : std_logic_vector(7 downto 0) := (others => '0');
  signal win21, win22 : std_logic_vector(7 downto 0) := (others => '0');

  signal n00, n01, n02, n10, n11, n12, n20, n21, n22 : std_logic_vector(7 downto 0);

  signal col_l, col_rt, row_t, row_b : unsigned(11 downto 0);
  signal abs_gx, abs_gy : unsigned(12 downto 0);
  signal mag            : unsigned(13 downto 0);
  signal sobel_v, sel_v : std_logic_vector(7 downto 0);

begin

  color_mode <= '1' when mode_r = MODE_COLOR else '0';

  s0_need_in <= '1' when (r_cnt < h_r and c_cnt < w_r) else '0';
  s0_rd      <= '1' when (c_cnt < w_r) else '0';
  -- The one mode-dependent piece of the iteration space. Colour passthrough
  -- emits the pixel it just took; every other mode emits the pixel a row and a
  -- column behind, because that is where the window centre is.
  s0_prod    <= s0_need_in when color_mode = '1' else
                '1' when (r_cnt >= 1 and c_cnt >= 1) else '0';
  last_step  <= '1' when (r_cnt = h_r and c_cnt = w_r) else '0';

  en <= '1' when (((s0_v = '0' or s0_need_in = '0') or s_valid = '1') and
                  ((s3_v = '0' or s3_prod = '0')    or m_ready = '1'))
        else '0';

  -- Both of these are single-cycle strobes qualified by `en`, not held
  -- AXI-style valid/ready. The pipeline can stall for a reason unrelated to the
  -- consumer -- S0 waiting on an input pixel -- and a held m_valid would make
  -- the downstream FIFO latch the same output pixel again every stalled cycle.
  s_ready <= en and s0_v and s0_need_in;
  m_valid <= en and s3_v and s3_prod;

  -- Luma of the pixel arriving at S0, on the way into S1. The weights sum to
  -- 256, so white lands on exactly 255 and no clamp is needed.
  luma_sum <= resize(unsigned(s_data(7 downto 0))   * LUMA_B, 18) +
              resize(unsigned(s_data(15 downto 8))  * LUMA_G, 18) +
              resize(unsigned(s_data(23 downto 16)) * LUMA_R, 18);
  luma_in  <= std_logic_vector(luma_sum(15 downto 8));

  -- The C shifts the window left first, then fills column 2. Because every
  -- right-hand side here reads the pre-shift registers, the "past the right
  -- edge" branch reduces to simply holding column 2.
  n00 <= win01;  n01 <= win02;
  n02 <= lb0_dout when s1_rd = '1' else win02;
  n10 <= win11;  n11 <= win12;
  n12 <= lb1_dout when s1_rd = '1' else win12;
  n20 <= win21;  n21 <= win22;
  n22 <= s1_newpx when s1_rd = '1' else win22;

  -- S0: counters
  process (clk) begin
    if rising_edge(clk) then
      if rst_n = '0' then
        running <= '0';
        s0_v    <= '0';
        r_cnt   <= (others => '0');
        c_cnt   <= (others => '0');
        w_r     <= (others => '0');
        h_r     <= (others => '0');
        mode_r  <= (others => '0');
        done    <= '0';
      else
        done <= '0';
        if start = '1' and running = '0' then
          w_r    <= unsigned(img_width);
          h_r    <= unsigned(img_height);
          mode_r <= mode;
          r_cnt  <= (others => '0');
          c_cnt  <= (others => '0');
          -- a zero-sized image has nothing to do
          if unsigned(img_width) /= 0 and unsigned(img_height) /= 0 then
            s0_v <= '1';
          else
            s0_v <= '0';
          end if;
          running <= '1';
        elsif running = '1' then
          if en = '1' and s0_v = '1' then
            if last_step = '1' then
              s0_v <= '0';
            elsif c_cnt = w_r then
              c_cnt <= (others => '0');
              r_cnt <= r_cnt + 1;
            else
              c_cnt <= c_cnt + 1;
            end if;
          end if;
          -- finished once the last step has drained past S3
          if s0_v = '0' and s1_v = '0' and s2_v = '0' and s3_v = '0' then
            running <= '0';
            done    <= '1';
          end if;
        end if;
      end if;
    end if;
  end process;

  -- line-buffer read
  process (clk) begin
    if rising_edge(clk) then
      if en = '1' then
        lb0_dout <= lb0(to_integer(c_cnt(10 downto 0)));
        lb1_dout <= lb1(to_integer(c_cnt(10 downto 0)));
      end if;
    end if;
  end process;

  -- S0 -> S1
  process (clk) begin
    if rising_edge(clk) then
      if rst_n = '0' then
        s1_v <= '0';
      elsif en = '1' then
        s1_v    <= s0_v;
        s1_rd   <= s0_rd;
        s1_prod <= s0_prod;
        s1_c    <= c_cnt;
        if s0_need_in = '1' then
          s1_newpx <= luma_in;
          s1_pix   <= s_data;
        else
          s1_newpx <= (others => '0');
          s1_pix   <= (others => '0');
        end if;
        -- Sobel is undefined on the 1px frame border; the C emits black there
        if r_cnt = 1 or r_cnt = h_r or c_cnt = 1 or c_cnt = w_r then
          s1_border <= '1';
        else
          s1_border <= '0';
        end if;
      end if;
    end if;
  end process;

  -- S1: window shift and line-buffer writeback
  process (clk) begin
    if rising_edge(clk) then
      if rst_n = '0' then
        win01 <= (others => '0'); win02 <= (others => '0');
        win11 <= (others => '0'); win12 <= (others => '0');
        win21 <= (others => '0'); win22 <= (others => '0');
      elsif en = '1' and s1_v = '1' then
        win01 <= n01; win02 <= n02;
        win11 <= n11; win12 <= n12;
        win21 <= n21; win22 <= n22;
      end if;
    end if;
  end process;

  process (clk) begin
    if rising_edge(clk) then
      if en = '1' and s1_v = '1' and s1_rd = '1' then
        lb0(to_integer(s1_c(10 downto 0))) <= lb1_dout;   -- row r-1 -> r-2
        lb1(to_integer(s1_c(10 downto 0))) <= s1_newpx;   -- row r   -> r-1
      end if;
    end if;
  end process;

  -- S1 -> S2: Sobel partial sums from the post-shift window
  col_l  <= resize(unsigned(n00), 12) + (resize(unsigned(n10), 12) sll 1) + resize(unsigned(n20), 12);
  col_rt <= resize(unsigned(n02), 12) + (resize(unsigned(n12), 12) sll 1) + resize(unsigned(n22), 12);
  row_t  <= resize(unsigned(n00), 12) + (resize(unsigned(n01), 12) sll 1) + resize(unsigned(n02), 12);
  row_b  <= resize(unsigned(n20), 12) + (resize(unsigned(n21), 12) sll 1) + resize(unsigned(n22), 12);

  process (clk) begin
    if rising_edge(clk) then
      if rst_n = '0' then
        s2_v <= '0';
      elsif en = '1' then
        s2_v      <= s1_v;
        s2_prod   <= s1_prod;
        s2_border <= s1_border;
        s2_gray   <= n11;
        s2_pix    <= s1_pix;
        s2_gx     <= signed("0" & col_rt) - signed("0" & col_l);
        s2_gy     <= signed("0" & row_b)  - signed("0" & row_t);
      end if;
    end if;
  end process;

  -- S2 -> S3: absolute value, clamp, mode select
  abs_gx <= unsigned(-s2_gx) when s2_gx(12) = '1' else unsigned(s2_gx);
  abs_gy <= unsigned(-s2_gy) when s2_gy(12) = '1' else unsigned(s2_gy);
  mag    <= ("0" & abs_gx) + ("0" & abs_gy);

  sobel_v <= (others => '0') when s2_border = '1' else
             x"FF"           when mag(13 downto 8) /= "000000" else
             std_logic_vector(mag(7 downto 0));

  -- Compare the whole word, not just the low bits: the C tests "== MODE_COLOR",
  -- "== MODE_GRAY" then "== MODE_INVERT" and falls through to Sobel for every
  -- other value, so mode 7 must give Sobel.
  sel_v <= s2_gray when mode_r = MODE_GRAY else
           std_logic_vector(to_unsigned(255, 8) - unsigned(s2_gray))
                    when mode_r = MODE_INVERT else
           sobel_v;

  process (clk) begin
    if rising_edge(clk) then
      if rst_n = '0' then
        s3_v <= '0';
      elsif en = '1' then
        s3_v    <= s2_v;
        s3_prod <= s2_prod;
        -- Colour passthrough hands back the pixel untouched, alpha included.
        -- Every other mode replicates the result across B, G and R and forces
        -- alpha opaque -- a frame reaching the DisplayPort with a transparent
        -- alpha byte is a black screen, not a subtle bug.
        if color_mode = '1' then
          m_data <= s2_pix;
        else
          m_data <= x"FF" & sel_v & sel_v & sel_v;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
