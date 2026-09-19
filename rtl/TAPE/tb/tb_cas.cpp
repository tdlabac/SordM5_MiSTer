// Test přehrávače kazety (tb_cas.sv): cas_player + rtl/ddram.sv + model DDR3.
//
//  Soubor zapisuje test přímo do modelu DDR od 0x30000000, jako MiSTer u
//  "F2,CAS,Load Tape,30000000"; ioctl nese jen download, index a velikost.
//  1. velikost souboru převzatá z ioctl_addr, čtení jen z oblasti 0x30000000,
//     ddram nikdy nezapisuje
//  2. přehrání: z cas_out se podle délky kladné půlvlny (1 tik = '1',
//     2 tiky = '0') dekódují bity, z nich zaváděcí tóny a bajty (start '0',
//     8 bitů od LSB, stop '1'). Musí sedět: tón 500 bajtů (4000 × '1') před
//     blokem 'H', 32 bajtů před ostatními, bajty bloků = soubor, na konci '1'.
//  3. totéž s náhodným vypínáním motoru (cas_on) během přehrávání
//  4. rychlý režim (cas_fast): poloviční tik, jiný soubor na stejném místě
//  5. soubor bez hlavičky "SORDM5" se nepřehraje
//  6. nahrání s jiným ioctl indexem přehrávač nerozběhne
//  7. (TB_REAL=1, TICK_CE = 874) skutečné časy: tik 244,2 µs, '1' = 2048 Hz
//
// Prostředí: TB_BUSY = pravděpodobnost DDRAM_BUSY v promile (výchozí 20),
//            TB_TICK = TICK_CE, se kterým je model přeložený (výchozí 8).
#include "Vtb_cas.h"
#include <cstdio>
#include <cstdarg>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

static Vtb_cas* t;
static std::mt19937 rng(1);
static int fails = 0;
static long clk = 0, ce_cnt = 0;
static int busy_pm = 20;                 // DDRAM_BUSY v promile
static int TICK = 8;

// --- model DDR3 (slova po 64 bitech, adresa DDRAM_ADDR[15:0])
static uint64_t ddr[65536];
static int rd_lat = -1; static uint32_t rd_word;
static int busy_left = 0;
static long ddr_writes = 0, ddr_bad_addr = 0;

static void check(const char* name, bool ok, const char* fmt = "", ...) {
   char b[200] = "";
   va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
   printf("  %-58s %s %s\n", name, ok ? "OK  " : "CHYBA", b);
   if (!ok) fails++;
}

// dekodér cas_out
static std::vector<int> bits;
static long rise_ce = -1; static int prev_out = 0; static int tick_eff = 8;
static std::vector<long> highs;           // délky kladných půlvln v ce (pro test časů)

static void tick() {
   // DDR3 strana, Avalon: požadavek, který ddram vystaví po hraně k, se
   // převezme hranou k+1, když BUSY v taktu k..k+1 je 0. Převzetí se proto
   // vyhodnocuje před hranou k+1 s BUSY, který v tom taktu platí.
   t->DDRAM_DOUT_READY = 0;
   if (!t->DDRAM_BUSY) {
      if (t->DDRAM_WE) ddr_writes++;
      if ((t->DDRAM_RD || t->DDRAM_WE) && (t->DDRAM_ADDR >> 16) != (0x30000000u >> 19)) ddr_bad_addr++;
      if (t->DDRAM_WE) {
         uint32_t w = t->DDRAM_ADDR & 0xFFFF;
         for (int b = 0; b < 8; b++)
            if (t->DDRAM_BE & (1 << b))
               ddr[w] = (ddr[w] & ~(0xFFull << (8 * b))) | (t->DDRAM_DIN & (0xFFull << (8 * b)));
      }
      if (t->DDRAM_RD) { rd_word = t->DDRAM_ADDR; rd_lat = 2 + rng() % 8; }
   }
   if (rd_lat == 0) {
      t->DDRAM_DOUT = ddr[rd_word & 0xFFFF];
      t->DDRAM_DOUT_READY = 1;
      rd_lat = -1;
   } else if (rd_lat > 0) rd_lat--;

   t->ce = (clk % 6) == 0;
   t->clk = 1; t->eval();
   t->clk = 0; t->eval();
   // BUSY pro příští takt (platí spolu s požadavky, které ddram právě vystavil)
   if (busy_left > 0) busy_left--;
   else if ((int)(rng() % 1000) < busy_pm) busy_left = 1 + rng() % 6;
   t->DDRAM_BUSY = busy_left > 0;
   t->eval();
   if (t->ce) ce_cnt++;
   clk++;

   // dekódování
   int o = t->cas_out;
   if (o && !prev_out) rise_ce = ce_cnt;
   if (!o && prev_out && rise_ce >= 0) {
      long h = ce_cnt - rise_ce;
      highs.push_back(h);
      int ticks = (int)((h + tick_eff / 2) / tick_eff);
      bits.push_back(ticks == 1 ? 1 : ticks == 2 ? 0 : -1);
   }
   prev_out = o;
}


