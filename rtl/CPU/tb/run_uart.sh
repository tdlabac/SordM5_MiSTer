#!/bin/sh
# Test přenosu debuggeru přes UART a nástrojů tools/z80dbg proti modelu jádra.
#
#   wsl.exe -- bash rtl/CPU/tb/run_uart.sh           # model + Python test
#   UART_ONLY=1 bash rtl/CPU/tb/run_uart.sh          # jen model (pro ruční
#       zkoušení: python3 -m z80dbg.cli --link 127.0.0.1:5557)
set -e

cd "$(dirname "$0")"
OBJ=${OBJ:-obj_uart}
export UART_PORT=${UART_PORT:-5557}

rm -rf "$OBJ"
mkdir -p "$OBJ"
verilator -cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-MULTIDRIVEN --Mdir "$OBJ" -o tb --top-module tb_uart \
   ../tv80_dbg_pkg.sv ../tv80_alu.sv ../tv80.sv ../tv80_mcode.sv ../tv80_reg.sv ../tv80a.sv ../tv80_dbg.sv \
   ../tv80_dbg_regs.sv ../../clock.sv ../../dbg_link.sv ../../tstamp.sv \
   tb_uart.sv tb_uart.cpp >"$OBJ/build.log" 2>&1 || { grep -E "Error|error" "$OBJ/build.log" | head -20; exit 1; }

if [ -n "$UART_ONLY" ]; then exec "./$OBJ/tb"; fi

"./$OBJ/tb" &
MODEL=$!
sleep 0.5
RC=0
python3 ../../../tools/z80dbg/tests/test_model.py || RC=$?
wait $MODEL || true
exit $RC
