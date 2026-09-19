// Model jádra s debuggerem na UART, vystavený na TCP (tb_uart.sv).
//
// Program je stejný jako v tb_dbg.cpp / tb_link.cpp. Harness:
//   - poslouchá na TCP portu (UART_PORT, výchozí 5557),
//   - bajty z TCP posílá do jádra po bitech na uart_rxd (8N1),
//   - bity z uart_txd skládá do bajtů a posílá do TCP,
//   - skončí, když se klient odpojí (nebo po UART_MAXCLK taktech).
// Tak se proti modelu dají pustit nástroje z tools/z80dbg (run_uart.sh).
#include "Vtb_uart.h"
#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

static Vtb_uart* t;
static const int DIV = 32;                       // taktů na bit (tb_uart.sv)

static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }

static uint8_t image[65536];
static void build() {
   uint16_t o = 0;
   auto db = [&](std::initializer_list<int> b) { for (int x : b) image[o++] = (uint8_t)x; };
   o = 0x0000; db({0xC3, 0x00, 0x01});
   o = 0x0038; db({0xFB, 0xC9});
   o = 0x0100;
   db({0x31, 0x00, 0xF0}); db({0xED, 0x56}); db({0xFB}); db({0x0E, 0x00});   // 0100 START
   db({0x21, 0x00, 0x80});                                                    // 0108 LOOP
   db({0x3E, 0x11}); db({0x77}); db({0x3C}); db({0x77}); db({0x3C}); db({0x77}); // 010B..0111
   db({0x46});                                                                // 0112 R1
   db({0xD3, 0x40}); db({0xDB, 0x41}); db({0x32, 0x01, 0x80});               // 0113 O1, 0115 I1, 0117 W4
   db({0x3A, 0x00, 0x90}); db({0xD3, 0x42}); db({0x0C});                      // 011A R2, 011D O2, 011F
   db({0xC3, 0x08, 0x01});                                                    // 0120 JP LOOP
}

int main(int argc, char** argv) {
   Verilated::commandArgs(argc, argv);
   t = new Vtb_uart;
   build();
   const int port = getenv("UART_PORT") ? atoi(getenv("UART_PORT")) : 5557;
   const long maxclk = getenv("UART_MAXCLK") ? atol(getenv("UART_MAXCLK")) : 4000000000L;

   int srv = socket(AF_INET, SOCK_STREAM, 0);
   int one = 1;
   setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
   sockaddr_in sa{}; sa.sin_family = AF_INET; sa.sin_port = htons(port); sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
   if (bind(srv, (sockaddr*)&sa, sizeof sa) || listen(srv, 1)) { perror("bind"); return 2; }
   fprintf(stderr, "model: čekám na tcp 127.0.0.1:%d\n", port);

   t->clk = 0; t->eval();
   t->reset = 1; t->int_n = 1; t->io_val = 0x77; t->uart_rxd = 1;
   for (int a = 0; a < 65536; a++) { t->load_we = 1; t->load_a = a; t->load_d = image[a]; tick(); }
   t->load_we = 0;
   for (int i = 0; i < 20; i++) tick();
   t->reset = 0;

   int c = accept(srv, nullptr, nullptr);
   setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
   fcntl(c, F_SETFL, O_NONBLOCK);
   fprintf(stderr, "model: klient připojen\n");

   std::deque<uint8_t> to_core;
   std::string to_host;
   // vysílač do jádra
   int tx_bit = -1, tx_cnt = 0; uint16_t tx_sh = 0;
   // přijímač z jádra
   int rx_bit = -1, rx_cnt = 0; uint8_t rx_sh = 0; int prev_txd = 1;
   long rx_bytes = 0, tx_bytes = 0;

   for (long clk = 0; clk < maxclk; clk++) {
      if ((clk & 255) == 0) {
         uint8_t buf[4096];
         ssize_t n = recv(c, buf, sizeof buf, 0);
         if (n == 0) break;                                   // klient skončil
         if (n > 0) to_core.insert(to_core.end(), buf, buf + n);
         if (!to_host.empty()) {
            ssize_t w = send(c, to_host.data(), to_host.size(), MSG_NOSIGNAL);
            if (w > 0) to_host.erase(0, w);
         }
      }
      // host -> jádro
      if (tx_bit < 0 && !to_core.empty()) {
         tx_sh = (uint16_t)(0x200 | (to_core.front() << 1)); to_core.pop_front();
         tx_bit = 0; tx_cnt = DIV; tx_bytes++;
      }
      if (tx_bit >= 0) {
         t->uart_rxd = (tx_sh >> tx_bit) & 1;
         if (--tx_cnt == 0) { tx_cnt = DIV; if (++tx_bit == 10) tx_bit = -1; }
      } else t->uart_rxd = 1;

      tick();

      // jádro -> host
      int txd = t->uart_txd;
      if (rx_bit < 0) {
         if (prev_txd && !txd) { rx_bit = 0; rx_cnt = DIV / 2; }
      } else if (--rx_cnt == 0) {
         rx_cnt = DIV;
         if (rx_bit >= 1 && rx_bit <= 8) rx_sh = (uint8_t)((rx_sh >> 1) | (txd ? 0x80 : 0));
         if (rx_bit == 9) { if (txd) { to_host.push_back((char)rx_sh); rx_bytes++; } rx_bit = -1; }
         else rx_bit++;
      }
      prev_txd = txd;
   }
   fprintf(stderr, "model: konec (do jádra %ld B, z jádra %ld B)\n", tx_bytes, rx_bytes);
   close(c); close(srv);
   delete t;
   return 0;
}
