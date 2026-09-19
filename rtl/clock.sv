// Clock enables jádra Sord M5 z clk_sys (21,477 MHz).
//
// freeze = 1 zastaví celý počítač (debugger, doc/z80-debugger.md): děliče
// stojí a všechna ce_* jsou 0. Po uvolnění pokračují ze stejné fáze, takže
// běh se zastaveními je stejný jako bez nich.
module clock (
   input                     reset,
   input                     clk_sys,
   input                     freeze,
   output                    ce_3m58_p,
   output                    ce_3m58_n,
   output                    ce_10m7_p,
   output                    ce_10m7_n
);

   logic [1:0] div4;
   always_ff @(posedge clk_sys)
      if (reset)
         div4 <= 2'd0;
      else if (!freeze)
         div4 <= div4 + 2'd1;

   assign ce_10m7_p = !freeze &&  div4[0];
   assign ce_10m7_n = !freeze && !div4[0];


   logic [2:0] div6;
   always_ff @(posedge clk_sys)
   if (reset)
      div6 <= 3'd0;
   else if (!freeze)
      if (div6==5)
         div6 <= 3'd0;
      else
         div6 <= div6 + 3'd1;

   assign ce_3m58_p = !freeze && (div6 == 3'd0);
   assign ce_3m58_n = !freeze && (div6 == 3'd3);

endmodule
