// Clock enables jádra Sord M5 z clk_sys (21,477272 MHz).
//
// Jeden čítač modulo 6:
//   ce_3m58_p / ce_3m58_n  clk_sys / 6 = 3,579545 MHz (CPU, CTC, SGC),
//                          dvě fáze posunuté o půl periody (div6 = 0 a 3)
//   ce_10m7_p              clk_sys / 2 = 10,738635 MHz (VDP) = div6[0]:
//                          perioda 6 je sudá, takže nejnižší bit se střídá
//                          0,1,0,1… a ve fázi s CPU zůstává z principu.
//
// freeze = 1 zastaví celý počítač (debugger, doc/z80-debugger.md): čítač
// stojí a všechna ce_* jsou 0. Po uvolnění pokračuje ze stejné fáze, takže
// běh se zastaveními je stejný jako bez nich.
`default_nettype none

module clock (
   input  wire               reset,
   input  wire               clk_sys,
   input  wire               freeze,
   output logic              ce_3m58_p,
   output logic              ce_3m58_n,
   output logic              ce_10m7_p
);

   logic [2:0] div6;
   always_ff @(posedge clk_sys)
      if (reset)
         div6 <= 3'd0;
      else if (!freeze)
         div6 <= (div6 == 3'd5) ? 3'd0 : div6 + 3'd1;

   assign ce_3m58_p = !freeze && (div6 == 3'd0);
   assign ce_3m58_n = !freeze && (div6 == 3'd3);
   assign ce_10m7_p = !freeze &&  div6[0];     // 3 pulzy ze 6 taktů = clk_sys / 2

endmodule

`default_nettype wire
