// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the board alone, with the shell's clocks
//
// The fit project's top: cave68000 behind the two PLLs the Pocket shell will
// have, so the Timing Analyzer sees the real clocks and the real skew between
// them. Every other port is a virtual pin.
//
//   PLL A, from clk_74a: 96 MHz (the memories, sprites, frame buffer) and
//          32 MHz (the 68000 side) – one VCO, 864 MHz = 74.25 x 128 / 11,
//          so the two are integer divides of it (/9 and /27) and the 3:1
//          pair is phase-aligned, which the data freezers between them rely on.
//   PLL B, from clk_74a: 28 MHz (the layers and video timing) – its own VCO,
//          756 MHz = 74.25 x 112 / 11, /27. Unrelated to PLL A, as
//          upstream's video PLL is; the crossings are FIFOs and synchronisers.

`default_nettype none

module cave_fit_top (
  input  wire        clk_74a,

  input  wire        rst, rst_cpu, rst_vid,
  input  wire        rom_loaded,
  input  wire [2:0]  game,
  input  wire [7:0]  p1, p2,
  input  wire [1:0]  coin, start,
  input  wire        service, pause,
  input  wire [15:0] dsw,

  output wire        prog_rd,  output wire [24:0] prog_addr, input wire [15:0] prog_dout, input wire prog_wait_n, input wire prog_valid,
  output wire        snd_rd,   output wire [24:0] snd_addr,  input wire [15:0] snd_dout,  input wire snd_wait_n,  input wire snd_valid,
  output wire [2:0]  tile_rd,  output wire [74:0] tile_addr, input wire [47:0] tile_dout, input wire [2:0] tile_wait_n, input wire [2:0] tile_valid,
  output wire        spr_rd,   output wire [31:0] spr_addr,  input wire [63:0] spr_dout,  input wire spr_wait_n,  input wire spr_valid,
  output wire [7:0]  spr_burst_len, input wire spr_burst_done,
  output wire        fbr_rd, output wire [31:0] fbr_addr, input wire [63:0] fbr_dout, input wire fbr_wait_n, input wire fbr_valid, input wire fbr_burst_done,
  output wire        fb_wr, output wire [31:0] fb_addr, output wire [7:0] fb_mask, output wire [63:0] fb_din,
  input  wire        fb_wait_n, output wire [7:0] fb_burst_len, input wire fb_burst_done,
  output wire        ee_rd, ee_wr, output wire [6:0] ee_addr, output wire [15:0] ee_din, input wire [15:0] ee_dout, input wire ee_wait_n, input wire ee_valid,

  output wire        ce_pix, hs, vs, hblank, vblank, de,
  output wire [7:0]  r, g, b,
  output wire [15:0] snd
);

  wire clk, clk_cpu, clk_vid;

  altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("74.25 MHz"),
    .operation_mode("normal"),
    .number_of_clocks(2),
    .output_clock_frequency0("96.000000 MHz"), .phase_shift0("0 ps"), .duty_cycle0(50),
    .output_clock_frequency1("32.000000 MHz"), .phase_shift1("0 ps"), .duty_cycle1(50),
    .pll_type("General"),
    .pll_subtype("General")
  ) pll_a (
    .rst      (1'b0),
    .outclk   ({clk_cpu, clk}),
    .locked   (),
    .fboutclk (),
    .fbclk    (1'b0),
    .refclk   (clk_74a)
  );

  altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("74.25 MHz"),
    .operation_mode("normal"),
    .number_of_clocks(1),
    .output_clock_frequency0("28.000000 MHz"), .phase_shift0("0 ps"), .duty_cycle0(50),
    .pll_type("General"),
    .pll_subtype("General")
  ) pll_b (
    .rst      (1'b0),
    .outclk   (clk_vid),
    .locked   (),
    .fboutclk (),
    .fbclk    (1'b0),
    .refclk   (clk_74a)
  );

  cave68000 board (
    .clk (clk), .rst (rst), .clk_cpu (clk_cpu), .rst_cpu (rst_cpu), .clk_vid (clk_vid), .rst_vid (rst_vid),
    .rom_loaded (rom_loaded), .game (game),
    .p1 (p1), .p2 (p2), .coin (coin), .start (start), .service (service), .pause (pause), .dsw (dsw),
    .prog_rd (prog_rd), .prog_addr (prog_addr), .prog_dout (prog_dout), .prog_wait_n (prog_wait_n), .prog_valid (prog_valid),
    .snd_rd (snd_rd), .snd_addr (snd_addr), .snd_dout (snd_dout), .snd_wait_n (snd_wait_n), .snd_valid (snd_valid),
    .tile_rd (tile_rd), .tile_addr (tile_addr), .tile_dout (tile_dout), .tile_wait_n (tile_wait_n), .tile_valid (tile_valid),
    .spr_rd (spr_rd), .spr_addr (spr_addr), .spr_dout (spr_dout), .spr_wait_n (spr_wait_n), .spr_valid (spr_valid),
    .spr_burst_len (spr_burst_len), .spr_burst_done (spr_burst_done),
    .fbr_rd (fbr_rd), .fbr_addr (fbr_addr), .fbr_dout (fbr_dout), .fbr_wait_n (fbr_wait_n), .fbr_valid (fbr_valid), .fbr_burst_done (fbr_burst_done),
    .fb_wr (fb_wr), .fb_addr (fb_addr), .fb_mask (fb_mask), .fb_din (fb_din),
    .fb_wait_n (fb_wait_n), .fb_burst_len (fb_burst_len), .fb_burst_done (fb_burst_done),
    .ee_rd (ee_rd), .ee_wr (ee_wr), .ee_addr (ee_addr), .ee_din (ee_din), .ee_dout (ee_dout), .ee_wait_n (ee_wait_n), .ee_valid (ee_valid),
    .ce_pix (ce_pix), .hs (hs), .vs (vs), .hblank (hblank), .vblank (vblank), .de (de), .r (r), .g (g), .b (b),
    .snd (snd), .snd_sample (), .snd_overrun (), .spr_swap ()
  );

endmodule

`default_nettype wire
