// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the board with its memory adapters
//
// cave68000 speaks upstream's memory protocols (INTERFACES: "Upstream's
// protocols as the board has them now"). This puts the adapters round it so
// that what comes out are the Pocket's own ports, and nothing else changes:
//
//   rom   seven read ports for kaneko_sdram, one 64-bit line a request:
//         0 the program, 1 the YMZ280B's samples (DonPachi's OKIs'), 2-4 the three layers'
//         tiles (each through upstream's cache, cave_line_port), 5-6 the
//         sprite tiles (cave_spr_port, a tile's 16 or 32 lines on two ports
//         in turn). Addresses are whole-image word addresses: the region
//         offsets (CaveGameConfig) are added here, as upstream's MemSys did.
//   row   the sprite frame buffer, one 16-word row at a time, page 0 on
//         chip 0 and page 1 on chip 1 (cave_fb_rows).
//   dl    the loader's stream past the SDRAM, for the EEPROM's seed.
//   nv    the 93C46's store for the save slot (cave_eeprom_store).
//
// Platform-neutral like the board: the Pocket shell serves these ports with
// kaneko_sdram and the PSRAM servants, the simulation harness
// (sim/ddonpach/cave68000_psim.sv) with the same controller and models of
// the parts. Everything here runs on clk.

`default_nettype none

module cave68000_mem #(
  parameter int unsigned AW = 25,       // SDRAM word address [AW:1]
  parameter int unsigned SPR_PORTS = 2  // the sprite tiles on one port or two
) (
  input  wire          clk,             // 96 MHz
  input  wire          rst,
  input  wire          clk_cpu,         // 32 MHz
  input  wire          rst_cpu,
  input  wire          clk_vid,         // 28 MHz
  input  wire          rst_vid,

  input  wire          rom_loaded,
  input  wire [2:0]    game,

  input  wire [7:0]    p1, p2,
  input  wire [1:0]    coin, start,
  input  wire          service,
  input  wire          pause,
  input  wire [15:0]   dsw,

  // kaneko_sdram's read ports
  output wire [6:0]    rom_req,
  output wire [7*AW-1:0] rom_addr,      // port p at [AW*p +: AW]
  input  wire [6:0]    rom_ack,
  input  wire [7*64-1:0] rom_dout,      // port p at [64*p +: 64]

  // the frame buffer's two chips
  output wire [1:0]    row_req,
  output wire [1:0]    row_we,
  output wire [43:0]   row_addr,
  output wire [255:0]  row_wdata,        // both chips: one row write at a time
  output wire [31:0]   row_wmask,
  input  wire [1:0]    row_ack,
  input  wire [511:0]  row_rdata,

  // the loader's stream
  input  wire          dl_wr,
  input  wire [AW:1]   dl_addr,
  input  wire [15:0]   dl_data,

  // the save slot
  input  wire [5:0]    nv_addr,
  input  wire [15:0]   nv_din,
  input  wire          nv_we,
  output wire [15:0]   nv_dout,
  output wire          nv_dirty,
  input  wire          nv_dirty_clr,

  // video, on clk_vid
  output wire          ce_pix,
  output wire          hs, vs, hblank, vblank, de,
  output wire [7:0]    r, g, b,

  // audio, on clk_cpu
  output wire [15:0]   snd,
  output wire          snd_sample,
  output wire          snd_overrun,

  // diagnostics
  output wire          spr_swap,         // clk_cpu: the sprite page swap
  output wire          cpu_as,           // clk_cpu: the 68000's address strobe
  input  wire          diag_clr,         // clk: peaks back to zero
  output wire [15:0]   fb_rows_written,
  output wire [15:0]   fb_rows_read,
  output wire [15:0]   fb_rd_wait_max    // longest a line read waited for its first row
);

  // ------------------------------------------------------ region offsets
  wire [31:0] off_ee, off_snd, off_l0, off_l1, off_l2, off_spr;
  CaveGameConfig cfg (
    .game_index (game == 3'd7 ? 4'd1 : {1'b0, game}),
    .granularity (), .eeprom_offset (off_ee), .sound_0_device (),
    .sound_0_rom_offset (off_snd), .sound_1_rom_offset (), .sound_2_rom_offset (),
    .layer_0_format (), .layer_0_rom_offset (off_l0), .layer_0_palette_bank (),
    .layer_1_format (), .layer_1_rom_offset (off_l1), .layer_1_palette_bank (),
    .layer_2_format (), .layer_2_rom_offset (off_l2), .pwrinst2_layer_2_rom_offset (),
    .layer_2_palette_bank (), .sprite_format (), .sprite_rom_offset (off_spr),
    .sprite_zoom ()
  );

  // --------------------------------------------------------------- board
  wire        prog_rd, snd_rd, spr_rd;
  wire [24:0] prog_a, snd_a;
  wire [74:0] tile_a;
  wire [2:0]  tile_rd;
  wire [31:0] spr_a;
  wire [7:0]  spr_len;
  wire [15:0] prog_dout, snd_dout;
  wire [47:0] tile_dout;
  wire        prog_wait_n, snd_wait_n, prog_valid, snd_valid;
  wire [2:0]  tile_wait_n, tile_valid;
  wire [63:0] spr_dout;
  wire        spr_wait_n, spr_valid, spr_done;

  wire        fbr_rd, fbr_wait_n, fbr_valid, fbr_done;
  wire [31:0] fbr_addr;
  wire [63:0] fbr_dout;
  wire        fb_wr, fb_wait_n, fb_done;
  wire [31:0] fb_addr;
  wire [7:0]  fb_mask, fb_len;
  wire [63:0] fb_din;

  wire        ee_rd, ee_wr, ee_valid;
  wire [6:0]  ee_addr;
  wire [15:0] ee_din, ee_dout;

  cave68000 board (
    .clk (clk), .rst (rst), .clk_cpu (clk_cpu), .rst_cpu (rst_cpu),
    .clk_vid (clk_vid), .rst_vid (rst_vid),
    .rom_loaded (rom_loaded), .game (game),
    .p1 (p1), .p2 (p2), .coin (coin), .start (start),
    .service (service), .pause (pause), .dsw (dsw),
    .prog_rd (prog_rd), .prog_addr (prog_a), .prog_dout (prog_dout),
    .prog_wait_n (prog_wait_n), .prog_valid (prog_valid),
    .snd_rd (snd_rd), .snd_addr (snd_a), .snd_dout (snd_dout),
    .snd_wait_n (snd_wait_n), .snd_valid (snd_valid),
    .tile_rd (tile_rd), .tile_addr (tile_a), .tile_dout (tile_dout),
    .tile_wait_n (tile_wait_n), .tile_valid (tile_valid),
    .spr_rd (spr_rd), .spr_addr (spr_a), .spr_dout (spr_dout),
    .spr_wait_n (spr_wait_n), .spr_valid (spr_valid),
    .spr_burst_len (spr_len), .spr_burst_done (spr_done),
    .fbr_rd (fbr_rd), .fbr_addr (fbr_addr), .fbr_dout (fbr_dout),
    .fbr_wait_n (fbr_wait_n), .fbr_valid (fbr_valid), .fbr_burst_done (fbr_done),
    .fb_wr (fb_wr), .fb_addr (fb_addr), .fb_mask (fb_mask), .fb_din (fb_din),
    .fb_wait_n (fb_wait_n), .fb_burst_len (fb_len), .fb_burst_done (fb_done),
    .ee_rd (ee_rd), .ee_wr (ee_wr), .ee_addr (ee_addr), .ee_din (ee_din),
    .ee_dout (ee_dout), .ee_wait_n (1'b1), .ee_valid (ee_valid),
    .ce_pix (ce_pix), .hs (hs), .vs (vs), .hblank (hblank), .vblank (vblank), .de (de),
    .r (r), .g (g), .b (b), .snd (snd), .snd_sample (snd_sample), .snd_overrun (snd_overrun),
    .spr_swap (spr_swap), .cpu_as (cpu_as)
  );

  // ------------------------------------------------------ the five caches
  wire [4:0]   l_rd    = {tile_rd, snd_rd, prog_rd};
  wire [159:0] l_addr  = {{7'd0, tile_a[50 +: 25]} + off_l2,
                          {7'd0, tile_a[25 +: 25]} + off_l1,
                          {7'd0, tile_a[ 0 +: 25]} + off_l0,
                          {7'd0, snd_a} + off_snd,
                          {7'd0, prog_a}};
  wire [4:0]   l_wait_n, l_valid;
  wire [79:0]  l_dout;

  assign prog_wait_n = l_wait_n[0];
  assign prog_valid  = l_valid[0];
  assign prog_dout   = l_dout[0 +: 16];
  assign snd_wait_n  = l_wait_n[1];
  assign snd_valid   = l_valid[1];
  assign snd_dout    = l_dout[16 +: 16];
  assign tile_wait_n = l_wait_n[4:2];
  assign tile_valid  = l_valid[4:2];
  assign tile_dout   = l_dout[32 +: 48];

  genvar i;
  generate
    for (i = 0; i < 5; i = i + 1) begin : line
      cave_line_port #(.AW (AW)) port (
        .clk (clk), .rst (rst),
        .rd (l_rd[i]), .addr (l_addr[32*i +: 32]), .wait_n (l_wait_n[i]),
        .valid (l_valid[i]), .dout (l_dout[16*i +: 16]),
        .req (rom_req[i]), .req_addr (rom_addr[AW*i +: AW]),
        .ack (rom_ack[i]), .line (rom_dout[64*i +: 64])
      );
    end
  endgenerate

  // ----------------------------------------------------- the sprite tiles
  cave_spr_port #(.AW (AW), .PORTS (SPR_PORTS)) spr (
    .clk (clk), .rst (rst),
    .rd (spr_rd), .addr (spr_a + off_spr), .burst_len (spr_len),
    .wait_n (spr_wait_n), .valid (spr_valid), .dout (spr_dout), .burst_done (spr_done),
    .req (rom_req[6:5]), .req_addr (rom_addr[5*AW +: 2*AW]),
    .ack (rom_ack[6:5]), .line (rom_dout[5*64 +: 128])
  );

  // ---------------------------------------------------- the frame buffer
  cave_fb_rows fb (
    .clk (clk), .rst (rst),
    .rd (fbr_rd), .rd_addr (fbr_addr), .rd_dout (fbr_dout), .rd_wait_n (fbr_wait_n),
    .rd_valid (fbr_valid), .rd_burst_done (fbr_done),
    .wr (fb_wr), .wr_addr (fb_addr), .wr_mask (fb_mask), .wr_din (fb_din),
    .wr_burst_len (fb_len), .wr_wait_n (fb_wait_n), .wr_burst_done (fb_done),
    .row_req (row_req), .row_we (row_we), .row_addr (row_addr),
    .row_wdata (row_wdata), .row_wmask (row_wmask),
    .row_ack (row_ack), .row_rdata (row_rdata),
    .rows_written (fb_rows_written), .rows_read (fb_rows_read),
    .rd_wait_max (fb_rd_wait_max), .diag_clr (diag_clr)
  );

  // ----------------------------------------------------------- the 93C46
  cave_eeprom_store #(.AW(AW)) ee (
    .clk (clk), .rst (rst),
    .eeprom_offset (off_ee), .has_eeprom (game != 3'd6),
    .dl_wr (dl_wr), .dl_addr (dl_addr), .dl_data (dl_data),
    .ee_rd (ee_rd), .ee_wr (ee_wr), .ee_addr (ee_addr), .ee_din (ee_din),
    .ee_dout (ee_dout), .ee_valid (ee_valid),
    .nv_addr (nv_addr), .nv_din (nv_din), .nv_we (nv_we), .nv_dout (nv_dout),
    .nv_dirty (nv_dirty), .nv_dirty_clr (nv_dirty_clr)
  );

endmodule

`default_nettype wire
