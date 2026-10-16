// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the board
//
// Platform-neutral: no pins, no framework. The Pocket shell (pocket/) and the
// simulation harness (sim/ddonpach/) both host this module. It is what
// upstream's Cave.sv wired for MiSTer, with the MiSTer side taken away: the
// DDR and SDRAM memory system, the rotation frame buffer, the savestates,
// the high-score manager, the DonPachi and Power Instinct 2 sound hardware.
// Every memory the board reads or draws into is a port here, in upstream's
// own protocols for now (the ROM caches' SDRAM side, the sprite processor's
// burst reads, the sprite frame buffer's DDR-style queue); the platform
// serves them. docs/pocket/INTERFACES.md is the contract and changes with
// these ports.
//
// What is on the board (cave.cpp, the YMZ280B machines):
//
//   68000 @ 16 MHz        fx68k on clk_cpu with 16 MHz phase enables (Main)
//   038 tilemaps x 3      CaveLayerProcessor, on clk_vid
//   013 sprites           SpriteProcessor / Blitter / Decoder on clk, into
//                         the frame buffer the platform keeps
//   YMZ280B               Sound, on clk_cpu; built with CAVE_OKI defined,
//                         DonPachi's two OKI M6295s and NMK112 instead
//                         (SoundOki), the board then playing DonPachi alone;
//                         built with CAVE_Z80, Air Gallet's and Sailor Moon's
//                         Z80 sound board (for now a stand-in that never
//                         replies), the board playing those two alone
//   93C46                 EEPROM, inside Main; its 64 x 16 store is a port
//   palette, VRAMs, sprite RAM, work RAM   on chip, inside Main
//
// Three clocks, as upstream: clk (96 MHz) for the memories, the sprite
// processor and the frame buffer; clk_cpu (32 MHz) for the 68000 side and
// the sound; clk_vid (28 MHz) for the layers, mixer and timing, with a 7 MHz
// pixel enable. The crossings between them are upstream's.

`default_nettype none

module cave68000 (
  input  wire        clk,            // 96 MHz
  input  wire        rst,
  input  wire        clk_cpu,        // 32 MHz
  input  wire        rst_cpu,
  input  wire        clk_vid,        // 28 MHz
  input  wire        rst_vid,

  input  wire        rom_loaded,     // the memories hold the image; releases the 68000
  input  wire [3:0]  game,           // CaveGameConfig's index: 0 feversos, 1 ddonpach, 3 esprade, 4 uopoko, 5 guwange, 6 gaia (2 donpachi, 9 agallet, 10 sailormn on their own bitstreams)

  // Inputs
  input  wire [7:0]  p1, p2,         // {b4,b3,b2,b1,right,left,down,up} active high
  input  wire [1:0]  coin, start,
  input  wire        service,        // Test Mode: the service DIP
  input  wire        pause,
  input  wire [15:0] dsw,            // gaia / theroes DSW as MAME's port (active low)

  // Program ROM, after its cache (16-bit words of the image)
  output wire        prog_rd,
  output wire [24:0] prog_addr,
  input  wire [15:0] prog_dout,
  input  wire        prog_wait_n,
  input  wire        prog_valid,

  // YMZ280B sample ROM, after its cache
  output wire        snd_rd,
  output wire [24:0] snd_addr,
  input  wire [15:0] snd_dout,
  input  wire        snd_wait_n,
  input  wire        snd_valid,

  // The three layers' tile ROM, after their caches
  output wire [2:0]  tile_rd,
  output wire [74:0] tile_addr,      // layer k at [25k +: 25]
  input  wire [47:0] tile_dout,      // layer k at [16k +: 16]
  input  wire [2:0]  tile_wait_n,
  input  wire [2:0]  tile_valid,

  // Sprite tile ROM: one burst of 16 or 32 64-bit words per tile
  output wire        spr_rd,
  output wire [31:0] spr_addr,       // byte address within the sprite region
  input  wire [63:0] spr_dout,
  input  wire        spr_wait_n,
  input  wire        spr_valid,
  output wire [7:0]  spr_burst_len,
  input  wire        spr_burst_done,

  // Sprite frame buffer, as upstream queued it for DDR: the scan-out's line
  // reads (16-beat bursts) on a port of their own, and the clear and the
  // blitter's masked 64-bit writes on the other
  output wire        fbr_rd,
  output wire [31:0] fbr_addr,
  input  wire [63:0] fbr_dout,
  input  wire        fbr_wait_n,
  input  wire        fbr_valid,
  input  wire        fbr_burst_done,
  output wire        fb_wr,
  output wire [31:0] fb_addr,
  output wire [7:0]  fb_mask,
  output wire [63:0] fb_din,
  input  wire        fb_wait_n,
  output wire [7:0]  fb_burst_len,
  input  wire        fb_burst_done,

  // The 93C46's 64 x 16 store
  output wire        ee_rd,
  output wire        ee_wr,
  output wire [6:0]  ee_addr,
  output wire [15:0] ee_din,
  input  wire [15:0] ee_dout,
  input  wire        ee_wait_n,
  input  wire        ee_valid,

  // Video, on clk_vid
  output wire        ce_pix,
  output wire        hs, vs, hblank, vblank, de,
  output wire [7:0]  r, g, b,

  // Audio, on clk_cpu: the YMZ280B's mono output, held between samples;
  // snd_sample marks each new one (the chip's clock / 192), snd_overrun one
  // that came late (the OKI build: the two OKIs mixed, strobed at 88,200 Hz)
  output wire [15:0] snd,
  output wire        snd_sample,
  output wire        snd_overrun,

  // Diagnostics, on clk_cpu: the sprite frame buffer's page swap (the 68000
  // asking for the next frame of sprites) and the 68000's address strobe
  output wire        spr_swap,
  output wire        cpu_as
);

  // ------------------------------------------------------------- the game
  // Upstream's index, held to the YMZ280B games: 7 is not a game, so the
  // Power Instinct 2 paths (indices 7 and 8) can never be selected and
  // synthesis sweeps them, and the top bit is not looked at, so neither can
  // Air Gallet's and Sailor Moon's (9 and 10). The OKI build plays DonPachi
  // (2) alone and the Z80 build those two alone, and each sweeps the others.
`ifdef CAVE_OKI
  wire [3:0] gameIndex = 4'd2;
