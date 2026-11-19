#!/bin/bash
# Whole-machine bench (sim/tb_top.sv + sim/tb_main.cpp: ts_core + ts_mem + the SDRAM model), in WSL:
#   sim/run.sh +IMAGE=<set.sdram> +HDR=<set.hdr> +FRAMES=n [+SNAPS=a,b|all +SNAPPFX=p] [+PROGRESS=n] [+WAV=f] [+INPUTS=f] [+P1=hex +P2=hex]
# The images: python tools/ts_rom.py <set> --sdram work/<set>.sdram --stream ... (the header is the stream's first 256 bytes: --hdr).
# Builds once in $HOME/build_tecmosys (BDIR= another; NOBUILD=1 reuses it).  The 68000 on a gated clock (SIM_GATE=1, rtl/ts_m68k.sv).
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
B="${BDIR:-$HOME/build_tecmosys}"; mkdir -p "$B"
. ./files.sh
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" -MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-IMPLICIT -Wno-CASEX -Wno-COMBDLY -Wno-SELRANGE -Wno-ASCRANGE -Wno-GENUNNAMED -Wno-ENUMVALUE \
    -GSIM_GATE=${SIM_GATE:-1} ${VFLAGS} --top-module tb_top -Mdir "$B/obj" \
    $RTL_FILES $MOD_FILES ts_sdram_model.sv tb_top.sv tb_main.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
cp ../microrom.mem ../nanorom.mem "$B/"
cd "$B"
./obj/Vtb_top "$@"
