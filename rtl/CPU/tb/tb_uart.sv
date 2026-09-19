// Model pro test přenosu debuggeru přes UART: skutečný rtl/dbg_link.sv
// (UART + protokol), tv80_dbg_regs, tv80_dbg (DEBUG = 1), paměť a I/O
// jako tb_dbg.sv. UART řídí tb_uart.cpp po bitech a vystavuje ho na TCP,
// takže se proti modelu dají pustit nástroje z tools/z80dbg.
//
// Rychlost UART je v testu zkrácená (DIV = 32 taktů na bit), aby test
// netrval dlouho; logika je stejná jako ve FPGA.

module tb_uart
   import tv80_dbg_pkg::*;
#(
   parameter int CLK_HZ = 7_372_800,
   parameter int BAUD   = 230_400            // DIV = 32
)(
   input  logic         clk,
   input  logic         reset,

   input  logic         load_we,
   input  logic [15:0]  load_a,
   input  logic [7:0]   load_d,

   input  logic         uart_rxd,          // host -> jádro
   output logic         uart_txd,          // jádro -> host
   input  logic         int_n,
   input  logic [7:0]   io_val
);
   logic ce_p, ce_n, freeze;
   clock clock_i (.reset(reset), .clk_sys(clk), .freeze(freeze),
                  .ce_3m58_p(ce_p), .ce_3m58_n(ce_n), .ce_10m7_p());

   dbg_in_t  di;
   dbg_out_t dout;
   logic       l_wr;
   logic [7:0] l_addr, l_wdata, l_rdata;

   dbg_link #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .TIMEOUT_MS(20)) dbg_link_i (
      .clk(clk), .reset(reset), .uart_rxd(uart_rxd), .uart_txd(uart_txd),
      .wr(l_wr), .addr(l_addr), .wdata(l_wdata), .rdata(l_rdata));
   logic [47:0] ts;
   tstamp tstamp_i (.clk(clk), .reset(reset), .ce(ce_p), .count(ts));
   tv80_dbg_regs regs_i (.clk(clk), .reset(reset), .wr(l_wr), .addr(l_addr), .wdata(l_wdata),
                         .rdata(l_rdata), .dbg_i(di), .dbg_o(dout), .tstamp(ts));

   logic [15:0] A;
   logic [7:0]  DO, DI;
   logic        M1_n, MREQ_n, IORQ_n, RD_n, WR_n;

   tv80_dbg #(.Mode(0), .R800_MULU(0), .IOWait(1), .DEBUG(1)) cpu (
      .RESET_n(!reset), .R800_mode(1'b0), .CLK_n(clk), .CE_n(ce_n), .CE_p(ce_p),
      .WAIT_n(1'b1), .INT_n(int_n), .NMI_n(1'b1), .BUSRQ_n(1'b1),
      .M1_n(M1_n), .MREQ_n(MREQ_n), .IORQ_n(IORQ_n), .RD_n(RD_n), .WR_n(WR_n),
      .RFSH_n(), .HALT_n(), .BUSAK_n(), .A(A), .DI(DI), .DO(DO),
      .freeze(freeze), .dbg_i(di), .dbg_o(dout)
   );

   logic [7:0] mem [0:65535];
   logic [7:0] q;
   always_ff @(posedge clk) begin
      q <= (!MREQ_n && !RD_n) ? mem[A] : 8'hFF;
      if (load_we) mem[load_a] <= load_d;
      else if (!reset && !MREQ_n && !WR_n) mem[A] <= DO;
   end
   assign DI = (!IORQ_n && !RD_n && M1_n) ? io_val : q;
endmodule
