#!/bin/sh
# Test přehrávače kazety (cas_player + rtl/ddram.sv + model DDR3).
#
#   wsl.exe -- bash rtl/TAPE/tb/run_tb.sh          # zkrácený tik (rychlé), scénáře 1-6
#   TB_REAL=1 bash rtl/TAPE/tb/run_tb.sh           # skutečný tik 874, kontrola časů
#   TB_BUSY=0 ... / TB_BUSY=100 ...                # DDRAM_BUSY v promile
set -e

cd "$(dirname "$0")"
if [ -n "$TB_REAL" ]; then TICK=874; OBJ=obj_real; else TICK=${TB_TICK:-8}; OBJ=obj; fi
export TB_TICK=$TICK

rm -rf "$OBJ"
mkdir -p "$OBJ"
verilator -cc --exe --build -O2 -Wno-fatal -Wno-lint --Mdir "$OBJ" -o tb --top-module tb_cas \
   -GTICK_CE=$TICK \
   ../../sordm5_pkg.sv ../../ddram.sv ../cas_player.sv tb_cas.sv tb_cas.cpp \
   >"$OBJ/build.log" 2>&1 || { grep -E "Error|error" "$OBJ/build.log" | head -20; exit 1; }

exec "./$OBJ/tb"
