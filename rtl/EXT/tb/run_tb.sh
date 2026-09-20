#!/bin/sh
# Test cartridge na rozšiřující sběrnici (tb_cart.cpp). Z WSL/bash:
#
#   wsl.exe -- bash rtl/EXT/tb/run_tb.sh
set -e

cd "$(dirname "$0")"
R=../..
OBJ=${OBJ:-obj_dir}

rm -rf "$OBJ"
mkdir -p "$OBJ"
: > "$OBJ/cart.hex"   # CART_RAM se plni pres ioctl, ne ze souboru
verilator -cc --exe --build -O2 -Wno-fatal -Wno-lint --Mdir "$OBJ" -o tb --top-module tb_cart \
   $R/sordm5_pkg.sv $R/EXT/ext_bus.sv \
   $R/EXT/carts/cart_none.sv $R/EXT/carts/cart_em32.sv \
   $R/EXT/carts/cart_em64.sv $R/EXT/carts/cart_brno.sv \
   $R/tb/tb_mem.sv tb_cart.sv tb_cart.cpp >"$OBJ/build.log" 2>&1 || { grep -E "Error|error" "$OBJ/build.log" | head -20; exit 1; }

cd "$OBJ"
exec ./tb
