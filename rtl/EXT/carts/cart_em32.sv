//============================================================================
//  Sord M5 — cartridge EM-32: ROM cartridge s 32 kB RAM
//
//  Menu: "Cartridge,EM32". Podmenu nemá.
//
//  Pravidla (stejná jako u None, jen RAM je vždy celých 32 kB):
//    - ROM se musí vejít do 2000h-6FFFh, tedy 5000h bajtů. Delší ROM je
//      neplatná a cartridge se vůbec neaktivuje.
//    - ROM se adresuje výběry ROM1_n (2000h-3FFFh), ROM2_n (4000h-5FFFh)
//      a EXM_n (6000h-7FFFh), ale jen do délky nahrané ROM; nad ní vrací FFh.
//      Bez nahrané ROM se z prostoru cartridge čte FFh.
//    - RAM má 32 kB, v prostoru CPU leží na 8000h-FFFFh a dekóduje se jen
//      z adresy CPU. Na nahrané ROM nezávisí (je to paměťové rozšíření).
//
//  Sdílená RAM (rtl/EXT/ext_bus.sv): modul si určuje rozložení sám — ROM od
//  adresy 0 do ROM_MAX (hlásí ho loaderu výstupem rom_max, delší soubor se
//  nenahraje), RAM hned za ní.
//
//  Porty jsou stejné pro všechny moduly cartridge, viz rtl/EXT/ext_bus.sv.
//============================================================================

`default_nettype none

module cart_em32
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

   input  wire [15:0] opt,                    // tenhle modul podmenu nemá
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

   // Rozložení sdílené BRAM si určuje modul sám: ROM od 0 do ROM_MAX, RAM
   // hned za ní. ROM_MAX jde ven jako rom_max, loader nad něj nezapíše.
   localparam logic [CART_RAM_AW-1:0] ROM_MAX  = 'h5000;     // 2000h-6FFFh
   localparam logic [CART_RAM_AW-1:0] RAM_BASE = ROM_MAX;
   localparam logic [15:0]            ROM_BASE = 16'h2000;

   assign rom_max = ROM_MAX;

   // Příliš dlouhá ROM vypne celou cartridge; bez ROM zůstává jen RAM.
   wire size_ok = enable && rom_size <= ROM_MAX;
   wire rom_ok  = size_ok && rom_size != 0;

   // Šířky: adresa CPU se počítá v 16 bitech a do šířky paměti se rozšíří
   // funkcí cart_addr. Nikde tak není šířka sdílené RAM napevno.
   //
   // ROM: prostor cartridge, jen do délky nahrané ROM.
   wire [15:0]            rom_off  = A - ROM_BASE;
   wire [CART_RAM_AW-1:0] rom_addr = cart_addr(rom_off);
   wire                   rom_hit  = rom_ok && (!ROM1_n || !ROM2_n || !EXM_n) &&
                                     rom_addr < rom_size;
   wire        rom_rd  = rom_hit && !MRD_n;

   // RAM: 32 kB od 8000h, čistě podle adresy CPU.
   wire ram_hit = size_ok && A[15];
   wire ram_rd  = ram_hit && !MRD_n;
   wire ram_wr  = ram_hit && !MWR_n;

   always_comb begin
      mem = CART_MEM_IDLE;
      if (rom_rd) begin
         mem.addr = rom_addr;
         mem.cs_n = 1'b0;
         mem.oe_n = 1'b0;
         mem.we_n = 1'b1;
      end
      else if (ram_rd || ram_wr) begin
         mem.addr = RAM_BASE + cart_addr({1'b0, A[14:0]});
         mem.data = D_o;
         mem.cs_n = 1'b0;
         mem.oe_n = ~ram_rd;
         mem.we_n = ~ram_wr;
      end
   end

   assign D_i     = (rom_rd || ram_rd) ? mem_q : 8'hFF;
   assign WAIT_n  = 1'b1;
   assign ROMDS_n = 1'b1;
   assign EXINT_n = 1'b1;
   assign ROM0_ovrd_n = 1'b0;

endmodule

`default_nettype wire
