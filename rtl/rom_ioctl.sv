//============================================================================
//  Sord M5 — ROM plněná přes ioctl
//
//  Dvouportová bloková RAM:
//    port A  čtení pro CPU (address, q, cs, oe)
//    port B  zápis ze sběrnice ioctl — soubor z menu s indexem IOCTL_INDEX
//
//  Port B se povoluje sám: jen když probíhá nahrávání souboru s naším indexem
//  a adresa se vejde do paměti. Delší soubor se tedy utne, místo aby se
//  adresa zabalila a přepsala začátek.
//
//  Používá dpram, takže se stejný zdroják překládá pro FPGA (rtl/bram.sv)
//  i pro verilátor (verilator/rtl/dpram.sv).
//============================================================================

`default_nettype none

module rom_ioctl #(
   parameter addr_width    = 13,
   parameter mem_name      = "ROM",
   parameter mem_init_file = " ",
   parameter IOCTL_INDEX   = 0
)(
   input  wire                  clock,
   input  sordm5_pkg::ioctl_t   ioctl,

   input  wire [addr_width-1:0] address,
   output wire [7:0]            q,
   input  wire                  cs,
   input  wire                  oe
);

   // Adresa souboru nad rozsahem paměti se nezapisuje.
   wire in_range = (ioctl.addr >> addr_width) == 0;

   wire sel_b = ioctl.download && (ioctl.index == IOCTL_INDEX) && in_range;

   dpram #(
      .addr_width    (addr_width),
      .data_width    (8),
      .mem_init_file (mem_init_file),
      .mem_name      (mem_name)
   ) ram (
      .clock     (clock),

      .address_a (address),
      .data_a    (8'h00),
      .wren_a    (1'b0),
      .q_a       (q),
      .cs_a      (cs),
      .oe_a      (oe),

      .address_b (ioctl.addr[addr_width-1:0]),
      .data_b    (ioctl.data),
      .wren_b    (ioctl.wr),
      .q_b       (),
      .cs_b      (sel_b),
      .oe_b      (1'b0)
   );

endmodule

`default_nettype wire
