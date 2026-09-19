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

module SordM5 #(
   parameter DEBUG = 0                   // 1 = debugger Z80 (doc/z80-debugger.md)
)(
   input                    clk_sys,
   input                    reset,
   input   [10:0]           ps2_key,
   input   sordm5_pkg::ioctl_t ioctl,     // plnění ROM souborem z menu
   input                    TMS_border,
   input                    TMS_PAL,
   output                   TMS_interrupt_n,
   output  [7:0]            video_R,
   output  [7:0]            video_G,
   output  [7:0]            video_B,
   output                   video_HS_n,
   output                   video_VS_n,
   output                   video_hblank,
   output                   video_vblank,
   output                   video_blank_n,
   output                   video_ce_pix,
   output  signed [15:0]    audio,

   // debugger (jen DEBUG = 1), viz rtl/CPU/tv80_dbg.sv
   input                    dbg_stop,
   input                    dbg_step,
   input                    dbg_dirset,
   input   [211:0]          dbg_dir,
   output                   dbg_stopped,
   output  [211:0]          dbg_reg
);

logic ce_3m58_p, ce_3m58_n, ce_10m7_n, ce_10m7_p;
logic freeze;                            // debugger zastavil celý počítač
clock clock_i(
	.clk_sys(clk_sys),
	.reset(reset),
	.freeze(freeze),
	.ce_3m58_p(ce_3m58_p),
   	.ce_3m58_n(ce_3m58_n), 
    .ce_10m7_n(ce_10m7_n),
    .ce_10m7_p(ce_10m7_p)
);

