// Test zmrazení celého počítače (doc/z80-debugger.md, krok 4).
//
// Dvě instance celého SordM5 (DEBUG = 1), každá má vlastní hodiny:
//   a  debugger ji zastavuje, krokuje a nahrává registry (DIRSet s REG),
//   b  běží bez zásahů.
// C++ dává hodiny b jen v taktech, kdy a nestojí (freeze = 0). Když zmrazení
// nic nemění, musí být obě instance v každém taktu stejné: video, zvuk,
// sběrnice CPU i registry. Na konci se porovná celá RAM a VRAM.

module tb_freeze (
   input  logic         clk_a,
   input  logic         clk_b,
   input  logic         reset,

   // debugger instance a
   input  logic         dbg_stop,
   input  logic         dbg_step,
   input  logic         dbg_dirset,
   input  logic [211:0] dbg_dir,
   output logic         a_stopped,
   output logic [211:0] a_reg,
   output logic [211:0] b_reg,

   // porovnávané výstupy: {R,G,B}, {HS,VS,hblank,vblank,blank_n,ce_pix,int}, audio, sběrnice
   output logic [23:0]  a_rgb,  b_rgb,
   output logic [6:0]   a_sync, b_sync,
   output logic [15:0]  a_audio, b_audio,
   output logic [15:0]  a_addr, b_addr,
   output logic [7:0]   a_do,   b_do,
   output logic [7:0]   a_di,   b_di,
   output logic [5:0]   a_ctl,  b_ctl,     // {M1,MREQ,IORQ,RD,WR,RFSH}_n

   // porovnání pamětí na konci
   input  logic [13:0]  peek_a,
   output logic [7:0]   a_ram, b_ram, a_vram, b_vram
);
   sordm5_pkg::ioctl_t ioctl_idle;
   assign ioctl_idle = '0;

`define M5_INST(name, clk, stop, step, dirset, dir, stopped, regout) \
   SordM5 #(.DEBUG(1)) name ( \
      .clk_sys(clk), .reset(reset), .ps2_key(11'd0), .ioctl(ioctl_idle), \
      .TMS_border(1'b0), .TMS_PAL(1'b0), .TMS_interrupt_n(), \
      .video_R(), .video_G(), .video_B(), .video_HS_n(), .video_VS_n(), \
      .video_hblank(), .video_vblank(), .video_blank_n(), .video_ce_pix(), .audio(), \
      .dbg_stop(stop), .dbg_step(step), .dbg_dirset(dirset), .dbg_dir(dir), \
      .dbg_stopped(stopped), .dbg_reg(regout));

   `M5_INST(a, clk_a, dbg_stop, dbg_step, dbg_dirset, dbg_dir, a_stopped, a_reg)
   `M5_INST(b, clk_b, 1'b0, 1'b0, 1'b0, '0, , b_reg)

   assign a_rgb   = {a.video_R, a.video_G, a.video_B};
   assign b_rgb   = {b.video_R, b.video_G, b.video_B};
   assign a_sync  = {a.video_HS_n, a.video_VS_n, a.video_hblank, a.video_vblank, a.video_blank_n, a.video_ce_pix, a.TMS_interrupt_n};
   assign b_sync  = {b.video_HS_n, b.video_VS_n, b.video_hblank, b.video_vblank, b.video_blank_n, b.video_ce_pix, b.TMS_interrupt_n};
   assign a_audio = a.audio;   assign b_audio = b.audio;
   assign a_addr  = a.A;       assign b_addr  = b.A;
   assign a_do    = a.DO;      assign b_do    = b.DO;
   assign a_di    = a.DI;      assign b_di    = b.DI;
   assign a_ctl   = {a.M1_n, a.MREQ_n, a.IORQ_n, a.RD_n, a.WR_n, a.RFSH_n};
   assign b_ctl   = {b.M1_n, b.MREQ_n, b.IORQ_n, b.RD_n, b.WR_n, b.RFSH_n};

   assign a_ram   = a.ram.mem[peek_a[11:0]];
   assign b_ram   = b.ram.mem[peek_a[11:0]];
   assign a_vram  = a.vram.mem[peek_a];
   assign b_vram  = b.vram.mem[peek_a];
endmodule
