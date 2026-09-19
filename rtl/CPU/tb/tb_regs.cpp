// Test REG/DIRSet TV80a (doc/z80-debugger.md, krok 3).
//
// 1. Hranice instrukce a snímek registrů. Program prochází instrukce, u
//    kterých se výsledek zapisuje opožděně nebo neobvykle (ALU, INC/DEC,
//    16bit, EX/EXX, POP AF, LD A,I/R, LD R,A, bloky, DJNZ, CALL/RET, JP (HL),
//    IN, prefixy DD/FD/ED/CB/DDCB). Na KAŽDÉ hranici (M1, TState 2,
//    Prefix 0) se CE zastaví a REG se porovná s očekávaným stavem:
//    - PC musí být adresa další instrukce programu (hranice = začátek
//      instrukce, prefixy se přeskakují),
//    - všechny registry musí mít hodnotu po dokončení předchozí instrukce
//      (odpověď na otevřenou otázku, zda jsou v místě zastavení dopsané),
//    - R roste o počet M1 cyklů, bit 7 drží.
//    Očekávaný stav se na první hranici převezme z REG (banka registrů po
//    resetu není definovaná) a dál se počítá po instrukcích.
// 2. DIRSet. Po lichém počtu EXX (Alternate = 1) se nahrají náhodné
//    registry s PC na výpisovou rutinu. Ta vše uloží PUSH na zásobník;
//    hodnoty se ověří na hranicích přes REG i v paměti (zápisy po sběrnici).
// 3. IM a IFF z DIRSet: rutina končí HALT, test pustí INT a čeká skok na
//    0038h (IM 1) s návratovou adresou za HALT na zásobníku.
#include "Vtb_regs.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <random>
#include <string>
#include <vector>

static Vtb_regs* t;
static uint64_t clk = 0;
static int fails = 0;
static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); ++clk; }

enum : uint8_t { fS = 0x80, fZ = 0x40, fY = 0x20, fH = 0x10, fX = 0x08, fP = 0x04, fN = 0x02, fC = 0x01 };

struct St {
   uint8_t  a, f, a_, f_, i, r;
   uint16_t sp, pc, bc, de, hl, bc_, de_, hl_, ix, iy;
   uint8_t  iff1, iff2, im;
   bool     fk = true, fk_ = true;         // F / F' známé
};

// ---- REG <-> St (rozložení viz tv80.sv)
static uint32_t getb(const VlWide<7>& w, int lo, int n) {
   uint32_t v = 0;
   for (int k = 0; k < n; k++) v |= ((w[(lo + k) / 32] >> ((lo + k) % 32)) & 1u) << k;
   return v;
}
static void setb(VlWide<7>& w, int lo, int n, uint32_t v) {
   for (int k = 0; k < n; k++) {
      uint32_t& x = w[(lo + k) / 32]; uint32_t m = 1u << ((lo + k) % 32);
      x = (v >> k) & 1 ? (x | m) : (x & ~m);
   }
}
static St from_reg(const VlWide<7>& w) {
   St s;
   s.a = getb(w, 0, 8);    s.f = getb(w, 8, 8);    s.a_ = getb(w, 16, 8); s.f_ = getb(w, 24, 8);
   s.i = getb(w, 32, 8);   s.r = getb(w, 40, 8);   s.sp = getb(w, 48, 16); s.pc = getb(w, 64, 16);
   s.bc = getb(w, 80, 16); s.de = getb(w, 96, 16); s.hl = getb(w, 112, 16);
   s.bc_ = getb(w, 128, 16); s.de_ = getb(w, 144, 16); s.hl_ = getb(w, 160, 16);
   s.ix = getb(w, 176, 16); s.iy = getb(w, 192, 16);
   s.iff1 = getb(w, 208, 1); s.iff2 = getb(w, 209, 1); s.im = getb(w, 210, 2);
   return s;
}
static void to_reg(VlWide<7>& w, const St& s) {
   for (int k = 0; k < 7; k++) w[k] = 0;
   setb(w, 0, 8, s.a);    setb(w, 8, 8, s.f);    setb(w, 16, 8, s.a_);  setb(w, 24, 8, s.f_);
   setb(w, 32, 8, s.i);   setb(w, 40, 8, s.r);   setb(w, 48, 16, s.sp); setb(w, 64, 16, s.pc);
   setb(w, 80, 16, s.bc); setb(w, 96, 16, s.de); setb(w, 112, 16, s.hl);
   setb(w, 128, 16, s.bc_); setb(w, 144, 16, s.de_); setb(w, 160, 16, s.hl_);
   setb(w, 176, 16, s.ix); setb(w, 192, 16, s.iy);
   setb(w, 208, 1, s.iff1); setb(w, 209, 1, s.iff2); setb(w, 210, 2, s.im);
}

