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

module emu
(
	`include "sys/emu_ports.vh"
);

// default_nettype none az za hlavickou: vstupni port bez druhu (i s datovym
// typem, napr. struct) je podle LRM net vychoziho typu, pod `none` by byl
// chybou. Telo modulu je chranene (preklep v zapojeni nevyrobi implicitni net).
`default_nettype none

///////// Default values for ports not used in this core /////////

assign USER_OUT = '1;
assign {UART_RTS, UART_DTR} = 0;          // UART_TXD: debugger Z80 (dbg_link)
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
tv80_dbg_pkg::dbg_out_t dbg_o;       // stav debuggeru Z80 (DEBUG = 0: vse 0)
wire   dbg_stopped = dbg_o.stopped;  // debugger zastavil pocitac
assign HDMI_FREEZE = dbg_stopped;    // debugger stoji: drz posledni snimek
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire signed [15:0] audio;             // zvuk pocitace
wire signed [15:0] audio_out;         // + priposlech kazety (nize)
// Debugger zastavil pocitac: zastaveny obraz (HDMI_FREEZE) i zvuk (ticho).
// Zvukovy cip stoji a drzel by posledni vzorek (stejnosmerna slozka).
assign AUDIO_S = 1;                  // signed
assign AUDIO_L = dbg_stopped ? 16'sd0 : audio_out;
assign AUDIO_R = dbg_stopped ? 16'sd0 : audio_out;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v" 
localparam CONF_STR = {
	"Sord M5;;",
	"-;",
    "F1,binROM,Load to ROM;",
	"F2,CAS,Load Tape,30000000;",
	"O[11],Tape Sound,Off,On;",
	"O[12],Fast Tape,Off,On;",
	"O[13],Tape Input,File,ADC;",
	"-;",
	// Cartridge: vybrany typ dostane enable v rtl/EXT/ext_bus.sv. Jeho podmenu
	// se skryva pres menumask (prefix h<bit>, nize). Zmena typu resetuje
	// pocitac, jako by se modul vytahl a zasunul.
	"O[15:14],Cartridge,None,EM32,EM64,BRNO;",
	"h0O[16],WP monitor,Off,On;",
	"h0O[17],Autostart,Off,On;",
	"h0O[18],Mode,EM64,EM32;",
	"h0O[19],Monitor protect,Off,On;",
	"h1S0,DSK,Floppy A;",
	"h1S1,DSK,Floppy B;",
	"O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "O[8:6],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
    "O[9],Border,No,Yes;",
	"O[10],Video,NTSC,PAL;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"V,v",`BUILD_DATE 
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

// ioctl: plneni pameti souborem z menu. Do jadra jde jako jeden port typu
// sordm5_pkg::ioctl_t; poradi v concatenaci = poradi poli v package.
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;

sordm5_pkg::ioctl_t ioctl;
assign ioctl = {ioctl_download, ioctl_index, ioctl_wr, ioctl_addr, ioctl_dout};

// Cartridge: typ z menu a volby jeho podmenu. Podmenu se v menu skryje, dokud
// neni jeho typ vybrany: menumask bit 0 = EM64, bit 1 = BRNO (prefix h0/h1
// v CONF_STR; h skryva, d jen zesedi). Blokova zarizeni BRNO (S0/S1) zatim
// nikam nevedou, porty sd_* v hps_io jsou nezapojene — doplni se s modulem.
sordm5_pkg::cart_sel_t cart_sel;
assign cart_sel = sordm5_pkg::cart_sel_t'(status[15:14]);
wire [15:0] cart_opt = status[31:16];
wire [15:0] menumask = {14'd0,
                        cart_sel == sordm5_pkg::CART_BRNO,
                        cart_sel == sordm5_pkg::CART_EM64};
wire      [31:0] joy0, joy1;
wire       [5:0] joy[2];
hps_io #(.CONF_STR(CONF_STR), .VDNUM(2)) hps_io_i
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(menumask),
	.ps2_key(ps2_key),
	.joystick_0(joy0),
    .joystick_1(joy1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(1'b0)
);

assign joy[0] = joy0[5:0];
assign joy[1] = joy1[5:0];

// Kazeta (blok KAZETA nize). Nahrani kazety pocitac neresetuje (kazeta se
// vklada do beziciho pocitace).
wire tape_loading;                    // nahrava se soubor CAS
wire ce_cpu;                          // takt CPU z jadra, stoji pri zmrazeni
wire cas_in;                          // signal z kazety -> pocitac
wire cas_motor;                       // motor z pocitace (port 50h bit 1)

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
pll pll_i
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_sys)
);

// Reset jadra je registrovany. TV80 ma asynchronni reset, kombinacni vyraz
// by ho resetoval i glitchem: pri nabehu ioctl_download dorazi prima cesta
// driv nez negace tape_loading (ktera download obsahuje taky), vznikne kratky
// puls a CPU se resetoval pri nahrani kazety, aniz by synchronni logika
// (tstamp, periferie) reset videla. Nalezeno debuggerem: PC=0, SP=0, R=0
// a cas pocitace bezel dal.
//
// Zmena cartridge z menu resetuje pocitac (vymena modulu za behu je pro nej
// totez jako zapnuti). Reset se drzi par taktu, aby ho chytily vsechny bloky.
logic [1:0] cart_sel_d;
logic [7:0] cart_reset = '0;
always_ff @(posedge clk_sys) begin
	cart_sel_d <= cart_sel;
	if (cart_sel_d != cart_sel) cart_reset <= '1;
	else if (cart_reset != 0)   cart_reset <= cart_reset - 8'd1;
end

logic reset = 1'b1;
always_ff @(posedge clk_sys)
	reset <= RESET | status[0] | buttons[1] | (cart_reset != 0) |
	         (ioctl_download & !tape_loading);
logic [7:0] video_r, video_g, video_b;
logic       video_hs_n, video_vs_n, video_hblank, video_vblank, video_ce_pix;

// Debugger Z80 (doc/z80-debugger.md). Ve FPGA jde pres UART jadra na UART
// HPS (/dev/ttyS1, 230400 8N1, protokol doc/z80-debugger-protokol.md),
// v simulaci dbg_link nahrazuje DPI most do sim appky.
//
// Z80DBG_OFF (define) debugger vypne: CPU je hole TV80a, dbg_link ani
// registrovy prostor se nevytvori, UART_TXD stoji v 1. Quartus ho nedefinuje
// (debugger je ve FPGA vzdy), verilator ano, pokud se sordM5.sh nespusti
// se Z80DBG=1 (debugger v simulaci stoji vykon).
`ifdef Z80DBG_OFF
localparam DEBUG = 0;
`else
localparam DEBUG = 1;
`endif
tv80_dbg_pkg::dbg_in_t dbg_i;
wire [47:0] tstamp;                  // cas pocitace (takty CPU od resetu)

generate
if (DEBUG) begin : g_dbg
	wire       dbg_wr;
	wire [7:0] dbg_addr, dbg_wdata, dbg_rdata;

	// clk_sys = 21,477272 MHz (rtl/pll/pll_0002.v) = 6 x 3,579545 MHz
	dbg_link #(.CLK_HZ(21_477_272), .BAUD(230_400)) dbg_link_i
	(
		.clk(clk_sys),
		.reset(RESET),
		.uart_rxd(UART_RXD),
		.uart_txd(UART_TXD),
		.wr(dbg_wr),
		.addr(dbg_addr),
		.wdata(dbg_wdata),
		.rdata(dbg_rdata)
	);

	tv80_dbg_regs dbg_regs_i
	(
		.clk(clk_sys),
		.reset(RESET),                     // breakpointy preziji reset jadra
		.wr(dbg_wr),
		.addr(dbg_addr),
		.wdata(dbg_wdata),
		.rdata(dbg_rdata),
		.dbg_i(dbg_i),
		.dbg_o(dbg_o),
		.tstamp(tstamp)
	);
end else begin : g_nodbg
	assign dbg_i    = '0;
	assign UART_TXD = 1'b1;
end
endgenerate

sordm5_core #(.DEBUG(DEBUG)) sordm5_i
(
	.clk_sys(clk_sys),
	.reset(reset),
	.ps2_key(ps2_key),
	.joy(joy),
	.ioctl(ioctl),
	.vdp_border(status[9]),
	.vdp_pal(status[10]),
	.cart_sel(cart_sel),
	.cart_opt(cart_opt),
	.video_r(video_r),
    .video_g(video_g),
    .video_b(video_b),
    .video_hs_n(video_hs_n),
    .video_vs_n(video_vs_n),
    .video_hblank(video_hblank),
    .video_vblank(video_vblank),
	.video_ce_pix(video_ce_pix),
	.audio(audio),

	.ce_cpu(ce_cpu),
	.cas_in(cas_in),
	.cas_motor(cas_motor),

	.dbg_i(dbg_i),
	.dbg_o(dbg_o),
	.tstamp(tstamp)
);

/////////////////  KAZETA  /////////////////
// Magnetofon neni soucast pocitace, je to externi zarizeni ("side car"):
// do jadra jde jen hotovy signal z kazety (port 50h bit 0), ven motor.
//
// Soubor CAS nahraje MiSTer primo do DDR od 0x30000000 (CONF_STR
// "F2,CAS,Load Tape,30000000"), ioctl nese jen informaci o nahrani a
// velikost souboru (ioctl_addr po dobu ioctl_download). ddram.sv mapuje svou
// adresu 0 na 0x30000000. Jeho mezipamet se po nahrani vyprazdni resetem.
wire [27:0] tape_addr;
wire  [7:0] tape_dout;
wire        tape_rd, tape_ready;
wire        tape_file;                // signal ze souboru CAS

assign DDRAM_CLK = clk_sys;

ddram ddram_i
(
	.reset(tape_loading),
	.DDRAM_CLK(clk_sys),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),
	.addr(tape_addr),
	.dout(tape_dout),
	.din(8'hFF),
	.we(1'b0),
	.rd(tape_rd),
	.ready(tape_ready)
);

cas_player #(.IOCTL_INDEX(6'd2)) cas_player_i
(
	.clk(clk_sys),
	.ce(ce_cpu),
	.ioctl(ioctl),
	.loading(tape_loading),
	.cas_on(cas_motor),
	.cas_fast(status[12]),            // menu Fast Tape
	.cas_out(tape_file),
	.border(),
	.mem_addr(tape_addr),
	.mem_rd(tape_rd),
	.mem_dout(tape_dout),
	.mem_ready(tape_ready)
);

// Skutecny magnetofon na audio vstupu desky (ADC LTC2308 v sys/ltc2308.sv,
// prevod na logicky signal s hysterezi). active = na vstupu je signal.
wire tape_adc, tape_adc_act;

ltc2308_tape #(.ADC_RATE(120000), .CLK_RATE(21_477_272)) tape_adc_i
(
	.reset(RESET),
	.clk(clk_sys),
	.ADC_BUS(ADC_BUS),
	.dout(tape_adc),
	.active(tape_adc_act),
	.adc_sync(),
	.adc_data()
);

// Zdroj signalu kazety (menu Tape Input): soubor CAS, nebo vstup ADC.
// Vstup z ADC jde do pocitace bez ohledu na motor jako na skutecnem M5
// (magnetofon hraje, i kdyz ho pocitac neovlada).
wire tape_src_adc = status[13];
assign cas_in = tape_src_adc ? (tape_adc_act & tape_adc) : tape_file;

// Priposlech kazety (menu Tape Sound): signal z kazety se primicha do
// zvuku jako obdelnik +-1/8 rozsahu, se saturaci. Ze souboru pri zapnutem
// motoru, z ADC kdyz je na vstupu signal.
wire               tape_sound = status[11] & (tape_src_adc ? tape_adc_act : cas_motor);
wire signed [16:0] audio_mix  = $signed({audio[15], audio}) +
                                (tape_sound ? (cas_in ? 17'sd4096 : -17'sd4096) : 17'sd0);
assign audio_out = (audio_mix >  17'sd32767) ? 16'sh7FFF :
                   (audio_mix < -17'sd32768) ? 16'sh8000 : audio_mix[15:0];

/////////////////  VIDEO  /////////////////
logic scandoubler;
wire [21:0] gamma_bus;


logic      vga_de;
wire  [1:0] ar    = status[2:1];
wire  [2:0] sdfx  = status[5:3];          // Scandoubler Fx (CONF_STR O[5:3])
wire  [1:0] sl    = sdfx != 0 ? sdfx[1:0] - 2'd1 : 2'd0;    // 1..4 -> 0..3 (CRT 25..75 % = 1..3)

assign VGA_SL = sl;
assign CLK_VIDEO   = clk_sys;
assign scandoubler = forced_scandoubler || sdfx != 0;

logic  en216p;
always_ff @(posedge CLK_VIDEO) begin
	en216p <= ((HDMI_WIDTH == 1920) && (HDMI_HEIGHT == 1080) && !scandoubler);
end

video_freak video_freak_i
(
	.*,
	.VGA_DE_IN(vga_de),
    .VGA_VS(~video_vs_n),
	.ARX((ar == 0) ? 12'd4 : {10'b0, (ar - 1'd1)}),
	.ARY((ar == 0) ? 12'd3 : 12'd0),
	.CROP_SIZE(en216p ? 12'd216 : 12'd0),
	.CROP_OFF('0),
	.SCALE(status[8:6])
);

video_mixer #(.GAMMA(1), .LINE_LENGTH(290)) video_mixer_i
(
   .CLK_VIDEO(CLK_VIDEO),
   .hq2x(sdfx==1),
   .scandoubler(scandoubler),
   .gamma_bus(gamma_bus),

   .ce_pix(video_ce_pix),
   .R(video_r),
   .G(video_g),
   .B(video_b),
   .HSync(~video_hs_n),
   .VSync(~video_vs_n),
   .HBlank(video_hblank),
   .VBlank(video_vblank),

   .HDMI_FREEZE(dbg_stopped),
   .freeze_sync(),

   .CE_PIXEL(CE_PIXEL),
   .VGA_R(VGA_R),
   .VGA_G(VGA_G),
   .VGA_B(VGA_B),
   .VGA_VS(VGA_VS),
   .VGA_HS(VGA_HS),
   .VGA_DE(vga_de)
);


endmodule

`default_nettype wire
