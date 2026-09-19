// Testbench TV80a: CPU + model sběrnice (ROM, RAM, I/O port, řadič přerušení).
//
// ROM se plní z C++ před resetem (rom_we/rom_a/rom_d), RAM se z C++ čte
// (ram_a/ram_q). Hodiny CPU jsou clk/6 stejně jako v rtl/clock.sv.
// Při potvrzení přerušení (M1 && IORQ) je na datové sběrnici vec, při IN
// io_rd_val — obojí nastavuje C++.

module tb_tv80 (
   input  logic        clk,
   input  logic        rst_n,

   input  logic        rom_we,
   input  logic [7:0]  rom_a,
   input  logic [7:0]  rom_d,

   input  logic        int_n,
   input  logic [7:0]  vec,
   input  logic [7:0]  io_rd_val,

   input  logic [7:0]  ram_a,
   output logic [7:0]  ram_q,

   output logic        m1_n,
   output logic        mreq_n,
   output logic        iorq_n,
   output logic        rd_n,
   output logic        wr_n,
   output logic [15:0] addr,
   output logic [7:0]  dout,

   // ladění: vnitřní stav TV80
   output logic [2:0]  dbg_tstate,
   output logic [2:0]  dbg_mcycle,
   output logic [7:0]  dbg_di_reg,
   output logic        dbg_intcycle,
   output logic        dbg_ce_p,
   output logic        dbg_ce_n
);
   logic [2:0] div6 = '0;
   always_ff @(posedge clk) div6 <= (div6 == 3'd5) ? 3'd0 : div6 + 3'd1;
   wire ce_p = (div6 == 3'd0);
   wire ce_n = (div6 == 3'd3);

   logic [15:0] A;
   logic [7:0]  DO, DI;
   logic        M1_n, MREQ_n, IORQ_n, RD_n, WR_n;

   TV80a #(.Mode(0), .R800_MULU(0), .IOWait(1)) cpu (
      .RESET_n(rst_n), .R800_mode(1'b0), .CLK_n(clk), .CE_n(ce_n), .CE_p(ce_p),
      .WAIT_n(1'b1), .INT_n(int_n), .NMI_n(1'b1), .BUSRQ_n(1'b1),
      .M1_n(M1_n), .MREQ_n(MREQ_n), .IORQ_n(IORQ_n), .RD_n(RD_n), .WR_n(WR_n),
      .RFSH_n(), .HALT_n(), .BUSAK_n(), .A(A), .DI(DI), .DO(DO)
   );

   // ROM 0x0000-0x00FF (zrcadlí se do 0x7FFF), RAM 0x8000-0x80FF (zrcadlí se do 0xFFFF)
   logic [7:0] rom [0:255];
   logic [7:0] ram [0:255];

   always_ff @(posedge clk) begin
      if (rom_we) rom[rom_a] <= rom_d;
      if (!MREQ_n && !WR_n && A[15]) ram[A[7:0]] <= DO;
   end

   wire inta   = !M1_n && !IORQ_n;
   wire io_rd  =  M1_n && !IORQ_n && !RD_n;
   wire mem_rd = !MREQ_n && !RD_n;

   assign DI = inta   ? vec :
               io_rd  ? io_rd_val :
               mem_rd ? (A[15] ? ram[A[7:0]] : rom[A[7:0]]) :
                        8'hFF;

   assign ram_q  = ram[ram_a];
   assign m1_n   = M1_n;
   assign mreq_n = MREQ_n;
   assign iorq_n = IORQ_n;
   assign rd_n   = RD_n;
   assign wr_n   = WR_n;
   assign addr   = A;
   assign dout   = DO;

   assign dbg_tstate   = cpu.TState;
   assign dbg_mcycle   = cpu.MCycle;
   assign dbg_di_reg   = cpu.DI_Reg;
   assign dbg_intcycle = !cpu.IntCycle_n;
   assign dbg_ce_p     = ce_p;
   assign dbg_ce_n     = ce_n;
endmodule
