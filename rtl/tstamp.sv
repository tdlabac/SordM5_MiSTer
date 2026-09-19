//============================================================================
//  tstamp — čas počítače: počet taktů CPU (ce_3m58_p) od posledního resetu
//
//  Slouží jako „značka“ pro hledání chyb (doc/z80-debugger.md): na HW se
//  debuggerem přečte, kdy nastal problém, v simulaci se na stejné hodnotě
//  zastaví a zapne trace (verilator/rtl/tstamp_dpi.sv).
//
//  Počítá takty CPU, ne clk_sys: když debugger zmrazí počítač, stojí
//  i ce_3m58_p, takže čas zastavení se nezapočítá a stejný okamžik běhu má
//  na HW i v simulaci stejnou hodnotu. Reset jádra (i nahrání ROM přes
//  ioctl) čítač nuluje. Shoda platí, jen když jsou shodné i vstupy (klávesy).
//============================================================================

module tstamp (
   input  logic        clk,
   input  logic        reset,
   input  logic        ce,
   output logic [47:0] count
);
   always_ff @(posedge clk)
      if (reset)   count <= '0;
      else if (ce) count <= count + 48'd1;
endmodule
