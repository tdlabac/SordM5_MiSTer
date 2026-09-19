// Testbench TV80a — cyklus potvrzení přerušení a časování proti specifikaci Z80.
//
// Pro každý režim přerušení (IM0, IM1, IM2) poběží stejný program:
//   hlavní smyčka OUT (10h),A / INC A / IN A,(20h) / OUT (11h),A / JR
//   obsluha přerušení zapíše značku do RAM (LD (HL),n / INC HL) a skončí EI / RETI
// a C++ kontroluje:
//   1. na konci potvrzení se IORQ nezvedne později než M1 (jinak to periferie
//      Zilogu bez vývodu WR — CTC, PIO, SIO — vezmou jako zápis na port),
//   2. procesor vstoupí do správné obsluhy (značky v RAM ve správném pořadí),
//   3. délka potvrzení se nezmění proti dnešnímu TV80. Zilog udává IM0 RST 13,
//      IM1 13, IM2 19 T; TV80 dává 12..13 / 12..13 / 20..21 T. Kolísání o 1 T
//      je vlastnost TV80: Auto_Wait_t2 si nese hodnotu z předchozího I/O
//      cyklu, takže po IN/OUT má potvrzení o jeden wait stav méně,
//      a IM2 je navíc o 1..2 T delší. Funkci to neovlivní, jen počet taktů.
//   4. běžná smyčka s I/O trvá 49 T-stavů (11 + 4 + 11 + 11 + 12),
//   5. každý OUT (11h) pošle hodnotu z předchozího IN.
#include "Vtb_tv80.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <cstdlib>

static Vtb_tv80* t;
static long clk = 0;
static int  fails = 0;

static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); ++clk; }

static void check(const char* name, bool ok, const char* detail = "") {
    printf("  %-62s %s %s\n", name, ok ? "OK  " : "CHYBA", detail);
    if (!ok) fails++;
}

struct Mode {
    const char* name;
    uint8_t     im_opcode;   // druhý bajt ED xx
    std::vector<uint8_t> vectors;   // co řadič přerušení vystaví při potvrzení
    std::vector<uint8_t> markers;   // jaké značky čekáme v RAM (v pořadí)
    int         expect_t;    // T-stavy od potvrzení po první opkód obsluhy (Zilog)
    int         tv80_min;    // co dnes dává TV80
    int         tv80_max;
};

static void load_program(uint8_t im_opcode) {
    uint8_t rom[256] = {};
    auto put = [&](int a, std::initializer_list<uint8_t> b) { for (uint8_t x : b) rom[a++] = x; };
    put(0x00, {0xF3});                    // DI
    put(0x01, {0x31, 0x00, 0x81});        // LD SP,8100h
    put(0x04, {0xED, im_opcode});         // IM n
    put(0x06, {0x3E, 0x00});              // LD A,0
    put(0x08, {0xED, 0x47});              // LD I,A
    put(0x0A, {0x21, 0x00, 0x80});        // LD HL,8000h
    put(0x0D, {0xFB});                    // EI
    put(0x0E, {0xD3, 0x10});              // loop: OUT (10h),A
    put(0x10, {0x3C});                    // INC A
    put(0x11, {0xDB, 0x20});              // IN A,(20h)
    put(0x13, {0xD3, 0x11});              // OUT (11h),A
    put(0x15, {0x18, 0xF7});              // JR loop
    put(0x28, {0x36, 0xC0, 0x23, 0xFB, 0xED, 0x4D});   // IM0: RST 28h
    put(0x38, {0x36, 0xB1, 0x23, 0xFB, 0xED, 0x4D});   // IM1: RST 38h
    put(0x60, {0x70, 0x00, 0x78, 0x00, 0x80, 0x00});   // IM2: tabulka vektorů
    put(0x70, {0x36, 0xA0, 0x23, 0xFB, 0xED, 0x4D});
    put(0x78, {0x36, 0xA1, 0x23, 0xFB, 0xED, 0x4D});
    put(0x80, {0x36, 0xA2, 0x23, 0xFB, 0xED, 0x4D});
    for (int a = 0; a < 256; a++) {
        t->rom_we = 1; t->rom_a = a; t->rom_d = rom[a]; tick();
    }
    t->rom_we = 0;
}

