-------------------------------------------------------------------------------
--
-- EF9340 (VIN) / EF9341 (GEN) - CPU-facing register and RAM interface
--
-- Used by the Philips Videopac+ G7400 / Magnavox Odyssey 3 for the
-- higher resolution overlay graphics. This block implements the CPU
-- visible registers (TA/TB latches, X/Y/Y0/R/M) and the two 1KB
-- character/attribute RAMs (RAM A, RAM B). It is a direct port of the
-- documented EF9340/EF9341 command set (cross-checked against MAME's
-- ef9340_1 device model).
--
-- The 1KB x 2 RAM is read (async) by the companion video renderer
-- (ef9340_video) through vid_addr_i/vid_a_o/vid_b_o.
--
-- Note: external/extended character memory ("exram", used by the write
-- slice / read slice commands for custom cartridge-supplied character
-- sets) is not implemented - exram_d_i should be tied to a fixed value
-- by the caller, exram writes are exposed but otherwise unused.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ef9341_regs is

  port (
    clk_i      : in  std_logic;
    clk_en_i   : in  std_logic;
    res_n_i    : in  std_logic;
    -- CPU bus interface --------------------------------------------------
    cs_n_i     : in  std_logic;
    rd_n_i     : in  std_logic;
    wr_n_i     : in  std_logic;
    addr_i     : in  std_logic_vector(1 downto 0);
    din_i      : in  std_logic_vector(7 downto 0);
    dout_o     : out std_logic_vector(7 downto 0);
    -- video side register readout -----------------------------------------
    reg_x_o    : out unsigned(5 downto 0);
    reg_y_o    : out unsigned(4 downto 0);
    reg_y0_o   : out unsigned(5 downto 0);
    reg_r_o    : out std_logic_vector(7 downto 0);
    -- video side RAM A/B read port (async) ---------------------------------
    vid_addr_i : in  std_logic_vector(9 downto 0);
    vid_a_o    : out std_logic_vector(7 downto 0);
    vid_b_o    : out std_logic_vector(7 downto 0);
    -- external/extended memory (slice read/write, not implemented) ---------
    exram_a_o  : out std_logic_vector(19 downto 0);
    exram_d_o  : out std_logic_vector(7 downto 0);
    exram_d_i  : in  std_logic_vector(7 downto 0);
    exram_we_o : out std_logic
  );

end ef9341_regs;


