// Test cartridge None, EM32 a EM64 (tb_cart.sv) proti pravidlům z jejich
// hlaviček:
//
//   None: bez ROM neaktivní; ROM do 5000h se mapuje od 2000h podle své délky,
//         nad ní FFh; delší ROM cartridge vypne; ROM > 8 kB zapne 4 kB RAM
//         na 8000h, jinak na 8000h nic není.
//   EM32: totéž, ale RAM má 32 kB na 8000h-FFFFh a je i bez ROM; příliš
//         dlouhá ROM vypne celou cartridge včetně RAM.
//   EM64: viz níž.
//
// RAM a ROM sdílí jednu BRAM, proto se kontroluje i to, že zápis do RAM
// nepřepíše ROM (RAM leží za ní, zarovnaná na 4 kB).
//
// EM64 — pravidla, proti kterým se tu měří (rtl/EXT/carts/cart_em64.sv):
//
//   OUT (6Ch),1 zapne ROMDS (odpojí ROM), OUT (6Ch),0 ho vypne. Jiné porty
//   z prostoru EXIOA (60h-6Fh) i porty mimo něj se cartridge netýkají.
//   Bez ROMDS je cartridge obyčejná ROM od 2000h + RAM na 8000h-FFFFh.
//
//   Autostart (opt[1]) říká, jaký je ROMDS po resetu.
//   Mode (opt[2]): 0 = EM64 — s ROMDS je RAM i dole (0000-6FFFh),
//                  1 = EM32 — RAM je vždy jen 8000h-FFFFh.
//   Monitor protect (opt[3]): 1 = monitor na 0000-1FFF zůstává a cartridge
//                  se tam vůbec neozve; 0 = monitor se odpojí (ROM0_ovrd_n)
//                  a na 0000-1FFF je RAM cartridge.
//   WP monitor (opt[0]): 1 = 0000-1FFF je jen pro čtení.
//
//   7000h-7FFFh patří vždy interní RAM M5 (rtl/GA015/ga015.sv), cartridge
//   tam nesahá. Ve sdílené BRAM leží ROM na 0-4FFFh a RAM od 5000h.
#include "Vtb_cart.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static Vtb_cart* t;
static int fails = 0;

static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }

static void check(const char* name, bool ok, const char* fmt = "", ...) {
   char b[200] = "";
   va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
   printf("  %-58s %s %s\n", name, ok ? "OK  " : "CHYBA", b);
   if (!ok) fails++;
}

// obsah ROM: bajt na adrese a je a xor 5A
static uint8_t rom_byte(uint32_t a) { return (uint8_t)((a ^ 0x5A) & 0xFF); }

static void bus_idle() {
   t->mreq_n = 1; t->rd_n = 1; t->wr_n = 1; t->iowr_n = 1; t->A = 0; t->D_o = 0xFF;
   tick();
}

static uint8_t mem_rd(uint16_t a) {
   t->A = a; t->mreq_n = 0; t->rd_n = 0; t->wr_n = 1;
   tick(); tick();                      // q z BRAM je registrované
   uint8_t v = t->D_i;
   bus_idle();
   return v;
}

static void mem_wr(uint16_t a, uint8_t d) {
   t->A = a; t->D_o = d; t->mreq_n = 0; t->rd_n = 1; t->wr_n = 0;
   tick(); tick();
   bus_idle();
}

// Zápis na I/O port (OUT (port),d). Adresu dekóduje tb_cart.sv stejně jako
// GA015: EXIOA_n platí pro 60h-6Fh.
static void io_out(uint8_t port, uint8_t d) {
   t->A = port; t->D_o = d; t->iowr_n = 0;
   tick(); tick();
   bus_idle();
}

// Reset cartridge s danými volbami (autostart se bere až při resetu).
static void reset_cart(uint16_t opt) {
   t->cart_opt = opt;
   t->rst_n = 0; tick(); tick(); tick();
   t->rst_n = 1;
   bus_idle();
}

static bool ram_holds(uint16_t a, uint8_t v) { mem_wr(a, v); return mem_rd(a) == v; }
static bool reads_ff(uint16_t a) { return mem_rd(a) == 0xFF; }

