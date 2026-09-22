#!/bin/sh
# Test klávesnice a joysticků (tb_keyboard.cpp). Z WSL/bash:
#
#   wsl.exe -- bash rtl/KEYBOARD/tb/run_tb.sh
set -e

cd "$(dirname "$0")"
R=..
OBJ=${OBJ:-obj_dir}

rm -rf "$OBJ"
mkdir -p "$OBJ"
verilator -cc --exe --build -O2 -Wno-fatal -Wno-lint --Mdir "$OBJ" -o tb --top-module tb_keyboard \
   $R/keyboard.sv tb_keyboard.sv tb_keyboard.cpp >"$OBJ/build.log" 2>&1 || { grep -E "Error|error" "$OBJ/build.log" | head -20; exit 1; }

cd "$OBJ"
exec ./tb
