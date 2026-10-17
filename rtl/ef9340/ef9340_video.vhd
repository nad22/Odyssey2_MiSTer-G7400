-------------------------------------------------------------------------------
--
-- EF9340 (VIN) - scanline / character video renderer
--
-- Consumes the CPU-visible registers (X/Y/Y0/R) and RAM A/B contents from
-- ef9341_regs, and produces a pixel-synchronous RGB + "opaque" (not
-- box-masked) stream aligned to the existing i8244 hpos/vpos counters
-- (hpos active range 0..319 = 40 chars * 8 dots, vpos used directly as the
-- EF9340 local line counter with no extra offset - see repo memory file
-- g7400-implementation-plan.md for caveats/approximations).
--
-- This is a direct behavioural port of MAME's ef9340_1_device::draw_scanline
-- algorithm (BSD-3-Clause, Wilbert Pol/hap), restructured into a
-- column-boundary synchronous process instead of a per-line software loop.
--
-- Extended/external character memory ("exram", used when RAM B's top bit is
-- set) is NOT implemented - such characters are simply rendered as solid
-- (0xFF) pattern, matching MAME's own default readback value for an
-- unconnected exram bus.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ef9340_video is

  port (
    clk_i      : in  std_logic;
    clk_en_i   : in  std_logic;
    res_n_i    : in  std_logic;

    hpos_i     : in  std_logic_vector(8 downto 0);
    vpos_i     : in  std_logic_vector(8 downto 0);

    -- register file readout (from ef9341_regs) ------------------------------
    reg_x_i    : in  unsigned(5 downto 0);
    reg_y_i    : in  unsigned(4 downto 0);
    reg_y0_i   : in  unsigned(5 downto 0);
    reg_r_i    : in  std_logic_vector(7 downto 0);

    -- RAM A/B read port (async, addr/data pair to ef9341_regs) --------------
    vid_addr_o : out std_logic_vector(9 downto 0);
    vid_a_i    : in  std_logic_vector(7 downto 0);
    vid_b_i    : in  std_logic_vector(7 downto 0);

    -- character generator ROM (12 bit addr: set(1)&code(7)&slice(4)), 1
    -- clock registered read latency - char_a_o is issued 1 dot-clock ahead
    -- of when char_d_i is consumed (see the dot_s=1 pre-fetch below) -----
    char_a_o   : out std_logic_vector(11 downto 0);
    char_d_i   : in  std_logic_vector(7 downto 0);

    -- pixel output (registered, 1 hpos-tick pipeline) -----------------------
    rgb_o      : out std_logic_vector(2 downto 0);
    opaque_o   : out std_logic
  );

end ef9340_video;


