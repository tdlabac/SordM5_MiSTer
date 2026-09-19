#!/bin/sh
# Postaví a spustí testbench TV80a. Pouští se z WSL/bash:
#
#   wsl.exe -- bash rtl/CPU/tb/run_tb.sh
#
# Proměnnými TV80A a TV80CORE lze testbench pustit proti jiné verzi
# tv80a.sv / tv80.sv (např. proti původní bez opravy potvrzení přerušení).
# TB_TRACE=1 vypíše sběrnici kolem prvního potvrzení, TB_DUMP=1 časovou osu
# načítání opkódů (pro porovnání dvou verzí).
set -e

cd "$(dirname "$0")"
TV80A=${TV80A:-../tv80a.sv}
TV80CORE=${TV80CORE:-../tv80.sv}
OBJ=${OBJ:-obj_dir}

rm -rf "$OBJ"
mkdir -p "$OBJ"
verilator -cc --exe --build -O2 -Wno-fatal -Wno-lint --Mdir "$OBJ" -o tb --top-module tb_tv80 \
   ../tv80_alu.sv "$TV80CORE" ../tv80_mcode.sv ../tv80_reg.sv "$TV80A" \
   tb_tv80.sv tb_tv80.cpp >"$OBJ/build.log" 2>&1 || { grep -E "Error|error" "$OBJ/build.log" | head -20; exit 1; }

exec "./$OBJ/tb"
