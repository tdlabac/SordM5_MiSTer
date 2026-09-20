//============================================================================
//  Sord M5 — rozšiřující sběrnice (konektor pro cartridge a periferie)
//
//  Modul se chová jako konektor sběrnice M5. Sem se přidávají periferie,
//  které si uživatel zapne z menu. Napájení (-12V, +12V, +5V, GND) se neřeší.
//
//  Vývody konektoru:
//       A                        B
//   8   D3                  8   D4
//   9   D2                  9   D5
//  10   D1                 10   D6
//  11   D0                 11   D7
//  12   A7                 12   A8
//  13   A6                 13   A9
//  14   A5                 14   A10
//  15   A4                 15   A11
//  16   A3                 16   A12
//  17   A2                 17   A13
//  18   A1                 18   A14
//  19   A0                 19   A15
//  20   WAIT               20   MRQ
//  21   ROMDS              21   RFSH
//  22   ROM1 (?)           22   ROM0 (?)
//  23   ROM2               23   EXM
//  24   MRD                24   MWR
//  25   IORD               25   IOWR
//  26   EXIOA              26   EXIOB
//  27   EXINT              27   EXCLK  (ZC/TO2 z CTC)
//  28   RST                28   Ø (takt CPU)
//
//  (?) = ze skenu schématu nejde přečíst jistě.
//
//  Datová sběrnice je v FPGA rozdělená na dva směry. D_i vrací 0xFF, pokud
//  žádná periferie nečte, a jádro ji slučuje s ostatními periferiemi přes AND.
//  Každá přidaná periferie proto musí mimo svůj výběr také vracet 0xFF.
//
//  Takt: místo vývodu Ø je tu clk_sys + ce_cpu_p/ce_cpu_n (3,58 MHz),
//  stejně jako všude jinde v jádru.
//============================================================================

module ext_bus
(
   input                       clk_sys,
   input                       ce_cpu_p,    // Ø — náběžná hrana taktu CPU
   input                       ce_cpu_n,    // Ø — sestupná hrana taktu CPU
   input  sordm5_pkg::ioctl_t  ioctl,       // plnění periferií souborem z menu

   // M5 -> periferie
   input                       RST_n,
   input         [15:0]        A,
   input         [7:0]         D_o,         // data z CPU
   input                       MRQ_n,
   input                       RFSH_n,
   input                       MRD_n,
   input                       MWR_n,
   input                       IORD_n,
   input                       IOWR_n,
   input                       ROM0_n,
   input                       ROM1_n,
   input                       ROM2_n,
   input                       EXM_n,
   input                       EXIOA_n,
   input                       EXIOB_n,
   input                       EXCLK,       // CTC ZC/TO2, pulz 1 takt CPU

   // volba cartridge z menu (moduly nize)
   input  sordm5_pkg::cart_sel_t cart_sel,
   input                       [15:0] cart_opt,

   // periferie -> M5
   output logic  [7:0]         D_i,         // data do CPU, 0xFF = nic nečte
   output logic                WAIT_n,
   output logic                ROMDS_n,
   output logic                EXINT_n,
   output logic                ROM0_ovrd_n
);

// ---------------------------------------------------------------------------
// Sem přidávej periferie. Každá dostane vlastní data / wait a nahoře
// se sloučí:
//   D_i    — AND všech periferií
//   WAIT_n — AND (na skutečné sběrnici otevřený kolektor)
//   EXINT_n, ROMDS_n — AND (otevřený kolektor)
// Zvuk konektor M5 nemá, periferie ho nevedou.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Cartridge: moduly z rtl/EXT/carts nad sdílenou blokovou RAM.
//
// Všechny mají stejné porty a jsou zapojené současně, ale enable dostane jen
// typ vybraný z menu; ostatní drží výstupy v klidu (mem = CART_MEM_IDLE,
// D_i = FFh, WAIT_n/ROMDS_n/EXINT_n = 1). Slučují se proto stejně
// jako ostatní periferie přes AND, adresní sběrnici do RAM v to počítaje.
// Žádný modul nesmí na sběrnici sahat bez svého enable.
//
// RAM je dvouportová: port A patří modulům cartridge, port B plní ioctl
// souborem z menu (index 1 = F1). Soubor se nahrává od adresy 0 a `rom_size`
// říká modulům, kam až sahá.
//
// Rozložení BRAM si řídí každý modul sám a loaderu hlásí výstupem `rom_max`,
// kolik bajtů ROM ještě přijme; nahrávání se na té hranici zastaví, takže
// delší soubor nemůže sáhnout do RAM modulu.
//
// Přidání dalšího typu: nový soubor v carts/ se stejnými porty, instance níž,
// nová hodnota v sordm5_pkg::cart_sel_t a položka v CONF_STR.
// ---------------------------------------------------------------------------

localparam int CART_AW = sordm5_pkg::CART_RAM_AW;
localparam int NCART   = 4;                  // počet modulů (cart_sel_t)

wire dl = ioctl.download && ioctl.index[5:0] == 6'd1;