architecture rtl of ef9341_regs is

  type ram1k_t is array (0 to 1023) of std_logic_vector(7 downto 0);
  signal ram_a_q, ram_b_q : ram1k_t;

  signal ta_q, tb_q : std_logic_vector(7 downto 0);
  signal x_q        : unsigned(6 downto 0);
  signal y_q        : unsigned(4 downto 0);
  signal y0_q       : unsigned(5 downto 0);
  signal r_q        : std_logic_vector(7 downto 0);
  signal m_q        : std_logic_vector(7 downto 0);

  signal dout_q     : std_logic_vector(7 downto 0);
  signal exram_we_q : std_logic;

  signal rd_n_d_q,
         wr_n_d_q   : std_logic;

  -- Write data/address are captured while WR is low and committed on the
  -- rising edge: on the 8048 bus the data byte is not yet on DB at the
  -- falling edge of WR (DB still carries the latched address).
  signal wr_pend_q  : std_logic;
  signal wdata_q    : std_logic_vector(7 downto 0);
  signal waddr_q    : std_logic_vector(1 downto 0);

  -- packed helper: X/Y increment as specified by the EF9340 "increment C"
  -- command (also triggered implicitly by the auto-increment read/write
  -- RAM commands).
  function inc_c_f(x_i : unsigned(6 downto 0);
                    y_i : unsigned(4 downto 0))
    return std_logic_vector is
    variable nx_v : unsigned(6 downto 0);
    variable ny_v : unsigned(4 downto 0);
  begin
    nx_v := x_i + 1;
    ny_v := y_i;
    if nx_v = 40 or nx_v = 48 or nx_v = 56 or nx_v = 64 then
      ny_v := y_i + 1;
      if ny_v = 24 then
        ny_v := (others => '0');
      end if;
      nx_v := (others => '0');
    end if;
    return std_logic_vector(ny_v) & std_logic_vector(nx_v);
  end function;

  -- packed helper: translate X/Y character coordinates into the linear
  -- 10-bit RAM A/B address (service row is aliased at the high end).
  function get_c_addr_f(x_i : unsigned(6 downto 0);
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

  reg_x_o    <= x_q(5 downto 0);
  reg_y_o    <= y_q;
  reg_y0_o   <= y0_q;
  reg_r_o    <= r_q;
  dout_o     <= dout_q;
  exram_we_o <= exram_we_q;

  -- video side RAM read port (asynchronous, small RAM - fine for
  -- distributed/LUT RAM inference)
  vid_a_o <= ram_a_q(to_integer(unsigned(vid_addr_i)));
  vid_b_o <= ram_b_q(to_integer(unsigned(vid_addr_i)));

  -----------------------------------------------------------------------------
  -- Process cpu_if
  --
  -- Purpose:
  --   Implements the CPU visible registers, the RAM A/B write port and
  --   the EF9340/EF9341 command decoding. Bus cycles are recognized on
  --   the falling edge of rd_n_i while cs_n_i is asserted; writes are
  --   committed on the rising edge of wr_n_i (see wdata_q).
  --
  cpu_if: process (clk_i, res_n_i)
    variable caddr_v : unsigned(9 downto 0);
    variable slice_v : unsigned(3 downto 0);
    variable xy_v    : std_logic_vector(11 downto 0);
  begin
    if res_n_i = '0' then
      ta_q        <= (others => '0');
      tb_q        <= (others => '0');
      x_q         <= (others => '0');
      y_q         <= (others => '0');
      y0_q        <= (others => '0');
      r_q         <= (others => '0');
      m_q         <= (others => '0');
      dout_q      <= (others => '0');
      exram_we_q  <= '0';
      exram_a_o   <= (others => '0');
      exram_d_o   <= (others => '0');
      rd_n_d_q    <= '1';
      wr_n_d_q    <= '1';
      wr_pend_q   <= '0';
      wdata_q     <= (others => '0');
      waddr_q     <= (others => '0');
    elsif rising_edge(clk_i) then
      -- Sampled every clk_i, NOT gated by clk_en_i: the CPU bus (wr_n_i/
      -- rd_n_i) runs synchronous to clk_cpu_en_i, a different and
      -- out-of-phase enable than clk_vdc_en_i (this block's clk_en_i).
      -- Gating this edge-detect on clk_en_i caused write/read pulses to
      -- be missed almost always, since the two enables rarely coincide -
      -- matches the working i8244_cpuio.vhd bus sampling scheme, which
      -- also samples every clk_i with no clk_en_i gating.

      exram_we_q <= '0';

      if cs_n_i = '0' and wr_n_i = '0' then
        wr_pend_q <= '1';
        wdata_q   <= din_i;
        waddr_q   <= addr_i;
      elsif wr_n_i = '1' then
        wr_pend_q <= '0';
      end if;

      -------------------------------------------------------------------
      -- write cycle (committed on the rising edge of wr_n_i)
      -------------------------------------------------------------------
      if wr_pend_q = '1' and wr_n_i = '1' then

            if waddr_q(1) = '1' then
              -- command register --------------------------------------
              if waddr_q(0) = '1' then
                tb_q <= wdata_q;
                case wdata_q(7 downto 5) is
                  when "000" =>             -- begin row
                    x_q <= (others => '0');
                    y_q <= unsigned(ta_q(4 downto 0));
                  when "001" =>             -- load Y
                    y_q <= unsigned(ta_q(4 downto 0));
                  when "010" =>             -- load X
                    x_q <= resize(unsigned(ta_q(5 downto 0)), 7);
                  when "011" =>             -- increment C
                    xy_v := inc_c_f(x_q, y_q);
                    y_q  <= unsigned(xy_v(11 downto 7));
                    x_q  <= unsigned(xy_v(6 downto 0));
                  when "100" =>             -- load M
                    m_q <= ta_q;
                  when "101" =>             -- load R
                    r_q <= ta_q;
                  when "110" =>             -- load Y0
                    y0_q <= unsigned(ta_q(5 downto 0));
                  when others =>            -- not interpreted
                    null;
                end case;
              else
                ta_q <= wdata_q;
              end if;

            else
              -- data register -------------------------------------------
              if waddr_q(0) = '1' then
                tb_q     <= wdata_q;
                caddr_v  := get_c_addr_f(x_q, y_q);
                case m_q(7 downto 5) is
                  when "000" =>             -- write + increment
                    ram_a_q(to_integer(caddr_v)) <= ta_q;
                    ram_b_q(to_integer(caddr_v)) <= wdata_q;
                    xy_v := inc_c_f(x_q, y_q);
                    y_q  <= unsigned(xy_v(11 downto 7));
                    x_q  <= unsigned(xy_v(6 downto 0));
                  when "010" =>             -- write, no increment
                    ram_a_q(to_integer(caddr_v)) <= ta_q;
                    ram_b_q(to_integer(caddr_v)) <= wdata_q;
                  when "100" =>             -- write slice (exram)
                    slice_v    := unsigned(m_q(3 downto 0));
                    if unsigned(ram_b_q(to_integer(caddr_v))) >= 16#A0# then
                      exram_we_q <= '1';
                    end if;
                    exram_a_o  <= ram_a_q(to_integer(caddr_v)) &
                                  ram_b_q(to_integer(caddr_v)) &
                                  std_logic_vector(slice_v);
                    exram_d_o  <= ta_q;
                    if slice_v = 9 then
                      m_q(3 downto 0) <= (others => '0');
                    else
                      m_q(3 downto 0) <= std_logic_vector(slice_v + 1);
                    end if;
                  when others =>            -- illegal / read command
                    null;
                end case;
              else
                ta_q <= wdata_q;
              end if;
            end if;

          end if;

      if cs_n_i = '0' then

          ---------------------------------------------------------------
          -- read cycle (falling edge of rd_n_i)
          ---------------------------------------------------------------
          if rd_n_d_q = '1' and rd_n_i = '0' then

            if addr_i(1) = '1' then
              -- command/status register - busy flag, always idle here
              dout_q <= (others => '0');

            else
              if addr_i(0) = '1' then
                dout_q  <= tb_q;
                caddr_v := get_c_addr_f(x_q, y_q);
                case m_q(7 downto 5) is
                  when "001" =>             -- read + increment
                    ta_q <= ram_a_q(to_integer(caddr_v));
                    tb_q <= ram_b_q(to_integer(caddr_v));
                    xy_v := inc_c_f(x_q, y_q);
                    y_q  <= unsigned(xy_v(11 downto 7));
                    x_q  <= unsigned(xy_v(6 downto 0));
                  when "011" =>             -- read, no increment
                    ta_q <= ram_a_q(to_integer(caddr_v));
                    tb_q <= ram_b_q(to_integer(caddr_v));
                  when "101" =>             -- read slice (exram)
                    slice_v   := unsigned(m_q(3 downto 0));
                    exram_a_o <= ram_a_q(to_integer(caddr_v)) &
                                 ram_b_q(to_integer(caddr_v)) &
                                 std_logic_vector(slice_v);
                    ta_q      <= exram_d_i;
                    if slice_v = 9 then
                      m_q(3 downto 0) <= (others => '0');
                    else
                      m_q(3 downto 0) <= std_logic_vector(slice_v + 1);
                    end if;
                  when others =>            -- illegal / write command
                    null;
                end case;
              else
                dout_q <= ta_q;
              end if;
            end if;

          end if;

      end if;

      rd_n_d_q <= rd_n_i;
      wr_n_d_q <= wr_n_i;

    end if;
  end process cpu_if;
  --
  -----------------------------------------------------------------------------

end rtl;
