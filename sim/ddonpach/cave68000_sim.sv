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
//   * the 68000's bus, taken by hierarchical reference for the trace, and
//     the sprite frame buffer's page on screen, for --replay.
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
  input  wire [2:0]  game,

  input  wire [7:0]  p1, p2,
  input  wire [1:0]  coin, start,
  input  wire        service, pause,
  input  wire [15:0] dsw,

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

  // frame buffer, as upstream's DDR saw it
  output wire        fb_rd, fb_wr,
  output wire [31:0] fb_addr,
  output wire [7:0]  fb_mask,
  output wire [63:0] fb_din,
  output wire [7:0]  fb_len,
  output wire [7:0]  fb_beat,
  input  wire [63:0] fb_dout,
  input  wire        fb_wait_n, fb_valid,

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

  // the 68000's bus
  output wire        dbg_as, dbg_rw, dbg_uds, dbg_lds, dbg_dtack,
  output wire [2:0]  dbg_fc,
  output wire [23:0] dbg_addr,
  output wire [15:0] dbg_din, dbg_dout,
  output wire [2:0]  dbg_ipl,
  output wire        dbg_sprite_swap,
  output wire [1:0]  dbg_fb_read_page   // the sprite frame buffer page on screen
);
  wire [31:0] off_snd, off_l0, off_l1, off_l2, off_spr;
  CaveGameConfig cfg (
    .game_index (game == 3'd7 ? 4'd1 : {1'b0, game}),
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
  wire        fb_rd_b, fb_wr_b, fb_done;
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
  sim_ddr_port fb_port (
    .clock (clk), .reset (rst),
    .mem_rd (fb_rd_b), .mem_wr (fb_wr_b), .mem_burstLength (fb_len_b), .mem_burstDone (fb_done),
    .ddr_wait_n (fb_wait_n), .ddr_valid (fb_valid),
    .ddr_rd (fb_rd), .ddr_wr (fb_wr), .ddr_burstLength (fb_len), .beat (fb_beat)
  );

  cave68000 dut (
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
    .spr_rd (spr_rd_b), .spr_addr (spr_a), .spr_dout (spr_dout),
    .spr_wait_n (spr_wait_n), .spr_valid (spr_valid),
    .spr_burst_len (spr_len_b), .spr_burst_done (spr_done),
    .fb_rd (fb_rd_b), .fb_wr (fb_wr_b), .fb_addr (fb_addr), .fb_mask (fb_mask),
    .fb_din (fb_din), .fb_dout (fb_dout), .fb_wait_n (fb_wait_n), .fb_valid (fb_valid),
    .fb_burst_len (fb_len_b), .fb_burst_done (fb_done),
    .ee_rd (ee_rd), .ee_wr (ee_wr), .ee_addr (ee_addr), .ee_din (ee_din),
    .ee_dout (ee_dout), .ee_wait_n (ee_wait_n), .ee_valid (ee_valid),
    .ce_pix (ce_pix), .hs (hs), .vs (vs), .hblank (hblank), .vblank (vblank), .de (de),
    .r (r), .g (g), .b (b), .snd (snd)
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
endmodule

`default_nettype wire
