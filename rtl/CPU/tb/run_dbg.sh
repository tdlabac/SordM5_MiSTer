#!/bin/sh
# Test obálky tv80_dbg (tb_dbg.cpp): breakpointy, krok, přístup do paměti.
#
#   wsl.exe -- bash rtl/CPU/tb/run_dbg.sh
set -e

cd "$(dirname "$0")"
OBJ=${OBJ:-obj_dbg}

rm -rf "$OBJ"
mkdir -p "$OBJ"
verilator -cc --exe --build -O2 -Wno-fatal -Wno-lint -Wno-MULTIDRIVEN --Mdir "$OBJ" -o tb --top-module tb_dbg \
   ../tv80_dbg_pkg.sv ../tv80_alu.sv ../tv80.sv ../tv80_mcode.sv ../tv80_reg.sv ../tv80a.sv ../tv80_dbg.sv \
   ../../clock.sv tb_dbg.sv tb_dbg.cpp >"$OBJ/build.log" 2>&1 || { grep -E "Error|error" "$OBJ/build.log" | head -20; exit 1; }

exec "./$OBJ/tb"
