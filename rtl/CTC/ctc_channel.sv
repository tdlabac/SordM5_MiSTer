// Copyright (c) 2015, $ME
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
// Jeden kanál Z80 CTC (Z8430).
//
// Celý obvod běží na clk_sys, předdělička se posouvá na ce_3m58_p — to je
// systémový takt CPU, kterým se ve skutečném obvodu taktuje.
//
// Řídicí slovo kanálu (zápis s D0=1):
//   D7  interrupt enable
//   D6  mode          0 = timer, 1 = counter
//   D5  prescaler     0 = /16,   1 = /256          (jen timer mode)
//   D4  hrana CLK/TRG 0 = sestupná, 1 = náběžná
//   D3  timer trigger 0 = start hned, 1 = start hranou CLK/TRG  (jen timer mode)
//   D2  následuje time constant
//   D1  reset kanálu
//   D0  1 = je to řídicí slovo
//
// Time constant 0 znamená 256.

`default_nettype none

module ctc_channel
(
   input  logic       clk,
   input  logic       ce_3m58_p, // systémový takt CPU, posouvá předděličku
   input  logic       res_n,     // aktivní v 0

   input  logic       sel,       // kanál je vybraný (ctc.sv generuje z !en_n)

   input  logic [7:0] dIn,
   output logic [7:0] dOut,

   input  logic       rd_n,      // aktivní v 0

   output logic       int_req,   // ve VHDL `int`, což je v SV klíčové slovo
   output logic       int_clr,   // pulz: reset kanálu ruší čekající přerušení
   output logic       setTC,     // kanál čeká na time constant

   input  logic       clk_trg,
   output logic       zc_to
);

   typedef enum logic { ST_DEFAULT, ST_SET_TC } state_t;

   state_t     state = ST_DEFAULT;

   // Rozsah 7:3 drží mapování bitů řídicího slova.
   logic [7:3] control = '0;

   logic [7:0] preDivider = '0;
   logic [1:0] preDet     = '0;   // hrana na odbočce předděličky
   logic [1:0] trgDet     = '0;   // hrana na CLK/TRG

   // Datasheet má 8bitový čítač, ale time constant 256 se musí vejít, takže 9 bitů.
   logic [8:0] dCounter     = 9'd0;
   logic [8:0] timeConstant = 9'd256;

   logic       triggerIrq = 1'b0;
   logic       running    = 1'b0;
   logic       startUp    = 1'b1;

   logic       wr_sel_d = 1'b0;

   // D6 = 0 → timer, D5 volí odbočku předděličky (bit 3 = /16, bit 7 = /256)
   wire timer_mode = ~control[6];
   wire pre_tap    = control[5] ? preDivider[7] : preDivider[3];

   // Zápis se provede jednou, na náběžné hraně výběru. Původní VHDL ho nechávalo
   // platit po celou dobu, co byl kanál vybraný, a stav překlápělo až po jeho
   // uvolnění — to fungovalo jen díky mezerám mezi OUT instrukcemi.
   wire wr_sel   = sel & rd_n;
   wire wr_pulse = wr_sel & ~wr_sel_d;

   assign setTC   = (state == ST_SET_TC);
   assign dOut    = dCounter[7:0];       // 9. bit (hodnota 256) se do bajtu nevejde
   assign int_req = triggerIrq & control[7];

   // ctc counter
   always_ff @(posedge clk) begin : counter
      // VHDL proměnné procesu: platí jen v tomhle taktu, proto blokující.
      logic cntrEvent;
      logic trgEvent;

      // ZC/TO je pulz dlouhý jednu periodu CE, ne úroveň držená celou periodu
      // čítání. Shazuje se na CE, nastavuje se níž, takže set přebije clear.
      if (ce_3m58_p)
         zc_to <= 1'b0;

      if (ce_3m58_p)
         preDivider <= preDivider + 8'd1;   // 8 bitů přeteče samo

      // Detektory hran. Index 0 je novější vzorek, index 1 starší,
      // takže 2'b01 je náběžná a 2'b10 sestupná hrana.
      preDet[0] <= pre_tap;
      preDet[1] <= preDet[0];
      trgDet[0] <= clk_trg;
      trgDet[1] <= trgDet[0];

      // D4 platí pro vývod CLK/TRG; odbočka předděličky je interní a bere se
      // náběžnou hranou, aby dělicí poměr vyšel 16 resp. 256.
      trgEvent  = control[4] ? (trgDet == 2'b01) : (trgDet == 2'b10);
      cntrEvent = timer_mode ? (preDet == 2'b01) : trgEvent;

      triggerIrq <= 1'b0;

      if (running) begin
         if (startUp) begin
            // D3 = 1 v timer mode: čekej na hranu CLK/TRG. V counter mode se
            // začíná počítat hned po naplnění time constant.
            if (!timer_mode || !control[3] || trgEvent) begin
               startUp    <= 1'b0;
               dCounter   <= timeConstant;
               preDivider <= 8'd0;        // časovač startuje s čistou předděličkou
            end
         end
         else if (cntrEvent) begin
            if (dCounter == 9'd1) begin   // příští počet 0 => reload
               dCounter   <= timeConstant;
               triggerIrq <= 1'b1;
               zc_to      <= 1'b1;
            end
            else begin
               dCounter <= dCounter - 9'd1;
            end
         end
      end
      else begin
         // Zápisy jsou v procesu později, takže přebijí ty výše — stejně jako
         // ve VHDL, kde platí poslední přiřazení signálu.
         preDet     <= 2'b00;
         startUp    <= 1'b1;
         preDivider <= 8'd0;
         triggerIrq <= 1'b0;
         zc_to      <= 1'b0;
         // dCounter se schválně nenuluje: skutečný obvod hodnotu čítače drží,
         // takže se dá přečíst i po zastavení kanálu.
         // trgDet se taky nenuluje, aby start s D3=1 nechytil falešnou hranu
         // z vlastního rozběhu detektoru.
      end
   end

   // cpu-interface
   always_ff @(posedge clk) begin : cpu
      wr_sel_d <= wr_sel;
      int_clr  <= 1'b0;

      if (!res_n) begin
         state        <= ST_DEFAULT;
         control      <= '0;         // RESET zakazuje přerušení (D7)
         running      <= 1'b0;
         timeConstant <= 9'd256;
      end
      else if (wr_pulse) begin
         if (state == ST_SET_TC) begin           // set Time Constant
            state        <= ST_DEFAULT;
            running      <= 1'b1;
            timeConstant <= (dIn == 8'd0) ? 9'd256 : {1'b0, dIn};
         end
         else if (dIn[0]) begin                  // řídicí slovo
            control <= dIn[7:3];
            state   <= dIn[2] ? ST_SET_TC : ST_DEFAULT;   // D2

            if (dIn[1]) begin                    // D1: reset kanálu
               running <= 1'b0;
               int_clr <= 1'b1;                  // a s ním i čekající přerušení
            end
         end
      end
   end

endmodule

`default_nettype wire
