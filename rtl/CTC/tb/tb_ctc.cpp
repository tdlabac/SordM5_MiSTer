// Testbench pro rtl/CTC. Overuje veci, ktere se opravovaly proti datasheetu.
#include "Vctc.h"
#include <verilated.h>
#include <cstdio>
#include <cstdint>

static Vctc*   dut;
static int     ce_cnt = 0;
static long    ce_ticks = 0;
static int     fails = 0;

static void tick() {
    dut->ce_3m58_p = (ce_cnt == 0);
    if (ce_cnt == 0) ce_ticks++;
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
    ce_cnt = (ce_cnt + 1) % 6;   // CE 1 z 6 taktu clk_sys
}

static void ticks(int n) { for (int i = 0; i < n; i++) tick(); }

static void bus_idle() {
    dut->en_n = 1; dut->iorq_n = 1; dut->m1_n = 1; dut->rd_n = 1;
}

static void io_write(int ch, uint8_t data) {
    dut->cs = ch; dut->dIn = data;
    dut->en_n = 0; dut->iorq_n = 0; dut->m1_n = 1; dut->rd_n = 1;
    ticks(4);                     // IORQ drzi nekolik taktu clk_sys
    bus_idle();
    ticks(4);
}

static uint8_t io_read(int ch) {
    dut->cs = ch;
    dut->en_n = 0; dut->iorq_n = 0; dut->m1_n = 1; dut->rd_n = 0;
    ticks(2);
    uint8_t v = dut->dOut;
    bus_idle();
    ticks(2);
    return v;
}

static bool ack_stable = true;   // byl vektor po celou dobu IORQ stejny?

// Potvrzeni preruseni tak, jak ho dela TV80:
//   - M1 pada o takt driv nez IORQ,
//   - na konci M1 vyskoci NAHORU o 3 takty clk_sys driv nez IORQ
//     (M1 se meni na CE_p, IORQ na CE_n),
//   - na adrese je refresh (I, R); dekoder GA015 bere CTC jen podle A[7:4]
//     a IORQ, takze pri R s hornim nibblem 0 je CTC vybrane (en_n=0),
//     kanal 0, a na datech je, co zrovna zbylo na DO.
// V tom okne vypada sbernice jako zapis do CTC — CTC ho nesmi vzit.
static uint8_t tail_data = 0x00;  // DO v okne na konci (00 = D0=0 -> vektor)
static int     tail_cs   = 0;

static uint8_t int_ack() {
    dut->rd_n = 1;
    dut->m1_n = 0;               // M1 pada o takt driv nez IORQ
    tick();
    dut->iorq_n = 0;
    dut->en_n = 0;               // refresh adresa trefi dekoder CTC
    dut->cs   = tail_cs;
    dut->dIn  = tail_data;
    uint8_t sampled = 0, first = 0;
    ack_stable = true;
    for (int t = 0; t < 12; t++) {
        dut->eval();
        uint8_t v = dut->dOut;
        if (t == 0) first = v;
        else if (v != first) ack_stable = false;
        if (t == 6) sampled = v; // tady vektor cte TV80
        tick();
    }
    dut->m1_n = 1;               // konec: M1 nahoru, IORQ jeste dole
    ticks(3);
    bus_idle();
    ticks(4);
    return sampled;
}

// Fetch opkodu jako u TV80: RD drzi od CE_n v T1 do CE_n v T3, tedy pres
// dve CE_p (12 taktu clk_sys). RETI se vzorkuje jen na CE_p.
static void m1_fetch(uint8_t op) {
    dut->dInCpu = op;
    dut->m1_n = 0; dut->iorq_n = 1; dut->rd_n = 0;
    ticks(12);
    bus_idle();
    ticks(6);
}

static void do_reti() { m1_fetch(0xED); m1_fetch(0x4D); }

static void hw_reset() {
    bus_idle();
    dut->iei = 1; dut->clk_trg = 0; dut->dInCpu = 0; dut->dIn = 0; dut->cs = 0;
    dut->res_n = 0;
    ticks(20);
    dut->res_n = 1;
    ticks(6);
}

// Ceka, nez int_n spadne. Vraci pocet CE tiku (muze byt 0), -1 pri timeoutu.
static long wait_int(long max_ce) {
    long start = ce_ticks;
    while (ce_ticks - start < max_ce) {
        tick();
        if (!dut->int_n) return ce_ticks - start;
    }
    return -1;
}
static bool got_int(long v) { return v >= 0; }

