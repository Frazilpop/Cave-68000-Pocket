# The board alone on the Pocket's part, behind the shell's clocks: the
# 74.25 MHz reference on its pin, two PLLs (cave_fit_top.sv) making 96 and
# 32 MHz on one VCO and 28 MHz on another.
create_clock -name clk_74a -period 13.468 [get_ports clk_74a]
derive_pll_clocks
derive_clock_uncertainty

# PLL A's outputs are one group, timed against each other (the 3:1 pair is
# phase-aligned and the data freezers between 96 and 32 MHz rely on it);
# PLL B's 28 MHz and the reference are unrelated to them, crossed only by
# FIFOs and synchronisers.
set_clock_groups -asynchronous \
    -group [get_clocks {clk_74a}] \
    -group [get_clocks {pll_a|*}] \
    -group [get_clocks {pll_b|*}]

# fx68k's microcode paths, as upstream's constraints give them
set_multicycle_path -start -setup -from [get_keepers *fx68k:*|Ir[*]] -to [get_keepers *fx68k:*|microAddr[*]] 2
set_multicycle_path -start -hold  -from [get_keepers *fx68k:*|Ir[*]] -to [get_keepers *fx68k:*|microAddr[*]] 1
set_multicycle_path -start -setup -from [get_keepers *fx68k:*|Ir[*]] -to [get_keepers *fx68k:*|nanoAddr[*]] 2
set_multicycle_path -start -hold  -from [get_keepers *fx68k:*|Ir[*]] -to [get_keepers *fx68k:*|nanoAddr[*]] 1
set_multicycle_path -start -setup -from {*|nanoLatch[*]}        -to {*|excUnit|alu|pswCcr[*]} 2
set_multicycle_path -start -hold  -from {*|nanoLatch[*]}        -to {*|excUnit|alu|pswCcr[*]} 1
set_multicycle_path -start -setup -from {*|excUnit|alu|oper[*]} -to {*|excUnit|alu|pswCcr[*]} 2
set_multicycle_path -start -hold  -from {*|excUnit|alu|oper[*]} -to {*|excUnit|alu|pswCcr[*]} 1
