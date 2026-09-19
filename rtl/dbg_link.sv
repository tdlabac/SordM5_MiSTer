//============================================================================
//  dbg_link — přenos registrového prostoru debuggeru přes UART
//             (doc/z80-debugger.md, protokol: doc/z80-debugger-protokol.md)
//
//  Na MiSTeru vede UART jádra na UART HPS, v Linuxu /dev/ttyS1. 8N1,
//  výchozí 230 400 Bd (HPS UART má takt 100 MHz, vyšší standardní rychlosti
//  vycházejí s chybou 3-4 %).
//
//  Obsluhuje sběrnici tv80_dbg_regs: wr/addr/wdata registrované, rdata je
//  kombinační odpověď na addr, takže se vzorkuje takt po nastavení addr.
//
//  Příkazy (host -> jádro), argumenty jsou bajty:
//    'P'                  ping, odpověď 5Ah
//    'R' a                čtení registru a, odpověď 1 B
//    'W' a d              zápis registru, bez odpovědi
//    'B' a n              čtení n registrů od a (n = 0 znamená 256), odpověď n B
//    'M' lo hi nlo nhi    čtení paměti od adresy (jen při zastavení),
//                         odpověď n B (n = 0 znamená 65 536)
//    'N' lo hi nlo nhi d… zápis n bajtů paměti, na konci odpověď 5Ah
//  Když argument nepřijde do TIMEOUT_MS, rozpracovaný příkaz se zahodí
//  (host se tak vždy dostane do známého stavu: počkat a poslat 'P').
//
//  V simulaci ho nahrazuje verilator/rtl/dbg_link_dpi.sv (DPI do sim appky).
//============================================================================

