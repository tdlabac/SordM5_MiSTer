-- Copyright (c) 2015, $ME
-- Copyright (c) 2021, molekula
--
-- All rights reserved.
--
-- Redistribution and use in source and synthezised forms, with or without modification, are permitted 
-- provided that the following conditions are met:
--
-- 1. Redistributions of source code must retain the above copyright notice, this list of conditions 
--    and the following disclaimer.
--
-- 2. Redistributions in synthezised form must reproduce the above copyright notice, this list of conditions
--    and the following disclaimer in the documentation and/or other materials provided with the distribution.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED 
-- WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A 
-- PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR 
-- ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED 
-- TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
-- HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING 
-- NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
-- POSSIBILITY OF SUCH DAMAGE.
--
--
-- implementation of a z80 ctc
--
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all; 

entity ctc is
    port (
        clk   : in std_logic;
        clk_sys_i  : in std_logic;
        res_n : in std_logic; -- negative
        en    : in std_logic; -- negative
		  
        dIn   : in std_logic_vector(7 downto 0);
        dInCpu: in std_logic_vector(7 downto 0);
        dOut  : out std_logic_vector(7 downto 0);
        
        cs    : in std_logic_vector(1 downto 0);
        m1_n  : in std_logic; -- negative
        iorq_n : in std_logic; -- negative
        rd_n  : in std_logic; -- negative
        int_n : out std_logic := '1';
               
        clk_trg : in std_logic_vector(3 downto 0);
        zc_to   : out std_logic_vector(3 downto 0)
    );
end ctc;

architecture rtl of ctc is
    type byteArray is array (natural range <>) of std_logic_vector(7 downto 0);   
    signal cEn        : std_logic_vector(3 downto 0);
    signal cDOut      : byteArray(3 downto 0);
    signal cSetTC     : std_logic_vector(3 downto 0);
    signal setTC      : std_logic;
    
    signal irqVect    : std_logic_vector(7 downto 3) := (others => '0');
	 signal intAckChannel : std_logic_vector(1 downto 0):= (others => '0');
    
    type states is (idle, waitIntAccepted, waitReti);
	 signal state         : states := idle;
	 signal cpuACKint     : std_logic;
	 signal internalInt   : std_logic_vector(3 downto 0) := (others => '0');
	 signal lastInt       : std_logic_vector(3 downto 0) := (others => '0');
	 signal int           : std_logic_vector(3 downto 0) := (others => '0');
	 signal count         : std_logic_vector(1 downto 0);
	 signal reti			 : std_logic := '0';

begin
    cpuACKint <= '1' when iorq_n='0' and m1_n='0' else '0';
        
    dOut <= 
        irqVect & intAckChannel & "0" when cpuACKint='1' else -- int acknowledge
        cDOut(0) when cEn(0)='1' else
        cDOut(1) when cEn(1)='1' else
        cDOut(2) when cEn(2)='1' else
        cDOut(3);

    setTC <= 
        cSetTC(0) when cs="00" else
        cSetTC(1) when cs="01" else
        cSetTC(2) when cs="10" else
        cSetTC(3);
	 
    genInt : process 
    variable counterInt : integer;

    begin
      wait until rising_edge(clk);

      int_n <='1';

      if res_n = '0' then
        state <= idle;
        int_n <='1';
        lastInt <= "0000";
        internalInt <= "0000";
      else
        case state is
        when idle =>
         if internalInt /="0000" then -- int request
          state <= waitIntAccepted;
          int_n <='0';
        end if;
        when waitIntAccepted =>
          if cpuACKint = '1' then -- incoming ack		  
            int_n <='1';
            for i in 0 to 3 -- 0 is highest prio            
            loop
              if internalInt(i)='1' then
                internalInt(i) <= '0' ; --reset int
                counterInt := i;				  
                exit;
              end if;
            end loop;
            state <= waitReti;
          else 
            int_n <='0';
          end if;
        when waitReti =>
          if reti = '1' then
            state <= idle;
          end if;
        when others =>
        end case;
		  
		  for i in 0 to 3
        loop
          if lastInt(i) = '0' and int(i) = '1' then	-- new interupt
            internalInt(i) <= '1';
          end if;
        end loop;
        
        lastInt <= int;
      end if;
      intAckChannel	<= std_logic_vector(to_unsigned(counterInt, 2));
    end process;    
    
    cpuInt : process
    begin
        wait until rising_edge(clk);

        if (en='0' and rd_n='1' and iorq_n='0' and m1_n='1' and dIn(0)='0' and setTC='0') then -- set irq vector
            irqVect <= dIn(7 downto 3);
        end if;
    end process;
    
    channels: for i in 0 to 3 generate
        channel : entity work.ctc_channel
        port map (
            clk     => clk,
            res_n   => res_n,
            en      => cEn(i),            
            dIn     => dIn,
            dOut    => cDOut(i),            
            rd_n    => rd_n,            
            int     => int(i),
            setTC   => cSetTC(i),
            ctcClkEn => clk_sys_i,
            clk_trg  => clk_trg(i),
            zc_to    => zc_to(i)
        );
            
        cEn(i) <= '1' when (en='0' and iorq_n='0' and m1_n='1' and to_integer(unsigned(cs))=i) else '0';
    end generate;

findReti : process
	variable retiState : std_logic := '0';
	variable opcode : std_logic_vector(7 downto 0);
	variable last_opcodeRead : std_logic := '0';	
	begin
		wait until rising_edge(clk);
		reti <= '0';
		if m1_n = '0' and iorq_n = '1' and rd_n = '0' then
			opcode := dInCpu;
			last_opcodeRead := '1';
		else 
			if last_opcodeRead = '1' then
				last_opcodeRead := '0';
				if retiState = '0' then
					if opcode = x"ED" then
						retiState := '1';
					end if;
				else 
					if opcode = x"4D" then
						reti <= '1';
					end if;
					retiState := '0';
				end if;
			end if;
		end if;
	end process;
end;