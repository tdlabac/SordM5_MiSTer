// Obal klávesnice pro test (tb_keyboard.cpp). Modul má joy jako nezabalené
// pole, což se z C++ špatně budí, proto sem chodí dva samostatné vektory.

module tb_keyboard (
   input  logic        clk,
   input  logic [10:0] ps2,
   input  logic [5:0]  joy0,
   input  logic [5:0]  joy1,
   input  logic [2:0]  addr,
   input  logic        ce,

   output logic [7:0]  data,
   output logic        rst_key
);
   wire [5:0] joy [2];
   assign joy[0] = joy0;
   assign joy[1] = joy1;

   keyboard kb (
      .clk_i(clk),
      .ps2_code_i(ps2),
      .joy(joy),
      .addr_i(addr),
      .kb_ce_i(ce),
      .kb_data_o(data),
      .kb_rst_o(rst_key)
   );
endmodule