// ---- porovnání
static bool cmp(const char* where, const St& e, const St& g) {
   std::string bad;
   char b[64];
   auto c8  = [&](const char* n, uint8_t x, uint8_t y)   { if (x != y) { snprintf(b, sizeof b, " %s=%02X(čekáno %02X)", n, y, x); bad += b; } };
   auto c16 = [&](const char* n, uint16_t x, uint16_t y) { if (x != y) { snprintf(b, sizeof b, " %s=%04X(čekáno %04X)", n, y, x); bad += b; } };
   c8("A", e.a, g.a); if (e.fk) c8("F", e.f, g.f);
   c8("A'", e.a_, g.a_); if (e.fk_) c8("F'", e.f_, g.f_);
   c8("I", e.i, g.i); c8("R", e.r, g.r);
   c16("SP", e.sp, g.sp); c16("PC", e.pc, g.pc);
   c16("BC", e.bc, g.bc); c16("DE", e.de, g.de); c16("HL", e.hl, g.hl);
   c16("BC'", e.bc_, g.bc_); c16("DE'", e.de_, g.de_); c16("HL'", e.hl_, g.hl_);
   c16("IX", e.ix, g.ix); c16("IY", e.iy, g.iy);
   c8("IFF1", e.iff1, g.iff1); c8("IFF2", e.iff2, g.iff2); c8("IM", e.im, g.im);
   if (!bad.empty()) { printf("  CHYBA %-28s%s\n", where, bad.c_str()); fails++; return false; }
   return true;
}

// ---- program
struct Step {
   uint16_t addr;
   std::vector<uint8_t> bytes;
   std::string name;
   std::function<void(St&, const St&)> fx;   // (nový stav, stav před instrukcí)
   bool dirset = false;                      // na hranici téhle instrukce DIRSet
};
static std::vector<Step> prog;
static uint16_t org = 0;
static uint8_t  image[65536];

static void emit(const char* name, std::vector<uint8_t> bytes, std::function<void(St&, const St&)> fx = nullptr) {
   prog.push_back({org, bytes, name, fx});
   for (uint8_t x : bytes) image[org++] = x;
}
static uint8_t szp(uint8_t v) {   // S, Z, P (parita) pro IN r,(C) a LD A,I/R bez P
   int ones = __builtin_popcount(v);
   return (v & 0x80) | (v == 0 ? fZ : 0) | ((ones & 1) == 0 ? fP : 0);
}
static void set_af(uint16_t v) {  // F známé přes PUSH HL / POP AF
   emit("LD HL,nn", {0x21, (uint8_t)v, (uint8_t)(v >> 8)}, [=](St& s, const St&) { s.hl = v; });
   emit("PUSH HL", {0xE5}, [](St& s, const St&) { s.sp -= 2; });
   emit("POP AF",  {0xF1}, [=](St& s, const St&) { s.sp += 2; s.a = v >> 8; s.f = (uint8_t)v; s.fk = true; });
}
#define B8(x)  ((uint8_t)(x))
#define HI(x)  ((uint8_t)((x) >> 8))

