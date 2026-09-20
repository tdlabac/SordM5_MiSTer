//============================================================================
//  Sord M5 — cartridge EM-64 (rozšíření paměti)
//
//  Menu: "Cartridge,EM64" a čtyři vlastní volby v podmenu. Podmenu se
//  zobrazuje, jen když je EM64 vybrané (menumask bit 0, viz sordM5.sv).
//  Volby chodí sem v `opt`:
//     opt[0]  WP monitor,Off,On      (CONF_STR O[16])
//     opt[1]  Autostart,Off,On       (CONF_STR O[17])
//     opt[2]  Mode,EM64,EM32         (CONF_STR O[18])
//     opt[3]  Monitor protect,Off,On (CONF_STR O[19])
//
//  Pravidla (test rtl/EXT/tb/tb_cart.cpp, sekce EM64):
//
//  Zápis na port 6Ch (OUT (6Ch),d — prostor EXIOA 60h-6Fh, A[3:2] = 11)
//  nastaví podle D0 signál ROMDS, kterým se odpojí ROM. Po resetu ho nastaví
//  volba Autostart.
//
//  Bez ROMDS je cartridge obyčejná ROM od 2000h (do délky nahraného souboru)
//  plus RAM na 8000h-FFFFh.
//
//  Se zapnutým ROMDS:
//     Mode = EM64 — RAM i dole, tedy 0000h-6FFFh. 7000h-7FFFh patří interní
//                   RAM M5 (rtl/GA015/ga015.sv), tam cartridge nesahá.
//            EM32 — RAM zůstává jen 8000h-FFFFh.
//     Monitor protect Off — odpojí se i monitor (0000h-1FFFh) a je tam RAM
//                   cartridge; On = monitor zůstává a cartridge se na
//                   0000h-1FFFh neozve vůbec. V režimu EM32 se monitor
//                   neodpojuje, nebylo by ho čím nahradit.
//     WP monitor  — 0000h-1FFFh je jen pro čtení.
//
//  Porty jsou stejné pro všechny moduly cartridge, viz rtl/EXT/ext_bus.sv.
//============================================================================

