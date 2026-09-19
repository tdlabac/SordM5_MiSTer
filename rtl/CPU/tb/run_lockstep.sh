#!/bin/sh
# Lockstep test: upravený TV80 (DUT) proti zmrazené kopii ref/ (viz make_ref.sh).
#
#   wsl.exe -- bash rtl/CPU/tb/run_lockstep.sh
#
# Proměnné:
#   DUT_DIR   adresář se zdrojáky testovaného TV80 (výchozí ..)
#   DUT_DBG=1 testovat obálku tv80_dbg místo holého TV80a
#   LS_SEEDS, LS_CLOCKS, LS_SEED0  viz tb_lockstep.cpp
set -e

cd "$(dirname "$0")"
DUT_DIR=${DUT_DIR:-..}
OBJ=${OBJ:-obj_lockstep}
DEFS=""
EXTRA=""
if [ -n "$DUT_DBG" ]; then
   DEFS="+define+DUT_DBG"
   EXTRA="$DUT_DIR/tv80_dbg.sv"
fi

rm -rf "$OBJ"
mkdir -p "$OBJ"
verilator -cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-MULTIDRIVEN --Mdir "$OBJ" -o tb \
   --top-module tb_lockstep $DEFS \
   "$DUT_DIR/tv80_alu.sv" "$DUT_DIR/tv80.sv" "$DUT_DIR/tv80_mcode.sv" "$DUT_DIR/tv80_reg.sv" "$DUT_DIR/tv80a.sv" $EXTRA \
   ref/ref_tv80_alu.sv ref/ref_tv80.sv ref/ref_tv80_mcode.sv ref/ref_tv80_reg.sv ref/ref_tv80a.sv \
   tb_lockstep.sv tb_lockstep.cpp >"$OBJ/build.log" 2>&1 || { grep -E "Error|error" "$OBJ/build.log" | head -20; exit 1; }

exec "./$OBJ/tb"
