//============================================================================
//  tv80_dbg — obálka TV80a s debuggerem (návrh: doc/z80-debugger.md)
//
//  Porty sběrnice jsou stejné jako u TV80a, v SordM5.sv ji nahrazuje 1:1.
//  DEBUG = 0: jen holé TV80a, debugger se vůbec nepřeloží, freeze = 0.
//  Rozhraní debuggeru: tv80_dbg_pkg::dbg_in_t / dbg_out_t.
//
//  Zastavení zmrazí celý počítač: výstup freeze jde do clock.sv, který
//  zastaví všechna ce_*. CE_n/CE_p sem proto chodí už zmrazené.
//
//  Hranice instrukce: M1, TState 2, Prefix 0, ne potvrzení INT/NMI. Všechny
//  zápisy předchozí instrukce jsou hotové, PC = adresa nové instrukce,
//  opkód ještě není načtený. freeze naskočí v taktu clk_sys po hraně CE_p,
//  která hranici vytvořila; další CE CPU přijde nejdřív o 3 takty později.
//  M1 potvrzení přerušení hranice není: zastavení uprostřed potvrzení by
//  periferii rozbilo vektor, krok do přerušení proto skončí na první
//  instrukci obsluhy.
//
//  Breakpointy (NBP slotů, tv80_dbg_pkg::bp_t):
//    EXEC   shoda PC na hranici, zastaví se před provedením instrukce
//    MRD/MWR/IORD/IOWR  vyhodnotí se na konci cyklu sběrnice (čtení: DI,
//           zápis: DO); fetch opkódu a refresh se do MRD nepočítají. Zásah
//           se poznačí a zastaví se na nejbližší hranici (instrukce se
//           dokončí). hit_pc = PC instrukce, která zásah způsobila.
//
//  Přístup do paměti (jen při zastavení): obálka převezme sběrnici
//  (M1_n = IORQ_n = RFSH_n = 1), 3 takty clk_sys drží MREQ + RD/WR a na konci
//  vzorkuje DI, pak 1 takt uvolní a 2 takty vrací sběrnici CPU (paměti jsou
//  synchronní, fetch musí mít znovu platná data). Po dobu mem_busy se
//  run/step/dirset ignorují.
//
//  Testy: rtl/CPU/tb/run_dbg.sh (breakpointy, krok, paměť),
//  rtl/tb/run_freeze.sh (celý počítač), lockstep DUT_DBG=1 (průhlednost).
//============================================================================

module tv80_dbg
   import tv80_dbg_pkg::*;
