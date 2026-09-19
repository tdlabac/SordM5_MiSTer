#!/bin/sh
# Test časové značky: simulační náhrada tstamp + TimeMark ze sim appky.
#
#   wsl.exe -- bash rtl/tb/run_tstamp.sh
set -e

cd "$(dirname "$0")"
OBJ=${OBJ:-obj_tstamp}
SIM=../../verilator

rm -rf "$OBJ"
mkdir -p "$OBJ"
verilator -cc --exe --build -O2 -Wno-fatal -Wno-lint --Mdir "$OBJ" -o tb --top-module tb_tstamp \
   -CFLAGS "-I$(pwd)/$SIM/sim/modules -std=c++17" \
   $SIM/rtl/tstamp_dpi.sv tb_tstamp.sv tb_tstamp.cpp $SIM/sim/modules/tstamp_dpi.cpp \
   >"$OBJ/build.log" 2>&1 || { grep -E "Error|error" "$OBJ/build.log" | head -20; exit 1; }

exec "./$OBJ/tb"
