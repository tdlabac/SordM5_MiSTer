//============================================================================
//  Sord M5 — společné typy jádra
//
//  Package se musí překládat PŘED všemi soubory, které ho používají:
//  v Quartusu je proto v kořenovém files.qip před sordM5.sv, ve verilátoru
//  v sordM5.sh před ../sordM5.sv.
//============================================================================

package sordm5_pkg;

   // Jednosměrná sběrnice pro plnění pamětí souborem z HPS (ioctl_download).
   //
   // Paměť si z ní vybírá sama podle `index` (číslo souboru z menu, 0 = boot
   // ROM) — cs se nikam nerozvádí, viz rom_ioctl.sv. Každý soubor začíná na
   // adrese 0.
   //
   // Pole jsou ve stejném pořadí, v jakém je sordM5.sv skládá z portů hps_io
   // (download, index, wr, addr, data) — při změně upravit obojí.
   typedef struct packed {
      logic        download;   // probíhá nahrávání souboru
      logic [15:0] index;      // index souboru v menu (ioctl_index)
      logic        wr;         // zápisový pulz jednoho bajtu
      logic [26:0] addr;       // adresa bajtu v souboru
      logic [7:0]  data;       // bajt
   } ioctl_t;

endpackage
