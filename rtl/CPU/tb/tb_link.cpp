// End-to-end test debuggeru přes třídu Z80Dbg ze sim appky (tb_link.sv).
// Stejný program jako tb_dbg.cpp. Kontroluje, že API sim appky funguje nad
// skutečným registrovým prostorem: identifikace, stop, snímek registrů,
// breakpoint, čtení a zápis paměti, zápis registrů, krok, rozběh.
#include "Vtb_link.h"
#include "Z80dbg.h"
#include <cstdio>
#include <cstdint>
#include <cstdarg>
#include <functional>
#include <map>
#include <string>

extern Z80Dbg* z80dbg;
static Vtb_link* t;
static int fails = 0;
static uint8_t image[65536];
static std::map<std::string, uint16_t> L;

static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
static bool until(std::function<bool()> ok, long max = 100000) {
   for (long i = 0; i < max; i++) { if (ok()) return true; tick(); }
   return ok();
}
static void check(const char* name, bool ok, const char* fmt = "", ...) {
   char b[160] = "";
   va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
   printf("  %-50s %s %s\n", name, ok ? "OK  " : "CHYBA", b);
   if (!ok) fails++;
}
static bool settled() { return z80dbg->stopped && z80dbg->regs_valid && !z80dbg->busy(); }

static uint16_t org;
static void lbl(const char* n) { L[n] = org; }
static void db(std::initializer_list<int> b) { for (int x : b) image[org++] = (uint8_t)x; }
static void build() {
   org = 0x0000; db({0xC3, 0x00, 0x01});
   org = 0x0038; db({0xFB, 0xC9});
   org = 0x0100;
   lbl("START"); db({0x31, 0x00, 0xF0}); db({0xED, 0x56}); db({0xFB}); db({0x0E, 0x00});
   lbl("LOOP");  db({0x21, 0x00, 0x80});
   lbl("LDA");   db({0x3E, 0x11});
   lbl("W1");    db({0x77}); db({0x3C});
   lbl("W2");    db({0x77}); db({0x3C});
   lbl("W3");    db({0x77});
   lbl("R1");    db({0x46});
   lbl("O1");    db({0xD3, 0x40});
   lbl("I1");    db({0xDB, 0x41});
   lbl("W4");    db({0x32, 0x01, 0x80});
   lbl("R2");    db({0x3A, 0x00, 0x90});
   lbl("O2");    db({0xD3, 0x42});
                 db({0x0C});
   uint16_t lp = L["LOOP"];
                 db({0xC3, lp & 0xFF, lp >> 8});
}

int main(int argc, char** argv) {
   Verilated::commandArgs(argc, argv);
   t = new Vtb_link;
   build();
   t->clk = 0; t->eval();
   t->reset = 1; t->int_n = 1; t->io_val = 0x77;
   for (int a = 0; a < 65536; a++) { t->load_we = 1; t->load_a = a; t->load_d = image[a]; tick(); }
   t->load_we = 0;
   for (int i = 0; i < 20; i++) tick();
   t->reset = 0;

   Z80Dbg& d = *z80dbg;
   check("identifikace registrového prostoru (5Ah)", until([&] { return d.present; }));

   d.stop();
   bool s = until(settled);
   check("stop: zastaví, načte registry", s && d.reason == Z80Dbg::R_STOP && d.regs.pc == t->addr,
         "(důvod %d, PC %04X, A %04X)", d.reason, d.regs.pc, t->addr);

   Z80Dbg::Bp bp; bp.kind = Z80Dbg::BP_EXEC; bp.addr = L["R1"];
   d.set_bp(0, bp);
   d.run();
   s = until([&] { return settled() && d.reason == Z80Dbg::R_EXEC; });
   check("breakpoint EXEC", s && d.regs.pc == L["R1"] && d.hit == 1 && d.hit_pc == L["R1"] && d.regs.a == 0x13,
         "(PC %04X hit %X hit_pc %04X A %02X)", d.regs.pc, d.hit, d.hit_pc, d.regs.a);

   d.read_mem(0x0100, 32);
   until([&] { return !d.busy(); });
   bool rom_ok = true;
   for (int a = 0x100; a < 0x120; a++) if (!d.mem_valid[a] || d.mem[a] != image[a]) rom_ok = false;
   check("čtení paměti (32 B kódu)", rom_ok);

   d.write_mem(0x9000, 0xA5);
   d.mem_valid[0x9000] = false;
   d.read_mem(0x9000, 1);
   until([&] { return !d.busy(); });
   t->peek_a = 0x9000; t->eval();
   check("zápis paměti a zpětné čtení", d.mem_valid[0x9000] && d.mem[0x9000] == 0xA5 && t->peek_q == 0xA5,
         "(čteno %02X, v paměti %02X)", d.mem[0x9000], t->peek_q);

   Z80Dbg::Regs r = d.regs;
   r.bc = (uint16_t)((r.bc & 0xFF00) | 0x40);        // C = 40h
   r.de = 0xBEEF;
   d.write_regs(r);
   until([&] { return !d.busy(); });
   check("zápis registrů (C, DE) a zpětné čtení", d.regs_valid && (d.regs.bc & 0xFF) == 0x40 && d.regs.de == 0xBEEF,
         "(BC %04X DE %04X)", d.regs.bc, d.regs.de);

   bp.kind = 0; d.set_bp(0, bp);
   const char* seq[] = {"O1", "I1", "W4"};
   bool step_ok = true;
   for (const char* n : seq) {
      d.step(false);
      if (!until([&] { return settled() && d.reason == Z80Dbg::R_STEP; }) || d.regs.pc != L[n]) {
         step_ok = false; printf("    krok: čekáno %s %04X, PC %04X\n", n, L[n], d.regs.pc);
      }
   }
   check("krok po instrukcích (3)", step_ok);
   check("registry přežily krok (C = 40h, DE = BEEFh, B = 13h)",
         (d.regs.bc & 0xFF) == 0x40 && d.regs.de == 0xBEEF && (d.regs.bc >> 8) == 0x13,
         "(BC %04X DE %04X)", d.regs.bc, d.regs.de);

   d.run();
   bool ran = until([&] { return !d.stopped; }, 1000);
   long n = 0; bool restop = false;
   for (; n < 20000; n++) { tick(); if (d.stopped) restop = true; }
   d.stop();
   s = until(settled);
   check("rozběh a nové zastavení", ran && !restop && s && d.stop_count >= 6,
         "(běžel %d, zastavil sám %d, počet zastavení %u)", ran, restop, d.stop_count);

   printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails);
   delete t;
   return fails ? 1 : 0;
}