static void build(St& dirst, uint16_t& halt_addr) {
   std::mt19937 rng(12345);
   org = 0x0000;
   emit("JP 0100 (0038h patří obsluze IM 1)", {0xC3, 0x00, 0x01});
   org = 0x0100;
   emit("LD SP,F000", {0x31, 0x00, 0xF0}, [](St& s, const St&) { s.sp = 0xF000; });
   emit("LD BC,1234", {0x01, 0x34, 0x12}, [](St& s, const St&) { s.bc = 0x1234; });
   emit("LD DE,5678", {0x11, 0x78, 0x56}, [](St& s, const St&) { s.de = 0x5678; });
   emit("LD HL,9ABC", {0x21, 0xBC, 0x9A}, [](St& s, const St&) { s.hl = 0x9ABC; });
   emit("LD A,10",    {0x3E, 0x10},       [](St& s, const St&) { s.a = 0x10; });
   emit("ADD A,A",    {0x87},             [](St& s, const St&) { s.a = 0x20; s.f = fY; s.fk = true; });
   emit("INC A",      {0x3C},             [](St& s, const St&) { s.a = 0x21; s.f = fY | (s.f & fC); });
   emit("DEC B",      {0x05},             [](St& s, const St&) { s.bc = 0x1134; s.f = fN | (s.f & fC); });
   emit("INC HL",     {0x23},             [](St& s, const St&) { s.hl = 0x9ABD; });
   emit("DEC DE",     {0x1B},             [](St& s, const St&) { s.de = 0x5677; });
   emit("EX DE,HL",   {0xEB},             [](St& s, const St&) { std::swap(s.de, s.hl); });
   emit("EX AF,AF'",  {0x08},             [](St& s, const St&) { std::swap(s.a, s.a_); std::swap(s.f, s.f_); std::swap(s.fk, s.fk_); });
   emit("EXX",        {0xD9},             [](St& s, const St&) { std::swap(s.bc, s.bc_); std::swap(s.de, s.de_); std::swap(s.hl, s.hl_); });
   emit("LD BC,AAAA", {0x01, 0xAA, 0xAA}, [](St& s, const St&) { s.bc = 0xAAAA; });
   emit("EXX",        {0xD9},             [](St& s, const St&) { std::swap(s.bc, s.bc_); std::swap(s.de, s.de_); std::swap(s.hl, s.hl_); });
   emit("LD IX,1111", {0xDD, 0x21, 0x11, 0x11}, [](St& s, const St&) { s.ix = 0x1111; });
   emit("LD IY,2222", {0xFD, 0x21, 0x22, 0x22}, [](St& s, const St&) { s.iy = 0x2222; });
   emit("INC IX",     {0xDD, 0x23},       [](St& s, const St&) { s.ix = 0x1112; });
   emit("ADD IX,BC",  {0xDD, 0x09},       [](St& s, const St&) { s.ix = 0x1112 + 0x1134; s.fk = false; });
   emit("LD (IX+5),77", {0xDD, 0x36, 0x05, 0x77});
   emit("LD A,(IX+5)",  {0xDD, 0x7E, 0x05}, [](St& s, const St&) { s.a = 0x77; });
   emit("LD B,(IX+5)",  {0xDD, 0x46, 0x05}, [](St& s, const St&) { s.bc = 0x7734; });
   emit("PUSH BC",    {0xC5},             [](St& s, const St&) { s.sp -= 2; });
   emit("POP DE",     {0xD1},             [](St& s, const St&) { s.sp += 2; s.de = s.bc; });
   set_af(0x3456);
   emit("SCF",        {0x37},             [](St& s, const St&) { s.f = (s.f & (fS | fZ | fP)) | fC | (s.a & (fY | fX)); });
   emit("CPL",        {0x2F},             [](St& s, const St&) { s.a = ~s.a; s.f = (s.f & (fS | fZ | fP | fC)) | fH | fN | (s.a & (fY | fX)); });
   emit("LD A,5A",    {0x3E, 0x5A},       [](St& s, const St&) { s.a = 0x5A; });
   emit("LD I,A",     {0xED, 0x47},       [](St& s, const St&) { s.i = 0x5A; });
   emit("LD A,85",    {0x3E, 0x85},       [](St& s, const St&) { s.a = 0x85; });
   emit("LD R,A",     {0xED, 0x4F},       [](St& s, const St&) { s.r = 0x85; });
   emit("NOP",        {0x00});
   emit("LD A,FF",    {0x3E, 0xFF},       [](St& s, const St&) { s.a = 0xFF; });
   emit("LD R,A",     {0xED, 0x4F},       [](St& s, const St&) { s.r = 0xFF; });
   emit("NOP (R 7F->00, bit 7 drží)", {0x00});
   emit("EI",         {0xFB},             [](St& s, const St&) { s.iff1 = s.iff2 = 1; });
   emit("LD A,R",     {0xED, 0x5F},       [](St& s, const St& p) {
      s.a = (p.r & 0x80) | ((p.r + 2) & 0x7F);
      s.f = (s.f & (fC | fY | fX)) | (s.a & fS) | (s.a == 0 ? fZ : 0) | (s.iff2 ? fP : 0); });
   emit("DI",         {0xF3},             [](St& s, const St&) { s.iff1 = s.iff2 = 0; });
   emit("IM 1",       {0xED, 0x56},       [](St& s, const St&) { s.im = 1; });
   emit("IM 2",       {0xED, 0x5E},       [](St& s, const St&) { s.im = 2; });
   emit("IM 0",       {0xED, 0x46},       [](St& s, const St&) { s.im = 0; });
   emit("LD HL,8000", {0x21, 0x00, 0x80}, [](St& s, const St&) { s.hl = 0x8000; });
   emit("LD DE,9000", {0x11, 0x00, 0x90}, [](St& s, const St&) { s.de = 0x9000; });
   emit("LD BC,0003", {0x01, 0x03, 0x00}, [](St& s, const St&) { s.bc = 0x0003; });
   for (int k = 0; k < 2; k++)
      emit("LDI",     {0xED, 0xA0},       [](St& s, const St&) { s.hl++; s.de++; s.bc--; s.fk = false; });
   emit("LDIR (BC=1, jedna iterace)", {0xED, 0xB0}, [](St& s, const St&) { s.hl++; s.de++; s.bc--; s.fk = false; });
   emit("LD B,02",    {0x06, 0x02},       [](St& s, const St&) { s.bc = (s.bc & 0xFF) | 0x0200; });
   emit("DJNZ +0",    {0x10, 0x00},       [](St& s, const St&) { s.bc -= 0x100; });
   emit("DJNZ +0",    {0x10, 0x00},       [](St& s, const St&) { s.bc -= 0x100; });
   uint16_t ret_to = org + 3;
   emit("CALL 0400",  {0xCD, 0x00, 0x04}, [](St& s, const St&) { s.sp -= 2; });
   org = 0x0400;
   emit("RET",        {0xC9},             [](St& s, const St&) { s.sp += 2; });
   org = ret_to;
   emit("LD HL,0500", {0x21, 0x00, 0x05}, [](St& s, const St&) { s.hl = 0x0500; });
   emit("JP (HL)",    {0xE9});
   uint16_t back = org;
   org = 0x0500;
   emit("JP zpět",    {0xC3, B8(back), HI(back)});
   org = back;
   emit("IN A,(20)",  {0xDB, 0x20},       [](St& s, const St&) { s.a = 0xA5; });
   set_af(0x1200 | fY | fC);
   emit("LD BC,1020", {0x01, 0x20, 0x10}, [](St& s, const St&) { s.bc = 0x1020; });
   emit("IN B,(C)",   {0xED, 0x40},       [](St& s, const St&) { s.bc = 0xA520; s.f = (s.f & (fC | fY | fX)) | szp(0xA5); });
   emit("LD A,01",    {0x3E, 0x01},       [](St& s, const St&) { s.a = 0x01; });
   emit("NEG",        {0xED, 0x44},       [](St& s, const St&) { s.a = 0xFF; s.f = 0xBB; s.fk = true; });
   emit("SET 3,(IX+5),B (DDCB, nedok.)", {0xDD, 0xCB, 0x05, 0xD8}, [](St& s, const St&) { s.bc = (s.bc & 0xFF) | 0x7F00; });
   emit("EXX (Alternate = 1 pro DIRSet)", {0xD9}, [](St& s, const St&) { std::swap(s.bc, s.bc_); std::swap(s.de, s.de_); std::swap(s.hl, s.hl_); });

   // ---- DIRSet: nový stav, PC na výpisovou rutinu
   St& n = dirst;
   auto r16 = [&]() { return (uint16_t)rng(); };
   n.a = rng(); n.f = rng(); n.a_ = rng(); n.f_ = rng(); n.i = rng(); n.r = rng();
   n.bc = r16(); n.de = r16(); n.hl = r16(); n.bc_ = r16(); n.de_ = r16(); n.hl_ = r16();
   n.ix = r16(); n.iy = r16(); n.sp = 0xE000; n.pc = 0x0600;
   n.iff1 = 1; n.iff2 = 1; n.im = 1; n.fk = n.fk_ = true;
   emit("(stráž: sem se nemá dojít)", {0x76});
   prog.back().dirset = true;

   org = 0x0600;
   auto push = [](St& s, const St&) { s.sp -= 2; };
   emit("PUSH AF", {0xF5}, push); emit("PUSH BC", {0xC5}, push);
   emit("PUSH DE", {0xD5}, push); emit("PUSH HL", {0xE5}, push);
   emit("PUSH IX", {0xDD, 0xE5}, push); emit("PUSH IY", {0xFD, 0xE5}, push);
   emit("EXX",       {0xD9}, [](St& s, const St&) { std::swap(s.bc, s.bc_); std::swap(s.de, s.de_); std::swap(s.hl, s.hl_); });
   emit("EX AF,AF'", {0x08}, [](St& s, const St&) { std::swap(s.a, s.a_); std::swap(s.f, s.f_); std::swap(s.fk, s.fk_); });
   emit("PUSH AF'", {0xF5}, push); emit("PUSH BC'", {0xC5}, push);
   emit("PUSH DE'", {0xD5}, push); emit("PUSH HL'", {0xE5}, push);
   emit("LD A,I",   {0xED, 0x57}, [](St& s, const St&) {
      s.a = s.i; s.f = (s.f & (fC | fY | fX)) | (s.a & fS) | (s.a == 0 ? fZ : 0) | (s.iff2 ? fP : 0); });
   emit("PUSH AF",  {0xF5}, push);
   halt_addr = org;
   emit("HALT",     {0x76});
   image[0x0038] = 0x76;                       // obsluha IM 1: HALT
}