#(
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
    input  dbg_in_t  dbg_i,
    output dbg_out_t dbg_o
);

    logic   [2:0]   mcycle, tstate;
    logic   [1:0]   prefix;
    logic           intcycle, nmicycle;
    logic           dirset;
    logic           int_mask;
    logic  [211:0]  regs;

    // výstupy CPU, na sběrnici jdou přes multiplexor debuggeru
    logic   [15:0]  cA;
    logic    [7:0]  cDO;
    logic           cM1_n, cMREQ_n, cIORQ_n, cRD_n, cWR_n, cRFSH_n;

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
        .INT_n(INT_n | int_mask),
        .NMI_n(NMI_n),
        .BUSRQ_n(BUSRQ_n),
        .M1_n(cM1_n),
        .MREQ_n(cMREQ_n),
        .IORQ_n(cIORQ_n),
        .RD_n(cRD_n),
        .WR_n(cWR_n),
        .RFSH_n(cRFSH_n),
        .HALT_n(HALT_n),
        .BUSAK_n(BUSAK_n),
        .A(cA),
        .DI(DI),
        .DO(cDO),
        .REG(regs),
        .DIRSet(dirset),
        .DIR(dbg_i.dir),
        .DbgMCycle(mcycle),
        .DbgTState(tstate),
        .DbgPrefix(prefix),
        .DbgIntCycle(intcycle),
        .DbgNMICycle(nmicycle)
    );

    generate
        if (DEBUG) begin : g_dbg
            // ---------------------------------------------------------------
            // Hranice instrukce
            wire  bnd = mcycle == 3'd1 && tstate == 3'd2 && prefix == 2'b00 &&
                        !intcycle && !nmicycle;
            logic bnd_d;
            wire  bnd_entry = bnd && !bnd_d;

            // ---------------------------------------------------------------
            // Cykly sběrnice pro breakpointy: {IOWR, IORD, MWR, MRD, 0}
            wire [4:0] cyc = {
                !cIORQ_n && !cWR_n && cM1_n,
                !cIORQ_n && !cRD_n && cM1_n,
                !cMREQ_n && !cWR_n,
                !cMREQ_n && !cRD_n && cM1_n && cRFSH_n,
                1'b0 };
            logic [4:0]  cyc_d;
            logic [15:0] cyc_addr;
            logic [7:0]  cyc_data;
            // konec cyklu: minulý takt běžel, teď už ne (nebo jiný typ)
            wire  cyc_end = cyc_d != 5'd0 && cyc != cyc_d;

            // u I/O se porovnává jen A[7:0]
            wire [15:0] io_am = (cyc_d[4] | cyc_d[3]) ? 16'h00FF : 16'hFFFF;
            logic [NBP-1:0] acc_match, exec_match;
            always_comb
                for (int i = 0; i < NBP; i++) begin
                    acc_match[i]  = (dbg_i.bp[i].kind & cyc_d) != 5'd0 &&
                                    ((cyc_addr ^ dbg_i.bp[i].addr) & dbg_i.bp[i].amask & io_am) == 16'd0 &&
                                    ((cyc_data ^ dbg_i.bp[i].data) & dbg_i.bp[i].dmask) == 8'd0;
                    exec_match[i] = dbg_i.bp[i].kind[0] &&
                                    ((cA ^ dbg_i.bp[i].addr) & dbg_i.bp[i].amask) == 16'd0;
                end

            // ---------------------------------------------------------------
            // Řízení běhu
            logic           stopped, stepping, stop_req;
            reason_t        reason;
            logic           pend;           // zásah přístupem čeká na hranici
            logic [NBP-1:0] hit, pend_hit;
            logic [15:0]    hit_addr, hit_pc, pend_addr, pend_pc, pc_cur;
            logic [7:0]     hit_data, pend_data;

            // Přístup do paměti
            typedef enum logic [1:0] { M_IDLE, M_ACC, M_REL, M_SETTLE } mstate_t;
            mstate_t     mst;
            logic [1:0]  mcnt;
            logic        m_we;
            logic [15:0] m_addr;
            logic [7:0]  m_wdata, m_rdata;
            wire         busy = mst != M_IDLE;

            always_ff @(posedge CLK_n or negedge RESET_n) begin
                if (!RESET_n) begin
                    bnd_d    <= 1'b0;
                    cyc_d    <= '0;
                    stopped  <= 1'b0;
                    stepping <= 1'b0;
                    stop_req <= 1'b0;
                    reason   <= R_NONE;
                    pend     <= 1'b0;
                    hit      <= '0;
                    pend_hit <= '0;
                    mst      <= M_IDLE;
                    pc_cur   <= '0;
                end else begin
                    bnd_d <= bnd;

                    // --- sledování cyklů sběrnice (jen CPU, ne přístupy debuggeru)
                    cyc_d <= cyc;
                    if (cyc != 5'd0) begin
                        cyc_addr <= cA;
                        cyc_data <= (cyc[4] | cyc[2]) ? cDO : DI;
                    end
                    if (!stopped && cyc_end && acc_match != '0) begin
                        if (!pend) begin
                            pend_addr <= cyc_addr;
                            pend_data <= cyc_data;
                            pend_pc   <= pc_cur;
                        end
                        pend     <= 1'b1;
                        pend_hit <= pend_hit | acc_match;
                    end

                    if (dbg_i.stop && !stopped) stop_req <= 1'b1;

                    if (!stopped) begin
                        if (bnd_entry) begin
                            pc_cur <= cA;
                            if (pend) begin
                                stopped  <= 1'b1;
                                reason   <= R_ACC;
                                hit      <= pend_hit | exec_match;
                                hit_addr <= pend_addr;
                                hit_data <= pend_data;
                                hit_pc   <= pend_pc;
                            end else if (exec_match != '0) begin
                                stopped  <= 1'b1;
                                reason   <= R_EXEC;
                                hit      <= exec_match;
                                hit_addr <= cA;
                                hit_data <= '0;
                                hit_pc   <= cA;
                            end else if (stop_req || dbg_i.stop || stepping) begin
                                // (stop ve stejném taktu jako hranice se nesmí ztratit)
                                stopped  <= 1'b1;
                                reason   <= stepping ? R_STEP : R_STOP;
                                hit      <= '0;
                            end
                            if (pend || exec_match != '0 || stop_req || dbg_i.stop || stepping) begin
                                stepping <= 1'b0;
                                stop_req <= 1'b0;
                                pend     <= 1'b0;
                                pend_hit <= '0;
                            end
                        end
                    end else if (!busy) begin
                        // Rozběh. bnd zůstává 1 (CPU stojí v T2), takže
                        // bnd_entry přijde až na další hranici.
                        if (dbg_i.step) begin
                            stopped  <= 1'b0;
                            stepping <= 1'b1;
                            reason   <= R_NONE;
                        end else if (dbg_i.run) begin
                            stopped  <= 1'b0;
                            reason   <= R_NONE;
                        end
                    end

                    // --- přístup do paměti
                    case (mst)
                        M_IDLE:
                            if (stopped && dbg_i.mem_req) begin
                                mst     <= M_ACC;
                                mcnt    <= 2'd2;
                                m_we    <= dbg_i.mem_we;
                                m_addr  <= dbg_i.mem_addr;
                                m_wdata <= dbg_i.mem_wdata;
                            end
                        M_ACC:
                            if (mcnt == 2'd0) begin
                                m_rdata <= DI;
                                mst     <= M_REL;
                            end else
                                mcnt <= mcnt - 2'd1;
                        M_REL: begin
                            mst  <= M_SETTLE;
                            mcnt <= 2'd1;
                        end
                        M_SETTLE:
                            if (mcnt == 2'd0) mst <= M_IDLE;
                            else              mcnt <= mcnt - 2'd1;
                    endcase
                end
            end

            // ---------------------------------------------------------------
            // Sběrnice: CPU, nebo debugger (M_ACC/M_REL)
            wire own = mst == M_ACC || mst == M_REL;
            wire act = mst == M_ACC;
            assign A      = own ? m_addr  : cA;
            assign DO     = own ? m_wdata : cDO;
            assign M1_n   = own ? 1'b1    : cM1_n;
            assign MREQ_n = own ? !act    : cMREQ_n;
            assign IORQ_n = own ? 1'b1    : cIORQ_n;
            assign RD_n   = own ? !(act && !m_we) : cRD_n;
            assign WR_n   = own ? !(act &&  m_we) : cWR_n;
            assign RFSH_n = own ? 1'b1    : cRFSH_n;

            assign freeze   = stopped;
            assign dirset   = stopped && !busy && dbg_i.dirset;   // DIRSet jen při stojícím CE
            assign int_mask = stepping && dbg_i.step_noint;

            assign dbg_o.stopped   = stopped;
            assign dbg_o.reason    = reason;
            assign dbg_o.hit       = hit;
            assign dbg_o.hit_addr  = hit_addr;
            assign dbg_o.hit_data  = hit_data;
            assign dbg_o.hit_pc    = hit_pc;
            assign dbg_o.regs      = regs;
            assign dbg_o.mem_busy  = busy;
            assign dbg_o.mem_rdata = m_rdata;
        end else begin : g_nodbg
            assign A      = cA;
            assign DO     = cDO;
            assign M1_n   = cM1_n;
            assign MREQ_n = cMREQ_n;
            assign IORQ_n = cIORQ_n;
            assign RD_n   = cRD_n;
            assign WR_n   = cWR_n;
            assign RFSH_n = cRFSH_n;

            assign freeze   = 1'b0;
            assign dirset   = 1'b0;
            assign int_mask = 1'b0;
            assign dbg_o    = '0;
        end
    endgenerate

endmodule
