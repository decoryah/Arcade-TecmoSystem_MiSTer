#!/bin/bash
# Bench of the MiSTer top module (TecmoSys.sv, `emu`) with the framework's pll / hps_io / arcade_video replaced by emu_stubs.sv, in WSL:
#   sim/run_emu.sh +STREAM=<python tools/ts_rom.py <set> --stream f> +VERIFY=<... --sdram f> [+FAST=1] [+FRAMES=n +SNAPS=a,b +SNAPPFX=p] [+GAP=n]
# (after the owner's jchan-mister sim/run_emu.sh).  Builds once in $HOME/build_tecmosys_emu (NOBUILD=1 reuses it).  The 68000 runs on a gated
# clock (SIM_GATE = 1, patched into a copy of ts_core.sv: bit-identical results, faster).
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
B="${BDIR:-$HOME/build_tecmosys_emu}"; mkdir -p "$B"
. ./files.sh
if [ -z "$NOBUILD" ]; then
sed 's/parameter SIM_GATE    = 0/parameter SIM_GATE    = 1/' ../rtl/ts_core.sv > "$B/ts_core_sg.sv"
RTL_SG=$(echo $RTL_FILES | sed "s#../rtl/ts_core.sv#$B/ts_core_sg.sv#")
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" -MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-IMPLICIT -Wno-GENUNNAMED -Wno-ENUMVALUE -Wno-MULTITOP ${VFLAGS} -I../rtl -I.. \
    --top-module tb_emu_top -Mdir "$B/obj" \
    $RTL_SG ../rtl/ts_standby.sv $MOD_FILES ../modules/crt_adjust/crt_adjust.sv ../sys/video_freak.sv ../sys/math.sv ../TecmoSys.sv emu_stubs.sv \
    ts_sdram_model.sv tb_emu_top.sv tb_emu.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
cp ../microrom.mem ../nanorom.mem "$B/"
cd "$B"
./obj/Vtb_emu_top "$@"
