# Cave 68000 for Analogue Pocket — core timing constraints
#
# Read by apf/apf_constraints.sdc (Analogue's, unmodified) after it has
# created clk_74a / clk_74b / bridge_spiclk and run derive_pll_clocks. Not
# listed in ap_core.qsf, so it is applied once.

derive_clock_uncertainty

# ------------------------------------------------------------------ clocks
#
# The two PLLs' output counters, by the path derive_pll_clocks gives them
# (core_top's u_pll_core / u_pll_video -> altera_pll_i). Renaming any level
# silently breaks every line below, so each is checked.
set pll_core  {ic|u_pll_core|altera_pll_i}
set pll_video {ic|u_pll_video|altera_pll_i}
set clk          [get_clocks -nowarn "${pll_core}|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk_cpu      [get_clocks -nowarn "${pll_core}|general\[1\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk_sdram_ps [get_clocks -nowarn "${pll_core}|general\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk_vid      [get_clocks -nowarn "${pll_video}|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk_pix      [get_clocks -nowarn "${pll_video}|general\[1\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk_pix90    [get_clocks -nowarn "${pll_video}|general\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"]

# An empty collection turns set_clock_groups and set_multicycle_path into
# silent no-ops and the build "passes" untimed. Here that is an error.
foreach {name c} [list clk $clk clk_cpu $clk_cpu sdram_ps $clk_sdram_ps \
                       vid $clk_vid pix $clk_pix pix90 $clk_pix90] {
    if {[get_collection_size $c] == 0} {
        post_message -type error "core_constraints.sdc: PLL output '$name' not found. The constraints below would be no-ops; fix the path."
    }
}

# The SDRAM clock as the device sees it: clk_sdram_ps, forwarded through the
# DDIO output register in core_top (pin_ddio_clk, data 1/0) to the dram_clk
# pin. Quartus traces the path from the PLL counter through the I/O cell, so
# the pin-side clock carries the real output delay and the I/O constraints
# below are relative to the clock edge at the pin.
create_generated_clock -name dram_clk_pin \
    -source [get_pins "${pll_core}|general\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"] \
    [get_ports {dram_clk}]

# ---------------------------------------------------------- clock groups
#
# clk_74a (bridge, pad bus, I2S) is the PLLs' reference but is treated as
# unrelated to their outputs, and every path between them crosses through a
# synchroniser, a dcfifo or a dual-clock RAM (core_top.v lists them).
#
# Each PLL's outputs are ONE group and are timed against each other:
#
#   core    96 <-> 32: upstream's data freezers between the memories and the
#           68000 side rely on the 3:1 pair being phase-aligned, as are the
#           shell's resets, game id and diagnostics crossing on a register.
#           96 -> pin: the SDRAM I/O below, against dram_clk_pin.
#   video   28 -> 7: pocket_video's `hold` (28 MHz, loaded on ce_pix) is
#           sampled on every 7 MHz edge, and every 7 MHz edge coincides with
#           a 28 MHz edge, so it is a normal synchronous path; timing it is
#           what makes "a 7 MHz edge on the reload edge sees the old pixel"
#           true in silicon.
#
# The two PLLs are unrelated to each other, as upstream's system and video
# PLLs were: the board crosses between 96/32 and 28 MHz through its own
# FIFOs and synchronisers (the tile ROM crossings, the line buffer, the
# register mirrors), the shell through synch_3 and pocket_sync_bus.
set_clock_groups -asynchronous \
    -group [get_clocks {clk_74a}] \
    -group [get_clocks {clk_74b}] \
    -group [get_clocks {bridge_spiclk}] \
    -group [add_to_collection [get_clocks "${pll_core}|*"] [get_clocks {dram_clk_pin}]] \
    -group [get_clocks "${pll_video}|*"]

# ---------------------------------------------------------------- game id
# The game id (core_top's s_game96) is set before the board leaves reset and a
# change resets it again, so it is a constant while the board runs; the board
# reads it in all three of its domains (the YMZ280B's rate, the game's memory
# map, the layers' formats).
set_false_path -from [get_registers {*|s_game96|q*}]

# ---------------------------------------------------------------- fx68k
# The microcode paths, as upstream's constraints give them (the fit project's
# too): the decoder has two cycles of the 68000's phase enables to settle.
set_multicycle_path -start -setup -from [get_keepers *fx68k:*|Ir[*]] -to [get_keepers *fx68k:*|microAddr[*]] 2
set_multicycle_path -start -hold  -from [get_keepers *fx68k:*|Ir[*]] -to [get_keepers *fx68k:*|microAddr[*]] 1
set_multicycle_path -start -setup -from [get_keepers *fx68k:*|Ir[*]] -to [get_keepers *fx68k:*|nanoAddr[*]] 2
set_multicycle_path -start -hold  -from [get_keepers *fx68k:*|Ir[*]] -to [get_keepers *fx68k:*|nanoAddr[*]] 1
set_multicycle_path -start -setup -from {*|nanoLatch[*]}        -to {*|excUnit|alu|pswCcr[*]} 2
set_multicycle_path -start -hold  -from {*|nanoLatch[*]}        -to {*|excUnit|alu|pswCcr[*]} 1
set_multicycle_path -start -setup -from {*|excUnit|alu|oper[*]} -to {*|excUnit|alu|pswCcr[*]} 2
set_multicycle_path -start -hold  -from {*|excUnit|alu|oper[*]} -to {*|excUnit|alu|pswCcr[*]} 1

# ------------------------------------------------------------------ SDRAM
#
# AS4C32M16MSA-6 (1.8 V mobile SDR). Figures from the -6 grade of the same
# family's sheet (AS4C16M16MSA-6, Rev 1.0), CL = 2 as kaneko_sdram programs:
#
#   tCMS/tCAS  command/address setup  2.0 ns     tCMH/tCAH  hold  1.0 ns
#   tCDS       data-in setup          2.0 ns     tCDH       hold  1.0 ns
#   tAC(2)     access from clock      6.0 ns max tOH        hold  2.5 ns min
#
# Board traces are short (the SDRAM sits beside the FPGA); 0.2 ns allowed for
# a flight each way.
set sdr_trace 0.2

set sdr_out [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_dq[*]}]
set_output_delay -clock dram_clk_pin -max [expr {2.0 + $sdr_trace}] $sdr_out
set_output_delay -clock dram_clk_pin -min [expr {-1.0}]              $sdr_out

# Commands leave on a clk edge and are sampled by the device on the next
# dram_clk_pin edge, half a period later. That is the default relationship, so
# no exception is needed for outputs.

# READ DATA, A TWO-CYCLE PATH. Data appears tAC after a device clock edge,
# and the device clock is half a period behind clk plus the I/O cell's output
# delay; it is latched one full cycle after the default edge. On the Pocket
# the controller samples one edge earlier than this paper figure (CL+2,
# measured; core_top.v), and this constraint keeps the input path itself
# timed the same way from one fit to the next.
set_input_delay -clock dram_clk_pin -max [expr {6.0 + 2 * $sdr_trace}] [get_ports {dram_dq[*]}]
set_input_delay -clock dram_clk_pin -min 2.5                           [get_ports {dram_dq[*]}]
set_multicycle_path -from [get_clocks {dram_clk_pin}] -to $clk -setup -end 2
set_multicycle_path -from [get_clocks {dram_clk_pin}] -to $clk -hold  -end 1

# CKE is a constant 1 from kaneko_sdram; it has no timing to meet.
set_false_path -to [get_ports {dram_cke}]

# ------------------------------------------------------------ PSRAM, SRAM
#
# The PSRAMs are clocked at 48 MHz by a register toggling beside the other
# pins (pocket_psram_rows): every pin changes a whole 96 MHz period (10.4 ns)
# before the part samples it on cram_clk's rise and holds 10.4 ns after,
# against the part's 3 ns setup and 2 ns hold, and read data is captured
# 20.8 ns after the edge that launched the rise, inside a window from about
# 9 ns + the round trip to 22.8 ns + the round trip. Those margins are
# cycles, not picoseconds, and the fitter is told not to second-guess them;
# the latencies are measured on the part at power-up and shown on the
# overlay. The SRAM is not used (its pins are held).
set_false_path -to   [get_ports {cram0_* cram1_*}]
set_false_path -from [get_ports {cram0_dq[*] cram1_dq[*] cram0_wait cram1_wait}]
set_false_path -to   [get_ports {sram_a[*] sram_dq[*] sram_oe_n sram_we_n sram_ub_n sram_lb_n}]
set_false_path -from [get_ports {sram_dq[*]}]