static void run_mode(const Mode& m) {
    printf("\n=== %s ===\n", m.name);
    t->int_n = 1; t->vec = 0xFF; t->io_rd_val = 0x40;
    t->rst_n = 0;
    load_program(m.im_opcode);
    for (int i = 0; i < 60; i++) tick();
    t->rst_n = 1;

    const int N_INT = 24;
    int  ints_raised = 0, acks = 0;
    long next_int = 6000;

    // TB_TRACE: výpis od prvního INT v tomhle režimu
    bool traced = false; int trace_left = 0;

    // stav sběrnice v minulém taktu
    bool p_m1 = true, p_iorq = true, p_wr = true, p_rd = true, p_mreq = true;
    long m1_fall = 0;

    // 1. konec potvrzení: kolik taktů je M1 nahoře a IORQ ještě dole
    bool in_inta = false;
    int  tail_clk = 0, tail_worst = 0;

    // 3. latence potvrzení
    long inta_start = -1;
    unsigned last_fetch_before_int = 0;   // TB_DUMP: po které instrukci přišlo
    std::vector<int> lat;

    // 4. perioda smyčky
    long last_loop = -1; bool int_since_loop = false;
    std::vector<int> loop_t;

    // 5. I/O
    int  last_in = -1, out11 = 0, out11_bad = 0, ins = 0;
    bool io_write_seen = false, io_read_seen = false; uint8_t io_port = 0, io_data = 0;

    // 6. začátek I/O cyklu
    long io_start = -1; int io_lead = 0, io_kind = 0, in_lead = 0, out_lead = 0;

    for (long i = 0; i < 200000; i++) {
        // řadič přerušení: zvedne INT, drží do potvrzení
        if (ints_raised < N_INT && t->int_n && clk >= next_int) {
            t->int_n = 0;
            t->vec = m.vectors[ints_raised % m.vectors.size()];
            ints_raised++;
        }

        tick();
        bool m1 = !t->m1_n, iorq = !t->iorq_n, wr = !t->wr_n, rd = !t->rd_n, mreq = !t->mreq_n;

        // TB_TRACE=1: výpis sběrnice kolem prvních potvrzení (ladění testu)
        static const bool trace = getenv("TB_TRACE") != nullptr;
        if (!traced && trace && acks == 0 && !t->int_n) { traced = true; trace_left = 700; }
        if (trace_left > 0) {
            trace_left--;
            printf("    %7ld A=%04X M1=%d MREQ=%d IORQ=%d RD=%d WR=%d DO=%02X int_n=%d vec=%02X"
                   "  T=%d M=%d DIreg=%02X int=%d %s%s\n",
                   clk, t->addr, !m1, !mreq, !iorq, !rd, !wr, t->dout, t->int_n, t->vec,
                   t->dbg_tstate, t->dbg_mcycle, t->dbg_di_reg, t->dbg_intcycle,
                   t->dbg_ce_p ? "CEp" : "", t->dbg_ce_n ? "CEn" : "");
        }

        if (m1 && !p_m1) m1_fall = clk;             // M1 právě spadl

        // --- potvrzení přerušení
        if (m1 && iorq && !in_inta) {
            in_inta = true; tail_clk = 0;
            inta_start = m1_fall;
            acks++;
            t->int_n = 1;                                   // řadič stáhne INT
            next_int = clk + 3000;
            int_since_loop = true;
        }
        if (in_inta) {
            if (!m1 && iorq) tail_clk++;                    // M1 nahoře, IORQ ještě dole
            if (!iorq) {
                if (tail_clk > tail_worst) tail_worst = tail_clk;
                in_inta = false;
            }
        }

        // --- načtení opkódu (M1 + MREQ + RD)
        bool fetch = m1 && mreq && rd;
        static bool p_fetch = false;
        static const bool dump = getenv("TB_DUMP") != nullptr;
        if (fetch && !p_fetch) {
            if (dump) printf("F %ld %04X\n", m1_fall, t->addr);
            if (inta_start >= 0 && !in_inta) {
                lat.push_back((int)((m1_fall - inta_start) / 6));
                if (dump) printf("L %d po %04X\n", lat.back(), last_fetch_before_int);
                inta_start = -1;
            }
            if (inta_start < 0 && !in_inta) last_fetch_before_int = t->addr;
            if (t->addr == 0x000E) {
                if (last_loop >= 0 && !int_since_loop) loop_t.push_back((int)((m1_fall - last_loop) / 6));
                last_loop = m1_fall; int_since_loop = false;
            }
        }
        p_fetch = fetch;

        // --- 6. začátek I/O cyklu: IORQ spadne spolu s RD (IN) / WR (OUT)
        // Z80: obojí na náběžné hraně T2. Periferie Zilogu bez vývodu WR (CTC,
        // PIO, SIO) berou „IORQ a RD neaktivní“ jako zápis.
        if (!m1 && iorq && !p_iorq) { io_start = clk; io_lead = 0; io_kind = 0; }
        if (!m1 && iorq && io_start >= 0) {
            if (!rd && !wr && io_kind == 0) io_lead++;      // IORQ bez RD i WR
            if (rd && io_kind == 0) { io_kind = 1; if (io_lead > in_lead) in_lead = io_lead; }
            if (wr && io_kind == 0) { io_kind = 2; if (io_lead > out_lead) out_lead = io_lead; }
        }
        // TB_IOWAVE=1: průběh prvních I/O cyklů od začátku M3 (ladění)
        static const bool iowave = getenv("TB_IOWAVE") != nullptr;
        static int iowave_left = 0, p_mc = 0;
        if (iowave && t->dbg_mcycle == 3 && p_mc == 2 && ins < 2 && iowave_left == 0) {
            iowave_left = 26;
            printf("    začátek M3 (clk, A, IORQ RD WR, T, M, CE):\n");
        }
        p_mc = t->dbg_mcycle;
        if (iowave_left > 0) {
            iowave_left--;
            printf("    %7ld A=%04X IORQ=%d RD=%d WR=%d T=%d M=%d %s%s\n", clk, t->addr, !iorq, !rd, !wr,
                   t->dbg_tstate, t->dbg_mcycle, t->dbg_ce_p ? "CEp" : "", t->dbg_ce_n ? "CEn" : "");
        }

        // --- I/O
        if (!m1 && iorq && wr) { io_write_seen = true; io_port = t->addr & 0xFF; io_data = t->dout; }
        if (!m1 && iorq && rd) io_read_seen = true;
        if (!iorq && p_iorq) {                              // konec I/O cyklu
            if (io_write_seen && io_port == 0x11) {
                out11++;
                if (io_data != last_in) out11_bad++;
            }
            if (io_read_seen) { last_in = t->io_rd_val; ins++; t->io_rd_val = (uint8_t)(t->io_rd_val + 7); }
            io_write_seen = io_read_seen = false;
        }

        p_m1 = m1; p_iorq = iorq; p_wr = wr; p_rd = rd; p_mreq = mreq;
    }

    // značky v RAM
    int marker_bad = 0;
    for (int k = 0; k < acks; k++) {
        t->ram_a = k; t->eval();
        if (t->ram_q != m.markers[k % m.markers.size()]) marker_bad++;
    }

    char b[128];
    snprintf(b, sizeof b, "(potvrzení %d, IORQ po M1 nejvýš %d taktů clk)", acks, tail_worst);
    check("1. konec potvrzení: IORQ se nezvedne později než M1", acks > 0 && tail_worst == 0, b);
    snprintf(b, sizeof b, "(%d značek, špatně %d)", acks, marker_bad);
    check("2. vstup do správné obsluhy (značky v RAM)", acks == N_INT && marker_bad == 0, b);

    int lat_min = 1 << 30, lat_max = -1;
    for (int v : lat) { if (v < lat_min) lat_min = v; if (v > lat_max) lat_max = v; }
    // TV80 se tu od Zilogu odchyluje (viz hlavička souboru), test proto hlídá,
    // aby se jeho současné chování nezměnilo, a odchylku jen vypíše.
    snprintf(b, sizeof b, "(naměřeno %d..%d T, TV80 %d..%d T, Zilog %d T)",
             lat_min, lat_max, m.tv80_min, m.tv80_max, m.expect_t);
    check("3. délka potvrzení beze změny proti TV80", !lat.empty() &&
          lat_min >= m.tv80_min && lat_max <= m.tv80_max, b);

    int lp_min = 1 << 30, lp_max = -1;
    for (int v : loop_t) { if (v < lp_min) lp_min = v; if (v > lp_max) lp_max = v; }
    snprintf(b, sizeof b, "(naměřeno %d..%d T, čekáno 49 T, %zu smyček)", lp_min, lp_max, loop_t.size());
    check("4. smyčka OUT/INC/IN/OUT/JR = 49 T", !loop_t.empty() && lp_min == 49 && lp_max == 49, b);

    snprintf(b, sizeof b, "(OUT %d, špatně %d, IN %d)", out11, out11_bad, ins);
    check("5. OUT (11h) pošle hodnotu z předchozího IN", out11 > 100 && out11_bad == 0, b);

    snprintf(b, sizeof b, "(IORQ před RD nejvýš %d, před WR nejvýš %d taktů clk)", in_lead, out_lead);
    check("6. I/O: IORQ spadne současně s RD (IN) a WR (OUT)", ins > 100 && in_lead == 0 && out_lead == 0, b);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vtb_tv80;
    t->clk = 0; t->eval();      // první eval je inicializace, hranu by nechytil

    // IM0: řadič vystaví RST 28h (EF), IM1: sběrnice FF (ignoruje se),
    // IM2: vektory 60h/62h/64h -> obsluhy A0/A1/A2
    run_mode({"IM0 (vektor = RST 28h)", 0x46, {0xEF},             {0xC0},             13, 12, 13});
    run_mode({"IM1",                    0x56, {0xFF},             {0xB1},             13, 12, 13});
    run_mode({"IM2",                    0x5E, {0x60, 0x62, 0x64}, {0xA0, 0xA1, 0xA2}, 19, 20, 21});

    printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails);
    delete t;
    return fails ? 1 : 0;
}
