#!/bin/sh
# Postavi a spusti testbench CTC. Pousti se z WSL/bash, ne z PowerShellu:
#
#   wsl.exe -- bash rtl/CTC/tb/run_tb.sh
#
# Hlida veci, ktere se opravovaly proti datasheetu Z8430 — podrobnosti
# v TODO.md, sekce "CTC proti datasheetu Z8430". Kdyz se na CTC sahne,
# tohle musi projit.
set -e

cd "$(dirname "$0")"

verilator -cc --exe --build -O2 -o tb --top-module ctc \
   ../ctc.sv ../ctc_channel.sv tb_ctc.cpp

exec ./obj_dir/tb
