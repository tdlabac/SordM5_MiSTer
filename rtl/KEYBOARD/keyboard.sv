//============================================================================
//  Sord M5
//  Keyboard matrix maping
//  Copyright (C) 2021 molekula
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================
//
// Převod z keyboard.vhd 1:1.
//
// ps2_code_i je ps2_key z hps_io: [10] se překlápí s každou událostí,
// [9] = 1 při stisku / 0 při uvolnění, [8] = rozšířený kód (E0), [7:0] kód.
// Ve VHDL se bit [9] jmenoval `release`, ale nese 1 = stisknuto; navíc je
// `release` ve Verilogu klíčové slovo (force/release), proto `pressed`.
// Rozšířený bit [8] se nekontroluje, takže např. šipky (E0 74) a numerická 6
// (74) padnou na stejnou klávesu M5.

`default_nettype none

module keyboard
(
   input  wire        clk_i,
   input  wire [10:0] ps2_code_i,
   input  wire [5:0]  joy[2],
   input  wire [2:0]  addr_i,
   input  wire        kb_ce_i,
   output wire [7:0]  kb_data_o,
   output wire        kb_rst_o
);

   // keyMatrix[port][bit], port = kb_addr_i (I/O 0x30-0x37)
   logic [7:0][7:0] keyMatrix = '0;
   logic [7:0]      scancode;
   logic            resetKey = 1'b0;
   logic            pressed  = 1'b0;
   logic            changed  = 1'b0;

   // VHDL proměnná procesu change: porovnává se se starou hodnotou a zapisuje
   // až potom, takže je to obyčejný registr.
   logic [10:0]     old_code = '0;

   assign kb_rst_o  = resetKey;

   // Joystick se do matice přimíchává až tady, na výstupu.
   //
   // Do keyMatrix patřit nemůže: ta se přepisuje jen při události z PS/2
   // (`changed`), takže by se pohyb páky projevil až po stisku nějaké klávesy
   // a pak by v matici zůstal viset až do další události. Původní VHDL
   // (keyboard.vhd, commit "Joypad support") proto tyhle řádky mělo mimo
   // `if changed`, a stav kláves 1, 2, 5, 6 si drželo zvlášť, aby je spoušť
   // joysticku nepřepsala.
   logic [7:0][7:0] joyMatrix;
   always_comb begin
      joyMatrix = '0;
      // spouště: klávesy 1, 2 (levý joystick) a 5, 6 (pravý)
      joyMatrix[1][0] = joy[0][4];
      joyMatrix[1][1] = joy[0][5];
      joyMatrix[1][4] = joy[1][4];
      joyMatrix[1][5] = joy[1][5];
      // směry, port 37 (viz schéma dole)
      joyMatrix[7] = {joy[1][2], joy[1][1], joy[1][3], joy[1][0],
                      joy[0][2], joy[0][1], joy[0][3], joy[0][0]};
   end

   assign kb_data_o = kb_ce_i ? (keyMatrix[addr_i] | joyMatrix[addr_i]) : 8'hFF;

   always_ff @(posedge clk_i) begin : change
      if (old_code != ps2_code_i) begin
         pressed  <= ps2_code_i[9];
         scancode <= ps2_code_i[7:0];
         changed  <= 1'b1;
      end
      else begin
         changed  <= 1'b0;
      end
      old_code <= ps2_code_i;
   end

   always_ff @(posedge clk_i) begin : decode
      if (changed) begin
         case (scancode)
            // port 30
            8'h14: keyMatrix[0][0] <= pressed;   // CTRL
            8'h1f: keyMatrix[0][1] <= pressed;   // FUNC
            8'h12: keyMatrix[0][2] <= pressed;   // L. SHIFT
            8'h59: keyMatrix[0][3] <= pressed;   // R. SHIFT
            8'h29: keyMatrix[0][6] <= pressed;   // SPACE
            8'h5a: keyMatrix[0][7] <= pressed;   // ENTER
            // port 31
            8'h16: keyMatrix[1][0] <= pressed;   // 1 (+ spoušť JOY0, viz joyMatrix)
            8'h1e: keyMatrix[1][1] <= pressed;   // 2 (+ útok JOY0)
            8'h26: keyMatrix[1][2] <= pressed;   // 3
            8'h25: keyMatrix[1][3] <= pressed;   // 4
            8'h2e: keyMatrix[1][4] <= pressed;   // 5 (+ spoušť JOY1)
            8'h36: keyMatrix[1][5] <= pressed;   // 6 (+ útok JOY1)
            8'h3d: keyMatrix[1][6] <= pressed;   // 7
            8'h3e: keyMatrix[1][7] <= pressed;   // 8
            // port 32
            8'h15: keyMatrix[2][0] <= pressed;   // Q
            8'h1d: keyMatrix[2][1] <= pressed;   // W
            8'h24: keyMatrix[2][2] <= pressed;   // E
            8'h2d: keyMatrix[2][3] <= pressed;   // R
            8'h2c: keyMatrix[2][4] <= pressed;   // T
            8'h35: keyMatrix[2][5] <= pressed;   // Y
            8'h3c: keyMatrix[2][6] <= pressed;   // U
            8'h43: keyMatrix[2][7] <= pressed;   // I
            // port 33
            8'h1c: keyMatrix[3][0] <= pressed;   // A
            8'h1b: keyMatrix[3][1] <= pressed;   // S
            8'h23: keyMatrix[3][2] <= pressed;   // D
            8'h2b: keyMatrix[3][3] <= pressed;   // F
            8'h34: keyMatrix[3][4] <= pressed;   // G
            8'h33: keyMatrix[3][5] <= pressed;   // H
            8'h3b: keyMatrix[3][6] <= pressed;   // J
            8'h42: keyMatrix[3][7] <= pressed;   // K
            // port 34
            8'h1a: keyMatrix[4][0] <= pressed;   // Z
            8'h22: keyMatrix[4][1] <= pressed;   // X
            8'h21: keyMatrix[4][2] <= pressed;   // C
            8'h2a: keyMatrix[4][3] <= pressed;   // V
            8'h32: keyMatrix[4][4] <= pressed;   // B
            8'h31: keyMatrix[4][5] <= pressed;   // N
            8'h3a: keyMatrix[4][6] <= pressed;   // M
            8'h41: keyMatrix[4][7] <= pressed;   // ,
            // port 35
            8'h46: keyMatrix[5][0] <= pressed;   // 9
            8'h45: keyMatrix[5][1] <= pressed;   // 0
            8'h4e: keyMatrix[5][2] <= pressed;   // -
            8'h55: keyMatrix[5][3] <= pressed;   // ^
            8'h49: keyMatrix[5][4] <= pressed;   // .
            8'h4a: keyMatrix[5][5] <= pressed;   // /
            8'h0e: keyMatrix[5][6] <= pressed;   // _
            8'h5d: keyMatrix[5][7] <= pressed;   // zpětné lomítko
            // port 36
            8'h44: keyMatrix[6][0] <= pressed;   // O
            8'h4d: keyMatrix[6][1] <= pressed;   // P
            // keyMatrix[6][2] ve VHDL nezapojený
            8'h54: keyMatrix[6][3] <= pressed;   // [
            8'h4b: keyMatrix[6][4] <= pressed;   // L
            8'h4c: keyMatrix[6][5] <= pressed;   // ;
            8'h52: keyMatrix[6][6] <= pressed;   // :
            8'h5b: keyMatrix[6][7] <= pressed;   // ]

            // multy
            8'h66: begin                         // BACKSPACE
               keyMatrix[3][5] <= pressed;
               keyMatrix[0][0] <= pressed;
            end
            8'h76: resetKey <= pressed;          // PC ESC

            default: ;
         endcase
      end
   end

// joystick_x[0] - right
// joystick_x[1] - left
// joystick_x[2] - down
// // joystick_x[3] - up
//  P.JOY | P.JOY | P.JOY | P.JOY | L.JOY | L.JOY | L.JOY | L.JOY | 37
// |   |   |  <--  |   ^   |  -->  |   |   |  <--  |   ^   |  -->  |
// |   v   |       |   |   |       |   v   |       |   |   |       |
// `-------+-------+-------+-------+-------+-------+-------+-------'

// Spoustece joy ( fire, attack ) jsou napojeny na klavesy 1, 2, 5 a 6.
endmodule

`default_nettype wire
