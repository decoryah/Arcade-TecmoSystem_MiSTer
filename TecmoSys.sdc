# Timing constraints of the Tecmo System core (from the owner's jchan-mister Jchan.sdc and supduck-mister SuperDuck.sdc).
derive_pll_clocks
derive_clock_uncertainty

# ==============================================================================
# SDRAM. The chip is clocked by the PLL's second 96 MHz output, shifted about half a period (rtl/pll/pll_0002.v); the pin's clock is modelled
# as the machine clock inverted, and the read data -- launched by the chip's edge, captured by ts_sdram's input register a few edges after
# the READ command -- gets a two-cycle path.  The register assignments in sys/sys.tcl put the SDRAM pins' registers in the IO cells.
# ==============================================================================
set sdram_clk_src [get_pins -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sdram_clk_src] == 0 } {
    set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 -phase 180 [get_ports {SDRAM_CLK}]

set sys_clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sys_clk] == 0 } {
    set sys_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -hold  -end 2

# ==============================================================================
# The YMF262's 24 MHz (PLL output 2) and the machine clock: unrelated as far as the logic is concerned.  Every crossing goes through
# opl3_fpga's own asynchronous FIFO / synchronisers (host_if.sv) or ts_opl3.sv's toggle handshake and two-flop synchronisers.
# ==============================================================================
set opl_clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[2].output_counter|divclk}]
if { [get_collection_size $opl_clk] == 0 } {
    set opl_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
set_clock_groups -asynchronous -group $opl_clk -group $sys_clk

# ==============================================================================
# The 68000 (fx68k).  The multicycle paths below rely on the CPU phase enables (ts_cen: phi1 and phi2 each once per CPU_DIV = 6 clocks,
# 3 clocks apart); with a CPU_DIV below 6 they are wrong.  (jchan-mister's constraints, same CPU wrapper and bus protocol.)
# ==============================================================================
set_multicycle_path -setup -end 3 -from [get_registers {*|fx68k:u_cpu|*}] -to [get_registers {*|fx68k:u_cpu|*}]
set_multicycle_path -hold  -end 2 -from [get_registers {*|fx68k:u_cpu|*}] -to [get_registers {*|fx68k:u_cpu|*}]
set_multicycle_path -setup -end 3 -from [get_registers {*|fx68k:u_cpu|excUnit:excUnit|aob[*]}]
set_multicycle_path -hold  -end 2 -from [get_registers {*|fx68k:u_cpu|excUnit:excUnit|aob[*]}]
set_multicycle_path -setup -end 3 -from [get_registers {*|altsyncram*|*}] -to [get_registers {*|fx68k:u_cpu|excUnit:excUnit|dataIo:dataIo|*}]
set_multicycle_path -hold  -end 2 -from [get_registers {*|altsyncram*|*}] -to [get_registers {*|fx68k:u_cpu|excUnit:excUnit|dataIo:dataIo|*}]
set_multicycle_path -setup -end 3 -from [get_registers {*|fx68k:u_cpu|rFC[*]}]
set_multicycle_path -hold  -end 2 -from [get_registers {*|fx68k:u_cpu|rFC[*]}]

# ==============================================================================
# The Z80 (tv80s_cen) steps on cen_z80, every 12 clocks (8 MHz); jt6295 on cen_oki, every 48 clocks.  Only paths inside each are relaxed.
# ==============================================================================
set_multicycle_path -setup -end 2 -from [get_registers {emu|u_core|u_sound|u_cpu|*}] -to [get_registers {emu|u_core|u_sound|u_cpu|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|u_core|u_sound|u_cpu|*}] -to [get_registers {emu|u_core|u_sound|u_cpu|*}]
set_multicycle_path -setup -end 2 -from [get_registers {emu|u_core|u_sound|u_oki|*}] -to [get_registers {emu|u_core|u_sound|u_oki|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|u_core|u_sound|u_oki|*}] -to [get_registers {emu|u_core|u_sound|u_oki|*}]

# ==============================================================================
# The framework's HQ2x scandoubler (sys/hq2x.sv): the blender's registers advance on ce_x4 of the scandoubler, at least 3 clocks apart for
# this core's 13.7-clock pixels.
# ==============================================================================
set_multicycle_path -setup -end 2 -from [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}] -to [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}] -to [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}]
