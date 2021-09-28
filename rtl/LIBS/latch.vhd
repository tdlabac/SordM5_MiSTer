--//============================================================================
--//  Sord M5
--//  libs
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
USE ieee.numeric_std.ALL;

entity io_latch is
   generic (
      compare_width    : integer := 8;
      compare_value    : std_logic_vector(7 downto 0) := (others => '0')
   );
port (
   clk_i           : in  std_logic;
   reset_n_i       : in  std_logic;
   d_i             : in  std_logic_vector(7 downto 0);
   a_i             : in  std_logic_vector(7 downto 0);
   q_o             : out std_logic_vector(7 downto 0);
   iorq_n_i        : in  std_logic;
   m1_n_i          : in  std_logic;
   wr_n_i          : in  std_logic;
   default_i       : in  std_logic_vector(7 downto 0)
  );

end io_latch;


architecture rtl of io_latch is
   signal io_we_s       : std_logic;

begin
   io_we_s  <= '1' when iorq_n_i = '0' and m1_n_i = '1' and wr_n_i = '0' and a_i(7 downto 8 - compare_width) = compare_value (7 downto 8 - compare_width) else '0';
      
latch : process (clk_i, io_we_s, reset_n_i) 
   begin
    if clk_i'event and clk_i = '1' then
      if reset_n_i = '0' then 
         q_o <= default_i;
      elsif io_we_s = '1' then 
         q_o <= d_i;
      end if;
    end if;
   end process;
end rtl;   