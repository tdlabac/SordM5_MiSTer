// Test časové značky: simulační náhrada tstamp (verilator/rtl/tstamp_dpi.sv)
// s C++ třídou TimeMark (tstamp_dpi.cpp). CE jako ce_3m58_p (1 z 6 taktů).
module tb_tstamp (
   input  logic        clk,
   input  logic        reset,
   input  logic        ce,
   output logic [47:0] count
);
   tstamp tstamp_i (.clk(clk), .reset(reset), .ce(ce), .count(count));
endmodule
