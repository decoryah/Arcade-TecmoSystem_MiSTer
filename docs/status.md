# Status

## In short (2026-11-18)

The whole core is written: MiSTer top, 68000 board, video (tilemaps, zooming sprites, mixer), sound board (Z80, YMF262, YMZ280B, OKI),
memory system, MRAs, tools and benches.  Verified so far:

| What | How | Result |
|---|---|---|
| MRA stream | `tools/make_mra.py --check`: every MRA assembled by `tools/mra_build.py` from the merged ROMs vs `tools/ts_rom.py`'s stream | 5 / 5 sets byte-identical, every CRC found |
| Graphics formats | `tools/check_gfx.py`: the SDRAM image read as the RTL reads it vs MAME's own `gfx_layout` decode of the ROMs | 0 / 100,000 random sprite pixels and 0 / 40,000 tile pixels differ, both games |
| Reference renderer | `tools/ts_ref.py` (tecmosys_v.cpp transcribed) vs MAME's pixels | 11 / 11 deroon and 10 / 10 tkdensho attract frames pixel-identical |
| Video RTL (frozen states) | `tools/bench_video.py`: `ts_video` + `ts_mem` + SDRAM model with MAME's states preloaded vs MAME's pixels | 8 / 8 deroon and 9 / 9 tkdensho attract frames and 5 / 5 tkdensho fight frames (`capture.py --play`, up to 13 zoomed sprites), and the README's 4 game pictures (2 + 2, "Build") pixel-identical; lines take <= 1,460 of 6,144 clocks |
| Video RTL (stress) | `tools/stress.py`: zoom 0x80-0x300, flips, off-edge positions, priorities, blend flags on both palettes, tilemap scroll and flip, sprite layer flip, vs the core's model (MAME + the flip fix) | 8 / 8 frames pixel-identical |
| Screen flip (MAME flaw 1, fixed) | `tools/flip_study.py` (model) and the frozen-state bench on two MAME runs, normal and screen-inverted | inverted frames = MAME's normal ones turned 180 degrees, 4 / 4 (model and RTL) |
| Whole machine | `sim/run.sh`: both CPUs from reset through the SDRAM controller and model, blank 93C46, vs MAME's same frames | boots as MAME (watchdog reset, EEPROM initialisation); every checked picture pixel-identical at the same frame number up to tkdensho's attract (frame 1200: its first sprite scene) and deroon's frame 901; deroon one frame behind at 950 (a 20 us race of the YMF262's timer start against MAME's, not wait states); no late line, no SDRAM timing violation; see "Whole machine" below |
| Sound | the Z80's writes to the three chips, MAME vs RTL (`tools/cmp_sndlog.py`); each chip's gain fitted to MAME's recording (`tools/fit_mix.py`); the output against MAME's (`tools/cmp_audio.py`) | 2,689 writes in MAME's order (found and fixed the YMF262's timer-acknowledge bug); first sound within 20 ms of MAME's; the YMF262 was at half MAME's scale (fixed): deroon's 15 s of attract music now **+0.1 dB from MAME's level, envelope correlation 0.992**; then (20261118c) back to the chip's scale, the driver's balance before MAME's 0.225 bug (MAME flaw 11); the OKI's ADPCM bytes all in time (they were not: crackle), checked against MAME's decode |
| MiSTer top + loader | `sim/run_emu.sh`: the real `TecmoSys.sv` with framework stand-ins, the MRA stream played as the HPS does, `+FAST=1` as Main_MiSTer's DDR3 fast load | the SDRAM byte-exact against `ts_rom.py`'s image: deroon 20,971,520 bytes streamed and fast-loaded, tkdensho 41,943,040 bytes fast-loaded; the header decoded |
| Build | `quartus_sh --flow compile TecmoSys` | fits (49 % ALMs, 59 % RAM blocks); timing met in all four models; see "Build" below |

Not yet: the one-frame drift of deroon's attract (below), long play with inputs.  On hardware: the owner has tested every test build
from 20261117 to 20261118c (released as 20261118); both games run, and 20261118c's sound is "much better", the coin sound clean (below, "Controls and the
hardware tests").  MAME's flaws: the screen flip is fixed; the rest are checked or wait for evidence
from a real board (table below).

## Design decisions (and what is assumed)

