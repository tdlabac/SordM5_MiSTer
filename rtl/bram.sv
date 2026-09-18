//------------------------------------------------------------
// Blokové RAM nad altsyncram — převod z bram.vhd.
//
// Rozhraní odpovídá VHDL 1:1. Rozdíl je jen jeden: VHDL má u vstupů výchozí
// hodnoty (data = 0, enable = 1, wren = 0, cs = 1). Verilog v Quartusu 17
// výchozí hodnoty vstupů nezná, takže nezapojený vstup skončí na 0.
// U `cs` to znamená, že paměť nic nezapíše a čte samé 1 — nepoužitý `cs`
// proto zapojit na 1'b1.
//
// `cs` hradluje zápis i výstup: bez něj vrací q samé jedničky, aby se
// výstupy periferií daly slučovat přes AND.
//------------------------------------------------------------

`default_nettype none

//------------------------------------------------------------
// Single port Block RAM
//------------------------------------------------------------
module spram #(
   parameter addr_width    = 8,
   parameter data_width    = 8,
   parameter mem_init_file = " ",
   parameter mem_name      = "MEM"      // pro In-System Memory Content Editor
)(
   input  wire                  clock,
   input  wire [addr_width-1:0] address,
   input  wire [data_width-1:0] data,
   input  wire                  enable,   // ve VHDL taky nezapojený (BYPASS)
   input  wire                  wren,
   output wire [data_width-1:0] q,
   input  wire                  cs,
   input  wire                  oe
);

   wire [data_width-1:0] q0;

   assign q = cs && oe ? q0 : {data_width{1'b1}};

   altsyncram #(
      .clock_enable_input_a          ("BYPASS"),
      .clock_enable_output_a         ("BYPASS"),
      .intended_device_family        ("Cyclone V"),
      .lpm_hint                      ({"ENABLE_RUNTIME_MOD=YES,INSTANCE_NAME=", mem_name}),
      .lpm_type                      ("altsyncram"),
      .numwords_a                    (1 << addr_width),
      .operation_mode                ("SINGLE_PORT"),
      .outdata_aclr_a                ("NONE"),
      .outdata_reg_a                 ("UNREGISTERED"),
      .power_up_uninitialized        ("FALSE"),
      .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
      .init_file                     (mem_init_file),
      .widthad_a                     (addr_width),
      .width_a                       (data_width),
      .width_byteena_a               (1)
   ) altsyncram_component (
      .address_a (address),
      .clock0    (clock),
      .data_a    (data),
      .wren_a    (wren & cs),
      .q_a       (q0)
   );

endmodule

//------------------------------------------------------------
// Dual port Block RAM same parameters on both ports
//------------------------------------------------------------
module dpram #(
   parameter addr_width    = 8,
   parameter data_width    = 8,
   parameter mem_init_file = " ",
   parameter mem_name      = "MEM"      // ve VHDL se dál nepředává, tady taky ne
)(
   input  wire                  clock,

   input  wire [addr_width-1:0] address_a,
   input  wire [data_width-1:0] data_a,
   input  wire                  enable_a,
   input  wire                  wren_a,
   output wire [data_width-1:0] q_a,
   input  wire                  cs_a,

   input  wire [addr_width-1:0] address_b,
   input  wire [data_width-1:0] data_b,
   input  wire                  enable_b,
   input  wire                  wren_b,
   output wire [data_width-1:0] q_b,
   input  wire                  cs_b
);

   dpram_dif #(
      .addr_width_a  (addr_width),
      .data_width_a  (data_width),
      .addr_width_b  (addr_width),
      .data_width_b  (data_width),
      .mem_init_file (mem_init_file)
   ) ram (
      .clock     (clock),
      .address_a (address_a),
      .data_a    (data_a),
      .enable_a  (enable_a),
      .wren_a    (wren_a),
      .q_a       (q_a),
      .cs_a      (cs_a),
      .address_b (address_b),
      .data_b    (data_b),
      .enable_b  (enable_b),
      .wren_b    (wren_b),
      .q_b       (q_b),
      .cs_b      (cs_b)
   );

endmodule

//------------------------------------------------------------
// Dual port Block RAM different parameters on ports
//------------------------------------------------------------
module dpram_dif #(
   parameter addr_width_a  = 8,
   parameter data_width_a  = 8,
   parameter addr_width_b  = 8,
   parameter data_width_b  = 8,
   parameter mem_init_file = " "
)(
   input  wire                    clock,

   input  wire [addr_width_a-1:0] address_a,
   input  wire [data_width_a-1:0] data_a,
   input  wire                    enable_a,
   input  wire                    wren_a,
   output wire [data_width_a-1:0] q_a,
   input  wire                    cs_a,

   input  wire [addr_width_b-1:0] address_b,
   input  wire [data_width_b-1:0] data_b,
   input  wire                    enable_b,
   input  wire                    wren_b,
   output wire [data_width_b-1:0] q_b,
   input  wire                    cs_b
);

   wire [data_width_a-1:0] q0;
   wire [data_width_b-1:0] q1;

   assign q_a = cs_a ? q0 : {data_width_a{1'b1}};
   assign q_b = cs_b ? q1 : {data_width_b{1'b1}};

   altsyncram #(
      .address_reg_b                 ("CLOCK1"),
      .clock_enable_input_a          ("NORMAL"),
      .clock_enable_input_b          ("NORMAL"),
      .clock_enable_output_a         ("BYPASS"),
      .clock_enable_output_b         ("BYPASS"),
      .indata_reg_b                  ("CLOCK1"),
      .intended_device_family        ("Cyclone V"),
      .lpm_type                      ("altsyncram"),
      .numwords_a                    (1 << addr_width_a),
      .numwords_b                    (1 << addr_width_b),
      .operation_mode                ("BIDIR_DUAL_PORT"),
      .outdata_aclr_a                ("NONE"),
      .outdata_aclr_b                ("NONE"),
      .outdata_reg_a                 ("UNREGISTERED"),
      .outdata_reg_b                 ("UNREGISTERED"),
      .power_up_uninitialized        ("FALSE"),
      .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
      .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ"),
      .init_file                     (mem_init_file),
      .widthad_a                     (addr_width_a),
      .widthad_b                     (addr_width_b),
      .width_a                       (data_width_a),
      .width_b                       (data_width_b),
      .width_byteena_a               (1),
      .width_byteena_b               (1),
      .wrcontrol_wraddress_reg_b     ("CLOCK1")
   ) altsyncram_component (
      .address_a (address_a),
      .address_b (address_b),
      .clock0    (clock),
      .clock1    (clock),
      .clocken0  (enable_a),
      .clocken1  (enable_b),
      .data_a    (data_a),
      .data_b    (data_b),
      .wren_a    (wren_a & cs_a),
      .wren_b    (wren_b & cs_b),
      .q_a       (q0),
      .q_b       (q1)
   );

endmodule

`default_nettype wire
