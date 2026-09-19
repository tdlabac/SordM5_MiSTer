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
//
//  Jména signálů:
//    VELKÝMI  sběrnice Z80 a systémová sběrnice M5 tak, jak jsou ve schématu:
//             A, DI, DO, M1_n, MREQ_n, IORQ_n, RD_n, WR_n, RFSH_n,
//             MRD_n, MWR_n, IORD_n, IOWR_n a výběry vyvedené na konektor
//             (ROM0_n, ROM1_n, ROM2_n, EXM_n, EXIOA_n, EXIOB_n)
//    malými   všechno ostatní; vnitřní výběry obvodů cs_*_n (ce_* jsou
//             clock enable), výstupy periferií na DI data_*
//    instance jméno_i
//
//============================================================================

module sordm5_core #(
   parameter DEBUG = 0                   // 1 = debugger Z80 (doc/z80-debugger.md)
)(
   input  wire                 clk_sys,
   input  wire                 reset,
   input  wire  [10:0]         ps2_key,
   input  sordm5_pkg::ioctl_t  ioctl,     // plnění ROM souborem z menu
   input  wire                 vdp_border,
   input  wire                 vdp_pal,
   output logic [7:0]          video_r,
   output logic [7:0]          video_g,
   output logic [7:0]          video_b,
   output logic                video_hs_n,
   output logic                video_vs_n,
   output logic                video_hblank,
   output logic                video_vblank,
   output logic                video_ce_pix,
   output logic signed [15:0]  audio,

   // kazetový magnetofon (externí zařízení, v emu): port 50h
   output logic                ce_cpu,    // takt CPU pro zařízení mimo jádro (stojí při zmrazení)
   input  wire                 cas_in,    // signál z kazety -> port 50h čtení, bit 0
   output logic                cas_motor, // port 50h zápis, bit 1 (motor / remote)

   // debugger (jen DEBUG = 1), viz rtl/CPU/tv80_dbg.sv
   input   tv80_dbg_pkg::dbg_in_t  dbg_i,
   output  tv80_dbg_pkg::dbg_out_t dbg_o,

   // čas počítače: takty CPU od resetu (rtl/tstamp.sv), značka pro ladění
   output logic [47:0]         tstamp
);

