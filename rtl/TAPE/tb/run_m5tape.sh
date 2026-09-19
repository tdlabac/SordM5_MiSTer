#!/bin/sh
# Nahrání programu z kazety skutečným monitorem M5 (tb_m5tape.cpp). Z WSL/bash:
#
#   wsl.exe -- bash rtl/TAPE/tb/run_m5tape.sh
#
# Proměnné: TB_CLOCKS, TB_BUSY (viz tb_m5tape.cpp), ROM (monitor)
set -e

cd "$(dirname "$0")"
OBJ=obj_m5tape
R=../..
ROM=${ROM:-../../../verilator/rom/SORDINT.ROM}

rm -rf "$OBJ"
mkdir -p "$OBJ"
od -An -v -tx1 -w1 "$ROM" | tr -d ' ' > "$OBJ/rom.hex"
# bez cartridge: 2000h-3FFFh čte FFh, monitor pak čte kazetu
awk 'BEGIN { for (i = 0; i < 8192; i++) print "ff" }' > "$OBJ/cart.hex"

verilator -cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-MULTIDRIVEN -Wno-PINMISSING \
   --x-assign fast --x-initial fast --Mdir "$OBJ" -o tb --top-module tb_m5tape \
   -I$R/VDP \
   $R/sordm5_pkg.sv $R/CPU/tv80_dbg_pkg.sv \
   $R/CPU/tv80_alu.sv $R/CPU/tv80.sv $R/CPU/tv80_mcode.sv $R/CPU/tv80_reg.sv $R/CPU/tv80a.sv $R/CPU/tv80_dbg.sv \
   $R/VDP/vdp18_pack-p.sv $R/VDP/vdp18_col_pack-p.sv $R/VDP/vdp18_core.sv $R/VDP/vdp18_clk_gen.sv \
   $R/VDP/vdp18_hor_vert.sv $R/VDP/vdp18_ctrl.sv $R/VDP/vdp18_cpuio.sv $R/VDP/vdp18_addr_mux.sv \
   $R/VDP/vdp18_pattern.sv $R/VDP/vdp18_sprite.sv $R/VDP/vdp18_col_mux.sv \
   $R/CTC/ctc_channel.sv $R/CTC/ctc.sv \
   $R/SOUND/jt89/hdl/jt89.v $R/SOUND/jt89/hdl/jt89_tone.v $R/SOUND/jt89/hdl/jt89_noise.v \
   $R/SOUND/jt89/hdl/jt89_vol.v $R/SOUND/jt89/hdl/jt89_mixer.v \
   $R/sordm5_core.sv $R/rom_ioctl.sv $R/clock.sv $R/GA015/ga015.sv $R/KEYBOARD/keyboard.sv $R/EXT/ext_bus.sv $R/tstamp.sv \
   $R/ddram.sv ../cas_player.sv \
   ../../tb/tb_mem.sv tb_m5tape.sv tb_m5tape.cpp >"$OBJ/build.log" 2>&1 || { grep -E "Error|error" "$OBJ/build.log" | head -20; exit 1; }

cd "$OBJ"
exec ./tb
