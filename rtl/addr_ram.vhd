--//============================================================================
--//  Sord M5
--//  Memory address decoder
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

entity ram_dec is
port (
   a_i               : in  std_logic_vector(15 downto 0);
   mreq_n_i          : in  std_logic;
   rfsh_n_i          : in  std_logic;
   wr_n_i            : in  std_logic;
   em64_ram_en_i     : in  std_logic;
   brno_cas_en_i     : in  std_logic;
   brno_ram_en_i     : in  std_logic;
   brno_rom2_en_i    : in  std_logic;
   ramMode_i         : in  std_logic_vector(8 downto 0);
   kbf_mode_i        : in  std_logic_vector(2 downto 0);
   krx_mode_i        : in  std_logic_vector(7 downto 0);
   rom_cs_o          : out std_logic;
   ram_cs_o          : out std_logic;
   ram_wp_en_o       : out std_logic;
   ramD_cs_o         : out std_logic;
   rom_mmu_o         : out std_logic_vector(4 downto 0)
  );

end ram_dec;


architecture rtl of ram_dec is
   signal mem_s        : boolean;
   signal sram_cs_s    : boolean;
   signal rom0_ds_s    : boolean;
   signal romds_ds_s   : boolean;
   signal moditor_ds_s : boolean;
   signal rom_cs_s     : boolean;
   signal ram_cs_s     : boolean;
   signal mode_none_s  : boolean;
   signal mode_em5_s   : boolean;
   signal mode_em64_s  : boolean;
   signal mode_64kbf_s : boolean;
   signal mode_64krx_s : boolean;
   signal mode_brno_s  : boolean;
   signal cart_I_s     : boolean;
   signal cart_G_s     : boolean;
   signal cart_F_s     : boolean;
   signal cart_NONE_s  : boolean;
   signal cart_en_s    : boolean;
   signal rom_mmu_s    : std_logic_vector(4 downto 0);
