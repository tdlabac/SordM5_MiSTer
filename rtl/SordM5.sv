//============================================================================
//  Computer: Sord M5
//
//  Copyright (C) 2018 Sorgelig
//  Copyright (C) 2021 molekula
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module SordM5
(
   input                    clk_sys
);

logic ce_3m58_p, ce_3m58_n;
clock clock(
	.clk_sys(clk_sys),
	.reset('0),
	.ce_3m58_p(ce_3m58_p),
   	.ce_3m58_n(ce_3m58_n)
);


TV80a #(.Mode(0), .R800_MULU(0), .IOWait(1)) Z80
(
   .RESET_n('1),
   .R800_mode('0),
   .CLK_n(clk_sys),
   .CE_n(ce_3m58_n),
   .CE_p(ce_3m58_p),
   .WAIT_n('1),
   .INT_n('1),
   .NMI_n('1),
   .BUSRQ_n('1),
   .M1_n(),
   .MREQ_n(),
   .IORQ_n(),
   .RD_n(),
   .WR_n(),
   .RFSH_n(),
   .HALT_n(),
   .BUSAK_n(),
   .A(),
   .DI('0),
   .DO()
);


endmodule
