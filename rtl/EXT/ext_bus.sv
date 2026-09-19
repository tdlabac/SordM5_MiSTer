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

   // periferie -> M5
   output        [7:0]         D_i,         // data do CPU, 0xFF = nic nečte
   output                      WAIT_n,
   output                      ROMDS_n,
   output                      EXINT_n,
   output signed [15:0]        audio
);

// ---------------------------------------------------------------------------
// Sem přidávej periferie. Každá dostane vlastní data / wait / audio a nahoře
// se sloučí:
//   D_i    — AND všech periferií
//   WAIT_n — AND (na skutečné sběrnici otevřený kolektor)
//   EXINT_n, ROMDS_n — AND (otevřený kolektor)
//   audio  — součet
// ---------------------------------------------------------------------------

assign WAIT_n  = 1'b1;
assign ROMDS_n = 1'b1;
assign EXINT_n = 1'b1;
assign audio   = 16'sd0;

assign D_i = data_rom_cart;

// cartrige ROM
logic [7:0] data_rom_cart;
// Cartridge ROM; ioctl index 1 = první soubor z menu (F1).
rom_ioctl #(.addr_width(13),.mem_name("ROM_CART"),.IOCTL_INDEX(1)) rom_cart
(
   .clock(clk_sys),
   .ioctl(ioctl),
   .address(A[12:0]),
   .q(data_rom_cart),
   .cs(!ROM1_n),
   .oe(!MRD_n)
);

endmodule
