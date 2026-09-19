//============================================================================
//  tv80_dbg_regs — registrový prostor debuggeru Z80 (doc/z80-debugger.md)
//
//  Převádí jednoduchou 8bitovou sběrnici (addr, wdata, wr -> rdata) na
//  tv80_dbg_pkg::dbg_in_t / dbg_out_t. Přenos ven (UART, DDR, v simulaci DPI)
//  jen tuhle sběrnici obsluhuje. rdata je kombinační podle addr, zápis platí
//  na hraně clk při wr = 1.
//
//  Mapa (R = čtení, W = zápis):
//    00h  W  příkaz, bity se provedou naráz (pulzy):
//              0 stop   1 run   2 step   3 commit (DIRSet ze staging)
//              4 snap (staging <- aktuální registry)
//         R  stav: 0 stopped, 1 mem_busy, [4:2] důvod (tv80_dbg_pkg::reason_t)
//    01h  RW volby: 0 step_noint (při kroku maskovat INT)
//    02h  R  identifikace 5Ah
//    03h  R  počet breakpointů (NBP)
//    04h  R  hit_addr[7:0]    05h hit_addr[15:8]   06h hit_data
//    08h  R  hit_pc[7:0]      09h hit_pc[15:8]
//    0Ah  R  hit[7:0]         0Bh hit[15:8]
//    10h  RW mem_addr[7:0]    11h mem_addr[15:8]   12h mem_wdata
//    13h  W  1 = čtení, 2 = zápis (jen při zastavení); R: mem_rdata
//    18h-1Dh  R  čas počítače (rtl/tstamp.sv, takty CPU od resetu), 48 bitů
//             little-endian. Hodnota se zachytí, když adresa vstoupí do
//             rozsahu, a drží se, dokud v něm zůstává (blokové čtení je
//             konzistentní i za běhu). Při zastavení čas stojí.
//    20h-3Ah  R: aktuální registry (REG, bajt 0 = REG[7:0]), W: staging
//    40h + 8*i, i = 0..NBP-1: breakpoint i (RW)
//             +0 kind  +1 addr lo  +2 addr hi  +3 amask lo  +4 amask hi
//             +5 data  +6 dmask
//============================================================================

module tv80_dbg_regs
   import tv80_dbg_pkg::*;
