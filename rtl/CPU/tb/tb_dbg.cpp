// Test obálky tv80_dbg: breakpointy, krok, přístup do paměti (tb_dbg.sv).
//
// Program (smyčka) zapisuje do 8000h hodnoty 11, 12, 13, čte je zpět, píše na
// port 40h, čte port 41h, zapisuje do 8001h, čte 9000h a výsledek pošle na
// port 42h. Obsluha IM 1 na 38h je EI; RET.
//
//  1. EXEC: zastaví před instrukcí, PC = adresa, znovu po dalším průchodu
//  2. MWR s podmínkou na data (jen hodnota 12)
//  3. MWR bez podmínky na data (dmask 0)
//  4. MRD
//  5. IOWR (porovnává se jen A[7:0])
//  6. IORD
//  7. MRD s rozsahem adres (amask)
//  8. MRD na adrese kódu se při fetchi nespustí; příkaz stop
//  9. přístup do paměti při zastavení: čtení kódu, zápis a čtení RAM,
//     program po rozběhu vidí zapsanou hodnotu
// 10. krok po instrukcích (PC po každém kroku)
// 11. krok s čekajícím INT skončí na první instrukci obsluhy (38h),
//     s step_noint na další instrukci programu
// 12. stop při zastavení se nezapamatuje do dalšího běhu
#include "Vtb_dbg.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <string>
#include <vector>

static Vtb_dbg* t;
static int fails = 0;
static uint8_t image[65536];
static std::map<std::string, uint16_t> L;   // návěští

static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
static void check(const char* name, bool ok, const char* fmt = "", ...) {
   char b[160] = "";
   va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
   printf("  %-58s %s %s\n", name, ok ? "OK  " : "CHYBA", b);
   if (!ok) fails++;
}
static uint16_t getb(const VlWide<7>& w, int lo, int n) {
   uint32_t v = 0;
   for (int k = 0; k < n; k++) v |= ((w[(lo + k) / 32] >> ((lo + k) % 32)) & 1u) << k;
   return (uint16_t)v;
}
static uint16_t pc() { return getb(t->regs, 64, 16); }
static uint8_t  rA() { return (uint8_t)getb(t->regs, 0, 8); }
static uint16_t rBC() { return getb(t->regs, 80, 16); }
static uint16_t rHL() { return getb(t->regs, 112, 16); }

// pulzní příkaz na jeden takt
enum Cmd { STOP, RUN, STEP, STEP_NOINT };
static void cmd(Cmd c) {
   t->c_stop = c == STOP; t->c_run = c == RUN; t->c_step = c == STEP || c == STEP_NOINT;
   t->c_step_noint = c == STEP_NOINT;
   tick();
   t->c_stop = t->c_run = t->c_step = 0;
}
static bool wait_stopped(long max = 40000) {
   for (long i = 0; i < max; i++) { if (t->stopped) return true; tick(); }
   return t->stopped;
}
static void set_bp(int i, int kind, uint16_t addr, uint16_t amask = 0xFFFF, uint8_t data = 0, uint8_t dmask = 0) {
   t->bp_we = 1; t->bp_sel = i; t->bp_kind = kind; t->bp_addr = addr; t->bp_amask = amask;
   t->bp_data = data; t->bp_dmask = dmask; tick(); t->bp_we = 0;
}
static void clear_bps() { for (int i = 0; i < 9; i++) set_bp(i, 0, 0); }
enum { EXEC = 1, MRD = 2, MWR = 4, IORD = 8, IOWR = 16 };

static uint8_t mem_access(bool we, uint16_t a, uint8_t d = 0) {
   t->c_mem_req = 1; t->c_mem_we = we; t->c_mem_addr = a; t->c_mem_wdata = d;
   tick(); t->c_mem_req = 0;
   for (int i = 0; i < 50 && t->busy; i++) tick();
   return t->rdata;
}

// --- program
static uint16_t org;
static void lbl(const char* n) { L[n] = org; }
static void db(std::initializer_list<int> b) { for (int x : b) image[org++] = (uint8_t)x; }

