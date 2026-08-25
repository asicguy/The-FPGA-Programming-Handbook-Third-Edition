-- sobel_stream_core.vhd
-- ------------------------------------
-- Two-pixel-per-clock 3x3 window filter over two line buffers
-- ------------------------------------
-- Author : Frank Bruno
--
-- A direct transcription of the HLS kernel, including its iteration space,
-- which is what makes the implementations bit-identical. The SystemVerilog
-- version of this file is line for line the same design; both are simulated
-- against the same testbench.
--
-- Geometry
-- --------
-- Two pixels arrive per beat, so a line is B = img_width/2 beats. Filtered
-- pixel (r, c) needs input rows r-1, r, r+1 and columns c-1, c, c+1, so output
-- beat b of row r cannot be computed until input beat b+1 of row r+1 has
-- arrived. The loop therefore runs over (H+1) x (B+1) steps:
--
--     consume input beat b of row r        when  r < H and b < B
--     produce output beat b-1 of row r-1   when  r >= 1 and b >= 1
--
-- Both come to exactly B*H, so the block is transparent to the rest of the
-- pipeline: one beat out for every beat in, no frame ever short or long. Get
-- this wrong and the symptom is not a wrong picture, it is a VDMA that never
-- completes a frame.
--
-- The extra row (r = H) consumes nothing. The input frame is over and the
-- camera is in vertical blanking; the row exists purely to flush the last
-- output line out of the line buffers, so a frame is finished before the next
-- start-of-frame arrives.
--
-- The window
-- ----------
-- Per row the core keeps the last three columns it has seen -- q0, q1, q2 --
-- and combines them with the left-hand pixel of the beat arriving now:
--
--     step b:  q0 = col 2b-3   q1 = col 2b-2   q2 = col 2b-1   new = col 2b
--              output pixels are cols 2b-2 (centre q1) and 2b-1 (centre q2)
--
-- The two Sobel windows in a beat share two of their three columns, so four
-- columns of context cover both. Three rows of that is the 3x4 window below; a
-- one-pixel-per-clock filter would need 3x3.
--
-- Pipeline, one step per cycle when not stalled:
--
--   S0  counters; present the beat address to the line buffers; pop input
--   S1  line-buffer data arrives; shift the window; write the buffers back
--   S2  the four Sobel partial sums, two per output pixel
--   S3  absolute value, clamp, mode select, push the output beat
--
-- All four share one enable, so they advance together or stall together.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use IEEE.math_real.all;

entity sobel_stream_core is
  generic (
    MAX_WIDTH : integer := 1920
  );
  port (
    clk        : in  std_logic;
    rst_n      : in  std_logic;

    -- configuration, latched at start of frame
    img_width  : in  std_logic_vector(31 downto 0);
    img_height : in  std_logic_vector(31 downto 0);
    mode       : in  std_logic_vector(31 downto 0);

    -- input video stream
    s_valid    : in  std_logic;
    s_data     : in  std_logic_vector(47 downto 0);
    s_user     : in  std_logic;    -- start of frame
    s_last     : in  std_logic;    -- end of line
    s_ready    : out std_logic;

    -- output beat, into the skid buffer
    m_wr       : out std_logic;
    m_data     : out std_logic_vector(47 downto 0);
    m_user     : out std_logic;
    m_last     : out std_logic;
    m_full     : in  std_logic
  );
end entity sobel_stream_core;