int main(int argc, char** argv) {
   Verilated::commandArgs(argc, argv);
   t = new Vtb_regs;

   St dirst; uint16_t halt_addr = 0;
   build(dirst, halt_addr);

   t->run = 1; t->rst_n = 0; t->int_n = 1; t->io_val = 0xA5; t->dirset = 0;
   t->clk = 0; t->eval();        // první eval je inicializace, hranu by nechytil
   for (int a = 0; a < 65536; a++) { t->mem_we = 1; t->mem_a = a; t->mem_d = image[a]; tick(); }
   t->mem_we = 0;
   for (int i = 0; i < 60; i++) tick();
   t->rst_n = 1;
   if (getenv("TB_TRACE")) {
      for (int a = 0; a < 6; a++) { t->mem_a = a; t->eval(); printf("mem[%d]=%02X ", a, t->mem_q); }
      printf("\n");
      for (int i = 0; i < 80; i++) { tick(); printf("%3d A=%04X M1=%d MREQ=%d RD=%d WR=%d mc=%d ts=%d pre=%d\n", i, t->addr, t->m1_n, t->mreq_n, t->rd_n, t->wr_n, t->mc, t->ts, t->prefix); }
      return 0;
   }

   printf("=== 1. hranice instrukcí a REG, 2. DIRSet ===\n");
   St exp{}; size_t j = 0;            // j = instrukce, která na hranici začíná
   bool prev_bnd = false, prev_m1 = false, first = true;
   int m1s = 0, bounds = 0;
   bool dirset_done = false;

   for (long i = 0; i < 400000 && t->halt_n; i++) {
      tick();
      bool m1 = !t->m1_n;
      if (m1 && !prev_m1) m1s++;
      prev_m1 = m1;

      bool bnd = t->mc == 1 && t->ts == 2 && t->prefix == 0;
      if (bnd && !prev_bnd) {
         t->run = 0;                                   // zastavit CE
         St got = from_reg(t->reg_o);
         char where[96];
         if (first) {
            exp = got; first = false;                  // stav po resetu
            if (got.pc != prog[0].addr) { printf("  CHYBA první hranice PC=%04X\n", got.pc); fails++; }
         } else {
            const Step& s = prog[j];
            St before = exp;
            exp.r = (exp.r & 0x80) | ((exp.r + m1s) & 0x7F);   // R: +1 za každý M1
            if (s.fx) s.fx(exp, before);
            j++;
            if (j >= prog.size()) { printf("  CHYBA program skončil dřív než CPU\n"); fails++; break; }
            exp.pc = prog[j].addr;
            snprintf(where, sizeof where, "po %s", s.name.c_str());
            if (cmp(where, exp, got)) bounds++;
            exp = got.pc == exp.pc ? exp : got;        // po chybě pokračuj ze skutečného stavu
         }
         m1s = 0;

         if (prog[j].dirset) {
            // DIRSet při zastaveném CE, pak zpětné čtení
            to_reg(t->dir, dirst);
            t->dirset = 1; tick(); t->dirset = 0; tick();
            St rb = from_reg(t->reg_o);
            cmp("REG hned po DIRSet", dirst, rb);
            exp = dirst; j++;                          // stráž se neprovede, běží rutina
            if (prog[j].addr != dirst.pc) { printf("  CHYBA rutina není na PC z DIRSet\n"); fails++; }
            dirset_done = true;
         }
         t->run = 1;
      }
      prev_bnd = bnd;
   }
   printf("  hranic zkontrolováno: %d, instrukcí v programu: %zu, DIRSet: %s\n",
          bounds, prog.size(), dirset_done ? "ano" : "NE");
   if (!dirset_done) fails++;
   if (t->halt_n) { printf("  CHYBA CPU nedošel na HALT\n"); fails++; }
   else if (prog[j].addr != halt_addr) { printf("  CHYBA HALT na špatném místě (krok %zu)\n", j); fails++; }

   // ---- zásobník z výpisové rutiny (zápisy po sběrnici)
   printf("=== 2b. zásobník výpisové rutiny ===\n");
   auto rd16 = [](uint16_t a) {
      t->mem_a = a; t->eval(); uint16_t lo = t->mem_q;
      t->mem_a = a + 1; t->eval(); return (uint16_t)(lo | (t->mem_q << 8)); };
   const St& n = dirst;
   uint8_t fI = (n.f_ & (fC | fY | fX)) | (n.i & fS) | (n.i == 0 ? fZ : 0) | fP;
   struct { const char* nm; uint16_t v; } want[] = {
      {"AF", (uint16_t)(n.a << 8 | n.f)}, {"BC", n.bc}, {"DE", n.de}, {"HL", n.hl},
      {"IX", n.ix}, {"IY", n.iy},
      {"AF'", (uint16_t)(n.a_ << 8 | n.f_)}, {"BC'", n.bc_}, {"DE'", n.de_}, {"HL'", n.hl_},
      {"A=I,F", (uint16_t)(n.i << 8 | fI)},
   };
   int k = 0, bad = 0;
   for (auto& w : want) {
      uint16_t got = rd16(n.sp - 2 * (++k));
      if (got != w.v) { printf("  CHYBA %-6s v paměti %04X, čekáno %04X\n", w.nm, got, w.v); bad++; }
   }
   printf("  %d slov, špatně %d\n", k, bad);
   fails += bad;

   // ---- IM 1 + IFF1 z DIRSet: INT během HALT -> RST 38h
   printf("=== 3. IM/IFF z DIRSet: INT v HALT ===\n");
   t->int_n = 0;
   bool hit = false;
   for (long i = 0; i < 2000 && !hit; i++) {
      tick();
      if (!t->iorq_n && !t->m1_n) t->int_n = 1;
      if (!t->m1_n && !t->mreq_n && !t->rd_n && t->addr == 0x0038) hit = true;
   }
   uint16_t ret = rd16(n.sp - 2 * k - 2);
   printf("  skok na 0038h: %s, návratová adresa %04X (čekáno %04X)\n", hit ? "ano" : "NE", ret, (uint16_t)(halt_addr + 1));
   if (!hit || ret != (uint16_t)(halt_addr + 1)) fails++;

   printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails);
   delete t;
   return fails ? 1 : 0;
}