// `default_nettype none` až za hlavičkou: vstupní port bez druhu (i s datovým
// typem, např. struct) je podle LRM net výchozího typu a pod `none` by byl
// chybou. Tělo modulu je chráněné (překlep v zapojení nevyrobí implicitní net).
`default_nettype none

logic ce_3m58_p, ce_3m58_n, ce_10m7_p;
logic freeze;                            // debugger zastavil celý počítač
clock clock_i(
   .clk_sys(clk_sys),
   .reset(reset),
   .freeze(freeze),
   .ce_3m58_p(ce_3m58_p),
   .ce_3m58_n(ce_3m58_n),
   .ce_10m7_p(ce_10m7_p)
);
assign ce_cpu = ce_3m58_p;

// Čas počítače pro ladění (takty CPU od resetu, při zmrazení stojí).
tstamp tstamp_i(
   .clk(clk_sys),
   .reset(reset),
   .ce(ce_3m58_p),
   .count(tstamp)
);

// ---------------------------------------------------------------------------
// Sběrnice Z80 a systémová sběrnice M5
logic [15:0] A;
logic [7:0]  DO, DI;
logic        MREQ_n, RD_n, WR_n, IORQ_n, M1_n, RFSH_n;
logic        MRD_n, MWR_n, IORD_n, IOWR_n;
logic        ROM0_n, ROM1_n, ROM2_n, EXM_n, EXIOA_n, EXIOB_n;

// vnitřní výběry obvodů (GA015)
logic cs_ctc_n, cs_sgc_n, cs_ram0_n, cs_ram1_n, cs_kb_n, cs_vdp_rd_n, cs_vdp_wr_n;
logic cs_sts_n, cs_com_n;                // port 50h čtení / zápis

// Data periferií na DI. Každá mimo svůj výběr vrací FFh, sloučí se přes AND.
logic [7:0] data_ctc, data_rom, data_ram, data_kb, data_vdp, data_ext, data_sts;
assign DI = data_ctc & data_rom & data_ram & data_kb & data_vdp & data_ext & data_sts;

// ostatní spoje mezi bloky
logic        ctc_int_n;                  // CTC -> INT Z80
logic [3:0]  ctc_zc_to;                  // CTC ZC/TO, ZC/TO2 jde na sběrnici jako EXCLK
logic        vdp_int_n;                  // přerušení z VDP (aktivní v 0) -> CTC CK3
logic        sgc_ready;                  // SN76489 READY -> WAIT Z80
logic        ext_wait_n, ext_romds_n, ext_int_n;

// ---------------------------------------------------------------------------
tv80_dbg #(.Mode(0), .R800_MULU(0), .IOWait(1), .DEBUG(DEBUG)) z80_i
(
   .RESET_n(!reset),
   .R800_mode('0),
   .CLK_n(clk_sys),
   .CE_n(ce_3m58_n),
   .CE_p(ce_3m58_p),
   .WAIT_n(sgc_ready && ext_wait_n),
   .INT_n(ctc_int_n),
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
   .dbg_i(dbg_i),
   .dbg_o(dbg_o)
);

// Z80 CTC — porty 0x00-0x0F, kanál vybírá A[1:0] (0x04-0x0F se zrcadlí).
//
// Zapojení triggerů podle monitor ROM (tabulka na 0x01D7, vektory z 0x0165):
//   CK0  counter, sestupná hrana, TC=1, int  -> ISR 0x186C = EI;RETI, nevyužito
//   CK1  timer /256, TC=14, int              -> ~1 kHz tik, trigger nepotřebuje
//   CK2  counter, náběžná hrana, TC=23, bez int
//   CK3  counter, sestupná hrana, TC=1, int  -> ISR 0x01DF = IN A,(11), tedy VDP
// VDP dává int_n_o aktivní v nule, proto kanál 3 na sestupnou hranu.
// CK0 je EXINT ze sběrnice, CK2 zatím nezapojený (0).
ctc ctc_i
(
   .clk       (clk_sys),
   .ce_3m58_p (ce_3m58_p),
   .res_n     (!reset),
   .en_n      (cs_ctc_n),
   .dIn       (DO),
   .dInCpu    (DI),
   .dOut      (data_ctc),
   .cs        (A[1:0]),
   .m1_n      (M1_n),
   .iorq_n    (IORQ_n),
   .rd_n      (RD_n),
   .int_n     (ctc_int_n),
   .iei       (1'b1),
   .ieo       (),
   .clk_trg   ({vdp_int_n, 2'b00, ext_int_n}),
   .zc_to     (ctc_zc_to)
);

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
   .ROM0_n(ROM0_n),
   .ROM1_n(ROM1_n),
   .ROM2_n(ROM2_n),
   .EXM_n(EXM_n),
   .EXIOA_n(EXIOA_n),
   .EXIOB_n(EXIOB_n),
   .IORD_n(IORD_n),
   .IOWR_n(IOWR_n),
   .RAM0_n(cs_ram0_n),
   .RAM1_n(cs_ram1_n),
   .CSR_n(cs_vdp_rd_n),
   .CSW_n(cs_vdp_wr_n),
   .KB_n(cs_kb_n),
   .CTC_n(cs_ctc_n),
   .SGC_n(cs_sgc_n),
   .STS_n(cs_sts_n),
   .PCOM_n(cs_com_n),
   .PDT_n(),
   .PSTB_n()
);

// Zvukovy cip SN76489 (jt89) — port 0x20, jen zapis, takt 3.58 MHz jako CPU.
// jt89 zapisuje na nabezne hrane cs_n=0 && wr_n=0, cist z nej nejde.
logic signed [10:0] audio_sgc;
jt89 sgc_i
(
   .rst(reset),
   .clk(clk_sys),
   .clk_en(ce_3m58_p),
   .wr_n(WR_n),
   .cs_n(cs_sgc_n),
   .din(DO),
   .sound(audio_sgc),
   .ready(sgc_ready)
);

// Rozšiřující sběrnice — cartridge a periferie volitelné z menu.
// EXINT_n -> CTC CLK/TRG0, EXCLK <- CTC ZC/TO2 (pin 9). ROMDS_n zatím nepoužito.
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
   .ROM0_n(ROM0_n),
   .ROM1_n(ROM1_n),
   .ROM2_n(ROM2_n),
   .EXM_n(EXM_n),
   .EXIOA_n(EXIOA_n),
   .EXIOB_n(EXIOB_n),
   .D_i(data_ext),
   .WAIT_n(ext_wait_n),
   .ROMDS_n(ext_romds_n),
   .EXINT_n(ext_int_n),
   .EXCLK(ctc_zc_to[2]),
   .audio(audio_ext)
);

// Směšování zvuku: jt89 (11 b) roztažený na 16 b + sběrnice, se saturací.
logic signed [16:0] audio_sum;
assign audio_sum = $signed({audio_sgc[10], audio_sgc, 5'b0}) + $signed({audio_ext[15], audio_ext});
assign audio = (audio_sum >  17'sd32767) ? 16'sh7FFF :
               (audio_sum < -17'sd32768) ? 16'sh8000 : audio_sum[15:0];

// VDP a jeho VRAM. vram_do/vram_di jsou pojmenované z pohledu VDP:
// vram_do = data z VDP do VRAM, vram_di = data z VRAM do VDP.
logic        vram_we;
logic [7:0]  vram_di, vram_do;
logic [13:0] vram_a;

vdp18_core #(.compat_rgb_g(0)) vdp_i
(
    .clk_i(clk_sys),
    .clk_en_10m7_i(ce_10m7_p),
    .reset_n_i(!reset),
    .csr_n_i(cs_vdp_rd_n),
    .csw_n_i(cs_vdp_wr_n),
    .mode_i(A[0]),
    .cd_i(DO),
    .cd_o(data_vdp),
    .int_n_o(vdp_int_n),
    .vram_we_o(vram_we),
    .vram_a_o(vram_a),
    .vram_d_o(vram_do),
    .vram_d_i(vram_di),
    .border_i(vdp_border),
    .rgb_r_o(video_r),
    .rgb_g_o(video_g),
    .rgb_b_o(video_b),
    .hsync_n_o(video_hs_n),
    .vsync_n_o(video_vs_n),
    .hblank_o(video_hblank),
    .vblank_o(video_vblank),
    .blank_n_o(),
    .is_pal_i(vdp_pal),
    .ce_pix(video_ce_pix)
);

logic key_rst;                           // klávesa RESET (PC Esc), port 50h bit 7
keyboard keyboard_i
(
   .clk_i(clk_sys),
   .ps2_code_i(ps2_key),
   .addr_i(A[2:0]),
   .kb_ce_i(!cs_kb_n),
   .kb_data_o(data_kb),
   .kb_rst_o(key_rst)
);

// Port 50h (jako původní jádro, addr_dec.vhd a bus_mux.vhd):
//   čtení  bit 7 klávesa RESET, bit 0 signál z kazety, ostatní 0
//   zápis  bit 1 motor kazety (drží se do dalšího zápisu nebo resetu)
assign data_sts = !cs_sts_n ? {key_rst, 6'b000000, cas_in} : 8'hFF;

always_ff @(posedge clk_sys) begin
   if (reset)
      cas_motor <= 1'b0;
   else if (!cs_com_n)
      cas_motor <= DO[1];
end


/*verilator tracing_off*/
// Internal RAM
spram #(.addr_width(12),.mem_name("RAM")) ram_i
(
   .clock(clk_sys),
   .address(A[11:0]),
   .wren(!MWR_n),
   .data(DO),
   .q(data_ram),
   .oe(!MRD_n),
   .cs(!(cs_ram0_n && cs_ram1_n))
);

// Internal VRAM (data a q z pohledu paměti: data = vram_do z VDP, q = vram_di do VDP)
spram #(.addr_width(14),.mem_name("VRAM")) vram_i
(
   .clock(clk_sys),
   .address(vram_a),
   .wren(vram_we),
   .data(vram_do),
   .q(vram_di),
   .cs('1),
   .oe('1)
);

// Monitor ROM; ioctl index 0 = boot ROM, kterou MiSTer nahrává sám.
rom_ioctl #(.addr_width(13),.mem_name("ROM"),.IOCTL_INDEX(0)) rom_i
(
   .clock(clk_sys),
   .ioctl(ioctl),
   .address(A[12:0]),
   .q(data_rom),
   .cs(!ROM0_n),
   .oe(!MRD_n)
);

endmodule

`default_nettype wire
