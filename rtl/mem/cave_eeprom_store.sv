// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the 93C46's 64 x 16 store, on chip
//
// Upstream kept the EEPROM's contents in SDRAM behind a write-back cache and
// seeded it from the MRA; the board (EEPROM.sv) reads and writes it through
// the `ee` port: a byte address {word, 0}, a read answered the next clock.
// Here the store is a dual-port block RAM, the board on one port and the
// platform on the other, and it is filled twice over at boot, in the order
// APF loads the data slots:
//
//   1. as the loader streams the ROM image past (dl_*), the EEPROM region
//      (128 bytes at the game's eeprom_offset) is copied in: the factory
//      contents MAME's zip carries, which is what a first boot starts from;
//   2. a save file, if there is one, is written over it through the nv port
//      (pocket_nvram, which also reads the store back out at shutdown).
//
// Both happen with the board held in reset, so the platform's port has the
// seed and the save to itself; its reads (pocket_nvram's scanner) take the
// port whenever neither writes.
//
// Word order. The board's words are the region's bytes big-endian, word
// n = [2n] << 8 | [2n + 1], as MAME loads a 93C46 from its zip and as
// upstream's cache swapped them; the loader's words are the image's,
// little-endian, so the seed swaps each. The nv port swaps too, so a save
// file is byte for byte the zip's EEPROM file for the same set (pocket_nvram
// puts word w at file bytes {2w + 1, 2w}); MAME's own .nv has each pair of
// bytes swapped.
//
// nv_dirty rises when the game writes a word.

`default_nettype none

module cave_eeprom_store #(
  parameter int unsigned AW = 25       // the loader's word address [AW:1]: the whole SDRAM
) (
  input  wire         clk,
  input  wire         rst,

  input  wire [31:0]  eeprom_offset,     // byte offset of the region in the image
  input  wire         has_eeprom,

  // the loader's stream: one 16-bit word of the image, at a word address
  input  wire         dl_wr,
  input  wire [AW:1]  dl_addr,
  input  wire [15:0]  dl_data,

  // the board's side (upstream's ee port)
  input  wire         ee_rd,
  input  wire         ee_wr,
  input  wire [6:0]   ee_addr,
  input  wire [15:0]  ee_din,
  output reg  [15:0]  ee_dout,
  output reg          ee_valid,

  // the platform's save slot
  input  wire [5:0]   nv_addr,
  input  wire [15:0]  nv_din,
  input  wire         nv_we,
  output wire [15:0]  nv_dout,
  output reg          nv_dirty,
  input  wire         nv_dirty_clr
);

  reg [15:0] mem [0:63];

  // The whole address is compared: an image larger than 32 MB (esprade's
  // 43, guwange's 55) passes the region's address modulo 32 MB again, and a
  // narrower compare took those sprite words as the seed.
  wire [AW:1] seed_base = eeprom_offset[AW:1];
  wire [AW:1] seed_rel  = dl_addr - seed_base;
  wire        seed_hit  = has_eeprom && dl_wr && (dl_addr >= seed_base) && (seed_rel < 64);

  // ------------------------------------------------------- board's port
  wire [5:0] ee_w = ee_addr[6:1];
  always @(posedge clk) begin
    if (ee_wr) mem[ee_w] <= ee_din;
    ee_dout <= mem[ee_w];
  end

  always @(posedge clk) begin
    ee_valid <= ee_rd && !rst;
    if (rst)               nv_dirty <= 1'b0;
    else if (ee_wr)        nv_dirty <= 1'b1;
    else if (nv_dirty_clr) nv_dirty <= 1'b0;
  end

  // ---------------------------------------------------- platform's port
  wire        b_we   = seed_hit || nv_we;
  wire [5:0]  b_addr = seed_hit ? seed_rel[6:1] : nv_addr;
  wire [15:0] b_din  = seed_hit ? {dl_data[7:0], dl_data[15:8]} : {nv_din[7:0], nv_din[15:8]};
  reg  [15:0] b_q;
  always @(posedge clk) begin
    if (b_we) mem[b_addr] <= b_din;
    b_q <= mem[b_addr];
  end
  assign nv_dout = {b_q[7:0], b_q[15:8]};

endmodule

`default_nettype wire
