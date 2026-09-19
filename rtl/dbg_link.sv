//============================================================================
//  dbg_link — přenos registrového prostoru debuggeru ven (doc/z80-debugger.md)
//
//  Obsluhuje sběrnici tv80_dbg_regs: jeden přístup za takt, wr/addr/wdata
//  jsou registrované, rdata je kombinační odpověď na addr.
//
//  Ve FPGA zatím pahýl (žádný přenos, debugger vypnutý). Až bude UART nebo
//  DDR, nahradí ho tady. V simulaci ho nahrazuje verilator/rtl/dbg_link.sv
//  (DPI do sim appky).
//============================================================================

module dbg_link (
   input  logic       clk,
   output logic       wr,
   output logic [7:0] addr,
   output logic [7:0] wdata,
   input  logic [7:0] rdata
);
   assign wr    = 1'b0;
   assign addr  = 8'h00;
   assign wdata = 8'h00;

   wire unused = &{1'b0, clk, rdata};
endmodule
