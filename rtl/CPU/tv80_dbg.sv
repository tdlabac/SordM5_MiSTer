//============================================================================
//  tv80_dbg — obálka TV80a s debuggerem (návrh: doc/z80-debugger.md)
//
//  Porty sběrnice jsou stejné jako u TV80a, v SordM5.sv ji nahradí 1:1.
//  DEBUG = 0: jen holé TV80a, debugger se vůbec nepřeloží.
//
//  Zatím průchozí kostra. Průhlednost hlídá lockstep test:
//    DUT_DBG=1 bash rtl/CPU/tb/run_lockstep.sh
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
    output    [7:0] DO
);

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
        .REG(),
        .DIRSet(1'b0),
        .DIR('0),
        .DbgMCycle(),
        .DbgTState(),
        .DbgPrefix(),
        .DbgIntCycle(),
        .DbgNMICycle()
    );

endmodule
