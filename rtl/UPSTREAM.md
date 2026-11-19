# Files in this directory derived from other projects

The platform layer is the owner's Jackie Chan core (`jchan-mister`: also a 68000 + YMZ280B board on the 64 MB SDRAM module, hardware-proven
on a DE10-nano), taken on 2026-11-17; the Z80 / OKI sound structure follows the owner's Super Duck core (`supduck-mister`), the 93C46 the
owner's Metro core (`metro-mister`).

| File | Derived from | Licence | Changes for this core |
|---|---|---|---|
| `ts_sdram.sv` | `jchan-mister/mister/rtl/jchan_sdram.sv` (64 MB module, CL2 / BL1, close page, NP burst ports; physical layer of metro-mister's `metro_sdram.sv`) | GPL-3.0-or-later (`../LICENSE`) | renamed only |
| `ts_mem.sv` | `jchan_mem.sv`: `jchan_rcache` -> `ts_rcache`, `jchan_loader` -> `ts_loader` unchanged; `ts_byterd` = `jchan_ymzrd` without its region fold | same | this board's seven ports and SDRAM image; `ts_zcache` (the Z80's byte reads through `ts_rcache`) new |
| `ts_m68k.sv` | `jchan_m68k.sv` (fx68k with a req / ack bus) | same | renamed only |
| `ts_ram.sv` | `jchan_ram.sv` (`ts_spram`, `ts_tdpram`) | same | renamed; `ts_sdpram_w`, `ts_tdpram_w`, `ts_spram8` added |
| `ts_fastload.sv` | `jchan_fastload.sv` (DDR3 replay of the MRA image) | same | renamed only |
| `ts_cen.sv` | `jchan_cen.sv` (`jchan_pixgen` -> `ts_pixgen`) | same | this board's enables: 68000 16 MHz, Z80 8 MHz, OKI 2 MHz, dots 7 MHz in 448 x 272 |
| `ts_standby.sv` | `jchan_standby.sv` | same | this board's raster |
| `ts_ymz280b.sv` | `jchan_ymz280b.sv` (the YMZ280B written from MAME 0.289) | same | marked `TECMOSYS`: fractional 88.2 kHz tick for the 16.9344 MHz chip, the read side (status / end flags, external memory read 0xff) |
| `ts_eeprom.sv` | `metro-mister/mister/rtl/metro_eeprom.sv` (93C46, 16-bit, hardware-tested on the Metro boards) | same | renamed only |
| `pll.v`, `pll.qip`, `pll/` | `jchan-mister`'s PLL (96 MHz, 96 MHz shifted for the SDRAM chip) | same | a third output, 24 MHz, for the YMF262 |
| `../TecmoSys.sv` | `jchan-mister/mister/Jchan.sv` (hps_io, fast load, NVRAM save, Scale, CRT Adjust glue, standby raster) | same | this board's controls, loader map (header, BG tile row order, sprite area), no DIP switches, 448 x 272 raster for CRT Adjust |
| `../sim/ts_sdram_model.sv` | `jchan-mister/mister/sim/jchan_sdram_model.sv` (metro-mister's, from Arcade-HyperDuel_MiSTer) | same | renamed; the clock count and the times kept against it 64-bit (32-bit ones wrapped after ~1,290 frames and reported false tRP violations) |
| `../tools/mra_build.py`, `../tools/pngio.py` | `jchan-mister/mister/tools/` (mra_build.py from plasticbugs/analogue-pocket-gaiapolis) | same | none |
| `../tools/package.py` | `cojag-mister/mister/tools/package.py` (the release zip in the SD card's structure) | same | this core's names; keeps `dist/` to the latest release |

Written for this core (from MAME 0.289's tecmosys.cpp / tecmosys_v.cpp / tecmosys_m.cpp, not derived from HDL): `ts_main.sv` (the 68000's
map, interrupt, watchdog, registers), `ts_prot.sv` (the protection simulation), `ts_tiles.sv` (the four tilemaps' line renderer),
`ts_sprites.sv` (the zooming sprite engine, line by line), `ts_video.sv` (raster and final mix), `ts_sound.sv` (Z80 board),
`ts_opl3.sv` (YMF262 wrapper and clock crossing), `ts_audio48.sv` (the mix, the 48 kHz box filter after `jchan_audio48`, and the OKI's 4-point interpolation from MAME's `audio_resampler_lofi`),
`ts_core.sv`.
