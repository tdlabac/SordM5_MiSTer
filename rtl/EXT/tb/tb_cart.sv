// Test cartridge na rozšiřující sběrnici: ext_bus se sdílenou BRAM a moduly
// z rtl/EXT/carts. C++ (tb_cart.cpp) plní ROM přes ioctl a dělá cykly sběrnice.
//
// Výběry ROM1_n/ROM2_n/EXM_n a MRD_n/MWR_n se počítají stejně jako v GA015,
// aby test nepotřeboval celé jádro.

module tb_cart (
   input  logic        clk,
   input  logic        rst_n,

   // ioctl
   input  logic        io_download,
   input  logic [15:0] io_index,
   input  logic        io_wr,
   input  logic [26:0] io_addr,
   input  logic [7:0]  io_data,

   input  logic [1:0]  cart_sel,
   input  logic [15:0] cart_opt,

   // cyklus sběrnice
   input  logic [15:0] A,
   input  logic [7:0]  D_o,
   input  logic        mreq_n,
   input  logic        rd_n,
   input  logic        wr_n,
   input  logic        iowr_n,      // zápis na I/O port (A[7:0]), pro OUT (6Ch)

   output logic [7:0]  D_i,
   output logic        WAIT_n,
   output logic        ROMDS_n,
   output logic        ROM0_ovrd_n,
   output logic [16:0] rom_size
);
   sordm5_pkg::ioctl_t ioctl;
   assign ioctl = {io_download, io_index, io_wr, io_addr, io_data};

   // dekódování jako v rtl/GA015/ga015.sv
   wire ROM0_n  = !(A[15:13] == 3'b000);          // 0000-1FFF monitor
   wire ROM1_n  = !(A[15:13] == 3'b001);          // 2000-3FFF
   wire ROM2_n  = !(A[15:13] == 3'b010);          // 4000-5FFF
   wire EXM_n   = !(A[15:13] == 3'b011);          // 6000-7FFF
   wire EXIOA_n = !(A[7:4]   == 4'b0110);         // porty 60h-6Fh
   wire MRD_n   = mreq_n || rd_n;
   wire MWR_n   = mreq_n || wr_n;

   // Zpětná vazba jako v rtl/sordm5_core.sv: cartridge, která shodí monitor,
   // si tím sama odblokuje prostor 0000-1FFF.
   wire ROM0_gated = ROM0_n | ROM0_ovrd_n;

   assign rom_size = ext_i.rom_size;

   ext_bus ext_i (
      .clk_sys(clk),
      .ce_cpu_p(1'b1),
      .ce_cpu_n(1'b0),
      .ioctl(ioctl),
      .RST_n(rst_n),
      .A(A),
      .D_o(D_o),
      .MRQ_n(mreq_n),
      .RFSH_n(1'b1),
      .MRD_n(MRD_n),
      .MWR_n(MWR_n),
      .IORD_n(1'b1),
      .IOWR_n(iowr_n),
      .ROM0_n(ROM0_gated),
      .ROM1_n(ROM1_n),
      .ROM2_n(ROM2_n),
      .EXM_n(EXM_n),
      .EXIOA_n(EXIOA_n),
      .EXIOB_n(1'b1),
      .EXCLK(1'b0),
      .cart_sel(sordm5_pkg::cart_sel_t'(cart_sel)),
      .cart_opt(cart_opt),
      .D_i(D_i),
      .WAIT_n(WAIT_n),
      .ROMDS_n(ROMDS_n),
      .EXINT_n(),
      .ROM0_ovrd_n(ROM0_ovrd_n)
   );
endmodule
