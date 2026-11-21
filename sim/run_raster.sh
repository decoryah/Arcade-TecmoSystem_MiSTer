#!/bin/bash
# Raster bench (sim/tb_raster.sv + tb_raster.cpp), in WSL: the Video Timing's Original raster (rtl/ts_cen.sv, ts_video.sv) against the
# first release's modules (git tag 20261118, renamed *_old), clock for clock over three frames; then the shape of both rasters, frame by
# frame, across switches between them, for ts_video and the standby raster (ts_standby.sv).
#   sim/run_raster.sh            (builds in $HOME/build_tecmosys_raster)
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
B="${BDIR:-$HOME/build_tecmosys_raster}"; mkdir -p "$B"
git show 20261118:rtl/ts_cen.sv | sed -e 's/module ts_cen /module ts_cen_old /; s/module ts_pixgen /module ts_pixgen_old /; s/    ts_pixgen #/    ts_pixgen_old #/' > "$B/old_cen.sv"
git show 20261118:rtl/ts_video.sv | sed -e 's/module ts_video /module ts_video_old /' > "$B/old_video.sv"
verilator --cc --exe --build -O3 -j 8 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN --top-module tb_raster -Mdir "$B/obj" \
    ../rtl/ts_ram.sv ../rtl/ts_cen.sv ../rtl/ts_tiles.sv ../rtl/ts_sprites.sv ../rtl/ts_video.sv ../rtl/ts_standby.sv \
    "$B/old_cen.sv" "$B/old_video.sv" tb_raster.sv tb_raster.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
"$B/obj/Vtb_raster"