`elsif CAVE_Z80
  wire [3:0] gameIndex = (game == 4'd10) ? 4'd10 : 4'd9;
`else
  wire [3:0] gameIndex = (game[2:0] == 3'd7) ? 4'd1 : {1'b0, game[2:0]};
`endif
  wire       gameIsSailormn = (gameIndex == 4'd9) | (gameIndex == 4'd10);

  wire [8:0]  gameConfig_granularity;
  wire [1:0]  gameConfig_sound_0_device;
  wire [1:0]  layer_0_format, layer_1_format, layer_2_format, sprite_format;
  wire [1:0]  gameConfig_layer_0_paletteBank, gameConfig_layer_1_paletteBank, gameConfig_layer_2_paletteBank;
  wire        gameConfig_sprite_zoom;
  wire        gameIsPwrInst2, gameIsPlegends, rotateClockwise;

  CaveGameConfig gameConfig (
    .game_index           (gameIndex),
    .granularity          (gameConfig_granularity),
    .eeprom_offset        (),
    .sound_0_device       (gameConfig_sound_0_device),
    .sound_0_rom_offset   (),
    .sound_1_rom_offset   (),
    .sound_2_rom_offset   (),
    .layer_0_format       (layer_0_format),
    .layer_0_rom_offset   (),
    .layer_0_palette_bank (gameConfig_layer_0_paletteBank),
    .layer_1_format       (layer_1_format),
    .layer_1_rom_offset   (),
    .layer_1_palette_bank (gameConfig_layer_1_paletteBank),
    .layer_2_format       (layer_2_format),
    .layer_2_rom_offset   (),
    .pwrinst2_layer_2_rom_offset (),
    .layer_2_palette_bank (gameConfig_layer_2_paletteBank),
    .sprite_format        (sprite_format),
    .sprite_rom_offset    (),
    .sprite_zoom          (gameConfig_sprite_zoom)
  );

  CaveBoardProfile boardProfile (
    .game_index                  (gameIndex),
    .sound_device                (2'd0),
    .game_is_dfeveron            (),
    .game_is_dodonpachi          (),
    .game_is_donpachi            (),
    .game_is_esprade             (),
    .game_is_uopoko              (),
    .game_is_guwange             (),
    .game_is_gaia                (),
    .game_is_pwrinst2            (gameIsPwrInst2),
    .game_is_plegends            (gameIsPlegends),
    .board_uses_z80_sound        (),
    .board_is_vertical_clockwise (rotateClockwise),
    .sound_is_ymz280b            (),
    .sound_is_oki                (),
    .sound_is_z80                ()
  );

  // ----------------------------------------------------------- the resets
  // The 68000 side waits for the memories: rom_loaded through upstream's
  // bridge, which synchronises it into clk_cpu.
  wire cpuDomainReset;
  CaveCpuResetBridge cpuResetBridge (
    .clock            (clk_cpu),
    .cpu_reset        (rst_cpu),
    .mem_ready_async  (rom_loaded),
    .recovery_reset   (1'b0),
    .cpu_domain_reset (cpuDomainReset)
  );

  // ------------------------------------------------------ savestate buses
  // The kept modules still carry upstream's savestate bus ports. There is
  // no controller here: the buses sit idle, and the capture logic behind
  // them has no reader, so synthesis sweeps it.
  cave_ssbus_if ssMain();
  assign ssMain.data = 64'd0;   assign ssMain.addr = 32'd0;  assign ssMain.select = 8'd0;
  assign ssMain.write = 1'b0;   assign ssMain.read = 1'b0;   assign ssMain.query = 1'b0;

  // ------------------------------------------------------------- the wires
  wire [15:0]  _main_io_soundCtrl_ymz_dout;
  wire         _main_io_soundCtrl_irq;
  wire         _main_io_soundCtrl_oki_0_wr, _main_io_soundCtrl_oki_1_wr, _main_io_soundCtrl_nmk_wr;
  wire [15:0]  _main_io_soundCtrl_oki_0_din, _main_io_soundCtrl_oki_1_din, _main_io_soundCtrl_nmk_din;
  wire [15:0]  _main_io_soundCtrl_oki_0_dout, _main_io_soundCtrl_oki_1_dout;
  wire [22:0]  _main_io_soundCtrl_nmk_addr;
  wire [15:0]  _main_io_progRom_dout;
  wire         _main_io_progRom_valid;
  wire [15:0]  _main_io_eeprom_dout;
  wire         _main_io_eeprom_wait_n;
  wire         _main_io_eeprom_valid;

  wire         _main_io_gpuMem_layer_0_regs_tileSize, _main_io_gpuMem_layer_0_regs_enable;
  wire         _main_io_gpuMem_layer_0_regs_flipX, _main_io_gpuMem_layer_0_regs_flipY;
  wire         _main_io_gpuMem_layer_0_regs_rowScrollEnable, _main_io_gpuMem_layer_0_regs_rowSelectEnable;
  wire [8:0]   _main_io_gpuMem_layer_0_regs_scroll_x, _main_io_gpuMem_layer_0_regs_scroll_y;
  wire [31:0]  _main_io_gpuMem_layer_0_vram8x8_dout, _main_io_gpuMem_layer_0_vram16x16_dout, _main_io_gpuMem_layer_0_lineRam_dout;
  wire         _main_io_gpuMem_layer_1_regs_tileSize, _main_io_gpuMem_layer_1_regs_enable;
  wire         _main_io_gpuMem_layer_1_regs_flipX, _main_io_gpuMem_layer_1_regs_flipY;
  wire         _main_io_gpuMem_layer_1_regs_rowScrollEnable, _main_io_gpuMem_layer_1_regs_rowSelectEnable;
  wire [8:0]   _main_io_gpuMem_layer_1_regs_scroll_x, _main_io_gpuMem_layer_1_regs_scroll_y;
  wire [31:0]  _main_io_gpuMem_layer_1_vram8x8_dout, _main_io_gpuMem_layer_1_vram16x16_dout, _main_io_gpuMem_layer_1_lineRam_dout;
  wire         _main_io_gpuMem_layer_2_regs_tileSize, _main_io_gpuMem_layer_2_regs_enable;
  wire         _main_io_gpuMem_layer_2_regs_flipX, _main_io_gpuMem_layer_2_regs_flipY;
  wire         _main_io_gpuMem_layer_2_regs_rowScrollEnable, _main_io_gpuMem_layer_2_regs_rowSelectEnable;
  wire [8:0]   _main_io_gpuMem_layer_2_regs_scroll_x, _main_io_gpuMem_layer_2_regs_scroll_y;
  wire [31:0]  _main_io_gpuMem_layer_2_vram8x8_dout, _main_io_gpuMem_layer_2_vram16x16_dout, _main_io_gpuMem_layer_2_lineRam_dout;
  wire         _main_io_gpuMem_pwrinst2_layer_2_regs_tileSize, _main_io_gpuMem_pwrinst2_layer_2_regs_enable;
  wire         _main_io_gpuMem_pwrinst2_layer_2_regs_flipX, _main_io_gpuMem_pwrinst2_layer_2_regs_flipY;
  wire         _main_io_gpuMem_pwrinst2_layer_2_regs_rowScrollEnable, _main_io_gpuMem_pwrinst2_layer_2_regs_rowSelectEnable;
  wire [8:0]   _main_io_gpuMem_pwrinst2_layer_2_regs_scroll_x, _main_io_gpuMem_pwrinst2_layer_2_regs_scroll_y;
  wire [31:0]  _main_io_gpuMem_pwrinst2_layer_2_vram8x8_dout, _main_io_gpuMem_pwrinst2_layer_2_vram16x16_dout, _main_io_gpuMem_pwrinst2_layer_2_lineRam_dout;
  wire [8:0]   _main_io_gpuMem_sprite_regs_offset_x, _main_io_gpuMem_sprite_regs_offset_y;
  wire [1:0]   _main_io_gpuMem_sprite_regs_bank;
  wire         _main_io_gpuMem_sprite_regs_fixed, _main_io_gpuMem_sprite_regs_hFlip;
  wire [127:0] _main_io_gpuMem_sprite_vram_dout;
  wire [15:0]  _main_io_gpuMem_paletteRam_dout;
  wire         _main_io_soundCtrl_ymz_rd, _main_io_soundCtrl_ymz_wr;
  wire [22:0]  _main_io_soundCtrl_ymz_addr;
  wire [15:0]  _main_io_soundCtrl_ymz_din;
  wire         _main_io_progRom_rd;
  wire [21:0]  _main_io_progRom_addr;
  wire         _main_io_eeprom_rd, _main_io_eeprom_wr;
  wire [6:0]   _main_io_eeprom_addr;
  wire [15:0]  _main_io_eeprom_din;
  wire         _main_io_spriteFrameBufferSwap;
  wire         _main_io_layer2TileBank;

  wire [11:0]  _main_io_gpuMem_layer_0_vram8x8_addr, _main_io_gpuMem_layer_1_vram8x8_addr, _main_io_gpuMem_layer_2_vram8x8_addr, _main_io_gpuMem_pwrinst2_layer_2_vram8x8_addr;
  wire [9:0]   _main_io_gpuMem_layer_0_vram16x16_addr, _main_io_gpuMem_layer_1_vram16x16_addr, _main_io_gpuMem_layer_2_vram16x16_addr, _main_io_gpuMem_pwrinst2_layer_2_vram16x16_addr;
  wire [8:0]   _main_io_gpuMem_layer_0_lineRam_addr, _main_io_gpuMem_layer_1_lineRam_addr, _main_io_gpuMem_layer_2_lineRam_addr, _main_io_gpuMem_pwrinst2_layer_2_lineRam_addr;
  wire         _main_io_gpuMem_sprite_vram_rd;
  wire [11:0]  _main_io_gpuMem_sprite_vram_addr;
  wire [14:0]  _main_io_gpuMem_paletteRam_addr;

  wire         _gpu_io_layerCtrl_0_tileRom_rd, _gpu_io_layerCtrl_1_tileRom_rd, _gpu_io_layerCtrl_2_tileRom_rd, _gpu_io_pwrinst2Layer2_tileRom_rd;
  wire [31:0]  _gpu_io_layerCtrl_0_tileRom_addr, _gpu_io_layerCtrl_1_tileRom_addr, _gpu_io_layerCtrl_2_tileRom_addr, _gpu_io_pwrinst2Layer2_tileRom_addr;
  wire [63:0]  _gpu_io_layerCtrl_0_tileRom_dout, _gpu_io_layerCtrl_1_tileRom_dout, _gpu_io_layerCtrl_2_tileRom_dout;
  wire [8:0]   _gpu_io_spriteLineBuffer_addr;
  wire [15:0]  _gpu_io_spriteLineBuffer_dout;
  wire         _gpu_io_spriteFrameBuffer_wr;
  wire [16:0]  _gpu_io_spriteFrameBuffer_addr;
  wire [15:0]  _gpu_io_spriteFrameBuffer_din;
  wire         _gpu_io_spriteFrameBuffer_wait_n;
  wire [23:0]  _gpu_rgb;

  wire         _videoSys_io_video_clockEnable, _videoSys_io_video_displayEnable;
  wire [8:0]   _videoSys_io_video_pos_x, _videoSys_io_video_pos_y;
  wire         _videoSys_io_video_hBlank, _videoSys_io_video_vBlank;
  wire [8:0]   _videoSys_io_video_regs_size_x, _videoSys_io_video_regs_size_y;

  // the three layers' tile ROM reads, clk_vid -> clk, into their caches
  wire         _xing_0_rd, _xing_1_rd, _xing_2_rd;
  wire [31:0]  _xing_0_addr, _xing_1_addr, _xing_2_addr;
  wire [63:0]  _xing_0_dout, _xing_1_dout, _xing_2_dout;
  wire         _xing_0_wait_n, _xing_1_wait_n, _xing_2_wait_n;
  wire         _xing_0_valid, _xing_1_valid, _xing_2_valid;

  // the 68000's program reads, clk_cpu -> clk, into the cache
  wire         _frz_prog_rd;
  wire [21:0]  _frz_prog_addr;
  wire [15:0]  _frz_prog_dout;
  wire         _frz_prog_wait_n, _frz_prog_valid;

  // the YMZ280B's sample reads, clk_cpu -> clk, into the cache
  wire         _sound_io_rom_0_rd;
  wire [24:0]  _sound_io_rom_0_addr;
  wire [7:0]   _sound_io_rom_0_dout;
  wire         _sound_io_rom_0_wait_n, _sound_io_rom_0_valid;
  wire         _frz_snd_rd;
  wire [24:0]  _frz_snd_addr;
  wire [7:0]   _frz_snd_dout;
  wire         _frz_snd_wait_n, _frz_snd_valid;

  // the sprite list is drawn when vblank falls, seen on clk
  reg          videoVBlankPipe0, videoVBlankPipe1, videoVBlankPipe2;
  always @(posedge clk) begin
    videoVBlankPipe0 <= _videoSys_io_video_vBlank;
    videoVBlankPipe1 <= videoVBlankPipe0;
    videoVBlankPipe2 <= videoVBlankPipe1;
  end
  wire videoVBlankFalling = ~videoVBlankPipe1 & videoVBlankPipe2;

  // --------------------------------------------------------------- Main
  Main main (
    .clock                                  (clk_cpu),
    .reset                                  (cpuDomainReset),
    .io_systemClock                         (clk),
    .io_systemReset                         (rst),
    .io_highScoreReset                      (rst_cpu),
    .io_videoClock                          (clk_vid),
    .io_spriteClock                         (clk),
    .io_gameIndex                           (gameIndex),
    .io_options_service                     (service),
    .io_player_0_up                         (p1[0]),
    .io_player_0_down                       (p1[1]),
    .io_player_0_left                       (p1[2]),
    .io_player_0_right                      (p1[3]),
    .io_player_0_buttons                    (p1[7:4]),
    .io_player_0_start                      (start[0]),
    .io_player_0_coin                       (coin[0]),
    .io_player_0_pause                      (pause),
    .io_player_1_up                         (p2[0]),
    .io_player_1_down                       (p2[1]),
    .io_player_1_left                       (p2[2]),
    .io_player_1_right                      (p2[3]),
    .io_player_1_buttons                    (p2[7:4]),
    .io_player_1_start                      (start[1]),
    .io_player_1_coin                       (coin[1]),
    .io_player_1_pause                      (1'b0),
    .io_dips_0                              (dsw),
    .io_video_vBlank                        (_videoSys_io_video_vBlank),
    .io_gpuMem_layer_0_regs_tileSize        (_main_io_gpuMem_layer_0_regs_tileSize),
    .io_gpuMem_layer_0_regs_enable          (_main_io_gpuMem_layer_0_regs_enable),
    .io_gpuMem_layer_0_regs_flipX           (_main_io_gpuMem_layer_0_regs_flipX),
    .io_gpuMem_layer_0_regs_flipY           (_main_io_gpuMem_layer_0_regs_flipY),
    .io_gpuMem_layer_0_regs_rowScrollEnable (_main_io_gpuMem_layer_0_regs_rowScrollEnable),
    .io_gpuMem_layer_0_regs_rowSelectEnable (_main_io_gpuMem_layer_0_regs_rowSelectEnable),
    .io_gpuMem_layer_0_regs_scroll_x        (_main_io_gpuMem_layer_0_regs_scroll_x),
    .io_gpuMem_layer_0_regs_scroll_y        (_main_io_gpuMem_layer_0_regs_scroll_y),
    .io_gpuMem_layer_0_vram8x8_addr         (_main_io_gpuMem_layer_0_vram8x8_addr),
    .io_gpuMem_layer_0_vram8x8_dout         (_main_io_gpuMem_layer_0_vram8x8_dout),
    .io_gpuMem_layer_0_vram16x16_addr       (_main_io_gpuMem_layer_0_vram16x16_addr),
    .io_gpuMem_layer_0_vram16x16_dout       (_main_io_gpuMem_layer_0_vram16x16_dout),
    .io_gpuMem_layer_0_lineRam_addr         (_main_io_gpuMem_layer_0_lineRam_addr),
    .io_gpuMem_layer_0_lineRam_dout         (_main_io_gpuMem_layer_0_lineRam_dout),
    .io_gpuMem_layer_1_regs_tileSize        (_main_io_gpuMem_layer_1_regs_tileSize),
    .io_gpuMem_layer_1_regs_enable          (_main_io_gpuMem_layer_1_regs_enable),
    .io_gpuMem_layer_1_regs_flipX           (_main_io_gpuMem_layer_1_regs_flipX),
    .io_gpuMem_layer_1_regs_flipY           (_main_io_gpuMem_layer_1_regs_flipY),
    .io_gpuMem_layer_1_regs_rowScrollEnable (_main_io_gpuMem_layer_1_regs_rowScrollEnable),
    .io_gpuMem_layer_1_regs_rowSelectEnable (_main_io_gpuMem_layer_1_regs_rowSelectEnable),
    .io_gpuMem_layer_1_regs_scroll_x        (_main_io_gpuMem_layer_1_regs_scroll_x),
    .io_gpuMem_layer_1_regs_scroll_y        (_main_io_gpuMem_layer_1_regs_scroll_y),
    .io_gpuMem_layer_1_vram8x8_addr         (_main_io_gpuMem_layer_1_vram8x8_addr),
    .io_gpuMem_layer_1_vram8x8_dout         (_main_io_gpuMem_layer_1_vram8x8_dout),
    .io_gpuMem_layer_1_vram16x16_addr       (_main_io_gpuMem_layer_1_vram16x16_addr),
    .io_gpuMem_layer_1_vram16x16_dout       (_main_io_gpuMem_layer_1_vram16x16_dout),
    .io_gpuMem_layer_1_lineRam_addr         (_main_io_gpuMem_layer_1_lineRam_addr),
    .io_gpuMem_layer_1_lineRam_dout         (_main_io_gpuMem_layer_1_lineRam_dout),
    .io_gpuMem_layer_2_regs_tileSize        (_main_io_gpuMem_layer_2_regs_tileSize),
    .io_gpuMem_layer_2_regs_enable          (_main_io_gpuMem_layer_2_regs_enable),
    .io_gpuMem_layer_2_regs_flipX           (_main_io_gpuMem_layer_2_regs_flipX),
    .io_gpuMem_layer_2_regs_flipY           (_main_io_gpuMem_layer_2_regs_flipY),
    .io_gpuMem_layer_2_regs_rowScrollEnable (_main_io_gpuMem_layer_2_regs_rowScrollEnable),
    .io_gpuMem_layer_2_regs_rowSelectEnable (_main_io_gpuMem_layer_2_regs_rowSelectEnable),
    .io_gpuMem_layer_2_regs_scroll_x        (_main_io_gpuMem_layer_2_regs_scroll_x),
    .io_gpuMem_layer_2_regs_scroll_y        (_main_io_gpuMem_layer_2_regs_scroll_y),
    .io_gpuMem_layer_2_vram8x8_addr         (_main_io_gpuMem_layer_2_vram8x8_addr),
    .io_gpuMem_layer_2_vram8x8_dout         (_main_io_gpuMem_layer_2_vram8x8_dout),
    .io_gpuMem_layer_2_vram16x16_addr       (_main_io_gpuMem_layer_2_vram16x16_addr),
    .io_gpuMem_layer_2_vram16x16_dout       (_main_io_gpuMem_layer_2_vram16x16_dout),
    .io_gpuMem_layer_2_lineRam_addr         (_main_io_gpuMem_layer_2_lineRam_addr),
    .io_gpuMem_layer_2_lineRam_dout         (_main_io_gpuMem_layer_2_lineRam_dout),
    .io_gpuMem_pwrinst2_layer_2_regs_tileSize        (_main_io_gpuMem_pwrinst2_layer_2_regs_tileSize),
    .io_gpuMem_pwrinst2_layer_2_regs_enable          (_main_io_gpuMem_pwrinst2_layer_2_regs_enable),
    .io_gpuMem_pwrinst2_layer_2_regs_flipX           (_main_io_gpuMem_pwrinst2_layer_2_regs_flipX),
    .io_gpuMem_pwrinst2_layer_2_regs_flipY           (_main_io_gpuMem_pwrinst2_layer_2_regs_flipY),
    .io_gpuMem_pwrinst2_layer_2_regs_rowScrollEnable (_main_io_gpuMem_pwrinst2_layer_2_regs_rowScrollEnable),
    .io_gpuMem_pwrinst2_layer_2_regs_rowSelectEnable (_main_io_gpuMem_pwrinst2_layer_2_regs_rowSelectEnable),
    .io_gpuMem_pwrinst2_layer_2_regs_scroll_x        (_main_io_gpuMem_pwrinst2_layer_2_regs_scroll_x),
    .io_gpuMem_pwrinst2_layer_2_regs_scroll_y        (_main_io_gpuMem_pwrinst2_layer_2_regs_scroll_y),
    .io_gpuMem_pwrinst2_layer_2_vram8x8_addr         (_main_io_gpuMem_pwrinst2_layer_2_vram8x8_addr),
    .io_gpuMem_pwrinst2_layer_2_vram8x8_dout         (_main_io_gpuMem_pwrinst2_layer_2_vram8x8_dout),
    .io_gpuMem_pwrinst2_layer_2_vram16x16_addr       (_main_io_gpuMem_pwrinst2_layer_2_vram16x16_addr),
    .io_gpuMem_pwrinst2_layer_2_vram16x16_dout       (_main_io_gpuMem_pwrinst2_layer_2_vram16x16_dout),
    .io_gpuMem_pwrinst2_layer_2_lineRam_addr         (_main_io_gpuMem_pwrinst2_layer_2_lineRam_addr),
    .io_gpuMem_pwrinst2_layer_2_lineRam_dout         (_main_io_gpuMem_pwrinst2_layer_2_lineRam_dout),
    .io_gpuMem_sprite_regs_offset_x         (_main_io_gpuMem_sprite_regs_offset_x),
    .io_gpuMem_sprite_regs_offset_y         (_main_io_gpuMem_sprite_regs_offset_y),
    .io_gpuMem_sprite_regs_bank             (_main_io_gpuMem_sprite_regs_bank),
    .io_gpuMem_sprite_regs_fixed            (_main_io_gpuMem_sprite_regs_fixed),
    .io_gpuMem_sprite_regs_hFlip            (_main_io_gpuMem_sprite_regs_hFlip),
    .io_gpuMem_sprite_vram_rd               (_main_io_gpuMem_sprite_vram_rd),
    .io_gpuMem_sprite_vram_addr             (_main_io_gpuMem_sprite_vram_addr),
    .io_gpuMem_sprite_vram_dout             (_main_io_gpuMem_sprite_vram_dout),
    .io_gpuMem_paletteRam_addr              (_main_io_gpuMem_paletteRam_addr),
    .io_gpuMem_paletteRam_dout              (_main_io_gpuMem_paletteRam_dout),
    .io_soundCtrl_oki_0_wr                  (_main_io_soundCtrl_oki_0_wr),
    .io_soundCtrl_oki_0_din                 (_main_io_soundCtrl_oki_0_din),
    .io_soundCtrl_oki_0_dout                (_main_io_soundCtrl_oki_0_dout),
    .io_soundCtrl_oki_1_wr                  (_main_io_soundCtrl_oki_1_wr),
    .io_soundCtrl_oki_1_din                 (_main_io_soundCtrl_oki_1_din),
    .io_soundCtrl_oki_1_dout                (_main_io_soundCtrl_oki_1_dout),
    .io_soundCtrl_nmk_wr                    (_main_io_soundCtrl_nmk_wr),
    .io_soundCtrl_nmk_addr                  (_main_io_soundCtrl_nmk_addr),
    .io_soundCtrl_nmk_din                   (_main_io_soundCtrl_nmk_din),
    .io_soundCtrl_ymz_rd                    (_main_io_soundCtrl_ymz_rd),
    .io_soundCtrl_ymz_wr                    (_main_io_soundCtrl_ymz_wr),
    .io_soundCtrl_ymz_addr                  (_main_io_soundCtrl_ymz_addr),
    .io_soundCtrl_ymz_din                   (_main_io_soundCtrl_ymz_din),
    .io_soundCtrl_ymz_dout                  (_main_io_soundCtrl_ymz_dout),
    .io_soundCtrl_req                       (),
    .io_soundCtrl_data                      (),
    .io_soundCtrl_reply_rd                  (),
    // the Z80 board's replies: none yet (MAME's traces of both games read
    // the reply port twice in their first 260 frames, both times empty)
    .io_soundCtrl_reply                     (16'h00ff),
    .io_soundCtrl_reply_empty               (1'b1),
    .io_soundCtrl_irq                       (_main_io_soundCtrl_irq),
    .io_progRom_rd                          (_main_io_progRom_rd),
    .io_progRom_addr                        (_main_io_progRom_addr),
    .io_progRom_dout                        (_main_io_progRom_dout),
    .io_progRom_valid                       (_main_io_progRom_valid),
    .io_eeprom_rd                           (_main_io_eeprom_rd),
    .io_eeprom_wr                           (_main_io_eeprom_wr),
    .io_eeprom_addr                         (_main_io_eeprom_addr),
    .io_eeprom_din                          (_main_io_eeprom_din),
    .io_eeprom_dout                         (_main_io_eeprom_dout),
    .io_eeprom_wait_n                       (_main_io_eeprom_wait_n),
    .io_eeprom_valid                        (_main_io_eeprom_valid),
    .io_hs_config_download                  (1'b0),
    .io_hs_config_wr                        (1'b0),
    .io_hs_config_addr                      (27'd0),
    .io_hs_config_dout                      (16'd0),
    .io_hs_nvram_download                   (1'b0),
    .io_hs_nvram_upload                     (1'b0),
    .io_hs_nvram_rd                         (1'b0),
    .io_hs_nvram_wr                         (1'b0),
    .io_hs_nvram_addr                       (27'd0),
    .io_hs_nvram_dout                       (16'd0),
    .io_hs_nvram_din                        (),
    .io_hs_nvram_wait_n                     (),
    .io_hs_dirty                            (),
    .io_hs_active                           (),
    .io_spriteFrameBufferSwap               (_main_io_spriteFrameBufferSwap),
    .io_layer2TileBank                      (_main_io_layer2TileBank),
    .io_ss_hold                             (1'b0),
    .io_ss_capture_request                  (1'b0),
    .io_ss_restore_enable                   (1'b0),
    .io_ss_restore_start                    (1'b0),
    .io_ss_restore_commit                   (1'b0),
    .io_ss_release                          (1'b0),
    .io_ss_capture_done                     (),
    .io_ss_cpu_idle                         (),
    .io_ss_clients_idle                     (),
    .io_ss_restore_commit_done              (),
    .io_ss_reconstruction_ready             (),
    .io_ss_blocked_access                   (),
    .io_service_debug                       (),
    .io_cpu_as                              (cpu_as),
    .io_ssbus                               (ssMain),
    .io_debug_pipeline                      (),
    .io_debug_cpu                           (),
    .io_debug_writes                        (),
    .io_debug_data                          (),
    .io_debug_live                          (),
    .io_debug_palette                       ()
  );

  // --------------------------------------------- program ROM: freezer, cache
  CaveProgramRomReadFreezer main_io_progRom_freezer (
    .clock          (clk),
    .reset          (rst),
    .io_targetClock (clk_cpu),
    .io_targetReset (rst_cpu),
    .io_in_rd       (_main_io_progRom_rd),
    .io_in_addr     (_main_io_progRom_addr),
    .io_in_dout     (_main_io_progRom_dout),
    .io_in_valid    (_main_io_progRom_valid),
    .io_out_rd      (_frz_prog_rd),
    .io_out_addr    (_frz_prog_addr),
    .io_out_dout    (_frz_prog_dout),
    .io_out_wait_n  (_frz_prog_wait_n),
    .io_out_valid   (_frz_prog_valid)
  );

  CaveReadCache #(
    .IN_ADDR_WIDTH  (22),
    .IN_DATA_WIDTH  (16),
    .OUT_ADDR_WIDTH (25),
    .INDEX_WIDTH    (7),
    .TAG_WIDTH      (13)
  ) progRomCache (
    .clock         (clk),
    .reset         (rst),
    .io_enable     (rom_loaded),
    .io_in_rd      (_frz_prog_rd),
    .io_in_addr    (_frz_prog_addr),
    .io_in_dout    (_frz_prog_dout),
    .io_in_wait_n  (_frz_prog_wait_n),
    .io_in_valid   (_frz_prog_valid),
    .io_out_rd     (prog_rd),
    .io_out_addr   (prog_addr),
    .io_out_dout   (prog_dout),
    .io_out_wait_n (prog_wait_n),
    .io_out_valid  (prog_valid)
  );

  // ---------------------------------------------------- the 93C46's store
  CaveEepromDataFreezer main_io_eeprom_freezer (
    .clock          (clk),
    .reset          (rst),
    .io_targetClock (clk_cpu),
    .io_in_rd       (_main_io_eeprom_rd),
    .io_in_wr       (_main_io_eeprom_wr),
    .io_in_addr     (_main_io_eeprom_addr),
    .io_in_din      (_main_io_eeprom_din),
    .io_in_dout     (_main_io_eeprom_dout),
    .io_in_wait_n   (_main_io_eeprom_wait_n),
    .io_in_valid    (_main_io_eeprom_valid),
    .io_out_rd      (ee_rd),
    .io_out_wr      (ee_wr),
    .io_out_addr    (ee_addr),
    .io_out_din     (ee_din),
    .io_out_dout    (ee_dout),
    .io_out_wait_n  (ee_wait_n),
    .io_out_valid   (ee_valid)
  );

  // -------------------------------------------------------------- Sound
`ifdef CAVE_Z80
  // The Z80 sound board's stand-in: silent, no ROM reads
  assign _main_io_soundCtrl_oki_0_dout = 16'h0000;
  assign _main_io_soundCtrl_oki_1_dout = 16'h0000;
  assign _main_io_soundCtrl_ymz_dout = 16'h0000;
  assign _main_io_soundCtrl_irq = 1'b0;
  assign _sound_io_rom_0_rd = 1'b0;
  assign _sound_io_rom_0_addr = 25'd0;
  assign snd = 16'd0;
  reg [8:0] sndStrobeCount;
  always @(posedge clk_cpu)
    if (cpuDomainReset || sndStrobeCount == 9'd362) sndStrobeCount <= 9'd0;
    else sndStrobeCount <= sndStrobeCount + 9'd1;
  assign snd_sample = sndStrobeCount == 9'd362;
  assign snd_overrun = 1'b0;
`elsif CAVE_OKI
  wire [7:0] okiDout0, okiDout1;
  SoundOki sound (
    .clock                 (clk_cpu),
    .reset                 (cpuDomainReset),
    .io_pause              (pause),
    .io_oki_0_wr           (_main_io_soundCtrl_oki_0_wr),
    .io_oki_0_din          (_main_io_soundCtrl_oki_0_din[7:0]),
    .io_oki_0_dout         (okiDout0),
    .io_oki_1_wr           (_main_io_soundCtrl_oki_1_wr),
    .io_oki_1_din          (_main_io_soundCtrl_oki_1_din[7:0]),
    .io_oki_1_dout         (okiDout1),
    .io_nmk_wr             (_main_io_soundCtrl_nmk_wr),
    .io_nmk_addr           (_main_io_soundCtrl_nmk_addr[2:0]),
    .io_nmk_din            (_main_io_soundCtrl_nmk_din[7:0]),
    .io_rom_rd             (_sound_io_rom_0_rd),
    .io_rom_addr           (_sound_io_rom_0_addr),
    .io_rom_dout           (_sound_io_rom_0_dout),
    .io_rom_wait_n         (_sound_io_rom_0_wait_n),
    .io_rom_valid          (_sound_io_rom_0_valid),
    .io_audio              (snd),
    .io_audio_valid        (snd_sample),
    .io_overrun            (snd_overrun),
    .io_sample_valid_0     (),
    .io_sample_valid_1     (),
    .io_sample_0           (),
    .io_sample_1           ()
  );
  assign _main_io_soundCtrl_oki_0_dout = {8'h00, okiDout0};
  assign _main_io_soundCtrl_oki_1_dout = {8'h00, okiDout1};
  assign _main_io_soundCtrl_ymz_dout = 16'h0000;
  assign _main_io_soundCtrl_irq = 1'b0;
`else
  assign _main_io_soundCtrl_oki_0_dout = 16'h0000;
  assign _main_io_soundCtrl_oki_1_dout = 16'h0000;
  Sound #(.CLOCK_HZ (32000000)) sound (
    .clock                 (clk_cpu),
    .reset                 (cpuDomainReset),
    .io_clock16m           (gameIndex == 4'd6),
    .io_pause              (pause),
    .io_ctrl_ymz_rd        (_main_io_soundCtrl_ymz_rd),
    .io_ctrl_ymz_wr        (_main_io_soundCtrl_ymz_wr),
    .io_ctrl_ymz_addr      (_main_io_soundCtrl_ymz_addr),
    .io_ctrl_ymz_din       (_main_io_soundCtrl_ymz_din),
    .io_ctrl_ymz_dout      (_main_io_soundCtrl_ymz_dout),
    .io_ctrl_irq           (_main_io_soundCtrl_irq),
    .io_rom_0_rd           (_sound_io_rom_0_rd),
    .io_rom_0_addr         (_sound_io_rom_0_addr),
    .io_rom_0_dout         (_sound_io_rom_0_dout),
    .io_rom_0_wait_n       (_sound_io_rom_0_wait_n),
    .io_rom_0_valid        (_sound_io_rom_0_valid),
    .io_audio              (snd),
    .io_audio_valid        (snd_sample),
    .io_overrun            (snd_overrun)
  );
`endif

  CaveSoundRomReadFreezer sound_io_rom_0_freezer (
    .clock          (clk),
    .reset          (rst),
    .io_targetClock (clk_cpu),
    .io_hold_response (1'b0),
    .io_in_rd       (_sound_io_rom_0_rd),
    .io_in_addr     (_sound_io_rom_0_addr),
    .io_in_dout     (_sound_io_rom_0_dout),
    .io_in_wait_n   (_sound_io_rom_0_wait_n),
    .io_in_valid    (_sound_io_rom_0_valid),
    .io_out_rd      (_frz_snd_rd),
    .io_out_addr    (_frz_snd_addr),
    .io_out_dout    (_frz_snd_dout),
    .io_out_wait_n  (_frz_snd_wait_n),
    .io_out_valid   (_frz_snd_valid)
  );

  CaveReadCache #(
    .IN_ADDR_WIDTH  (25),
    .IN_DATA_WIDTH  (8),
    .OUT_ADDR_WIDTH (25),
    .INDEX_WIDTH    (2),
    .TAG_WIDTH      (21),
    .RAMSTYLE       ("MLAB")
  ) soundRomCache (
    .clock         (clk),
    .reset         (rst),
    .io_enable     (rom_loaded),
    .io_in_rd      (_frz_snd_rd),
    .io_in_addr    (_frz_snd_addr),
    .io_in_dout    (_frz_snd_dout),
    .io_in_wait_n  (_frz_snd_wait_n),
    .io_in_valid   (_frz_snd_valid),
    .io_out_rd     (snd_rd),
    .io_out_addr   (snd_addr),
    .io_out_dout   (snd_dout),
    .io_out_wait_n (snd_wait_n),
    .io_out_valid  (snd_valid)
  );

  // ------------------------------------------------------------ VideoSys
  // The timing registers: VideoSys's reset values (320 x 240, upstream's
  // porches) for every game but Gaia Crusaders and Thunder Heroes, which
  // show 224 lines. Upstream's MRAs programme those two through the prog
  // port (0140 00e0 0024 0018 0014 0002: 320 x 224, front porch 36 x 24,
  // retrace 20 x 2); the board writes the same six words after reset, in
  // the port's byte order, then commits them.
  reg  [2:0]  vprogStep;
  reg  [15:0] vprogValue;
  wire        vprogGaia = gameIndex == 4'd6;
  always @(posedge clk)
    if (rst)                    vprogStep <= 3'd0;
    else if (vprogStep != 3'd7) vprogStep <= vprogStep + 3'd1;
  always @* begin
    case (vprogStep)
      3'd0:    vprogValue = 16'h0140;
      3'd1:    vprogValue = 16'h00e0;
      3'd2:    vprogValue = 16'h0024;
      3'd3:    vprogValue = 16'h0018;
      3'd4:    vprogValue = 16'h0014;
      default: vprogValue = 16'h0002;
    endcase
  end

  VideoSys videoSys (
    .clock                      (clk),
    .reset                      (rst),
    .io_videoClock              (clk_vid),
    .io_videoReset              (rst_vid),
    .io_prog_video_wr           (vprogGaia && vprogStep < 3'd6),
    .io_prog_video_addr         ({23'd0, vprogStep, 1'b0}),
    .io_prog_video_din          ({vprogValue[7:0], vprogValue[15:8]}),
    .io_prog_done               (vprogGaia && vprogStep == 3'd6),
    .io_options_offset_x        (4'd0),
    .io_options_offset_y        (4'd0),
    .io_options_compatibility   (1'b0),
    .io_options_wideTiming      (1'b0),
    .io_video_clockEnable       (_videoSys_io_video_clockEnable),
    .io_video_displayEnable     (_videoSys_io_video_displayEnable),
    .io_video_pos_x             (_videoSys_io_video_pos_x),
    .io_video_pos_y             (_videoSys_io_video_pos_y),
    .io_video_hSync             (hs),
    .io_video_vSync             (vs),
    .io_video_hBlank            (_videoSys_io_video_hBlank),
    .io_video_vBlank            (_videoSys_io_video_vBlank),
    .io_video_regs_size_x       (_videoSys_io_video_regs_size_x),
    .io_video_regs_size_y       (_videoSys_io_video_regs_size_y),
    .io_video_regs_frontPorch_x (),
    .io_video_regs_frontPorch_y (),
    .io_video_regs_retrace_x    (),
    .io_video_regs_retrace_y    (),
    .io_video_changeMode        ()
  );

  // ----------------------------------------------------------------- GPU
  GPU gpu (
    .clock                               (clk),
    .reset                               (rst),
    .io_videoClock                       (clk_vid),
    .io_ss_hold                          (1'b0),
    .io_ss_canonicalize                  (1'b0),
    .io_layerCtrl_0_enable               (1'b1),
    .io_layerCtrl_0_format               (layer_0_format),
    .io_layerCtrl_0_regs_tileSize        (_main_io_gpuMem_layer_0_regs_tileSize),
    .io_layerCtrl_0_regs_enable          (_main_io_gpuMem_layer_0_regs_enable),
    .io_layerCtrl_0_regs_flipX           (_main_io_gpuMem_layer_0_regs_flipX),
    .io_layerCtrl_0_regs_flipY           (_main_io_gpuMem_layer_0_regs_flipY),
    .io_layerCtrl_0_regs_rowScrollEnable (_main_io_gpuMem_layer_0_regs_rowScrollEnable),
    .io_layerCtrl_0_regs_rowSelectEnable (_main_io_gpuMem_layer_0_regs_rowSelectEnable),
    .io_layerCtrl_0_regs_scroll_x        (_main_io_gpuMem_layer_0_regs_scroll_x),
    .io_layerCtrl_0_regs_scroll_y        (_main_io_gpuMem_layer_0_regs_scroll_y),
    .io_layerCtrl_0_vram8x8_addr         (_main_io_gpuMem_layer_0_vram8x8_addr),
    .io_layerCtrl_0_vram8x8_dout         (_main_io_gpuMem_layer_0_vram8x8_dout),
    .io_layerCtrl_0_vram16x16_addr       (_main_io_gpuMem_layer_0_vram16x16_addr),
    .io_layerCtrl_0_vram16x16_dout       (_main_io_gpuMem_layer_0_vram16x16_dout),
    .io_layerCtrl_0_lineRam_addr         (_main_io_gpuMem_layer_0_lineRam_addr),
    .io_layerCtrl_0_lineRam_dout         (_main_io_gpuMem_layer_0_lineRam_dout),
    .io_layerCtrl_0_tileRom_rd           (_gpu_io_layerCtrl_0_tileRom_rd),
    .io_layerCtrl_0_tileRom_addr         (_gpu_io_layerCtrl_0_tileRom_addr),
    .io_layerCtrl_0_tileRom_dout         (_gpu_io_layerCtrl_0_tileRom_dout),
    .io_layerCtrl_1_enable               (1'b1),
    .io_layerCtrl_1_format               (layer_1_format),
    .io_layerCtrl_1_regs_tileSize        (_main_io_gpuMem_layer_1_regs_tileSize),
    .io_layerCtrl_1_regs_enable          (_main_io_gpuMem_layer_1_regs_enable),
    .io_layerCtrl_1_regs_flipX           (_main_io_gpuMem_layer_1_regs_flipX),
    .io_layerCtrl_1_regs_flipY           (_main_io_gpuMem_layer_1_regs_flipY),
    .io_layerCtrl_1_regs_rowScrollEnable (_main_io_gpuMem_layer_1_regs_rowScrollEnable),
    .io_layerCtrl_1_regs_rowSelectEnable (_main_io_gpuMem_layer_1_regs_rowSelectEnable),
    .io_layerCtrl_1_regs_scroll_x        (_main_io_gpuMem_layer_1_regs_scroll_x),
    .io_layerCtrl_1_regs_scroll_y        (_main_io_gpuMem_layer_1_regs_scroll_y),
    .io_layerCtrl_1_vram8x8_addr         (_main_io_gpuMem_layer_1_vram8x8_addr),
    .io_layerCtrl_1_vram8x8_dout         (_main_io_gpuMem_layer_1_vram8x8_dout),
    .io_layerCtrl_1_vram16x16_addr       (_main_io_gpuMem_layer_1_vram16x16_addr),
    .io_layerCtrl_1_vram16x16_dout       (_main_io_gpuMem_layer_1_vram16x16_dout),
    .io_layerCtrl_1_lineRam_addr         (_main_io_gpuMem_layer_1_lineRam_addr),
    .io_layerCtrl_1_lineRam_dout         (_main_io_gpuMem_layer_1_lineRam_dout),
    .io_layerCtrl_1_tileRom_rd           (_gpu_io_layerCtrl_1_tileRom_rd),
    .io_layerCtrl_1_tileRom_addr         (_gpu_io_layerCtrl_1_tileRom_addr),
    .io_layerCtrl_1_tileRom_dout         (_gpu_io_layerCtrl_1_tileRom_dout),
    .io_layerCtrl_2_enable               (1'b1),
    .io_layerCtrl_2_format               (layer_2_format),
    .io_layerCtrl_2_regs_tileSize        (_main_io_gpuMem_layer_2_regs_tileSize),
    .io_layerCtrl_2_regs_enable          (_main_io_gpuMem_layer_2_regs_enable),
    .io_layerCtrl_2_regs_flipX           (_main_io_gpuMem_layer_2_regs_flipX),
    .io_layerCtrl_2_regs_flipY           (_main_io_gpuMem_layer_2_regs_flipY),
    .io_layerCtrl_2_regs_rowScrollEnable (_main_io_gpuMem_layer_2_regs_rowScrollEnable),
    .io_layerCtrl_2_regs_rowSelectEnable (_main_io_gpuMem_layer_2_regs_rowSelectEnable),
    .io_layerCtrl_2_regs_scroll_x        (_main_io_gpuMem_layer_2_regs_scroll_x),
    .io_layerCtrl_2_regs_scroll_y        (_main_io_gpuMem_layer_2_regs_scroll_y),
    .io_layerCtrl_2_vram8x8_addr         (_main_io_gpuMem_layer_2_vram8x8_addr),
    .io_layerCtrl_2_vram8x8_dout         (_main_io_gpuMem_layer_2_vram8x8_dout),
    .io_layerCtrl_2_vram16x16_addr       (_main_io_gpuMem_layer_2_vram16x16_addr),
    .io_layerCtrl_2_vram16x16_dout       (_main_io_gpuMem_layer_2_vram16x16_dout),
    .io_layerCtrl_2_lineRam_addr         (_main_io_gpuMem_layer_2_lineRam_addr),
    .io_layerCtrl_2_lineRam_dout         (_main_io_gpuMem_layer_2_lineRam_dout),
    .io_layerCtrl_2_tileRom_rd           (_gpu_io_layerCtrl_2_tileRom_rd),
    .io_layerCtrl_2_tileRom_addr         (_gpu_io_layerCtrl_2_tileRom_addr),
    .io_layerCtrl_2_tileRom_dout         (_gpu_io_layerCtrl_2_tileRom_dout),
    .io_pwrinst2Layer2_enable            (1'b0),
    .io_gameConfig_sailormn              (gameIsSailormn),
    .io_layer2TileBank                   (_main_io_layer2TileBank),
    .io_pwrinst2Layer2_regs_tileSize     (_main_io_gpuMem_pwrinst2_layer_2_regs_tileSize),
    .io_pwrinst2Layer2_regs_enable       (_main_io_gpuMem_pwrinst2_layer_2_regs_enable),
    .io_pwrinst2Layer2_regs_flipX        (_main_io_gpuMem_pwrinst2_layer_2_regs_flipX),
    .io_pwrinst2Layer2_regs_flipY        (_main_io_gpuMem_pwrinst2_layer_2_regs_flipY),
    .io_pwrinst2Layer2_regs_rowScrollEnable (_main_io_gpuMem_pwrinst2_layer_2_regs_rowScrollEnable),
    .io_pwrinst2Layer2_regs_rowSelectEnable (_main_io_gpuMem_pwrinst2_layer_2_regs_rowSelectEnable),
    .io_pwrinst2Layer2_regs_scroll_x     (_main_io_gpuMem_pwrinst2_layer_2_regs_scroll_x),
    .io_pwrinst2Layer2_regs_scroll_y     (_main_io_gpuMem_pwrinst2_layer_2_regs_scroll_y),
    .io_pwrinst2Layer2_vram8x8_addr      (_main_io_gpuMem_pwrinst2_layer_2_vram8x8_addr),
    .io_pwrinst2Layer2_vram8x8_dout      (_main_io_gpuMem_pwrinst2_layer_2_vram8x8_dout),
    .io_pwrinst2Layer2_vram16x16_addr    (_main_io_gpuMem_pwrinst2_layer_2_vram16x16_addr),
    .io_pwrinst2Layer2_vram16x16_dout    (_main_io_gpuMem_pwrinst2_layer_2_vram16x16_dout),
    .io_pwrinst2Layer2_lineRam_addr      (_main_io_gpuMem_pwrinst2_layer_2_lineRam_addr),
    .io_pwrinst2Layer2_lineRam_dout      (_main_io_gpuMem_pwrinst2_layer_2_lineRam_dout),
    .io_pwrinst2Layer2_tileRom_rd        (_gpu_io_pwrinst2Layer2_tileRom_rd),
    .io_pwrinst2Layer2_tileRom_addr      (_gpu_io_pwrinst2Layer2_tileRom_addr),
    .io_pwrinst2Layer2_tileRom_dout      (64'd0),
    .io_spriteCtrl_enable                (1'b1),
    .io_spriteCtrl_format                (sprite_format),
    .io_spriteCtrl_pwrinst2              (gameIsPwrInst2),
    .io_gameConfig_plegends              (gameIsPlegends),
    .io_spriteCtrl_start                 (videoVBlankFalling),
    .io_spriteCtrl_zoom                  (gameConfig_sprite_zoom),
    .io_spriteCtrl_regs_offset_x         (_main_io_gpuMem_sprite_regs_offset_x),
    .io_spriteCtrl_regs_offset_y         (_main_io_gpuMem_sprite_regs_offset_y),
    .io_spriteCtrl_regs_bank             (_main_io_gpuMem_sprite_regs_bank),
    .io_spriteCtrl_regs_fixed            (_main_io_gpuMem_sprite_regs_fixed),
    .io_spriteCtrl_regs_hFlip            (_main_io_gpuMem_sprite_regs_hFlip),
    .io_spriteCtrl_vram_rd               (_main_io_gpuMem_sprite_vram_rd),
    .io_spriteCtrl_vram_addr             (_main_io_gpuMem_sprite_vram_addr),
    .io_spriteCtrl_vram_dout             (_main_io_gpuMem_sprite_vram_dout),
    .io_spriteCtrl_tileRom_rd            (spr_rd),
    .io_spriteCtrl_tileRom_addr          (spr_addr),
    .io_spriteCtrl_tileRom_dout          (spr_dout),
    .io_spriteCtrl_tileRom_wait_n        (spr_wait_n),
    .io_spriteCtrl_tileRom_valid         (spr_valid),
    .io_spriteCtrl_tileRom_burstLength   (spr_burst_len),
    .io_spriteCtrl_tileRom_burstDone     (spr_burst_done),
    .io_gameConfig_granularity           (gameConfig_granularity),
    .io_gameConfig_layer_0_paletteBank   (gameConfig_layer_0_paletteBank),
    .io_gameConfig_layer_1_paletteBank   (gameConfig_layer_1_paletteBank),
    .io_gameConfig_layer_2_paletteBank   (gameConfig_layer_2_paletteBank),
    .io_options_rotate                   (1'b0),
    .io_options_rotateClockwise          (rotateClockwise),
    .io_options_flipVideo                (1'b0),
    .io_video_clockEnable                (_videoSys_io_video_clockEnable),
    .io_video_displayEnable              (_videoSys_io_video_displayEnable),
    .io_video_pos_x                      (_videoSys_io_video_pos_x),
    .io_video_pos_y                      (_videoSys_io_video_pos_y),
    .io_video_vBlank                     (_videoSys_io_video_vBlank),
    .io_video_regs_size_x                (_videoSys_io_video_regs_size_x),
    .io_video_regs_size_y                (_videoSys_io_video_regs_size_y),
    .io_spriteLineBuffer_addr            (_gpu_io_spriteLineBuffer_addr),
    .io_spriteLineBuffer_dout            (_gpu_io_spriteLineBuffer_dout),
    .io_spriteFrameBuffer_wr             (_gpu_io_spriteFrameBuffer_wr),
    .io_spriteFrameBuffer_addr           (_gpu_io_spriteFrameBuffer_addr),
    .io_spriteFrameBuffer_din            (_gpu_io_spriteFrameBuffer_din),
    .io_spriteFrameBuffer_wait_n         (_gpu_io_spriteFrameBuffer_wait_n),
    .io_spriteCtrl_frameReady            (),
    .io_systemFrameBuffer_wr             (),
    .io_systemFrameBuffer_addr           (),
    .io_systemFrameBuffer_din            (),
    .io_paletteRam_addr                  (_main_io_gpuMem_paletteRam_addr),
    .io_paletteRam_dout                  (_main_io_gpuMem_paletteRam_dout),
    .io_rgb                              (_gpu_rgb),
    .io_ss_idle                          (),
    .io_ss_reconstruction_ready          ()
  );

  // ------------------------------------- tile ROM: crossings, then caches
  CaveTileRomClockCrossing gpu_io_layerCtrl_0_tileRom_crossing (
    .clock          (clk),
    .reset          (rst),
    .io_targetClock (clk_vid),
    .io_block_new_requests (1'b0),
    .io_in_rd       (_gpu_io_layerCtrl_0_tileRom_rd),
    .io_in_addr     (_gpu_io_layerCtrl_0_tileRom_addr),
    .io_in_dout     (_gpu_io_layerCtrl_0_tileRom_dout),
    .io_out_rd      (_xing_0_rd),
    .io_out_addr    (_xing_0_addr),
    .io_out_dout    (_xing_0_dout),
    .io_out_wait_n  (_xing_0_wait_n),
    .io_out_valid   (_xing_0_valid),
    .io_idle        ()
  );
  CaveTileRomClockCrossing gpu_io_layerCtrl_1_tileRom_crossing (
    .clock          (clk),
    .reset          (rst),
    .io_targetClock (clk_vid),
    .io_block_new_requests (1'b0),
    .io_in_rd       (_gpu_io_layerCtrl_1_tileRom_rd),
    .io_in_addr     (_gpu_io_layerCtrl_1_tileRom_addr),
    .io_in_dout     (_gpu_io_layerCtrl_1_tileRom_dout),
    .io_out_rd      (_xing_1_rd),
    .io_out_addr    (_xing_1_addr),
    .io_out_dout    (_xing_1_dout),
    .io_out_wait_n  (_xing_1_wait_n),
    .io_out_valid   (_xing_1_valid),
    .io_idle        ()
  );
  CaveTileRomClockCrossing gpu_io_layerCtrl_2_tileRom_crossing (
    .clock          (clk),
    .reset          (rst),
    .io_targetClock (clk_vid),
    .io_block_new_requests (1'b0),
    .io_in_rd       (_gpu_io_layerCtrl_2_tileRom_rd),
    .io_in_addr     (_gpu_io_layerCtrl_2_tileRom_addr),
    .io_in_dout     (_gpu_io_layerCtrl_2_tileRom_dout),
    .io_out_rd      (_xing_2_rd),
    .io_out_addr    (_xing_2_addr),
    .io_out_dout    (_xing_2_dout),
    .io_out_wait_n  (_xing_2_wait_n),
    .io_out_valid   (_xing_2_valid),
    .io_idle        ()
  );

  CaveReadCache #(
    .IN_ADDR_WIDTH (32), .IN_DATA_WIDTH (64), .OUT_ADDR_WIDTH (25), .INDEX_WIDTH (3), .TAG_WIDTH (27),
    .RAMSTYLE ("MLAB")
  ) layerRomCache_0 (
    .clock (clk), .reset (rst), .io_enable (rom_loaded),
    .io_in_rd (_xing_0_rd), .io_in_addr (_xing_0_addr), .io_in_dout (_xing_0_dout),
    .io_in_wait_n (_xing_0_wait_n), .io_in_valid (_xing_0_valid),
    .io_out_rd (tile_rd[0]), .io_out_addr (tile_addr[0 +: 25]), .io_out_dout (tile_dout[0 +: 16]),
    .io_out_wait_n (tile_wait_n[0]), .io_out_valid (tile_valid[0])
  );
  CaveReadCache #(
    .IN_ADDR_WIDTH (32), .IN_DATA_WIDTH (64), .OUT_ADDR_WIDTH (25), .INDEX_WIDTH (3), .TAG_WIDTH (27),
    .RAMSTYLE ("MLAB")
  ) layerRomCache_1 (
    .clock (clk), .reset (rst), .io_enable (rom_loaded),
    .io_in_rd (_xing_1_rd), .io_in_addr (_xing_1_addr), .io_in_dout (_xing_1_dout),
    .io_in_wait_n (_xing_1_wait_n), .io_in_valid (_xing_1_valid),
    .io_out_rd (tile_rd[1]), .io_out_addr (tile_addr[25 +: 25]), .io_out_dout (tile_dout[16 +: 16]),
    .io_out_wait_n (tile_wait_n[1]), .io_out_valid (tile_valid[1])
  );
  CaveReadCache #(
    .IN_ADDR_WIDTH (32), .IN_DATA_WIDTH (64), .OUT_ADDR_WIDTH (25), .INDEX_WIDTH (4), .TAG_WIDTH (26),
    .RAMSTYLE ("MLAB")
  ) layerRomCache_2 (
    .clock (clk), .reset (rst), .io_enable (rom_loaded),
    .io_in_rd (_xing_2_rd), .io_in_addr (_xing_2_addr), .io_in_dout (_xing_2_dout),
    .io_in_wait_n (_xing_2_wait_n), .io_in_valid (_xing_2_valid),
    .io_out_rd (tile_rd[2]), .io_out_addr (tile_addr[50 +: 25]), .io_out_dout (tile_dout[32 +: 16]),
    .io_out_wait_n (tile_wait_n[2]), .io_out_valid (tile_valid[2])
  );

  // --------------------------------------------------- sprite frame buffer
  SpriteFrameBuffer spriteFrameBuffer (
    .clock                 (clk),
    .reset                 (rst),
    .io_videoClock         (clk_vid),
    .io_enable             (rom_loaded),
    .io_ss_hold            (1'b0),
    .io_ss_canonicalize    (1'b0),
    .io_swap               (_main_io_spriteFrameBufferSwap),
    .io_video_pos_y        (_videoSys_io_video_pos_y),
    .io_video_regs_size_x  (_videoSys_io_video_regs_size_x),
    .io_video_regs_size_y  (_videoSys_io_video_regs_size_y),
    .io_video_hBlank       (_videoSys_io_video_hBlank),
    .io_lineBuffer_addr    (_gpu_io_spriteLineBuffer_addr),
    .io_lineBuffer_dout    (_gpu_io_spriteLineBuffer_dout),
    .io_frameBuffer_wr     (_gpu_io_spriteFrameBuffer_wr),
    .io_frameBuffer_addr   (_gpu_io_spriteFrameBuffer_addr),
    .io_frameBuffer_din    (_gpu_io_spriteFrameBuffer_din),
    .io_frameBuffer_wait_n (_gpu_io_spriteFrameBuffer_wait_n),
    .io_ddrRd_rd           (fbr_rd),
    .io_ddrRd_addr         (fbr_addr),
    .io_ddrRd_dout         (fbr_dout),
    .io_ddrRd_wait_n       (fbr_wait_n),
    .io_ddrRd_valid        (fbr_valid),
    .io_ddrRd_burstDone    (fbr_burst_done),
    .io_ddr_wr             (fb_wr),
    .io_ddr_addr           (fb_addr),
    .io_ddr_mask           (fb_mask),
    .io_ddr_din            (fb_din),
    .io_ddr_wait_n         (fb_wait_n),
    .io_ddr_burstLength    (fb_burst_len),
    .io_ddr_burstDone      (fb_burst_done),
    .io_ss_idle            ()
  );

  assign spr_swap = _main_io_spriteFrameBufferSwap;

  // --------------------------------------------------------------- video
  assign ce_pix = _videoSys_io_video_clockEnable;
  assign de     = _videoSys_io_video_displayEnable;
  assign hblank = _videoSys_io_video_hBlank;
  assign vblank = _videoSys_io_video_vBlank;
  assign {r, g, b} = _gpu_rgb;

endmodule

`default_nettype wire