`default_nettype none

module cart_em64
   import sordm5_pkg::*;
(
   input  wire        clk_sys,
   input  wire        ce_cpu_p,
   input  wire        ce_cpu_n,
   input  wire        RST_n,
   input  wire        enable,

   input  wire [15:0] A,
   input  wire [7:0]  D_o,
   input  wire        MRQ_n,
   input  wire        RFSH_n,
   input  wire        MRD_n,
   input  wire        MWR_n,
   input  wire        IORD_n,
   input  wire        IOWR_n,
   input  wire        ROM0_n,
   input  wire        ROM1_n,
   input  wire        ROM2_n,
   input  wire        EXM_n,
   input  wire        EXIOA_n,
   input  wire        EXIOB_n,

   input  wire [15:0] opt,
   input  wire [CART_RAM_AW-1:0] rom_size,    // délka nahrané ROM
   output logic [CART_RAM_AW-1:0] rom_max,   // kolik ROM modul přijme (loader)

   output cart_mem_t  mem,
   input  wire [7:0]  mem_q,

   output logic [7:0] D_i,
   output logic       WAIT_n,
   output logic       ROMDS_n,
   output logic       EXINT_n,
   output logic       ROM0_ovrd_n
);
   
   // Rozložení sdílené BRAM si určuje modul sám: ROM od 0 do ROM_MAX (prostor
   // cartridge 2000h-6FFFh), RAM hned za ní — 64 kB, tedy po 14FFFh. Zbytek
   // BRAM se nepoužívá. ROM_MAX jde ven jako rom_max, loader nad něj nezapíše.
   localparam logic [CART_RAM_AW-1:0] ROM_MAX  = 'h5000;
   localparam logic [CART_RAM_AW-1:0] RAM_BASE = ROM_MAX;
   localparam logic [15:0]            ROM_BASE = 16'h2000;

   assign rom_max = ROM_MAX;

   wire size_ok = enable && rom_size <= ROM_MAX;
   wire rom_ok  = size_ok && rom_size != 0;

   // Volby z podmenu (viz hlavička).
   wire wp_monitor = opt[0];    // 0000-1FFF jen pro čtení
   wire autostart  = opt[1];    // stav ROMDS po resetu
   wire mode_em32  = opt[2];    // 0 = EM64 (RAM i dole), 1 = EM32
   wire mon_prot   = opt[3];    // 1 = monitor na 0000-1FFF zůstává

   logic romds;

   // Šířky: posun v ROM se počítá v šířce adresy CPU (16 b) a do šířky paměti
   // se rozšíří jednou, funkcí cart_addr. Porovnání s rom_size i zápis do
   // mem.addr pak mají obě strany stejně široké, ať je CART_RAM_AW jakékoli.
   wire [15:0]            rom_off  = A - ROM_BASE;
   wire [CART_RAM_AW-1:0] rom_addr = cart_addr(rom_off);
   wire                   rom_hit  = rom_ok && (!ROM1_n || !ROM2_n || !EXM_n) && (rom_addr < rom_size);
   wire                   rom_rd   = rom_hit && !MRD_n && !romds;

   // ROMDS se přepíná zápisem na port 6Ch (EXIOA = 60h-6Fh, A[3:2] = 11),
   // po resetu ho nastaví volba Autostart.
   always_ff @(posedge clk_sys) begin
      if (!RST_n) begin
         if (enable) begin
               romds <= autostart;
         end else begin
            romds <= 1'b0;
         end
      end else begin
         if (enable) begin
            if (A[3:2] == 2'b11 && !EXIOA_n & !IOWR_n) begin
               romds <= D_o[0];
            end
         end
      end
   end

   // Monitor se odpojí jen v režimu EM64, když to volba dovolí — v EM32 by
   // nebylo čím ho nahradit. Jádro pak samo zamaskuje ROM0_n (sordm5_core.sv),
   // takže se cartridge o 0000-1FFF stará jen tehdy, když monitor odpojila.
   wire mon_ovrd = enable && romds && !mode_em32 && !mon_prot;

   // RAM: 8000h-FFFFh vždy, dole (0000-6FFFh) jen v EM64 se zapnutým ROMDS.
   // 7000h-7FFFh patří interní RAM M5, tam cartridge nesahá.
   wire ram_lo  = romds && !mode_em32;
   wire ram_hit = enable
              && (A[15] || ram_lo)
              && (A[15:12] != 4'h7)
              && ROM0_n;                 // přichází už zamaskovaný, viz výš

   wire ram_wr_ok = !(A[15:13] == 3'b000 && wp_monitor);   // WP monitor

   always_comb begin
      mem = CART_MEM_IDLE;
      ROMDS_n = 1'b1;
      ROM0_ovrd_n = 1'b0;
      if (rom_rd) begin
         mem.addr = rom_addr;
         mem.cs_n = 1'b0;
         mem.oe_n = 1'b0;
         mem.we_n = 1'b1;
      end
      else if (ram_hit) begin
         mem.addr = RAM_BASE + cart_addr(A);
         mem.data = D_o;
         mem.cs_n = 1'b0;
         if (!MRD_n)
            mem.oe_n = 1'b0;
         else if (!MWR_n && ram_wr_ok)
            mem.we_n = 1'b0;
      end
      if (enable) begin
         ROMDS_n = !romds;
         ROM0_ovrd_n = mon_ovrd;         // '1 blokuje ROM0, viz ext_bus.sv
      end
   end

   assign D_i     = mem.oe_n ? 8'hFF : mem_q;
   assign WAIT_n  = 1'b1;
   assign EXINT_n = 1'b1;

endmodule

`default_nettype wire
