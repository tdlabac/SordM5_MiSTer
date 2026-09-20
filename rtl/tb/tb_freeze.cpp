// Test zmrazení celého počítače (viz tb_freeze.sv).
//
// Instance a: debugger ji zastavuje příkazem stop i breakpointy (zápis do
// RAM 7000h-7FFFh, zápis na porty VDP 10h-1Fh, zapínají se náhodně), drží
// zastavenou náhodný počet taktů, čte paměť převzetím sběrnice (a přečtenou
// hodnotu RAM občas zapíše zpět), krokuje a nahrává registry (DIRSet s REG).
// Instance b běží bez zásahů a dostává takt jen tehdy, když a nestojí.
//
// V každém taktu se porovná video, zvuk a registry, sběrnice CPU mimo
// přístupy debuggeru; na konci celá RAM a VRAM. Navíc:
//   - při zastavení PC v REG = adresa na sběrnici,
//   - DIRSet s REG nezmění REG,
//   - čtení debuggerem vrátí obsah ROM (rom.hex), RAM (z instance b)
//     i cartridge (cart.hex ve sdílené RAM).
//
// Cartridge se nahrává přes ioctl ještě za resetu, stejnou cestou jako
// v jádře — bez toho by modul cartridge zůstal bez rom_size neaktivní.
//
// Prostředí: FZ_CLOCKS (takty instance a, výchozí 6 000 000),
//            FZ_SEED (semínko, výchozí 1), FZ_NOSTOP=1 (bez zastavování).
#include "Vtb_freeze.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <random>
#include <vector>

static Vtb_freeze* t;
static long env(const char* n, long d) { const char* v = getenv(n); return v ? strtol(v, 0, 0) : d; }

static uint32_t getb(const VlWide<7>& w, int lo, int n) {
   uint32_t v = 0;
   for (int k = 0; k < n; k++) v |= ((w[(lo + k) / 32] >> ((lo + k) % 32)) & 1u) << k;
   return v;
}
static bool reg_eq(const VlWide<7>& x, const VlWide<7>& y) {
   for (int k = 0; k < 7; k++) if (x[k] != y[k]) return false;
   return true;
}

// jeden takt clk_sys; b jen když a nestojí
static void tick(bool b_too) {
   t->clk_a = 1; if (b_too) t->clk_b = 1; t->eval();
   t->clk_a = 0; t->clk_b = 0; t->eval();
}

static uint8_t rom[8192];
static void load_rom() {
   FILE* f = fopen("rom.hex", "r");
   for (int i = 0; f && i < 8192; i++) { unsigned v; if (fscanf(f, "%x", &v) == 1) rom[i] = v; }
   if (f) fclose(f);
}

// Cartridge se do sdílené RAM nahrává přes ioctl (index 1), stejně jako
// v jádře — jinak by modul cartridge zůstal bez rom_size neaktivní. Obě
// instance se přitom taktují stejně, zmrazení začne až potom.
static std::vector<uint8_t> cart_img;      // obraz cartridge pro kontrolu čtení

static long download_cart() {
   std::vector<uint8_t>& img = cart_img;
   FILE* f = fopen("cart.hex", "r");
   for (unsigned v; f && fscanf(f, "%x", &v) == 1; ) img.push_back((uint8_t)v);
   if (f) fclose(f);
   if (img.empty()) return 0;

   t->io_download = 1;
   tick(true);
   for (size_t a = 0; a < img.size(); a++) {
      t->io_addr = (uint32_t)a; t->io_data = img[a]; t->io_wr = 1;
      tick(true);
      t->io_wr = 0;
      tick(true);
   }
   t->io_download = 0;
   tick(true);
   return (long)img.size();
}

