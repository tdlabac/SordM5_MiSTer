// Nahrání programu z kazety skutečným monitorem M5 (tb_m5tape.sv).
//
// Jádro bez cartridge: monitor po startu skočí do RBTCMT a čte kazetu
// (SRLAD naladí rychlost, RDFID přečte hlavičku do SYSBUF, BLOAD data, při
// autostartu program spustí). Na kazetě je program, který zapíše A5h na
// 7F00h. Test sleduje:
//   - jestli nahrání kazety (ioctl index 2) neresetuje počítač,
//   - motor (port 50h zápis bit 1),
//   - kolikrát CPU prošel SRLAD / RDCNT, čtení portu 50h a CTC kanálu 1,
//   - hlavičku v SYSBUF (7262h) a značku na 7F00h.
// Prostředí: TB_CLOCKS (max. taktů clk_sys, výchozí 400 M), TB_BUSY (promile),
//            TB_TRACE = N: vypíše N hran pásky s přístupy na CTC kanál 1
//            (časy v taktech CPU). Tak se našlo, že IN A,(1) CTC bralo i jako
//            zápis (rtl/CTC/ctc_channel.sv, wr_n).
#include "Vtb_m5tape.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

static Vtb_m5tape* t;
static std::mt19937 rng(1);
static long clk = 0;
static int busy_pm = 20;

// --- model DDR3 (jako tb_cas.cpp), slova po 64 bitech, adresa DDRAM_ADDR[15:0]
static uint64_t ddr[65536];
static int rd_lat = -1; static uint32_t rd_word;
static int busy_left = 0;

static void tick() {
   t->DDRAM_DOUT_READY = 0;
   if (!t->DDRAM_BUSY && t->DDRAM_RD) { rd_word = t->DDRAM_ADDR; rd_lat = 2 + rng() % 8; }
   if (rd_lat == 0) { t->DDRAM_DOUT = ddr[rd_word & 0xFFFF]; t->DDRAM_DOUT_READY = 1; rd_lat = -1; }
   else if (rd_lat > 0) rd_lat--;
   t->clk = 1; t->eval();
   t->clk = 0; t->eval();
   if (busy_left > 0) busy_left--;
   else if ((int)(rng() % 1000) < busy_pm) busy_left = 1 + rng() % 6;
   t->DDRAM_BUSY = busy_left > 0;
   t->eval();
   clk++;
}

static void put_ddr(const std::vector<uint8_t>& f) {
   memset(ddr, 0, sizeof ddr);
   for (size_t a = 0; a < f.size(); a++)
      ddr[a >> 3] |= (uint64_t)f[a] << (8 * (a & 7));
}

static void block(std::vector<uint8_t>& f, uint8_t type, const std::vector<uint8_t>& d) {
   f.push_back(type);
   f.push_back((uint8_t)(d.size() == 256 ? 0 : d.size()));
   uint8_t sum = 0;
   for (uint8_t x : d) { f.push_back(x); sum += x; }
   f.push_back(sum);
}

static uint8_t peek(uint16_t a) { t->peek_addr = a & 0xFFF; t->eval(); return t->peek_data; }

