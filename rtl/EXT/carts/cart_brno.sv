//============================================================================
//  Sord M5 — cartridge BRNO (rozšíření s disketovou jednotkou)
//
//  Menu: "Cartridge,BRNO" a podmenu s připojením blokových zařízení
//  (Floppy A = S0, Floppy B = S1). Podmenu se zobrazuje, jen když je BRNO
//  vybrané (menumask bit 1, viz sordM5.sv).
//
//  KOSTRA: modul se zatím chová jako prázdný slot. Až se bude doplňovat,
//  patří sem:
//    - layout ve sdílené RAM (ROM řadiče, RAM, případný sektorový buffer),
//    - dekódování prostoru cartridge a I/O portů řadiče,
//    - obsluha blokových zařízení z hps_io: img_mounted/img_size,
//      sd_lba/sd_rd/sd_wr/sd_ack a sektorový buffer sd_buff_*.
//      Ty se do modulu teprve přivedou (v sordM5.sv jsou dnes nezapojené).
//
//  Porty jsou stejné pro všechny moduly cartridge, viz rtl/EXT/ext_bus.sv.
//============================================================================

`default_nettype none

module cart_brno
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

   // Kolik ROM modul přijme (loader nad to nezapíše, viz rtl/EXT/ext_bus.sv).
   // Kostra bere stejných 5000h jako ostatní; až se doplní layout ROM řadiče
   // a RAM, upravit podle něj.
   assign rom_max = 'h5000;

   assign mem     = CART_MEM_IDLE;
   assign D_i     = 8'hFF;
   assign WAIT_n  = 1'b1;
   assign ROMDS_n = 1'b1;
   assign EXINT_n = 1'b1;
   assign ROM0_ovrd_n = 1'b0;

endmodule

`default_nettype wire
