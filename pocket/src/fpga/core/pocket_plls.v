// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the two PLLs
//
// Both from the 74.25 MHz reference (clk_74a), each on a VCO whose outputs
// are integer divides of it, so the clocks that meet inside one PLL are
// phase-aligned and are timed against each other (core_constraints.sdc):
//
//   pocket_pll_core, VCO 864 MHz = 74.25 x 128 / 11
//     clk           96 MHz  /9   the memories, the sprite processor, the
//                                frame buffer, the loader
//     clk_cpu       32 MHz  /27  the 68000 side and the YMZ280B; 3:1 with
//                                clk, rising together, which upstream's data
//                                freezers between the two rely on
//     clk_sdram_ps  96 MHz  /9, 180 degrees: forwarded to dram_clk
//
//   pocket_pll_video, VCO 756 MHz = 74.25 x 112 / 11
//     clk_vid       28 MHz  /27  the layers, the mixer and the video timing
//     clk_pix        7 MHz  /108 APF's video bus (the board's pixel rate)
//     clk_pix90      7 MHz  /108, 90 degrees: APF's DDR video clock
//
// The board's crossings between the two PLLs are upstream's (FIFOs and
// synchronisers): its video PLL was unrelated to its system clocks too.
// Written as altera_pll instances, as the wizard's mf_pllbase is, with the
// instance named altera_pll_i so the clock paths read the same.

`default_nettype none

module pocket_pll_core (
    input  wire refclk,
    output wire clk,
    output wire clk_cpu,
    output wire clk_sdram_ps,
    output wire locked
);
    altera_pll #(
        .fractional_vco_multiplier ("false"),
        .reference_clock_frequency ("74.25 MHz"),
        .operation_mode            ("normal"),
        .number_of_clocks          (3),
        .output_clock_frequency0   ("96.000000 MHz"), .phase_shift0 ("0 ps"),    .duty_cycle0 (50),
        .output_clock_frequency1   ("32.000000 MHz"), .phase_shift1 ("0 ps"),    .duty_cycle1 (50),
        .output_clock_frequency2   ("96.000000 MHz"), .phase_shift2 ("5208 ps"), .duty_cycle2 (50),
        .pll_type                  ("General"),
        .pll_subtype               ("General")
    ) altera_pll_i (
        .rst      (1'b0),
        .outclk   ({clk_sdram_ps, clk_cpu, clk}),
        .locked   (locked),
        .fboutclk (),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );
endmodule

module pocket_pll_video (
    input  wire refclk,
    output wire clk_vid,
    output wire clk_pix,
    output wire clk_pix90,
    output wire locked
);
    altera_pll #(
        .fractional_vco_multiplier ("false"),
        .reference_clock_frequency ("74.25 MHz"),
        .operation_mode            ("normal"),
        .number_of_clocks          (3),
        .output_clock_frequency0   ("28.000000 MHz"), .phase_shift0 ("0 ps"),     .duty_cycle0 (50),
        .output_clock_frequency1   ("7.000000 MHz"),  .phase_shift1 ("0 ps"),     .duty_cycle1 (50),
        .output_clock_frequency2   ("7.000000 MHz"),  .phase_shift2 ("35714 ps"), .duty_cycle2 (50),
        .pll_type                  ("General"),
        .pll_subtype               ("General")
    ) altera_pll_i (
        .rst      (1'b0),
        .outclk   ({clk_pix90, clk_pix, clk_vid}),
        .locked   (locked),
        .fboutclk (),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );
endmodule

`default_nettype wire