architecture rtl of sobel_stream_core is

  constant MAX_BEATS : integer := MAX_WIDTH / 2;
  constant AW        : integer := integer(ceil(log2(real(MAX_BEATS))));

  constant MODE_GRAY   : std_logic_vector(31 downto 0) := x"00000000";
  constant MODE_INVERT : std_logic_vector(31 downto 0) := x"00000002";
  constant MODE_COLOR  : std_logic_vector(31 downto 0) := x"00000003";

  constant ST_SYNC : std_logic_vector(1 downto 0) := "00";  -- waiting for a start-of-frame
  constant ST_RUN  : std_logic_vector(1 downto 0) := "01";  -- filtering a frame
  constant ST_PASS : std_logic_vector(1 downto 0) := "10";  -- forwarding a frame untouched

  signal state : std_logic_vector(1 downto 0);

  -- configuration
  signal cfg_beats : unsigned(31 downto 0);
  signal cfg_ok    : std_logic;
  signal b_r       : unsigned(15 downto 0);   -- beats per line
  signal h_r       : unsigned(15 downto 0);   -- lines per frame
  signal mode_r    : std_logic_vector(31 downto 0);

  -- line buffers, two luma values per word, one word per beat
  type lb_t is array (0 to MAX_BEATS-1) of std_logic_vector(15 downto 0);
  signal lb0 : lb_t;                          -- row r-2
  signal lb1 : lb_t;                          -- row r-1
  attribute ram_style : string;
  attribute ram_style of lb0 : signal is "block";
  attribute ram_style of lb1 : signal is "block";
  signal lb0_dout : std_logic_vector(15 downto 0);
  signal lb1_dout : std_logic_vector(15 downto 0);

  -- stage valids and payloads
  signal s0_v, s1_v, s2_v, s3_v : std_logic;
  signal r_cnt, b_cnt           : unsigned(15 downto 0);

  signal s0_consume, s0_lbrw, s0_prod : std_logic;

  signal s1_lbrw, s1_prod             : std_logic;
  signal s1_bord0, s1_bord1           : std_logic;
  signal s1_user, s1_last             : std_logic;
  signal s1_new2l, s1_new2r           : std_logic_vector(7 downto 0);
  signal s1_b                         : unsigned(AW-1 downto 0);

  signal s2_prod                      : std_logic;
  signal s2_bord0, s2_bord1           : std_logic;
  signal s2_user, s2_last             : std_logic;
  signal s2_gray0, s2_gray1           : std_logic_vector(7 downto 0);
  signal s2_gx0, s2_gy0               : signed(12 downto 0);
  signal s2_gx1, s2_gy1               : signed(12 downto 0);

  signal s3_prod, s3_user, s3_last    : std_logic;
  signal s3_data                      : std_logic_vector(47 downto 0);

  signal en : std_logic;

  -- window registers
  signal q00, q01, q02 : std_logic_vector(7 downto 0);   -- row r-2
  signal q10, q11, q12 : std_logic_vector(7 downto 0);   -- row r-1
  signal q20, q21, q22 : std_logic_vector(7 downto 0);   -- row r

  signal new0l, new0r : std_logic_vector(7 downto 0);
  signal new1l, new1r : std_logic_vector(7 downto 0);
  signal new2l, new2r : std_logic_vector(7 downto 0);

  signal l_col0, l_col2, l_top, l_bot : unsigned(11 downto 0);
  signal r_col1, r_col3, r_top, r_bot : unsigned(11 downto 0);

  signal last_step : std_logic;
  signal line_cnt  : unsigned(15 downto 0);

  signal sel0, sel1 : std_logic_vector(7 downto 0);

  -- BT.601 in Q8: 0.299/0.587/0.114 -> 77/150/29, on B,G,R from the LSB up,
  -- which is the byte order axis_channel_swap hands us. The sum reaches
  -- 255*256 = 65280, so sixteen bits hold it and the result is the top byte.
  function luma8 (px : std_logic_vector(23 downto 0)) return std_logic_vector is
    variable s : unsigned(15 downto 0);
  begin
    s := resize(29 * unsigned(px(7 downto 0)), 16)
       + resize(150 * unsigned(px(15 downto 8)), 16)
       + resize(77 * unsigned(px(23 downto 16)), 16);
    return std_logic_vector(s(15 downto 8));
  end function;

  -- a + 2b + c, the weighting every Sobel row and column tap uses. Three 8-bit
  -- pixels reach 1020, so twelve bits.
  function tap3 (a : std_logic_vector(7 downto 0);
                 b : std_logic_vector(7 downto 0);
                 c : std_logic_vector(7 downto 0)) return unsigned is
  begin
    return resize(unsigned(a), 12)
         + shift_left(resize(unsigned(b), 12), 1)
         + resize(unsigned(c), 12);
  end function;

  -- |gx| + |gy|, saturated to 8 bits.
  function magnitude (gx : signed(12 downto 0);
                      gy : signed(12 downto 0)) return std_logic_vector is
    variable ax, ay : unsigned(12 downto 0);
    variable m      : unsigned(13 downto 0);
  begin
    if gx(12) = '1' then ax := unsigned(-gx); else ax := unsigned(gx); end if;
    if gy(12) = '1' then ay := unsigned(-gy); else ay := unsigned(gy); end if;
    m := resize(ax, 14) + resize(ay, 14);
    if m(13 downto 8) /= "000000" then
      return x"FF";
    else
      return std_logic_vector(m(7 downto 0));
    end if;
  end function;

