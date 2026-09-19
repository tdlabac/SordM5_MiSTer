// Copyright (c) 2015, $ME
// Copyright (c) 2021, molekula
//
// All rights reserved.
//
// Redistribution and use in source and synthezised forms, with or without modification, are permitted
// provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this list of conditions
//    and the following disclaimer.
//
// 2. Redistributions in synthezised form must reproduce the above copyright notice, this list of conditions
//    and the following disclaimer in the documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
// WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
// PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
// TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
// HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
// NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//
//
// Z80 CTC (Z8430) — čtyři kanály, vektorové přerušení v režimu IM2.
//
// Celý obvod běží na clk_sys, předdělička kanálů se posouvá na ce_3m58_p.
// Rozdělení řídicího slova je popsané v ctc_channel.sv.
//
// Zapojení:
//   ce_3m58_p  musí být takt CPU (3,58 MHz), ne clk_sys — jinak nesedí časy
//   iei        daisy chain; samostatné CTC váže na 1'b1
//   dOut       FPGA nemá třístavovou sběrnici, takže mimo povolený výstup
//              vrací 8'hFF a nadřazený modul periferie slučuje přes AND.
//              Výstup je povolený při čtení z CTC a po celou dobu potvrzení
//              přerušení, na které CTC odpovídá.
//   zc_to[3]   skutečný Z8430 vývod ZC/TO3 nemá, tady je pro úplnost funkční

