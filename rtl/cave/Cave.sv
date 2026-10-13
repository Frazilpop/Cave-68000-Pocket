// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).

// Core top-level shell connecting MiSTer-facing services to the Cave game hardware.
module Cave(
  input         clock,
  input         reset,
  input         cpuClock,
  input         cpuReset,
  input         videoClock,
  input         videoReset,
  input  [3:0]  options_offset_x,
  input  [3:0]  options_offset_y,
  input         options_rotate,
  input         options_compatibility,
  input         options_service,
  input         options_layer_0,
  input         options_layer_1,
  input         options_layer_2,
  input         options_sprite,
  input         options_flipVideo,
  input  [3:0]  options_gameIndex,
  input         options_debugVideo,
  input  [2:0]  options_debugView,
  input         options_ym_psg,
  input         options_ym_fm,
  input         options_oki_0,
  input         options_oki_1,
  input  [3:0]  options_pwrinst2_oki0_level,
  input  [3:0]  options_pwrinst2_oki1_level,
  input         options_pwrinst2_headroom,
  input  [3:0]  options_pwrinst2_psg_level,
  input  [3:0]  options_pwrinst2_fm_level,
  input  [3:0]  options_ymz_level,
  input         player_0_up,
  input         player_0_down,
  input         player_0_left,
  input         player_0_right,
  input  [3:0]  player_0_buttons,
  input         player_0_start,
  input         player_0_coin,
  input         player_0_pause,
  input         player_1_up,
  input         player_1_down,
  input         player_1_left,
  input         player_1_right,
  input  [3:0]  player_1_buttons,
  input         player_1_start,
  input         player_1_coin,
  input         player_1_pause,
  input         ss_save_request,
  input         ss_load_request,
  input  [1:0]  ss_slot,
  output        ss_available,
  output        ss_active,
  output        ss_busy,
  output [3:0]  ss_state_debug,
  output [3:0]  ss_last_error,
  output [31:0] service_debug,
  output [3:0]  game_index,
  input         ioctl_download,
  input         ioctl_upload,
  input         ioctl_rd,
  input         ioctl_wr,
  output        ioctl_wait_n,
  input  [7:0]  ioctl_index,
  input  [26:0] ioctl_addr,
  output [15:0] ioctl_din,
  input  [15:0] ioctl_dout,
  output        nvram_dirty,
  output        led_power,
  output        led_disk,
  output        led_user,
  output        frameBufferCtrl_enable,
  output [11:0] frameBufferCtrl_hSize,
  output [11:0] frameBufferCtrl_vSize,
  output [4:0]  frameBufferCtrl_format,
  output [31:0] frameBufferCtrl_baseAddr,
  output [13:0] frameBufferCtrl_stride,
  input         frameBufferCtrl_vBlank,
  input         frameBufferCtrl_lowLat,
  output        frameBufferCtrl_forceBlank,
  output        video_clockEnable,
  output        video_displayEnable,
  output [8:0]  video_pos_x,
  output [8:0]  video_pos_y,
  output        video_hSync,
  output        video_vSync,
  output        video_hBlank,
  output        video_vBlank,
  output [8:0]  video_regs_size_x,
  output [8:0]  video_regs_size_y,
  output [8:0]  video_regs_frontPorch_x,
  output [8:0]  video_regs_frontPorch_y,
  output [8:0]  video_regs_retrace_x,
  output [8:0]  video_regs_retrace_y,
  output        video_changeMode,
  output        video_rotated,
  output [23:0] rgb,
  output [15:0] audio,
  output        sdram_cke,
  output        sdram_cs_n,
  output        sdram_ras_n,
  output        sdram_cas_n,
  output        sdram_we_n,
  output        sdram_oe_n,
  output [1:0]  sdram_bank,
  output [12:0] sdram_addr,
  output [15:0] sdram_din,
  input  [15:0] sdram_dout,
  output        ddr_rd,
  output        ddr_wr,
  output [31:0] ddr_addr,
  output [7:0]  ddr_mask,
  output [63:0] ddr_din,
  input  [63:0] ddr_dout,
  input         ddr_wait_n,
  input         ddr_valid,
  output [7:0]  ddr_burstLength,
  input         ddr_burstDone
);

  wire         systemFrameBufferForceBlank;
  wire [63:0]  _gpu_io_layerCtrl_0_tileRom_dout;
  wire [63:0]  _gpu_io_layerCtrl_1_tileRom_dout;
  wire [63:0]  _gpu_io_layerCtrl_2_tileRom_dout;
  wire [63:0]  _gpu_io_pwrinst2Layer2_tileRom_dout;
  wire         _gpu_io_spriteCtrl_start;
  wire         _gpu_io_spriteCtrl_zoom;
  wire [1:0]   _gpu_io_gameConfig_layer_1_paletteBank;
  wire [15:0]  _gpu_io_spriteLineBuffer_dout;
  wire         _gpu_io_spriteFrameBuffer_wait_n;
  wire         _gpu_io_layerCtrl_0_tileRom_rd;
  wire [31:0]  _gpu_io_layerCtrl_0_tileRom_addr;
  wire         _gpu_io_layerCtrl_1_tileRom_rd;
  wire [31:0]  _gpu_io_layerCtrl_1_tileRom_addr;
  wire         _gpu_io_layerCtrl_2_tileRom_rd;
  wire [31:0]  _gpu_io_layerCtrl_2_tileRom_addr;
  wire         _gpu_io_pwrinst2Layer2_tileRom_rd;
  wire [31:0]  _gpu_io_pwrinst2Layer2_tileRom_addr;
  wire [8:0]   _gpu_io_spriteLineBuffer_addr;
  wire         _gpu_io_spriteFrameBuffer_wr;
  wire [16:0]  _gpu_io_spriteFrameBuffer_addr;
  wire [15:0]  _gpu_io_spriteFrameBuffer_din;
  wire         _gpu_io_systemFrameBuffer_wr;
  wire [16:0]  _gpu_io_systemFrameBuffer_addr;
  wire [31:0]  _gpu_io_systemFrameBuffer_din;
  wire         _gpu_io_ss_idle;
  wire         _gpu_io_ss_reconstruction_ready;
  wire         _spriteFrameBuffer_io_ss_idle;
  wire         _systemFrameBuffer_io_ss_idle;
  wire         _layerTileRomCrossing0_io_ss_idle;
  wire         _layerTileRomCrossing1_io_ss_idle;
  wire         _layerTileRomCrossing2_io_ss_idle;
  wire         _pwrinst2LayerTileRomCrossing_io_ss_idle;
  wire [7:0]   _sound_io_rom_0_dout;
  wire         _sound_io_rom_0_wait_n;
  wire         _sound_io_rom_0_valid;
  wire [7:0]   _sound_io_rom_1_dout;
  wire         _sound_io_rom_1_valid;
  wire [7:0]   _sound_io_rom_2_dout;
  wire         _sound_io_rom_2_valid;
  wire         _sound_io_rom_0_rd;
  wire         _sound_io_rom_1_rd;
  wire         _sound_io_rom_2_rd;
  wire [24:0]  _sound_io_rom_0_addr;
  wire [24:0]  _sound_io_rom_1_addr;
  wire [24:0]  _sound_io_rom_2_addr;
  wire [11:0]  _main_io_gpuMem_layer_0_vram8x8_addr;
  wire [9:0]   _main_io_gpuMem_layer_0_vram16x16_addr;
  wire [8:0]   _main_io_gpuMem_layer_0_lineRam_addr;
  wire [11:0]  _main_io_gpuMem_layer_1_vram8x8_addr;
  wire [9:0]   _main_io_gpuMem_layer_1_vram16x16_addr;
  wire [8:0]   _main_io_gpuMem_layer_1_lineRam_addr;
  wire [11:0]  _main_io_gpuMem_layer_2_vram8x8_addr;
  wire [9:0]   _main_io_gpuMem_layer_2_vram16x16_addr;
  wire [8:0]   _main_io_gpuMem_layer_2_lineRam_addr;
  wire [11:0]  _main_io_gpuMem_pwrinst2_layer_2_vram8x8_addr;
  wire [9:0]   _main_io_gpuMem_pwrinst2_layer_2_vram16x16_addr;
  wire [8:0]   _main_io_gpuMem_pwrinst2_layer_2_lineRam_addr;
  wire         _main_io_gpuMem_sprite_vram_rd;
  wire [11:0]  _main_io_gpuMem_sprite_vram_addr;
  wire [14:0]  _main_io_gpuMem_paletteRam_addr;
  reg  [3:0]   gameIndexReg;
  reg          gameIndexReg_latched;