// Kam až smí soubor do BRAM: hranici hlásí vybraný modul (rom_max), protože
// rozložení ROM a RAM si řídí sám. Co je nad ní, se nenahraje — RAM modulu
// tím zůstane nedotčená.
logic [CART_AW-1:0] c_rom_max [NCART];
wire [CART_AW-1:0]  rom_max    = c_rom_max[cart_sel];
wire [26:0]         rom_max_27 = {{(27-CART_AW){1'b0}}, rom_max};

wire dl_over = ioctl.addr >= rom_max_27;
wire dl_wr   = dl && ioctl.wr && !dl_over;

// Délka nahrané ROM: poslední zapsaná adresa + 1. Na začátku nahrávání se
// nuluje, aby kratší soubor nezdědil délku po předchozím. Soubor delší než
// prostor ROM dostane samé jedničky — každý modul si ho pak zamítne jako
// příliš velký a cartridge se neaktivuje.
//
// Reset jádra sem schválně nesahá: rom_size i obsah BRAM musí přežít reset
// po přepnutí cartridge v menu i reset z klávesnice, jinak by se ROM po
// restartu ztratila. Mění ji jen nové nahrání souboru.
logic [CART_AW-1:0] rom_size = '0;
logic               dl_d = 1'b0;
always_ff @(posedge clk_sys) begin
   dl_d <= dl;
   if (dl && !dl_d)
      rom_size <= '0;
   else if (dl && ioctl.wr)
      rom_size <= dl_over ? {CART_AW{1'b1}} : (ioctl.addr[CART_AW-1:0] + CART_AW'(1));
end

sordm5_pkg::cart_mem_t cart_mem;
logic [7:0] cart_mem_q;

sordm5_pkg::cart_mem_t c_mem [NCART];
logic [7:0]            c_di  [NCART];
logic                  c_wait_n [NCART];
logic                  c_romds_n[NCART];
logic                  c_exint_n[NCART];
logic                  c_rom0_ovrd_n[NCART];

`define CART_PORTS(i)                                                      \
   .clk_sys(clk_sys), .ce_cpu_p(ce_cpu_p), .ce_cpu_n(ce_cpu_n),            \
   .RST_n(RST_n), .enable(cart_sel == sordm5_pkg::cart_sel_t'(i)),         \
   .A(A), .D_o(D_o), .MRQ_n(MRQ_n), .RFSH_n(RFSH_n),                       \
   .MRD_n(MRD_n), .MWR_n(MWR_n), .IORD_n(IORD_n), .IOWR_n(IOWR_n),         \
   .ROM0_n(ROM0_n), .ROM1_n(ROM1_n), .ROM2_n(ROM2_n), .EXM_n(EXM_n),       \
   .EXIOA_n(EXIOA_n), .EXIOB_n(EXIOB_n),                                   \
   .opt(cart_opt), .rom_size(rom_size), .rom_max(c_rom_max[i]),            \
   .mem(c_mem[i]), .mem_q(cart_mem_q),                                     \
   .D_i(c_di[i]), .WAIT_n(c_wait_n[i]), .ROMDS_n(c_romds_n[i]),            \
   .EXINT_n(c_exint_n[i]), .ROM0_ovrd_n(c_rom0_ovrd_n[i])

cart_none none_i (`CART_PORTS(sordm5_pkg::CART_NONE));
cart_em32 em32_i (`CART_PORTS(sordm5_pkg::CART_EM32));
cart_em64 em64_i (`CART_PORTS(sordm5_pkg::CART_EM64));
cart_brno brno_i (`CART_PORTS(sordm5_pkg::CART_BRNO));

`undef CART_PORTS

always_comb begin
   cart_mem = sordm5_pkg::CART_MEM_IDLE;
   D_i         = 8'hFF;
   WAIT_n      = 1'b1;
   ROMDS_n     = 1'b1;
   EXINT_n     = 1'b1;
   ROM0_ovrd_n = 1'b0;
   for (int i = 0; i < NCART; i++) begin
      cart_mem = cart_mem & c_mem[i];        // neaktivní drží samé jedničky
      D_i      = D_i      & c_di[i];
      WAIT_n   = WAIT_n   & c_wait_n[i];
      ROMDS_n  = ROMDS_n  & c_romds_n[i];
      EXINT_n  = EXINT_n  & c_exint_n[i];
      ROM0_ovrd_n = ROM0_ovrd_n | c_rom0_ovrd_n[i];      //Pozor '1 blokuje signál ROM0
   end
end

// Sdílená RAM cartridge: 128 kB, port A moduly, port B ioctl.
dpram #(.addr_width(CART_AW), .data_width(8), .mem_name("CART_RAM")) cart_ram
(
   .clock(clk_sys),

   .address_a(cart_mem.addr),
   .data_a(cart_mem.data),
   .wren_a(!cart_mem.we_n),
   .q_a(cart_mem_q),
   .cs_a(!cart_mem.cs_n),
   .oe_a(!cart_mem.oe_n),

   .address_b(ioctl.addr[CART_AW-1:0]),
   .data_b(ioctl.data),
   .wren_b(dl_wr),
   .q_b(),
   .cs_b(dl),
   .oe_b(1'b0)
);

endmodule
