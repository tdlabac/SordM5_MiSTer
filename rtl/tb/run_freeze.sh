#!/bin/sh
# Test zmrazení celého počítače debuggerem (tb_freeze.cpp). Z WSL/bash:
#
#   wsl.exe -- bash rtl/tb/run_freeze.sh
#
# Proměnné: FZ_CLOCKS, FZ_SEED, FZ_NOSTOP (viz tb_freeze.cpp),
#           ROM, CART (výchozí verilator/rom/boot.rom a basic-i.bin), CLOCK
set -e

cd "$(dirname "$0")"
OBJ=${OBJ:-obj_freeze}
R=..
ROM=${ROM:-../../verilator/rom/boot.rom}
CART=${CART:-../../verilator/rom/basic-i.bin}
CLOCK=${CLOCK:-$R/clock.sv}   # jiný clock.sv (samotest: zmrazení, které něco vynechá, musí selhat)

rm -rf "$OBJ"
mkdir -p "$OBJ"
od -An -v -tx1 -w1 "$ROM"  | tr -d ' ' > "$OBJ/rom.hex"
od -An -v -tx1 -w1 "$CART" | tr -d ' ' > "$OBJ/cart.hex"

verilator -cc --exe --build -O3 -Wno-fatal -Wno-lint -Wno-MULTIDRIVEN -Wno-PINMISSING \
   --x-assign fast --x-initial fast --Mdir "$OBJ" -o tb --top-module tb_freeze \
   -I$R/VDP \
   $R/sordm5_pkg.sv $R/CPU/tv80_dbg_pkg.sv \
   $R/CPU/tv80_alu.sv $R/CPU/tv80.sv $R/CPU/tv80_mcode.sv $R/CPU/tv80_reg.sv $R/CPU/tv80a.sv $R/CPU/tv80_dbg.sv \
   $R/VDP/vdp18_pack-p.sv $R/VDP/vdp18_col_pack-p.sv $R/VDP/vdp18_core.sv $R/VDP/vdp18_clk_gen.sv \
   $R/VDP/vdp18_hor_vert.sv $R/VDP/vdp18_ctrl.sv $R/VDP/vdp18_cpuio.sv $R/VDP/vdp18_addr_mux.sv \
   $R/VDP/vdp18_pattern.sv $R/VDP/vdp18_sprite.sv $R/VDP/vdp18_col_mux.sv \
   $R/CTC/ctc_channel.sv "${CTC:-$R/CTC/ctc.sv}" \
   $R/SOUND/jt89/hdl/jt89.v $R/SOUND/jt89/hdl/jt89_tone.v $R/SOUND/jt89/hdl/jt89_noise.v \
   $R/SOUND/jt89/hdl/jt89_vol.v $R/SOUND/jt89/hdl/jt89_mixer.v \
   $R/sordm5_core.sv $R/rom_ioctl.sv "$CLOCK" $R/GA015/ga015.sv $R/KEYBOARD/keyboard.sv $R/EXT/ext_bus.sv $R/EXT/carts/cart_none.sv $R/EXT/carts/cart_em32.sv $R/EXT/carts/cart_em64.sv $R/EXT/carts/cart_brno.sv $R/tstamp.sv \
   tb_mem.sv tb_freeze.sv tb_freeze.cpp >"$OBJ/build.log" 2>&1 || { grep -E "Error|error" "$OBJ/build.log" | head -20; exit 1; }

cd "$OBJ"
exec ./tb
