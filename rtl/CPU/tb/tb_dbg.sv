// Test obálky tv80_dbg (breakpointy, krok, přístup do paměti).
// CPU s DEBUG = 1, skutečný clock.sv (freeze), paměť 64 kB se synchronním
// čtením jako bloková RAM (q registrované, 0xFF mimo čtení), I/O: čtení vrací
// io_val, zápisy se hlásí ven (io_wr, io_port, io_data).

module tb_dbg
   import tv80_dbg_pkg::*;
(
   input  logic         clk,
   input  logic         reset,

   input  logic         load_we,
   input  logic [15:0]  load_a,
   input  logic [7:0]   load_d,
   input  logic [15:0]  peek_a,
   output logic [7:0]   peek_q,

   input  logic         int_n,
   input  logic [7:0]   io_val,
   output logic         io_wr,         // 1 takt na konci zápisu I/O
   output logic [7:0]   io_port,
   output logic [7:0]   io_data,

   // příkazy
   input  logic         c_stop, c_run, c_step, c_step_noint,
   input  logic         c_mem_req, c_mem_we,
   input  logic [15:0]  c_mem_addr,
   input  logic [7:0]   c_mem_wdata,
   // nastavení breakpointu
   input  logic         bp_we,
   input  logic [3:0]   bp_sel,
   input  logic [4:0]   bp_kind,
   input  logic [15:0]  bp_addr, bp_amask,
   input  logic [7:0]   bp_data, bp_dmask,

   // stav
   output logic         stopped,
   output logic [2:0]   reason,
   output logic [8:0]   hit,
   output logic [15:0]  hit_addr, hit_pc,
   output logic [7:0]   hit_data,
   output logic [211:0] regs,
   output logic         busy,
   output logic [7:0]   rdata,
   output logic [15:0]  addr,
   output logic         m1_n, mreq_n, rd_n, wr_n
);
   logic ce_p, ce_n, freeze;
   clock clock_i (.reset(reset), .clk_sys(clk), .freeze(freeze),
                  .ce_3m58_p(ce_p), .ce_3m58_n(ce_n), .ce_10m7_p(), .ce_10m7_n());

   bp_t bps [NBP];
   always_ff @(posedge clk)
      if (bp_we) bps[bp_sel] <= '{kind: bp_kind, addr: bp_addr, amask: bp_amask, data: bp_data, dmask: bp_dmask};

   dbg_in_t  di;
   dbg_out_t dout;
   always_comb begin
      di = '0;
      di.stop = c_stop; di.run = c_run; di.step = c_step; di.step_noint = c_step_noint;
      di.mem_req = c_mem_req; di.mem_we = c_mem_we; di.mem_addr = c_mem_addr; di.mem_wdata = c_mem_wdata;
      for (int i = 0; i < NBP; i++) di.bp[i] = bps[i];
   end

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

   // paměť jako bloková RAM
   logic [7:0] mem [0:65535];
   logic [7:0] q;
   always_ff @(posedge clk) begin
      q <= (!MREQ_n && !RD_n) ? mem[A] : 8'hFF;
      if (load_we) mem[load_a] <= load_d;
      else if (!reset && !MREQ_n && !WR_n) mem[A] <= DO;
   end
   wire io_rd = !IORQ_n && !RD_n && M1_n;
   assign DI  = io_rd ? io_val : q;

   // hlášení zápisů I/O (na konci cyklu)
   logic iow_d;
   wire  iow = !IORQ_n && !WR_n && M1_n;
   always_ff @(posedge clk) begin
      iow_d <= iow;
      if (iow) begin io_port <= A[7:0]; io_data <= DO; end
   end
   assign io_wr = iow_d && !iow;

   assign peek_q   = mem[peek_a];
   assign stopped  = dout.stopped;  assign reason = dout.reason; assign hit = dout.hit;
   assign hit_addr = dout.hit_addr; assign hit_pc = dout.hit_pc; assign hit_data = dout.hit_data;
   assign regs     = dout.regs;     assign busy   = dout.mem_busy; assign rdata = dout.mem_rdata;
   assign addr     = A;  assign m1_n = M1_n; assign mreq_n = MREQ_n; assign rd_n = RD_n; assign wr_n = WR_n;
endmodule
