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

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;  

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
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

hps_io #(.CONF_STR(CONF_STR)) hps_io_i
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(1'b0)
);

wire reset = RESET | status[0] | buttons[1] | ioctl_download;

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
pll pll_i
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);
logic [7:0] video_R, video_G, video_B;
logic       video_HS_n, video_VS_n, video_hblank, video_vblank, video_blank_n, video_ce_pix;
logic       TMS_interrupt_n;
SordM5 sordm5_i
(
	.clk_sys(clk_sys),
	.reset(reset),
	.ps2_key(ps2_key),
	.ioctl(ioctl),
	.TMS_border(status[9]),
	.TMS_interrupt_n(TMS_interrupt_n),
	.TMS_PAL(status[10]),
	.video_R(video_R),
    .video_G(video_G),
    .video_B(video_B),
    .video_HS_n(video_HS_n),
    .video_VS_n(video_VS_n),
    .video_hblank(video_hblank),
    .video_vblank(video_vblank),
    .video_blank_n(video_blank_n),
	.video_ce_pix(video_ce_pix)
);

/////////////////  VIDEO  /////////////////
logic scandoubler;
wire [21:0] gamma_bus;


logic      vga_de;
wire  [1:0] ar    = status[2:1];
wire  [2:0] scale = status[5:3];
wire  [2:0] sl    = scale != 0 ? scale - 1'd1 : 3'd0;

assign VGA_SL = sl[1:0];
assign CLK_VIDEO   = clk_sys;
assign scandoubler = forced_scandoubler || scale != 0;

logic  en216p;
always_ff @(posedge CLK_VIDEO) begin
	en216p <= ((HDMI_WIDTH == 1920) && (HDMI_HEIGHT == 1080) && !scandoubler);
end

video_freak video_freak_i
(
	.*,
	.VGA_DE_IN(vga_de),
    .VGA_VS(~video_VS_n),
	.ARX((ar == 0) ? 12'd4 : {10'b0, (ar - 1'd1)}),
	.ARY((ar == 0) ? 12'd3 : 12'd0),
	.CROP_SIZE(en216p ? 12'd216 : 12'd0),
	.CROP_OFF(0),
	.SCALE(status[8:6])
);

video_mixer #(.GAMMA(1), .LINE_LENGTH(290)) video_mixer_i
(
   .CLK_VIDEO(CLK_VIDEO),
   .hq2x(scale==1),
   .scandoubler(scandoubler),
   .gamma_bus(gamma_bus),

   .ce_pix(video_ce_pix),
   .R(video_R),
   .G(video_G),
   .B(video_B),
   .HSync(~video_HS_n),
   .VSync(~video_VS_n),
   .HBlank(video_hblank),
   .VBlank(video_vblank),

   .HDMI_FREEZE(0),
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