`ifdef CAVE_ENABLE_DEBUG_OVERLAY
  wire [63:0]  _main_io_debug_pipeline;
  wire [63:0]  _main_io_debug_cpu;
  wire [63:0]  _main_io_debug_writes;
  wire [63:0]  _main_io_debug_data;
  wire [63:0]  _main_io_debug_live;
  wire [63:0]  _main_io_debug_palette;
  wire [63:0]  _sound_io_debug;
  wire [63:0]  _gpu_io_debug_video;
  wire [63:0]  _gpu_io_debug_readout;
  wire [23:0]  _gpu_io_debug_source_rgb;
`endif
`ifdef CAVE_PWRINST2_SOUND_DIAGNOSTICS
  wire [255:0] _sound_io_hw_debug;
  reg          pwrinst2DiagCoinD = 1'b0;
  reg          pwrinst2DiagStartD = 1'b0;
  reg  [15:0]  pwrinst2DiagCoinCount = 16'd0;
  reg  [15:0]  pwrinst2DiagStartCount = 16'd0;
  wire [10:0]  pwrinst2DiagInputs = {
    player_0_up,
    player_0_down,
    player_0_left,
    player_0_right,
    player_0_buttons,
    player_0_start,
    player_0_coin,
    player_0_pause
  };
  wire [63:0] pwrinst2DiagInputProbe = {
    16'hC5D2,
    gameIndexReg,
    options_service,
    pwrinst2DiagInputs,
    pwrinst2DiagCoinCount,
    pwrinst2DiagStartCount
  };

  always @(posedge clock) begin
    if (reset) begin
      pwrinst2DiagCoinD <= 1'b0;
      pwrinst2DiagStartD <= 1'b0;
      pwrinst2DiagCoinCount <= 16'd0;
      pwrinst2DiagStartCount <= 16'd0;
    end
    else begin
      pwrinst2DiagCoinD <= player_0_coin;
      pwrinst2DiagStartD <= player_0_start;
      if (player_0_coin && !pwrinst2DiagCoinD)
        pwrinst2DiagCoinCount <= pwrinst2DiagCoinCount + 16'd1;
      if (player_0_start && !pwrinst2DiagStartD)
        pwrinst2DiagStartCount <= pwrinst2DiagStartCount + 16'd1;
    end
  end
`endif
  wire [23:0]  _gpu_rgb;
  wire [15:0]  _main_io_soundCtrl_oki_0_dout;
  wire [15:0]  _main_io_soundCtrl_oki_1_dout;
  wire [15:0]  _main_io_soundCtrl_ymz_dout;
  wire [15:0]  _main_io_soundCtrl_reply;
  wire         _main_io_soundCtrl_irq;
  wire [15:0]  _main_io_progRom_dout;
  wire         _main_io_progRom_valid;
  wire [15:0]  _main_io_eeprom_dout;
  wire         _main_io_eeprom_wait_n;
  wire         _main_io_eeprom_valid;
  wire         _main_io_ss_capture_done;
  wire         _main_io_ss_cpu_idle;
  wire         _main_io_ss_clients_idle;
  wire         _main_io_ss_restore_commit_done;
  wire         _main_io_ss_reconstruction_ready;
  wire         _main_io_ss_blocked_access;
  wire         _sound_io_ss_idle;
  wire         _sound_io_ss_capture_done;
  wire         _sound_io_ss_cpu_idle;
  wire         _sound_io_ss_restore_commit_done;
  wire         _sound_io_ss_reconstruction_ready;
  wire         _main_io_gpuMem_layer_0_regs_tileSize;
  wire         _main_io_gpuMem_layer_0_regs_enable;
  wire         _main_io_gpuMem_layer_0_regs_flipX;
  wire         _main_io_gpuMem_layer_0_regs_flipY;
  wire         _main_io_gpuMem_layer_0_regs_rowScrollEnable;
  wire         _main_io_gpuMem_layer_0_regs_rowSelectEnable;
  wire [8:0]   _main_io_gpuMem_layer_0_regs_scroll_x;
  wire [8:0]   _main_io_gpuMem_layer_0_regs_scroll_y;
  wire [31:0]  _main_io_gpuMem_layer_0_vram8x8_dout;
  wire [31:0]  _main_io_gpuMem_layer_0_vram16x16_dout;
  wire [31:0]  _main_io_gpuMem_layer_0_lineRam_dout;
  wire         _main_io_gpuMem_layer_1_regs_tileSize;
  wire         _main_io_gpuMem_layer_1_regs_enable;
  wire         _main_io_gpuMem_layer_1_regs_flipX;
  wire         _main_io_gpuMem_layer_1_regs_flipY;
  wire         _main_io_gpuMem_layer_1_regs_rowScrollEnable;
  wire         _main_io_gpuMem_layer_1_regs_rowSelectEnable;
  wire [8:0]   _main_io_gpuMem_layer_1_regs_scroll_x;
  wire [8:0]   _main_io_gpuMem_layer_1_regs_scroll_y;
  wire [31:0]  _main_io_gpuMem_layer_1_vram8x8_dout;
  wire [31:0]  _main_io_gpuMem_layer_1_vram16x16_dout;
  wire [31:0]  _main_io_gpuMem_layer_1_lineRam_dout;
  wire         _main_io_gpuMem_layer_2_regs_tileSize;
  wire         _main_io_gpuMem_layer_2_regs_enable;
  wire         _main_io_gpuMem_layer_2_regs_flipX;
  wire         _main_io_gpuMem_layer_2_regs_flipY;
  wire         _main_io_gpuMem_layer_2_regs_rowScrollEnable;
  wire         _main_io_gpuMem_layer_2_regs_rowSelectEnable;
  wire [8:0]   _main_io_gpuMem_layer_2_regs_scroll_x;
  wire [8:0]   _main_io_gpuMem_layer_2_regs_scroll_y;
  wire [31:0]  _main_io_gpuMem_layer_2_vram8x8_dout;
  wire [31:0]  _main_io_gpuMem_layer_2_vram16x16_dout;
  wire [31:0]  _main_io_gpuMem_layer_2_lineRam_dout;
  wire         _main_io_gpuMem_pwrinst2_layer_2_regs_tileSize;
  wire         _main_io_gpuMem_pwrinst2_layer_2_regs_enable;
  wire         _main_io_gpuMem_pwrinst2_layer_2_regs_flipX;
  wire         _main_io_gpuMem_pwrinst2_layer_2_regs_flipY;
  wire         _main_io_gpuMem_pwrinst2_layer_2_regs_rowScrollEnable;
  wire         _main_io_gpuMem_pwrinst2_layer_2_regs_rowSelectEnable;
  wire [8:0]   _main_io_gpuMem_pwrinst2_layer_2_regs_scroll_x;
  wire [8:0]   _main_io_gpuMem_pwrinst2_layer_2_regs_scroll_y;
  wire [31:0]  _main_io_gpuMem_pwrinst2_layer_2_vram8x8_dout;
  wire [31:0]  _main_io_gpuMem_pwrinst2_layer_2_vram16x16_dout;
  wire [31:0]  _main_io_gpuMem_pwrinst2_layer_2_lineRam_dout;
  wire [8:0]   _main_io_gpuMem_sprite_regs_offset_x;
  wire [8:0]   _main_io_gpuMem_sprite_regs_offset_y;
  wire [1:0]   _main_io_gpuMem_sprite_regs_bank;
  wire         _main_io_gpuMem_sprite_regs_fixed;
  wire         _main_io_gpuMem_sprite_regs_hFlip;
  wire [127:0] _main_io_gpuMem_sprite_vram_dout;
  wire [15:0]  _main_io_gpuMem_paletteRam_dout;
  wire         _main_io_soundCtrl_oki_0_wr;
  wire [15:0]  _main_io_soundCtrl_oki_0_din;
  wire         _main_io_soundCtrl_oki_1_wr;
  wire [15:0]  _main_io_soundCtrl_oki_1_din;
  wire         _main_io_soundCtrl_nmk_wr;
  wire [22:0]  _main_io_soundCtrl_nmk_addr;
  wire [15:0]  _main_io_soundCtrl_nmk_din;
  wire         _main_io_soundCtrl_ymz_rd;
  wire         _main_io_soundCtrl_ymz_wr;
  wire [22:0]  _main_io_soundCtrl_ymz_addr;
  wire [15:0]  _main_io_soundCtrl_ymz_din;
  wire         _main_io_soundCtrl_req;
  wire [15:0]  _main_io_soundCtrl_data;
  wire         _main_io_soundCtrl_reply_rd;
  wire         _main_io_soundCtrl_reply_empty;
  wire         _main_io_progRom_rd;
  wire [21:0]  _main_io_progRom_addr;
  wire         _main_io_eeprom_rd;
  wire         _main_io_eeprom_wr;
  wire [6:0]   _main_io_eeprom_addr;
  wire [15:0]  _main_io_eeprom_din;
  wire [15:0]  _main_io_hs_nvram_din;
  wire         _main_io_hs_nvram_wait_n;
  wire         _main_io_hs_dirty;
  wire         _main_io_hs_active;
  wire         _main_io_spriteFrameBufferSwap;
  wire         _gpu_io_spriteCtrl_frameReady;
  wire         _videoSys_io_prog_video_wr;
  wire         _videoSys_io_prog_done;
  wire         _videoSys_io_video_clockEnable;
  wire         _videoSys_io_video_displayEnable;
  wire [8:0]   _videoSys_io_video_pos_x;
  wire [8:0]   _videoSys_io_video_pos_y;
  wire         _videoSys_io_video_hBlank;
  wire         _videoSys_io_video_vBlank;
  wire [8:0]   _videoSys_io_video_regs_size_x;
  wire [8:0]   _videoSys_io_video_regs_size_y;
  wire         _memSys_io_prog_rom_wr;
  wire         _memSys_io_prog_nvram_rd;
  wire         _memSys_io_prog_nvram_wr;
  wire [26:0]  _memSys_io_prog_nvram_addr;
  wire [15:0]  _memSys_io_prog_nvram_din;
  wire         _memSys_io_prog_done;
  wire         _memSys_io_progRom_rd;
  wire [21:0]  _memSys_io_progRom_addr;
  wire         _memSys_io_eeprom_rd;
  wire         _memSys_io_eeprom_wr;
  wire [6:0]   _memSys_io_eeprom_addr;
  wire [15:0]  _memSys_io_eeprom_din;
  wire         _memSys_io_soundRom_0_rd;
  wire [24:0]  _memSys_io_soundRom_0_addr;
  wire         _memSys_io_soundRom_1_rd;
  wire [24:0]  _memSys_io_soundRom_1_addr;
  wire         _memSys_io_soundRom_2_rd;
  wire [24:0]  _memSys_io_soundRom_2_addr;
  wire         _memSys_io_layerTileRom_0_rd;
  wire [31:0]  _memSys_io_layerTileRom_0_addr;
  wire         _memSys_io_layerTileRom_1_rd;
  wire [31:0]  _memSys_io_layerTileRom_1_addr;
  wire         _memSys_io_layerTileRom_2_rd;
  wire [31:0]  _memSys_io_layerTileRom_2_addr;
  wire         _memSys_io_pwrinst2Layer2TileRom_rd;
  wire [31:0]  _memSys_io_pwrinst2Layer2TileRom_addr;
  wire         _memSys_io_spriteTileRom_rd;
  wire [31:0]  _memSys_io_spriteTileRom_addr;
  wire [7:0]   _memSys_io_spriteTileRom_burstLength;
  wire         _memSys_io_spriteFrameBuffer_rd;
  wire         _memSys_io_spriteFrameBuffer_wr;
  wire [31:0]  _memSys_io_spriteFrameBuffer_addr;
  wire [7:0]   _memSys_io_spriteFrameBuffer_mask;
  wire [63:0]  _memSys_io_spriteFrameBuffer_din;
  wire [7:0]   _memSys_io_spriteFrameBuffer_burstLength;
  wire         _memSys_io_systemFrameBuffer_wr;
  wire [31:0]  _memSys_io_systemFrameBuffer_addr;
  wire [7:0]   _memSys_io_systemFrameBuffer_mask;
  wire [63:0]  _memSys_io_systemFrameBuffer_din;
  wire         _memSys_io_prog_rom_wait_n;
  wire [15:0]  _memSys_io_prog_nvram_dout;
  wire         _memSys_io_prog_nvram_wait_n;
  wire         _memSys_io_prog_nvram_valid;
  wire [15:0]  _memSys_io_progRom_dout;
  wire         _memSys_io_progRom_wait_n;
  wire         _memSys_io_progRom_valid;
  wire [15:0]  _memSys_io_eeprom_dout;
  wire         _memSys_io_eeprom_wait_n;
  wire         _memSys_io_eeprom_valid;
  wire [7:0]   _memSys_io_soundRom_0_dout;
  wire         _memSys_io_soundRom_0_wait_n;
  wire         _memSys_io_soundRom_0_valid;
  wire [7:0]   _memSys_io_soundRom_1_dout;
  wire         _memSys_io_soundRom_1_wait_n;
  wire         _memSys_io_soundRom_1_valid;
  wire [7:0]   _memSys_io_soundRom_2_dout;
  wire         _memSys_io_soundRom_2_wait_n;
  wire         _memSys_io_soundRom_2_valid;
  wire [63:0]  _memSys_io_layerTileRom_0_dout;
  wire         _memSys_io_layerTileRom_0_wait_n;
  wire         _memSys_io_layerTileRom_0_valid;
  wire [63:0]  _memSys_io_layerTileRom_1_dout;
  wire         _memSys_io_layerTileRom_1_wait_n;
  wire         _memSys_io_layerTileRom_1_valid;
  wire [63:0]  _memSys_io_layerTileRom_2_dout;
  wire         _memSys_io_layerTileRom_2_wait_n;
  wire         _memSys_io_layerTileRom_2_valid;
  wire [63:0]  _memSys_io_pwrinst2Layer2TileRom_dout;
  wire         _memSys_io_pwrinst2Layer2TileRom_wait_n;
  wire         _memSys_io_pwrinst2Layer2TileRom_valid;
  wire [63:0]  _memSys_io_spriteTileRom_dout;
  wire         _memSys_io_spriteTileRom_wait_n;
  wire         _memSys_io_spriteTileRom_valid;
  wire         _memSys_io_spriteTileRom_burstDone;
  wire [63:0]  _memSys_io_spriteFrameBuffer_dout;
  wire         _memSys_io_spriteFrameBuffer_wait_n;
  wire         _memSys_io_spriteFrameBuffer_valid;
  wire         _memSys_io_spriteFrameBuffer_burstDone;
  wire         _memSys_io_systemFrameBuffer_wait_n;
  wire         _memSys_io_ready;
  wire         _sdram_1_io_mem_rd;
  wire         _sdram_1_io_mem_wr;
  wire [24:0]  _sdram_1_io_mem_addr;
  wire [15:0]  _sdram_1_io_mem_din;
  wire [15:0]  _sdram_1_io_mem_dout;
  wire         _sdram_1_io_mem_wait_n;
  wire         _sdram_1_io_mem_valid;
  wire         _sdram_1_io_mem_burstDone;
  wire         _ddr_1_io_mem_rd;
  wire         _ddr_1_io_mem_wr;
  wire [31:0]  _ddr_1_io_mem_addr;
  wire [7:0]   _ddr_1_io_mem_mask;
  wire [63:0]  _ddr_1_io_mem_din;
  wire [7:0]   _ddr_1_io_mem_burstLength;
  wire [63:0]  _ddr_1_io_mem_dout;
  wire         _ddr_1_io_mem_wait_n;
  wire         _ddr_1_io_mem_valid;
  wire         _ddr_1_io_mem_burstDone;
  wire         _ddr_1_idle;
  wire         _ddr_game_rd;
  wire         _ddr_game_wr;
  wire [31:0]  _ddr_game_addr;
  wire [7:0]   _ddr_game_mask;
  wire [63:0]  _ddr_game_din;
  wire [7:0]   _ddr_game_burstLength;
  wire [63:0]  _ddr_game_dout;
  wire         _ddr_game_wait_n;
  wire         _ddr_game_valid;
  wire         dipsRegsWr;
  wire [1:0]   dipsRegsAddr;
  wire [15:0]  _dipsRegs_io_regs_0;
  reg          videoVBlankPipe0;
  reg          videoVBlankPipe1;
  reg          videoVBlankPipe2;
  reg          gameIndexCpuLoadToggle = 1'b0;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg          gameIndexCpuToggleSync0 = 1'b0;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg          gameIndexCpuToggleSync1 = 1'b0;
  reg          gameIndexCpuToggleSeen = 1'b0;
  reg  [3:0]   gameIndexCpuReg = 4'h0;
  reg          ioctlDownloadReg;
  wire [8:0]   gameConfig_granularity;
  wire [31:0]  gameConfig_eepromOffset;
  wire [1:0]   gameConfig_sound_0_device;
  wire [1:0]   gameConfigCpu_sound_0_device;
  wire [31:0]  gameConfig_sound_0_romOffset;
  wire [31:0]  gameConfig_sound_1_romOffset;
  wire [31:0]  gameConfig_sound_2_romOffset;
  wire [1:0]   gpu_io_layerCtrl_0_format;
  wire [31:0]  gameConfig_layer_0_romOffset;
  wire [1:0]   gameConfig_layer_0_paletteBank;
  wire [1:0]   gpu_io_layerCtrl_1_format;
  wire [31:0]  gameConfig_layer_1_romOffset;
  wire [1:0]   gameConfig_layer_1_paletteBank;
  wire [1:0]   gpu_io_layerCtrl_2_format;
  wire [31:0]  gameConfig_layer_2_romOffset;
  wire [31:0]  gameConfig_pwrinst2_layer_2_romOffset;
  wire [1:0]   gameConfig_layer_2_paletteBank;
  wire [1:0]   gpu_io_spriteCtrl_format;
  wire [31:0]  gameConfig_sprite_romOffset;
  wire         gameConfig_sprite_zoom;
  wire         gameIsPwrInst2;
  wire         gameIsPlegends;
  wire         rotateClockwise;