begin

  -- ------------------------------------------------------------------
  -- Configuration, and what counts as usable
  -- ------------------------------------------------------------------
  -- An odd width has no representation on a two-pixel bus, and a width beyond
  -- the line buffers cannot be filtered. Rather than quietly truncating, the
  -- core stays in ST_SYNC and drains: pixels are dropped until a notebook
  -- writes a geometry that works. Dropping is deliberate -- a block that stops
  -- reading backs the CSI-2 subsystem up until it overflows, and recovering
  -- from that needs a reset of the whole video pipeline.
  cfg_beats <= shift_right(unsigned(img_width), 1);
  cfg_ok    <= '1' when (img_width(0) = '0' and
                         cfg_beats /= 0 and
                         cfg_beats <= to_unsigned(MAX_BEATS, 32) and
                         unsigned(img_height) /= 0) else '0';

  s0_consume <= '1' when (r_cnt < h_r and b_cnt < b_r) else '0';
  s0_lbrw    <= '1' when (b_cnt < b_r) else '0';
  s0_prod    <= '1' when (r_cnt >= 1 and b_cnt >= 1) else '0';
  last_step  <= '1' when (r_cnt = h_r and b_cnt = b_r) else '0';

  -- ------------------------------------------------------------------
  -- Pipeline enable
  -- ------------------------------------------------------------------
  en <= '1' when (((s0_v = '0' or s0_consume = '0') or s_valid = '1') and
                  ((s3_v = '0' or s3_prod = '0')    or m_full = '0'))
        else '0';

  -- ------------------------------------------------------------------
  -- Stream handshake
  -- ------------------------------------------------------------------
  -- In ST_SYNC the core accepts and discards everything except a start-of-frame
  -- it can actually use -- that beat is left on the bus for the pipeline (or
  -- the passthrough) to consume as its first. TREADY is allowed to depend on
  -- TVALID and TUSER; it is TVALID that must not depend on TREADY, which is
  -- what the skid buffer on the output is for.
  process (state, en, s0_v, s0_consume, m_full, s_user, cfg_ok)
  begin
    if state = ST_RUN then
      s_ready <= en and s0_v and s0_consume;
    elsif state = ST_PASS then
      s_ready <= not m_full;
    else
      if s_user = '1' and cfg_ok = '1' then
        s_ready <= '0';
      else
        s_ready <= '1';
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------
  -- Past the right-hand edge and on the flush row there is no data. Zero is
  -- safe rather than merely convenient: every output pixel those values could
  -- reach is a frame border, and the border is black in Sobel and centre-only
  -- in the pointwise modes, so they are never observable.
  -- ------------------------------------------------------------------
  new0l <= lb0_dout(7 downto 0)   when s1_lbrw = '1' else x"00";
  new0r <= lb0_dout(15 downto 8)  when s1_lbrw = '1' else x"00";
  new1l <= lb1_dout(7 downto 0)   when s1_lbrw = '1' else x"00";
  new1r <= lb1_dout(15 downto 8)  when s1_lbrw = '1' else x"00";
  new2l <= s1_new2l;
  new2r <= s1_new2r;

  -- ------------------------------------------------------------------
  -- State machine and S0 counters
  -- ------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        state    <= ST_SYNC;
        s0_v     <= '0';
        r_cnt    <= (others => '0');
        b_cnt    <= (others => '0');
        b_r      <= (others => '0');
        h_r      <= (others => '0');
        mode_r   <= (others => '0');
        line_cnt <= (others => '0');
      else
        case state is

          when ST_SYNC =>
            if s_valid = '1' and s_user = '1' and cfg_ok = '1' then
              b_r      <= cfg_beats(15 downto 0);
              h_r      <= unsigned(img_height(15 downto 0));
              mode_r   <= mode;
              r_cnt    <= (others => '0');
              b_cnt    <= (others => '0');
              line_cnt <= (others => '0');
              if mode = MODE_COLOR then
                state <= ST_PASS;
              else
                state <= ST_RUN;
                s0_v  <= '1';
              end if;
            end if;

          when ST_RUN =>
            if en = '1' and s0_v = '1' then
              if last_step = '1' then
                s0_v <= '0';
              elsif b_cnt = b_r then
                b_cnt <= (others => '0');
                r_cnt <= r_cnt + 1;
              else
                b_cnt <= b_cnt + 1;
              end if;
            end if;
            -- back to hunting for a start-of-frame once the last step has drained
            if s0_v = '0' and s1_v = '0' and s2_v = '0' and s3_v = '0' then
              state <= ST_SYNC;
            end if;

          when ST_PASS =>
            -- Lines are counted from TLAST rather than from the beat counter,
            -- so a passthrough frame stays aligned with the stream even if the
            -- registers disagree with what the camera is actually sending.
            if s_valid = '1' and m_full = '0' and s_last = '1' then
              if line_cnt = h_r - 1 then
                state <= ST_SYNC;
              else
                line_cnt <= line_cnt + 1;
              end if;
            end if;

          when others =>
            state <= ST_SYNC;

        end case;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------
  -- Line-buffer read, S0 -> S1
  -- ------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      if en = '1' then
        lb0_dout <= lb0(to_integer(b_cnt(AW-1 downto 0)));
        lb1_dout <= lb1(to_integer(b_cnt(AW-1 downto 0)));
      end if;
    end if;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        s1_v <= '0';
      elsif en = '1' then
        if s0_v = '1' and state = ST_RUN then
          s1_v <= '1';
        else
          s1_v <= '0';
        end if;
        s1_lbrw <= s0_lbrw;
        s1_prod <= s0_prod;
        s1_b    <= b_cnt(AW-1 downto 0);
        if s0_consume = '1' then
          s1_new2l <= luma8(s_data(23 downto 0));
          s1_new2r <= luma8(s_data(47 downto 24));
        else
          s1_new2l <= x"00";
          s1_new2r <= x"00";
        end if;
        -- Output pixel (r-1, 2b-2) and (r-1, 2b-1). Sobel is undefined on the
        -- one-pixel frame border, where the C emits black:
        --   row    r-1 = 0     -> r = 1        r-1 = H-1 -> r = H
        --   col  2b-2 = 0      -> b = 1        2b-1 = W-1 -> b = B
        -- 2b-2 can never be W-1 and 2b-1 can never be 0, so those two cases do
        -- not appear -- a consequence of the pixels being paired.
        if r_cnt = 1 or r_cnt = h_r or b_cnt = 1 then
          s1_bord0 <= '1';
        else
          s1_bord0 <= '0';
        end if;
        if r_cnt = 1 or r_cnt = h_r or b_cnt = b_r then
          s1_bord1 <= '1';
        else
          s1_bord1 <= '0';
        end if;
        if r_cnt = 1 and b_cnt = 1 then
          s1_user <= '1';
        else
          s1_user <= '0';
        end if;
        if b_cnt = b_r then
          s1_last <= '1';
        else
          s1_last <= '0';
        end if;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------
  -- S1: window shift and line-buffer writeback
  -- ------------------------------------------------------------------
  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        q00 <= x"00"; q01 <= x"00"; q02 <= x"00";
        q10 <= x"00"; q11 <= x"00"; q12 <= x"00";
        q20 <= x"00"; q21 <= x"00"; q22 <= x"00";
      elsif en = '1' and s1_v = '1' then
        q00 <= q02;  q01 <= new0l;  q02 <= new0r;
        q10 <= q12;  q11 <= new1l;  q12 <= new1r;
        q20 <= q22;  q21 <= new2l;  q22 <= new2r;
      end if;
    end if;
  end process;

  -- The write address trails the read address by one step, so a line buffer is
  -- never read and written at the same location in the same cycle.
  process (clk)
  begin
    if rising_edge(clk) then
      if en = '1' and s1_v = '1' and s1_lbrw = '1' then
        lb0(to_integer(s1_b)) <= lb1_dout;                 -- row r-1 becomes r-2
        lb1(to_integer(s1_b)) <= s1_new2r & s1_new2l;      -- row r becomes r-1
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------
  -- S1 -> S2: the four Sobel partial sums, from the pre-shift window
  -- ------------------------------------------------------------------
  -- centred on q1: columns q0, q1, q2
  l_col0 <= tap3(q00, q10, q20);
  l_col2 <= tap3(q02, q12, q22);
  l_top  <= tap3(q00, q01, q02);
  l_bot  <= tap3(q20, q21, q22);
  -- centred on q2: columns q1, q2, new
  r_col1 <= tap3(q01,   q11,   q21);
  r_col3 <= tap3(new0l, new1l, new2l);
  r_top  <= tap3(q01,   q02,   new0l);
  r_bot  <= tap3(q21,   q22,   new2l);

  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        s2_v <= '0';
      elsif en = '1' then
        s2_v     <= s1_v;
        s2_prod  <= s1_prod;
        s2_bord0 <= s1_bord0;
        s2_bord1 <= s1_bord1;
        s2_user  <= s1_user;
        s2_last  <= s1_last;
        s2_gray0 <= q11;
        s2_gray1 <= q12;
        s2_gx0   <= signed('0' & l_col2) - signed('0' & l_col0);
        s2_gy0   <= signed('0' & l_bot)  - signed('0' & l_top);
        s2_gx1   <= signed('0' & r_col3) - signed('0' & r_col1);
        s2_gy1   <= signed('0' & r_bot)  - signed('0' & r_top);
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------
  -- S2 -> S3: absolute value, clamp, mode select
  -- ------------------------------------------------------------------
  -- Compare the whole word, not just the low bits: the C tests = MODE_GRAY,
  -- = MODE_INVERT and = MODE_COLOR and falls through to Sobel for every other
  -- value, so mode 7 must give Sobel rather than something else.
  process (mode_r, s2_gray0, s2_gray1, s2_bord0, s2_bord1,
           s2_gx0, s2_gy0, s2_gx1, s2_gy1)
  begin
    if mode_r = MODE_GRAY then
      sel0 <= s2_gray0;
      sel1 <= s2_gray1;
    elsif mode_r = MODE_INVERT then
      sel0 <= std_logic_vector(x"FF" - unsigned(s2_gray0));
      sel1 <= std_logic_vector(x"FF" - unsigned(s2_gray1));
    else
      if s2_bord0 = '1' then
        sel0 <= x"00";
      else
        sel0 <= magnitude(s2_gx0, s2_gy0);
      end if;
      if s2_bord1 = '1' then
        sel1 <= x"00";
      else
        sel1 <= magnitude(s2_gx1, s2_gy1);
      end if;
    end if;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      if rst_n = '0' then
        s3_v <= '0';
      elsif en = '1' then
        s3_v    <= s2_v;
        s3_prod <= s2_prod;
        s3_user <= s2_user;
        s3_last <= s2_last;
        -- luma replicated across B, G and R for both pixels of the beat
        s3_data <= sel1 & sel1 & sel1 & sel0 & sel0 & sel0;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------------
  -- Output
  -- ------------------------------------------------------------------
  -- The write strobe is qualified by `en` rather than held: the pipeline can
  -- stall for a reason that has nothing to do with the consumer -- S0 waiting
  -- on an input beat -- and a held strobe would push the same beat again on
  -- every stalled cycle.
  process (state, s_valid, s_data, s_user, s_last, m_full,
           en, s3_v, s3_prod, s3_data, s3_user, s3_last)
  begin
    if state = ST_PASS then
      m_wr   <= s_valid and not m_full;
      m_data <= s_data;
      m_user <= s_user;
      m_last <= s_last;
    else
      m_wr   <= en and s3_v and s3_prod;
      m_data <= s3_data;
      m_user <= s3_user;
      m_last <= s3_last;
    end if;
  end process;

end architecture rtl;
