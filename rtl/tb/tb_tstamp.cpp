// Test časové značky (tb_tstamp.sv): náhrada tstamp + TimeMark ze sim appky.
//  1. zastavení přesně na zadané hodnotě (i daleko, přes mnoho period sync)
//  2. "trace od" 5 taktů CPU před "zastavit" (bližší než perioda sync):
//     obě se splní, trace dřív, stop přesně
//  3. značka zadaná za běhu se převezme nejpozději po jedné periodě sync
//  4. značka v minulosti se nesplní
//  5. reset čas nuluje, značka zadaná po resetu se splní
#include "Vtb_tstamp.h"
#include "TimeMark.h"
#include <cstdio>
#include <cstdarg>

static Vtb_tstamp* t;
static int fails = 0;
static long clk = 0;

static void tick() {
   t->ce = (clk % 6) == 0;
   t->clk = 1; t->eval(); t->clk = 0; t->eval();
   clk++;
}
static void check(const char* name, bool ok, const char* fmt = "", ...) {
   char b[160] = "";
   va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
   printf("  %-56s %s %s\n", name, ok ? "OK  " : "CHYBA", b);
   if (!ok) fails++;
}
// běh jako Sim::verilate: po každém taktu kontrola příznaků; vrátí čas zastavení
static long run_until_stop(long max, uint64_t* trace_at = nullptr) {
   for (long i = 0; i < max; i++) {
      tick();
      if (timemark.trace_pending) { timemark.trace_pending = false; if (trace_at) *trace_at = t->count; }
      if (timemark.stop_pending)  { timemark.stop_pending = false; return (long)t->count; }
   }
   return -1;
}

int main(int argc, char** argv) {
   Verilated::commandArgs(argc, argv);
   t = new Vtb_tstamp;
   t->clk = 0; t->eval();
   t->reset = 1; for (int i = 0; i < 10; i++) tick(); t->reset = 0;

   timemark.set_stop_at(100000);
   long s = run_until_stop(2000000);
   check("1. zastavení přesně na 100000", s == 100000, "(zastavil na %ld)", s);

   uint64_t tr = 0;
   timemark.set_trace_from(150000);
   timemark.set_stop_at(150005);
   s = run_until_stop(2000000, &tr);
   check("2. trace od 150000, zastavit 150005 (blíž než sync)", tr == 150000 && s == 150005,
         "(trace %llu, stop %ld)", (unsigned long long)tr, s);

   for (int i = 0; i < 1000; i++) tick();               // čas běží dál
   uint64_t now = t->count;
   timemark.set_stop_at(now + 700);                      // 700 taktů CPU = 4200 clk > 1 sync
   s = run_until_stop(100000);
   check("3. značka zadaná za běhu (+700 taktů CPU)", s == (long)(now + 700), "(čekáno %llu, zastavil %ld)",
         (unsigned long long)(now + 700), s);

   timemark.set_stop_at(1000);                           // dávno uplynulo
   s = run_until_stop(200000);
   check("4. značka v minulosti se nesplní", s < 0 && !timemark.stop_done);
   timemark.set_stop_at(0);

   t->reset = 1; for (int i = 0; i < 10; i++) tick(); t->reset = 0;
   check("5. reset čas nuluje", t->count < 5, "(%llu)", (unsigned long long)t->count);
   timemark.set_stop_at(5000);
   s = run_until_stop(200000);
   check("   po resetu zastaví na 5000", s == 5000, "(%ld)", s);
   check("   TimeMark.now odpovídá", timemark.now == 5000, "(%llu)", (unsigned long long)timemark.now);

   printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails);
   delete t;
   return fails ? 1 : 0;
}
