#!/bin/sh
# End-to-end test debuggeru: třída Z80Dbg ze sim appky přes DPI
# (verilator/rtl/dbg_link_dpi.sv) a registrový prostor až do tv80_dbg.
#
#   wsl.exe -- bash rtl/CPU/tb/run_link.sh
set -e

cd "$(dirname "$0")"
OBJ=${OBJ:-obj_link}
SIM=../../../verilator

rm -rf "$OBJ"
mkdir -p "$OBJ"
verilator -cc --exe --build -O2 -Wno-fatal -Wno-lint -Wno-MULTIDRIVEN --Mdir "$OBJ" -o tb --top-module tb_link \
   -CFLAGS "-I$(pwd)/$SIM/sim/modules -std=c++17" \
   ../tv80_dbg_pkg.sv ../tv80_alu.sv ../tv80.sv ../tv80_mcode.sv ../tv80_reg.sv ../tv80a.sv ../tv80_dbg.sv \
   ../tv80_dbg_regs.sv ../../clock.sv $SIM/rtl/dbg_link_dpi.sv \
   tb_link.sv tb_link.cpp $SIM/sim/modules/Z80dbg.cpp $SIM/sim/modules/dbg_link_dpi.cpp \
   >"$OBJ/build.log" 2>&1 || { grep -E "Error|error" "$OBJ/build.log" | head -20; exit 1; }

exec "./$OBJ/tb"
