--//============================================================================
--//  Sord M5
--//  Address decoder
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

entity addr_dec is

  port (
    clk_i           : in  std_logic;
    reset_n_i       : in  std_logic;
    a_i             : in  std_logic_vector(15 downto 0);
    d_i             : in  std_logic_vector(7 downto 0);
    iorq_n_i        : in  std_logic;
    m1_n_i          : in  std_logic;
    rd_n_i          : in  std_logic;
    wr_n_i          : in  std_logic;
    mreq_n_i        : in  std_logic;
    rfsh_n_i        : in  std_logic;
    bios_ce_n_o     : out std_logic;
    ram_ce_n_o      : out std_logic;
    ram_we_n_o      : out std_logic;
    vdp_r_n_o       : out std_logic;
    vdp_w_n_o       : out std_logic;
    psg_we_n_o      : out std_logic;
    kb_ce_n_o       : out std_logic;
    cas_ce_n_o      : out std_logic;
    ctc_ce_n_o      : out std_logic;
    int_vect_ce_n_o : out std_logic;
    casOn_o         : out std_logic := '0';
    ramMode_i       : in  std_logic_vector(5 downto 0)
  );

end addr_dec;


architecture rtl of addr_dec is
     signal io_s          : boolean;
     signal mem_s         : boolean;
     signal mode64kbi_s   : std_logic := '1';
     signal mode64krx_s   : std_logic_vector(7 downto 0) := (others =>'1');
     signal ram64kbi_CS_s : std_logic;
     signal ram64krx_CS_s : std_logic; -- future
     signal ram_ce_n_s    : std_logic;
     signal bios_ce_n_s   : std_logic;
     signal cas_we_s            : std_logic;
     
     signal area_bios_s         : boolean;
     signal area_internal_RAM_s : boolean;
     signal area_low_ram_s      : boolean;
     signal area_hi_ram_s       : boolean;
    
     signal extram_em5_s        : boolean;
     signal extram_kbi_s        : boolean;
     signal extram_kbx_s        : boolean;    -- future
     
     signal kbi_mode_32_64_s    : boolean;    -- 0 - 32KB / 1 - 64KB
     signal kbi_mode_mon_s      : boolean;    -- 0 - not disable monitor / 1 - enable disable monitor (RAM 64KB)
     signal kbi_mode_RW_s       : boolean;    -- 0 - loRAM RW enable / 1 - loRAM RW disable (write protect)
     signal kbi_bios_disable_s  : boolean;
     signal kbi_loRam_enable_s  : boolean;
     
begin
  io_s               <= iorq_n_i = '0' and m1_n_i = '1';
  mem_s              <= mreq_n_i = '0' and rfsh_n_i = '1';
  
  extram_em5_s       <= ramMode_i(1 downto 0) = "01";
  extram_kbi_s       <= ramMode_i(1 downto 0) = "10";
  extram_kbx_s       <= ramMode_i(1 downto 0) = "11";  -- future
  kbi_mode_32_64_s   <= ramMode_i(2) = '1';
  kbi_mode_mon_s     <= ramMode_i(3) = '1';
  kbi_mode_RW_s      <= ramMode_i(4) = '1';
  
  area_bios_s        <= mem_s AND a_i(15 downto 13) = "000";
  area_internal_ram_s<= mem_s AND a_i(15 downto 13) = "011";
  area_low_ram_s     <= mem_s AND a_i(15) = '0';
  area_hi_ram_s      <= mem_s AND a_i(15) = '1';
  
  kbi_bios_disable_s <= extram_kbi_s and kbi_mode_mon_s and mode64kbi_s='1';
  kbi_loRam_enable_s <= extram_kbi_s and kbi_mode_32_64_s;
  
  
  bios_ce_n_s        <= '0' when area_bios_s AND NOT kbi_bios_disable_s else '1';
  ram_ce_n_s         <= '0' when area_internal_RAM_s 
                              OR (area_low_ram_s and bios_ce_n_s = '1' )
                              OR (area_hi_ram_s and (extram_em5_s or extram_kbi_s))
                              else '1';
                              
  ram_we_n_o         <= '0' when wr_n_i = '0' and ram_ce_n_s = '0' and not(area_low_ram_s and kbi_mode_RW_s and not area_internal_ram_s) else '1';
  ram_ce_n_o         <= ram_ce_n_s;                          
  bios_ce_n_o        <= bios_ce_n_s;
  
-- IO
  vdp_r_n_o          <= '0' when io_s and a_i(7 downto 4) = "0001"     AND rd_n_i = '0' else '1' ;    -- VDP rd
  vdp_w_n_o          <= '0' when io_s and a_i(7 downto 4) = "0001"     AND wr_n_i = '0' else '1' ;    -- VDP wr
  kb_ce_n_o          <= '0' when io_s and a_i(7 downto 4) = "0011"     AND rd_n_i = '0' else '1' ;    -- KB rd
  cas_ce_n_o         <= '0' when io_s and a_i(7 downto 4) = "0101"     AND rd_n_i = '0' else '1' ;    -- CAS rd
  cas_we_s           <= '1' when io_s and a_i(7 downto 4) = "0101"     AND wr_n_i = '0' else '0' ;    -- CAS wr
  ctc_ce_n_o         <= '0' when io_s and a_i(7 downto 4) = "0000"                      else '1' ;    -- CTC rd
  psg_we_n_o         <= '0' when io_s and a_i(7 downto 0) = "00100000" AND wr_n_i = '0' else '1' ;    -- SGC wr
  ram64kbi_CS_s      <= '1' when io_s and a_i(7 downto 0) = "01101100" AND wr_n_i = '0' else '0' ;    -- 64kbi 6C
  ram64krx_CS_s      <= '1' when io_s and a_i(7 downto 0) = "01111111" AND wr_n_i = '0' else '0' ;    -- 64krx 7f   -- future

-- INTERUPT
  int_vect_ce_n_o <= '0' when m1_n_i='0' and iorq_n_i='0' else '1'; 


-- RAM mode  
  ram64kbi : process (clk_i, ram64kbi_CS_s, reset_n_i)
  begin
    if clk_i'event and clk_i = '1' then
      if reset_n_i = '0' then 
        mode64kbi_s <= ramMode_i(5);
      elsif ram64kbi_CS_s = '1' then
        mode64kbi_s <= d_i(0);
      end if;
    end if;
  end process;
  
  ram64krx : process (clk_i, ram64krx_CS_s, reset_n_i)  -- future
  begin
    if clk_i'event and clk_i = '1' then
      if reset_n_i = '0' then 
        mode64krx_s <= (others =>'1');
      elsif ram64krx_CS_s = '1' then
        mode64krx_s <= d_i;
      end if;
    end if;
  end process; 

-- Cassete   
  casOn : process (clk_i, cas_we_s, reset_n_i)
  begin
    if clk_i'event and clk_i = '1' then
      if reset_n_i = '0' then 
        casOn_o <= '0';
      elsif cas_we_s = '1' then
        casOn_o <= d_i(1);
      end if;
    end if;
  end process;
  
end rtl;
