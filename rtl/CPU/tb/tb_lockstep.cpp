// Lockstep test TV80 — upravený procesor proti zmrazené kopii (viz tb_lockstep.sv).
//
// Pro každé semínko:
//   - 64 kB paměti náhodně (program i data jsou náhodné bajty),
//   - náhodné INT (drží se do potvrzení), NMI pulzy, WAIT a BUSRQ,
//   - v každém taktu clk_sys porovná A, DO a všechny řídicí výstupy.
// Při prvním rozdílu vypíše posledních 24 taktů obou procesorů a skončí.
// Na konci ukáže pokrytí opkódů (kolik různých opkódů se v každé tabulce
// opravdu provedlo), aby bylo vidět, že náhodný program instrukce prošel.
//
// Parametry z prostředí: LS_SEEDS (počet semínek, výchozí 16),
// LS_CLOCKS (taktů na semínko, výchozí 2 000 000), LS_SEED0 (první semínko),
// LS_MODE:
//   0  běh bez zásahů (výchozí)
//   1  na každé hranici instrukce zmrazí CE obou procesorů na 1..8 taktů
//      (zmrazení nesmí nic změnit)
//   2  jako 1 a během zmrazení DUT dostane DIRSet s vlastním REG
//      (zápis beze změny nesmí nic změnit: REG je úplný a DIRSet nemá
//      vedlejší účinky)
// Hranice instrukce = M1, TState 2, Prefix 0 (doc/z80-debugger.md).
#include "Vtb_lockstep.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <random>

static Vtb_lockstep* t;
static uint64_t clk = 0;

static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); ++clk; }

struct Snap { uint64_t clk; uint16_t da, ra; uint8_t ddo, rdo, dctl, rctl, di; };
static Snap hist[24]; static int hpos = 0;

static const char* ctl_str(uint8_t c, char* b) {
   // {M1,MREQ,IORQ,RD,WR,RFSH,HALT,BUSAK}_n, velké písmeno = aktivní (0)
   const char* n = "MQIRWFHB";
   for (int i = 0; i < 8; i++) b[i] = (c >> (7 - i)) & 1 ? '.' : n[i];
   b[8] = 0; return b;
}

static long env(const char* n, long d) { const char* v = getenv(n); return v ? strtol(v, 0, 0) : d; }