`default_nettype none

module ctc
(
   input  logic       clk,
   input  logic       ce_3m58_p,  // systémový takt CPU
   input  logic       res_n,      // aktivní v 0
   input  logic       en_n,       // výběr obvodu, aktivní v 0

   input  logic [7:0] dIn,
   input  logic [7:0] dInCpu,     // datová sběrnice CPU, kvůli detekci RETI
   output logic [7:0] dOut,

   input  logic [1:0] cs,
   input  logic       m1_n,       // aktivní v 0
   input  logic       iorq_n,     // aktivní v 0
   input  logic       rd_n,       // aktivní v 0
   output logic       int_n,      // aktivní v 0

   input  logic       iei,        // daisy chain in
   output logic       ieo,        // daisy chain out

   input  logic [3:0] clk_trg,
   output logic [3:0] zc_to
);

   logic [3:0] cSel;
   logic [7:0] cDOut [0:3];
   logic [3:0] cSetTC;
   logic       setTC;

   logic [3:0] ch_int;            // ve VHDL `int`, což je v SV klíčové slovo
   logic [3:0] ch_int_clr;

   // Rozsah 7:3 drží mapování bitů vektoru.
   logic [7:3] irqVect       = '0;
   logic [1:0] intAckChannel = '0;

   typedef enum logic [1:0] { ST_IDLE, ST_WAIT_INT_ACCEPTED, ST_WAIT_RETI } state_t;

   state_t     state = ST_IDLE;

   logic       cpuACKint;
   logic [3:0] internalInt = '0;
   logic [3:0] lastInt     = '0;
   logic       reti = 1'b0;

   // VHDL má `int_n : out std_logic := '1'`, ale SV na výstupním portu
   // inicializátor nedovoluje, proto registr uvnitř.
   logic       int_n_q = 1'b1;

   // Tohle CTC odpovídá na právě běžící potvrzení přerušení. Drží se po celou
   // dobu M1+IORQ: stav přejde do ST_WAIT_RETI hned v prvním taktu, ale Z80
   // čte vektor až později (TV80 na konci T2, zhruba 6 taktů clk_sys).
   logic       ack_hold = 1'b0;

   assign int_n = int_n_q;

   assign cpuACKint = (!iorq_n && !m1_n);

   // Běžný I/O cyklus CPU (ne potvrzení přerušení).
   //
   // TV80 na konci potvrzení přerušení zvedne M1 (na CE_p) o půl taktu CPU
   // dřív než IORQ (na CE_n). V tom okně je IORQ=0, M1=1, RD=1 a na adrese je
   // refresh (I, R) — pro CTC k nerozeznání od zápisu. Když horní nibble R
   // vyjde 0, CTC by si ho vzalo jako zápis: na kanál 0 s D0=0 přepsalo vektor
   // přerušení, jinde přeprogramovalo kanál hodnotou z DO. Závisí to na R, takže
   // se to projeví náhodně po chvíli běhu (další přerušení skočí na špatnou
   // adresu).
   //
   // Proto: cyklus IORQ, který začal jako potvrzení, zůstává potvrzením, dokud
   // IORQ nespadne zpátky do jedničky.
   logic ack_cycle = 1'b0;
   always_ff @(posedge clk) begin
      if (iorq_n)
         ack_cycle <= 1'b0;
      else if (!m1_n)
         ack_cycle <= 1'b1;
   end

   wire io_cycle = !iorq_n && m1_n && !ack_cycle;

   // Kanál s nejvyšší prioritou mezi čekajícími (0 je nejvyšší).
   logic [1:0] prio_ch;
   always_comb begin
      if      (internalInt[0]) prio_ch = 2'd0;
      else if (internalInt[1]) prio_ch = 2'd1;
      else if (internalInt[2]) prio_ch = 2'd2;
      else                     prio_ch = 2'd3;
   end

   // V prvním taktu potvrzení ještě intAckChannel nemá novou hodnotu,
   // proto se číslo kanálu bere přímo z priority.
   wire [1:0] vec_ch = (state == ST_WAIT_INT_ACCEPTED) ? prio_ch : intAckChannel;

   // Vektor jen tehdy, když o přerušení požádalo tohle CTC a nic ho v daisy
   // chain nepředbíhá — ne na každý ack cyklus, tedy ne i za jiné zařízení.
   wire vector_oe = cpuACKint && iei &&
                    ((state == ST_WAIT_INT_ACCEPTED && internalInt != 4'b0000) ||
                     ack_hold);

   // Čtení z CTC: vybraný obvod, I/O cyklus (ne potvrzení), RD aktivní.
   wire read_oe = !en_n && io_cycle && !rd_n;

   // Prioritu pouští dál jen když tohle CTC nic nechce ani neobsluhuje.
   assign ieo = iei && (state == ST_IDLE) && (internalInt == 4'b0000);

   assign dOut = read_oe   ? cDOut[cs] :
                 vector_oe ? {irqVect, vec_ch, 1'b0} :
                             8'hFF;

   assign setTC = (cs == 2'b00) ? cSetTC[0] :
                  (cs == 2'b01) ? cSetTC[1] :
                  (cs == 2'b10) ? cSetTC[2] :
                                  cSetTC[3];

   always_ff @(posedge clk) begin : genInt
      int_n_q <= 1'b1;

      if (!cpuACKint)
         ack_hold <= 1'b0;

      if (!res_n) begin
         state       <= ST_IDLE;
         int_n_q     <= 1'b1;
         lastInt     <= 4'b0000;
         internalInt <= 4'b0000;
         ack_hold    <= 1'b0;
      end
      else begin
         case (state)
            ST_IDLE:
               if (internalInt != 4'b0000 && iei) begin   // int request
                  state   <= ST_WAIT_INT_ACCEPTED;
                  int_n_q <= 1'b0;
               end

            ST_WAIT_INT_ACCEPTED:
               if (cpuACKint && iei && internalInt != 4'b0000) begin  // incoming ack
                  int_n_q                <= 1'b1;
                  internalInt[prio_ch]   <= 1'b0;         // reset int
                  intAckChannel          <= prio_ch;
                  ack_hold               <= 1'b1;
                  state                  <= ST_WAIT_RETI;
               end
               else if (internalInt == 4'b0000) begin
                  // Žádost stažená resetem kanálu — int_n_q zůstane v 1
                  // z defaultu na začátku procesu.
                  state <= ST_IDLE;
               end
               else begin
                  int_n_q <= 1'b0;
               end

            ST_WAIT_RETI:
               // RETI ruší obsluhu jen tomu, kdo ji opravdu drží.
               if (reti && iei)
                  state <= ST_IDLE;

            default: ;
         endcase

         // Je to v procesu za case, takže nová hrana přebije reset int výše —
         // stejně jako ve VHDL. Reset kanálu je až za tím, aby přebil obojí.
         for (int k = 0; k < 4; k++) begin
            if (!lastInt[k] && ch_int[k])                 // new interupt
               internalInt[k] <= 1'b1;

            if (ch_int_clr[k])
               internalInt[k] <= 1'b0;
         end

         lastInt <= ch_int;
      end
   end

   always_ff @(posedge clk) begin : cpuInt
      // Vektor přerušení se podle datasheetu plní zápisem na kanál 0 s D0=0.
      if (!en_n && rd_n && io_cycle && cs == 2'b00 && !dIn[0] && !setTC)
         irqVect <= dIn[7:3];
   end

   // Quartus 17 nebere `for (genvar i = ...)` ani bit-select na genvaru,
   // proto genvar zvlášť a číslo kanálu přes integer localparam
   // (stejně jako sys/mt32pi.sv).
   genvar i;
   generate
      for (i = 0; i < 4; i++) begin : channels
         localparam integer CH = i;

         ctc_channel channel
         (
            .clk       (clk),
            .ce_3m58_p (ce_3m58_p),
            .res_n     (res_n),
            .sel       (cSel[i]),
            .dIn       (dIn),
            .dOut      (cDOut[i]),
            .rd_n      (rd_n),
            .int_req   (ch_int[i]),
            .int_clr   (ch_int_clr[i]),
            .setTC     (cSetTC[i]),
            .clk_trg   (clk_trg[i]),
            .zc_to     (zc_to[i])
         );

         assign cSel[i] = (!en_n && io_cycle && (cs == CH[1:0]));
      end
   endgenerate

   // Proměnné procesu findReti. Ve VHDL to jsou proměnné procesu: drží
   // hodnotu mezi takty a uvnitř taktu jsou vidět hned, proto modulové
   // signály s blokujícím přiřazením.
   logic       retiState       = 1'b0;
   logic [7:0] opcode          = '0;
   logic       last_opcodeRead = 1'b0;

   // Hledá sekvenci ED 4D ve dvou po sobě jdoucích M1 cyklech. Cyklus int
   // acknowledge se vynechává tím, že se vyžaduje iorq_n v jedničce.
   //
   // Vzorkuje se jen na ce_3m58_p (hodiny CPU, jako skutečný Z80-CTC), ne
   // každý takt clk_sys. Při zmrazení počítače debuggerem (doc/z80-debugger.md)
   // tak detektor nevidí přístupy debuggeru do paměti: debugger na chvíli
   // zvedne M1 uprostřed fetche a bez toho by se opkód (třeba ED z RETI)
   // započetl dvakrát a RETI by se ztratilo. Fetch trvá přes dvě CE_p
   // (konec T1 a T2), poslední vzorek je opkód na konci T2.
   /* verilator lint_off BLKSEQ */
   always_ff @(posedge clk) begin : findReti
      reti <= 1'b0;

      if (!ce_3m58_p) begin
         // mimo CE se nic nemění
      end
      else if (!m1_n && iorq_n && !rd_n) begin
         opcode          = dInCpu;
         last_opcodeRead = 1'b1;
      end
      else if (last_opcodeRead) begin
         last_opcodeRead = 1'b0;

         if (!retiState) begin
            if (opcode == 8'hED)
               retiState = 1'b1;
         end
         else begin
            if (opcode == 8'h4D)
               reti <= 1'b1;
            retiState = 1'b0;
         end
      end
   end
   /* verilator lint_on BLKSEQ */

endmodule

`default_nettype wire
