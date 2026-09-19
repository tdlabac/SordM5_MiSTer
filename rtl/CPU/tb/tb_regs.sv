// Test REG/DIRSet TV80a: CPU + 64 kB paměti + I/O, CE lze zastavit (run).
// Řídí tb_regs.cpp: na každé hranici instrukce zastaví CE, porovná REG
// s očekávaným stavem, případně nahraje registry přes DIRSet.

module tb_regs (
   input  logic         clk,
   input  logic         rst_n,
   input  logic         run,

   input  logic         mem_we,
   input  logic [15:0]  mem_a,
   input  logic [7:0]   mem_d,
   output logic [7:0]   mem_q,

   input  logic         int_n,
   input  logic [7:0]   io_val,     // co vrací každé čtení I/O

   input  logic         dirset,
   input  logic [211:0] dir,
   output logic [211:0] reg_o,
   output logic [2:0]   mc,
   output logic [2:0]   ts,
   output logic [1:0]   prefix,
   output logic         intcycle,

   output logic         m1_n,
   output logic         mreq_n,
   output logic         iorq_n,
   output logic         rd_n,
   output logic         wr_n,
   output logic         halt_n,
   output logic [15:0]  addr,
   output logic [7:0]   dout
);
   logic [2:0] div6 = '0;
   always_ff @(posedge clk) div6 <= (div6 == 3'd5) ? 3'd0 : div6 + 3'd1;
   wire ce_p = run && (div6 == 3'd0);
   wire ce_n = run && (div6 == 3'd3);

   logic [15:0] A;
   logic [7:0]  DO, DI;
   logic        M1_n, MREQ_n, IORQ_n, RD_n, WR_n, HALT_n;

   TV80a #(.Mode(0), .R800_MULU(0), .IOWait(1)) cpu (
      .RESET_n(rst_n), .R800_mode(1'b0), .CLK_n(clk), .CE_n(ce_n), .CE_p(ce_p),
      .WAIT_n(1'b1), .INT_n(int_n), .NMI_n(1'b1), .BUSRQ_n(1'b1),
      .M1_n(M1_n), .MREQ_n(MREQ_n), .IORQ_n(IORQ_n), .RD_n(RD_n), .WR_n(WR_n),
      .RFSH_n(), .HALT_n(HALT_n), .BUSAK_n(), .A(A), .DI(DI), .DO(DO),
      .REG(reg_o), .DIRSet(dirset), .DIR(dir), .DbgMCycle(mc), .DbgTState(ts),
      .DbgPrefix(prefix), .DbgIntCycle(intcycle), .DbgNMICycle()
   );

   logic [7:0] mem [0:65535];
   always_ff @(posedge clk) begin
      if (mem_we) mem[mem_a] <= mem_d;
      else if (rst_n && !MREQ_n && !WR_n) mem[A] <= DO;   // v resetu drží TV80 MREQ/WR dole
   end

   wire inta = !M1_n && !IORQ_n;
   assign DI = inta                      ? 8'hFF :        // IM1: vektor se nečte
               (!IORQ_n && !RD_n)        ? io_val :
               (!MREQ_n && !RD_n)        ? mem[A] :
                                           8'hFF;

   assign mem_q  = mem[mem_a];
   assign m1_n   = M1_n;   assign mreq_n = MREQ_n; assign iorq_n = IORQ_n;
   assign rd_n   = RD_n;   assign wr_n   = WR_n;   assign halt_n = HALT_n;
   assign addr   = A;      assign dout   = DO;
endmodule
