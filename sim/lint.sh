#!/bin/bash
# Verilator lint of the core (ts_core and below, or the module given), in WSL:  sim/lint.sh [top-module]
# The same warning set as the benches (sim/run.sh); prints the warnings and errors that are left.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
TOP="${1:-ts_core}"
. ./files.sh
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-UNUSEDPARAM -Wno-IMPLICIT -Wno-CASEX -Wno-COMBDLY -Wno-SELRANGE -Wno-ASCRANGE -Wno-GENUNNAMED -Wno-ENUMVALUE \
    $VFLAGS --top-module "$TOP" $RTL_FILES $MOD_FILES 2>&1 | grep -v -E "^\s*:|^\s*\||^\s*$|Exiting due to" | grep -E "%(Warning|Error)" | \
    grep -v -E "modules/(cpu-fx68k|cpu-tv80|jt6295|opl3)/" || true