architecture rtl of ef9340_video is

  signal hpos_q, vpos_q       : std_logic_vector(8 downto 0);
  signal col_s                : unsigned(5 downto 0);
  signal dot_s                : unsigned(2 downto 0);

  -- per-line state (updated once, at start of each line) ------------------
  signal row_active_r         : std_logic;
  signal y_row_r               : unsigned(4 downto 0);
  signal slice_r               : unsigned(3 downto 0);
  signal dh_line_r             : std_logic;
  signal h_parity_r            : std_logic;
  signal blink_prescaler_r     : unsigned(4 downto 0);
  signal blink_phase_r         : std_logic;

  -- per-column carry state (updated at every column boundary) -------------
  signal box_r, conceal_r, underline_r, w_parity_r : std_logic;

  -- per-column held output state (loaded at dot0, held for dots 1-7) -------
  signal shiftreg_r            : std_logic_vector(15 downto 0);
  signal fg_hold_r, bg_hold_r  : std_logic_vector(2 downto 0);
  signal mask_hold_r           : std_logic;
  signal opaque_hold_r         : std_logic;

  signal rgb_q                 : std_logic_vector(2 downto 0);
  signal opaque_q              : std_logic;

  function double_bits_f(c_i : std_logic_vector(7 downto 0))
    return std_logic_vector is
    variable r_v : std_logic_vector(15 downto 0);
  begin
    for i in 0 to 7 loop
      r_v(2*i)   := c_i(i);
      r_v(2*i+1) := c_i(i);
    end loop;
    return r_v;
  end function;

  function to_std_logic_f(b_i : boolean) return std_logic is
  begin
    if b_i then
      return '1';
    else
      return '0';
    end if;
  end function;

  -- Packs a char-generator ROM address exactly like MAME's reference
  -- charset_ef9340_1.rom layout: ((set&code) as an 8 bit index) * 10 +
  -- slice (slice 0-9 only) - 256 * 10 = 2560 bytes total, so a standard
  -- MAME charset dump can be loaded via the OSD as-is, with no repacking.
  function pack_char_addr_f(set_i   : std_logic;
                             code_i  : std_logic_vector(6 downto 0);
                             slice_i : unsigned(3 downto 0))
    return std_logic_vector is
    variable idx_v  : unsigned(7 downto 0);
    variable addr_v : unsigned(11 downto 0);
  begin
    idx_v  := unsigned(set_i & code_i);
    addr_v := resize(idx_v * 10, 12) + resize(slice_i, 12);
    return std_logic_vector(addr_v);
  end function;

  -- Resolves the char-generator ROM address for whichever column's a/b
  -- RAM bytes are currently on vid_a_i/vid_b_i. Used 1 dot-clock ahead of
  -- the column it applies to (see dot_s=1 pre-fetch), so that by the time
  -- that column's own dot0 runs, ef_char_rom's registered output already
  -- holds the right data. Always returns *a* address, even for the
  -- fixed-pattern cases (deliminator/exram/box/underline-blank) that end
  -- up not using char_d_i at all - issuing an unused address is harmless.
  function resolve_char_a_f(a_i         : std_logic_vector(7 downto 0);
                             b_i         : std_logic_vector(7 downto 0);
                             slice_i     : unsigned(3 downto 0);
                             h_parity_i  : std_logic)
    return std_logic_vector is
    variable s_v  : unsigned(4 downto 0);
    variable dh_v : std_logic;
  begin
    if a_i(7) = '1' then
      return pack_char_addr_f('1', b_i(6 downto 0), slice_i);
    else
      dh_v := a_i(4);
      s_v  := resize(slice_i, 5);
      if dh_v = '1' then
        if h_parity_i = '1' then
          s_v := s_v + 10;
        end if;
        if s_v > 0 then
          s_v := (s_v - 1) / 2;
        end if;
      end if;
      return pack_char_addr_f('0', b_i(6 downto 0), s_v(3 downto 0));
    end if;
  end function;

  function get_c_addr_f(x_i : unsigned(5 downto 0);
                         y_i : unsigned(4 downto 0))
    return unsigned is
    variable xv_v, yv_v : unsigned(9 downto 0);
    variable addr_v     : unsigned(9 downto 0);
  begin
    xv_v := resize(x_i, 10);
    yv_v := resize(y_i, 10);
    if (yv_v and to_unsigned(16#18#, 10)) = to_unsigned(16#18#, 10) then
      addr_v := to_unsigned(16#318#, 10) or
                shift_left(xv_v and to_unsigned(16#38#, 10), 2) or
                (xv_v and to_unsigned(16#07#, 10));
    elsif (xv_v and to_unsigned(16#20#, 10)) /= 0 then
      addr_v := to_unsigned(16#300#, 10) or
                shift_left(yv_v and to_unsigned(16#07#, 10), 5) or
                (yv_v and to_unsigned(16#18#, 10)) or
                (xv_v and to_unsigned(16#07#, 10));
    else
      addr_v := shift_left(yv_v and to_unsigned(16#1f#, 10), 5) or
                (xv_v and to_unsigned(16#1f#, 10));
    end if;
    return addr_v and to_unsigned(16#3ff#, 10);
  end function;

begin

  col_s <= unsigned(hpos_i(8 downto 3));
  dot_s <= unsigned(hpos_i(2 downto 0));

  rgb_o    <= rgb_q;
  opaque_o <= opaque_q;

  -----------------------------------------------------------------------------
  -- Process render
  --
  -- Purpose:
  --   Line-boundary (vpos change) and column-boundary (hpos change within
  --   the active 0..319 range) state updates, plus per-dot pixel output.
  --
  render: process (clk_i, res_n_i)
    variable a_v, b_v          : std_logic_vector(7 downto 0);
    variable fg_v, bg_v        : std_logic_vector(2 downto 0);
    variable pattern_v         : std_logic_vector(15 downto 0);
    variable c_v               : std_logic_vector(7 downto 0);
    variable s_v               : unsigned(4 downto 0);
    variable dh_v, dw_v, del_v : std_logic;
    variable cursor_v, blink_v, invert_v : std_logic;
    variable vpos_u_v, vpos_prev_u_v : unsigned(8 downto 0);
    variable max_vpos_v        : unsigned(8 downto 0);
    variable set_v             : std_logic;
    variable code_v            : std_logic_vector(6 downto 0);
    variable zoom_v            : integer range 1 to 2;
    variable line_v            : integer range 0 to 511;
    variable row_active_v      : std_logic;
    variable y_row_v           : unsigned(4 downto 0);
    variable slice_v           : unsigned(3 downto 0);
    variable box_v, conceal_v, underline_v : std_logic;
    variable mask_now_v        : std_logic;
    variable fg_now_v, bg_now_v : std_logic_vector(2 downto 0);
    variable opaque_now_v      : std_logic;
    variable pattern_now_v     : std_logic_vector(15 downto 0);
    variable bit_v             : std_logic;
    variable color_v           : std_logic_vector(2 downto 0);
  begin
    if res_n_i = '0' then
      hpos_q            <= (others => '1');
      vpos_q            <= (others => '1');
      row_active_r      <= '0';
      y_row_r           <= (others => '0');
      slice_r           <= (others => '0');
      dh_line_r         <= '0';
      h_parity_r        <= '0';
      blink_prescaler_r <= (others => '0');
      blink_phase_r     <= '0';
      box_r             <= '0';
      conceal_r         <= '0';
      underline_r       <= '0';
      w_parity_r        <= '0';
      shiftreg_r        <= (others => '0');
      fg_hold_r         <= (others => '0');
      bg_hold_r         <= (others => '0');
      mask_hold_r       <= '0';
      opaque_hold_r     <= '0';
      rgb_q             <= (others => '0');
      opaque_q          <= '0';
      vid_addr_o        <= (others => '0');
      char_a_o          <= (others => '0');

    elsif rising_edge(clk_i) then
      if clk_en_i = '1' then

        hpos_q <= hpos_i;
        vpos_q <= vpos_i;

        if hpos_i /= hpos_q then

          ---------------------------------------------------------------
          -- line boundary: vpos changed this same cycle -> recompute
          -- row_active_v/y_row_v/slice_v fresh (into variables, so the
          -- very first column of the new line can use them immediately
          -- without waiting a cycle for the registers to update).
          ---------------------------------------------------------------
          if vpos_i /= vpos_q then

            vpos_u_v      := unsigned(vpos_i);
            vpos_prev_u_v := unsigned(vpos_q);

            -- next h_parity (uses OLD dh_line_r / previous line's slice) --
            if vpos_prev_u_v >= 10 and vpos_prev_u_v(0) = '1' and
               slice_r = 9 then
              if dh_line_r = '1' then
                h_parity_r <= not h_parity_r;
              else
                h_parity_r <= '0';
              end if;
            end if;

            -- blink prescaler: advances once per frame (vpos wraps to 0) --
            if vpos_u_v = 0 then
              if reg_r_i(6) = '1' and blink_prescaler_r = 24 then
                blink_prescaler_r <= (others => '0');
                blink_phase_r     <= not blink_phase_r;
              elsif blink_prescaler_r = 31 then
                blink_prescaler_r <= (others => '0');
                blink_phase_r     <= not blink_phase_r;
              else
                blink_prescaler_r <= blink_prescaler_r + 1;
              end if;
              h_parity_r <= '0';
            end if;

            -- zoom / slice / row-active / y_row for the new line ----------
            line_v := to_integer(vpos_u_v);
            if reg_y0_i(5) = '1' and line_v >= 10 then
              zoom_v  := 2;
              slice_v := to_unsigned(((line_v - 10) mod 20) / 2, 4);
            else
              zoom_v  := 1;
              slice_v := to_unsigned(line_v mod 10, 4);
            end if;

            if reg_r_i(6) = '1' then
              max_vpos_v := to_unsigned(250, 9);
            else
              max_vpos_v := to_unsigned(210, 9);
            end if;

            if reg_r_i(0) = '0' or vpos_u_v >= max_vpos_v then
              row_active_v := '0';
              y_row_v      := (others => '0');
            elsif line_v < 10 then
              if reg_r_i(3) = '0' then
                row_active_v := '0';
                y_row_v      := (others => '0');
              else
                row_active_v := '1';
                y_row_v      := (others => '1'); -- 31: service row
              end if;
            else
              row_active_v := '1';
              y_row_v := to_unsigned(
                (to_integer(reg_y0_i(4 downto 0)) +
                 (line_v - 10) / (10 * zoom_v)) mod 24, 5);
            end if;

            slice_r      <= slice_v;
            row_active_r <= row_active_v;
            y_row_r      <= y_row_v;

            -- reset per-line carry state ------------------------------------
            box_v       := reg_r_i(1);
            conceal_v   := '0';
            underline_v := '0';
            box_r       <= box_v;
            conceal_r   <= conceal_v;
            underline_r <= underline_v;
            w_parity_r  <= '0';
            dh_line_r   <= '0';

          else
            -- same line: carry forward the held/registered state -----------
            slice_v      := slice_r;
            row_active_v := row_active_r;
            y_row_v      := y_row_r;
            box_v        := box_r;
            conceal_v    := conceal_r;
            underline_v  := underline_r;
          end if;

          ---------------------------------------------------------------
          -- column processing: dot0 loads a new character, dots 1-7 just
          -- shift the already-resolved pattern/attributes.
          ---------------------------------------------------------------
          if unsigned(hpos_i) < 320 and dot_s = 0 then

            a_v := vid_a_i;
            b_v := vid_b_i;

            cursor_v := reg_r_i(4) and
                        to_std_logic_f(col_s = reg_x_i) and
                        to_std_logic_f(y_row_v = reg_y_i);
            blink_v  := reg_r_i(7) and blink_phase_r;
            invert_v := cursor_v and not blink_v;
            dh_v := '0'; dw_v := '0'; del_v := '0';
            fg_v := (others => '0');
            bg_v := (others => '0');

            if a_v(7) = '1' then
              ---------------------------------------------------- graphics
              fg_v := a_v(2 downto 0);
              bg_v := a_v(6 downto 4);
              if b_v(7 downto 5) = "100" then
                pattern_v := x"00FF";
              elsif b_v(7) = '1' then
                pattern_v := x"00FF"; -- exram not implemented
              else
                set_v      := '1';
                code_v     := b_v(6 downto 0);
                char_a_o   <= pack_char_addr_f(set_v, code_v, slice_v);
                pattern_v  := "00000000" & char_d_i;
              end if;
            else
              ---------------------------------------------------- alphanum
              if b_v(7 downto 5) = "100" then
                -- deliminator
                fg_v      := a_v(2 downto 0);
                bg_v      := a_v(6 downto 4);
                pattern_v := x"00FF";
                del_v     := '1';
              else
                fg_v := a_v(2 downto 0);
                dh_v := a_v(4);
                s_v  := resize(slice_v, 5);
                if dh_v = '1' then
                  if h_parity_r = '1' then
                    s_v := s_v + 10;
                  end if;
                  if s_v > 0 then
                    s_v := (s_v - 1) / 2;
                  end if;
                end if;

                if b_v(7) = '1' then
                  c_v := x"FF"; -- exram not implemented
                elsif s_v = 9 and underline_v = '1' then
                  c_v := x"FF";
                else
                  set_v    := '0';
                  code_v   := b_v(6 downto 0);
                  char_a_o <= pack_char_addr_f(set_v, code_v, s_v(3 downto 0));
                  c_v      := char_d_i;
                end if;

                dw_v := a_v(5);
                if dw_v = '1' then
                  if w_parity_r = '0' then
                    pattern_v := double_bits_f(c_v);
                  else
                    pattern_v := shiftreg_r; -- continuation: keep old
                  end if;
                else
                  pattern_v := "00000000" & c_v;
                end if;

                if a_v(6) = '1' then
                  invert_v := not invert_v;
                  blink_v  := reg_r_i(7) and not blink_phase_r;
                end if;
              end if;
            end if;

            -- blink masking -------------------------------------------------
            if blink_v = '1' and cursor_v = '0' and
               b_v(7 downto 5) /= "100" and a_v(3) = '0' then
              pattern_v := (others => '0');
            end if;

            -- invert ----------------------------------------------------------
            if invert_v = '1' then
              pattern_v := pattern_v xor x"00FF";
            end if;

            -- w_parity update (uses THIS column's dw_v + OLD w_parity_r) ------
            if dw_v = '1' then
              w_parity_r <= not w_parity_r;
            else
              w_parity_r <= '0';
            end if;

            -- deliminator carry-state update (affects NEXT columns) -----------
            if del_v = '1' then
              conceal_r   <= b_v(0) and reg_r_i(2);
              box_r       <= (not b_v(1)) and reg_r_i(1);
              underline_r <= b_v(2);
            end if;

            dh_line_r <= dh_line_r or dh_v;

            -- prepare the RAM address for the NEXT column ----------------------
            vid_addr_o <= std_logic_vector(get_c_addr_f(col_s + 1, y_row_v));

            -- resolve dot0 output now (combinational use, then hold) -----------
            mask_now_v    := box_v or conceal_v; -- OLD (pre-update) values
            fg_now_v      := fg_v;
            bg_now_v      := bg_v;
            opaque_now_v  := not box_v;           -- OLD box_v (pre-update)
            pattern_now_v := pattern_v;

            shiftreg_r    <= '0' & pattern_now_v(15 downto 1);
            fg_hold_r     <= fg_now_v;
            bg_hold_r     <= bg_now_v;
            mask_hold_r   <= mask_now_v;
            opaque_hold_r <= opaque_now_v;

            bit_v := pattern_now_v(0);
            if row_active_v = '0' then
              rgb_q    <= (others => '0');
              opaque_q <= '0';
            else
              if mask_now_v = '1' then
                color_v := (others => '0');
              elsif bit_v = '1' then
                color_v := fg_now_v;
              else
                color_v := bg_now_v;
              end if;
              rgb_q    <= color_v;
              opaque_q <= opaque_now_v;
            end if;

          elsif unsigned(hpos_i) < 320 then
            -- dots 1..7: shift the already-loaded pattern, reuse held fg/bg
            shiftreg_r <= '0' & shiftreg_r(15 downto 1);

            -- pre-fetch the char ROM address for the NEXT column, 1 dot
            -- clock ahead of that column's own dot0 use of char_d_i: this
            -- hides ef_char_rom's 1 cycle registered read latency (vid_a_i/
            -- vid_b_i already hold the next column's data from dot_s=1
            -- onward, thanks to the vid_addr_o "col_s+1" prefetch above).
            if dot_s = 1 then
              char_a_o <= resolve_char_a_f(vid_a_i, vid_b_i, slice_r, h_parity_r);
            end if;

            if row_active_v = '0' then
              rgb_q    <= (others => '0');
              opaque_q <= '0';
            else
              if mask_hold_r = '1' then
                rgb_q <= (others => '0');
              elsif shiftreg_r(0) = '1' then
                rgb_q <= fg_hold_r;
              else
                rgb_q <= bg_hold_r;
              end if;
              opaque_q <= opaque_hold_r;
            end if;

          else
            -- outside the active 320-wide window: force blank/transparent
            rgb_q    <= (others => '0');
            opaque_q <= '0';
          end if;

        end if;

      end if;
    end if;
  end process render;
  --
  -----------------------------------------------------------------------------

end rtl;
