// Test nahrávání z kazety skutečným monitorem M5: celé jádro sordm5_core
// (bez cartridge, monitor po startu sám čte kazetu, RBTCMT) + cas_player
// + rtl/ddram.sv. DDR3 modeluje tb_m5tape.cpp. Zapojení kazety a reset jako
// v sordM5.sv (nahrání kazety počítač neresetuje).

module tb_m5tape (
   input  logic        clk,
   input  logic        reset_in,          // RESET z tb

   input  logic        io_download,
   input  logic [15:0] io_index,
   input  logic [26:0] io_addr,

   output logic        reset,             // reset jádra (jako v sordM5.sv)
   output logic        cas_motor,
   output logic        cas_in,
   output logic [15:0] A,
   output logic        M1_n, MREQ_n, IORQ_n, RD_n, WR_n,
   output logic [7:0]  DI, DO,
   output logic [47:0] tstamp,

   input  logic [11:0] peek_addr,         // RAM 7000h-7FFFh
   output logic [7:0]  peek_data,
   output logic        ctc1_wr,           // zápis do kanálu 1, jak ho vidí CTC
   output logic [7:0]  ctc1_din,

   input  logic        DDRAM_BUSY,
   output logic [7:0]  DDRAM_BURSTCNT,
   output logic [28:0] DDRAM_ADDR,
   input  logic [63:0] DDRAM_DOUT,
   input  logic        DDRAM_DOUT_READY,
   output logic        DDRAM_RD,
   output logic [63:0] DDRAM_DIN,
   output logic [7:0]  DDRAM_BE,
   output logic        DDRAM_WE
);
   sordm5_pkg::ioctl_t ioctl;
   assign ioctl = {io_download, io_index, 1'b0, io_addr, 8'h00};

   logic tape_loading, ce_cpu;
   assign reset = reset_in | (io_download & !tape_loading);

   tv80_dbg_pkg::dbg_out_t dbg_o;

   sordm5_core #(.DEBUG(0)) core_i (
      .clk_sys(clk), .reset(reset), .ps2_key(11'd0), .ioctl(ioctl),
      .vdp_border(1'b0), .vdp_pal(1'b0),
      .cart_sel(sordm5_pkg::CART_NONE), .cart_opt(16'd0),
      .video_r(), .video_g(), .video_b(), .video_hs_n(), .video_vs_n(),
      .video_hblank(), .video_vblank(), .video_ce_pix(), .audio(),
      .ce_cpu(ce_cpu), .cas_in(cas_in), .cas_motor(cas_motor),
      .dbg_i('0), .dbg_o(dbg_o), .tstamp(tstamp)
   );

   assign A      = core_i.A;
   assign M1_n   = core_i.M1_n;
   assign MREQ_n = core_i.MREQ_n;
   assign IORQ_n = core_i.IORQ_n;
   assign RD_n   = core_i.RD_n;
   assign WR_n   = core_i.WR_n;
   assign DI     = core_i.DI;
   assign DO     = core_i.DO;
   assign peek_data = core_i.ram_i.mem[peek_addr];
   assign ctc1_wr   = core_i.ctc_i.channels[1].channel.wr_pulse;
   assign ctc1_din  = core_i.ctc_i.dIn;

   logic [27:0] mem_addr;
   logic [7:0]  mem_dout;
   logic        mem_rd, mem_ready;

   cas_player #(.IOCTL_INDEX(6'd2)) cas_i (
      .clk(clk), .ce(ce_cpu), .ioctl(ioctl), .loading(tape_loading),
      .cas_on(cas_motor), .cas_fast(1'b0), .cas_out(cas_in), .border(),
      .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_dout(mem_dout), .mem_ready(mem_ready)
   );

   ddram ddram_i (
      .reset(tape_loading), .DDRAM_CLK(clk),
      .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
      .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
      .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
      .addr(mem_addr), .dout(mem_dout), .din(8'hFF), .we(1'b0), .rd(mem_rd), .ready(mem_ready)
   );
endmodule
