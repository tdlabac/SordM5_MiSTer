#!/bin/sh
# Test REG/DIRSet TV80a (tb_regs.cpp). Pouští se z WSL/bash:
#
#   wsl.exe -- bash rtl/CPU/tb/run_regs.sh
set -e

cd "$(dirname "$0")"
OBJ=${OBJ:-obj_regs}

rm -rf "$OBJ"
mkdir -p "$OBJ"
verilator -cc --exe --build -O2 -Wno-fatal -Wno-lint -Wno-MULTIDRIVEN --Mdir "$OBJ" -o tb --top-module tb_regs \
   ../tv80_alu.sv ../tv80.sv ../tv80_mcode.sv ../tv80_reg.sv ../tv80a.sv \
   tb_regs.sv tb_regs.cpp >"$OBJ/build.log" 2>&1 || { grep -E "Error|error" "$OBJ/build.log" | head -20; exit 1; }

exec "./$OBJ/tb"
