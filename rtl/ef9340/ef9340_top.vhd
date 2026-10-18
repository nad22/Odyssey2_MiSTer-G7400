-------------------------------------------------------------------------------
--
-- EF9340 (VIN) + EF9341 (GEN) - top level wrapper
--
-- Combines ef9341_regs (CPU-facing registers + RAM A/B) and ef9340_video
-- (scanline/column renderer) into a single instantiable block for
-- vp_console.vhd.
--
-- Extended character memory ("exram", 2 KB, cart-defined glyphs written by\r
-- the write-slice command) is implemented here; the read-slice command is not.
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ef9340_top is

  port (
    clk_i      : in  std_logic;
    clk_en_i   : in  std_logic;
    res_n_i    : in  std_logic;

    -- CPU bus interface ------------------------------------------------------
    cs_n_i     : in  std_logic;
    rd_n_i     : in  std_logic;
    wr_n_i     : in  std_logic;
    addr_i     : in  std_logic_vector(1 downto 0);
    din_i      : in  std_logic_vector(7 downto 0);
    dout_o     : out std_logic_vector(7 downto 0);

    -- video timing (from i8244) ----------------------------------------------
    hpos_i     : in  std_logic_vector(8 downto 0);
    vpos_i     : in  std_logic_vector(8 downto 0);

    -- character generator ROM (async, 12 bit addr) ---------------------------
    char_a_o   : out std_logic_vector(11 downto 0);
    char_d_i   : in  std_logic_vector(7 downto 0);

    -- pixel output -------------------------------------------------------------
    rgb_o      : out std_logic_vector(2 downto 0);
    opaque_o   : out std_logic
  );

end ef9340_top;


architecture rtl of ef9340_top is

  signal reg_x_s  : unsigned(5 downto 0);
  signal reg_y_s  : unsigned(4 downto 0);
  signal reg_y0_s : unsigned(5 downto 0);
  signal reg_r_s  : std_logic_vector(7 downto 0);

  signal vid_addr_s : std_logic_vector(9 downto 0);
  signal vid_a_s, vid_b_s : std_logic_vector(7 downto 0);

  signal exram_a_s  : std_logic_vector(19 downto 0);
  signal exram_d_s   : std_logic_vector(7 downto 0);
  signal exram_we_s  : std_logic;

  signal exr_a_s     : std_logic_vector(19 downto 0);
  signal exr_q       : std_logic_vector(7 downto 0);
  type exmem_t is array (0 to 2047) of std_logic_vector(7 downto 0);
  signal exmem_s     : exmem_t := (others => (others => '0'));

  -- 20 bit a&b&slice to 11 bit RAM index, same folding as MAME odyssey2.cpp
  function exidx_f(a_i : std_logic_vector(19 downto 0)) return integer is
    variable l_v : std_logic_vector(7 downto 0);
    variable r_v : std_logic_vector(10 downto 0);
  begin
    l_v := a_i(19) & a_i(10 downto 4);
    r_v := (others => '0');
    r_v(4 downto 0) := l_v(4 downto 0);
    r_v(9) := a_i(0);
    r_v(10) := l_v(7);
    if a_i(3) = '1' then
      r_v(6 downto 5) := l_v(6 downto 5);
    else
      r_v(6 downto 5) := a_i(2 downto 1);
      r_v(8 downto 7) := l_v(6 downto 5);
    end if;
    return to_integer(unsigned(r_v));
  end function;

begin

  process (clk_i)
  begin
    if rising_edge(clk_i) then
      if exram_we_s = '1' then
        exmem_s(exidx_f(exram_a_s)) <= exram_d_s;
      end if;
      exr_q <= exmem_s(exidx_f(exr_a_s));
    end if;
  end process;

  regs_b: entity work.ef9341_regs
    port map (
      clk_i      => clk_i,
      clk_en_i   => clk_en_i,
      res_n_i    => res_n_i,
      cs_n_i     => cs_n_i,
      rd_n_i     => rd_n_i,
      wr_n_i     => wr_n_i,
      addr_i     => addr_i,
      din_i      => din_i,
      dout_o     => dout_o,
      reg_x_o    => reg_x_s,
      reg_y_o    => reg_y_s,
      reg_y0_o   => reg_y0_s,
      reg_r_o    => reg_r_s,
      vid_addr_i => vid_addr_s,
      vid_a_o    => vid_a_s,
      vid_b_o    => vid_b_s,
      exram_a_o  => exram_a_s,
      exram_d_o  => exram_d_s,
      exram_d_i  => x"FF",
      exram_we_o => exram_we_s
    );

  video_b: entity work.ef9340_video
    port map (
      clk_i      => clk_i,
      clk_en_i   => clk_en_i,
      res_n_i    => res_n_i,
      hpos_i     => hpos_i,
      vpos_i     => vpos_i,
      reg_x_i    => reg_x_s,
      reg_y_i    => reg_y_s,
      reg_y0_i   => reg_y0_s,
      reg_r_i    => reg_r_s,
      vid_addr_o => vid_addr_s,
      vid_a_i    => vid_a_s,
      vid_b_i    => vid_b_s,
      char_a_o   => char_a_o,
      char_d_i   => char_d_i,
      exr_a_o    => exr_a_s,
      exr_d_i    => exr_q,
      rgb_o      => rgb_o,
      opaque_o   => opaque_o
    );


end rtl;
