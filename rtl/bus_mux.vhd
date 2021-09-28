--//============================================================================
--//  Sord M5
--//  BUS Multiplexer
--//  Copyright (C) 2021 molekula
--//
--//  This program is free software; you can redistribute it and/or modify it
--//  under the terms of the GNU General Public License as published by the Free
--//  Software Foundation; either version 2 of the License, or (at your option)
--//  any later version.
--//
--//  This program is distributed in the hope that it will be useful, but WITHOUT
--//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
--//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
--//  more details.
--//
--//  You should have received a copy of the GNU General Public License along
--//  with this program; if not, write to the Free Software Foundation, Inc.,
--//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
--//
--//============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity bus_mux is

  port (
    mreq_n_i        : in  std_logic;
    rfsh_n_i        : in  std_logic;
    kb_ce_n_i       : in  std_logic;
    cas_ce_n_i      : in  std_logic;
    vdp_r_n_i       : in  std_logic;
    ctc_ce_n_i      : in  std_logic;
    int_vect_ce_n_i : in  std_logic;
    vdp_d_i         : in  std_logic_vector(7 downto 0);
    kb_d_i          : in  std_logic_vector(7 downto 0);
    ctc_d_i         : in  std_logic_vector(7 downto 0);
    kb_rst_i        : in  std_logic;
    casOut_i        : in  std_logic;
    d_o             : out std_logic_vector(7 downto 0);
    rd_n_i          : in  std_logic;
    ram_d_i         : in  std_logic_vector(7 downto 0)
  );

end bus_mux;


architecture rtl of bus_mux is

begin
      d_o <= ctc_d_i                             when (ctc_ce_n_i = '0' OR int_vect_ce_n_i = '0' ) else
             ram_d_i                             when mreq_n_i = '0' and rfsh_n_i = '1' and rd_n_i = '0' else
             vdp_d_i                             when (vdp_r_n_i = '0' ) else
             kb_d_i                              when (kb_ce_n_i = '0' ) else
             (7 => kb_rst_i, 0=> casOut_i, others => '0') when (cas_ce_n_i = '0' ) else
             (others => '1');
end rtl;
