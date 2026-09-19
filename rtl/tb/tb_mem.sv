// Behaviorální spram/dpram pro testy celého jádra (bez DPI a bez altsyncram).
// Chování jako verilator/rtl/spram.sv a dpram.sv: q registrované, cs && oe
// jinak 0xFF, zápis při wren && cs. Obsah podle mem_name z hex souborů
// (jeden bajt na řádek), které připraví run skript: ROM -> rom.hex,
// ROM_CART -> cart.hex. Ostatní paměti začínají nulou.

module spram #(
   parameter addr_width    = 8,
   parameter data_width    = 8,
   parameter mem_init_file = " ",
   parameter mem_name      = "MEM"
)(
   input  wire                  clock,
   input  wire [addr_width-1:0] address,
   input  wire [data_width-1:0] data,
   input  wire                  wren,
   output logic [data_width-1:0] q,
   input  wire                  cs,
   input  wire                  oe
);
   logic [data_width-1:0] mem [0:(1<<addr_width)-1];
   initial for (int i = 0; i < (1<<addr_width); i++) mem[i] = '0;

   always_ff @(posedge clock) begin
      q <= (cs && oe) ? mem[address] : '1;
      if (wren && cs) mem[address] <= data;
   end
endmodule

module dpram #(
   parameter addr_width    = 8,
   parameter data_width    = 8,
   parameter mem_init_file = " ",
   parameter mem_name      = "MEM"
)(
   input  wire                  clock,
   input  wire [addr_width-1:0] address_a,
   input  wire [data_width-1:0] data_a,
   input  wire                  wren_a,
   output logic [data_width-1:0] q_a,
   input  wire                  cs_a,
   input  wire                  oe_a,
   input  wire [addr_width-1:0] address_b,
   input  wire [data_width-1:0] data_b,
   input  wire                  wren_b,
   output logic [data_width-1:0] q_b,
   input  wire                  cs_b,
   input  wire                  oe_b
);
   logic [data_width-1:0] mem [0:(1<<addr_width)-1];
   initial begin
      for (int i = 0; i < (1<<addr_width); i++) mem[i] = '0;
      if (mem_name == "ROM")      $readmemh("rom.hex", mem);
      if (mem_name == "ROM_CART") $readmemh("cart.hex", mem);
   end

   always_ff @(posedge clock) begin
      q_a <= (cs_a && oe_a) ? mem[address_a] : '1;
      q_b <= (cs_b && oe_b) ? mem[address_b] : '1;
      if (wren_a && cs_a) mem[address_a] <= data_a;
      if (wren_b && cs_b) mem[address_b] <= data_b;
   end
endmodule
