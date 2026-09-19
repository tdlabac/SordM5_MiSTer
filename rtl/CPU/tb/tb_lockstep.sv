// Lockstep test TV80: testovaný procesor (DUT) proti zmrazené referenční kopii
// (REF_TV80a z ref/). Oba dostávají v každém taktu stejné vstupy a C++
// porovnává všechny jejich výstupy. Jakýkoli rozdíl = změna chování.
//
// DUT: TV80a, nebo s +define+DUT_DBG obálka tv80_dbg (debugger v klidu musí
// být průhledný).
//
// Paměť 64 kB plní C++ před resetem (mem_we/mem_a/mem_d), za běhu do ní
// zapisuje DUT. Při čtení I/O vrací sběrnice A ^ lfsr, při potvrzení
// přerušení vec. Hodiny CPU jsou clk/6 jako v rtl/clock.sv.

module tb_lockstep (
   input  logic        clk,
   input  logic        rst_n,

   input  logic        mem_we,
   input  logic [15:0] mem_a,
   input  logic [7:0]  mem_d,

   input  logic        int_n,
   input  logic        nmi_n,
   input  logic        wait_n,
   input  logic        busrq_n,
   input  logic [7:0]  vec,

   // DUT
   output logic [15:0] d_a,
   output logic [7:0]  d_do,
   output logic [7:0]  d_ctl,   // {M1,MREQ,IORQ,RD,WR,RFSH,HALT,BUSAK}_n
   // REF
   output logic [15:0] r_a,
   output logic [7:0]  r_do,
   output logic [7:0]  r_ctl,

   output logic [7:0]  di       // co je na datové sběrnici (pro statistiku opkódů)
);
   logic [2:0] div6 = '0;
   always_ff @(posedge clk) div6 <= (div6 == 3'd5) ? 3'd0 : div6 + 3'd1;
   wire ce_p = (div6 == 3'd0);
   wire ce_n = (div6 == 3'd3);

   logic [15:0] dA, rA;
   logic [7:0]  dDO, rDO, DI;
   logic dM1, dMREQ, dIORQ, dRD, dWR, dRFSH, dHALT, dBUSAK;
   logic rM1, rMREQ, rIORQ, rRD, rWR, rRFSH, rHALT, rBUSAK;

`ifdef DUT_DBG
   tv80_dbg #(.Mode(0), .R800_MULU(0), .IOWait(1)) dut (
`else
   TV80a #(.Mode(0), .R800_MULU(0), .IOWait(1)) dut (
`endif
      .RESET_n(rst_n), .R800_mode(1'b0), .CLK_n(clk), .CE_n(ce_n), .CE_p(ce_p),
      .WAIT_n(wait_n), .INT_n(int_n), .NMI_n(nmi_n), .BUSRQ_n(busrq_n),
      .M1_n(dM1), .MREQ_n(dMREQ), .IORQ_n(dIORQ), .RD_n(dRD), .WR_n(dWR),
      .RFSH_n(dRFSH), .HALT_n(dHALT), .BUSAK_n(dBUSAK), .A(dA), .DI(DI), .DO(dDO)
   );

   REF_TV80a #(.Mode(0), .R800_MULU(0), .IOWait(1)) ref_cpu (
      .RESET_n(rst_n), .R800_mode(1'b0), .CLK_n(clk), .CE_n(ce_n), .CE_p(ce_p),
      .WAIT_n(wait_n), .INT_n(int_n), .NMI_n(nmi_n), .BUSRQ_n(busrq_n),
      .M1_n(rM1), .MREQ_n(rMREQ), .IORQ_n(rIORQ), .RD_n(rRD), .WR_n(rWR),
      .RFSH_n(rRFSH), .HALT_n(rHALT), .BUSAK_n(rBUSAK), .A(rA), .DI(DI), .DO(rDO)
   );

   logic [7:0] mem [0:65535];
   logic [15:0] lfsr = 16'hACE1;

   always_ff @(posedge clk) begin
      if (mem_we) mem[mem_a] <= mem_d;
      else if (!dMREQ && !dWR && dBUSAK) mem[dA] <= dDO;
      lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
   end

   wire inta   = !dM1 && !dIORQ;
   wire io_rd  =  dM1 && !dIORQ && !dRD;
   wire mem_rd = !dMREQ && !dRD;

   assign DI = inta   ? vec :
               io_rd  ? (dA[7:0] ^ dA[15:8] ^ lfsr[7:0]) :
               mem_rd ? mem[dA] :
                        8'hFF;

   assign d_a   = dA;   assign d_do = dDO;
   assign r_a   = rA;   assign r_do = rDO;
   assign d_ctl = {dM1, dMREQ, dIORQ, dRD, dWR, dRFSH, dHALT, dBUSAK};
   assign r_ctl = {rM1, rMREQ, rIORQ, rRD, rWR, rRFSH, rHALT, rBUSAK};
   assign di    = DI;
endmodule