// Nahrání jako MiSTer s adresou v "F": HPS zapíše soubor do DDR sám, pak
// FIO_FILE_TX s velikostí -> ioctl_download = 1, ioctl_addr = velikost,
// žádné ioctl_wr. Na konci hps_io přičte k ioctl_addr 1 (download už je 0).
static void download(const std::vector<uint8_t>& f, int index, bool fast) {
   t->cas_fast = fast;
   t->io_index = index; t->io_addr = 0; t->io_download = 1;
   for (size_t a = 0; a < f.size(); a++)
      ddr[a >> 3] = (ddr[a >> 3] & ~(0xFFull << (8 * (a & 7)))) | ((uint64_t)f[a] << (8 * (a & 7)));
   for (int i = 0; i < 5; i++) tick();
   t->io_addr = f.size();
   for (int i = 0; i < 200; i++) tick();
   t->io_download = 0;
   t->io_addr = f.size() + 1;
   tick();
}

// CAS soubor: hlavička + bloky
struct Blk { uint8_t type; std::vector<uint8_t> data; };
static std::vector<uint8_t> make_cas(const std::vector<Blk>& blks, bool good_hdr = true) {
   std::vector<uint8_t> f(16, 0);
   memcpy(f.data(), good_hdr ? "SORDM5" : "SORDX5", 6);
   for (auto& b : blks) {
      f.push_back(b.type);
      f.push_back((uint8_t)(b.data.size() == 256 ? 0 : b.data.size()));
      uint8_t sum = 0;
      for (uint8_t x : b.data) { f.push_back(x); sum += x; }
      f.push_back(sum);
   }
   return f;
}

// rozbor bitů: [(délka tónu, bajty)], poslední položka = závěrečný bit
struct Seg { int leader; std::vector<uint8_t> bytes; };
static std::vector<Seg> parse(const std::vector<int>& b, int& bad) {
   std::vector<Seg> out; size_t i = 0; bad = 0;
   while (i < b.size()) {
      Seg s{0, {}};
      while (i < b.size() && b[i] == 1) { s.leader++; i++; }
      while (i + 10 <= b.size() && b[i] == 0) {
         int v = 0;
         for (int k = 0; k < 8; k++) { if (b[i + 1 + k] < 0) bad++; v |= (b[i + 1 + k] == 1) << k; }
         if (b[i + 9] != 1) bad++;
         s.bytes.push_back((uint8_t)v); i += 10;
      }
      size_t before = i;
      if (i < b.size() && b[i] < 0) { bad++; i++; }
      out.push_back(s);
      if (s.leader == 0 && s.bytes.empty() && i == before) break;   // neúplný bajt na konci
   }
   return out;
}

static bool play_and_check(const char* name, const std::vector<Blk>& blks, const std::vector<uint8_t>& f,
                           bool toggle_motor, long max_clk) {
   bits.clear(); highs.clear(); rise_ce = -1;
   t->cas_on = 1;
   long off_clk = 0;
   size_t expected_segments = blks.size() + 1;
   for (long i = 0; i < max_clk; i++) {
      if (toggle_motor && (rng() % 20000) == 0) { t->cas_on = !t->cas_on; }
      if (!t->cas_on) off_clk++;
      tick();
      // hotovo: poslední bit '1' je za bajty posledního bloku
      if (i % 20000000 == 0) printf("    ... takt %ld, bitů %zu\n", i, bits.size());
      if (i % 50000 == 0 && bits.size() > 20) {
         int bad; auto s = parse(bits, bad);
         if (s.size() == expected_segments && s.back().leader == 1 && s.back().bytes.empty()) {
            for (int k = 0; k < 3000 * TICK; k++) tick();     // nic dalšího nepřijde?
            break;
         }
      }
   }
   t->cas_on = 1;
   int bad; auto s = parse(bits, bad);
   bool ok = bad == 0 && s.size() == expected_segments;
   int blk_bad = 0;
   for (size_t k = 0; ok && k < blks.size(); k++) {
      int lead = 8 * (blks[k].type == 0x48 ? 500 : 32);
      std::vector<uint8_t> exp;
      exp.push_back(blks[k].type);
      exp.push_back((uint8_t)(blks[k].data.size() == 256 ? 0 : blks[k].data.size()));
      uint8_t sum = 0;
      for (uint8_t x : blks[k].data) { exp.push_back(x); sum += x; }
      exp.push_back(sum);
      if (s[k].leader != lead || s[k].bytes != exp) {
         blk_bad++;
         printf("    blok %zu: tón %d (čekáno %d), bajtů %zu (čekáno %zu)\n", k, s[k].leader, lead,
                s[k].bytes.size(), exp.size());
      }
   }
   ok = ok && blk_bad == 0 && s.back().leader == 1 && s.back().bytes.empty();
   check(name, ok, "(bitů %zu, úseků %zu, chyb dekódování %d%s)", bits.size(), s.size(), bad,
         toggle_motor ? ", s vypínáním motoru" : "");
   (void)f; (void)off_clk;
   return ok;
}

