//
// ddram.v
//
// DE10-nano DDR3 memory interface
//
// Copyright (c) 2017 Sorgelig
//
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ------------------------------------------
//

// 8-bit version
//
// Úprava pro Sord M5 (2026-09-19): nic se neztrácí při DDRAM_BUSY.
// 1. Původní verze hlídala náběžnou hranu rd/we jen v taktech s
//    DDRAM_BUSY = 0: pulz během DDRAM_BUSY se ztratil a pokles požadavku
//    během DDRAM_BUSY zůstal nezaznamenaný (old_we = 1), takže další
//    požadavek už nebyl hrana. Teď se hrany rd/we zachytí na každé hraně
//    hodin do čekajícího požadavku (s adresou a daty) a provedou se, až je
//    DDR volná.
// 2. DDRAM_DOUT_READY se hlídal taky jen při DDRAM_BUSY = 0; data čtení,
//    která přišla souběžně s BUSY, se ztratila a ddram visel. Teď se berou
//    vždy.
// ready je v nule, dokud požadavek čeká nebo běží. Rozhraní pro klienta je
// stejné: pulz rd/we, pak čekat na ready (dout platí s ready).
// Ověřeno testem rtl/TAPE/tb (model DDR3 s náhodným DDRAM_BUSY).

module ddram
(
	input         reset,
	input         DDRAM_CLK,

	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	input  [27:0] addr,        // 256MB at the end of 1GB
	output  [7:0] dout,        // data output to cpu
	input   [7:0] din,         // data input from cpu
	input         we,          // cpu requests write
	input         rd,          // cpu requests read
	output        ready        // dout is valid. Ready to accept new read/write.
);

assign DDRAM_BURSTCNT = 1;
assign DDRAM_BE       = (8'd1<<ram_address[2:0]) | {8{ram_read}};
assign DDRAM_ADDR     = {4'b0011, ram_address[27:3]}; // RAM at 0x30000000
assign DDRAM_RD       = ram_read;
assign DDRAM_DIN      = ram_cache;
assign DDRAM_WE       = ram_write;

assign dout = ram_q;
assign ready = ~(pend_rd | pend_we | state | ram_read | ram_write);

reg  [7:0] ram_q;
reg [27:0] ram_address;
reg        ram_read;
reg [63:0] ram_cache;
reg        ram_write;
reg  [7:0] cached;
reg        state;

// čekající požadavky (zachycené hrany rd/we)
reg        old_rd, old_we;
reg        pend_rd, pend_we;
reg [27:0] rd_addr, wr_addr;
reg  [7:0] wr_din;

always @(posedge DDRAM_CLK)
begin
	reg old_reset;

	old_reset <= reset;
	if(old_reset && ~reset) begin
		state   <= 0;
		cached  <= 0;
		pend_rd <= 0;
		pend_we <= 0;
	end

	// Data čtení: DDRAM_DOUT_READY (Avalon readdatavalid) nezávisí na
	// DDRAM_BUSY (waitrequest). Původně se hlídala jen při DDRAM_BUSY = 0
	// a data, která přišla souběžně s BUSY, se ztratila (ddram pak visel).
	if(state && DDRAM_DOUT_READY) begin
		ram_q     <= DDRAM_DOUT[{ram_address[2:0], 3'b000} +:8];
		ram_cache <= DDRAM_DOUT;
		cached    <= 8'hFF;
		state     <= 0;
	end

	if(!DDRAM_BUSY)
	begin
		ram_write <= 0;
		ram_read  <= 0;
		if(state) begin
			// čeká se na data čtení (výše)
		end
		else if(pend_we) begin
			ram_cache[{wr_addr[2:0], 3'b000} +:8] <= wr_din;
			ram_address <= wr_addr;
			ram_write   <= 1;
			pend_we     <= 0;
			cached      <= ((ram_address[27:3] == wr_addr[27:3]) ? cached : 8'h00) | (8'd1<<wr_addr[2:0]);
		end
		else if(pend_rd) begin
			pend_rd <= 0;
			if((ram_address[27:3] == rd_addr[27:3]) && cached[rd_addr[2:0]]) begin
				ram_q <= ram_cache[{rd_addr[2:0], 3'b000} +:8];
			end
			else begin
				ram_address <= rd_addr;
				ram_read    <= 1;
				state       <= 1;
				cached      <= 0;
			end
		end
	end

	// hrany požadavků na každé hraně hodin, i během DDRAM_BUSY
	old_rd <= rd;
	old_we <= we;
	if(~old_we && we) begin
		pend_we <= 1;
		wr_addr <= addr;
		wr_din  <= din;
	end
	if(~old_rd && rd) begin
		pend_rd <= 1;
		rd_addr <= addr;
	end
end

endmodule
