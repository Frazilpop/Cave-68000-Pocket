// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the board as the harness hosts it
//
// cave68000 with what a host adds round it in simulation:
//
//   * the region offsets (CaveGameConfig), so the C++ side sees whole-image
//     addresses: the caches' line reads and the sprite bursts land where the
//     .rom file has them, as upstream's MemSys placed them;
//   * upstream's DDR.sv burst bookkeeping in front of the sprite tile and
//     frame buffer ports (sim_ddr_port below): burstDone with the last beat,
//     combinationally on a write as MiSTer's bridge gave it;
//   * the 68000's bus, taken by hierarchical reference for the trace, the
//     sprite frame buffer's page on screen, for --replay, and the YMZ280B's
//     68000 side and whether it is working on a sample, for --ymz-log (built
//     with CAVE_OKI, sim/ddonpach/build.sh --oki: the OKIs' and the NMK112's
//     writes, the samples begun and each chip's samples, for --oki-log).
//
// The memories themselves are the C++ side's (tb_ddonpach.cpp).

`default_nettype none

module sim_ddr_port (
  input  wire        clock,
  input  wire        reset,
  input  wire        mem_rd,
  input  wire        mem_wr,
  input  wire [7:0]  mem_burstLength,
  output wire        mem_burstDone,
  input  wire        ddr_wait_n,
  input  wire        ddr_valid,
  output wire        ddr_rd,
  output wire        ddr_wr,
  output wire [7:0]  ddr_burstLength,
  output wire [7:0]  beat              // the write beat this cycle carries
);
  // upstream's DDR.sv, the parts the board sees
  localparam [1:0] IDLE = 2'd0, READ_WAIT = 2'd1, WRITE_WAIT = 2'd2;
  reg [1:0] stateReg;
  reg [7:0] burstLengthReg, burstCounter;

  wire idle          = stateReg == IDLE;
  wire read          = idle && mem_rd;
  wire write         = (idle || stateReg == WRITE_WAIT) && mem_wr;
  wire acceptedRead  = read && ddr_wait_n;
  wire acceptedWrite = write && ddr_wait_n;
  wire [7:0] burstLength = idle ? mem_burstLength : burstLengthReg;
  wire last          = burstCounter == 8'(burstLength - 8'h1) || burstLength == 8'h0;
  wire enable        = (stateReg == READ_WAIT && ddr_valid) || acceptedWrite;
  wire wrap          = enable && last;

  always @(posedge clock) begin
    if (reset) begin
      stateReg <= IDLE;
      burstCounter <= 8'h0;
    end else begin
      if (wrap)              stateReg <= IDLE;
      else if (acceptedRead) stateReg <= READ_WAIT;
      else if (acceptedWrite) stateReg <= WRITE_WAIT;
      if (enable) burstCounter <= last ? 8'h0 : 8'(burstCounter + 8'h1);
    end
    if (idle) burstLengthReg <= mem_burstLength;
  end

  assign mem_burstDone   = wrap;
  assign ddr_rd          = read;
  assign ddr_wr          = write;
  assign ddr_burstLength = burstLength;
  assign beat            = burstCounter;
endmodule

module cave68000_sim (
  input  wire        clk, rst,
  input  wire        clk_cpu, rst_cpu,
  input  wire        clk_vid, rst_vid,
  input  wire        rom_loaded,
  input  wire [3:0]  game,

  input  wire [7:0]  p1, p2,
  input  wire [1:0]  coin, start,
  input  wire        service, pause,
  input  wire [15:0] dsw,
  // the loader's stream (the Z80 build keeps its sound CPU's first 16 KB)
  input  wire        dl_wr,
  input  wire [24:0] dl_addr,
  input  wire [15:0] dl_data,

  // the caches' line reads: byte address in the image, four words back
  output wire        prog_rd,
  output wire [31:0] prog_addr,
  input  wire [15:0] prog_dout,
  input  wire        prog_wait_n, prog_valid,
  output wire        snd_rd,
  output wire [31:0] snd_addr,
  input  wire [15:0] snd_dout,
  input  wire        snd_wait_n, snd_valid,
  output wire [2:0]  tile_rd,
  output wire [95:0] tile_addr,      // layer k at [32k +: 32]
  input  wire [47:0] tile_dout,
  input  wire [2:0]  tile_wait_n, tile_valid,

  // sprite tiles: byte address in the image, a burst of 64-bit words
  output wire        spr_rd,
  output wire [31:0] spr_addr,
  output wire [7:0]  spr_len,
  input  wire [63:0] spr_dout,
  input  wire        spr_wait_n, spr_valid,

  // frame buffer, as upstream's DDR saw it: line reads on their own port
  output wire        fbr_rd,
  output wire [31:0] fbr_addr,
  input  wire [63:0] fbr_dout,
  input  wire        fbr_wait_n, fbr_valid,
  output wire        fb_wr,
  output wire [31:0] fb_addr,
  output wire [7:0]  fb_mask,
  output wire [63:0] fb_din,
  output wire [7:0]  fb_len,
  output wire [7:0]  fb_beat,
  input  wire        fb_wait_n,

  // the 93C46's store
  output wire        ee_rd, ee_wr,
  output wire [6:0]  ee_addr,
  output wire [15:0] ee_din,
  input  wire [15:0] ee_dout,
  input  wire        ee_wait_n, ee_valid,
  output wire [31:0] eeprom_offset,

  output wire        ce_pix, hs, vs, hblank, vblank, de,
  output wire [7:0]  r, g, b,
  output wire [15:0] snd,
  output wire        snd_sample, snd_overrun,

  // the 68000's bus
  output wire        dbg_as, dbg_rw, dbg_uds, dbg_lds, dbg_dtack,
  output wire [2:0]  dbg_fc,
  output wire [23:0] dbg_addr,
  output wire [15:0] dbg_din, dbg_dout,
  output wire [2:0]  dbg_ipl,
  output wire        dbg_sprite_swap,
  output wire [1:0]  dbg_fb_read_page,  // the sprite frame buffer page on screen
  output wire        dbg_ymz_rd, dbg_ymz_wr, dbg_ymz_a0, dbg_ymz_busy, dbg_ymz_begin, dbg_ymz_apply,
  output wire [7:0]  dbg_ymz_din, dbg_ymz_dout,
  output wire        dbg_oki_wr0, dbg_oki_wr1, dbg_nmk_wr, dbg_oki_tick,
  output wire [7:0]  dbg_oki_din,
  output wire [2:0]  dbg_nmk_addr,
  output wire        dbg_oki_sv0, dbg_oki_sv1,
  output wire [19:0] dbg_oki_s0, dbg_oki_s1,
  // the Z80 sound board: each access its Z80 makes (SoundZ80's taps)
  output wire        dbg_z80_reset,      // the sound board held in reset (its time 0 the first clock after)
  output wire        dbg_z80_cmd,        // the 68000's command written to the latch, this clock
  output wire        dbg_z80_act, dbg_z80_acc, dbg_z80_io, dbg_z80_wr, dbg_z80_m1,
  output wire [15:0] dbg_z80_addr,
  output wire [7:0]  dbg_z80_data, dbg_z80_late,
  output wire [39:0] dbg_z80_time,       // the sound board's clock of the access (MAME's time)
  output wire        dbg_ym_sample,
  output wire [15:0] dbg_ym_left, dbg_ym_right
);
`ifdef CAVE_OKI
  wire [3:0] gameIndex = 4'd2;