// Nahrání ROM přes ioctl (index 1 = F1), soubor začíná na adrese 0.
static void load_rom(uint32_t size) {
   t->io_index = 1; t->io_download = 1; t->io_addr = 0; t->io_wr = 0;
   tick();
   for (uint32_t a = 0; a < size; a++) {
      t->io_addr = a; t->io_data = rom_byte(a); t->io_wr = 1; tick();
      t->io_wr = 0; tick();
   }
   t->io_download = 0;
   bus_idle();
}

struct Cart { const char* name; int sel; uint32_t ram_size; uint16_t ram_base; };

// Projde pravidla pro jeden modul a jednu velikost ROM.
static void test_rom(const Cart& c, uint32_t size, bool valid, bool ram_on) {
   load_rom(size);
   t->cart_sel = c.sel;
   char tag[80];

   // 1. ROM se čte do své délky, za ní FFh
   int bad = 0, bad_over = 0;
   if (valid) {
      for (uint32_t off = 0; off < size; off += (size > 64 ? size / 37 : 1))
         if (mem_rd((uint16_t)(0x2000 + off)) != rom_byte(off)) bad++;
      // první bajt za ROM (pokud ještě padne do prostoru cartridge)
      if (0x2000 + size <= 0x7FFF && mem_rd((uint16_t)(0x2000 + size)) != 0xFF) bad_over++;
   } else {
      for (uint32_t off = 0; off < 0x5000; off += 0x800)
         if (mem_rd((uint16_t)(0x2000 + off)) != 0xFF) bad++;
   }
   snprintf(tag, sizeof tag, "%s, ROM %04Xh: %s", c.name, size,
            valid ? "mapuje se podle délky" : "neplatná, cartridge mlčí");
   check(tag, bad == 0 && bad_over == 0, "(chyb %d, za ROM %d)", bad, bad_over);

   // 2. RAM na 8000h
   bool ram_ok = true;
   if (ram_on) {
      for (uint32_t off = 0; off < c.ram_size; off += (c.ram_size / 9)) {
         uint16_t a = (uint16_t)(c.ram_base + off);
         mem_wr(a, (uint8_t)(off ^ 0xA5));
         if (mem_rd(a) != (uint8_t)(off ^ 0xA5)) ram_ok = false;
      }
      // poslední bajt RAM
      uint16_t last = (uint16_t)(c.ram_base + c.ram_size - 1);
      mem_wr(last, 0x3C);
      if (mem_rd(last) != 0x3C) ram_ok = false;
   } else {
      ram_ok = mem_rd(c.ram_base) == 0xFF;
      mem_wr(c.ram_base, 0x12);
      ram_ok = ram_ok && mem_rd(c.ram_base) == 0xFF;
   }
   snprintf(tag, sizeof tag, "%s, ROM %04Xh: RAM na %04Xh %s", c.name, size, c.ram_base,
            ram_on ? "drží zápisy" : "není");
   check(tag, ram_ok);

   // 3. zápisy do RAM nesmí poškodit ROM (sdílená BRAM)
   if (valid && ram_on) {
      int rom_bad = 0;
      for (uint32_t off = 0; off < size; off += (size > 64 ? size / 37 : 1))
         if (mem_rd((uint16_t)(0x2000 + off)) != rom_byte(off)) rom_bad++;
      snprintf(tag, sizeof tag, "%s, ROM %04Xh: zápisy do RAM nepřepsaly ROM", c.name, size);
      check(tag, rom_bad == 0, "(chyb %d)", rom_bad);
   }
}