`ifdef CAVE_HW_DIAGNOSTICS
  wire [11:0]  memSysHwDebug;
`ifdef CAVE_SIGNALTAP_BOOT_DIAGNOSTIC
  wire [2:0]   caveHwDiagSource;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg          caveDiagnosticResetSystemSync0 = 1'b0;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg          caveDiagnosticResetSystemSync1 = 1'b0;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg          caveDiagnosticResetCpuSync0 = 1'b0;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg          caveDiagnosticResetCpuSync1 = 1'b0;
`ifdef CAVE_SIGNALTAP_BOOT_HOLD
  reg  [1:0]   caveBootHoldSync = 2'b11;
`endif
`else
  wire [0:0]   caveHwDiagSource;
`endif
  wire [127:0] caveHwDiagProbe;
`endif

`ifdef CAVE_SIGNALTAP_BOOT_DIAGNOSTIC
  wire effectiveCpuReset =
    cpuReset | caveDiagnosticResetCpuSync1;
  wire diagnosticBridgeReset =
    reset | caveDiagnosticResetSystemSync1;
  wire diagnosticTargetBridgeReset =
    reset | caveDiagnosticResetCpuSync1;
`else
  wire effectiveCpuReset = cpuReset;
  wire diagnosticBridgeReset = reset;
  wire diagnosticTargetBridgeReset = reset;
`endif

  localparam [63:0] SS_CPU_OWNER_MASK =
    64'h0000_007F_E2F9_FFFC;
  localparam [63:0] SS_YMZ_SUPPORT_BITMAP =
    64'h0000_0000_E379_FFFD;
  localparam [63:0] SS_DONPACHI_SUPPORT_BITMAP =
    64'h0000_0070_0379_FFFD;
  localparam [63:0] SS_PWRINST2_SUPPORT_BITMAP =
    64'h0000_007F_03F9_FFFD;
  wire [63:0] ssSupportBitmap =
    gameIndexReg == 4'd2 ? SS_DONPACHI_SUPPORT_BITMAP :
    (gameIndexReg == 4'd7 || gameIndexReg == 4'd8) ?
      SS_PWRINST2_SUPPORT_BITMAP :
      SS_YMZ_SUPPORT_BITMAP;

  cave_ss_ddr_if ssDdr();
  cave_ssbus_if ssStreamBus();
  cave_ssbus_if ssSystemOwners[3]();
  cave_ssbus_if ssCpuBus();
  cave_ssbus_if ssCpuOwners[2]();

  wire         ssStreamBusy;
  wire         ssStreamDone;
  wire         ssStreamFormatError;
  wire         ssControllerActive;
  wire         ssFreeze;
  wire         ssBlockClients;
  wire         ssCpuHoldRequest;
  wire         ssCpuCaptureRequest;
  wire         ssStreamSaveStart;
  wire         ssStreamLoadStart;
  wire         ssMetadataRestoreStart;
  wire         ssStreamAbort;
  wire         ssRestoreWriteEnable;
  wire         ssRestoreCommitRequest;
  wire         ssReleasePulse;
  wire         ssRecoveryReset;
  wire         ssRestoreComplete;
  wire         ssRestoreValid;
  wire         ssCpuCaptureDoneSystem;
  wire         ssCpuIdleSystem;
  wire         ssCpuClientsIdleSystem;
  wire         ssCpuCommitDoneSystem;
  wire         ssCpuReconstructionReadySystem;
  wire         ssCpuCaptureRequestCpu;
  wire         ssCpuHoldCpu;
  wire         ssRestoreStartCpu;
  wire         ssRestoreCommitCpu;
  wire         ssReleaseCpu;
  wire         ssRecoveryResetCpu;
  wire         ssRestoreEnableCpu;
  wire         ssDdrGranted;
  wire         ssRomIdentityValid;
  wire [31:0]  ssRomSize;
  wire [63:0]  ssRomSignature;
  wire         ssNvramRd;
  wire         ssNvramWr;
  wire [6:0]   ssNvramAddr;
  wire [15:0]  ssNvramDin;
  wire         ssNvramBusy;
  wire [31:0]  ssSetId = {24'h434156, 4'd0, gameIndexReg};
  reg  [3:0]   ssVideoIdleCount;
  wire         ssCanonicalizeSystem =
    ssRestoreCommitRequest | ssRecoveryReset;
  wire         ssVideoClientsIdleRaw =
    _gpu_io_ss_idle &
    _spriteFrameBuffer_io_ss_idle &
    _systemFrameBuffer_io_ss_idle &
    _layerTileRomCrossing0_io_ss_idle &
    _layerTileRomCrossing1_io_ss_idle &
    _layerTileRomCrossing2_io_ss_idle &
    _pwrinst2LayerTileRomCrossing_io_ss_idle;
  wire         ssVideoClientsIdle = &ssVideoIdleCount;
  wire         ssGameplaySourcesIdle =
    ssCpuIdleSystem & ssCpuClientsIdleSystem & ssVideoClientsIdle;
  wire         ssCpuCaptureDoneCombined =
    _main_io_ss_capture_done & _sound_io_ss_capture_done;
  wire         ssCpuIdleCombined =
    _main_io_ss_cpu_idle & _sound_io_ss_cpu_idle;
  wire         ssReconstructionReadyCombined =
    _main_io_ss_reconstruction_ready &
    _sound_io_ss_reconstruction_ready;
  reg          ssMainCommitSeen = 1'b0;
  reg          ssSoundCommitSeen = 1'b0;
  reg          ssCombinedCommitReported = 1'b0;
  reg          ssCombinedCommitDone = 1'b0;

  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg          cpuResetSystemSync0 = 1'b1;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg          cpuResetSystemSync1 = 1'b1;

  CaveGameConfig gameConfig (
    .game_index           (gameIndexReg),
    .granularity          (gameConfig_granularity),
    .eeprom_offset        (gameConfig_eepromOffset),
    .sound_0_device       (gameConfig_sound_0_device),
    .sound_0_rom_offset   (gameConfig_sound_0_romOffset),
    .sound_1_rom_offset   (gameConfig_sound_1_romOffset),
    .sound_2_rom_offset   (gameConfig_sound_2_romOffset),
    .layer_0_format       (gpu_io_layerCtrl_0_format),
    .layer_0_rom_offset   (gameConfig_layer_0_romOffset),
    .layer_0_palette_bank (gameConfig_layer_0_paletteBank),
    .layer_1_format       (gpu_io_layerCtrl_1_format),
    .layer_1_rom_offset   (gameConfig_layer_1_romOffset),
    .layer_1_palette_bank (gameConfig_layer_1_paletteBank),
    .layer_2_format       (gpu_io_layerCtrl_2_format),
    .layer_2_rom_offset   (gameConfig_layer_2_romOffset),
    .pwrinst2_layer_2_rom_offset (gameConfig_pwrinst2_layer_2_romOffset),
    .layer_2_palette_bank (gameConfig_layer_2_paletteBank),
    .sprite_format        (gpu_io_spriteCtrl_format),
    .sprite_rom_offset    (gameConfig_sprite_romOffset),
    .sprite_zoom          (gameConfig_sprite_zoom)
  );

  CaveGameConfig gameConfigCpu (
    .game_index           (gameIndexCpuReg),
    .granularity          (),
    .eeprom_offset        (),
    .sound_0_device       (gameConfigCpu_sound_0_device),
    .sound_0_rom_offset   (),
    .sound_1_rom_offset   (),
    .sound_2_rom_offset   (),
    .layer_0_format       (),
    .layer_0_rom_offset   (),
    .layer_0_palette_bank (),
    .layer_1_format       (),
    .layer_1_rom_offset   (),
    .layer_1_palette_bank (),
    .layer_2_format       (),
    .layer_2_rom_offset   (),
    .pwrinst2_layer_2_rom_offset (),
    .layer_2_palette_bank (),
    .sprite_format        (),
    .sprite_rom_offset    (),
    .sprite_zoom          ()
  );

  CaveBoardProfile boardProfile(
    .game_index                  (gameIndexReg),
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
  wire         ioctlRomIndexSelected = ioctl_index == 8'h0;
  wire         memSys_io_prog_rom_writeEnable = ioctl_download & ioctlRomIndexSelected;
  wire         ioctlNvramIndexSelected = ioctl_index == 8'h2;
  wire         ioctlNvramEepromAddress = ioctl_addr < 27'd128;
  wire         ioctlNvramEepromReadEnable =
    ioctl_upload & ioctlNvramIndexSelected & ioctlNvramEepromAddress;
  wire         ioctlNvramEepromWriteEnable =
    ioctl_download & ioctlNvramIndexSelected & ioctlNvramEepromAddress;
  wire         ioctlNvramHighScoreReadEnable =
    ioctl_upload & ioctlNvramIndexSelected & ~ioctlNvramEepromAddress;
  wire         memSys_io_prog_nvram_writeEnable =
    ioctlNvramEepromWriteEnable;
  wire [15:0]  ioctlNvramEepromDout;
  wire         ioctlNvramEepromUploadWaitN;
  wire         ioctlNvramEepromMemRd;
  wire [6:0]   ioctlNvramEepromMemAddr;
  wire         ioctlNvramAccess =
    (ioctl_upload | ioctl_download) & ioctlNvramIndexSelected;
  wire         ioctlNvramEepromWaitN = ioctl_upload
    ? ioctlNvramEepromUploadWaitN
    : _memSys_io_prog_nvram_wait_n;
  wire         ioctlNvramWaitN = _main_io_hs_nvram_wait_n &
    (~ioctlNvramEepromAddress | ioctlNvramEepromWaitN);
  wire         ioctlMemoryWaitN =
    ioctlNvramAccess
      ? ioctlNvramWaitN
      : ~memSys_io_prog_rom_writeEnable | _memSys_io_prog_rom_wait_n;
  reg          memSysIoctlDownloadReg;
  wire         ioctlVideoIndexSelected = ioctl_index == 8'h3;
  wire         videoSys_io_prog_video_writeEnable =
    ioctl_download & ioctlVideoIndexSelected;
  reg          videoSysIoctlDownloadReg;
  wire         ioctlHighScoreConfigSelected = ioctl_index == 8'h4;
  reg          eepromDirtyReg;
  reg          nvramUploadReg;
  wire         ssControllerReset = reset | cpuResetSystemSync1;
  wire         ssBusReset = ssControllerReset | ssRecoveryReset;
  wire         cpuDomainResetBase;
`ifdef CAVE_SIGNALTAP_BOOT_HOLD
  wire         cpuDomainReset = cpuDomainResetBase | caveBootHoldSync[1];
`else
  wire         cpuDomainReset = cpuDomainResetBase;
`endif
  wire         ioctlGameIndexWrite = ioctl_download & ioctl_wr & ioctl_index == 8'h1;
  wire         optionGameIndexFallback =
    ~ioctl_download & ioctlDownloadReg & ~gameIndexReg_latched;
  wire         effectiveRotate = options_rotate;
  assign game_index = gameIndexReg;
  wire         videoVBlankFalling = ~videoVBlankPipe1 & videoVBlankPipe2;
  wire         spriteFrameBufferSwap = _main_io_spriteFrameBufferSwap;

  CaveCpuResetBridge cpuResetBridge (
    .clock            (cpuClock),
    .cpu_reset        (effectiveCpuReset),
    .mem_ready_async  (_memSys_io_ready),
    .recovery_reset   (ssRecoveryResetCpu),
    .cpu_domain_reset (cpuDomainResetBase)
  );

`ifdef CAVE_SIGNALTAP_BOOT_DIAGNOSTIC
  always @(posedge clock) begin
    caveDiagnosticResetSystemSync0 <= caveHwDiagSource[2];
    caveDiagnosticResetSystemSync1 <= caveDiagnosticResetSystemSync0;
  end

  always @(posedge cpuClock) begin
    caveDiagnosticResetCpuSync0 <= caveHwDiagSource[2];
    caveDiagnosticResetCpuSync1 <= caveDiagnosticResetCpuSync0;
  end
`endif

`ifdef CAVE_SIGNALTAP_BOOT_HOLD
  always @(posedge cpuClock)
    caveBootHoldSync <= {caveBootHoldSync[0], caveHwDiagSource[1]};
`endif

  always @(posedge cpuClock) begin
    gameIndexCpuToggleSync0 <= gameIndexCpuLoadToggle;
    gameIndexCpuToggleSync1 <= gameIndexCpuToggleSync0;
    if (gameIndexCpuToggleSync1 != gameIndexCpuToggleSeen) begin
      gameIndexCpuReg <= gameIndexReg;
      gameIndexCpuToggleSeen <= gameIndexCpuToggleSync1;
    end
  end

  always @(posedge cpuClock) begin
    ssCombinedCommitDone <= 1'b0;

    if (cpuDomainReset | ssRestoreStartCpu | ssReleaseCpu) begin
      ssMainCommitSeen <= 1'b0;
      ssSoundCommitSeen <= 1'b0;
      ssCombinedCommitReported <= 1'b0;
    end else begin
      if (_main_io_ss_restore_commit_done)
        ssMainCommitSeen <= 1'b1;
      if (_sound_io_ss_restore_commit_done)
        ssSoundCommitSeen <= 1'b1;

      if (!ssCombinedCommitReported &&
          (ssMainCommitSeen | _main_io_ss_restore_commit_done) &&
          (ssSoundCommitSeen | _sound_io_ss_restore_commit_done)) begin
        ssCombinedCommitDone <= 1'b1;
        ssCombinedCommitReported <= 1'b1;
      end
    end
  end

  always @(posedge clock) begin
    if (ssControllerReset | ~ssBlockClients | ~ssVideoClientsIdleRaw)
      ssVideoIdleCount <= 4'd0;
    else if (~(&ssVideoIdleCount))
      ssVideoIdleCount <= ssVideoIdleCount + 4'd1;

    cpuResetSystemSync0 <= effectiveCpuReset;
    cpuResetSystemSync1 <= cpuResetSystemSync0;
    videoVBlankPipe0 <= _videoSys_io_video_vBlank;
    videoVBlankPipe1 <= videoVBlankPipe0;
    videoVBlankPipe2 <= videoVBlankPipe1;
    if (optionGameIndexFallback)
      gameIndexReg <= options_gameIndex;
    else if (ioctlGameIndexWrite)
      gameIndexReg <= ioctl_dout[3:0];
    if (reset)
      gameIndexCpuLoadToggle <= 1'b0;
    else if (optionGameIndexFallback | ioctlGameIndexWrite)
      gameIndexCpuLoadToggle <= ~gameIndexCpuLoadToggle;
    ioctlDownloadReg <= ioctl_download;
    memSysIoctlDownloadReg <= ioctl_download;
    videoSysIoctlDownloadReg <= ioctl_download;
    if (reset) begin
      nvramUploadReg <= 1'b0;
      eepromDirtyReg <= 1'b0;
    end else begin
      nvramUploadReg <= ioctl_upload & ioctlNvramIndexSelected;
      if ((ioctl_upload & ioctlNvramIndexSelected) & ~nvramUploadReg)
        eepromDirtyReg <= 1'b0;
      if (_memSys_io_eeprom_wr)
        eepromDirtyReg <= 1'b1;
    end
    if (reset)
      gameIndexReg_latched <= 1'b0;
    else
      gameIndexReg_latched <=
        optionGameIndexFallback | ioctlGameIndexWrite | gameIndexReg_latched;
  end // always @(posedge)

  CaveNvramUploadPrefetch nvramUploadPrefetch (
    .clock         (clock),
    .reset         (reset),
    .upload        (ioctlNvramEepromReadEnable),
    .upload_addr   (ioctl_addr),
    .upload_dout   (ioctlNvramEepromDout),
    .upload_wait_n (ioctlNvramEepromUploadWaitN),
    .mem_rd        (ioctlNvramEepromMemRd),
    .mem_addr      (ioctlNvramEepromMemAddr),
    .mem_dout      (_memSys_io_prog_nvram_dout),
    .mem_wait_n    (_memSys_io_prog_nvram_wait_n),
    .mem_valid     (_memSys_io_prog_nvram_valid)
  );

  assign dipsRegsWr =
    ioctl_download & ioctl_index == 8'hFE & ioctl_addr[26:3] == 24'h0 & ioctl_wr;
  assign dipsRegsAddr = ioctl_addr[2:1];
  CaveSingleRegisterFile dipsRegs (
    .clock       (clock),
    .io_mem_wr   (dipsRegsWr),
    .io_mem_addr (dipsRegsAddr),
    .io_mem_din  (ioctl_dout),
    .io_ss_wr    (1'b0),
    .io_ss_din   (16'd0),
    .io_regs_0   (_dipsRegs_io_regs_0)
  );

  CaveSaveStateBusMux #(.COUNT(3)) saveStateSystemBusMux (
    .clk     (clock),
    .owners  (ssSystemOwners),
    .stream  (ssStreamBus)
  );

  CaveSaveStateMetadata saveStateMetadata (
    .clk                    (clock),
    .reset                  (ssBusReset),
    .restore_start          (ssMetadataRestoreStart),
    .current_game_id        ({4'd0, gameIndexReg}),
    .current_set_id         (ssSetId),
    .current_rom_size       (ssRomSize),
    .current_rom_signature  (ssRomSignature),
    .current_support_bitmap (ssSupportBitmap),
    .restore_complete       (ssRestoreComplete),
    .restore_valid          (ssRestoreValid),
    .restored_game_id       (),
    .restored_rom_signature (),
    .ssbus                  (ssSystemOwners[0])
  );

  CaveSaveStateNvram saveStateNvram (
    .clk            (clock),
    .reset          (ssBusReset),
    .state_enable   (ssBlockClients &
                     ssCpuIdleSystem &
                     ssCpuClientsIdleSystem),
    .restore_enable (ssRestoreWriteEnable),
    .mem_rd         (ssNvramRd),
    .mem_wr         (ssNvramWr),
    .mem_addr       (ssNvramAddr),
    .mem_din        (ssNvramDin),
    .mem_dout       (_memSys_io_prog_nvram_dout),
    .mem_wait_n     (_memSys_io_prog_nvram_wait_n),
    .mem_valid      (_memSys_io_prog_nvram_valid),
    .busy           (ssNvramBusy),
    .blocked_access (),
    .ssbus          (ssSystemOwners[2])
  );

  CaveSaveStateBusCdc #(
    .SELECT_MASK(SS_CPU_OWNER_MASK)
  ) saveStateCpuBusCdc (
    .src_clk            (clock),
    .src_reset          (ssBusReset),
    .src_restore_enable (ssRestoreWriteEnable),
    .src_select_mask    (ssSupportBitmap),
    .src_bus            (ssSystemOwners[1]),
    .dst_clk            (cpuClock),
    .dst_reset          (cpuDomainReset),
    .dst_restore_enable (ssRestoreEnableCpu),
    .dst_bus            (ssCpuBus)
  );

  CaveSaveStateBusMux #(.COUNT(2)) saveStateCpuBusMux (
    .clk     (cpuClock),
    .owners  (ssCpuOwners),
    .stream  (ssCpuBus)
  );

  CaveSaveStateCpuControlCdc saveStateCpuControlCdc (
    .src_clk                       (clock),
    .src_reset                     (ssControllerReset),
    .src_capture_request           (ssCpuCaptureRequest),
    .src_hold                      (ssCpuHoldRequest),
    .src_restore_start             (ssMetadataRestoreStart),
    .src_restore_commit            (ssRestoreCommitRequest),
    .src_release                   (ssReleasePulse),
    .src_recovery_reset            (ssRecoveryReset),
    .src_capture_done              (ssCpuCaptureDoneSystem),
    .src_cpu_idle                  (ssCpuIdleSystem),
    .src_clients_idle              (ssCpuClientsIdleSystem),
    .src_restore_commit_done       (ssCpuCommitDoneSystem),
    .src_reconstruction_ready      (ssCpuReconstructionReadySystem),
    .dst_clk                       (cpuClock),
    .dst_reset                     (effectiveCpuReset),
    .dst_capture_request           (ssCpuCaptureRequestCpu),
    .dst_hold                      (ssCpuHoldCpu),
    .dst_restore_start             (ssRestoreStartCpu),
    .dst_restore_commit            (ssRestoreCommitCpu),
    .dst_release                   (ssReleaseCpu),
    .dst_recovery_reset            (ssRecoveryResetCpu),
    .dst_capture_done              (ssCpuCaptureDoneCombined),
    .dst_cpu_idle                  (ssCpuIdleCombined),
    .dst_clients_idle              (_main_io_ss_clients_idle &
                                    _sound_io_ss_idle),
    .dst_restore_commit_done       (ssCombinedCommitDone),
    .dst_reconstruction_ready      (ssReconstructionReadyCombined)
  );

  CaveSaveStateController saveStateController (
    .clk                     (clock),
    .reset                   (ssControllerReset),
    .allow                   (ss_available),
    .save_request            (ss_save_request),
    .load_request            (ss_load_request),
    .vblank                  (videoVBlankPipe2),
    .cpu_capture_done        (ssCpuCaptureDoneSystem),
    .clients_idle            (ssCpuIdleSystem &
                              ssCpuClientsIdleSystem &
                              ssVideoClientsIdle &
                              _ddr_1_idle),
    .stream_busy             (ssStreamBusy),
    .stream_done             (ssStreamDone),
    .stream_format_error     (ssStreamFormatError),
    .restore_valid           (ssRestoreValid),
    .restore_commit_done     (ssCpuCommitDoneSystem),
    .reconstruction_ready    (ssCpuReconstructionReadySystem &
                              _gpu_io_ss_reconstruction_ready),
    .active                  (ssControllerActive),
    .freeze                  (ssFreeze),
    .block_clients           (ssBlockClients),
    .cpu_hold                (ssCpuHoldRequest),
    .cpu_capture_request     (ssCpuCaptureRequest),
    .stream_save_start       (ssStreamSaveStart),
    .stream_load_start       (ssStreamLoadStart),
    .metadata_restore_start  (ssMetadataRestoreStart),
    .stream_abort            (ssStreamAbort),
    .restore_write_enable    (ssRestoreWriteEnable),
    .restore_commit_request  (ssRestoreCommitRequest),
    .release_pulse           (ssReleasePulse),
    .recovery_reset          (ssRecoveryReset),
    .state_debug             (ss_state_debug),
    .last_error              (ss_last_error)
  );

  CaveSaveStateData #(
    .DDR_BASE    (32'h3e00_0000),
    .SLOT_LENGTH (32'h0040_0000),
    .CHUNK_COUNT (48)
  ) saveStateData (
    .clk          (clock),
    .reset        (ssBusReset),
    .ddr          (ssDdr),
    .load_start   (ssStreamLoadStart),
    .save_start   (ssStreamSaveStart),
    .abort        (ssStreamAbort),
    .slot         (ss_slot),
    .busy         (ssStreamBusy),
    .done         (ssStreamDone),
    .format_error (ssStreamFormatError),
    .ssbus        (ssStreamBus)
  );

  assign ss_available = _memSys_io_ready & ssRomIdentityValid &
                        ~ioctl_download & ~_main_io_hs_active;
  assign ss_active = ssControllerActive;
  assign ss_busy = ssStreamBusy;

  DDR ddr_1 (
    .clock              (clock),
    .reset              (reset),
    .io_block_new_requests(ssBlockClients & ssGameplaySourcesIdle),
    .io_mem_rd          (_ddr_1_io_mem_rd),
    .io_mem_wr          (_ddr_1_io_mem_wr),
    .io_mem_addr        (_ddr_1_io_mem_addr),
    .io_mem_mask        (_ddr_1_io_mem_mask),
    .io_mem_din         (_ddr_1_io_mem_din),
    .io_mem_dout        (_ddr_1_io_mem_dout),
    .io_mem_wait_n      (_ddr_1_io_mem_wait_n),
    .io_mem_valid       (_ddr_1_io_mem_valid),
    .io_mem_burstLength (_ddr_1_io_mem_burstLength),
    .io_mem_burstDone   (_ddr_1_io_mem_burstDone),
    .io_ddr_rd          (_ddr_game_rd),
    .io_ddr_wr          (_ddr_game_wr),
    .io_ddr_addr        (_ddr_game_addr),
    .io_ddr_mask        (_ddr_game_mask),
    .io_ddr_din         (_ddr_game_din),
    .io_ddr_dout        (_ddr_game_dout),
    .io_ddr_wait_n      (_ddr_game_wait_n),
    .io_ddr_valid       (_ddr_game_valid),
    .io_ddr_burstLength (_ddr_game_burstLength),
    .io_idle            (_ddr_1_idle)
  );

  CaveSaveStateDdrArbiter saveStateDdrArbiter (
    .clk               (clock),
    .reset             (reset),
    .game_idle         (_ddr_1_idle),
    .game_rd           (_ddr_game_rd),
    .game_wr           (_ddr_game_wr),
    .game_addr         (_ddr_game_addr),
    .game_mask         (_ddr_game_mask),
    .game_din          (_ddr_game_din),
    .game_burst_length (_ddr_game_burstLength),
    .game_dout         (_ddr_game_dout),
    .game_wait_n       (_ddr_game_wait_n),
    .game_valid        (_ddr_game_valid),
    .save              (ssDdr),
    .ddr_rd            (ddr_rd),
    .ddr_wr            (ddr_wr),
    .ddr_addr          (ddr_addr),
    .ddr_mask          (ddr_mask),
    .ddr_din           (ddr_din),
    .ddr_burst_length  (ddr_burstLength),
    .ddr_dout          (ddr_dout),
    .ddr_wait_n        (ddr_wait_n),
    .ddr_valid         (ddr_valid),
    .save_granted      (ssDdrGranted)
  );
  SDRAM sdram_1 (
    .clock            (clock),
    .reset            (reset),
    .io_mem_rd        (_sdram_1_io_mem_rd),
    .io_mem_wr        (_sdram_1_io_mem_wr),
    .io_mem_addr      (_sdram_1_io_mem_addr),
    .io_mem_din       (_sdram_1_io_mem_din),
    .io_mem_dout      (_sdram_1_io_mem_dout),
    .io_mem_wait_n    (_sdram_1_io_mem_wait_n),
    .io_mem_valid     (_sdram_1_io_mem_valid),
    .io_mem_burstDone (_sdram_1_io_mem_burstDone),
    .io_sdram_cs_n    (sdram_cs_n),
    .io_sdram_ras_n   (sdram_ras_n),
    .io_sdram_cas_n   (sdram_cas_n),
    .io_sdram_we_n    (sdram_we_n),
    .io_sdram_oe_n    (sdram_oe_n),
    .io_sdram_bank    (sdram_bank),
    .io_sdram_addr    (sdram_addr),
    .io_sdram_din     (sdram_din),
    .io_sdram_dout    (sdram_dout)
  );
  assign _memSys_io_prog_rom_wr = memSys_io_prog_rom_writeEnable & ioctl_wr;
  assign _memSys_io_prog_nvram_rd =
    ssNvramRd | ioctlNvramEepromMemRd;
  assign _memSys_io_prog_nvram_wr =
    ssNvramWr | (memSys_io_prog_nvram_writeEnable & ioctl_wr);
  assign _memSys_io_prog_nvram_addr =
    (ssNvramRd | ssNvramWr) ? {20'd0, ssNvramAddr} :
    ioctlNvramEepromReadEnable ? {20'd0, ioctlNvramEepromMemAddr} :
    ioctl_addr;
  assign _memSys_io_prog_nvram_din = ssNvramWr ? ssNvramDin : ioctl_dout;
  assign _memSys_io_prog_done =
    ~ioctl_download & memSysIoctlDownloadReg & ioctlRomIndexSelected;
  MemSys memSys (
    .clock                            (clock),
    .reset                            (reset),
    .io_gameIndex                     (gameIndexReg),
    .io_gameConfig_eepromOffset       (gameConfig_eepromOffset),
    .io_gameConfig_sound_0_romOffset  (gameConfig_sound_0_romOffset),
    .io_gameConfig_sound_1_romOffset  (gameConfig_sound_1_romOffset),
    .io_gameConfig_sound_2_romOffset  (gameConfig_sound_2_romOffset),
    .io_gameConfig_layer_0_romOffset  (gameConfig_layer_0_romOffset),
    .io_gameConfig_layer_1_romOffset  (gameConfig_layer_1_romOffset),
    .io_gameConfig_layer_2_romOffset  (gameConfig_layer_2_romOffset),
    .io_gameConfig_pwrinst2_layer_2_romOffset (gameConfig_pwrinst2_layer_2_romOffset),
    .io_gameConfig_sprite_romOffset   (gameConfig_sprite_romOffset),
    .io_prog_rom_wr                   (_memSys_io_prog_rom_wr),
    .io_prog_rom_addr                 (ioctl_addr),
    .io_prog_rom_din                  (ioctl_dout),
    .io_prog_rom_wait_n               (_memSys_io_prog_rom_wait_n),
    .io_prog_nvram_rd                 (_memSys_io_prog_nvram_rd),
    .io_prog_nvram_wr                 (_memSys_io_prog_nvram_wr),
    .io_prog_nvram_addr               (_memSys_io_prog_nvram_addr),
    .io_prog_nvram_din                (_memSys_io_prog_nvram_din),
    .io_prog_nvram_dout               (_memSys_io_prog_nvram_dout),
    .io_prog_nvram_wait_n             (_memSys_io_prog_nvram_wait_n),
    .io_prog_nvram_valid              (_memSys_io_prog_nvram_valid),
    .io_prog_done                     (_memSys_io_prog_done),
    .io_progRom_rd                    (_memSys_io_progRom_rd),
    .io_progRom_addr                  (_memSys_io_progRom_addr),
    .io_progRom_dout                  (_memSys_io_progRom_dout),
    .io_progRom_wait_n                (_memSys_io_progRom_wait_n),
    .io_progRom_valid                 (_memSys_io_progRom_valid),
    .io_eeprom_rd                     (_memSys_io_eeprom_rd),
    .io_eeprom_wr                     (_memSys_io_eeprom_wr),
    .io_eeprom_addr                   (_memSys_io_eeprom_addr),
    .io_eeprom_din                    (_memSys_io_eeprom_din),
    .io_eeprom_dout                   (_memSys_io_eeprom_dout),
    .io_eeprom_wait_n                 (_memSys_io_eeprom_wait_n),
    .io_eeprom_valid                  (_memSys_io_eeprom_valid),
    .io_soundRom_0_rd                 (_memSys_io_soundRom_0_rd),
    .io_soundRom_0_addr               (_memSys_io_soundRom_0_addr),
    .io_soundRom_0_dout               (_memSys_io_soundRom_0_dout),
    .io_soundRom_0_wait_n             (_memSys_io_soundRom_0_wait_n),
    .io_soundRom_0_valid              (_memSys_io_soundRom_0_valid),
    .io_soundRom_1_rd                 (_memSys_io_soundRom_1_rd),
    .io_soundRom_1_addr               (_memSys_io_soundRom_1_addr),
    .io_soundRom_1_dout               (_memSys_io_soundRom_1_dout),
    .io_soundRom_1_wait_n             (_memSys_io_soundRom_1_wait_n),
    .io_soundRom_1_valid              (_memSys_io_soundRom_1_valid),
    .io_soundRom_2_rd                 (_memSys_io_soundRom_2_rd),
    .io_soundRom_2_addr               (_memSys_io_soundRom_2_addr),
    .io_soundRom_2_dout               (_memSys_io_soundRom_2_dout),
    .io_soundRom_2_wait_n             (_memSys_io_soundRom_2_wait_n),
    .io_soundRom_2_valid              (_memSys_io_soundRom_2_valid),
    .io_layerTileRom_0_rd             (_memSys_io_layerTileRom_0_rd),
    .io_layerTileRom_0_addr           (_memSys_io_layerTileRom_0_addr),
    .io_layerTileRom_0_dout           (_memSys_io_layerTileRom_0_dout),
    .io_layerTileRom_0_wait_n         (_memSys_io_layerTileRom_0_wait_n),
    .io_layerTileRom_0_valid          (_memSys_io_layerTileRom_0_valid),
    .io_layerTileRom_1_rd             (_memSys_io_layerTileRom_1_rd),
    .io_layerTileRom_1_addr           (_memSys_io_layerTileRom_1_addr),
    .io_layerTileRom_1_dout           (_memSys_io_layerTileRom_1_dout),
    .io_layerTileRom_1_wait_n         (_memSys_io_layerTileRom_1_wait_n),
    .io_layerTileRom_1_valid          (_memSys_io_layerTileRom_1_valid),
    .io_layerTileRom_2_rd             (_memSys_io_layerTileRom_2_rd),
    .io_layerTileRom_2_addr           (_memSys_io_layerTileRom_2_addr),
    .io_layerTileRom_2_dout           (_memSys_io_layerTileRom_2_dout),
    .io_layerTileRom_2_wait_n         (_memSys_io_layerTileRom_2_wait_n),
    .io_layerTileRom_2_valid          (_memSys_io_layerTileRom_2_valid),
    .io_pwrinst2Layer2TileRom_rd      (_memSys_io_pwrinst2Layer2TileRom_rd),
    .io_pwrinst2Layer2TileRom_addr    (_memSys_io_pwrinst2Layer2TileRom_addr),
    .io_pwrinst2Layer2TileRom_dout    (_memSys_io_pwrinst2Layer2TileRom_dout),
    .io_pwrinst2Layer2TileRom_wait_n  (_memSys_io_pwrinst2Layer2TileRom_wait_n),
    .io_pwrinst2Layer2TileRom_valid   (_memSys_io_pwrinst2Layer2TileRom_valid),
    .io_spriteTileRom_rd              (_memSys_io_spriteTileRom_rd),
    .io_spriteTileRom_addr            (_memSys_io_spriteTileRom_addr),
    .io_spriteTileRom_dout            (_memSys_io_spriteTileRom_dout),
    .io_spriteTileRom_wait_n          (_memSys_io_spriteTileRom_wait_n),
    .io_spriteTileRom_valid           (_memSys_io_spriteTileRom_valid),
    .io_spriteTileRom_burstLength     (_memSys_io_spriteTileRom_burstLength),
    .io_spriteTileRom_burstDone       (_memSys_io_spriteTileRom_burstDone),
    .io_ddr_rd                        (_ddr_1_io_mem_rd),
    .io_ddr_wr                        (_ddr_1_io_mem_wr),
    .io_ddr_addr                      (_ddr_1_io_mem_addr),
    .io_ddr_mask                      (_ddr_1_io_mem_mask),
    .io_ddr_din                       (_ddr_1_io_mem_din),
    .io_ddr_dout                      (_ddr_1_io_mem_dout),
    .io_ddr_wait_n                    (_ddr_1_io_mem_wait_n),
    .io_ddr_valid                     (_ddr_1_io_mem_valid),
    .io_ddr_burstLength               (_ddr_1_io_mem_burstLength),
    .io_ddr_burstDone                 (_ddr_1_io_mem_burstDone),
    .io_sdram_rd                      (_sdram_1_io_mem_rd),
    .io_sdram_wr                      (_sdram_1_io_mem_wr),
    .io_sdram_addr                    (_sdram_1_io_mem_addr),
    .io_sdram_din                     (_sdram_1_io_mem_din),
    .io_sdram_dout                    (_sdram_1_io_mem_dout),
    .io_sdram_wait_n                  (_sdram_1_io_mem_wait_n),
    .io_sdram_valid                   (_sdram_1_io_mem_valid),
    .io_sdram_burstDone               (_sdram_1_io_mem_burstDone),
    .io_spriteFrameBuffer_rd          (_memSys_io_spriteFrameBuffer_rd),
    .io_spriteFrameBuffer_wr          (_memSys_io_spriteFrameBuffer_wr),
    .io_spriteFrameBuffer_addr        (_memSys_io_spriteFrameBuffer_addr),
    .io_spriteFrameBuffer_mask        (_memSys_io_spriteFrameBuffer_mask),
    .io_spriteFrameBuffer_din         (_memSys_io_spriteFrameBuffer_din),
    .io_spriteFrameBuffer_dout        (_memSys_io_spriteFrameBuffer_dout),
    .io_spriteFrameBuffer_wait_n      (_memSys_io_spriteFrameBuffer_wait_n),
    .io_spriteFrameBuffer_valid       (_memSys_io_spriteFrameBuffer_valid),
    .io_spriteFrameBuffer_burstLength (_memSys_io_spriteFrameBuffer_burstLength),
    .io_spriteFrameBuffer_burstDone   (_memSys_io_spriteFrameBuffer_burstDone),
    .io_systemFrameBuffer_wr          (_memSys_io_systemFrameBuffer_wr),
    .io_systemFrameBuffer_addr        (_memSys_io_systemFrameBuffer_addr),
    .io_systemFrameBuffer_mask        (_memSys_io_systemFrameBuffer_mask),
    .io_systemFrameBuffer_din         (_memSys_io_systemFrameBuffer_din),
    .io_systemFrameBuffer_wait_n      (_memSys_io_systemFrameBuffer_wait_n),
    .io_romIdentity_valid             (ssRomIdentityValid),
    .io_romIdentity_size              (ssRomSize),
    .io_romIdentity_signature         (ssRomSignature),
    .io_ready                         (_memSys_io_ready)
`ifdef CAVE_HW_DIAGNOSTICS
    ,
    .io_hw_debug                      (memSysHwDebug)
`endif
  );
  assign _videoSys_io_prog_video_wr = videoSys_io_prog_video_writeEnable & ioctl_wr;
  assign _videoSys_io_prog_done =
    ~ioctl_download & videoSysIoctlDownloadReg & ioctlVideoIndexSelected;
  VideoSys videoSys (
    .clock                      (clock),
    .reset                      (reset),
    .io_videoClock              (videoClock),
    .io_videoReset              (videoReset),
    .io_prog_video_wr           (_videoSys_io_prog_video_wr),
    .io_prog_video_addr         (ioctl_addr),
    .io_prog_video_din          (ioctl_dout),
    .io_prog_done               (_videoSys_io_prog_done),
    .io_options_offset_x        (options_offset_x),
    .io_options_offset_y        (options_offset_y),
    .io_options_compatibility   (options_compatibility),
    .io_options_wideTiming      (1'b0),
    .io_video_clockEnable       (_videoSys_io_video_clockEnable),
    .io_video_displayEnable     (_videoSys_io_video_displayEnable),
    .io_video_pos_x             (_videoSys_io_video_pos_x),
    .io_video_pos_y             (_videoSys_io_video_pos_y),
    .io_video_hSync             (video_hSync),
    .io_video_vSync             (video_vSync),
    .io_video_hBlank            (_videoSys_io_video_hBlank),
    .io_video_vBlank            (_videoSys_io_video_vBlank),
    .io_video_regs_size_x       (_videoSys_io_video_regs_size_x),
    .io_video_regs_size_y       (_videoSys_io_video_regs_size_y),
    .io_video_regs_frontPorch_x (video_regs_frontPorch_x),
    .io_video_regs_frontPorch_y (video_regs_frontPorch_y),
    .io_video_regs_retrace_x    (video_regs_retrace_x),
    .io_video_regs_retrace_y    (video_regs_retrace_y),
    .io_video_changeMode        (video_changeMode)
  );
  Main main (
    .clock                                  (cpuClock),
    .reset                                  (cpuDomainReset),
    .io_systemClock                         (clock),
    .io_systemReset                         (reset),
    .io_highScoreReset                      (effectiveCpuReset),
    .io_videoClock                          (videoClock),
    .io_spriteClock                         (clock),
    .io_gameIndex                           (gameIndexCpuReg),
    .io_options_service                     (options_service),
    .io_player_0_up                         (player_0_up),
    .io_player_0_down                       (player_0_down),
    .io_player_0_left                       (player_0_left),
    .io_player_0_right                      (player_0_right),
    .io_player_0_buttons                    (player_0_buttons),
    .io_player_0_start                      (player_0_start),
    .io_player_0_coin                       (player_0_coin),
    .io_player_0_pause                      (player_0_pause),
    .io_player_1_up                         (player_1_up),
    .io_player_1_down                       (player_1_down),
    .io_player_1_left                       (player_1_left),
    .io_player_1_right                      (player_1_right),
    .io_player_1_buttons                    (player_1_buttons),
    .io_player_1_start                      (player_1_start),
    .io_player_1_coin                       (player_1_coin),
    .io_player_1_pause                      (player_1_pause),
    .io_dips_0                              (_dipsRegs_io_regs_0),
    .io_video_vBlank                        (_videoSys_io_video_vBlank),
    .io_gpuMem_layer_0_regs_tileSize        (_main_io_gpuMem_layer_0_regs_tileSize),
    .io_gpuMem_layer_0_regs_enable          (_main_io_gpuMem_layer_0_regs_enable),
    .io_gpuMem_layer_0_regs_flipX           (_main_io_gpuMem_layer_0_regs_flipX),
    .io_gpuMem_layer_0_regs_flipY           (_main_io_gpuMem_layer_0_regs_flipY),
    .io_gpuMem_layer_0_regs_rowScrollEnable
      (_main_io_gpuMem_layer_0_regs_rowScrollEnable),
    .io_gpuMem_layer_0_regs_rowSelectEnable
      (_main_io_gpuMem_layer_0_regs_rowSelectEnable),
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
    .io_gpuMem_layer_1_regs_rowScrollEnable
      (_main_io_gpuMem_layer_1_regs_rowScrollEnable),
    .io_gpuMem_layer_1_regs_rowSelectEnable
      (_main_io_gpuMem_layer_1_regs_rowSelectEnable),
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
    .io_gpuMem_layer_2_regs_rowScrollEnable
      (_main_io_gpuMem_layer_2_regs_rowScrollEnable),
    .io_gpuMem_layer_2_regs_rowSelectEnable
      (_main_io_gpuMem_layer_2_regs_rowSelectEnable),
    .io_gpuMem_layer_2_regs_scroll_x        (_main_io_gpuMem_layer_2_regs_scroll_x),
    .io_gpuMem_layer_2_regs_scroll_y        (_main_io_gpuMem_layer_2_regs_scroll_y),
    .io_gpuMem_layer_2_vram8x8_addr         (_main_io_gpuMem_layer_2_vram8x8_addr),
    .io_gpuMem_layer_2_vram8x8_dout         (_main_io_gpuMem_layer_2_vram8x8_dout),
    .io_gpuMem_layer_2_vram16x16_addr       (_main_io_gpuMem_layer_2_vram16x16_addr),
    .io_gpuMem_layer_2_vram16x16_dout       (_main_io_gpuMem_layer_2_vram16x16_dout),
    .io_gpuMem_layer_2_lineRam_addr         (_main_io_gpuMem_layer_2_lineRam_addr),
    .io_gpuMem_layer_2_lineRam_dout         (_main_io_gpuMem_layer_2_lineRam_dout),
    .io_gpuMem_pwrinst2_layer_2_regs_tileSize
      (_main_io_gpuMem_pwrinst2_layer_2_regs_tileSize),
    .io_gpuMem_pwrinst2_layer_2_regs_enable
      (_main_io_gpuMem_pwrinst2_layer_2_regs_enable),
    .io_gpuMem_pwrinst2_layer_2_regs_flipX
      (_main_io_gpuMem_pwrinst2_layer_2_regs_flipX),
    .io_gpuMem_pwrinst2_layer_2_regs_flipY
      (_main_io_gpuMem_pwrinst2_layer_2_regs_flipY),
    .io_gpuMem_pwrinst2_layer_2_regs_rowScrollEnable
      (_main_io_gpuMem_pwrinst2_layer_2_regs_rowScrollEnable),
    .io_gpuMem_pwrinst2_layer_2_regs_rowSelectEnable
      (_main_io_gpuMem_pwrinst2_layer_2_regs_rowSelectEnable),
    .io_gpuMem_pwrinst2_layer_2_regs_scroll_x
      (_main_io_gpuMem_pwrinst2_layer_2_regs_scroll_x),
    .io_gpuMem_pwrinst2_layer_2_regs_scroll_y
      (_main_io_gpuMem_pwrinst2_layer_2_regs_scroll_y),
    .io_gpuMem_pwrinst2_layer_2_vram8x8_addr
      (_main_io_gpuMem_pwrinst2_layer_2_vram8x8_addr),
    .io_gpuMem_pwrinst2_layer_2_vram8x8_dout
      (_main_io_gpuMem_pwrinst2_layer_2_vram8x8_dout),
    .io_gpuMem_pwrinst2_layer_2_vram16x16_addr
      (_main_io_gpuMem_pwrinst2_layer_2_vram16x16_addr),
    .io_gpuMem_pwrinst2_layer_2_vram16x16_dout
      (_main_io_gpuMem_pwrinst2_layer_2_vram16x16_dout),
    .io_gpuMem_pwrinst2_layer_2_lineRam_addr
      (_main_io_gpuMem_pwrinst2_layer_2_lineRam_addr),
    .io_gpuMem_pwrinst2_layer_2_lineRam_dout
      (_main_io_gpuMem_pwrinst2_layer_2_lineRam_dout),
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
    .io_soundCtrl_req                       (_main_io_soundCtrl_req),
    .io_soundCtrl_data                      (_main_io_soundCtrl_data),
    .io_soundCtrl_reply_rd                  (_main_io_soundCtrl_reply_rd),
    .io_soundCtrl_reply                     (_main_io_soundCtrl_reply),
    .io_soundCtrl_reply_empty               (_main_io_soundCtrl_reply_empty),
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
    .io_hs_config_download                  (ioctl_download &
                                             ioctlHighScoreConfigSelected),
    .io_hs_config_wr                        (ioctl_wr),
    .io_hs_config_addr                      (ioctl_addr),
    .io_hs_config_dout                      (ioctl_dout),
    .io_hs_nvram_download                   (ioctl_download &
                                             ioctlNvramIndexSelected),
    .io_hs_nvram_upload                     (ioctl_upload &
                                             ioctlNvramIndexSelected),
    .io_hs_nvram_rd                         (ioctl_rd),
    .io_hs_nvram_wr                         (ioctl_wr),
    .io_hs_nvram_addr                       (ioctl_addr),
    .io_hs_nvram_dout                       (ioctl_dout),
    .io_hs_nvram_din                        (_main_io_hs_nvram_din),
    .io_hs_nvram_wait_n                     (_main_io_hs_nvram_wait_n),
    .io_hs_dirty                            (_main_io_hs_dirty),
    .io_hs_active                           (_main_io_hs_active),
    .io_spriteFrameBufferSwap               (_main_io_spriteFrameBufferSwap),
    .io_ss_hold                             (ssCpuHoldCpu),
    .io_ss_capture_request                  (ssCpuCaptureRequestCpu),
    .io_ss_restore_enable                   (ssRestoreEnableCpu),
    .io_ss_restore_start                    (ssRestoreStartCpu),
    .io_ss_restore_commit                   (ssRestoreCommitCpu),
    .io_ss_release                          (ssReleaseCpu),
    .io_ss_capture_done                     (_main_io_ss_capture_done),
    .io_ss_cpu_idle                         (_main_io_ss_cpu_idle),
    .io_ss_clients_idle                     (_main_io_ss_clients_idle),
    .io_ss_restore_commit_done              (_main_io_ss_restore_commit_done),
    .io_ss_reconstruction_ready             (_main_io_ss_reconstruction_ready),
    .io_ss_blocked_access                   (_main_io_ss_blocked_access),
    .io_service_debug                       (service_debug),
    .io_ssbus                               (ssCpuOwners[0])
`ifdef CAVE_ENABLE_DEBUG_OVERLAY
    ,
    .io_debug_pipeline                      (_main_io_debug_pipeline),
    .io_debug_cpu                           (_main_io_debug_cpu),
    .io_debug_writes                        (_main_io_debug_writes),
    .io_debug_data                          (_main_io_debug_data),
    .io_debug_live                          (_main_io_debug_live),
    .io_debug_palette                       (_main_io_debug_palette)
`endif
  );
  CaveProgramRomReadFreezer main_io_progRom_freezer (
    .clock          (clock),
    .reset          (diagnosticBridgeReset),
    .io_targetClock (cpuClock),
    .io_targetReset (diagnosticTargetBridgeReset),
    .io_in_rd       (_main_io_progRom_rd),
    .io_in_addr     (_main_io_progRom_addr),
    .io_in_dout     (_main_io_progRom_dout),
    .io_in_valid    (_main_io_progRom_valid),
    .io_out_rd      (_memSys_io_progRom_rd),
    .io_out_addr    (_memSys_io_progRom_addr),
    .io_out_dout    (_memSys_io_progRom_dout),
    .io_out_wait_n  (_memSys_io_progRom_wait_n),
    .io_out_valid   (_memSys_io_progRom_valid)
  );
  CaveEepromDataFreezer main_io_eeprom_freezer (
    .clock          (clock),
    .reset          (reset),
    .io_targetClock (cpuClock),
    .io_in_rd       (_main_io_eeprom_rd),
    .io_in_wr       (_main_io_eeprom_wr),
    .io_in_addr     (_main_io_eeprom_addr),
    .io_in_din      (_main_io_eeprom_din),
    .io_in_dout     (_main_io_eeprom_dout),
    .io_in_wait_n   (_main_io_eeprom_wait_n),
    .io_in_valid    (_main_io_eeprom_valid),
    .io_out_rd      (_memSys_io_eeprom_rd),
    .io_out_wr      (_memSys_io_eeprom_wr),
    .io_out_addr    (_memSys_io_eeprom_addr),
    .io_out_din     (_memSys_io_eeprom_din),
    .io_out_dout    (_memSys_io_eeprom_dout),
    .io_out_wait_n  (_memSys_io_eeprom_wait_n),
    .io_out_valid   (_memSys_io_eeprom_valid)
  );
  Sound sound (
    .clock                        (cpuClock),
    .reset                        (cpuDomainReset),
    .io_ctrl_oki_0_wr             (_main_io_soundCtrl_oki_0_wr),
    .io_ctrl_oki_0_din            (_main_io_soundCtrl_oki_0_din),
    .io_ctrl_oki_0_dout           (_main_io_soundCtrl_oki_0_dout),
    .io_ctrl_oki_1_wr             (_main_io_soundCtrl_oki_1_wr),
    .io_ctrl_oki_1_din            (_main_io_soundCtrl_oki_1_din),
    .io_ctrl_oki_1_dout           (_main_io_soundCtrl_oki_1_dout),
    .io_ctrl_nmk_wr               (_main_io_soundCtrl_nmk_wr),
    .io_ctrl_nmk_addr             (_main_io_soundCtrl_nmk_addr),
    .io_ctrl_nmk_din              (_main_io_soundCtrl_nmk_din),
    .io_ctrl_ymz_rd               (_main_io_soundCtrl_ymz_rd),
    .io_ctrl_ymz_wr               (_main_io_soundCtrl_ymz_wr),
    .io_ctrl_ymz_addr             (_main_io_soundCtrl_ymz_addr),
    .io_ctrl_ymz_din              (_main_io_soundCtrl_ymz_din),
    .io_ctrl_ymz_dout             (_main_io_soundCtrl_ymz_dout),
    .io_ctrl_req                  (_main_io_soundCtrl_req),
    .io_ctrl_data                 (_main_io_soundCtrl_data),
    .io_ctrl_reply_rd             (_main_io_soundCtrl_reply_rd),
    .io_ctrl_reply                (_main_io_soundCtrl_reply),
    .io_ctrl_reply_empty          (_main_io_soundCtrl_reply_empty),
    .io_ctrl_irq                  (_main_io_soundCtrl_irq),
    .io_gameIndex                 (gameIndexCpuReg),
    .io_gameConfig_sound_0_device (gameConfigCpu_sound_0_device),
    .io_options_ym_psg            (options_ym_psg),
    .io_options_ym_fm             (options_ym_fm),
    .io_options_oki_0             (options_oki_0),
    .io_options_oki_1             (options_oki_1),
    .io_options_pwrinst2_oki0_level (options_pwrinst2_oki0_level),
    .io_options_pwrinst2_oki1_level (options_pwrinst2_oki1_level),
    .io_options_pwrinst2_headroom (options_pwrinst2_headroom),
    .io_options_pwrinst2_psg_level (options_pwrinst2_psg_level),
    .io_options_pwrinst2_fm_level  (options_pwrinst2_fm_level),
    .io_options_ymz_level           (options_ymz_level),
    .io_rom_0_rd                  (_sound_io_rom_0_rd),
    .io_rom_0_addr                (_sound_io_rom_0_addr),
    .io_rom_0_dout                (_sound_io_rom_0_dout),
    .io_rom_0_wait_n              (_sound_io_rom_0_wait_n),
    .io_rom_0_valid               (_sound_io_rom_0_valid),
    .io_rom_1_rd                  (_sound_io_rom_1_rd),
    .io_rom_1_addr                (_sound_io_rom_1_addr),
    .io_rom_1_dout                (_sound_io_rom_1_dout),
    .io_rom_1_valid               (_sound_io_rom_1_valid),
    .io_rom_2_rd                  (_sound_io_rom_2_rd),
    .io_rom_2_addr                (_sound_io_rom_2_addr),
    .io_rom_2_dout                (_sound_io_rom_2_dout),
    .io_rom_2_valid               (_sound_io_rom_2_valid),
`ifdef CAVE_ENABLE_DEBUG_OVERLAY
    .io_debug                     (_sound_io_debug),
`endif
`ifdef CAVE_PWRINST2_SOUND_DIAGNOSTICS
    .io_hw_debug                  (_sound_io_hw_debug),
`endif
    .io_audio                     (audio),
    .io_ss_hold                   (ssCpuHoldCpu),
    .io_ss_capture_request        (ssCpuCaptureRequestCpu),
    .io_ss_restore_enable         (ssRestoreEnableCpu),
    .io_ss_restore_start          (ssRestoreStartCpu),
    .io_ss_restore_commit         (ssRestoreCommitCpu),
    .io_ss_release                (ssReleaseCpu),
    .io_ss_capture_done           (_sound_io_ss_capture_done),
    .io_ss_cpu_idle               (_sound_io_ss_cpu_idle),
    .io_ss_restore_commit_done    (
      _sound_io_ss_restore_commit_done
    ),
    .io_ss_reconstruction_ready   (
      _sound_io_ss_reconstruction_ready
    ),
    .io_ss_idle                   (_sound_io_ss_idle),
    .io_ssbus                     (ssCpuOwners[1])
  );
  CaveSoundRomReadFreezer sound_io_rom_0_freezer (
    .clock          (clock),
    .reset          (reset),
    .io_targetClock (cpuClock),
    .io_hold_response(gameConfigCpu_sound_0_device == 2'h3),
    .io_in_rd       (_sound_io_rom_0_rd),
    .io_in_addr     (_sound_io_rom_0_addr),
    .io_in_dout     (_sound_io_rom_0_dout),
    .io_in_wait_n   (_sound_io_rom_0_wait_n),
    .io_in_valid    (_sound_io_rom_0_valid),
    .io_out_rd      (_memSys_io_soundRom_0_rd),
    .io_out_addr    (_memSys_io_soundRom_0_addr),
    .io_out_dout    (_memSys_io_soundRom_0_dout),
    .io_out_wait_n  (_memSys_io_soundRom_0_wait_n),
    .io_out_valid   (_memSys_io_soundRom_0_valid)
  );
  CaveSoundRomReadFreezer sound_io_rom_1_freezer (
    .clock          (clock),
    .reset          (reset),
    .io_targetClock (cpuClock),
    .io_hold_response(gameConfigCpu_sound_0_device == 2'h3),
    .io_in_rd       (_sound_io_rom_1_rd),
    .io_in_addr     (_sound_io_rom_1_addr),
    .io_in_dout     (_sound_io_rom_1_dout),
    .io_in_wait_n   (/* unused */),
    .io_in_valid    (_sound_io_rom_1_valid),
    .io_out_rd      (_memSys_io_soundRom_1_rd),
    .io_out_addr    (_memSys_io_soundRom_1_addr),
    .io_out_dout    (_memSys_io_soundRom_1_dout),
    .io_out_wait_n  (_memSys_io_soundRom_1_wait_n),
    .io_out_valid   (_memSys_io_soundRom_1_valid)
  );
  CaveSoundRomReadFreezer sound_io_rom_2_freezer (
    .clock          (clock),
    .reset          (reset),
    .io_targetClock (cpuClock),
    .io_hold_response(gameConfigCpu_sound_0_device == 2'h3),
    .io_in_rd       (_sound_io_rom_2_rd),
    .io_in_addr     (_sound_io_rom_2_addr),
    .io_in_dout     (_sound_io_rom_2_dout),
    .io_in_wait_n   (/* unused */),
    .io_in_valid    (_sound_io_rom_2_valid),
    .io_out_rd      (_memSys_io_soundRom_2_rd),
    .io_out_addr    (_memSys_io_soundRom_2_addr),
    .io_out_dout    (_memSys_io_soundRom_2_dout),
    .io_out_wait_n  (_memSys_io_soundRom_2_wait_n),
    .io_out_valid   (_memSys_io_soundRom_2_valid)
  );
  assign _gpu_io_spriteCtrl_start = videoVBlankFalling;
  assign _gpu_io_spriteCtrl_zoom = gameConfig_sprite_zoom;
  assign _gpu_io_gameConfig_layer_1_paletteBank = gameConfig_layer_1_paletteBank;
  GPU gpu (
    .clock                               (clock),
    .reset                               (reset),
    .io_videoClock                       (videoClock),
    .io_ss_hold                          (ssBlockClients),
    .io_ss_canonicalize                  (ssCanonicalizeSystem),
    .io_layerCtrl_0_enable               (options_layer_0),
    .io_layerCtrl_0_format               (gpu_io_layerCtrl_0_format),
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
    .io_layerCtrl_1_enable               (options_layer_1),
    .io_layerCtrl_1_format               (gpu_io_layerCtrl_1_format),
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
    .io_layerCtrl_2_enable               (options_layer_2),
    .io_layerCtrl_2_format               (gpu_io_layerCtrl_2_format),
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
    .io_pwrinst2Layer2_enable            (options_layer_2 & gameIsPwrInst2),
    .io_pwrinst2Layer2_regs_tileSize     (_main_io_gpuMem_pwrinst2_layer_2_regs_tileSize),
    .io_pwrinst2Layer2_regs_enable       (_main_io_gpuMem_pwrinst2_layer_2_regs_enable),
    .io_pwrinst2Layer2_regs_flipX        (_main_io_gpuMem_pwrinst2_layer_2_regs_flipX),
    .io_pwrinst2Layer2_regs_flipY        (_main_io_gpuMem_pwrinst2_layer_2_regs_flipY),
    .io_pwrinst2Layer2_regs_rowScrollEnable
      (_main_io_gpuMem_pwrinst2_layer_2_regs_rowScrollEnable),
    .io_pwrinst2Layer2_regs_rowSelectEnable
      (_main_io_gpuMem_pwrinst2_layer_2_regs_rowSelectEnable),
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
    .io_pwrinst2Layer2_tileRom_dout      (_gpu_io_pwrinst2Layer2_tileRom_dout),
    .io_spriteCtrl_enable                (options_sprite),
    .io_spriteCtrl_format                (gpu_io_spriteCtrl_format),
    .io_spriteCtrl_pwrinst2              (gameIsPwrInst2),
    .io_gameConfig_plegends              (gameIsPlegends),
    .io_spriteCtrl_start                 (_gpu_io_spriteCtrl_start),
    .io_spriteCtrl_zoom                  (_gpu_io_spriteCtrl_zoom),
    .io_spriteCtrl_regs_offset_x         (_main_io_gpuMem_sprite_regs_offset_x),
    .io_spriteCtrl_regs_offset_y         (_main_io_gpuMem_sprite_regs_offset_y),
    .io_spriteCtrl_regs_bank             (_main_io_gpuMem_sprite_regs_bank),
    .io_spriteCtrl_regs_fixed            (_main_io_gpuMem_sprite_regs_fixed),
    .io_spriteCtrl_regs_hFlip            (_main_io_gpuMem_sprite_regs_hFlip),
    .io_spriteCtrl_vram_rd               (_main_io_gpuMem_sprite_vram_rd),
    .io_spriteCtrl_vram_addr             (_main_io_gpuMem_sprite_vram_addr),
    .io_spriteCtrl_vram_dout             (_main_io_gpuMem_sprite_vram_dout),
    .io_spriteCtrl_tileRom_rd            (_memSys_io_spriteTileRom_rd),
    .io_spriteCtrl_tileRom_addr          (_memSys_io_spriteTileRom_addr),
    .io_spriteCtrl_tileRom_dout          (_memSys_io_spriteTileRom_dout),
    .io_spriteCtrl_tileRom_wait_n        (_memSys_io_spriteTileRom_wait_n),
    .io_spriteCtrl_tileRom_valid         (_memSys_io_spriteTileRom_valid),
    .io_spriteCtrl_tileRom_burstLength   (_memSys_io_spriteTileRom_burstLength),
    .io_spriteCtrl_tileRom_burstDone     (_memSys_io_spriteTileRom_burstDone),
    .io_gameConfig_granularity           (gameConfig_granularity),
    .io_gameConfig_layer_0_paletteBank   (gameConfig_layer_0_paletteBank),
    .io_gameConfig_layer_1_paletteBank   (_gpu_io_gameConfig_layer_1_paletteBank),
    .io_gameConfig_layer_2_paletteBank   (gameConfig_layer_2_paletteBank),
    .io_options_rotate                   (effectiveRotate),
    .io_options_rotateClockwise          (rotateClockwise),
    .io_options_flipVideo                (options_flipVideo),
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
    .io_spriteCtrl_frameReady            (_gpu_io_spriteCtrl_frameReady),
    .io_systemFrameBuffer_wr             (_gpu_io_systemFrameBuffer_wr),
    .io_systemFrameBuffer_addr           (_gpu_io_systemFrameBuffer_addr),
    .io_systemFrameBuffer_din            (_gpu_io_systemFrameBuffer_din),
    .io_paletteRam_addr                  (_main_io_gpuMem_paletteRam_addr),
    .io_paletteRam_dout                  (_main_io_gpuMem_paletteRam_dout),
    .io_rgb                              (_gpu_rgb),
    .io_ss_idle                          (_gpu_io_ss_idle),
    .io_ss_reconstruction_ready          (_gpu_io_ss_reconstruction_ready)
`ifdef CAVE_ENABLE_DEBUG_OVERLAY
    ,
    .io_debug_video                      (_gpu_io_debug_video),
    .io_debug_readout                    (_gpu_io_debug_readout),
    .io_debug_source_rgb                 (_gpu_io_debug_source_rgb)
`endif
  );

`ifdef CAVE_ENABLE_DEBUG_OVERLAY
  wire [63:0] debugBits =
    options_debugView == 3'd1 ? _main_io_debug_cpu :
    options_debugView == 3'd2 ? _main_io_debug_writes :
    options_debugView == 3'd3 ? _main_io_debug_live :
    options_debugView == 3'd4 ? _main_io_debug_palette :
    options_debugView == 3'd5 ? (gameIsPwrInst2 ? _gpu_io_debug_readout : _main_io_debug_data) :
    options_debugView == 3'd6 ? _gpu_io_debug_video :
    options_debugView == 3'd7 ? _sound_io_debug :
                                 _main_io_debug_pipeline;
  reg [63:0] debugBitsFrameReg;
  wire       debugFrameStart =
    (_videoSys_io_video_pos_x == 9'd0) & (_videoSys_io_video_pos_y == 9'd0);
  wire [23:0] debugRgb;

  always @(posedge videoClock) begin
    if (videoReset)
      debugBitsFrameReg <= 64'd0;
    else if (debugFrameStart)
      debugBitsFrameReg <= debugBits;
  end

  CaveDebugOverlay debugOverlay (
    .io_video_pos_x (_videoSys_io_video_pos_x),
    .io_video_pos_y (_videoSys_io_video_pos_y),
    .io_debug_view  (options_debugView),
    .io_debug_bits  (debugBitsFrameReg),
    .io_rgb         (debugRgb)
  );

  assign rgb = (options_debugVideo & (options_debugView == 3'd6)) ? _gpu_io_debug_source_rgb :
               options_debugVideo ? debugRgb : _gpu_rgb;
`else
  assign rgb = _gpu_rgb;
`endif
  CaveTileRomClockCrossing gpu_io_layerCtrl_0_tileRom_crossing (
    .clock          (clock),
    .reset          (reset),
    .io_targetClock (videoClock),
    .io_block_new_requests (ssBlockClients),
    .io_in_rd       (_gpu_io_layerCtrl_0_tileRom_rd),
    .io_in_addr     (_gpu_io_layerCtrl_0_tileRom_addr),
    .io_in_dout     (_gpu_io_layerCtrl_0_tileRom_dout),
    .io_out_rd      (_memSys_io_layerTileRom_0_rd),
    .io_out_addr    (_memSys_io_layerTileRom_0_addr),
    .io_out_dout    (_memSys_io_layerTileRom_0_dout),
    .io_out_wait_n  (_memSys_io_layerTileRom_0_wait_n),
    .io_out_valid   (_memSys_io_layerTileRom_0_valid),
    .io_idle        (_layerTileRomCrossing0_io_ss_idle)
  );
  CaveTileRomClockCrossing gpu_io_layerCtrl_1_tileRom_crossing (
    .clock          (clock),
    .reset          (reset),
    .io_targetClock (videoClock),
    .io_block_new_requests (ssBlockClients),
    .io_in_rd       (_gpu_io_layerCtrl_1_tileRom_rd),
    .io_in_addr     (_gpu_io_layerCtrl_1_tileRom_addr),
    .io_in_dout     (_gpu_io_layerCtrl_1_tileRom_dout),
    .io_out_rd      (_memSys_io_layerTileRom_1_rd),
    .io_out_addr    (_memSys_io_layerTileRom_1_addr),
    .io_out_dout    (_memSys_io_layerTileRom_1_dout),
    .io_out_wait_n  (_memSys_io_layerTileRom_1_wait_n),
    .io_out_valid   (_memSys_io_layerTileRom_1_valid),
    .io_idle        (_layerTileRomCrossing1_io_ss_idle)
  );
  CaveTileRomClockCrossing gpu_io_layerCtrl_2_tileRom_crossing (
    .clock          (clock),
    .reset          (reset),
    .io_targetClock (videoClock),
    .io_block_new_requests (ssBlockClients),
    .io_in_rd       (_gpu_io_layerCtrl_2_tileRom_rd),
    .io_in_addr     (_gpu_io_layerCtrl_2_tileRom_addr),
    .io_in_dout     (_gpu_io_layerCtrl_2_tileRom_dout),
    .io_out_rd      (_memSys_io_layerTileRom_2_rd),
    .io_out_addr    (_memSys_io_layerTileRom_2_addr),
    .io_out_dout    (_memSys_io_layerTileRom_2_dout),
    .io_out_wait_n  (_memSys_io_layerTileRom_2_wait_n),
    .io_out_valid   (_memSys_io_layerTileRom_2_valid),
    .io_idle        (_layerTileRomCrossing2_io_ss_idle)
  );
  CaveTileRomClockCrossing gpu_io_pwrinst2Layer2_tileRom_crossing (
    .clock          (clock),
    .reset          (reset),
    .io_targetClock (videoClock),
    .io_block_new_requests (ssBlockClients),
    .io_in_rd       (_gpu_io_pwrinst2Layer2_tileRom_rd),
    .io_in_addr     (_gpu_io_pwrinst2Layer2_tileRom_addr),
    .io_in_dout     (_gpu_io_pwrinst2Layer2_tileRom_dout),
    .io_out_rd      (_memSys_io_pwrinst2Layer2TileRom_rd),
    .io_out_addr    (_memSys_io_pwrinst2Layer2TileRom_addr),
    .io_out_dout    (_memSys_io_pwrinst2Layer2TileRom_dout),
    .io_out_wait_n  (_memSys_io_pwrinst2Layer2TileRom_wait_n),
    .io_out_valid   (_memSys_io_pwrinst2Layer2TileRom_valid),
    .io_idle        (_pwrinst2LayerTileRomCrossing_io_ss_idle)
  );
  SpriteFrameBuffer spriteFrameBuffer (
    .clock                 (clock),
    .reset                 (reset),
    .io_videoClock         (videoClock),
    .io_enable             (_memSys_io_ready),
    .io_ss_hold            (ssBlockClients),
    .io_ss_canonicalize    (ssCanonicalizeSystem),
    .io_swap               (spriteFrameBufferSwap),
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
    .io_ddr_rd             (_memSys_io_spriteFrameBuffer_rd),
    .io_ddr_wr             (_memSys_io_spriteFrameBuffer_wr),
    .io_ddr_addr           (_memSys_io_spriteFrameBuffer_addr),
    .io_ddr_mask           (_memSys_io_spriteFrameBuffer_mask),
    .io_ddr_din            (_memSys_io_spriteFrameBuffer_din),
    .io_ddr_dout           (_memSys_io_spriteFrameBuffer_dout),
    .io_ddr_wait_n         (_memSys_io_spriteFrameBuffer_wait_n),
    .io_ddr_valid          (_memSys_io_spriteFrameBuffer_valid),
    .io_ddr_burstLength    (_memSys_io_spriteFrameBuffer_burstLength),
    .io_ddr_burstDone      (_memSys_io_spriteFrameBuffer_burstDone),
    .io_ss_idle            (_spriteFrameBuffer_io_ss_idle)
  );
  assign systemFrameBufferForceBlank = ~_memSys_io_ready;
  SystemFrameBuffer systemFrameBuffer (
    .clock                         (clock),
    .reset                         (reset),
    .io_videoClock                 (videoClock),
    .io_enable                     (_memSys_io_ready),
    .io_ss_hold                    (ssBlockClients),
    .io_ss_canonicalize            (ssCanonicalizeSystem),
    .io_rotate                     (effectiveRotate),
    .io_forceBlank                 (systemFrameBufferForceBlank),
    .io_video_vBlank               (_videoSys_io_video_vBlank),
    .io_video_regs_size_x          (_videoSys_io_video_regs_size_x),
    .io_video_regs_size_y          (_videoSys_io_video_regs_size_y),
    .io_frameBufferCtrl_enable     (frameBufferCtrl_enable),
    .io_frameBufferCtrl_hSize      (frameBufferCtrl_hSize),
    .io_frameBufferCtrl_vSize      (frameBufferCtrl_vSize),
    .io_frameBufferCtrl_baseAddr   (frameBufferCtrl_baseAddr),
    .io_frameBufferCtrl_stride     (frameBufferCtrl_stride),
    .io_frameBufferCtrl_vBlank     (frameBufferCtrl_vBlank),
    .io_frameBufferCtrl_lowLat     (frameBufferCtrl_lowLat),
    .io_frameBufferCtrl_forceBlank (frameBufferCtrl_forceBlank),
    .io_frameBuffer_wr             (_gpu_io_systemFrameBuffer_wr),
    .io_frameBuffer_addr           (_gpu_io_systemFrameBuffer_addr),
    .io_frameBuffer_din            (_gpu_io_systemFrameBuffer_din),
    .io_ddr_wr                     (_memSys_io_systemFrameBuffer_wr),
    .io_ddr_addr                   (_memSys_io_systemFrameBuffer_addr),
    .io_ddr_mask                   (_memSys_io_systemFrameBuffer_mask),
    .io_ddr_din                    (_memSys_io_systemFrameBuffer_din),
    .io_ddr_wait_n                 (_memSys_io_systemFrameBuffer_wait_n),
    .io_ss_idle                    (_systemFrameBuffer_io_ss_idle)
  );
  assign ioctl_wait_n = videoSys_io_prog_video_writeEnable | ioctlMemoryWaitN;
  assign ioctl_din =
    ioctlNvramEepromReadEnable ? ioctlNvramEepromDout :
    ioctlNvramHighScoreReadEnable ? _main_io_hs_nvram_din : 16'h0;
  assign nvram_dirty = eepromDirtyReg | _main_io_hs_dirty;
  assign led_power = 1'b0;
  assign led_disk = ioctl_download;
  assign led_user = _memSys_io_ready;
  assign frameBufferCtrl_format = 5'h6;
  assign video_clockEnable = _videoSys_io_video_clockEnable;
  assign video_displayEnable = _videoSys_io_video_displayEnable;
  assign video_pos_x = _videoSys_io_video_pos_x;
  assign video_pos_y = _videoSys_io_video_pos_y;
  assign video_hBlank = _videoSys_io_video_hBlank;
  assign video_vBlank = _videoSys_io_video_vBlank;
  assign video_regs_size_x = _videoSys_io_video_regs_size_x;
  assign video_regs_size_y = _videoSys_io_video_regs_size_y;
  assign video_rotated = effectiveRotate;

`ifdef CAVE_HW_DIAGNOSTICS
  CaveHardwareDiagnostics hardwareDiagnostics (
    .system_clock         (clock),
    .cpu_clock            (cpuClock),
    .video_clock          (videoClock),
    .clear                (caveHwDiagSource[0]),
    .system_reset         (diagnosticBridgeReset),
    .cpu_reset            (cpuDomainReset),
    .video_reset          (videoReset),
    .game_index_system    (gameIndexReg),
    .game_index_cpu       (gameIndexCpuReg),
    .game_index_latched   (gameIndexReg_latched),
    .ioctl_download       (ioctl_download),
    .rom_identity_read    (memSysHwDebug[11]),
    .mem_prog_done        (_memSys_io_prog_done),
    .mem_startup_debug    (memSysHwDebug[7:0]),
    .mem_ready            (_memSys_io_ready),
    .rom_identity_valid   (ssRomIdentityValid),
    .rom_size             (ssRomSize),
    .mem_prog_rom_rd      (_memSys_io_progRom_rd),
    .mem_prog_rom_wait_n  (_memSys_io_progRom_wait_n),
    .mem_prog_rom_valid   (_memSys_io_progRom_valid),
    .mem_cache_rom_rd     (memSysHwDebug[10]),
    .mem_cache_rom_wait_n (memSysHwDebug[9]),
    .mem_cache_rom_valid  (memSysHwDebug[8]),
    .sdram_rd             (_sdram_1_io_mem_rd),
    .sdram_wait_n         (_sdram_1_io_mem_wait_n),
    .sdram_valid          (_sdram_1_io_mem_valid),
    .sdram_dout           (_sdram_1_io_mem_dout),
    .sdram_wr_event       (_sdram_1_io_mem_wr &
                           _sdram_1_io_mem_wait_n),
    .ddr_rd_event         (_ddr_game_rd & _ddr_game_wait_n),
    .ddr_wr_event         (_ddr_game_wr & _ddr_game_wait_n),
    .framebuffer_wr_event (_memSys_io_systemFrameBuffer_wr &
                           _memSys_io_systemFrameBuffer_wait_n),
    .cpu_prog_rom_rd      (_main_io_progRom_rd),
    .cpu_prog_rom_valid   (_main_io_progRom_valid),
    .cpu_frame_swap       (_main_io_spriteFrameBufferSwap),
    .video_vblank         (_videoSys_io_video_vBlank),
    .frame_force_blank    (frameBufferCtrl_forceBlank),
    .ss_available         (ss_available),
    .ss_active            (ss_active),
    .ss_busy              (ss_busy),
    .ss_save_request      (ss_save_request),
    .ss_load_request      (ss_load_request),
    .ss_block_clients     (ssBlockClients),
    .ss_cpu_idle          (ssCpuIdleSystem),
    .ss_cpu_clients_idle  (ssCpuClientsIdleSystem),
    .ss_main_clients_idle_cpu(_main_io_ss_clients_idle),
    .ss_sound_idle_cpu    (_sound_io_ss_idle),
    .ss_video_clients_idle(ssVideoClientsIdle),
    .ss_video_clients_idle_raw(ssVideoClientsIdleRaw),
    .ss_gpu_idle          (_gpu_io_ss_idle),
    .ss_sprite_framebuffer_idle(_spriteFrameBuffer_io_ss_idle),
    .ss_system_framebuffer_idle(_systemFrameBuffer_io_ss_idle),
    .ss_tile_0_idle       (_layerTileRomCrossing0_io_ss_idle),
    .ss_tile_1_idle       (_layerTileRomCrossing1_io_ss_idle),
    .ss_tile_2_idle       (_layerTileRomCrossing2_io_ss_idle),
    .ss_pwrinst_tile_idle (_pwrinst2LayerTileRomCrossing_io_ss_idle),
    .ss_ddr_idle          (_ddr_1_idle),
    .ss_gameplay_sources_idle(ssGameplaySourcesIdle),
    .ss_state             (ss_state_debug),
    .ss_last_error        (ss_last_error),
    .probe                (caveHwDiagProbe)
  );

  altsource_probe #(
    .sld_auto_instance_index ("NO"),
    .sld_instance_index      (0),
    .instance_id             ("CHD"),
    .probe_width             (128),
`ifdef CAVE_SIGNALTAP_BOOT_DIAGNOSTIC
    .source_width            (3),
`ifdef CAVE_SIGNALTAP_BOOT_HOLD
    .source_initial_value    ("2"),
`else
    .source_initial_value    ("0"),
`endif
`else
    .source_width            (1),
    .source_initial_value    ("0"),
`endif
    .enable_metastability    ("NO")
  ) caveHardwareDiagnosticsProbe (
    .probe  (caveHwDiagProbe),
    .source (caveHwDiagSource)
  );

`ifdef CAVE_PWRINST2_SOUND_DIAGNOSTICS
  wire [0:0] cavePwrInst2SoundDiagSource;

  altsource_probe #(
    .sld_auto_instance_index ("NO"),
    .sld_instance_index      (1),
    .instance_id             ("PSD"),
    .probe_width             (256),
    .source_width            (1),
    .source_initial_value    ("0"),
    .enable_metastability    ("NO")
  ) cavePwrInst2SoundDiagnosticsProbe (
    .probe  (_sound_io_hw_debug),
    .source (cavePwrInst2SoundDiagSource)
  );

  wire [0:0] cavePwrInst2InputDiagSource;

  altsource_probe #(
    .sld_auto_instance_index ("NO"),
    .sld_instance_index      (2),
    .instance_id             ("PID"),
    .probe_width             (64),
    .source_width            (1),
    .source_initial_value    ("0"),
    .enable_metastability    ("NO")
  ) cavePwrInst2InputDiagnosticsProbe (
    .probe  (pwrinst2DiagInputProbe),
    .source (cavePwrInst2InputDiagSource)
  );
`endif
`endif

  assign sdram_cke = 1'b1;
endmodule
