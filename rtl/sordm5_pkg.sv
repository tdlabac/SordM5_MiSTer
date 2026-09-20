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

   // ------------------------------------------------------------------------
   // Cartridge na rozšiřující sběrnici (rtl/EXT)
   //
   // Typ se vybírá z menu ("O[15:14],Cartridge,None,EM32,EM64,BRNO"), pořadí
   // hodnot odpovídá pořadí v CONF_STR. Vybraný modul dostane enable, ostatní
   // drží všechny výstupy v klidu.
   typedef enum logic [1:0] {
      CART_NONE = 2'd0,       // holá ROM cartridge
      CART_EM32 = 2'd1,
      CART_EM64 = 2'd2,
      CART_BRNO = 2'd3
   } cart_sel_t;

   // Sdílená bloková RAM všech modulů: 128 kB (2^17). ROM se do ní nahrává
   // portem B z ioctl od adresy 0, moduly čtou/zapisují portem A.
   localparam int CART_RAM_AW = 17;

   // Rozložení BRAM si řídí každý modul cartridge sám — jen on ví, kolik
   // ROM umí použít a kde chce mít RAM. Společné je tohle:
   //
   //    - ROM se vždy nahrává od adresy 0,
   //    - modul svou hranici hlásí výstupem `rom_max` (bajtů ROM, které ještě
   //      přijme) a RAM si dává až za ni,
   //    - loader v rtl/EXT/ext_bus.sv `rom_max` respektuje: co je nad ním,
   //      do BRAM nezapíše, takže delší soubor nemůže RAM poškodit, a délku
   //      ROM nahlásí jako neplatnou.
   //
   // Hranice je tím pevná po celou dobu běhu: ROM se nahraje jednou a RAM ji
   // nemá jak přepsat ani po resetu.

   // Sběrnice modulu do sdílené RAM. cs/oe/we jsou aktivní v nule a neaktivní
   // modul drží všechna pole v jedničkách (CART_MEM_IDLE), takže se sběrnice
   // všech modulů slučují prostým AND — aktivní smí být vždy jen jeden.
   typedef struct packed {
      logic [CART_RAM_AW-1:0] addr;
      logic [7:0]             data;      // data k zápisu
      logic                   cs_n;
      logic                   oe_n;
      logic                   we_n;
   } cart_mem_t;

   localparam cart_mem_t CART_MEM_IDLE = '{addr: '1, data: '1,
                                           cs_n: 1'b1, oe_n: 1'b1, we_n: 1'b1};

   // Adresa CPU (16 b) v šířce sdílené RAM.
   //
   // Používat všude, kde se adresa CPU potkává s adresou paměti: doplnění
   // nulami se odvodí z CART_RAM_AW, takže se při změně velikosti RAM nemá
   // co rozejít a Verilator nemá co hlásit. Psát místo toho {1'b0, addr}
   // znamená mít šířku paměti napevno v každém výrazu.
   //
   // Záměrně bez size castu (CART_RAM_AW'(x)) — Quartus 17 ho v některých
   // výrazech nebere. Předpokládá CART_RAM_AW > 16.
   function automatic logic [CART_RAM_AW-1:0] cart_addr(input logic [15:0] a);
      cart_addr = {{(CART_RAM_AW-16){1'b0}}, a};
   endfunction

   // ------------------------------------------------------------------------
   // Řízení simulace z verilogu (trace od určitého okamžiku)
   //
   // Zapnutí ukládání signálů (sim.fst) až v místě, které nás zajímá — trace
   // od začátku je obrovský a pomalý:
   //
   //    if (A == 16'h1234 && !MRD_n) begin
   //       sim_trace(1);            // od teď ukládej
   //       sim_stop_after(20000);   // a za 20000 tiků simulaci zastav
   //    end
   //    if (hotovo)                  sim_trace(0);   // dost, zavři
   //    if (chyba)                   sim_stop();     // zastav hned
   //
   // Tik v sim_stop_after je jeden krok simulátoru, tj. půlperioda CLK_50M —
   // stejná jednotka, v jaké běží čas ve waveformu (takt CPU 3,58 MHz je asi
   // 28 tiků, řádek obrazu asi 3200). 0 zruší naplánované zastavení.
   // Po zastavení se trace flushne, takže je soubor rovnou čitelný, a dál
   // se dá pokračovat tlačítkem v GUI.
   //
   // Ukládání pokračuje do téhož souboru, takže se dá zapínat a vypínat
   // opakovaně; mezi úseky je ve waveformu mezera (signály drží hodnotu).
   // sim_stop() zastaví běh stejně jako tlačítko v GUI, stav zůstane
   // prohlédnutelný.
   //
   // Mimo simulaci (Quartus, testbenche bez +define+SIMULATION) jsou oba
   // tasky prázdné a nic se nesyntetizuje. Modul, který je volá, musí mít
   // `import sordm5_pkg::*` (nebo psát sordm5_pkg::sim_trace(1)).
   //
   // Druhá cesta ke stejnému je časová značka v GUI ("Trace od" v panelu
   // debuggeru, rtl/tstamp_dpi.sv) — ta se zadává časem, tohle podmínkou.
`ifdef SIMULATION
   import "DPI-C" function void sim_trace_set(input int on);
   import "DPI-C" function void sim_stop_req();
   import "DPI-C" function void sim_stop_after_req(input int ticks);
`endif

   task automatic sim_trace(input bit on);
`ifdef SIMULATION
      sim_trace_set(on ? 1 : 0);
`endif
   endtask

   task automatic sim_stop();
`ifdef SIMULATION
      sim_stop_req();
`endif
   endtask

   /* verilator lint_off UNUSEDSIGNAL */
   task automatic sim_stop_after(input int ticks);
`ifdef SIMULATION
      sim_stop_after_req(ticks);
`endif
   endtask
   /* verilator lint_on UNUSEDSIGNAL */

endpackage
