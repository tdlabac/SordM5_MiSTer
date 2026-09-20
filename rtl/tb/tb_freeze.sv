// Test zmrazení celého počítače (doc/z80-debugger.md, kroky 4 a 5).
//
// Dvě instance celého jádra sordm5_core (DEBUG = 1), každá má vlastní hodiny:
//   a  debugger ji zastavuje (příkaz stop i breakpointy), krokuje, nahrává
//      registry (DIRSet s REG) a za zastavení čte paměť převzetím sběrnice,
//   b  běží bez zásahů.
// C++ dává hodiny b jen v taktech, kdy a nestojí (freeze = 0). Když zmrazení
// ani přístupy debuggeru nic nemění, musí být obě instance v každém taktu
// stejné: video, zvuk, sběrnice CPU (mimo přístupy debuggeru) i registry.
// Na konci se porovná celá RAM a VRAM.

module tb_freeze
   import tv80_dbg_pkg::*;
(
   input  logic         clk_a,
   input  logic         clk_b,
   input  logic         reset,

   // nahrání cartridge přes ioctl (index 1) — stejnou cestou jako v jádře,
   // jinak by modul cartridge zůstal bez rom_size neaktivní
   input  logic         io_download,
   input  logic         io_wr,
   input  logic [26:0]  io_addr,
   input  logic [7:0]   io_data,

   // příkazy debuggeru instance a
   input  logic         c_stop, c_run, c_step, c_dirset,
   input  logic [211:0] c_dir,
   input  logic         c_mem_req, c_mem_we,
   input  logic [15:0]  c_mem_addr,
   input  logic [7:0]   c_mem_wdata,
   input  logic         bp_we,
   input  logic [3:0]   bp_sel,
   input  logic [4:0]   bp_kind,
   input  logic [15:0]  bp_addr, bp_amask,

   output logic         a_stopped,
   output logic [2:0]   a_reason,
   output logic         a_busy,
   output logic [7:0]   a_rdata,
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
   output logic [47:0]  a_ts,   b_ts,      // čas počítače (rtl/tstamp.sv)

   // porovnání pamětí na konci
   input  logic [13:0]  peek_a,
   output logic [7:0]   a_ram, b_ram, a_vram, b_vram,
   output logic [16:0]  a_rom_size
);
   sordm5_pkg::ioctl_t ioctl_bus;
   assign ioctl_bus = {io_download, 16'd1, io_wr, io_addr, io_data};

   bp_t bps [NBP];
   always_ff @(posedge clk_a)
      if (bp_we) bps[bp_sel] <= '{kind: bp_kind, addr: bp_addr, amask: bp_amask, data: 8'h00, dmask: 8'h00};

   dbg_in_t  a_i;
   dbg_out_t a_o, b_o;
   always_comb begin
      a_i = '0;
      a_i.stop = c_stop; a_i.run = c_run; a_i.step = c_step;
      a_i.dirset = c_dirset; a_i.dir = c_dir;
      a_i.mem_req = c_mem_req; a_i.mem_we = c_mem_we; a_i.mem_addr = c_mem_addr; a_i.mem_wdata = c_mem_wdata;
      for (int i = 0; i < NBP; i++) a_i.bp[i] = bps[i];
   end

`define M5_INST(name, clk, din, dout, ts) \
   sordm5_core #(.DEBUG(1)) name ( \
      .clk_sys(clk), .reset(reset), .ps2_key(11'd0), .ioctl(ioctl_bus), \
      .vdp_border(1'b0), .vdp_pal(1'b0), \
      .cart_sel(sordm5_pkg::CART_NONE), .cart_opt(16'd0), \
      .video_r(), .video_g(), .video_b(), .video_hs_n(), .video_vs_n(), \
      .video_hblank(), .video_vblank(), .video_ce_pix(), .audio(), \
      .ce_cpu(), .cas_in(1'b0), .cas_motor(), \
      .dbg_i(din), .dbg_o(dout), .tstamp(ts));

   `M5_INST(a, clk_a, a_i, a_o, a_ts)
   `M5_INST(b, clk_b, '0, b_o, b_ts)

   assign a_stopped = a_o.stopped;  assign a_reason = a_o.reason;
   assign a_busy    = a_o.mem_busy; assign a_rdata  = a_o.mem_rdata;
   assign a_reg     = a_o.regs;     assign b_reg    = b_o.regs;

   assign a_rgb   = {a.video_r, a.video_g, a.video_b};
   assign b_rgb   = {b.video_r, b.video_g, b.video_b};
   // vdp_int_n je vnitřní signál jádra (přerušení VDP -> CTC); bit 2 je
   // volný (dřív video_blank_n), aby se neposunuly pozice HS/VS pro C++
   assign a_sync  = {a.video_hs_n, a.video_vs_n, a.video_hblank, a.video_vblank, 1'b1, a.video_ce_pix, a.vdp_int_n};
   assign b_sync  = {b.video_hs_n, b.video_vs_n, b.video_hblank, b.video_vblank, 1'b1, b.video_ce_pix, b.vdp_int_n};
   assign a_audio = a.audio;   assign b_audio = b.audio;
   assign a_addr  = a.A;       assign b_addr  = b.A;
   assign a_do    = a.DO;      assign b_do    = b.DO;
   assign a_di    = a.DI;      assign b_di    = b.DI;
   assign a_ctl   = {a.M1_n, a.MREQ_n, a.IORQ_n, a.RD_n, a.WR_n, a.RFSH_n};
   assign b_ctl   = {b.M1_n, b.MREQ_n, b.IORQ_n, b.RD_n, b.WR_n, b.RFSH_n};

   assign a_ram   = a.ram_i.mem[peek_a[11:0]];
   assign b_ram   = b.ram_i.mem[peek_a[11:0]];
   assign a_rom_size = a.ext_i.rom_size;
   assign a_vram  = a.vram_i.mem[peek_a];
   assign b_vram  = b.vram_i.mem[peek_a];
endmodule