(
   input  logic        clk,
   input  logic        reset,

   input  logic        wr,
   input  logic [7:0]  addr,
   input  logic [7:0]  wdata,
   output logic [7:0]  rdata,

   output dbg_in_t     dbg_i,
   input  dbg_out_t    dbg_o,
   input  logic [47:0] tstamp          // čas počítače (rtl/tstamp.sv)
);
   localparam int         REGB   = 27;       // bajtů REG (212 bitů)
   localparam logic [7:0] REG_LO = 8'h20;    // REG na 20h..3Ah
   localparam logic [7:0] REG_HI = 8'h3B;

   logic         step_noint;
   logic [15:0]  mem_addr;
   logic [7:0]   mem_wdata;
   logic [215:0] stage;                     // staging registrů (27 B)
   bp_t          bps [NBP];

   // pulzy z příkazů
   logic c_stop, c_run, c_step, c_commit, c_mreq, c_mwe;

   wire [215:0] regs_b = {4'b0, dbg_o.regs};
   wire [4:0]   ri     = 5'(addr - REG_LO);    // index bajtu REG (platí pro 20h-3Ah)

   always_ff @(posedge clk) begin
      c_stop <= 1'b0; c_run <= 1'b0; c_step <= 1'b0; c_commit <= 1'b0; c_mreq <= 1'b0;
      if (reset) begin
         step_noint <= 1'b0;
         for (int i = 0; i < NBP; i++) bps[i] <= '0;
      end else if (wr) begin
         if (addr == 8'h00) begin
            c_stop   <= wdata[0];
            c_run    <= wdata[1];
            c_step   <= wdata[2];
            c_commit <= wdata[3];
            if (wdata[4]) stage <= regs_b;
         end
         if (addr == 8'h01) step_noint     <= wdata[0];
         if (addr == 8'h10) mem_addr[7:0]  <= wdata;
         if (addr == 8'h11) mem_addr[15:8] <= wdata;
         if (addr == 8'h12) mem_wdata      <= wdata;
         if (addr == 8'h13) begin
            c_mreq <= wdata[0] | wdata[1];
            c_mwe  <= wdata[1];
         end
         if (addr >= REG_LO && addr < REG_HI)
            stage[8*ri +: 8] <= wdata;
         for (int i = 0; i < NBP; i++)
            if (addr[7:3] == 5'(8 + i))
               case (addr[2:0])
                  3'd0: bps[i].kind        <= wdata[4:0];
                  3'd1: bps[i].addr[7:0]   <= wdata;
                  3'd2: bps[i].addr[15:8]  <= wdata;
                  3'd3: bps[i].amask[7:0]  <= wdata;
                  3'd4: bps[i].amask[15:8] <= wdata;
                  3'd5: bps[i].data        <= wdata;
                  3'd6: bps[i].dmask       <= wdata;
                  default: ;
               endcase
      end
   end

   always_comb begin
      dbg_i            = '0;
      dbg_i.stop       = c_stop;
      dbg_i.run        = c_run;
      dbg_i.step       = c_step;
      dbg_i.step_noint = step_noint;
      dbg_i.dirset     = c_commit;
      dbg_i.dir        = stage[211:0];
      dbg_i.mem_req    = c_mreq;
      dbg_i.mem_we     = c_mwe;
      dbg_i.mem_addr   = mem_addr;
      dbg_i.mem_wdata  = mem_wdata;
      for (int i = 0; i < NBP; i++) dbg_i.bp[i] = bps[i];
   end

   // čas: snímek se drží, dokud se čte rozsah 18h-1Dh
   logic [47:0] ts_snap;
   wire         ts_rd = addr >= 8'h18 && addr <= 8'h1D;
   always_ff @(posedge clk)
      if (!ts_rd) ts_snap <= tstamp;

   // čtení
   wire [15:0] hit16 = 16'(dbg_o.hit);
   always_comb begin
      rdata = 8'h00;
      case (addr)
         8'h00: rdata = {3'b0, dbg_o.reason, dbg_o.mem_busy, dbg_o.stopped};
         8'h01: rdata = {7'b0, step_noint};
         8'h02: rdata = 8'h5A;
         8'h03: rdata = 8'(NBP);
         8'h04: rdata = dbg_o.hit_addr[7:0];
         8'h05: rdata = dbg_o.hit_addr[15:8];
         8'h06: rdata = dbg_o.hit_data;
         8'h08: rdata = dbg_o.hit_pc[7:0];
         8'h09: rdata = dbg_o.hit_pc[15:8];
         8'h0A: rdata = hit16[7:0];
         8'h0B: rdata = hit16[15:8];
         8'h10: rdata = mem_addr[7:0];
         8'h11: rdata = mem_addr[15:8];
         8'h12: rdata = mem_wdata;
         8'h13: rdata = dbg_o.mem_rdata;
         8'h18: rdata = ts_snap[7:0];
         8'h19: rdata = ts_snap[15:8];
         8'h1A: rdata = ts_snap[23:16];
         8'h1B: rdata = ts_snap[31:24];
         8'h1C: rdata = ts_snap[39:32];
         8'h1D: rdata = ts_snap[47:40];
         default: ;
      endcase
      if (addr >= REG_LO && addr < REG_HI)
         rdata = regs_b[8*ri +: 8];
      for (int i = 0; i < NBP; i++)
         if (addr[7:3] == 5'(8 + i))
            case (addr[2:0])
               3'd0: rdata = {3'b0, bps[i].kind};
               3'd1: rdata = bps[i].addr[7:0];
               3'd2: rdata = bps[i].addr[15:8];
               3'd3: rdata = bps[i].amask[7:0];
               3'd4: rdata = bps[i].amask[15:8];
               3'd5: rdata = bps[i].data;
               3'd6: rdata = bps[i].dmask;
               default: ;
            endcase
   end
endmodule