module dbg_link #(
   parameter int CLK_HZ     = 21_477_270,
   parameter int BAUD       = 230_400,
   parameter int TIMEOUT_MS = 20
)(
   input  logic       clk,
   input  logic       reset,
   input  logic       uart_rxd,
   output logic       uart_txd,

   output logic       wr,
   output logic [7:0] addr,
   output logic [7:0] wdata,
   input  logic [7:0] rdata
);
   localparam int DIV = (CLK_HZ + BAUD / 2) / BAUD;   // zaokrouhleno
   localparam int TMO = CLK_HZ / 1000 * TIMEOUT_MS;

   // ------------------------------------------------------------------
   // UART příjem (8N1, vzorkování uprostřed bitu)
   logic [2:0]  rx_sync = 3'b111;
   logic        rx_busy = 1'b0;
   logic [15:0] rx_cnt;
   logic [3:0]  rx_bit;
   logic [7:0]  rx_sh;
   logic        rx_valid;
   logic [7:0]  rx_byte;

   always_ff @(posedge clk) begin
      rx_sync  <= {rx_sync[1:0], uart_rxd};
      rx_valid <= 1'b0;
      if (reset) begin
         rx_busy <= 1'b0;
      end else if (!rx_busy) begin
         if (rx_sync[2:1] == 2'b10) begin           // sestupná hrana = start bit
            rx_busy <= 1'b1;
            rx_cnt  <= 16'(DIV / 2);
            rx_bit  <= 4'd0;
         end
      end else if (rx_cnt != 0) begin
         rx_cnt <= rx_cnt - 16'd1;
      end else begin
         rx_cnt <= 16'(DIV - 1);
         rx_bit <= rx_bit + 4'd1;
         case (rx_bit)
            4'd0: if (rx_sync[1]) rx_busy <= 1'b0;   // start bit nebyl 0: šum
            4'd9: begin
                     rx_busy <= 1'b0;
                     if (rx_sync[1]) begin            // platný stop bit
                        rx_valid <= 1'b1;
                        rx_byte  <= rx_sh;
                     end
                  end
            default: rx_sh <= {rx_sync[1], rx_sh[7:1]};
         endcase
      end
   end

   // FIFO příjmu (16 B)
   logic [7:0] fifo [16];
   logic [4:0] f_wp = '0, f_rp = '0;
   wire        f_empty = f_wp == f_rp;
   wire [7:0]  f_out   = fifo[f_rp[3:0]];
   logic       f_pop;
   always_ff @(posedge clk) begin
      if (reset) begin
         f_wp <= '0; f_rp <= '0;
      end else begin
         if (rx_valid && (f_wp - f_rp) != 5'd16) begin
            fifo[f_wp[3:0]] <= rx_byte;
            f_wp <= f_wp + 5'd1;
         end
         if (f_pop && !f_empty) f_rp <= f_rp + 5'd1;
      end
   end

   // ------------------------------------------------------------------
   // UART vysílání
   logic        tx_go;           // pulz: odeslat tx_data
   logic [7:0]  tx_data;
   logic        tx_busy = 1'b0;
   logic [15:0] tx_cnt;
   logic [9:0]  tx_sh;
   logic [3:0]  tx_bit;

   always_ff @(posedge clk) begin
      if (reset) begin
         tx_busy  <= 1'b0;
         uart_txd <= 1'b1;
      end else if (!tx_busy) begin
         uart_txd <= 1'b1;
         if (tx_go) begin
            tx_busy <= 1'b1;
            tx_sh   <= {1'b1, tx_data, 1'b0};
            tx_cnt  <= 16'(DIV - 1);
            tx_bit  <= 4'd0;
            uart_txd <= 1'b0;
         end
      end else if (tx_cnt != 0) begin
         tx_cnt <= tx_cnt - 16'd1;
      end else begin
         tx_cnt <= 16'(DIV - 1);
         tx_bit <= tx_bit + 4'd1;
         tx_sh  <= {1'b1, tx_sh[9:1]};
         uart_txd <= tx_sh[1];
         if (tx_bit == 4'd9) begin
            tx_busy  <= 1'b0;
            uart_txd <= 1'b1;
         end
      end
   end

   // ------------------------------------------------------------------
   // Příkazy
   typedef enum logic [4:0] {
      S_IDLE, S_ARGS, S_DISPATCH, S_SEND,
      S_BRD, S_BRD_CAP,
      S_M_A0, S_M_A1, S_M_CMD, S_M_WAIT, S_M_RD, S_M_CAP,
      S_N_DATA, S_N_A0, S_N_A1, S_N_D, S_N_CMD, S_N_WAIT
   } st_t;
   st_t         st, ret;
   logic [7:0]  cmd;
   logic [7:0]  arg [4];
   logic [2:0]  argi, nargs, na;
   logic [23:0] tmo;
   logic [7:0]  ra;
   logic [16:0] cnt;
   logic [15:0] maddr;
   logic [7:0]  txb, nd;
   logic [2:0]  wcnt;

   always_comb
      case (f_out)
         "R":          nargs = 3'd1;
         "W", "B":     nargs = 3'd2;
         "M", "N":     nargs = 3'd4;
         default:      nargs = 3'd0;
      endcase

   // f_pop je kombinační: bajt se odebere v taktu, kdy ho FSM převezme
   always_comb
      f_pop = !f_empty && (st == S_IDLE || st == S_ARGS || st == S_N_DATA);

   always_ff @(posedge clk) begin
      wr    <= 1'b0;
      tx_go <= 1'b0;
      if (reset) begin
         st <= S_IDLE;
         addr <= 8'h00;
      end else case (st)
         S_IDLE:
            if (!f_empty) begin
               cmd  <= f_out;
               na   <= nargs;
               argi <= 3'd0;
               tmo  <= '0;
               st   <= (nargs == 0) ? S_DISPATCH : S_ARGS;
            end
         S_ARGS:
            if (!f_empty) begin
               arg[argi[1:0]] <= f_out;
               argi <= argi + 3'd1;
               tmo  <= '0;
               if (argi + 3'd1 == na)
                  st <= S_DISPATCH;
            end else if (tmo == 24'(TMO)) st <= S_IDLE;
            else tmo <= tmo + 24'd1;
         S_DISPATCH:
            case (cmd)
               "P": begin txb <= 8'h5A; ret <= S_IDLE; st <= S_SEND; end
               "R": begin ra <= arg[0]; cnt <= 17'd1; st <= S_BRD; end
               "B": begin ra <= arg[0]; cnt <= (arg[1] == 0) ? 17'd256 : 17'(arg[1]); st <= S_BRD; end
               "W": begin wr <= 1'b1; addr <= arg[0]; wdata <= arg[1]; st <= S_IDLE; end
               "M", "N": begin
                  maddr <= {arg[1], arg[0]};
                  cnt   <= ({arg[3], arg[2]} == 0) ? 17'd65536 : 17'({arg[3], arg[2]});
                  st    <= (cmd == "M") ? S_M_A0 : S_N_DATA;
                  tmo   <= '0;
               end
               default: st <= S_IDLE;
            endcase
         S_SEND:
            if (!tx_busy && !tx_go) begin
               tx_go   <= 1'b1;
               tx_data <= txb;
               st      <= ret;
            end

         // čtení registrů (R, B)
         S_BRD:     begin addr <= ra; st <= S_BRD_CAP; end
         S_BRD_CAP: begin
                       txb <= rdata; ra <= ra + 8'd1; cnt <= cnt - 17'd1;
                       ret <= (cnt == 17'd1) ? S_IDLE : S_BRD;
                       st  <= S_SEND;
                    end

         // čtení paměti (M): adresa, příkaz čtení, čekání na mem_busy, data
         S_M_A0:   begin wr <= 1'b1; addr <= 8'h10; wdata <= maddr[7:0];  st <= S_M_A1; end
         S_M_A1:   begin wr <= 1'b1; addr <= 8'h11; wdata <= maddr[15:8]; st <= S_M_CMD; end
         S_M_CMD:  begin wr <= 1'b1; addr <= 8'h13; wdata <= 8'h01; wcnt <= 3'd4; st <= S_M_WAIT; end
         S_M_WAIT: begin
                      addr <= 8'h00;                         // stav, bit 1 = mem_busy
                      if (wcnt != 0) wcnt <= wcnt - 3'd1;
                      else if (!rdata[1]) st <= S_M_RD;
                   end
         S_M_RD:   begin addr <= 8'h13; st <= S_M_CAP; end
         S_M_CAP:  begin
                      txb <= rdata; maddr <= maddr + 16'd1; cnt <= cnt - 17'd1;
                      ret <= (cnt == 17'd1) ? S_IDLE : S_M_A0;
                      st  <= S_SEND;
                   end

         // zápis paměti (N): bajt z UART, adresa, data, příkaz zápisu, čekání
         S_N_DATA: if (!f_empty) begin nd <= f_out; tmo <= '0; st <= S_N_A0; end
                   else if (tmo == 24'(TMO)) st <= S_IDLE;
                   else tmo <= tmo + 24'd1;
         S_N_A0:   begin wr <= 1'b1; addr <= 8'h10; wdata <= maddr[7:0];  st <= S_N_A1; end
         S_N_A1:   begin wr <= 1'b1; addr <= 8'h11; wdata <= maddr[15:8]; st <= S_N_D; end
         S_N_D:    begin wr <= 1'b1; addr <= 8'h12; wdata <= nd;          st <= S_N_CMD; end
         S_N_CMD:  begin wr <= 1'b1; addr <= 8'h13; wdata <= 8'h02; wcnt <= 3'd4; st <= S_N_WAIT; end
         S_N_WAIT: begin
                      addr <= 8'h00;
                      if (wcnt != 0) wcnt <= wcnt - 3'd1;
                      else if (!rdata[1]) begin
                         maddr <= maddr + 16'd1; cnt <= cnt - 17'd1;
                         if (cnt == 17'd1) begin txb <= 8'h5A; ret <= S_IDLE; st <= S_SEND; end
                         else st <= S_N_DATA;
                      end
                   end
         default: st <= S_IDLE;
      endcase
   end
endmodule
