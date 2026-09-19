//============================================================================
//  Sord M5 — přehrávač kazety (CAS soubor z DDR)
//  Copyright (C) 2021 molekula, přepis z rtl/tape.vhd do SystemVerilogu
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================
//
//  Co dělá
//  -------
//  Externí zařízení vedle počítače (magnetofon), v jádře ho instancuje emu.
//  1. Nahrání: soubor z menu ("F2,CAS,Load Tape,30000000") zapíše MiSTer
//     sám přímo do DDR od 0x30000000 (= adresa 0 rtl/ddram.sv). ioctl slouží
//     jen jako zpráva: po dobu ioctl_download s naším indexem drží ioctl_addr
//     velikost souboru, ioctl_wr nechodí. Po nahrání se z DDR zkontroluje
//     hlavička "SORDM5" na adresách 0-5.
//  2. Přehrávání (cas_on = 1, motor kazety z portu 5xh): od adresy 10h (za
//     16bajtovou hlavičkou) čte bloky a „pípá“ je na cas_out tak, jak by je
//     přehrál magnetofon. cas_out jde na vstup kazety počítače (port 50h,
//     bit 0).
//
//  Formát CAS (Sord M5)
//  --------------------
//    00h-0Fh  hlavička: "SORDM5" a doplnění
//    blok:    typ (1 B) | délka n (1 B, 0 = 256) | data (n B) | součet (1 B)
//             typ 'H' (48h) = hlavičkový blok, jinak datový
//
//  Co se vysílá za každý blok
//  --------------------------
//    zaváděcí tón  8 × '1' na bajt, bez start/stop bitu:
//                  500 bajtů před blokem 'H', 32 bajtů před ostatními
//    blok          typ, délka, data, součet (n + 3 bajtů), každý bajt jako
//                  start '0', 8 bitů od LSB, stop '1'
//  Za posledním blokem jeden bit '1'.
//
//  Kódování bitu: tik = TICK_CE taktů ce (výchozí 874 × 1/3,579545 MHz =
//  244,2 µs). '1' = 1 tik v jedničce + 1 tik v nule (2048 Hz), '0' = 2 + 2
//  tiky (1024 Hz). cas_fast zkracuje tik na polovinu (platí hned, od
//  dalšího tiku; menu Fast Tape). Časy odpovídají
//  původnímu jádru (tik 2 × 5209 taktů při 42,666 MHz).
//
//  Rozdíly proti tape.vhd
//  ----------------------
//  - Soubor nejde přes ioctl_wr do DDR, zapisuje ho MiSTer přímo (viz výše),
//    hlavička se proto kontroluje čtením z DDR.
//  - Místo vlastního 42,666MHz čítače tiků jede na ce (takt CPU), takže
//    přehrávání stojí i při zmrazení debuggerem.
//  - Soubor se bere jen z vlastního ioctl indexu (VHDL bral jakýkoli).
//  - Zaváděcí tón: VHDL nastavoval čítač 1000/64, ale ve stavu PLAY_SYNC ho
//    odečítal dvakrát za bajt (start_s čekal jen na busy), takže vysílal
//    500/32 bajtů. Tady je to 500/32 rovnou, výstup je stejný.
//  - reset_n se ve VHDL nepoužíval, tady port není.
//  - VHDL převzal rychlost (casSpeed) jen při nahrání, tady platí přepnutí
//    kdykoli.
//
//  Paměť jako ve VHDL: jednotaktový pulz mem_rd, pak čekat na mem_ready.
//  Aby se pulz neztratil, když DDR zrovna hlásí DDRAM_BUSY, zachytává ho
//  rtl/ddram.sv do čekajícího požadavku (upraveno, viz tam). Mezipaměť
//  ddram.sv musí emu po nahrání vyprázdnit (reset ddram = loading).
//============================================================================