int main(int argc, char** argv) {
   Verilated::commandArgs(argc, argv);
   t = new Vtb_lockstep;
   t->clk = 0; t->eval();        // první eval je inicializace, hranu by nechytil

   const long seeds  = env("LS_SEEDS", 16);
   const long clocks = env("LS_CLOCKS", 2000000);
   const long seed0  = env("LS_SEED0", 1);
   const long mode   = env("LS_MODE", 0);
   long stops = 0;

   // pokrytí: 0 = základní, 1 = CB, 2 = ED, 3 = DD/FD
   static bool seen[4][256];
   long ints = 0, nmis = 0, waits = 0, busrqs = 0, fetches = 0, halts = 0;

   for (long s = seed0; s < seed0 + seeds; s++) {
      std::mt19937 rng((uint32_t)s);
      auto chance = [&](int n) { return (int)(rng() % (uint32_t)n) == 0; };

      t->run = 1; t->dirset = 0;
      t->rst_n = 0; t->int_n = 1; t->nmi_n = 1; t->wait_n = 1; t->busrq_n = 1; t->vec = 0xFF;
      for (int a = 0; a < 65536; a++) {
         // HALT (76h) jen v 1/16 výskytů, jinak by náhodný program většinu času stál
         uint8_t b = (uint8_t)rng();
         if (b == 0x76 && !chance(16)) b = 0x00;
         t->mem_we = 1; t->mem_a = a; t->mem_d = b; tick();
      }
      t->mem_we = 0;
      for (int i = 0; i < 60; i++) tick();
      t->rst_n = 1;

      int int_hold = 0, nmi_left = 0, wait_left = 0, busrq_left = 0;
      int page = 0; bool in_fetch = false; uint8_t last_di = 0;
      int frozen = 0, dirset_at = -1; bool prev_bnd = false;

      for (long i = 0; i < clocks; i++) {
         // --- náhodné vstupy
         if (t->int_n) { if (chance(4000)) { t->int_n = 0; t->vec = (uint8_t)rng(); int_hold = 0; ints++; } }
         else if (++int_hold > 3000 || ((t->d_ctl & 0xA0) == 0)) t->int_n = 1;   // M1 && IORQ = potvrzení

         if (nmi_left) { if (--nmi_left == 0) t->nmi_n = 1; }
         else if (chance(8000)) {
            // obsluha NMI = JP na náhodnou adresu, aby běh neuvízl v malé smyčce
            // a prošel víc různého kódu (3 takty zápisu mají přednost před CPU)
            uint16_t to = (uint16_t)rng();
            const uint8_t jp[3] = {0xC3, (uint8_t)to, (uint8_t)(to >> 8)};
            for (int k = 0; k < 3; k++) { t->mem_we = 1; t->mem_a = 0x66 + k; t->mem_d = jp[k]; tick(); }
            t->mem_we = 0;
            t->nmi_n = 0; nmi_left = 12 + rng() % 24; nmis++;
         }

         if (wait_left) { if (--wait_left == 0) t->wait_n = 1; }
         else if (chance(300)) { t->wait_n = 0; wait_left = 1 + rng() % 30; waits++; }

         if (busrq_left) { if (--busrq_left == 0) t->busrq_n = 1; }
         else if (chance(20000)) { t->busrq_n = 0; busrq_left = 1 + rng() % 200; busrqs++; }

         // --- zmrazení (LS_MODE 1/2)
         t->dirset = 0;
         if (frozen > 0) {
            if (mode == 2 && frozen == dirset_at) { t->dir = t->d_reg; t->dirset = 1; }
            if (--frozen == 0) t->run = 1;
         }

         tick();
         if (!(t->d_ctl & 0x02)) halts++;

         // Hranice instrukce jako v debuggeru (rtl/CPU/tv80_dbg.sv): potvrzení
         // přerušení se vynechává. DIRSet totiž nastavuje i A <= PC, a uprostřed
         // potvrzení je na adrese obnovovací adresa {I,R}, ne PC.
         bool bnd = t->d_mc == 1 && t->d_ts == 2 && t->d_prefix == 0 &&
                    !t->d_intcycle && !t->d_nmicycle;
         if (mode && bnd && !prev_bnd && t->run) {
            // DIRSet jen při stojícím CE: nejpozději takt před rozběhem
            t->run = 0; frozen = 2 + rng() % 8; dirset_at = 2 + rng() % (frozen - 1); stops++;
         }
         prev_bnd = bnd;

         hist[hpos] = {clk, t->d_a, t->r_a, t->d_do, t->r_do, t->d_ctl, t->r_ctl, t->di};
         hpos = (hpos + 1) % 24;

         if (t->d_a != t->r_a || t->d_do != t->r_do || t->d_ctl != t->r_ctl) {
            printf("\nROZDIL: semínko %ld, takt %ld od resetu\n", s, i);
            printf("  %10s  %-6s %-4s %-8s | %-6s %-4s %-8s  DI\n", "clk", "DUT A", "DO", "ctl", "REF A", "DO", "ctl");
            for (int k = 0; k < 24; k++) {
               const Snap& h = hist[(hpos + k) % 24];
               char b1[9], b2[9];
               printf("  %10llu  %04X   %02X   %s | %04X   %02X   %s  %02X %s\n",
                      (unsigned long long)h.clk, h.da, h.ddo, ctl_str(h.dctl, b1),
                      h.ra, h.rdo, ctl_str(h.rctl, b2), h.di,
                      (h.da != h.ra || h.ddo != h.rdo || h.dctl != h.rctl) ? "<<<" : "");
            }
            printf("\nNEPROSLO\n");
            delete t; return 1;
         }

         // --- pokrytí opkódů: M1 fetch = M1 && MREQ && RD, opkód je DI před koncem RD
         bool fetch = (t->d_ctl & 0xD0) == 0 && (t->d_ctl & 0x02);   // mimo HALT
         if (fetch) { in_fetch = true; last_di = t->di; }
         else if (in_fetch) {
            in_fetch = false; fetches++;
            seen[page][last_di] = true;
            if (page == 0 && last_di == 0xCB) page = 1;
            else if (page == 0 && last_di == 0xED) page = 2;
            else if (last_di == 0xDD || last_di == 0xFD) page = 3;
            else page = 0;   // DD CB d op: opkód op se nečte jako M1, CB se započte v DD/FD
         }
      }
      printf("semínko %ld: OK (%ld taktů)\n", s, clocks);
   }

   int cnt[4] = {};
   for (int p = 0; p < 4; p++) for (int o = 0; o < 256; o++) cnt[p] += seen[p][o];
   printf("\nPokrytí opkódů: základní %d/256, CB %d/256, ED %d/256, DD/FD %d/256 (fetchů %ld)\n",
          cnt[0], cnt[1], cnt[2], cnt[3], fetches);
   printf("Podněty: INT %ld, NMI %ld, WAIT %ld, BUSRQ %ld; v HALT %.1f %% taktů\n",
          ints, nmis, waits, busrqs, 100.0 * halts / ((double)clocks * seeds));
   if (mode) printf("Zastavení na hranici instrukce: %ld%s\n", stops, mode == 2 ? " (každé s DIRSet)" : "");
   printf("\nVSE PROSLO\n");
   delete t;
   return 0;
}
