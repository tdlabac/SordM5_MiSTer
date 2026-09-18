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
   input                    clk_sys,
   input                    reset,

   input                    TMS_border,
   input                    TMS_PAL,
   output                   TMS_interrupt_n,
   output  [7:0]            video_R,
   output  [7:0]            video_G,
   output  [7:0]            video_B,
   output                   video_HS,
   output                   video_VS,
   output                   video_hblank,
   output                   video_vblank,
   output                   video_blank,
   output                   video_ce_pix
);

logic ce_3m58_p, ce_3m58_n, ce_10m7_n, ce_10m7_p;
clock clock(
	.clk_sys(clk_sys),
	.reset(reset),
	.ce_3m58_p(ce_3m58_p),
   	.ce_3m58_n(ce_3m58_n), 
    .ce_10m7_n(ce_10m7_n),
    .ce_10m7_p(ce_10m7_p)
);

logic [15:0] A;
logic [7:0] DO, DI;
logic MREQ_n, RD_n, WR_n, IORQ_n, M1_n;
logic CTC_int_n;
TV80a #(.Mode(0), .R800_MULU(0), .IOWait(1)) Z80
(
   .RESET_n(!reset),
   .R800_mode('0),
   .CLK_n(clk_sys),
   .CE_n(ce_3m58_n),
   .CE_p(ce_3m58_p),
   .WAIT_n('1),
   .INT_n(CTC_int_n),
   .NMI_n('1),
   .BUSRQ_n('1),
   .M1_n(M1_n),
   .MREQ_n(MREQ_n),
   .IORQ_n(IORQ_n),
   .RD_n(RD_n),
   .WR_n(WR_n),
   .RFSH_n(),
   .HALT_n(),
   .BUSAK_n(),
   .A(A),
   .DI(DI),
   .DO(DO)
);

logic AREA_ROM, AREA_RAM, AREA_ROM_CART;

assign AREA_ROM      = (A[15:13] == 3'b000  && !MREQ_n) ? 1:0;
assign AREA_ROM_CART = (A[15:13] == 3'b001  && !MREQ_n) ? 1:0;
assign AREA_RAM      = (A[15:12] == 4'b0111 && !MREQ_n) ? 1:0;

//IORQ
logic IORQ_IO, AREA_TMS, AREA_KB, AREA_CAS, AREA_CTC, AREA_PSG;
assign IORQ_IO       =  !IORQ_n && M1_n;

assign AREA_TMS      = (IORQ_IO && A[7:4] == 4'b0001);
assign AREA_KB       = (IORQ_IO && A[7:4] == 4'b0011);
assign AREA_CAS      = (IORQ_IO && A[7:4] == 4'b0101);
assign AREA_PSG      = (IORQ_IO && A[7:0] == 8'b00100000);


logic [7:0] DATA_CTC;

assign DI = DATA_CTC & (
            RD_n          ? 8'hFF    :
            AREA_ROM      ? DATA_ROM :
            AREA_RAM      ? DATA_RAM :
            AREA_ROM_CART ? DATA_ROM_CART :
            AREA_TMS      ? DATA_TMS :
            8'hFF);

// Z80 CTC — porty 0x00-0x0F, kanál vybírá A[1:0] (0x04-0x0F se zrcadlí).
//
// Zapojení triggerů podle monitor ROM (tabulka na 0x01D7, vektory z 0x0165):
//   CK0  counter, sestupná hrana, TC=1, int  -> ISR 0x186C = EI;RETI, nevyužito
//   CK1  timer /256, TC=14, int              -> ~1 kHz tik, trigger nepotřebuje
//   CK2  counter, náběžná hrana, TC=23, bez int
//   CK3  counter, sestupná hrana, TC=1, int  -> ISR 0x01DF = IN A,(11), tedy VDP
// VDP dává int_n_o aktivní v nule, proto kanál 3 na sestupnou hranu.
// Nevyužité triggery na 0 stejně jako v původním VHDL projektu.
ctc ctc_i
(
   .clk       (clk_sys),
   .ce_3m58_p (ce_3m58_p),
   .res_n     (!reset),
   .en_n      (CE_CTC_n),
   .dIn       (DO),
   .dInCpu    (DI),
   .dOut      (DATA_CTC),
   .cs        (A[1:0]),
   .m1_n      (M1_n),
   .iorq_n    (IORQ_n),
   .rd_n      (RD_n),
   .int_n     (CTC_int_n),
   .iei       (1'b1),
   .ieo       (),
   .clk_trg   ({TMS_interrupt_n, 3'b000}),
   .zc_to     ()
);

logic CE_CTC_n;
ga015 ga015_i
(
   .A(A),
   .D(DO),
   .RST_n(!reset),
   .MRQ_n(MREQ_n),
   .IORQ_n(IORQ_n),
   .RD_n(RD_n),
   .WR_n(WR_n),
   .CTC_n(CE_CTC_n)
);

/*verilator tracing_off*/
logic vram_we;
logic [7:0] vram_di, vram_do, DATA_TMS;
logic [13:0] vram_A;

logic ce_pix;
vdp18_core #(.compat_rgb_g(0)) tms_i
(
    .clk_i(clk_sys),
    .clk_en_10m7_i(ce_10m7_p),
    .reset_n_i(!reset),
    .csr_n_i(!(AREA_TMS && !RD_n)),
    .csw_n_i(!(AREA_TMS && !WR_n)),
    .mode_i(A[0]),
    .cd_i(DO),
    .cd_o(DATA_TMS),
    .int_n_o(TMS_interrupt_n),
    .vram_we_o(vram_we),
    .vram_a_o(vram_A),
    .vram_d_o(vram_do),
    .vram_d_i(vram_di),
    .border_i(TMS_border),
    .rgb_r_o(video_R),
    .rgb_g_o(video_G),
    .rgb_b_o(video_B),
    .hsync_n_o(video_HS),
    .vsync_n_o(video_VS),
    .hblank_o(video_hblank),
    .vblank_o(video_vblank),
    .blank_n_o(video_blank),
    .is_pal_i(TMS_PAL),
    .ce_pix(video_ce_pix)
);

// Internal RAM
logic [7:0] DATA_RAM;
spram #(.addr_width(12),.mem_name("RAM")) ram
(
   .clock(clk_sys),
   .address(A[11:0]),
   .wren(AREA_RAM && !WR_n),
   .data(DO),
   .q(DATA_RAM)
);

// Internal VRAM
spram #(.addr_width(14),.mem_name("VRAM")) vram
(
   .clock(clk_sys),
   .address(vram_A),
   .wren(vram_we),
   .data(vram_do),
   .q(vram_di)
);

// internal ROM
logic [7:0] DATA_ROM;
spram #(.addr_width(13),.mem_name("ROM")) rom
(
   .clock(clk_sys),
   .address(A[12:0]),
   .wren('0),
   .data('0),
   .q(DATA_ROM)
);

// cartrige ROM
logic [7:0] DATA_ROM_CART;
spram #(.addr_width(13),.mem_name("ROM_CART")) rom_cart
(
   .clock(clk_sys),
   .address(A[12:0]),
   .wren('0),
   .data('0),
   .q(DATA_ROM_CART)
);
endmodule