static void build() {
   org = 0x0000; db({0xC3, 0x00, 0x01});                       // JP START
   org = 0x0038; db({0xFB, 0xC9});                             // IM 1: EI; RET
   org = 0x0100;
   lbl("START"); db({0x31, 0x00, 0xF0});                       // LD SP,F000
                 db({0xED, 0x56});                             // IM 1
                 db({0xFB});                                   // EI
                 db({0x0E, 0x00});                             // LD C,0
   lbl("LOOP");  db({0x21, 0x00, 0x80});                       // LD HL,8000
   lbl("LDA");   db({0x3E, 0x11});                             // LD A,11
   lbl("W1");    db({0x77});                                   // LD (HL),A
   lbl("INC1");  db({0x3C});                                   // INC A
   lbl("W2");    db({0x77});
   lbl("INC2");  db({0x3C});
   lbl("W3");    db({0x77});
   lbl("R1");    db({0x46});                                   // LD B,(HL)
   lbl("O1");    db({0xD3, 0x40});                             // OUT (40),A
   lbl("I1");    db({0xDB, 0x41});                             // IN A,(41)
   lbl("W4");    db({0x32, 0x01, 0x80});                       // LD (8001),A
   lbl("R2");    db({0x3A, 0x00, 0x90});                       // LD A,(9000)
   lbl("O2");    db({0xD3, 0x42});                             // OUT (42),A
   lbl("INCC");  db({0x0C});                                   // INC C
   uint16_t lp = L["LOOP"];
                 db({0xC3, lp & 0xFF, lp >> 8});               // JP LOOP
}