int main(int argc, char** argv) {
   Verilated::commandArgs(argc, argv);
   setvbuf(stdout, nullptr, _IONBF, 0);
   t = new Vtb_cart;
   t->cart_opt = 0;
   t->rst_n = 1;
   bus_idle();

   const Cart none = {"None", 0, 0x1000, 0x8000};
   const Cart em32 = {"EM32", 1, 0x8000, 0x8000};

   printf("=== None ===\n");
   // bez ROM: nic
   t->cart_sel = none.sel;
   check("None, bez ROM: prostor cartridge i 8000h vrací FFh",
         mem_rd(0x2000) == 0xFF && mem_rd(0x8000) == 0xFF && t->rom_size == 0);

   test_rom(none, 0x2000, true,  false);   // 8 kB: jen ROM, RAM ne
   test_rom(none, 0x2001, true,  true);    // o bajt víc: RAM se zapne
   test_rom(none, 0x5000, true,  true);    // největší povolená ROM
   test_rom(none, 0x5001, false, false);   // o bajt delší: neplatná

   printf("\n=== EM32 ===\n");
   t->cart_sel = em32.sel;
   load_rom(0);
   check("EM32, bez ROM: ROM mlčí, ale RAM je",
         mem_rd(0x2000) == 0xFF);
   {
      bool ok = true;
      mem_wr(0x8000, 0x77); ok = ok && mem_rd(0x8000) == 0x77;
      mem_wr(0xFFFF, 0x88); ok = ok && mem_rd(0xFFFF) == 0x88;
      check("EM32, bez ROM: RAM 8000h-FFFFh drží zápisy", ok);
   }

   test_rom(em32, 0x2000, true,  true);
   test_rom(em32, 0x5000, true,  true);
   test_rom(em32, 0x5001, false, false);   // neplatná ROM vypne i RAM

   // Pevné rozložení BRAM: ROM 0-4FFFh, RAM od 5000h. Delší soubor se do RAM
   // nesmí nahrát a reset nesmí ROM ani její délku ztratit.
   {
      t->cart_sel = em32.sel;
      load_rom(0x2000);
      mem_wr(0x8000, 0xC3); mem_wr(0xFFFF, 0x3C);

      load_rom(0x5100);                       // delší než povolená ROM
      check("EM32, soubor delší než 5000h: cartridge se neaktivuje",
            t->rom_size == 0x1FFFF && reads_ff(0x2000) && reads_ff(0x8000));

      load_rom(0x2000);                       // znovu platná ROM
      check("EM32, dlouhý soubor nesáhl do RAM za 5000h",
            mem_rd(0x8000) == 0xC3 && mem_rd(0xFFFF) == 0x3C);

      int bad = 0;
      reset_cart(0);
      for (uint32_t off = 0; off < 0x2000; off += 0x137)
         if (mem_rd((uint16_t)(0x2000 + off)) != rom_byte(off)) bad++;
      check("EM32, reset nesmaže ROM ani její délku",
            bad == 0 && t->rom_size == 0x2000 && mem_rd(0x8000) == 0xC3,
            "(chyb %d)", bad);

      // Hranici hlásí modul vybraný z menu (rom_max), ne ext_bus — zkouška
      // s jiným modulem, RAM EM32 to nesmí poznat.
      t->cart_sel = 3;                        // BRNO
      load_rom(0x5100);
      t->cart_sel = em32.sel;
      load_rom(0x2000);
      check("Loader se řídí rom_max vybraného modulu",
            mem_rd(0x8000) == 0xC3 && mem_rd(0xFFFF) == 0x3C);
   }

   // ---------------------------------------------------------------- EM64
   const uint16_t WP    = 1 << 0;   // WP monitor:     0000-1FFF jen pro čtení
   const uint16_t AUTO  = 1 << 1;   // Autostart:      ROMDS hned po resetu
   const uint16_t EM32M = 1 << 2;   // Mode:           1 = EM32 (dole nic)
   const uint16_t MPROT = 1 << 3;   // Monitor protect:1 = monitor zůstává

   printf("\n=== EM64 ===\n");
   t->cart_sel = 2;
   load_rom(0x2000);

   // 1. bez ROMDS je to obyčejná ROM cartridge + RAM nahoře
   reset_cart(0);
   check("EM64, po resetu bez autostartu: ROMDS neaktivní",
         t->ROMDS_n == 1 && t->ROM0_ovrd_n == 0);
   {
      int bad = 0;
      for (uint32_t off = 0; off < 0x2000; off += 0x137)
         if (mem_rd((uint16_t)(0x2000 + off)) != rom_byte(off)) bad++;
      check("EM64, bez ROMDS: ROM se čte od 2000h", bad == 0, "(chyb %d)", bad);
   }
   check("EM64, bez ROMDS: 0000-1FFF patří monitoru",
         t->ROM0_ovrd_n == 0 && reads_ff(0x0000) && reads_ff(0x1FFF));
   check("EM64, bez ROMDS: RAM 8000h-FFFFh drží zápisy",
         ram_holds(0x8000, 0x11) && ram_holds(0xFFFF, 0x22));

   // 2. autostart = stav ROMDS po resetu
   reset_cart(AUTO);
   check("EM64, autostart On: po resetu je ROMDS aktivní", t->ROMDS_n == 0);
   reset_cart(0);
   check("EM64, autostart Off: po resetu je ROMDS neaktivní", t->ROMDS_n == 1);

   // 3. přepínání portem 6Ch
   io_out(0x6C, 1);
   check("EM64, OUT (6Ch),1 zapne ROMDS", t->ROMDS_n == 0);
   io_out(0x6C, 0);
   check("EM64, OUT (6Ch),0 vypne ROMDS", t->ROMDS_n == 1);
   io_out(0x6C, 1);
   io_out(0x68, 0);
   check("EM64, OUT (68h) se cartridge netýká", t->ROMDS_n == 0);
   io_out(0x7C, 0);
   check("EM64, OUT (7Ch) mimo EXIOA se cartridge netýká", t->ROMDS_n == 0);

   // 4. režim EM64 + chráněný monitor: RAM dole od 2000h, monitor zůstává
   reset_cart(MPROT);
   io_out(0x6C, 1);
   check("EM64+ROMDS: místo ROM je od 2000h RAM",
         ram_holds(0x2000, 0x5A) && ram_holds(0x6FFF, 0xA5));
   check("EM64+ROMDS: 7000-7FFF patří interní RAM M5",
         reads_ff(0x7000) && reads_ff(0x7FFF));
   check("EM64+ROMDS, monitor protect On: 0000-1FFF zůstává monitoru",
         t->ROM0_ovrd_n == 0 && reads_ff(0x0000) && reads_ff(0x1FFF));
   check("EM64+ROMDS: RAM 8000h-FFFFh dál drží zápisy", ram_holds(0x9000, 0x33));

   // 5. monitor protect Off: monitor se odpojí a dole je RAM cartridge
   reset_cart(0);
   io_out(0x6C, 1);
   check("EM64+ROMDS, monitor protect Off: monitor odpojen", t->ROM0_ovrd_n == 1);
   check("EM64+ROMDS, monitor protect Off: RAM i na 0000-1FFF",
         ram_holds(0x0000, 0x12) && ram_holds(0x1FFF, 0x34));

   // 6. WP monitor (volba platí hned, bez resetu)
   t->cart_opt = WP;
   mem_wr(0x0000, 0xEE); mem_wr(0x1FFF, 0xEE);
   check("EM64, WP monitor On: zápis do 0000-1FFF neprojde",
         mem_rd(0x0000) == 0x12 && mem_rd(0x1FFF) == 0x34);
   check("EM64, WP monitor On: 2000h a výš se zapisovat dá", ram_holds(0x2000, 0x99));
   t->cart_opt = 0;
   check("EM64, WP monitor Off: zápis do 0000-1FFF zase projde",
         ram_holds(0x0000, 0x56));

   // 7. režim EM32: dole nic ani se zapnutým ROMDS
   reset_cart(EM32M);
   io_out(0x6C, 1);
   check("EM64 v režimu EM32: 0000-6FFF mlčí i s ROMDS",
         reads_ff(0x0000) && reads_ff(0x2000) && reads_ff(0x6FFF));
   check("EM64 v režimu EM32: monitor se neodpojuje", t->ROM0_ovrd_n == 0);
   check("EM64 v režimu EM32: RAM 8000h-FFFFh funguje", ram_holds(0x8000, 0x77));

   // 8. po vypnutí ROMDS je ROM zpátky a zápisy do RAM ji nepoškodily
   reset_cart(0);
   {
      int bad = 0;
      for (uint32_t off = 0; off < 0x2000; off += 0x137)
         if (mem_rd((uint16_t)(0x2000 + off)) != rom_byte(off)) bad++;
      check("EM64, po vypnutí ROMDS je ROM zpět a nepoškozená", bad == 0, "(chyb %d)", bad);
   }

   // 9. bez ROM je to pořád paměťové rozšíření
   load_rom(0);
   reset_cart(0);
   check("EM64, bez ROM: 2000h mlčí, RAM nahoře funguje",
         reads_ff(0x2000) && ram_holds(0x8000, 0x44) && t->rom_size == 0);
   io_out(0x6C, 1);
   check("EM64, bez ROM + ROMDS: RAM i dole", ram_holds(0x2000, 0x66));

   printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails);
   delete t;
   return fails ? 1 : 0;
}
