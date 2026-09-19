// Test přehrávače kazety: cas_player + skutečný rtl/ddram.sv. DDR3 (DDRAM_*)
// modeluje tb_cas.cpp (latence čtení, náhodný DDRAM_BUSY). Soubor zapisuje
// C++ přímo do modelu DDR (jako MiSTer u "F...,adresa"), ioctl nese jen
// download/index/velikost. Zapojení ddram a cas_player jako v sordM5.sv.

module tb_cas #(
   parameter int TICK_CE = 874
)(
   input  logic        clk,
   input  logic        reset,
   input  logic        ce,

   // ioctl (rozložené; sestaví se do sordm5_pkg::ioctl_t)
   input  logic        io_download,
   input  logic [15:0] io_index,
   input  logic [26:0] io_addr,

   input  logic        cas_on,
   input  logic        cas_fast,
   output logic        cas_out,
   output logic [24:0] size,             // velikost souboru, jak ji převzal cas_player

   // DDR3 strana ddram.sv
   input  logic        DDRAM_BUSY,
   output logic [7:0]  DDRAM_BURSTCNT,
   output logic [28:0] DDRAM_ADDR,
   input  logic [63:0] DDRAM_DOUT,
   input  logic        DDRAM_DOUT_READY,
   output logic        DDRAM_RD,
   output logic [63:0] DDRAM_DIN,
   output logic [7:0]  DDRAM_BE,
   output logic        DDRAM_WE
);
   sordm5_pkg::ioctl_t ioctl;
   assign ioctl = {io_download, io_index, 1'b0, io_addr, 8'h00};
   assign size  = cas_i.size;

   logic [27:0] mem_addr;
   logic [7:0]  mem_dout;
   logic        mem_rd, mem_ready, loading;

   cas_player #(.IOCTL_INDEX(6'd2), .TICK_CE(TICK_CE)) cas_i (
      .clk(clk), .ce(ce), .ioctl(ioctl), .loading(loading),
      .cas_on(cas_on), .cas_fast(cas_fast), .cas_out(cas_out), .border(),
      .mem_addr(mem_addr), .mem_rd(mem_rd), .mem_dout(mem_dout), .mem_ready(mem_ready)
   );

   ddram ddram_i (
      .reset(reset || loading), .DDRAM_CLK(clk),
      .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
      .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
      .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
      .addr(mem_addr), .dout(mem_dout), .din(8'hFF), .we(1'b0), .rd(mem_rd), .ready(mem_ready)
   );
endmodule