static void check(const char* name, bool ok, const char* detail = "") {
    printf("%-58s %s %s\n", name, ok ? "OK  " : "CHYBA", detail);
    if (!ok) fails++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vctc;

    // ---------------------------------------------------------------- 1
    // Timer mode, predelicka /16, TC=5, preruseni povolene.
    // control = D7 int | D6=0 timer | D5=0 /16 | D4=0 | D3=0 auto | D2 TC | D0
    hw_reset();
    io_write(0, 0x85);
    io_write(0, 5);
    long t1 = wait_int(400);
    check("1. timer /16, TC=5 -> preruseni po ~72 CE",
          t1 > 60 && t1 < 90, t1 < 0 ? "(timeout)" : "");
    if (t1 > 0) printf("     namereno %ld CE tiku\n", t1);

    // ---------------------------------------------------------------- 2
    // Vektor: zapis na kanal 0 s D0=0. Ack ma vratit vektor s cislem kanalu.
    hw_reset();
    io_write(0, 0xE0);            // irqVect = 0b11100
    io_write(0, 0x85);
    io_write(0, 5);
    wait_int(400);
    uint8_t v2 = int_ack();
    check("2. vektor z kanalu 0, ack vraci {D7:D3, kanal, 0}", v2 == 0xE0);
    if (v2 != 0xE0) printf("     dostal jsem 0x%02X, cekal 0xE0\n", v2);

    // ---------------------------------------------------------------- 3
    // Zapis vektoru na kanal 2 se musi ignorovat (datasheet: jen kanal 0).
    hw_reset();
    io_write(0, 0xE0);
    io_write(2, 0x40);            // pokus prepsat vektor jinym kanalem
    io_write(0, 0x85);
    io_write(0, 5);
    wait_int(400);
    uint8_t v3 = int_ack();
    check("3. zapis vektoru na kanal 2 se ignoruje", v3 == 0xE0);
    if (v3 != 0xE0) printf("     dostal jsem 0x%02X, cekal 0xE0\n", v3);

    // ---------------------------------------------------------------- 4
    // D4: counter mode, sestupna vs nabezna hrana CLK/TRG.
    for (int edge = 0; edge < 2; edge++) {
        hw_reset();
        // D6=1 counter, D4=edge, D7 int, D2 TC, D0
        io_write(1, 0xC5 | (edge ? 0x10 : 0x00));
        io_write(1, 2);           // dva eventy na preruseni

        // Dva pulzy na clk_trg[1]. Nejdriv hrany, ktere NEMAJI pocitat.
        for (int i = 0; i < 4; i++) {
            dut->clk_trg = edge ? 0x0 : 0x2;   // pri edge=1 posilame sestupne
            ticks(12);
            dut->clk_trg = edge ? 0x2 : 0x0;
            ticks(12);
            // pri edge=0 (sestupna) prave probehla 1 sestupna hrana za cyklus,
            // takze tohle je jen prohozene poradi — obe varianty dodaji hrany.
        }
        bool got = !dut->int_n;
        char buf[64];
        snprintf(buf, sizeof buf, "(edge=%d)", edge);
        check(edge ? "4b. counter mode, nabezna hrana pocita"
                   : "4a. counter mode, sestupna hrana pocita", got, buf);
    }

    // ---------------------------------------------------------------- 5
    // D4 rozlisuje: pri D4=0 (sestupna) nesmi nabezna hrana sama pocitat
    // dost na preruseni, kdyz jich poslu jen tolik, kolik je TC.
    hw_reset();
    io_write(1, 0xC5);            // counter, sestupna, TC follows, int
    io_write(1, 200);             // hodne, at se to nepretoci
    for (int i = 0; i < 100; i++) { // 100 nabeznych + 100 sestupnych hran
        dut->clk_trg = 0x2; ticks(8);
        dut->clk_trg = 0x0; ticks(8);
    }
    uint8_t c5 = io_read(1);
    // 100 sestupnych hran z 200 -> citac ma byt 100
    check("5. D4=0 pocita jen sestupne hrany (citac 200-100)", c5 == 100);
    printf("     citac = %u, cekal 100\n", c5);

    // ---------------------------------------------------------------- 6
    // ZC/TO musi byt pulz. TC=1 drive zaseklo zc_to trvale v jednicce.
    hw_reset();
    io_write(2, 0x05);            // timer /16, TC follows, int zakazane
    io_write(2, 1);               // TC=1 - kriticky pripad
    int zc_high = 0, zc_edges = 0, last = 0;
    for (int i = 0; i < 3000; i++) {
        tick();
        int z = (dut->zc_to >> 2) & 1;
        if (z) zc_high++;
        if (z && !last) zc_edges++;
        last = z;
    }
    check("6a. ZC/TO pri TC=1 pulzuje (vic nez jedna hrana)", zc_edges > 3);
    check("6b. ZC/TO neni zaseknuty v jednicce", zc_high < 3000 / 2);
    printf("     hran %d, v jednicce %d z 3000 taktu\n", zc_edges, zc_high);

    // ---------------------------------------------------------------- 7
    // Reset kanalu (D1) musi zrusit cekajici preruseni a pustit int_n.
    hw_reset();
    io_write(3, 0x85);
    io_write(3, 5);
    long t7 = wait_int(400);
    bool asserted = got_int(t7);
    io_write(3, 0x03);            // D0=1, D1=1 -> reset kanalu
    ticks(10);
    check("7. reset kanalu (D1) pusti int_n", asserted && dut->int_n);

    // ---------------------------------------------------------------- 8
    // Hardwarovy reset musi smazat control, tedy i D7 (int enable).
    hw_reset();
    io_write(0, 0x85);
    io_write(0, 5);
    wait_int(400);
    hw_reset();                   // po resetu musi byt ticho
    long t8 = wait_int(600);
    check("8. hw reset zakaze preruseni (control smazany)", t8 < 0);

    // ---------------------------------------------------------------- 9
    // Zastaveny kanal drzi hodnotu citace (drive vracel 0).
    hw_reset();
    io_write(1, 0x05);            // timer /16, TC follows, int zakazane
    io_write(1, 200);
    ticks(600);                   // chvili pocitej
    io_write(1, 0x03);            // reset kanalu
    uint8_t a = io_read(1);
    ticks(50);
    uint8_t b = io_read(1);
    check("9. zastaveny kanal drzi citac", a != 0 && a == b);
    printf("     citac po zastaveni = %u, po 50 taktech = %u\n", a, b);

    // ---------------------------------------------------------------- 10
    // iei=0: CTC nesmi zadat o preruseni ani dat vektor.
    hw_reset();
    dut->iei = 0;
    io_write(0, 0x85);
    io_write(0, 5);
    long t10 = wait_int(400);
    check("10a. iei=0 blokuje zadost o preruseni", t10 < 0);
    dut->iei = 1;
    long t10b = wait_int(400);
    check("10b. po iei=1 zadost projde", got_int(t10b));

    // ---------------------------------------------------------------- 11
    // IEO: v idle a bez cekajiciho preruseni pousti prioritu dal.
    hw_reset();
    dut->iei = 1;
    ticks(4);
    bool ieo_idle = dut->ieo;
    io_write(0, 0x85);
    io_write(0, 5);
    wait_int(400);
    bool ieo_busy = dut->ieo;
    check("11. ieo=1 v idle, ieo=0 kdyz CTC zada o preruseni",
          ieo_idle && !ieo_busy);

    // ---------------------------------------------------------------- 12
    // RETI uvolni obsluhu: po ack a RETI muze prijit dalsi preruseni.
    hw_reset();
    io_write(0, 0x85);
    io_write(0, 5);
    wait_int(400);
    int_ack();
    ticks(10);
    bool quiet_before_reti = dut->int_n;
    long t12a = wait_int(400);    // ve WAIT_RETI nesmi znovu zadat
    do_reti();
    long t12b = wait_int(400);
    check("12. bez RETI zadna dalsi zadost, po RETI ano",
          quiet_before_reti && t12a < 0 && got_int(t12b));

    // ---------------------------------------------------------------- 13
    // D3=1 v timer mode: casovac nesmi startovat, dokud neprijde hrana CLK/TRG.
    hw_reset();
    // D7 int | D6=0 timer | D5=0 /16 | D4=1 nabezna | D3=1 trigger | D2 TC | D0
    io_write(0, 0x9D);
    io_write(0, 5);
    long t13a = wait_int(400);            // bez hrany se nesmi rozjet
    dut->clk_trg = 0x1;                   // nabezna hrana na TRG0
    ticks(4);
    long t13b = wait_int(400);
    check("13. D3=1 startuje az hranou CLK/TRG", t13a < 0 && got_int(t13b));
    if (t13b >= 0) printf("     po hrane preruseni za %ld CE\n", t13b);

    // ---------------------------------------------------------------- 14
    // D5: predelicka /256 ma byt 16x pomalejsi nez /16.
    hw_reset();
    io_write(0, 0x85);                    // /16
    io_write(0, 2);
    long t14a = wait_int(3000);
    hw_reset();
    io_write(0, 0xA5);                    // D5=1 -> /256
    io_write(0, 2);
    long t14b = wait_int(3000);
    bool ratio_ok = got_int(t14a) && got_int(t14b) &&
                    t14b > t14a * 12 && t14b < t14a * 20;
    check("14. predelicka /256 je ~16x pomalejsi nez /16", ratio_ok);
    printf("     /16 = %ld CE, /256 = %ld CE\n", t14a, t14b);

    // ---------------------------------------------------------------- 15
    // Kanal 3 jako VDP v monitor ROM M5: vektor 0x00, counter, sestupna hrana,
    // TC=1. Spravny vektor je 0x06 a musi vydrzet cely cyklus potvrzeni.
    hw_reset();
    io_write(0, 0x00);
    io_write(3, 0xC7);
    io_write(3, 0x01);
    dut->clk_trg = 0x8; ticks(12);
    dut->clk_trg = 0x0;                   // sestupna hrana na CK3
    long t15 = wait_int(100);
    uint8_t v15 = int_ack();
    check("15. kanal 3: vektor 0x06 v miste cteni TV80",
          got_int(t15) && v15 == 0x06);
    check("15b. vektor stabilni po celou dobu M1+IORQ", ack_stable);
    printf("     precteno 0x%02X\n", v15);

    // ---------------------------------------------------------------- 16
    // Mimo povoleny vystup vraci dOut 0xFF (sluceni periferii pres AND).
    hw_reset();
    ticks(4);
    dut->eval();
    check("16. klid na sbernici -> dOut 0xFF", dut->dOut == 0xFF);

    // Zapis do CTC: vybrano, ale RD neaktivni -> nesmi budit sbernici.
    io_write(1, 0x05);                    // timer, TC follows
    dut->cs = 1; dut->dIn = 50;
    dut->en_n = 0; dut->iorq_n = 0; dut->m1_n = 1; dut->rd_n = 1;
    ticks(2);
    bool ff_write = (dut->dOut == 0xFF);
    bus_idle(); ticks(4);
    check("17. zapis do CTC -> dOut 0xFF", ff_write);

    // Cteni jineho zarizeni (IORQ, ale CTC nevybrane).
    dut->cs = 0; dut->en_n = 1; dut->iorq_n = 0; dut->m1_n = 1; dut->rd_n = 0;
    ticks(2);
    bool ff_other = (dut->dOut == 0xFF);
    bus_idle(); ticks(4);
    check("18. cteni jineho I/O -> dOut 0xFF", ff_other);

    // Potvrzeni preruseni, na ktere CTC nezada.
    hw_reset();
    int_ack();
    uint8_t v19 = int_ack();
    check("19. ack bez zadosti CTC -> dOut 0xFF", v19 == 0xFF);

    // Potvrzeni, kdyz CTC zada, ale iei=0 (prednost ma nekdo pred nim).
    hw_reset();
    io_write(0, 0x85);
    io_write(0, 5);
    wait_int(400);
    dut->iei = 0;
    uint8_t v20 = int_ack();
    dut->iei = 1;
    check("20. ack s iei=0 -> dOut 0xFF", v20 == 0xFF);

    // ---------------------------------------------------------------- 21
    // Konec potvrzeni (M1=1, IORQ=0, RD=1) s D0=0 na kanal 0 nesmi prepsat
    // vektor. Pred opravou tady CTC zapsalo vektor 0 a dalsi preruseni
    // skocilo na spatnou adresu.
    hw_reset();
    io_write(0, 0xE0);
    io_write(0, 0x85);
    io_write(0, 5);
    tail_cs = 0; tail_data = 0x00;
    wait_int(400); int_ack(); do_reti();
    wait_int(400);
    uint8_t v21 = int_ack();
    check("21. konec potvrzeni neprepise vektor (druhy ack = 0xE0)", v21 == 0xE0);
    printf("     druhy vektor 0x%02X\n", v21);

    // ---------------------------------------------------------------- 22
    // Totez s ridicim slovem "reset kanalu" (D0=1, D1=1) na kanal, ktery
    // prave preruseni vyvolal - kanal se nesmi zastavit.
    hw_reset();
    io_write(0, 0xE0);
    io_write(1, 0x85);                    // kanal 1: timer /16, int
    io_write(1, 5);
    tail_cs = 1; tail_data = 0x03;
    wait_int(400); int_ack(); do_reti();
    long t22 = wait_int(400);
    check("22. konec potvrzeni neprogramuje kanal (dalsi preruseni prijde)", got_int(t22));
    tail_cs = 0; tail_data = 0x00;

    printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails);
    delete dut;
    return fails ? 1 : 0;
}
