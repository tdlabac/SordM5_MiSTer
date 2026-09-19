// Test zmrazení celého počítače (viz tb_freeze.sv).
//
// Instance a: debugger ji náhodně zastavuje na hranici instrukce, drží
// zastavenou náhodný počet taktů, krokuje po instrukcích a nahrává registry
// (DIRSet s vlastním REG). Instance b běží bez zásahů a dostává takt jen
// tehdy, když a nestojí. V každém taktu se porovná video, zvuk, sběrnice CPU
// a registry, na konci celá RAM a VRAM.
//
// Navíc se při každém zastavení kontroluje, že PC v REG = adresa na sběrnici
// (CPU stojí na začátku fetche) a že DIRSet s REG nic nezmění.
//
// Prostředí: FZ_CLOCKS (takty instance a, výchozí 6 000 000),
//            FZ_SEED (semínko, výchozí 1), FZ_NOSTOP=1 (bez zastavování).
#include "Vtb_freeze.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <random>

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

int main(int argc, char** argv) {
   Verilated::commandArgs(argc, argv);
   t = new Vtb_freeze;
   const long clocks = env("FZ_CLOCKS", 6000000);
   const bool nostop = env("FZ_NOSTOP", 0);
   std::mt19937 rng((uint32_t)env("FZ_SEED", 1));
   auto chance = [&](int n) { return (int)(rng() % (uint32_t)n) == 0; };

   t->clk_a = 0; t->clk_b = 0; t->eval();
   t->reset = 1; t->dbg_stop = 0; t->dbg_step = 0; t->dbg_dirset = 0;
   for (int i = 0; i < 20; i++) tick(true);
   t->reset = 0;

   long common = 0, frozen = 0, stops = 0, steps = 0, dirsets = 0, pc_bad = 0, dirset_bad = 0;
   long vsyncs = 0, intas = 0; int prev_vs = 1; bool prev_inta = false;
   uint32_t pcs_seen = 0;

   // stav řízení debuggeru
   enum { RUN, WANT_STOP, HOLD, STEP_WAIT } st = RUN;
   int hold = 0, steps_left = 0;
   bool did_dirset = false;

   for (long i = 0; i < clocks; i++) {
      // --- řízení debuggeru (vstupy před hranou)
      t->dbg_step = 0; t->dbg_dirset = 0;
      switch (st) {
      case RUN:
         if (!nostop && chance(20000)) { t->dbg_stop = 1; st = WANT_STOP; }
         break;
      case WANT_STOP:
      case STEP_WAIT:
         if (t->a_stopped) {
            stops += (st == WANT_STOP); steps += (st == STEP_WAIT);
            // při zastavení: PC = adresa na sběrnici
            if (getb(t->a_reg, 64, 16) != t->a_addr) pc_bad++;
            pcs_seen++;
            if (st == WANT_STOP) steps_left = chance(3) ? 1 + rng() % 6 : 0;
            hold = rng() % 40; did_dirset = false;
            st = HOLD;
         }
         break;
      case HOLD:
         if (!did_dirset && chance(4)) {
            t->dbg_dir = t->a_reg; t->dbg_dirset = 1; did_dirset = true; dirsets++;
         } else if (hold > 0) {
            hold--;
         } else if (steps_left > 0) {
            steps_left--; t->dbg_step = 1; st = STEP_WAIT;
         } else {
            t->dbg_stop = 0; st = RUN;
         }
         break;
      }

      bool b_too = !t->a_stopped;          // freeze a platí pro tuto hranu
      VlWide<7> reg_before; for (int k = 0; k < 7; k++) reg_before[k] = t->a_reg[k];
      bool was_dirset = t->dbg_dirset;
      tick(b_too);
      if (b_too) common++; else frozen++;

      if (was_dirset && !reg_eq(reg_before, t->a_reg)) dirset_bad++;

      bool inta = (t->b_ctl & 0x28) == 0;   // M1 && IORQ = potvrzení přerušení
      if (inta && !prev_inta) intas++;
      prev_inta = inta;
      int vs = (t->b_sync >> 5) & 1;
      if (!vs && prev_vs) vsyncs++;
      prev_vs = vs;

      // --- porovnání a proti b
      bool diff = t->a_rgb != t->b_rgb || t->a_sync != t->b_sync || t->a_audio != t->b_audio ||
                  t->a_addr != t->b_addr || t->a_do != t->b_do || t->a_di != t->b_di ||
                  t->a_ctl != t->b_ctl || !reg_eq(t->a_reg, t->b_reg);
      if (diff) {
         printf("\nROZDIL v taktu a %ld (společných %ld, zmrazených %ld, a %s)\n",
                i, common, frozen, t->a_stopped ? "stojí" : "běží");
         printf("  rgb %06X/%06X sync %02X/%02X audio %04X/%04X\n", t->a_rgb, t->b_rgb,
                t->a_sync, t->b_sync, t->a_audio, t->b_audio);
         printf("  A %04X/%04X DO %02X/%02X DI %02X/%02X ctl %02X/%02X reg %s\n", t->a_addr, t->b_addr,
                t->a_do, t->b_do, t->a_di, t->b_di, t->a_ctl, t->b_ctl,
                reg_eq(t->a_reg, t->b_reg) ? "stejné" : "RŮZNÉ");
         printf("  PC %04X/%04X\n", getb(t->a_reg, 64, 16), getb(t->b_reg, 64, 16));
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
   printf("Zastavení %ld, kroků %ld, DIRSet %ld; přerušení %ld, nenulových bajtů VRAM %d\n",
          stops, steps, dirsets, intas, vram_used);
   printf("  %-52s %s (%ld)\n", "PC v REG = adresa na sběrnici při zastavení", pc_bad ? "CHYBA" : "OK", pc_bad);   fails += pc_bad != 0;
   printf("  %-52s %s (%ld)\n", "DIRSet s REG nezmění REG", dirset_bad ? "CHYBA" : "OK", dirset_bad);           fails += dirset_bad != 0;
   printf("  %-52s %s (%d)\n",  "RAM a VRAM na konci shodné", mem_bad ? "CHYBA" : "OK", mem_bad);                 fails += mem_bad != 0;
   bool enough = nostop || (stops > 20 && steps > 20 && dirsets > 10);
   bool alive = intas > 2 && vram_used > 100;
   printf("  %-52s %s\n", "počítač běží (přerušení, zápisy do VRAM)", alive ? "OK" : "CHYBA");                 fails += !alive;
   printf("  %-52s %s\n", "dost zastavení, kroků a DIRSet", enough ? "OK" : "CHYBA");                            fails += !enough;
   printf("  %-52s %s\n", "video, zvuk, sběrnice, registry v každém taktu", "OK");

   printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails);
   delete t;
   return fails ? 1 : 0;
}
