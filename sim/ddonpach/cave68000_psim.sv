// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the board on the Pocket's memories, as the
// harness hosts it
//
// cave68000_mem (the board and its adapters) with what the Pocket shell puts
// behind its ports, the same RTL the shell uses: kaneko_sdram for the seven
// read ports (through cave_sdram, which interleaves the banks),
// pocket_psram_rows for the frame buffer's two chips. Behind
// those, models of the parts: sdram_model (which also checks the SDRAM
// protocol) holding the ROM image, loaded by the C++ side before reset, and a
// psram_model per chip. The 68000's bus and the YMZ280B's side are taken by
// hierarchical reference, as cave68000_sim.sv does.
//
// The capture depth is the model's (rd_lat_sel 3, CL + 3); the Pocket's
// device needs CL + 2 (core_top.v says why).

`default_nettype none

module cave68000_psim #(
  parameter int unsigned PS_LAT_W = 4,
  parameter int unsigned PS_LAT_R = 4,
  parameter int unsigned PS_DQ_DELAY = 0,
  parameter int unsigned SPR_PORTS = 2
) (
  input  wire        clk, rst,
  input  wire        clk_cpu, rst_cpu,
  input  wire        clk_vid, rst_vid,
  input  wire        rom_loaded,
  input  wire [2:0]  game,

  input  wire [7:0]  p1, p2,
  input  wire [1:0]  coin, start,
  input  wire        service, pause,
  input  wire [15:0] dsw,

  // the loader's stream past the SDRAM (the EEPROM's seed)
  input  wire        dl_wr,
  input  wire [25:1] dl_addr,     // [AW:1], the SDRAM word address
  input  wire [15:0] dl_data,

  output wire        sdram_ready,
  output wire        psram_ready,
  output wire [1:0]  psram_cal_fail,
  output wire [13:0] psram_lats,          // chip c at [7c +: 7]: {wr_lat, rd_ph, rd_lat}
  output wire [31:0] sdram_violations,
  output wire [31:0] psram_violations,

  output wire        ce_pix, hs, vs, hblank, vblank, de,
  output wire [7:0]  r, g, b,
  output wire [15:0] snd,
  output wire        snd_sample, snd_overrun,

  output wire [15:0] fb_rows_written, fb_rows_read, fb_rd_wait_max,

  // the 68000's bus
  output wire        dbg_as, dbg_rw, dbg_uds, dbg_lds, dbg_dtack,
  output wire [2:0]  dbg_fc,
  output wire [23:0] dbg_addr,
  output wire [15:0] dbg_din, dbg_dout,
  output wire [2:0]  dbg_ipl,
  output wire        dbg_sprite_swap,
  output wire [1:0]  dbg_fb_read_page,
  output wire        dbg_ymz_rd, dbg_ymz_wr, dbg_ymz_a0, dbg_ymz_busy, dbg_ymz_begin, dbg_ymz_apply,
  output wire [7:0]  dbg_ymz_din, dbg_ymz_dout,
  output wire        dbg_oki_wr0, dbg_oki_wr1, dbg_nmk_wr, dbg_oki_tick,
  output wire [7:0]  dbg_oki_din,
  output wire [2:0]  dbg_nmk_addr,
  output wire        dbg_oki_sv0, dbg_oki_sv1,
  output wire [19:0] dbg_oki_s0, dbg_oki_s1,
  output wire [6:0]  dbg_rom_req          // the seven read ports, for their wait counts
);
  localparam int unsigned AW = 25;

  wire [6:0]      rom_req, rom_ack;
  wire [7*AW-1:0] rom_addr;
  wire [7*64-1:0] rom_dout;
  wire [1:0]      row_req, row_we, row_ack;
  wire [43:0]     row_addr;
  wire [255:0]    row_wdata;
  wire [511:0]    row_rdata;
  wire [31:0]     row_wmask;

  cave68000_mem #(.AW (AW), .SPR_PORTS (SPR_PORTS)) mem (
    .clk (clk), .rst (rst), .clk_cpu (clk_cpu), .rst_cpu (rst_cpu),
    .clk_vid (clk_vid), .rst_vid (rst_vid),
    .rom_loaded (rom_loaded), .game (game),
    .p1 (p1), .p2 (p2), .coin (coin), .start (start),
    .service (service), .pause (pause), .dsw (dsw),
    .rom_req (rom_req), .rom_addr (rom_addr), .rom_ack (rom_ack), .rom_dout (rom_dout),
    .row_req (row_req), .row_we (row_we), .row_addr (row_addr),
    .row_wdata (row_wdata), .row_wmask (row_wmask), .row_ack (row_ack), .row_rdata (row_rdata),
    .dl_wr (dl_wr), .dl_addr (dl_addr), .dl_data (dl_data),
    .nv_addr (6'd0), .nv_din (16'd0), .nv_we (1'b0), .nv_dout (), .nv_dirty (), .nv_dirty_clr (1'b0),
    .ce_pix (ce_pix), .hs (hs), .vs (vs), .hblank (hblank), .vblank (vblank), .de (de),
    .r (r), .g (g), .b (b), .snd (snd), .snd_sample (snd_sample), .snd_overrun (snd_overrun),
    .spr_swap (), .cpu_as (), .diag_clr (1'b0), .fb_rows_written (fb_rows_written), .fb_rows_read (fb_rows_read),
    .fb_rd_wait_max (fb_rd_wait_max)
  );

  // the memories' own power-on reset: the board's rst is held until they
  // are ready, so they cannot share it
  reg [3:0] por = 4'hF;
  always @(posedge clk) if (por != 4'd0) por <= por - 4'd1;
  wire rst_por = por != 4'd0;

  // ------------------------------------------------------------- SDRAM
  wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe, dev_dq_oe;
  wire [1:0]  sd_ba, sd_dqm;
  wire [12:0] sd_a;
  wire [15:0] sd_dq_o, dev_dq_o;
  int unsigned sd_viol;

  cave_sdram #(
    .COL_BITS (10), .NP (7),
    .T_REFI (700), .T_RC (11), .INIT_NOP (2000),
    .URGENT (7'b001_1100), .ACK_HOLD (1)
  ) sdram (
    .clk (clk), .rst_n (!rst_por), .ready (sdram_ready), .rd_lat_sel (2'd3),
    .sd_cke (sd_cke), .sd_cs_n (sd_cs_n), .sd_ras_n (sd_ras_n), .sd_cas_n (sd_cas_n),
    .sd_we_n (sd_we_n), .sd_ba (sd_ba), .sd_a (sd_a), .sd_dqm (sd_dqm),
    .sd_dq_o (sd_dq_o), .sd_dq_oe (sd_dq_oe), .sd_dq_i (dev_dq_o),
    .wr_req (1'b0), .wr_addr ('0), .wr_din (16'd0), .wr_be (2'b11), .wr_ack (),
    .p_req (rom_req), .p_addr (rom_addr), .p_dout (rom_dout), .p_ack (rom_ack)
  );

  sdram_model #(.COL_BITS (10), .T_RC (11), .T_REFI (700)) sdram_dev (
    .clk (clk), .cke (sd_cke), .cs_n (sd_cs_n), .ras_n (sd_ras_n), .cas_n (sd_cas_n),
    .we_n (sd_we_n), .ba (sd_ba), .a (sd_a), .dqm (sd_dqm),
    .dq_i (sd_dq_o), .dq_oe_i (sd_dq_oe), .dq_o (dev_dq_o), .dq_oe_o (dev_dq_oe),
    .violations (sd_viol), .v_flags (), .reads_served (), .writes_served ()
  );
  assign sdram_violations = sd_viol;

  // ------------------------------------------------------------- PSRAM
  wire [1:0] ps_ready, ps_fail;
  int unsigned ps_viol [2];
  genvar c;
  generate
    for (c = 0; c < 2; c = c + 1) begin : chip
      wire [21:16] ca;
      wire [15:0]  cdq_o, mdq_o;
      wire         cdq_oe, mdq_oe, cclk, cadv, ccre, cce0, cce1, coe, cwe, cub, clb;
      wire [2:0]   rl, wl;
      wire         rp;
      wire [15:0]  bcr;
      pocket_psram_rows servant (
        .clk (clk), .rst (rst_por),
        .req (row_req[c]), .we (row_we[c]), .addr (row_addr[22*c +: 22]),
        .wdata (row_wdata), .wmask (row_wmask),
        .ack (row_ack[c]), .rdata (row_rdata[256*c +: 256]),
        .ready (ps_ready[c]), .cal_fail (ps_fail[c]), .rd_lat (rl), .rd_ph (rp), .wr_lat (wl),
        .cram_a (ca), .cram_dq_o (cdq_o), .cram_dq_oe (cdq_oe),
        .cram_dq_i (mdq_oe ? mdq_o : (cdq_oe ? cdq_o : 16'hzzzz)),
        .cram_clk (cclk), .cram_adv_n (cadv), .cram_cre (ccre),
        .cram_ce0_n (cce0), .cram_ce1_n (cce1), .cram_oe_n (coe), .cram_we_n (cwe),
        .cram_ub_n (cub), .cram_lb_n (clb)
      );
      psram_model #(.LAT_W (PS_LAT_W), .LAT_R (PS_LAT_R), .DQ_DELAY (PS_DQ_DELAY)) dev (
        .clk (clk), .a (ca), .dq_i (cdq_o), .dq_oe_i (cdq_oe), .dq_o (mdq_o), .dq_oe_o (mdq_oe),
        .cram_clk (cclk), .adv_n (cadv), .cre (ccre), .ce0_n (cce0), .oe_n (coe),
        .we_n (cwe), .ub_n (cub), .lb_n (clb), .violations (ps_viol[c]), .bcr (bcr)
      );
      assign psram_lats[7*c +: 7] = {wl, rp, rl};
    end
  endgenerate
  assign psram_ready = &ps_ready;
  assign psram_cal_fail = ps_fail;
  assign psram_violations = ps_viol[0] + ps_viol[1];

  // ------------------------------------------------------------- probes
  assign dbg_as    = mem.board.main._cpu_io_as;
  assign dbg_rw    = mem.board.main._cpu_io_rw;
  assign dbg_uds   = mem.board.main._cpu_io_uds;
  assign dbg_lds   = mem.board.main._cpu_io_lds;
  assign dbg_dtack = mem.board.main.dtackReg;
  assign dbg_fc    = mem.board.main._cpu_io_fc;
  assign dbg_addr  = {mem.board.main._cpu_io_addr, 1'b0};
  assign dbg_din   = mem.board.main.cpuDin;
  assign dbg_dout  = mem.board.main._cpu_io_dout;
  assign dbg_ipl   = mem.board.main._cpu_io_ipl;
  assign dbg_sprite_swap  = mem.board._main_io_spriteFrameBufferSwap;
  assign dbg_fb_read_page = mem.board.spriteFrameBuffer.pageFlipper.read_index;
  assign dbg_ymz_rd   = mem.board._main_io_soundCtrl_ymz_rd;
  assign dbg_ymz_wr   = mem.board._main_io_soundCtrl_ymz_wr;
  assign dbg_ymz_a0   = mem.board._main_io_soundCtrl_ymz_addr[0];
  assign dbg_ymz_din  = mem.board._main_io_soundCtrl_ymz_din[7:0];
  assign dbg_ymz_dout = mem.board._main_io_soundCtrl_ymz_dout[7:0];
`ifdef CAVE_OKI
  assign dbg_ymz_busy = 1'b0;
  assign dbg_ymz_begin = 1'b0;
  assign dbg_ymz_apply = 1'b0;
  assign dbg_oki_wr0  = mem.board._main_io_soundCtrl_oki_0_wr;
  assign dbg_oki_wr1  = mem.board._main_io_soundCtrl_oki_1_wr;
  assign dbg_nmk_wr   = mem.board._main_io_soundCtrl_nmk_wr;
  assign dbg_oki_din  = mem.board._main_io_soundCtrl_nmk_wr ? mem.board._main_io_soundCtrl_nmk_din[7:0] :
                        mem.board._main_io_soundCtrl_oki_1_wr ? mem.board._main_io_soundCtrl_oki_1_din[7:0] :
                        mem.board._main_io_soundCtrl_oki_0_din[7:0];
  assign dbg_nmk_addr = mem.board._main_io_soundCtrl_nmk_addr[2:0];
  assign dbg_oki_tick = mem.board.sound.tick1;
  assign dbg_oki_sv0  = mem.board.sound.io_sample_valid_0;
  assign dbg_oki_sv1  = mem.board.sound.io_sample_valid_1;
  assign dbg_oki_s0   = mem.board.sound.io_sample_0;
  assign dbg_oki_s1   = mem.board.sound.io_sample_1;
`else
  assign dbg_ymz_busy = mem.board.sound.ymz280b.channelCtrl.state != 4'd0;
  // the next clk_cpu edge begins a sample (an access on it lands after the sample)
  assign dbg_ymz_begin = mem.board.sound.ymz280b.channelCtrl.state == 4'd0 &&
                         (mem.board.sound.ymz280b.channelCtrl.tickPending ||
                          mem.board.sound.ymz280b.channelCtrl.tick) &&
                         mem.board.sound.ymz280b.queueCount == 4'd0;
  // the next edge applies the write at the head of the chip's queue
  assign dbg_ymz_apply = mem.board.sound.ymz280b.apply;
  assign {dbg_oki_wr0, dbg_oki_wr1, dbg_nmk_wr, dbg_oki_tick, dbg_oki_din, dbg_nmk_addr} = '0;
  assign {dbg_oki_sv0, dbg_oki_sv1, dbg_oki_s0, dbg_oki_s1} = '0;
`endif
  assign dbg_rom_req  = rom_req;
endmodule

`default_nettype wire
