# Vendored modules

Third-party HDL cores copied into the tree -- no submodules, so the build is self-contained and reproducible. Each keeps its own licence
alongside (or in its file headers).

| module | upstream | via | licence |
|---|---|---|---|
| cpu-fx68k (+ `../microrom.mem`, `../nanorom.mem`) | https://github.com/ijor/fx68k (Jorge Cwik) | copied unchanged from the owner's `supduck-mister/mister/modules/cpu-fx68k` (the copy that builds with Quartus 17 and runs in Verilator with `--no-assert-case -Wno-BLKANDNBLK`) on 2026-11-17 | GPL-3.0 |
| cpu-tv80 | https://github.com/hoglet67/tv80 (Guy Hutchison's TV80) | `tv80_alu.v`, `tv80_core.v`, `tv80_mcode.v`, `tv80_reg.v`, `tv80s_cen.v` (the clock-enable wrapper of plasticbugs/punchout), copied unchanged from `supduck-mister/mister/modules/cpu-tv80` on 2026-11-17 (`tv80s.v` kept for reference, not built) | MIT |
| jt6295 (OKI M6295) | https://github.com/jotego/jt6295 (Jose Tejada) | the 8 files `hdl/jt6295*.v` (INTERPOL=0), copied unchanged from `supduck-mister/mister/modules/jt6295` on 2026-11-17 | GPL-3.0 |
| crt_adjust (CRT Adjust: H-Size, H-Position, V-Shift) | https://github.com/rmonic79/MiSTer-CRT-Adjust (Umberto Parisi, rmonic79) | `rtl/crt_adjust.sv` at upstream commit c682de9, copied unchanged from `supduck-mister/mister/modules/crt_adjust` (the Metro core's copy, with its two changes marked `METRO`) on 2026-11-17 | GPL-3.0-or-later |
| opl3 (YMF262) | https://github.com/gtaylormb/opl3_fpga (Greg Taylor; LGPL-3.0-or-later, the Java / C++ OPL3 emulators by Robson Cozendey and Steffen Ohrendorf before it) | MiSTer's ao486 core's copy, https://github.com/MiSTer-devel/ao486_MiSTer `rtl/soc/sound/opl3/` (master, last change 2025-02-24 "OPL3: fix envelope RELEASE state on reset", fetched 2026-11-17; pristine copy in `../../ref/ao486_opl3/`) + its `rtl/common/synchronizer.sv`; **changes marked `TECMOSYS`**: `opl3_pkg.sv` (24 MHz clock, the exact 14.31818 MHz / 288 sample enable as a 35 / 16896 fraction, timer ticks of 4 / 16 samples), `clk_div.sv` (the fractional enable), `timer.sv` / `timers.sv` (count samples, not seconds: the chip's 80.4 / 321.8 us; **register 04 with bit 7 set is a one-shot flag reset that leaves the other bits alone**, as the chip and MAME's ymfm -- ao486's copy stored the low bits and held the reset, so the games' interrupt acknowledge c3 / a3 masked timer 1 and stopped all later timer interrupts: the sound driver stalled after its first one), `host_if.sv` (no `trick_sw_detection`: ao486's aid for DOS programs; `trick_sw_detection.sv` removed), `opl3.qip` (+ synchronizer, - trick_sw_detection) | LGPL-3.0-or-later (compatible with the core's GPL-3.0) |

The fx68k microcode ROM files are read with `$readmemb("microrom.mem")` / `"nanorom.mem"`, i.e. relative to the directory the simulator or
Quartus runs in: `sim/run.sh` copies them next to the binary, Quartus finds them in the project directory.

To update one: re-copy from upstream at the new commit, re-apply the marked changes, and record it here.