int main(int argc, char** argv) {
   Verilated::commandArgs(argc, argv);
   setvbuf(stdout, nullptr, _IONBF, 0);
   if (getenv("TB_BUSY")) busy_pm = atoi(getenv("TB_BUSY"));
   if (getenv("TB_TICK")) TICK = atoi(getenv("TB_TICK"));
   const bool real = getenv("TB_REAL") != nullptr;
   t = new Vtb_cas;
   t->clk = 0; t->eval();
   t->reset = 1; for (int i = 0; i < 20; i++) tick(); t->reset = 0;
   printf("TICK_CE %d, DDRAM_BUSY %d promile\n", TICK, busy_pm);

   std::vector<Blk> blks;
   if (real) {
      blks = {{0x48, {1, 2, 3, 4}}, {0x44, {0x55, 0xAA}}};
   } else {
      std::vector<uint8_t> d1(16), d2(256), d3(5);
      for (auto& x : d1) x = rng(); for (auto& x : d2) x = rng(); for (auto& x : d3) x = rng();
      d2[0] = 0x00; d2[1] = 0xFF;                 // krajní hodnoty
      blks = {{0x48, d1}, {0x44, d2}, {0x44, d3}};
   }
   auto f = make_cas(blks);

   // 1. nahrání (velikost), 2. přehrání
   download(f, 2, false);
   tick_eff = TICK;
   play_and_check("2. přehrání: tóny, bajty bloků, závěrečný bit", blks, f, false, 400000000L);
   check("1. velikost z ioctl_addr, jen čtení z DDR od 0x30000000",
         t->size == f.size() && ddr_writes == 0 && ddr_bad_addr == 0,
         "(%u B / %zu B, zápisů %ld, mimo oblast %ld)", (unsigned)t->size, f.size(), ddr_writes, ddr_bad_addr);
   if (getenv("TB_ONLY")) { printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails); return fails ? 1 : 0; }

   if (real) {
      long mn = 1L << 30, mx = 0;
      for (long h : highs) { if (h < mn) mn = h; if (h > mx) mx = h; }
      double us1 = mn / 3.579545, us0 = mx / 3.579545;
      check("7. skutečné časy: '1' = 244,2 µs, '0' = 488,3 µs v jedničce",
            mn == TICK && mx == 2 * TICK, "(%.1f µs = %.0f Hz, %.1f µs = %.0f Hz)", us1, 1e6 / (2 * us1), us0,
            1e6 / (2 * us0));
      printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails);
      return fails ? 1 : 0;
   }

   // 3. znovu nahrát (přetočení) a přehrát s vypínáním motoru
   download(f, 2, false);
   play_and_check("3. přehrání s náhodným vypínáním motoru (cas_on)", blks, f, true, 800000000L);

   // 4. rychlý režim, jiný soubor (stejné adresy, jiný obsah)
   std::vector<Blk> blks2 = blks;
   for (auto& b : blks2) for (auto& x : b.data) x ^= 0x5A;
   blks2.push_back({0x44, {9, 8, 7}});
   auto f2 = make_cas(blks2);
   download(f2, 2, true);
   tick_eff = TICK / 2;
   play_and_check("4. rychlý režim (cas_fast), jiný soubor", blks2, f2, false, 400000000L);
   tick_eff = TICK;

   // 5. špatná hlavička
   auto fbad = make_cas(blks, false);
   download(fbad, 2, false);
   bits.clear(); t->cas_on = 1;
   long edges = 0; int po = t->cas_out;
   for (long i = 0; i < 200000L * TICK; i++) { tick(); if (t->cas_out != po) edges++; po = t->cas_out; }
   check("5. soubor bez hlavičky SORDM5 se nepřehraje", edges == 0, "(hran %ld)", edges);

   // 6. jiný ioctl index (DDR obsahuje platný CAS, ale nahrával se jiný soubor)
   {
      auto fg = make_cas(blks);
      for (size_t a = 0; a < fg.size(); a++)
         ddr[a >> 3] = (ddr[a >> 3] & ~(0xFFull << (8 * (a & 7)))) | ((uint64_t)fg[a] << (8 * (a & 7)));
      t->io_index = 1; t->io_addr = 300; t->io_download = 1;
      for (int i = 0; i < 200; i++) tick();
      t->io_download = 0;
      long e6 = 0; int p6 = t->cas_out;
      for (long i = 0; i < 200000L * TICK; i++) { tick(); if (t->cas_out != p6) e6++; p6 = t->cas_out; }
      check("6. nahrání s jiným ioctl indexem přehrávač nerozběhne", e6 == 0 && t->size == fbad.size(),
            "(hran %ld)", e6);
   }

   printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails);
   delete t;
   return fails ? 1 : 0;
}