logic [15:0] A;
logic [7:0] DO, DI;
logic MREQ_n, RD_n, WR_n, IORQ_n, M1_n, RFSH_n;
logic CTC_int_n;
logic [3:0] CTC_zc_to;
tv80_dbg #(.Mode(0), .R800_MULU(0), .IOWait(1), .DEBUG(DEBUG)) Z80
(
   .RESET_n(!reset),
   .R800_mode('0),
   .CLK_n(clk_sys),
   .CE_n(ce_3m58_n),
   .CE_p(ce_3m58_p),
   .WAIT_n(sgc_ready && EXT_WAIT_n),
   .INT_n(CTC_int_n),
   .NMI_n('1),
   .BUSRQ_n('1),
   .M1_n(M1_n),
   .MREQ_n(MREQ_n),
   .IORQ_n(IORQ_n),
   .RD_n(RD_n),
   .WR_n(WR_n),
   .RFSH_n(RFSH_n),
   .HALT_n(),
   .BUSAK_n(),
   .A(A),
   .DI(DI),
   .DO(DO),
   .freeze(freeze),
   .dbg_stop(dbg_stop),
   .dbg_step(dbg_step),
   .dbg_dirset(dbg_dirset),
   .dbg_dir(dbg_dir),
   .dbg_stopped(dbg_stopped),
   .dbg_reg(dbg_reg)
);

logic [7:0] DATA_CTC;

assign DI = DATA_CTC & DATA_ROM & DATA_RAM & DATA_KB & DATA_TMS & DATA_EXT;

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
   .clk_trg   ({TMS_interrupt_n, 2'b00, EXT_INT_n}),
   .zc_to     (CTC_zc_to)
);

logic CE_CTC_n, CE_SGC_n, CE_ROM0_n, CE_ROM1_n, CE_ROM2_n, CE_RAM0_n, CE_RAM1_n, MRD_n, MWR_n, CE_KB_n, CE_VDP_RD_n, CE_VDP_WR_n;
logic IORD_n, IOWR_n, CE_EXM_n, CE_EXIOA_n, CE_EXIOB_n;
ga015 ga015_i
(
   .A(A),
   .D(DO),
   .RST_n(!reset),
   .MRQ_n(MREQ_n),
   .IORQ_n(IORQ_n),
   .RD_n(RD_n),
   .WR_n(WR_n),
   .MRD_n(MRD_n),
   .MWR_n(MWR_n),
   .ROM0_n(CE_ROM0_n),
   .ROM1_n(CE_ROM1_n),
   .ROM2_n(CE_ROM2_n),
   .EXM_n(CE_EXM_n),
   .EXIOA_n(CE_EXIOA_n),
   .EXIOB_n(CE_EXIOB_n),
   .IORD_n(IORD_n),
   .IOWR_n(IOWR_n),
   .RAM0_n(CE_RAM0_n),
   .RAM1_n(CE_RAM1_n),
   .CSR_n(CE_VDP_RD_n),
   .CSW_n(CE_VDP_WR_n),
   .KB_n(CE_KB_n),
   .CTC_n(CE_CTC_n),
   .SGC_n(CE_SGC_n)
);

// Zvukovy cip SN76489 (jt89) — port 0x20, jen zapis, takt 3.58 MHz jako CPU.
// jt89 zapisuje na nabezne hrane cs_n=0 && wr_n=0, cist z nej nejde.
logic sgc_ready;
logic signed [10:0] audio_sgc;
jt89 sgc_i
(
   .rst(reset),
   .clk(clk_sys),
   .clk_en(ce_3m58_p),
   .wr_n(WR_n),
   .cs_n(CE_SGC_n),
   .din(DO),
   .sound(audio_sgc),
   .ready(sgc_ready)
);

// Rozšiřující sběrnice — cartridge a periferie volitelné z menu.
// EXINT_n -> CTC CLK/TRG0, EXCLK <- CTC ZC/TO2 (pin 9). ROMDS_n zatím nepoužito.
logic [7:0] DATA_EXT;
logic EXT_WAIT_n, EXT_ROMDS_n, EXT_INT_n;
logic signed [15:0] audio_ext;
ext_bus ext_i
(
   .clk_sys(clk_sys),
   .ce_cpu_p(ce_3m58_p),
   .ce_cpu_n(ce_3m58_n),
   .ioctl(ioctl),
   .RST_n(!reset),
   .A(A),
   .D_o(DO),
   .MRQ_n(MREQ_n),
   .RFSH_n(RFSH_n),
   .MRD_n(MRD_n),
   .MWR_n(MWR_n),
   .IORD_n(IORD_n),
   .IOWR_n(IOWR_n),
   .ROM0_n(CE_ROM0_n),
   .ROM1_n(CE_ROM1_n),
   .ROM2_n(CE_ROM2_n),
   .EXM_n(CE_EXM_n),
   .EXIOA_n(CE_EXIOA_n),
   .EXIOB_n(CE_EXIOB_n),
   .D_i(DATA_EXT),
   .WAIT_n(EXT_WAIT_n),
   .ROMDS_n(EXT_ROMDS_n),
   .EXINT_n(EXT_INT_n),
   .EXCLK(CTC_zc_to[2]),
   .audio(audio_ext)
);

// Směšování zvuku: jt89 (11 b) roztažený na 16 b + sběrnice, se saturací.
logic signed [16:0] audio_sum;
assign audio_sum = $signed({audio_sgc[10], audio_sgc, 5'b0}) + $signed({audio_ext[15], audio_ext});
assign audio = (audio_sum >  17'sd32767) ? 16'sh7FFF :
               (audio_sum < -17'sd32768) ? 16'sh8000 : audio_sum[15:0];

logic vram_we;
logic [7:0] vram_di, vram_do, DATA_TMS;
logic [13:0] vram_A;

logic ce_pix;
vdp18_core #(.compat_rgb_g(0)) tms_i
(
    .clk_i(clk_sys),
    .clk_en_10m7_i(ce_10m7_p),
    .reset_n_i(!reset),
    .csr_n_i(CE_VDP_RD_n),
    .csw_n_i(CE_VDP_WR_n),
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
    .hsync_n_o(video_HS_n),
    .vsync_n_o(video_VS_n),
    .hblank_o(video_hblank),
    .vblank_o(video_vblank),
    .blank_n_o(video_blank_n),
    .is_pal_i(TMS_PAL),
    .ce_pix(video_ce_pix)
);

logic [7:0] DATA_KB;
logic KEY_RST;
keyboard keyboard_i
(
   .clk_i(clk_sys),
   .ps2_code_i(ps2_key),
   .addr_i(A[2:0]),
   .kb_ce_i(!CE_KB_n),
   .kb_data_o(DATA_KB),
   .kb_rst_o(KEY_RST)
);


/*verilator tracing_off*/
// Internal RAM
logic [7:0] DATA_RAM;
spram #(.addr_width(12),.mem_name("RAM")) ram
(
   .clock(clk_sys),
   .address(A[11:0]),
   .wren(!MWR_n),
   .data(DO),
   .q(DATA_RAM),
   .oe(!MRD_n),
	.cs(!(CE_RAM0_n && CE_RAM1_n))
);

// Internal VRAM
spram #(.addr_width(14),.mem_name("VRAM")) vram
(
   .clock(clk_sys),
   .address(vram_A),
   .wren(vram_we),
   .data(vram_do),
   .q(vram_di),
	.cs('1),
   .oe('1)
);

// internal ROM
logic [7:0] DATA_ROM;
// Monitor ROM; ioctl index 0 = boot ROM, kterou MiSTer nahrává sám.
rom_ioctl #(.addr_width(13),.mem_name("ROM"),.IOCTL_INDEX(0)) rom
(
   .clock(clk_sys),
   .ioctl(ioctl),
   .address(A[12:0]),
   .q(DATA_ROM),
   .cs(!CE_ROM0_n),
   .oe(!MRD_n)
);

endmodule