int main(int argc, char** argv) {
   Verilated::commandArgs(argc, argv);
   setvbuf(stdout, nullptr, _IONBF, 0);
   long max_clk = getenv("TB_CLOCKS") ? atol(getenv("TB_CLOCKS")) : 400000000L;
   if (getenv("TB_BUSY")) busy_pm = atoi(getenv("TB_BUSY"));
   t = new Vtb_m5tape;

   // program: LD A,0A5h; LD (7F00h),A; JR $
   const std::vector<uint8_t> prog = {0x3E, 0xA5, 0x32, 0x00, 0x7F, 0x18, 0xFE};
   const uint16_t load = 0x7400;
   std::vector<uint8_t> hdr(31, 0);
   hdr[0] = 0x03;                                   // program, autostart, RAM
   memcpy(&hdr[1], "TEST     ", 9);
   hdr[10] = load & 0xFF; hdr[11] = load >> 8;      // ukládací adresa
   hdr[12] = (uint8_t)prog.size(); hdr[13] = 0;     // délka
   hdr[14] = load & 0xFF; hdr[15] = load >> 8;      // start
   std::vector<uint8_t> f(16, 0);
   memcpy(f.data(), "SORDM5", 6);
   block(f, 0x48, hdr);
   block(f, 0x44, prog);
   put_ddr(f);

   // reset, pak "nahrání" kazety jako MiSTer (soubor už je v DDR)
   t->reset_in = 1; for (int i = 0; i < 100; i++) tick(); t->reset_in = 0;
   for (int i = 0; i < 1000; i++) tick();
   long resets_by_load = 0;
   t->io_index = 2; t->io_addr = 0; t->io_download = 1;
   for (int i = 0; i < 5; i++) tick();
   t->io_addr = f.size();
   for (int i = 0; i < 200; i++) { tick(); resets_by_load += t->reset; }
   t->io_download = 0; t->io_addr = f.size() + 1;

   long motor_on = -1, m1_srlad = 0, m1_rdcnt = 0, m1_ldbyt = 0, m1_prog = 0;
   long rd50 = 0, rd50_1 = 0, rdctc1 = 0, cas_edges = 0;
   int ctc_hist[256] = {0};
   int prev_m1 = 1, prev_io = 1, prev_cas = 0;
   bool m1_pending = false;
   static long m1_hist[65536];
   uint64_t ts_prev = 0; long ts_back = 0;
   bool ok = false;
   for (long i = 0; i < max_clk; i++) {
      tick();
      if (t->cas_motor && motor_on < 0) motor_on = clk;
      static long trace_n = getenv("TB_TRACE") ? atol(getenv("TB_TRACE")) : 0;
      static long last_ev = 0;
      if (t->cas_in != prev_cas) {
         cas_edges++;
         if (trace_n > 0 && cas_edges > 3000) { trace_n--; printf("  %9ld (+%5ld)  páska -> %d\n", clk / 6, (clk - last_ev) / 6, t->cas_in); last_ev = clk; }
      }
      {
         static int prev_iow = 1, prev_ior = 1, last_di = 0;
         int iow = !t->IORQ_n && !t->WR_n, ior = !t->IORQ_n && !t->RD_n && t->M1_n;
         if (trace_n > 0 && cas_edges > 3000 && (t->A & 0xFF) == 0x01) {
            if (iow && !prev_iow) { printf("  %9ld (+%5ld)  OUT (1),%02X\n", clk / 6, (clk - last_ev) / 6, t->DO); last_ev = clk; }
            if (!ior && prev_ior) { printf("  %9ld (+%5ld)  IN (1) = %02X\n", clk / 6, (clk - last_ev) / 6, last_di); last_ev = clk; }
         }
         if (ior) last_di = t->DI;
         if (trace_n > 0 && cas_edges > 3000 && t->ctc1_wr)
            printf("  %9ld           CTC1 vidí zápis %02X (IORQ %d RD %d WR %d)\n", clk / 6, t->ctc1_din, t->IORQ_n, t->RD_n, t->WR_n);
         prev_iow = iow; prev_ior = ior;
      }
      prev_cas = t->cas_in;
      if (!t->M1_n && prev_m1) m1_pending = true;
      if (m1_pending && !t->MREQ_n && !t->RD_n) {
         m1_pending = false;
         uint16_t a = t->A;
         if (motor_on >= 0) m1_hist[a]++;
         if (a == 0x16D1) m1_srlad++;
         if (a == 0x1739) m1_rdcnt++;
         if (a == 0x16B6) m1_ldbyt++;
         if (a == load) m1_prog++;
      }
      prev_m1 = t->M1_n;
      int io_rd = !t->IORQ_n && !t->RD_n && t->M1_n;
      if (io_rd && !prev_io) {
         if ((t->A & 0xF0) == 0x50) { rd50++; rd50_1 += t->DI & 1; }
         if ((t->A & 0xFF) == 0x01) { rdctc1++; ctc_hist[t->DI]++; }
      }
      prev_io = io_rd;
      if (t->tstamp < ts_prev) ts_back++;
      ts_prev = t->tstamp;
      if (i % 20000000 == 0)
         printf("  ... takt %ld: motor %d, hran pásky %ld, SRLAD %ld, RDCNT %ld, LDBYT1 %ld, čtení 50h %ld (s 1: %ld), CTC1 %ld\n",
                i, t->cas_motor, cas_edges, m1_srlad, m1_rdcnt, m1_ldbyt, rd50, rd50_1, rdctc1);
      if ((i & 0xFFFF) == 0 && peek(0x7F00) == 0xA5) { ok = true; break; }
   }

   printf("\nnahrání kazety resetovalo počítač: %s (%ld taktů resetu)\n", resets_by_load ? "ANO" : "ne", resets_by_load);
   printf("čas počítače šel zpět (reset): %ld×\n", ts_back);
   printf("motor zapnut v taktu %ld\n", motor_on);
   printf("SRLAD %ld×, RDCNT %ld×, LDBYT1 %ld×, program %ld×\n", m1_srlad, m1_rdcnt, m1_ldbyt, m1_prog);
   printf("čtení portu 50h %ld× (bit0=1: %ld), čtení CTC1 %ld×, hran pásky %ld\n", rd50, rd50_1, rdctc1, cas_edges);
   printf("CTC1 nejčastější hodnoty:");
   for (int k = 0; k < 8; k++) {
      int best = -1;
      for (int v = 0; v < 256; v++) if (ctc_hist[v] && (best < 0 || ctc_hist[v] > ctc_hist[best])) best = v;
      if (best < 0) break;
      printf(" %02X(%d)", best, ctc_hist[best]); ctc_hist[best] = 0;
   }
   printf("\nM1 od zapnutí motoru, nejčastější adresy:");
   for (int k = 0; k < 24; k++) {
      int best = -1;
      for (int v = 0; v < 65536; v++) if (m1_hist[v] && (best < 0 || m1_hist[v] > m1_hist[best])) best = v;
      if (best < 0) break;
      printf("%s %04X(%ld)", k % 8 ? "" : "\n ", best, m1_hist[best]); m1_hist[best] = 0;
   }
   printf("\nSYSBUF:");
   int hdr_bad = 0;
   for (int k = 0; k < 16; k++) { uint8_t v = peek(0x7262 + k); printf(" %02X", v); hdr_bad += v != hdr[k]; }
   printf("  (%s)\n", hdr_bad ? "neodpovídá hlavičce" : "= hlavička z kazety");
   printf("\n%s\n", ok && !resets_by_load ? "PROSLO: program z kazety se nahrál a spustil"
                                          : "NEPROSLO");
   delete t;
   return ok && !resets_by_load ? 0 : 1;
}
