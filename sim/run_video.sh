#!/bin/bash
# Frozen-state video bench (tb_video.sv + tb_video.cpp: ts_video + ts_mem + the SDRAM model, MAME's state preloaded), in WSL:
#   sim/run_video.sh +IMAGE=<set.sdram> +HDR=<set.hdr> +STATE=<dir/fNNNNN> +SPRSTATE=<dir/fNNNNN-1> +MAMERGB=<dir/fNNNNN.rgb> [+OUT=f.ppm]
# Builds once in $HOME/build_tecmosys_video (NOBUILD=1 reuses it).
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
B="${BDIR:-$HOME/build_tecmosys_video}"; mkdir -p "$B"
. ./files.sh
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-IMPLICIT -Wno-GENUNNAMED -Wno-ENUMVALUE ${VFLAGS} --top-module tb_video -Mdir "$B/obj" \
    ../rtl/ts_ram.sv ../rtl/ts_cen.sv ../rtl/ts_tiles.sv ../rtl/ts_sprites.sv ../rtl/ts_video.sv ../rtl/ts_sdram.sv ../rtl/ts_mem.sv \
    ts_sdram_model.sv tb_video.sv tb_video.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
cd "$B"
./obj/Vtb_video "$@"
