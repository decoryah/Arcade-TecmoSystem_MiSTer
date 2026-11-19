# The core's source list for the Verilator benches and the lint (sourced from sim/*.sh, run from sim/).  Keep in step with files.qip.
M=../modules
RTL_FILES="../rtl/ts_ram.sv ../rtl/ts_cen.sv ../rtl/ts_m68k.sv ../rtl/ts_eeprom.sv ../rtl/ts_prot.sv ../rtl/ts_main.sv \
    ../rtl/ts_tiles.sv ../rtl/ts_sprites.sv ../rtl/ts_video.sv \
    ../rtl/ts_opl3.sv ../rtl/ts_ymz280b.sv ../rtl/ts_sound.sv ../rtl/ts_audio48.sv ../rtl/ts_core.sv \
    ../rtl/ts_sdram.sv ../rtl/ts_mem.sv ../rtl/ts_fastload.sv"
OPL3="$M/opl3/opl3_pkg.sv $M/opl3/afifo.v $M/opl3/synchronizer.sv $M/opl3/calc_phase_inc.sv $M/opl3/calc_rhythm_phase.sv \
    $M/opl3/dac_prep.sv $M/opl3/channels.sv $M/opl3/clk_div.sv $M/opl3/control_operators.sv $M/opl3/edge_detector.sv \
    $M/opl3/calc_envelope_shift.sv $M/opl3/envelope_generator.sv $M/opl3/host_if.sv $M/opl3/ksl_add_rom.sv $M/opl3/leds.sv \
    $M/opl3/mem_multi_bank_reset.sv $M/opl3/mem_multi_bank.sv $M/opl3/mem_simple_dual_port_async_read.sv $M/opl3/mem_simple_dual_port.sv \
    $M/opl3/operator.sv $M/opl3/opl3_exp_lut.sv $M/opl3/opl3_log_sine_lut.sv $M/opl3/opl3.sv $M/opl3/phase_generator.sv \
    $M/opl3/pipeline_sr.sv $M/opl3/reset_sync.sv $M/opl3/timer.sv $M/opl3/timers.sv $M/opl3/tremolo.sv $M/opl3/vibrato.sv"
MOD_FILES="$M/cpu-fx68k/fx68kAlu.sv $M/cpu-fx68k/uaddrPla.sv $M/cpu-fx68k/fx68k.sv \
    $M/cpu-tv80/tv80_alu.v $M/cpu-tv80/tv80_core.v $M/cpu-tv80/tv80_mcode.v $M/cpu-tv80/tv80_reg.v $M/cpu-tv80/tv80s_cen.v \
    $M/jt6295/hdl/jt6295.v $M/jt6295/hdl/jt6295_adpcm.v $M/jt6295/hdl/jt6295_timing.v $M/jt6295/hdl/jt6295_acc.v \
    $M/jt6295/hdl/jt6295_ctrl.v $M/jt6295/hdl/jt6295_rom.v $M/jt6295/hdl/jt6295_serial.v $M/jt6295/hdl/jt6295_sh_rst.v \
    $OPL3"