begin

   -----------------
   -- Mode select --
   -----------------
   mode_none_s    <= ramMode_i(2 downto 0) = "000";
   mode_em5_s     <= ramMode_i(2 downto 0) = "001";
   mode_em64_s    <= ramMode_i(2 downto 0) = "010";
   mode_64kbf_s   <= ramMode_i(2 downto 0) = "011";
   mode_64krx_s   <= ramMode_i(2 downto 0) = "100";
   mode_brno_s    <= ramMode_i(2 downto 0) = "101";
   cart_en_s      <= mode_none_s or mode_em5_s or mode_em64_s;       -- Enable cart specific memory extensions
   
   -----------------
   -- Cart select --
   -----------------
   cart_NONE_s    <= ramMode_i(4 downto 3) = "00" and cart_en_s;
   cart_I_s       <= ramMode_i(4 downto 3) = "01" and cart_en_s;
   cart_G_s       <= ramMode_i(4 downto 3) = "10" and cart_en_s;
   cart_F_s       <= ramMode_i(4 downto 3) = "11" and cart_en_s;
   
   -----------------
   -- Memory help --
   -----------------
   mem_s          <= mreq_n_i = '0' and rfsh_n_i = '1';
   sram_cs_s      <= a_i(15 downto 12) = "0111";                                                      -- 7000 - 7fff    SRAM        
   
   ------------------------------
   -- MAP ROM to Address space --
   ------------------------------
   rom_mmu_s      <= 
                     -- None, EM-5, EM64, Brno mod --
                     "0000"&a_i(12) when a_i(15 downto 13) = "000"                                          else -- 0000 - 1fff    MONITOR      
                     "0010"&a_i(12) when a_i(15 downto 13) = "001" and cart_I_s                             else -- 2000 - 3fff    BASIC I
                     "0001"&a_i(12) when a_i(15 downto 13) = "001" and mode_brno_s  and brno_rom2_en_i='0'  else -- 2000 - 3fff    WINDOWS BRNO
                     "0010"&a_i(12) when a_i(15 downto 13) = "001" and mode_brno_s  and brno_rom2_en_i='1'  else -- 2000 - 3fff    BASIC I
                     "0110"&a_i(12) when a_i(15 downto 13) = "001" and cart_G_s                             else -- 2000 - 3fff    BASIC G Part 1
                     "0111"&a_i(12) when a_i(15 downto 13) = "010" and cart_G_s                             else -- 4000 - 5fff    BASIC G Part 2
                     "0101"&a_i(12) when a_i(15 downto 13) = "001" and cart_F_s                             else -- 2000 - 7fff    BASIC F Part 1
                     "0100"&a_i(12) when a_i(15 downto 13) = "010" and cart_F_s                             else -- 4000 - 5fff    BASIC F Part 2
                     "00111"        when a_i(15 downto 13) = "011" and cart_F_s                             else -- 6000 - 6fff    BASIC F Part 3
                     "1100"&a_i(12) when a_i(15 downto 13) = "001" and cart_NONE_s                          else -- 2000 - 7fff    Loaded ROM
                     "1101"&a_i(12) when a_i(15 downto 13) = "010" and cart_NONE_s                          else -- 4000 - 5fff    Loaded ROM
                     "1110"&a_i(12) when a_i(15 downto 13) = "011" and cart_NONE_s                          else -- 6000 - 6fff    Loaded ROM                     
                     -- KBF mode --
                     "0101"&a_i(12) when a_i(15 downto 13) = "001" and mode_64kbf_s                         else -- 2000 - 7fff    BASIC F Part 1
                     "0100"&a_i(12) when a_i(15 downto 13) = "010" and mode_64kbf_s                         else -- 4000 - 5fff    BASIC F Part 2
                     "00111"        when a_i(15 downto 13) = "011" and mode_64kbf_s                         else -- 6000 - 6fff    BASIC F Part 3
                     -- KRX mode --
                     "0000"&a_i(12) when a_i(15 downto 13) = "000" and mode_64krx_s and krx_mode_i(0) = '1' else -- 0000 - 1fff    MONITOR
                     "0011"&a_i(12) when a_i(15 downto 13) = "001" and mode_64krx_s and krx_mode_i(1) = '1' else -- 2000 - 3fff    WINDOWS + BASIC F Part 3
                     "0010"&a_i(12) when a_i(15 downto 13) = "010" and mode_64krx_s and krx_mode_i(2) = '1' else -- 4000 - 5fff    BASIC I
                     "0100"&a_i(12) when a_i(15 downto 13) = "100" and mode_64krx_s and krx_mode_i(4) = '1' else -- 8000 - 9fff    BASIC F Part 2
                     "0101"&a_i(12) when a_i(15 downto 13) = "101" and mode_64krx_s and krx_mode_i(4) = '1' else -- a000 - bfff    BASIC F Part 1
                     "0110"&a_i(12) when a_i(15 downto 13) = "110" and mode_64krx_s and krx_mode_i(5) = '1' else -- c000 - dfff    BASIC G Part 1
                     "0111"&a_i(12) when a_i(15 downto 13) = "111" and mode_64krx_s and krx_mode_i(5) = '1' else -- e000 - ffff    BASIC G Part 2
                     "1000"&a_i(12) when a_i(15 downto 13) = "100" and mode_64krx_s and krx_mode_i(6) = '1' else -- 8000 - 9fff    MSX Part 1
                     "1001"&a_i(12) when a_i(15 downto 13) = "101" and mode_64krx_s and krx_mode_i(6) = '1' else -- a000 - bfff    MSX Part 2
                     "1010"&a_i(12) when a_i(15 downto 13) = "110" and mode_64krx_s and krx_mode_i(7) = '1' else -- c000 - dfff    MSX Part 3
                     "1011"&a_i(12) when a_i(15 downto 13) = "111" and mode_64krx_s and krx_mode_i(7) = '1' else -- e000 - ffff    MSX Part 4
                     "11111";                                                                                                      -- no ROM
   -------------------
   -- fianly assign --
   -------------------   
   moditor_ds_s   <= true when mode_em64_s
                           and em64_ram_en_i = '1' 
                           and ramMode_i(6)  = '0'                                                          else
                     true when mode_64kbf_s 
                           and wr_n_i='1' 
                           and (   kbf_mode_i ="001" 
                                or kbf_mode_i ="011" 
                                or kbf_mode_i ="100" 
                                or kbf_mode_i ="111")                                                       else         
                     false;
   
   
   rom_cs_s       <= false when sram_cs_s                                                                   else -- 7000 - 7fff    SRAM
                     false when rom_mmu_s = "11111"                                                         else -- no ROM
                     true  when a_i(15 downto 13) = "000" and moditor_ds_s                                  else -- Disable monitor enabled ?
                     false when mode_em64_s and em64_ram_en_i = '1'                                         else -- EM64 Disable ROM
                     false when mode_brno_s and brno_ram_en_i = '1'                                         else -- Brno Mod Enable RAM
                     false when mode_64kbf_s 
                            and wr_n_i='0' 
                            and not (kbf_mode_i="000" or kbf_mode_i="101")                                  else
                     
                     true;
                     
                     
   ram_cs_s       <= false when sram_cs_s and mode_brno_s and brno_ram_en_i = '1'                           else  -- SRAM disable if RAM disk enable
                     true  when sram_cs_s                                                                   else  -- SRAM allways
                     false when rom_cs_s                                                                    else  -- disable if ROM request
                     false when mode_none_s                                                                 else  -- No memory extension
                     false when mode_brno_s                                                                 else  -- Use RAM disk
                     true  when mode_em5_s   and a_i(15) = '1'                                              else  -- EM5 only high ram
                     true  when mode_em64_s  and (a_i(15) = '1' or ramMode_i(5) = '0')                      else  -- EM64 low ram if enabled and high ram allways
                     true  when mode_64krx_s                                                                else  -- 64KRX if ROM not request
                     false when mode_64kbf_s and kbf_mode_i ="111"                                          else  -- KBF mod 7 RAM RW DISABLE
                     true  when mode_64kbf_s and a_i(15)='1'                                                else  -- KBF read if not maped ROM
                     false;   
                     
   rom_mmu_o      <= rom_mmu_s;  
   rom_cs_o       <= '1' when mem_s and rom_cs_s  else '0';   
   ram_cs_o       <= '1' when mem_s and ram_cs_s else '0';
   ram_wp_en_o    <= '0' when sram_cs_s                                                                     else  -- SRAM not WP
                     '1' when mode_em64_s and ramMode_i(7) = '1' and a_i(15) = '0'                          else  -- EM64 write protect low memory
                     '1' when mode_64kbf_s and kbf_mode_i = "011" and a_i(15) = '0'                         else  -- KBF LOW RAM WP
                     '1' when mode_64kbf_s and kbf_mode_i = "100" and a_i(15 downto 13) = "000"             else  -- KBF half LOW RAM WP
                     '0';  
   ramD_cs_o      <= '1' when mem_s                                                                               -- RAM 1 Bank if not request ROM/SRAM and CAS enable
                          and not rom_cs_s 
                          and not ram_cs_s                                      
                          and mode_brno_s                                                                         -- Brno mod
                          and brno_cas_en_i = '1'                                                           else  -- RAM disk detached
                     '0';    
end rtl;   