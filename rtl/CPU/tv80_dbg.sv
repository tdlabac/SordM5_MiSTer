//============================================================================
//  tv80_dbg — obálka TV80a s debuggerem (návrh: doc/z80-debugger.md)
//
//  Porty sběrnice jsou stejné jako u TV80a, v SordM5.sv ji nahrazuje 1:1.
//  DEBUG = 0: jen holé TV80a, debugger se vůbec nepřeloží, freeze = 0.
//
//  Zastavení zmrazí celý počítač: výstup freeze jde do clock.sv, který
//  zastaví všechna ce_*. CE_n/CE_p sem proto chodí už zmrazené.
//
//  Místo zastavení je hranice instrukce: M1, TState 2, Prefix 0 (všechny
//  zápisy předchozí instrukce jsou hotové, PC = adresa nové instrukce,
//  opkód ještě není načtený). freeze naskočí v taktu clk_sys po hraně CE_p,
//  která hranici vytvořila; další CE CPU přijde nejdřív o 3 takty později.
//
//  Ovládání (zatím přímé porty, později registrový prostor debuggeru):
//    dbg_stop    1 = zastavit na nejbližší hranici a stát, 0 = běžet
//    dbg_step    pulz při zastavení: provést jednu instrukci a zastavit
//    dbg_dirset  pulz při zastavení: nahrát dbg_dir do registrů (DIRSet)
//    dbg_stopped počítač stojí na hranici instrukce
//    dbg_reg     snímek registrů (rozložení viz tv80.sv), platí při zastavení
//
//  Průhlednost (DEBUG = 1, v klidu) hlídá lockstep:
//    DUT_DBG=1 bash rtl/CPU/tb/run_lockstep.sh
//  Zmrazení celého počítače hlídá rtl/tb/run_freeze.sh.
//============================================================================

module tv80_dbg #(
    parameter       Mode      = 0,
                    R800_MULU = 1,
                    IOWait    = 1,
                    DEBUG     = 0
)(
    input           RESET_n,
    input           R800_mode,
    input           CE_n,
    input           CE_p,
    input           CLK_n,
    input           WAIT_n,
    input           INT_n,
    input           NMI_n,
    input           BUSRQ_n,
    output          M1_n,
    output          MREQ_n,
    output          IORQ_n,
    output          RD_n,
    output          WR_n,
    output          RFSH_n,
    output          HALT_n,
    output          BUSAK_n,
    output   [15:0] A,
    input     [7:0] DI,
    output    [7:0] DO,

    // debugger
    output          freeze,
    input           dbg_stop,
    input           dbg_step,
    input           dbg_dirset,
    input   [211:0] dbg_dir,
    output          dbg_stopped,
    output  [211:0] dbg_reg
);

    logic   [2:0]   mcycle, tstate;
    logic   [1:0]   prefix;
    logic           dirset;

    TV80a #(
        .Mode(Mode),
        .R800_MULU(R800_MULU),
        .IOWait(IOWait)
    ) cpu (
        .RESET_n(RESET_n),
        .R800_mode(R800_mode),
        .CE_n(CE_n),
        .CE_p(CE_p),
        .CLK_n(CLK_n),
        .WAIT_n(WAIT_n),
        .INT_n(INT_n),
        .NMI_n(NMI_n),
        .BUSRQ_n(BUSRQ_n),
        .M1_n(M1_n),
        .MREQ_n(MREQ_n),
        .IORQ_n(IORQ_n),
        .RD_n(RD_n),
        .WR_n(WR_n),
        .RFSH_n(RFSH_n),
        .HALT_n(HALT_n),
        .BUSAK_n(BUSAK_n),
        .A(A),
        .DI(DI),
        .DO(DO),
        .REG(dbg_reg),
        .DIRSet(dirset),
        .DIR(dbg_dir),
        .DbgMCycle(mcycle),
        .DbgTState(tstate),
        .DbgPrefix(prefix),
        .DbgIntCycle(),
        .DbgNMICycle()
    );

    generate
        if (DEBUG) begin : g_dbg
            // Hranice instrukce a její začátek (první takt, kdy platí).
            wire  bnd = mcycle == 3'd1 && tstate == 3'd2 && prefix == 2'b00;
            logic bnd_d;
            wire  bnd_entry = bnd && !bnd_d;

            logic stopped, stepping;

            always_ff @(posedge CLK_n or negedge RESET_n) begin
                if (!RESET_n) begin
                    bnd_d    <= 1'b0;
                    stopped  <= 1'b0;
                    stepping <= 1'b0;
                end else begin
                    bnd_d <= bnd;
                    if (stopped) begin
                        // Rozběh: krok, nebo konec požadavku na zastavení.
                        // Při rozběhu je bnd pořád 1 (CPU stojí v T2), takže
                        // bnd_entry přijde až na další hranici.
                        if (dbg_step) begin
                            stopped  <= 1'b0;
                            stepping <= 1'b1;
                        end else if (!dbg_stop)
                            stopped  <= 1'b0;
                    end else if (bnd_entry && (dbg_stop || stepping)) begin
                        stopped  <= 1'b1;
                        stepping <= 1'b0;
                    end
                end
            end

            assign freeze      = stopped;
            assign dbg_stopped = stopped;
            assign dirset      = stopped && dbg_dirset;   // DIRSet jen při stojícím CE
        end else begin : g_nodbg
            assign freeze      = 1'b0;
            assign dbg_stopped = 1'b0;
            assign dirset      = 1'b0;
        end
    endgenerate

endmodule