- **Raster**: 7 MHz dots (28 MHz / 4), 448 x 272: a 15.625 kHz line and 57.4449 Hz, which is MAME's 57.4458 Hz to 0.002 % (MAME's own
  raster is a placeholder 512 x 512).  The board's real totals and sync positions are not documented; hsync dots 344-375, vsync lines
  248-250 are this core's choice.  The vertical blank (lines 240-271) is 32 lines here against MAME's 272 of 512: 880000 bit 0 (1 outside
  the blank) and the time the 68000 has between the interrupt and the picture differ from MAME accordingly.
- **Sprites**: drawn line by line from a copy of the selected list taken at the start of the vertical blank, one frame behind the tilemaps as
  MAME draws them.  MAME's source-driven drawing is reproduced exactly (including the gaps of zoom > 1).  The cost of a line is one scan
  of the 1024 entries (1 a clock) plus the pixels; a strongly shrunk sprite costs all its source rows and columns (as MAME's loop).
- **Tilemaps**: drawn line by line from the live tile RAM and scroll registers (MAME takes them at the start of the vertical blank: the
  same picture for games that write them in the blank, which these do).
- **Memory**: 64 MB SDRAM: everything (program, Z80, samples, tiles, 30 MB of sprites) in the SDRAM; the DDR3 only for the fast load.
- **YMF262**: opl3_fpga on a 24 MHz clock with the exact 49.716 kHz sample enable; the timers count samples.  Not ymfm (MAME's): the sound
  will not be sample-identical to MAME.
- **Mix**: MAME's route gains (YMZ280B 0.30, YMF262 0.50 per side, OKI 0.25) with the YMF262 on the chip's own scale (the old MAME core's,
  not ymfm's twice-as-loud one: MAME flaw 11), all times 1.5.  To 48 kHz: the YMZ280B and the YMF262 box-filtered (averaged over each
  output period), the OKI interpolated as MAME 0.289's default resampler does (4-point "lofi"; held, it hissed: "Sound").
- **Memory priority**: the two sample chips' SDRAM ports come first (the OKI takes its ADPCM byte at a fixed time, ready or not); "Sound".
- **Protection**: MAME's simulation (tecmosys_m.cpp), selected by the header byte.
- **Watchdog**: MAME's 400 vertical blanks (a guess in the driver).

## MAME's flaws (to fix in the end)

What MAME's driver says it does not know or does not do, and what this core found.  Each needs evidence from the real board (PCB videos,
a board owner, the games' own code) before the core departs from MAME; until then the core does what MAME does.

| # | Flaw | MAME (0.289) | How to decide |
|---|---|---|---|
| 1 | Flip screen "is wrong" | tilemaps flipped about a 512 x 512 "screen", sprites not flipped at all | **FIXED.**  The code (tkdensho 0x2e5e, the sub MAME's comment names): with the invert flag (2005b3) set the game ORs **0x8000 into both sprite offsets** (880000 = X + 0x30, 880002 = Y + 0xf4), sets the flip words (a80004 / b00004 / c80004 = 3, c00004 = 0x13) and adds 0x20 / 0x116 to every scroll; MAME masks bit 15 away.  Two MAME runs of the same play, one with 2005b3 poked to 1 (`tools/capture.py --poke`), differ only in those registers; the model of `tools/flip_study.py` -- BG tilemaps flipped about 287 / -39 (319 - 0x20, 239 - 0x116), the text layer about 319 / 239, the sprite layer mirrored (x' = 271 - x, y' = -5 - y: 319 - 0x30, 239 - 0xf4) -- renders the inverted state as MAME's normal picture turned 180 degrees: **0 pixels differ on 4 fight frames** (MAME's own inverted pictures differ by 4.9 K-70 K pixels), and the unflipped picture stays MAME's.  RTL (`ts_tiles`, `ts_sprites`: a reverse row stepper for the Y flip that keeps MAME's row order): the 4 inverted frames pixel-identical to MAME's normal ones turned around, 8 / 8 random stress frames (sprite layer flipped in X / Y independently, tilemap flips, zoom) identical to the model.  Open: the text layer's scroll registers (MAME ignores them; tkdensho writes 018e / 01ee, deroon 018e / 01ef): if the board applies them (offsets 114 / 18 would cancel tkdensho's) deroon's text sits one line lower than MAME shows -- the flip test cannot tell, the core keeps MAME's picture; a PCB photo of deroon's text against its background would |
| 2 | Line scroll (301000 / 401000 / 501000) unimplemented, "seems unused" | ignored (popmessage on non-zero writes) | **checked**: `tools/lua/wrlog.lua`, 10,000 frames of each game (boot, attract, coin, start, random play): not one non-zero write to any of the three line RAMs.  Nothing to implement for these games (the RAMs are there, read / write, as on the board) |
| 3 | tkdenshoa: garbage sprites at the top during Y scroll on the PCB | not shown | sprite Y wrap (9-bit Y, the 0x1ff mask) / the list entries MAME skips; needs the PCB video |
| 4 | Priority / mixing "unverified" | do_final_mix as written | PCB video of the blend-flag effects |
| 5 | Sprite zoom: source-driven, so a zoom above 1.0 leaves empty rows / columns (seen in the stress frames), and below 1.0 several source rows / columns land on one line / pixel (the last opaque one wins) | as described | **Checked what the games use** (`tkdensho` play, 9 frames): no magnification at all; the only zoom is X 1.0 / Y 0.25 (0x100 / 0x040, 99 sprites: the fighters' squashed shadows), so the gaps never show.  The open point is the shrink: a real zoom unit most likely samples one source row per line (which of the four?) where MAME composites all four.  Needs a PCB capture of a shadow; until then MAME's |
| 6 | Sprites one frame behind the tilemaps ("which is correct?") | one frame behind | the board's sprite DRAM frame buffers (2 x 424260) make a one-frame delay natural; keep |
| 7 | 880000 registers other than 00 / 02 / 08 / 22 ("unknowns of sprite / tilemap registers") | ignored | **logged** (`wrlog.lua`, same runs): written once at boot, identically by both games: 880004 = 01f0, 88000a = 0f40, 88000c-880020 = 0, 880024 = 6969 (deroon, byte) / 0069 (tkdensho), deroon later 880024 = 0; the four flip words stay 0 except c00004 = 0010 (MAME: "bit 4 of c00004 is unknown").  Constants (CRTC-like set-up): they change nothing the games show; worth a look only if a PCB capture disagrees with the raster |
| 8 | Raster: placeholder 512 x 512 | — | this core: 448 x 272 at 7 MHz (above); a PCB measurement would settle it |
| 9 | Protection MCU not dumped | simulated | nothing to do unless it is dumped |
| 10 | Watchdog period (400 vertical blanks, "guess") decides the first boot | the cold boot (deroon 0x0bf0-0x0c42; tkdensho has the same handshake at 0x3382) writes "Power on reset" to work RAM 200000, writes 0 to 880025 and spins in `nop; bra` at 0x0c40 waiting to be reset; MAME's watchdog resets it after 400 frames (6.96 s), the warm boot finds the string and goes on (MAME: "Z80 INITIALIZ" at frame ~450) | **880025 is not a reset trigger**: deroon writes 69 then 00 to it on both paths (0x0430, 0x044c; 0x0c38 on the cold one) and the warm boot keeps running after its 00 -- the board resets the cold boot with a watchdog of unknown period.  Needs a power-on video of a board (time from power to the first text).  The core keeps MAME's 400 frames (the reset is held 2048 clocks: the 68000 needs a long one) |
| 11 | The FM 6 dB too loud against the YMZ280B and the OKI (found 2026-11-18, after the owner heard Angel Eyes' voices and effects "buried under music" against MAME videos) | left = 1.0 x the FM's A sum + 0.25 x the OKI + 0.30 x the YMZ280B (ymfm's YMF262 at 0.50 with its 2x scale) | **FIXED** (20261118c) from MAME's own history (sources of each release, `work/oldmame/`): 0.140-0.224 route the FM at 1.00, the OKI at 0.50, the YMZ280B at 0.30 (`ymz280b.cpp` without the `/ 2`).  0.225's stream conversion of `ymf262.cpp` wrote output A to all four outputs (`ch_a..ch_d.put_int_clamp(i, a, ...)`), and these games pan to A and B only (0x30), so left = A + "C" = 2 A.  In December 2020 R. Belmont halved the YMZ280B ("ymz280b: Fix major mixer overdriving", d0cf574b51) and David Haywood halved this driver's FM and OKI routes to keep the balance ("rebalance sound after ymz280b change", e28a67d352): everything was meant to drop 6 dB, but the FM was doubled by then and stayed at its old level.  ymfm (0.231 on) is exactly twice the old core's scale, so the doubling stayed.  The core mixes the FM at the old scale with 0.227's gains (the ratios of 0.224, the ones the rebalance meant to keep), times 1.5 to keep 20261118b's loudness; MAME 0.224's own level would be 2.  The analogue mix of a real board is unmeasured |

## Whole machine

`sim/run.sh` (ts_core + ts_mem + the SDRAM model, both CPUs from reset, blank 93C46 as MAME's `capture.py` default):

- Both games' cold boot spins waiting for the watchdog exactly as MAME (deroon 68000 0x0c40-0x0c44, tkdensho 0x2222-0x2224, frames 0-399;
  the Z80 in its idle loop 0x00e8-0x00ea), the watchdog resets the machine at frame 400 as MAME's.
- The first runs showed the warm boot never starting: the watchdog's reset was a few clocks long and fx68k did not take it.  Fixed
  (ts_core holds it 2048 clocks).
- A run with a 10-frame watchdog (`VFLAGS=-GWDOG_FRAMES=10`: the same boot 390 frames earlier) shows "Z80 INITIALIZ" 15-20 frames after the
  reset as MAME does after its own, the game initialises the 93C46 (108 writes) and prints MAME's first-boot screen ("DIP1 / DIP2 /
  DEBUG_DIP READ ERROR!"): its pictures 200-220 are **pixel-identical to MAME's frame 600**.
- Full-length runs (400-frame watchdog: frame numbers as MAME's), every checked picture **pixel-identical to MAME's picture of the same
  frame**: deroon 449-451 ("Z80 INITIALIZ"), 599-601 (the READ ERROR lines), 749-751 ("INITIALIZED"); tkdensho 599-601 (the grid),
  749-751 (the version screen), 899-901 (the TECMO logo over its background); deroon 899-901.  At frame 950 (deroon's TECMO logo with the
  flashing "INSERT COIN") the RTL is **one frame behind**: its picture 951 is MAME's 950 (the quick run: 561 for 950 + 390 - 1).  The
  CPU-timing differences (the 32-line vertical blank against MAME's 272-of-512, the program cache's wait states) are the candidates; not
  investigated yet.  In the attract after the logo (the sound run, 10-frame watchdog) pictures 760 / 850 / 900 / 949 are pixel-identical to
  MAME's frames 389 (or 388) later -- the sprite character, its caption, the BG text -- and picture 800 is 42 pixels from MAME's closest
  (an animation phase in between: the same drift).  deroon ran 960 frames without a late line (tile lines <= 1,503 clocks, sprite lines <= 1,026 of 6,144) and without an
  SDRAM timing violation.
- The drift, looked into (2026-11-18).  Not the vertical blank's length: each game reads 880000 once a frame, first thing in its level-1
  handler (deroon 0x486, tkdensho the instruction before 0x22ce: a Lua read tap in MAME), and only checks that bit 0 says "in the blank", which it does at the
  interrupt in MAME and in the core alike.  Not the program caches' wait states: over 1,250 frames 99.7 % of the 68000's 68 M ROM reads
  were zero-wait (the misses cost ~0.1 % of its time), the Z80 had WAIT low in 0.5 % of its clocks, and a Z80 cache eight times larger
  left the pictures at the drift (quick-run 560 / 561 = MAME 949 / 950) and the sound writes exactly as before (A / B runs; reverted).
  What does differ: the first sound write out of MAME's frame is the YMF262 timer acknowledge (`01 c3`) at the frame 915 / 916
  boundary; opl3_fpga starts a timer's period at its next sample (TECMOSYS: ticks of 4 / 16 samples), MAME's ymfm at the exact time of
  the write -- up to one sample (20 us) apart, enough to put an event that close to the boundary in the other frame; the next sound
  command then meets the Z80 in the other order, and the attract runs a frame apart from there.  A 20 us race between two models of the
  chip, neither known to be the board's; left as it is.
- Angel Eyes' I/O-check exit (2026-11-18, `+INPUTS`, the ports changed on the vertical-blank pulse as `TecmoSys.sv`'s Start 1P+2P is):
  from reset, test switch at frame 900, cursor down three times, button 1 at 1100 (the I/O check), a lone 1P Start at 1340, 1P Start
  at 1370 with 2P Start at 1371, both Starts at 1400.  Pictures 1312 / 1360 / 1390 (still the I/O check) and 1430 (back in the main
  menu) **pixel-identical to MAME's same frames** with the same holds; no late line, no SDRAM timing violation over 1,432 frames.  (The
  bench drives `ts_core`'s ports, not the pad bits: the three lines of `TecmoSys.sv` that turn bit 10 into both Starts are not in it.)

(More as the runs complete.)

## Sound

- The Z80's writes to the sound chips (`tools/lua/sndlog.lua` in MAME, `sim/run.sh +SNDLOG=`, `tools/cmp_sndlog.py`), deroon from its
  watchdog reset to MAME frame 718: **all 1,858 writes in MAME's order** (YMF262 1,770, YMZ280B 72, OKI 3, OKI / Z80 banks 6, NMI enable 7),
  within a frame of MAME's (670 in the same frame).
- That comparison found a bug of the vendored YMF262: register 04 with bit 7 set must be a one-shot reset of the timer flags that leaves the
  other bits alone (as the chip, as ymfm); opl3_fpga stored the low bits and held the reset, so the games' interrupt acknowledge (c3 / a3)
  masked timer 1 and kept the flags cleared: the sound driver stopped after its first timer interrupt.  Fixed (`modules/opl3/timers.sv`,
  TECMOSYS).
- With the fix, a 950-frame run (10-frame watchdog: MAME's time = the bench's + 389 frames / 6.772 s) against MAME from a blank 93C46:
  **2,689 writes in MAME's order** (to MAME frame 916, where a sound command's NMI and a timer interrupt fall in the other order: the
  one-frame drift again); the **first sound at 19.76 s against MAME's 19.78 s**; over deroon's first 3.4 s of music the loudness envelopes
  correlate **0.978** at zero shift, but the core was **3.9 dB quieter** (RMS 1,698 against 2,672; peak 7,523 against 12,031).
- **The level, calibrated (2026-11-18).**  The cause is the YMF262's scale: opl3_fpga makes an operator's output
  `((exp | 0x400) << 1) >> shift` (at most 4,084: Nuked OPL3's, the die's), MAME's ymfm `((exp | 0x400) << 2) >> shift` (8,168), and ymfm's
  YMF262 sums the channels unshifted into 16 bits ("mixing details for YMF262 need verification"): MAME's FM is exactly twice opl3_fpga's
  at the same registers.  MAME's route gains (0.50 for the FM) were set against ymfm's scale, so the board's balance as MAME has it needs
  the factor.  The other two match MAME's code exactly: `ts_ymz280b` sums `sample * vol / 2 / 256` as MAME's `32768 * 256` scale, and
  jt6295's voice is the 12-bit ADPCM value times MAME's volume table (0x20 = 1.0).  Measured: `sim/run.sh +CHIPS=` logs the three chips'
  outputs at each 48 kHz sample, `tools/fit_mix.py` fits the mixer's gains to MAME's 40 s recording of the same boot by power over 50 ms
  windows (non-negative least squares):

  | Run (bench frames 0-1400, 10-frame watchdog) | YMZ280B | YMF262 | OKI | MAME / core |
  |---|---|---|---|---|
  | deroon (227 windows with sound) | 0.306 (+0.15 dB; 12 % of the power) | **0.979 (+5.84 dB**; 84 %) | 4 % (not fitted well) | +4.00 dB |
  | tkdensho (273 windows) | 3.9 % (not fitted well) | **0.978 (+5.83 dB**; 96 %) | 0.2 % | +3.05 dB |

  The fitted mix lands within 0.1 dB of MAME's; the rebuilt bench (deroon, 1,250 frames) is **+0.1 dB** from MAME's recording (RMS 1,029
  against 1,012, envelope correlation 0.992; the same run without the fix: -4.1 dB, 0.978).  Fix (20261118 and 20261118b): `ts_opl3` doubled opl3_fpga's output, saturated to
  16 bits (ymfm's clamp), and the mixer kept MAME's gains.  (The real chip's digital scale is Nuked's; that restored MAME 0.289's balance
  between the three chips.)  **Superseded in 20261118c**: MAME 0.289's balance is not the driver's -- the FM has been 6 dB too loud against
  the samples since 0.225 (MAME flaw 11 above: a YMF262 output bug, a rebalance that kept it, ymfm's scale).  `ts_opl3` keeps the chip's
  scale (`X2 = 0`) and `ts_audio48` mixes at 0.227's gains times 1.5 (115 / 192 / 1536 in 1/256).
- **The owner's test of 20261118b (2026-11-18)**: Deroon's coin sound "crackly and glitchy", more background noise and static than the
  owner's other cores, Angel Eyes' voices and effects buried under the music against MAME videos.  Three causes, all fixed in 20261118c:
  - **The OKI's ADPCM bytes came late.**  jt6295 puts a voice's address out for two 192-clock slots and takes the byte at the end of
    the second, ready or not (`jt6295_rom`: no ok for ADPCM data).  The sample ports were 4 (YMZ280B) and 5 (OKI) of the SDRAM's
    fixed priority, below the tile rows and the CPUs' line fills, and waited up to 382 clocks.  A byte taken before it came is a wrong
    nibble pair, and the OKI's decoder integrates without a leak: the rest of the phrase sits on a DC offset (Deroon's coin sound,
    phrase 14, drifted to -700 of a 2,048 range: a thump and crackle).  `sim/run.sh` counts it now (the "sample ROMs:" line) and
    `+OKILOG=` logs the OKI at its own rate; `tools/oki_decode.py` decodes a phrase from the ROM with MAME's ADPCM.  Fix: the OKI and the
    YMZ280B are ports 1 and 2 (`ts_mem`), above everything but the loader; their reads are single words.  From reset with the same
    inputs (10-frame watchdog):

    | Run | YMZ280B samples late | OKI bytes taken before they came | Longest OKI wait (of 384) |
    |---|---|---|---|
    | deroon, 1,000 frames, coin at 911: before | 175 | 694 | 382 |
    | after | **0** | **1** (in the watchdog's reset, no voice playing; no longer counted) | 33 |
    | tkdensho, 1,711 frames, a fight: before | 685 | 4,165 | 382 |
    | after | **0** | **1** (the same) | 39 |

    The coin sound against MAME's decode of the ROM: **all 14,078 samples equal MAME's + 2** (jt6295 starts a phrase's decoder at 0,
    MAME's okim6295 at -2: a constant 1/1024 of full scale, inaudible; before, the bench's mean drifted to -700).  The rest of the machine
    as before: the snapshots (deroon 891, 951; tkdensho 1011, 1461) byte-identical to the runs before the change; the 68000's ROM reads
    over 6 clocks 831,611 -> 837,709 (+0.7 %), its longest 234 -> 252 clocks; the Z80's wait share 0.61 % -> 0.54 %; the longest tile /
    sprite line 1,596 / 1,838 of 6,144 clocks, no late line, no SDRAM timing violation.
  - **The FM 6 dB too loud** against the samples: MAME flaw 11 (above).  The fight's mix with the fix: RMS 0.8 dB under the same sounds at
    20261118b's settings, peak 11,944 of 32,767.
  - **The OKI's output held as a staircase.**  ts_audio48 box-averaged its held 15.15 kHz output, which keeps the staircase's images:
    on the coin sound (the OKI alone) 15 - 28 dB more than MAME's recording between 10 and 22 kHz (relative band levels, 10 / 12 / 16 /
    20 kHz: bench -18.7 / -16.9 / -20.7 / -25.8 dB, MAME -34.9 / -42.1 / -48.6 / -48.0 dB): a hiss on every OKI voice.  MAME 0.289's
    default resampler ("lofi", `emu/resampler.cpp`) interpolates a slower stream with a 4-point formula; `ts_oki_interp` does the same
    in Q16 at each output sample (`sim/tb_oki_interp.sv` + `sim/check_oki_interp.py`: 20,001 outputs from random full-range samples
    against MAME's formula in floating point, largest error 0.39 of one OKI step, every phase covered).  In the machine (deroon's coin
    run again, 1,000 frames): the OKI's log and the pictures identical to the run without it, no OKI byte late (0: the count leaves the
    reset out now), and the coin sound's bands against MAME's recording over the same phrase (relative band levels, 10 / 12 / 16 / 20 /
    22 kHz): **core -31.9 / -42.8 / -49.0 / -43.9 / -46.2 dB, MAME -33.6 / -42.2 / -47.6 / -46.1 / -48.6 dB** (held: -18.7 / -16.9 /
    -20.7 / -25.8 / -30.6).  (MAME's window also holds the end of its music below 250 Hz: its music fades a little later than the
    core's.)
  - **On hardware** (the owner, 2026-11-19, 20261118c): the sound "much better now", the coin sound clean.

## Controls and the hardware tests

- First hardware test (the owner, 2026-11-17, release 20261117): both games ran.  Deroon's first boot showed "checking errors" that did not
  come back: MAME shows the same on a blank 93C46 (`capture.py deroon 10-890/20`: "Z80 INITIALIZ", "DIP1 / DIP2 / DEBUG_DIP / RANKING DATA
  READ ERROR!", "INITIALIZED") -- the game setting up its EEPROM, which the core then saves; nothing to fix.
- Button names, from the games themselves (MAME runs with `capture.py --hold`): Deroon's I/O test lists PUSH1-3 (no fourth button); its
  how-to-play says the left / right button turns the piece left / right ("ボタン左右で、左右回転"), and in play button 2 turned a standing
  pair clockwise and button 3 dropped a bomb: **Rotate Left, Rotate Right, Bomb**.  Angel Eyes' I/O test lists A-D BUTTON; in a two-player
  fight against an idle opponent A jabbed, B threw a straight punch, C kicked low, D kicked high, KLOV's panel "Light Punch | Heavy Punch |
  Light Kick | Heavy Kick": **Light Punch, Heavy Punch, Light Kick, Heavy Kick** (pad defaults: punches on Y / X, kicks on B / A).  The MRAs
  name them (`tools/make_mra.py`); the core's own J1 says Button A-D.  The service coin is no longer a mappable button (keyboard 9 only).
- Test mode: both games enter it when the test switch is pressed in attract with no credits (MAME's "press the test switch before you
  insert any coins").
- Second hardware test (the owner, 2026-11-18, release 20261118): the sound level and the button names fine; **Angel Eyes' I/O check
  could not be left by one player** -- it needed both Starts.  The screen says "1P & 2P START TO EXIT", and the rule is stricter than
  that: the game's input routine (0x30C0, run from the vertical-blank interrupt) reads P1 (d00000) and then P2 (d00002) about 40 us later,
  and keeps each port's new presses for that frame (2000ec / 2000ee).  The exit needs **both Starts' new presses in the same frame**.  MAME
  (`capture.py --hold`, from a blank 93C46 and from a set-up one): a lone 1P Start, and 1P Start with 2P Start one frame later, stay in the
  test; both Starts together on one frame leave it.  So holding one Start and pressing the other never works: one player on two pads
  cannot do it.  Deroon's I/O check ("PRESS 1P START AND <PUSH1> TO EXIT") exits with Start held and button 1 pressed later (MAME), so
  only Angel Eyes needed help.
  Fix: a seventh pad button, **Start 1P+2P** (the core's joystick bit 10: J1, Angel Eyes' MRAs, default pad R), that presses both Starts.
  `TecmoSys.sv` samples it on the vertical-blank pulse that raises the interrupt, so both port reads of a frame see the same value; a
  press between the two reads would otherwise split the Starts over two frames.  Deroon's MRAs hide it.  RTL: the whole-machine bench
  (`sim/run.sh +INPUTS`, which changes the ports at the same vertical-blank pulse) runs the same schedule as MAME, pixel-identical at
  all four checked frames: see "Whole machine".
- The MRAs' pad defaults: Main_MiSTer (`joymapping.cpp`, since 2020) skips a "-" button **without using up an entry of `default`**.
  Deroon's MRAs listed a default for their hidden fourth button (`A,B,X,Y,Start,Select`), so on a pad with no saved mapping Start sat on
  Y and Coin on Start.  Now `A,B,X,Start,Select`.
- Third hardware test (the owner, 2026-11-18, release 20261118b): **Start 1P+2P leaves Angel Eyes' I/O check**.  The sound: Deroon's
  coin sound crackly, more background noise than the owner's other cores, Angel Eyes' voices and effects under the music: three causes,
  fixed in 20261118c ("Sound").
- Fourth hardware test (the owner, 2026-11-19, test build 20261118c, released as 20261118): the sound "much better now", Deroon's coin sound clean.

## Build

**Names**: the first release, 20261118 (2026-11-19), is test build 20261118c renamed (the same RBF, SHA-256 1586ebce...5e7f44).  The
owner's test builds 20261117, 20261118 and 20261118b were never published; this document keeps their names for the history, and their
RBFs and reports moved out of `releases/` to `work/old_releases/` (outside the repository).  The release notes and the README describe
the release alone.

`releases/tecmosys_20261118.rbf` (Quartus 17.0.2 Lite, seed 1, jchan-mister's settings, ~20 min; `tools/release.py`): **20,681 ALMs (49 %),
329 / 553 RAM blocks (59 %), 59 / 112 DSP, 3 PLLs**; `tools/check_ram_depth.py`: every RAM as deep as declared; timing met in all four
models for every check (`quartus_sta --multicorner=on`; the release script found 0 negative slacks of 78).  The tightest setup is the
framework's HDMI clock; the core's 96 MHz has +0.358 ns:

| Model | Setup | Hold | Recovery | Removal |
|---|---|---|---|---|
| Slow 1100 mV 100 C | +0.197 ns | +0.207 ns | +1.335 ns | +1.069 ns |
| Slow 1100 mV -40 C | +0.076 ns | +0.094 ns | +1.433 ns | +0.991 ns |
| Fast 1100 mV 100 C | +3.160 ns | +0.132 ns | +4.594 ns | +0.526 ns |
| Fast 1100 mV -40 C | +3.528 ns | +0.074 ns | +4.939 ns | +0.449 ns |

20261118c against 20261118b: the sound ("Sound": the sample ports first in the SDRAM's priority, the FM at the driver's balance and the
mix times 1.5, the OKI interpolated as MAME's resampler; 12 more DSP blocks for the interpolation).  Its first build missed the 96 MHz
clock by 0.013 ns in the mixer's last stage (a 41 x 32 product and two 73-bit sums in one clock): split over two clocks.
20261118b against 20261118: the Start 1P+2P button (Angel Eyes' I/O check exit) and Deroon's MRA pad defaults (see "Controls").
20261118 against 20261117: the buttons named per game (MRAs; the service coin no longer a mappable button) and the YMF262 at MAME's scale.
Packaged by `tools/package.py` as `dist/TecmoSys_MiSTer_20261118.zip` (the five MRAs and the RBF in the SD card's structure), with
`dist/RELEASE_NOTES_20261118.md` and `dist/REPO_DESCRIPTION.txt` (`dist/` holds the latest release only and is not in git).
The README's game pictures (2026-11-19): `capture.py <set> N-1,N --play --seed S`: deroon seed 21 frames 5400 (the player's two-chain)
and 6326 (the opponent's), tkdensho seed 7 frames 2452 (stage 1, the castle) and 6820 (stage 2, the burning wreck); through
`tools/bench_video.py` with the release's RTL 0 pixels differ on all four.

History: the first build (before the flip fix) met setup / hold; the second (flip fix, the watchdog's reset stretch) failed **recovery** by
0.476 ns -- the machine reset had become combinational (`rst | hold != 0`) and drives the Z80's and the OKI's asynchronous clears across the
chip; `ts_core` registers it now.  The YMF262's 24 MHz domain has +28 ns.  The one critical warning (an array port of the framework's
`ascal`) is the framework's own (Super Duck's build has it too).

## Next

1. Long play with inputs against MAME (tools/capture.py --play / --hold, sim/run.sh +INPUTS), both games.
2. More hardware tests (the owner): Deroon's pad defaults (with no saved mapping).
3. The MAME flaws above that wait for a real board's evidence.
4. Sound details: jt6295's decoder starts a phrase at 0 where MAME's starts at -2 (a constant 2-step offset, inaudible: a fourth patch to
   the vendored copy would make the OKI sample-identical); the YMF262 and the YMZ280B are box-filtered where MAME's lofi resampler
   averages pairs and interpolates (their spectra matched MAME's within ~1 dB below 14 kHz on Deroon's music, so it was left).