int main(int argc, char** argv) {
   Verilated::commandArgs(argc, argv);
   t = new Vtb_freeze;
   load_rom();
   const long clocks = env("FZ_CLOCKS", 6000000);
   const bool nostop = env("FZ_NOSTOP", 0);
   std::mt19937 rng((uint32_t)env("FZ_SEED", 1));
   auto chance = [&](int n) { return (int)(rng() % (uint32_t)n) == 0; };

   t->clk_a = 0; t->clk_b = 0; t->eval();
   t->reset = 1;
   for (int i = 0; i < 20; i++) tick(true);
   const long cart_len = download_cart();   // ještě v resetu, ať čas počítače začne od nuly
   t->reset = 0;

   long common = 0, frozen = 0, stops = 0, bp_stops = 0, steps = 0, dirsets = 0;
   long reads = 0, writes = 0, read_bad = 0, pc_bad = 0, dirset_bad = 0;
   long vsyncs = 0, intas = 0; int prev_vs = 1; bool prev_inta = false;

   // stav řízení debuggeru
   enum { RUN, WAIT_STOP, HOLD, MEM_WAIT } st = RUN;
   int hold = 0, steps_left = 0, reads_left = 0, mem_wait = 0;
   bool did_dirset = false, bp_on[2] = {false, false};
   uint16_t m_addr = 0; bool m_we = false;
   bool busy_d = false;

   auto set_bp = [&](int i, int kind, uint16_t addr, uint16_t amask) {
      t->bp_we = 1; t->bp_sel = i; t->bp_kind = kind; t->bp_addr = addr; t->bp_amask = amask;
   };

   for (long i = 0; i < clocks; i++) {
      // --- řízení debuggeru (vstupy před hranou)
      t->c_stop = t->c_run = t->c_step = t->c_dirset = t->c_mem_req = 0;
      t->bp_we = 0;
      if (!nostop && i % 100000 == 50000) {                   // breakpointy náhodně zap/vyp
         int k = rng() % 2; bp_on[k] = !bp_on[k];
         if (k == 0) set_bp(0, bp_on[0] ? 4 : 0, 0x7000, 0xF000);   // MWR 7000h-7FFFh
         else        set_bp(1, bp_on[1] ? 16 : 0, 0x0010, 0x00F0); // IOWR porty 10h-1Fh
      }
      switch (st) {
      case RUN:
         if (!nostop && chance(20000)) { t->c_stop = 1; }
         if (t->a_stopped) st = WAIT_STOP;                     // zastavil breakpoint
         else if (t->c_stop) st = WAIT_STOP;
         break;
      case WAIT_STOP:
         if (t->a_stopped) {
            int why = t->a_reason;
            if (why == 2) steps++; else if (why >= 3) bp_stops++; else stops++;
            if (getb(t->a_reg, 64, 16) != t->a_addr) pc_bad++;
            if (why != 2) steps_left = chance(3) ? 1 + rng() % 6 : 0;
            hold = rng() % 40; reads_left = rng() % 6; did_dirset = false;
            st = HOLD;
         }
         break;
      case HOLD:
         if (reads_left > 0) {
            reads_left--;
            m_we = false;
            m_addr = chance(2) ? (uint16_t)(0x7000 + rng() % 0x1000)
                   : chance(2) ? (uint16_t)(0x2000 + rng() % 0x2000)   // cartridge
                               : (uint16_t)rng();
            t->c_mem_req = 1; t->c_mem_we = 0; t->c_mem_addr = m_addr;
            mem_wait = 2; st = MEM_WAIT; reads++;
         } else if (!did_dirset && chance(4)) {
            t->c_dir = t->a_reg; t->c_dirset = 1; did_dirset = true; dirsets++;
         } else if (hold > 0) {
            hold--;
         } else if (steps_left > 0) {
            steps_left--; t->c_step = 1; st = WAIT_STOP;
         } else {
            t->c_run = 1; st = RUN;
         }
         break;
      case MEM_WAIT:
         if (mem_wait > 0) { mem_wait--; break; }
         if (t->a_busy) break;
         if (!m_we) {
            // kontrola přečtené hodnoty: ROM z rom.hex, RAM z instance b
            uint8_t got = t->a_rdata;
            int want = -1;
            if (m_addr < 0x2000) want = rom[m_addr];
            if (m_addr >= 0x2000 && m_addr < 0x2000 + (int)cart_img.size())
               want = cart_img[m_addr - 0x2000];       // cartridge ze sdílené RAM
            if (m_addr >= 0x7000 && m_addr < 0x8000) {   // RAM; 8000h+ nic nečte (FF)
               t->peek_a = m_addr & 0x0FFF; t->eval(); want = t->b_ram;
            }
            if (want >= 0 && got != want) {
               if (read_bad < 8) printf("  čtení %04X: %02X, čekáno %02X\n", m_addr, got, want);
               read_bad++;
            }
            if (m_addr >= 0x7000 && m_addr < 0x8000) {
               if (chance(2)) {                                // zápis stejné hodnoty zpět
                  m_we = true;
                  t->c_mem_req = 1; t->c_mem_we = 1; t->c_mem_addr = m_addr; t->c_mem_wdata = got;
                  mem_wait = 2; writes++;
                  break;
               }
            }
         }
         st = HOLD;
         break;
      }

      bool b_too = !t->a_stopped;          // freeze a platí pro tuto hranu
      VlWide<7> reg_before; for (int k = 0; k < 7; k++) reg_before[k] = t->a_reg[k];
      bool was_dirset = t->c_dirset;
      tick(b_too);
      if (b_too) common++; else frozen++;

      if (was_dirset && !reg_eq(reg_before, t->a_reg)) dirset_bad++;

      bool inta = (t->b_ctl & 0x28) == 0;   // M1 && IORQ = potvrzení přerušení
      if (inta && !prev_inta) intas++;
      prev_inta = inta;
      int vs = (t->b_sync >> 5) & 1;
      if (!vs && prev_vs) vsyncs++;
      prev_vs = vs;

      // --- porovnání a proti b (sběrnice ne během přístupu debuggeru)
      bool bus_cmp = !t->a_busy && !busy_d;
      busy_d = t->a_busy;
      bool diff = t->a_rgb != t->b_rgb || t->a_sync != t->b_sync || t->a_audio != t->b_audio ||
                  !reg_eq(t->a_reg, t->b_reg) || t->a_ts != t->b_ts ||
                  (bus_cmp && (t->a_addr != t->b_addr || t->a_do != t->b_do || t->a_di != t->b_di ||
                               t->a_ctl != t->b_ctl));
      if (diff) {
         printf("\nROZDIL v taktu a %ld (společných %ld, zmrazených %ld, a %s, busy %d)\n",
                i, common, frozen, t->a_stopped ? "stojí" : "běží", t->a_busy);
         printf("  rgb %06X/%06X sync %02X/%02X audio %04X/%04X\n", t->a_rgb, t->b_rgb,
                t->a_sync, t->b_sync, t->a_audio, t->b_audio);
         printf("  A %04X/%04X DO %02X/%02X DI %02X/%02X ctl %02X/%02X reg %s\n", t->a_addr, t->b_addr,
                t->a_do, t->b_do, t->a_di, t->b_di, t->a_ctl, t->b_ctl,
                reg_eq(t->a_reg, t->b_reg) ? "stejné" : "RŮZNÉ");
         printf("  PC %04X/%04X  čas %llu/%llu\n", getb(t->a_reg, 64, 16), getb(t->b_reg, 64, 16),
                (unsigned long long)t->a_ts, (unsigned long long)t->b_ts);
         printf("\nNEPROSLO\n");
         delete t; return 1;
      }
   }

   // --- paměti na konci
   int mem_bad = 0, vram_used = 0;
   for (int a = 0; a < 16384; a++) {
      t->peek_a = a; t->eval();
      if (a < 4096 && t->a_ram != t->b_ram) mem_bad++;
      if (t->a_vram != t->b_vram) mem_bad++;
      if (t->b_vram) vram_used++;
   }

   int fails = 0;
   printf("Taktů a %ld: společných %ld, zmrazených %ld; snímků (VSYNC) %ld\n", clocks, common, frozen, vsyncs);
   printf("Zastavení: stop %ld, breakpoint %ld, kroků %ld; DIRSet %ld; čtení %ld, zápisů zpět %ld\n",
          stops, bp_stops, steps, dirsets, reads, writes);
   printf("Přerušení %ld, nenulových bajtů VRAM %d; čas počítače na konci %llu (a = b)\n", intas, vram_used,
          (unsigned long long)t->a_ts);
   bool ts_ok = t->a_ts == t->b_ts && t->a_ts > (uint64_t)(common / 6 - 10) && t->a_ts <= (uint64_t)(common / 6 + 10);
   printf("  %-52s %s\n", "čas = společné takty / 6 (zmrazení se nepočítá)", ts_ok ? "OK" : "CHYBA");
   fails += !ts_ok;
   printf("  %-52s %s (%ld)\n", "PC v REG = adresa na sběrnici při zastavení", pc_bad ? "CHYBA" : "OK", pc_bad);   fails += pc_bad != 0;
   printf("  %-52s %s (%ld)\n", "DIRSet s REG nezmění REG", dirset_bad ? "CHYBA" : "OK", dirset_bad);           fails += dirset_bad != 0;
   printf("  %-52s %s (%ld)\n", "čtení debuggerem = obsah ROM a RAM", read_bad ? "CHYBA" : "OK", read_bad);      fails += read_bad != 0;
   printf("  %-52s %s (%d)\n",  "RAM a VRAM na konci shodné", mem_bad ? "CHYBA" : "OK", mem_bad);                 fails += mem_bad != 0;
   printf("Cartridge: nahráno %ld B přes ioctl, rom_size v jádře %04X\n",
          cart_len, (unsigned)t->a_rom_size);
   bool cart_ok = (long)t->a_rom_size == cart_len;
   printf("  %-52s %s\n", "cartridge: rom_size = délka souboru", cart_ok ? "OK" : "CHYBA");   fails += !cart_ok;
   bool alive = intas > 2 && vram_used > 100;
   printf("  %-52s %s\n", "počítač běží (přerušení, zápisy do VRAM)", alive ? "OK" : "CHYBA");                   fails += !alive;
   bool enough = nostop || (stops > 20 && bp_stops > 20 && steps > 20 && dirsets > 10 && reads > 50 && writes > 10);
   printf("  %-52s %s\n", "dost zastavení, breakpointů, kroků, DIRSet, přístupů", enough ? "OK" : "CHYBA");       fails += !enough;
   printf("  %-52s %s\n", "video, zvuk, sběrnice, registry v každém taktu", "OK");

   printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails);
   delete t;
   return fails ? 1 : 0;
}