`default_nettype none

module cas_pulse #(
   parameter int TICK_CE = 874
)(
   input  wire        clk,
   input  wire        ce,          // takt CPU (tik = TICK_CE taktů ce)
   input  wire        fast,        // tik poloviční
   input  wire  [7:0] data,
   input  wire        start,       // náběžná hrana = vyslat (jen když !busy)
   input  wire        sync,        // 8 bitů bez start/stop (zaváděcí tón)
   input  wire        stop,        // jediný bit '1' (konec pásky)
   output logic       busy,
   output logic       out
);
   // tik: ekvivalent náběžné hrany pulseClock ve VHDL
   localparam int          TICK_FULL_I = TICK_CE - 1;
   localparam int          TICK_HALF_I = TICK_CE / 2 - 1;
   localparam logic [15:0] TICK_FULL = TICK_FULL_I[15:0];
   localparam logic [15:0] TICK_HALF = TICK_HALF_I[15:0];
   logic [15:0] tcnt = '0;
   logic        tick;
   always_ff @(posedge clk) begin
      tick <= 1'b0;
      if (ce) begin
         if (tcnt == 0) begin
            tick <= 1'b1;
            tcnt <= fast ? TICK_HALF : TICK_FULL;
         end else
            tcnt <= tcnt - 16'd1;
      end
   end

   logic [3:0] count = '0;
   logic [9:0] shreg;
   logic       prev_start = 1'b0;
   logic       add = 1'b0;         // bit '0': prodloužit právě běžící půlvlnu o tik
   initial out = 1'b0;

   assign busy = count != 0;

   always_ff @(posedge clk) begin
      prev_start <= start;
      if (count == 0) begin
         if (start && !prev_start) begin
            case ({stop, sync})
               2'b00:   begin shreg <= {1'b1, data, 1'b0}; count <= 4'd10; end  // stop, data, start
               2'b01:   begin shreg <= {2'b00, data};      count <= 4'd8;  end
               default: begin shreg <= '1;                 count <= 4'd1;  end
            endcase
         end
      end else if (tick) begin
         if (add)
            add <= 1'b0;
         else if (!out) begin
            out <= 1'b1;
            add <= !shreg[0];
         end else begin
            out   <= 1'b0;
            add   <= !shreg[0];
            shreg <= {1'b0, shreg[9:1]};
            count <= count - 4'd1;
         end
      end
   end
endmodule


module cas_player #(
   parameter logic [5:0] IOCTL_INDEX = 6'd2,     // "F2,CAS,..." v CONF_STR
   parameter int         TICK_CE     = 874       // tik 244,2 µs při ce 3,579545 MHz
)(
   input  wire                clk,
   input  wire                ce,                // takt CPU (ce_3m58_p, stojí při zmrazení)
   input  sordm5_pkg::ioctl_t ioctl,             // jen download/index/addr (velikost)
   output logic               loading,           // právě se nahrává soubor (-> reset ddram)

   input  wire                cas_on,            // přehrávat (motor kazety)
   input  wire                cas_fast,          // dvojnásobná rychlost
   output logic               cas_out,           // signál z kazety -> vstup počítače
   output logic [4:0]         border,            // {cas_out, data[3:0]}: barva okraje při nahrávání

   // rtl/ddram.sv, 8bitové rozhraní, jen čtení
   output logic [27:0]        mem_addr,
   output logic               mem_rd,
   input  wire  [7:0]         mem_dout,
   input  wire                mem_ready
);
   localparam logic [8:0] LEADER_HDR  = 9'd500;  // bajtů zaváděcího tónu před blokem 'H'
   localparam logic [8:0] LEADER_DATA = 9'd32;   // ... před ostatními

   // ------------------------------------------------------------------
   // Nahrání: velikost souboru z ioctl_addr (po dobu ioctl_download)
   assign loading = ioctl.download && ioctl.index[5:0] == IOCTL_INDEX;

   logic [24:0] size = '0;
   always_ff @(posedge clk)
      if (loading) size <= ioctl.addr[24:0];

   function automatic logic [7:0] magic(input logic [2:0] i);
      case (i)
         3'd0: magic = "S"; 3'd1: magic = "O"; 3'd2: magic = "R";
         3'd3: magic = "D"; 3'd4: magic = "M"; default: magic = "5";
      endcase
   endfunction

   // ------------------------------------------------------------------
   // Kontrola hlavičky a přehrávání
   typedef enum logic [3:0] {
      P_MAGIC0, P_MAGIC,                          // kontrola "SORDM5" (bez ohledu na motor)
      P_START, P_TYPE, P_SYNC, P_LEN, P_DATA, P_STOP,
      P_IDLE
   } pstate_t;
   pstate_t     st = P_IDLE;
   logic [24:0] addr = '0;
   logic [8:0]  cnt;
   logic [7:0]  data = '1;
   logic        start = 1'b0, sync = 1'b0, stop = 1'b0;
   logic        rd = 1'b0;
   logic        busy;

   wire checking = st == P_MAGIC0 || st == P_MAGIC;
   wire at_end   = size <= addr;                  // za posledním bajtem souboru

   assign mem_addr = {3'b000, addr};
   assign mem_rd   = rd;

   always_ff @(posedge clk) begin
      if (loading) begin
         addr  <= '0;
         st    <= P_MAGIC0;
         rd    <= 1'b0;
         start <= 1'b0;
         stop  <= 1'b0;
      end else if (checking || cas_on) begin
         start <= 1'b0;
         case (st)
            P_MAGIC0:
               if (size < 25'd17)                 // hlavička + aspoň 1 bajt
                  st <= P_IDLE;
               else if (mem_ready) begin
                  rd <= 1'b1;
                  st <= P_MAGIC;
               end
            P_MAGIC: begin
               rd <= 1'b0;
               if (mem_ready && !rd) begin
                  if (mem_dout != magic(addr[2:0]))
                     st <= P_IDLE;                // není to CAS pro M5
                  else if (addr[2:0] == 3'd5) begin
                     addr <= 25'h10;              // za hlavičku
                     st   <= P_START;
                  end else begin
                     addr <= addr + 25'd1;
                     rd   <= 1'b1;
                  end
               end
            end
            P_START:
               if (mem_ready) begin               // čtení typu prvního bloku
                  rd <= 1'b1;
                  st <= P_TYPE;
               end
            P_TYPE: begin                         // typ -> délka zaváděcího tónu
               rd <= 1'b0;
               if (mem_ready && !rd) begin
                  cnt  <= (mem_dout == 8'h48) ? LEADER_HDR : LEADER_DATA;
                  addr <= addr + 25'd1;          // čte se délka bloku
                  rd   <= 1'b1;
                  st   <= P_SYNC;
               end
            end
            P_SYNC:                               // zaváděcí tón
               if (cnt == 0)
                  st <= P_LEN;
               else if (!busy && !start) begin
                  data  <= '1;
                  sync  <= 1'b1;
                  start <= 1'b1;
                  cnt   <= cnt - 9'd1;
               end
            P_LEN: begin                          // délka -> počet bajtů bloku
               rd <= 1'b0;
               if (mem_ready && !rd) begin
                  cnt  <= (mem_dout == 0) ? 9'h103 : {1'b0, mem_dout} + 9'd3;  // typ, délka, data, součet
                  addr <= addr - 25'd1;          // zpět na typ, vysílá se celý blok
                  rd   <= 1'b1;
                  st   <= P_DATA;
               end
            end
            P_DATA: begin
               rd <= 1'b0;
               if (cnt == 0)
                  st <= at_end ? P_STOP : P_TYPE;
               else if (!busy && !start && mem_ready && !rd) begin
                  data  <= mem_dout;
                  sync  <= 1'b0;
                  start <= 1'b1;
                  cnt   <= cnt - 9'd1;
                  addr  <= addr + 25'd1;
                  rd    <= 1'b1;                  // další bajt předem
               end
            end
            P_STOP:
               if (!busy && !start) begin         // závěrečný bit '1'
                  sync  <= 1'b0;
                  stop  <= 1'b1;
                  start <= 1'b1;
                  st    <= P_IDLE;
               end
            default: ;                            // P_IDLE
         endcase
         // konec souboru kdykoli během přehrávání
         if (!checking && st != P_IDLE && st != P_STOP && at_end)
            st <= P_STOP;
      end
   end

   cas_pulse #(.TICK_CE(TICK_CE)) pulse_i (
      .clk(clk), .ce(ce), .fast(cas_fast),
      .data(data), .start(start), .sync(sync), .stop(stop),
      .busy(busy), .out(cas_out)
   );

   assign border = {cas_out, data[3:0]};
endmodule

`default_nettype wire