`elsif CAVE_Z80
  wire [3:0] gameIndex = (game == 4'd10) ? 4'd10 : 4'd9;
`else
  wire [3:0] gameIndex = (game[2:0] == 3'd7) ? 4'd1 : {1'b0, game[2:0]};
`endif
  wire [31:0] off_snd, off_l0, off_l1, off_l2, off_spr;
  CaveGameConfig cfg (
    .game_index (gameIndex),
    .granularity (), .eeprom_offset (eeprom_offset), .sound_0_device (),
    .sound_0_rom_offset (off_snd), .sound_1_rom_offset (), .sound_2_rom_offset (),
    .layer_0_format (), .layer_0_rom_offset (off_l0), .layer_0_palette_bank (),
    .layer_1_format (), .layer_1_rom_offset (off_l1), .layer_1_palette_bank (),
    .layer_2_format (), .layer_2_rom_offset (off_l2), .pwrinst2_layer_2_rom_offset (),
    .layer_2_palette_bank (), .sprite_format (), .sprite_rom_offset (off_spr),
    .sprite_zoom ()
  );

  wire [24:0] prog_a, snd_a;
  wire [74:0] tile_a;
  wire [31:0] spr_a;
  wire        spr_rd_b, spr_done;
  wire [7:0]  spr_len_b;
  wire        fb_wr_b, fb_done, fbr_rd_b, fbr_done;
  wire [7:0]  fb_len_b;

  assign prog_addr = {7'd0, prog_a};
  assign snd_addr  = {7'd0, snd_a} + off_snd;
  assign tile_addr = {{7'd0, tile_a[50 +: 25]} + off_l2,
                      {7'd0, tile_a[25 +: 25]} + off_l1,
                      {7'd0, tile_a[ 0 +: 25]} + off_l0};
  assign spr_addr  = spr_a + off_spr;

  sim_ddr_port spr_port (
    .clock (clk), .reset (rst),
    .mem_rd (spr_rd_b), .mem_wr (1'b0), .mem_burstLength (spr_len_b), .mem_burstDone (spr_done),
    .ddr_wait_n (spr_wait_n), .ddr_valid (spr_valid),
    .ddr_rd (spr_rd), .ddr_wr (), .ddr_burstLength (spr_len), .beat ()
  );
  sim_ddr_port fbr_port (
    .clock (clk), .reset (rst),
    .mem_rd (fbr_rd_b), .mem_wr (1'b0), .mem_burstLength (8'd16), .mem_burstDone (fbr_done),
    .ddr_wait_n (fbr_wait_n), .ddr_valid (fbr_valid),
    .ddr_rd (fbr_rd), .ddr_wr (), .ddr_burstLength (), .beat ()
  );
  sim_ddr_port fb_port (
    .clock (clk), .reset (rst),
    .mem_rd (1'b0), .mem_wr (fb_wr_b), .mem_burstLength (fb_len_b), .mem_burstDone (fb_done),
    .ddr_wait_n (fb_wait_n), .ddr_valid (1'b0),
    .ddr_rd (), .ddr_wr (fb_wr), .ddr_burstLength (fb_len), .beat (fb_beat)
  );

  // The 68000's own RAM, which the Z80 build puts off the chip: here a block
  // RAM, as it was inside Main (the Pocket's SRAM is cave68000_psim's).
  wire        xram_rd, xram_wr;
  wire [15:0] xram_addr, xram_din, xram_dout;
  wire [1:0]  xram_mask;
  single_port_ram #(.ADDR_WIDTH (16), .DATA_WIDTH (16), .MASK_ENABLE ("TRUE")) xram (
    .clk (clk_cpu), .rd (xram_rd), .wr (xram_wr), .addr (xram_addr),
    .mask (xram_mask), .din (xram_din), .dout (xram_dout)
  );

  cave68000 dut (
    .clk (clk), .rst (rst), .clk_cpu (clk_cpu), .rst_cpu (rst_cpu),
    .clk_vid (clk_vid), .rst_vid (rst_vid),
    .rom_loaded (rom_loaded), .game (game),
    .dl_wr (dl_wr), .dl_addr (dl_addr), .dl_data (dl_data),
    .xram_rd (xram_rd), .xram_wr (xram_wr), .xram_addr (xram_addr),
    .xram_mask (xram_mask), .xram_din (xram_din), .xram_dout (xram_dout),
    .p1 (p1), .p2 (p2), .coin (coin), .start (start),
    .service (service), .pause (pause), .dsw (dsw),
    .prog_rd (prog_rd), .prog_addr (prog_a), .prog_dout (prog_dout),
    .prog_wait_n (prog_wait_n), .prog_valid (prog_valid),
    .snd_rd (snd_rd), .snd_addr (snd_a), .snd_dout (snd_dout),
    .snd_wait_n (snd_wait_n), .snd_valid (snd_valid),
    .tile_rd (tile_rd), .tile_addr (tile_a), .tile_dout (tile_dout),
    .tile_wait_n (tile_wait_n), .tile_valid (tile_valid),
    .spr_rd (spr_rd_b), .spr_addr (spr_a), .spr_dout (spr_dout),
    .spr_wait_n (spr_wait_n), .spr_valid (spr_valid),
    .spr_burst_len (spr_len_b), .spr_burst_done (spr_done),
    .fbr_rd (fbr_rd_b), .fbr_addr (fbr_addr), .fbr_dout (fbr_dout),
    .fbr_wait_n (fbr_wait_n), .fbr_valid (fbr_valid), .fbr_burst_done (fbr_done),
    .fb_wr (fb_wr_b), .fb_addr (fb_addr), .fb_mask (fb_mask), .fb_din (fb_din),
    .fb_wait_n (fb_wait_n), .fb_burst_len (fb_len_b), .fb_burst_done (fb_done),
    .ee_rd (ee_rd), .ee_wr (ee_wr), .ee_addr (ee_addr), .ee_din (ee_din),
    .ee_dout (ee_dout), .ee_wait_n (ee_wait_n), .ee_valid (ee_valid),
    .ce_pix (ce_pix), .hs (hs), .vs (vs), .hblank (hblank), .vblank (vblank), .de (de),
    .r (r), .g (g), .b (b), .snd (snd), .snd_sample (snd_sample), .snd_overrun (snd_overrun),
    .spr_swap (), .cpu_as ()
  );

  assign dbg_as    = dut.main._cpu_io_as;
  assign dbg_rw    = dut.main._cpu_io_rw;
  assign dbg_uds   = dut.main._cpu_io_uds;
  assign dbg_lds   = dut.main._cpu_io_lds;
  assign dbg_dtack = dut.main.dtackReg;
  assign dbg_fc    = dut.main._cpu_io_fc;
  assign dbg_addr  = {dut.main._cpu_io_addr, 1'b0};
  assign dbg_din   = dut.main.cpuDin;
  assign dbg_dout  = dut.main._cpu_io_dout;
  assign dbg_ipl   = dut.main._cpu_io_ipl;
  assign dbg_sprite_swap = dut._main_io_spriteFrameBufferSwap;
  assign dbg_fb_read_page = dut.spriteFrameBuffer.pageFlipper.read_index;
  assign dbg_ymz_rd   = dut._main_io_soundCtrl_ymz_rd;
  assign dbg_ymz_wr   = dut._main_io_soundCtrl_ymz_wr;
  assign dbg_ymz_a0   = dut._main_io_soundCtrl_ymz_addr[0];
  assign dbg_ymz_din  = dut._main_io_soundCtrl_ymz_din[7:0];
  assign dbg_ymz_dout = dut._main_io_soundCtrl_ymz_dout[7:0];
`ifdef CAVE_OKI
  assign dbg_ymz_busy = 1'b0;
  assign dbg_ymz_begin = 1'b0;
  assign dbg_ymz_apply = 1'b0;
  assign dbg_oki_wr0  = dut._main_io_soundCtrl_oki_0_wr;
  assign dbg_oki_wr1  = dut._main_io_soundCtrl_oki_1_wr;
  assign dbg_nmk_wr   = dut._main_io_soundCtrl_nmk_wr;
  assign dbg_oki_din  = dut._main_io_soundCtrl_nmk_wr ? dut._main_io_soundCtrl_nmk_din[7:0] :
                        dut._main_io_soundCtrl_oki_1_wr ? dut._main_io_soundCtrl_oki_1_din[7:0] :
                        dut._main_io_soundCtrl_oki_0_din[7:0];
  assign dbg_nmk_addr = dut._main_io_soundCtrl_nmk_addr[2:0];
  // the next clk_cpu edge begins one of OKI 1's samples (an access on it
  // lands after the sample)
  assign dbg_oki_tick = dut.sound.tick1;
  assign dbg_oki_sv0  = dut.sound.io_sample_valid_0;
  assign dbg_oki_sv1  = dut.sound.io_sample_valid_1;
  assign dbg_oki_s0   = dut.sound.io_sample_0;
  assign dbg_oki_s1   = dut.sound.io_sample_1;
  assign {dbg_z80_reset, dbg_z80_cmd, dbg_z80_act, dbg_z80_acc, dbg_z80_io, dbg_z80_wr, dbg_z80_m1, dbg_z80_addr, dbg_z80_data, dbg_z80_late, dbg_z80_time} = '0;
  assign {dbg_ym_sample, dbg_ym_left, dbg_ym_right} = '0;
`elsif CAVE_Z80
  // the Z80 sound board
  assign {dbg_ymz_busy, dbg_ymz_begin, dbg_ymz_apply} = '0;
  assign {dbg_oki_wr0, dbg_oki_wr1, dbg_nmk_wr, dbg_oki_tick, dbg_oki_din, dbg_nmk_addr} = '0;
  assign dbg_oki_sv0  = dut.sound.dbg_oki_sv0;
  assign dbg_oki_sv1  = dut.sound.dbg_oki_sv1;
  assign dbg_oki_s0   = dut.sound.dbg_oki_s0;
  assign dbg_oki_s1   = dut.sound.dbg_oki_s1;
  assign dbg_z80_reset = dut.sound.reset;
  assign dbg_z80_cmd  = dut.sound.io_cmd_wr;
  assign dbg_z80_act  = dut.sound.dbg_act;
  assign dbg_z80_acc  = dut.sound.dbg_acc;
  assign dbg_z80_io   = dut.sound.dbg_acc_io;
  assign dbg_z80_wr   = dut.sound.dbg_acc_wr;
  assign dbg_z80_m1   = dut.sound.dbg_acc_m1;
  assign dbg_z80_addr = dut.sound.dbg_acc_addr;
  assign dbg_z80_data = dut.sound.dbg_acc_data;
  assign dbg_z80_late = dut.sound.dbg_acc_late;
  assign dbg_z80_time = dut.sound.dbg_acc_time;
  assign dbg_ym_sample = dut.sound.dbg_ym_sample;
  assign dbg_ym_left  = dut.sound.dbg_ym_left;
  assign dbg_ym_right = dut.sound.dbg_ym_right;
`else
  assign dbg_ymz_busy = dut.sound.ymz280b.channelCtrl.state != 4'd0;
  // the next clk_cpu edge begins a sample (an access on it lands after the sample)
  assign dbg_ymz_begin = dut.sound.ymz280b.channelCtrl.state == 4'd0 &&
                         (dut.sound.ymz280b.channelCtrl.tickPending ||
                          dut.sound.ymz280b.channelCtrl.tick) &&
                         dut.sound.ymz280b.queueCount == 4'd0;
  // the next edge applies the write at the head of the chip's queue
  assign dbg_ymz_apply = dut.sound.ymz280b.apply;
  assign {dbg_oki_wr0, dbg_oki_wr1, dbg_nmk_wr, dbg_oki_tick, dbg_oki_din, dbg_nmk_addr} = '0;
  assign {dbg_oki_sv0, dbg_oki_sv1, dbg_oki_s0, dbg_oki_s1} = '0;
  assign {dbg_z80_reset, dbg_z80_cmd, dbg_z80_act, dbg_z80_acc, dbg_z80_io, dbg_z80_wr, dbg_z80_m1, dbg_z80_addr, dbg_z80_data, dbg_z80_late, dbg_z80_time} = '0;
  assign {dbg_ym_sample, dbg_ym_left, dbg_ym_right} = '0;
`endif
endmodule

`default_nettype wire
