// Test klávesnice a joysticků (rtl/KEYBOARD/keyboard.sv).
//
// Hlavní věc, kterou hlídá: joystick se musí na portech projevit sám od sebe,
// bez jakékoli události z PS/2. Když byl přimícháván uvnitř `if (changed)`,
// pohyb páky se objevil až po stisku klávesy a pak v matici zůstal viset.
//
// Rozložení podle keyboard.vhd (commit "Joypad support"):
//   port 31h  bit0 = klávesa 1 / spoušť JOY0, bit1 = 2 / útok JOY0,
//             bit4 = 5 / spoušť JOY1, bit5 = 6 / útok JOY1
//   port 37h  bit0..3 = levý joystick  vpravo, nahoru, vlevo, dolů
//             bit4..7 = pravý joystick vpravo, nahoru, vlevo, dolů
//
// Bity joysticku z hps_io: 0 = vpravo, 1 = vlevo, 2 = dolů, 3 = nahoru,
//                          4 = spoušť, 5 = útok.
#include "Vtb_keyboard.h"
#include <cstdio>
#include <cstdint>

static Vtb_keyboard* t;
static int fails = 0;
static int ps2_toggle = 0;

static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }

static void check(const char* name, bool ok, const char* fmt = "", ...) {
   char b[200] = "";
   va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
   printf("  %-56s %s %s\n", name, ok ? "OK  " : "CHYBA", b);
   if (!ok) fails++;
}

// Přečte port 30h-37h (ce = výběr klávesnice v sordm5_core).
static uint8_t port_rd(int port) {
   t->addr = port & 7; t->ce = 1;
   t->eval();
   uint8_t v = t->data;
   t->ce = 0; t->eval();
   return v;
}

// Událost z PS/2: bit10 se s každou událostí překlápí, bit9 = stisk.
static void ps2_key(uint8_t code, bool pressed) {
   ps2_toggle ^= 1;
   t->ps2 = (ps2_toggle << 10) | (pressed << 9) | code;
   tick(); tick(); tick();
}

static void joy_set(uint8_t j0, uint8_t j1) {
   t->joy0 = j0; t->joy1 = j1;
   tick();                        // stačí takt, na událost z PS/2 se nečeká
}

int main(int argc, char** argv) {
   Verilated::commandArgs(argc, argv);
   setvbuf(stdout, nullptr, _IONBF, 0);
   t = new Vtb_keyboard;
   t->ps2 = 0; t->joy0 = 0; t->joy1 = 0; t->addr = 0; t->ce = 0;
   tick(); tick();

   printf("=== klávesnice ===\n");
   check("po startu jsou porty prázdné", port_rd(0x1) == 0x00 && port_rd(0x7) == 0x00);

   ps2_key(0x16, true);
   check("stisk klávesy 1 nastaví port 31h bit0", port_rd(0x1) == 0x01, "(%02X)", port_rd(0x1));
   ps2_key(0x16, false);
   check("uvolnění klávesy 1 bit shodí", port_rd(0x1) == 0x00);

   ps2_key(0x1c, true);          // A
   check("klávesa A je na portu 33h bit0", port_rd(0x3) == 0x01);
   ps2_key(0x1c, false);

   check("mimo výběr (ce = 0) je na sběrnici FFh", (t->addr = 1, t->ce = 0, t->eval(), t->data) == 0xFF);

   ps2_key(0x76, true);          // ESC
   check("ESC drží reset", t->rst_key == 1);
   ps2_key(0x76, false);
   check("uvolnění ESC reset pustí", t->rst_key == 0);

   printf("\n=== joystick ===\n");
   // 1. bez jediné události z PS/2 se musí páka projevit hned
   joy_set(0x01, 0x00);          // levý vpravo
   check("levý vpravo bez události z PS/2 (port 37h bit0)", port_rd(0x7) == 0x01,
         "(%02X)", port_rd(0x7));
   joy_set(0x08, 0x00);          // levý nahoru
   check("levý nahoru (bit1)", port_rd(0x7) == 0x02, "(%02X)", port_rd(0x7));
   joy_set(0x02, 0x00);          // levý vlevo
   check("levý vlevo (bit2)", port_rd(0x7) == 0x04, "(%02X)", port_rd(0x7));
   joy_set(0x04, 0x00);          // levý dolů
   check("levý dolů (bit3)", port_rd(0x7) == 0x08, "(%02X)", port_rd(0x7));

   joy_set(0x00, 0x01);
   check("pravý vpravo (bit4)", port_rd(0x7) == 0x10, "(%02X)", port_rd(0x7));
   joy_set(0x00, 0x08);
   check("pravý nahoru (bit5)", port_rd(0x7) == 0x20, "(%02X)", port_rd(0x7));
   joy_set(0x00, 0x02);
   check("pravý vlevo (bit6)", port_rd(0x7) == 0x40, "(%02X)", port_rd(0x7));
   joy_set(0x00, 0x04);
   check("pravý dolů (bit7)", port_rd(0x7) == 0x80, "(%02X)", port_rd(0x7));

   joy_set(0x00, 0x00);
   check("puštěná páka port 37h zase vynuluje", port_rd(0x7) == 0x00);

   // 2. spouště na portu 31h
   joy_set(0x10, 0x00);
   check("spoušť JOY0 = port 31h bit0 (klávesa 1)", port_rd(0x1) == 0x01, "(%02X)", port_rd(0x1));
   joy_set(0x20, 0x00);
   check("útok JOY0 = bit1 (klávesa 2)", port_rd(0x1) == 0x02, "(%02X)", port_rd(0x1));
   joy_set(0x00, 0x10);
   check("spoušť JOY1 = bit4 (klávesa 5)", port_rd(0x1) == 0x10, "(%02X)", port_rd(0x1));
   joy_set(0x00, 0x20);
   check("útok JOY1 = bit5 (klávesa 6)", port_rd(0x1) == 0x20, "(%02X)", port_rd(0x1));

   // 3. klávesa a joystick se nesmí navzájem přebíjet
   joy_set(0x10, 0x00);          // spoušť JOY0 drží
   ps2_key(0x16, true);          // a k tomu stisk klávesy 1
   check("klávesa 1 a spoušť JOY0 zároveň", port_rd(0x1) == 0x01);
   ps2_key(0x16, false);         // klávesa pustí, páka drží dál
   check("uvolnění klávesy 1 nesmí shodit drženou spoušť", port_rd(0x1) == 0x01,
         "(%02X)", port_rd(0x1));
   joy_set(0x00, 0x00);
   check("puštěná spoušť bit shodí", port_rd(0x1) == 0x00);

   // 4. směry se nesmí plést mezi porty
   joy_set(0x0F, 0x0F);
   check("obě páky ve všech směrech = port 37h FFh", port_rd(0x7) == 0xFF, "(%02X)", port_rd(0x7));
   check("směry neovlivní port 31h", port_rd(0x1) == 0x00, "(%02X)", port_rd(0x1));

   printf("\n%s (%d chyb)\n", fails ? "NEPROSLO" : "VSE PROSLO", fails);
   delete t;
   return fails ? 1 : 0;
}