int main(int argc, char** argv) {
   Verilated::commandArgs(argc, argv);
   t = new Vtb_dbg;
   build();
   t->clk = 0; t->eval();
   t->reset = 1; t->int_n = 1; t->io_val = 0x77;
   for (int a = 0; a < 65536; a++) { t->load_we = 1; t->load_a = a; t->load_d = image[a]; tick(); }
   t->load_we = 0;
   clear_bps();
   for (int i = 0; i < 20; i++) tick();
   t->reset = 0;

   printf("=== breakpointy ===\n");
   // 1. EXEC
   set_bp(0, EXEC, L["R1"]);
   bool s = wait_stopped();
   check("1. EXEC zastaví před instrukcí", s && t->reason == 3 && pc() == L["R1"] && t->addr == L["R1"],
         "(důvod %d, PC %04X, A %04X)", t->reason, pc(), t->addr);
   check("   hit, hit_pc, registry před provedením", t->hit == 1 && t->hit_pc == L["R1"] && rA() == 0x13 && rHL() == 0x8000,
         "(hit %03X, hit_pc %04X, A %02X, HL %04X)", t->hit, t->hit_pc, rA(), rHL());
   uint8_t c0 = rBC() & 0xFF;
   cmd(RUN); s = wait_stopped();
   check("   po rozběhu znovu na dalším průchodu", s && pc() == L["R1"] && (rBC() & 0xFF) == (uint8_t)(c0 + 1),
         "(PC %04X, C %02X)", pc(), rBC() & 0xFF);

   // 2. MWR s daty
   clear_bps(); set_bp(1, MWR, 0x8000, 0xFFFF, 0x12, 0xFF);
   cmd(RUN); s = wait_stopped();
   check("2. MWR 8000h = 12h (podmínka na data)", s && t->reason == 4 && t->hit == 2 && t->hit_addr == 0x8000 &&
         t->hit_data == 0x12 && t->hit_pc == L["W2"] && pc() == L["INC2"],
         "(důvod %d hit %03X adr %04X data %02X hit_pc %04X PC %04X)", t->reason, t->hit, t->hit_addr, t->hit_data, t->hit_pc, pc());

   // 3. MWR bez dat
   clear_bps(); set_bp(2, MWR, 0x8000);
   cmd(RUN); s = wait_stopped();
   check("3. MWR 8000h, data nerozhodují", s && t->hit == 4 && t->hit_data == 0x13 && t->hit_pc == L["W3"] && pc() == L["R1"],
         "(hit %03X data %02X hit_pc %04X PC %04X)", t->hit, t->hit_data, t->hit_pc, pc());

   // 4. MRD
   clear_bps(); set_bp(3, MRD, 0x8000);
   cmd(RUN); s = wait_stopped();
   check("4. MRD 8000h", s && t->hit == 8 && t->hit_data == 0x13 && t->hit_pc == L["R1"] && pc() == L["O1"],
         "(hit %03X data %02X hit_pc %04X PC %04X)", t->hit, t->hit_data, t->hit_pc, pc());

   // 5. IOWR, horní bajt adresy (A) nerozhoduje
   clear_bps(); set_bp(4, IOWR, 0xFF40);
   cmd(RUN); s = wait_stopped();
   check("5. IOWR port 40h (jen A[7:0])", s && t->hit == 16 && (t->hit_addr & 0xFF) == 0x40 && t->hit_data == 0x13 && t->hit_pc == L["O1"],
         "(hit %03X adr %04X data %02X hit_pc %04X)", t->hit, t->hit_addr, t->hit_data, t->hit_pc);

   // 6. IORD
   clear_bps(); set_bp(5, IORD, 0x0041);
   cmd(RUN); s = wait_stopped();
   check("6. IORD port 41h", s && t->hit == 32 && t->hit_data == 0x77 && t->hit_pc == L["I1"] && pc() == L["W4"],
         "(hit %03X data %02X hit_pc %04X PC %04X)", t->hit, t->hit_data, t->hit_pc, pc());

   // 7. rozsah
   clear_bps(); set_bp(6, MRD, 0x9ABC, 0xF000);
   cmd(RUN); s = wait_stopped();
   check("7. MRD rozsah 9000h-9FFFh (amask F000h)", s && t->hit == 64 && t->hit_addr == 0x9000 && t->hit_pc == L["R2"],
         "(hit %03X adr %04X hit_pc %04X)", t->hit, t->hit_addr, t->hit_pc);

   // 8. fetch není MRD
   clear_bps(); set_bp(7, MRD, L["W1"]);
   cmd(RUN);
   uint8_t cstart = rBC() & 0xFF;
   bool st = wait_stopped(6000);
   cmd(STOP); bool s2 = wait_stopped();
   check("8. MRD na adrese kódu se při fetchi nespustí", !st && s2 && t->reason == 1 && (rBC() & 0xFF) != cstart,
         "(zastavil sám %d, důvod po stop %d, C %02X->%02X)", st, t->reason, cstart, rBC() & 0xFF);

   printf("=== přístup do paměti ===\n");
   clear_bps();
   bool rom_ok = true;
   for (int a = 0x100; a < 0x110; a++) if (mem_access(false, a) != image[a]) rom_ok = false;
   check("9. čtení kódu při zastavení", rom_ok);
   mem_access(true, 0x9000, 0x5A);
   uint8_t rb = mem_access(false, 0x9000);
   t->peek_a = 0x9000; t->eval();
   check("   zápis 9000h = 5Ah a zpětné čtení", rb == 0x5A && t->peek_q == 0x5A, "(čteno %02X, v paměti %02X)", rb, t->peek_q);
   uint16_t pc_before = pc();
   cmd(RUN);
   // CPU mohl stát až za LD A,(9000h) se starou hodnotou v A, proto se
   // bere OUT (42h) z dalšího průchodu smyčkou.
   int out42 = -1, outs = 0;
   for (int i = 0; i < 40000 && outs < 2; i++) {
      tick();
      if (t->io_wr && t->io_port == 0x42) { out42 = t->io_data; outs++; }
   }
   check("   program po rozběhu pokračuje a vidí 5Ah", outs == 2 && out42 == 0x5A,
         "(z PC %04X, druhý OUT (42h) = %02X)", pc_before, out42 & 0xFF);

   printf("=== krok ===\n");
   set_bp(0, EXEC, L["LOOP"]); s = wait_stopped(); clear_bps();
   const char* seq[] = {"LDA", "W1", "INC1", "W2", "INC2", "W3", "R1", "O1", "I1", "W4"};
   bool step_ok = s;
   for (const char* n : seq) {
      cmd(STEP);
      if (!wait_stopped() || t->reason != 2 || pc() != L[n]) {
         step_ok = false; printf("    krok: čekáno %s %04X, PC %04X, důvod %d\n", n, L[n], pc(), t->reason);
      }
   }
   check("10. krok po instrukcích (10 kroků)", step_ok);

   t->int_n = 0;
   cmd(STEP); s = wait_stopped();
   t->int_n = 1;
   check("11. krok s čekajícím INT skončí v obsluze (38h)", s && pc() == 0x0038, "(PC %04X)", pc());
   set_bp(0, EXEC, L["LOOP"]); cmd(RUN); s = wait_stopped(); clear_bps();
   t->int_n = 0;
   cmd(STEP_NOINT); s = wait_stopped() && s;
   t->int_n = 1;
   check("    step_noint: INT se nepřijme, další instrukce programu", s && pc() == L["LDA"], "(PC %04X)", pc());

   cmd(STOP); cmd(RUN);
   bool restop = wait_stopped(3000);
   check("12. stop při zastavení se do dalšího běhu nepřenese", !restop);

   printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails);
   delete t;
   return fails ? 1 : 0;
}
