// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — RndMnkIII's Analogizer in the cartridge slot
//
// The board's own raster (15.625 kHz, 448 dots by 272 lines, 320 x 240 shown)
// goes out of the adapter's VGA connector, and SNAC controllers come in for
// either player, through RndMnkIII's openFPGA_Pocket_Analogizer
// (pocket/src/fpga/analogizer/). Everything here is on clk_vid, the board's
// video clock (28 MHz, a dot every fourth clock), which is also the clock the
// module puts on the cartridge pin that clocks the adapter's DAC.
//
// SETTINGS come from analogizer.bin, the file Pupdate and RndMnkIII's
// AnalogizerConfigurator write to Assets/analogizer/common/ and every
// Analogizer core that reads the file shares: data slot 330 (data.json),
// platform index 1 (core.json's second platform id, "analogizer"), loaded to
// 0xF7000000. It is one 32-bit word, written little-endian (BitConverter);
// the bridge is big-endian here (bridge_endian_little = 0), so the file's
// first byte arrives in [31:24] and the bytes are turned back round:
//
//   [4:0]   SNAC controller: 0 none, 1 DB15, 2 NES, 3 SNES, 4 PC Engine
//           2-button, 5 6-button, 6 multitap, 9 DB15 fast, 0xB SNES with A,B
//           and X,Y swapped (the ones taken here; the PS/2 and PlayStation
//           types and JVS are not, and leave the Pocket's controls in place)
//   [5]     Analogizer on
//   [9:6]   SNAC assignment: 0 SNAC 1 -> player 1, 1 SNAC 1 -> player 2,
//           2 SNAC 1, 2 -> players 1, 2, 3 SNAC 1, 2 -> players 2, 1,
//           4 SNAC 1, 2 -> players 3, 4 (none here), 5 SNAC 1-4 -> players
//           1-4 (1 and 2 here)
//   [13:10] video: 0 RGBS, 1 RGsB, 2 YPbPr, 3 Y/C NTSC, 4 Y/C PAL, 5-8 the
//           scandoubler (31 kHz RGBHV) with scanlines of 0, 25, 50 and 75 %,
//           9 HQ2x, which this module has not got: the scandoubler without
//           scanlines. The module's own codes are older (5-7 the scandoubler,
//           its scanlines on fx; 8-F the same modes with the Pocket's screen
//           off), so the file's are turned into them below.
//   [14]    the Pocket's own screen black
//   [15]    OSD on the adapter's output, [19:16] region: nothing here uses
//           them
//
// No file, or [5] clear, is the Analogizer off: the module holds the pins
// idle, which is the template's tie-off for every pin but pin30 (the module
// lets it float as an input, the template drives it low and leaves its
// direction to the hardware), so pin30 is driven as the template has it here.
// A Pocket with no adapter, or no file, sees the slot exactly as before.
//
// SNAC words come out in the Pocket's controller order (key[15:0]: up, down,
// left, right, A, B, X, Y, L1, R1, L2, R2, L3, R3, select, start), so they
// stand in for cont1_key and cont2_key as they are: key1 and key2 are the
// players' controls, the Pocket's or a SNAC controller's as the assignment
// gives them. Each bit is a level held for a frame or more, and core_top.v
// synchronises them into clk_cpu bit by bit, as it did the Pocket's alone.

`default_nettype none

module pocket_analogizer (
    input  wire        clk_74a,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,

    input  wire        clk_vid,
    input  wire        ce_pix,
    input  wire        hs, vs,              // active high, as the board makes them
    input  wire        hblank, vblank, de,
    input  wire [7:0]  r, g, b,

    output wire        pocket_off,          // the Pocket's own screen to black

    input  wire [15:0] cont1_key, cont2_key,  // the Pocket's controls (clk_74a)
    output wire [15:0] key1, key2,          // the players' controls
    output wire        p1_snac,             // player 1 is on a SNAC controller

    inout  wire [7:0]  cart_tran_bank2,
    output wire        cart_tran_bank2_dir,
    inout  wire [7:0]  cart_tran_bank3,
    output wire        cart_tran_bank3_dir,
    inout  wire [7:0]  cart_tran_bank1,
    output wire        cart_tran_bank1_dir,
    inout  wire [7:4]  cart_tran_bank0,
    output wire        cart_tran_bank0_dir,
    inout  wire        cart_tran_pin30,
    output wire        cart_tran_pin30_dir,
    output wire        cart_pin30_pwroff_reset,
    inout  wire        cart_tran_pin31,
    output wire        cart_tran_pin31_dir
);

    // ------------------------------------------------------- the settings
    reg  [31:0] cfg_74 = 32'd0;
    always @(posedge clk_74a)
        if (bridge_wr && bridge_addr == 32'hF7000000)
            cfg_74 <= {bridge_wr_data[7:0], bridge_wr_data[15:8],
                       bridge_wr_data[23:16], bridge_wr_data[31:24]};

    wire [31:0] cfg;
    pocket_sync_bus #(.W(32)) s_cfg (.clk (clk_vid), .d (cfg_74), .q (cfg));

    wire        on      = cfg[5];
    wire [4:0]  ctype   = cfg[4:0];
    wire [3:0]  assign_ = cfg[9:6];
    wire [3:0]  vtype   = cfg[13:10];

    reg  [3:0]  m_vtype = 4'd0;             // the module's video code
    reg  [1:0]  m_lines = 2'd0;             // its scanlines (fx[1:0])
    reg         snac_ok = 1'b0;
    reg  [1:0]  p1_sel  = 2'd0;             // 0 the Pocket's controls, 1 SNAC 1, 2 SNAC 2
    reg  [1:0]  p2_sel  = 2'd0;
    always @(posedge clk_vid) begin
        m_vtype <= (vtype <= 4'd4) ? vtype : (vtype <= 4'd9) ? 4'd5 : 4'd0;
        m_lines <= (vtype >= 4'd5 && vtype <= 4'd8) ? vtype[1:0] - 2'd1 : 2'd0;
        case (ctype)
        5'h01, 5'h02, 5'h03, 5'h04, 5'h05, 5'h06, 5'h09, 5'h0B: snac_ok <= on;
        default:                                               snac_ok <= 1'b0;
        endcase
        p1_sel <= !snac_ok ? 2'd0 :
                  (assign_ == 4'd0 || assign_ == 4'd2 || assign_ == 4'd5) ? 2'd1 :
                  (assign_ == 4'd3) ? 2'd2 : 2'd0;
        p2_sel <= !snac_ok ? 2'd0 :
                  (assign_ == 4'd1 || assign_ == 4'd3) ? 2'd1 :
                  (assign_ == 4'd2 || assign_ == 4'd5) ? 2'd2 : 2'd0;
    end

    assign pocket_off = on & cfg[14];

    wire [15:0] snac1, snac2;
    assign key1    = (p1_sel == 2'd1) ? snac1 : (p1_sel == 2'd2) ? snac2 : cont1_key;
    assign key2    = (p2_sel == 2'd1) ? snac1 : (p2_sel == 2'd2) ? snac2 : cont2_key;
    assign p1_snac = (p1_sel != 2'd0);

    // Y/C: the colour subcarrier as a step of a 40-bit phase per clk_vid
    // clock, f * 2^40 / 28 MHz (NTSC 3.579545 MHz, PAL 4.43361875 MHz)
    wire        pal = (m_vtype == 4'd4);
    wire [39:0] phase_inc = pal ? 40'd174100548884 : 40'd140562548202;

    // ----------------------------------------------------------- the dot
    // Every one of the board's video signals is good on ce_pix, the clock its
    // consumers sample it on, but they do not all change on the same clock of
    // the four a dot lasts (the colour comes later than the blanking). The
    // module passes them to the pins as they are, so they are taken together
    // on ce_pix, as pocket_video takes them, and held for the whole dot.
    reg  [7:0]  vr = 8'd0, vg = 8'd0, vb = 8'd0;
    reg         vhs = 1'b0, vvs = 1'b0, vhb = 1'b1, vvb = 1'b1, vde = 1'b0;
    always @(posedge clk_vid) if (ce_pix) begin
        {vr, vg, vb} <= {r, g, b};
        {vhs, vvs, vhb, vvb, vde} <= {hs, vs, hblank, vblank, de};
    end

    // The scandoubler (MiST's) is the one part that reads vblank. It notes
    // where in an input line the change came and replays it at that place in
    // the first of the two output lines made from the next one. The board's
    // vblank changes on the dot its hsync ends, where the scandoubler starts
    // a line (on a falling edge: a sync is active low to it), and was noted
    // at the end of the line before, so the picture's last line came out
    // once, not twice (in sim). A few dots into the line, the change plays
    // at the start of the black line after the picture, and before the first.
    reg  [8:0]  dot = 9'd0;                 // dots since hsync ended
    reg         vvb_sd = 1'b1, vhs_q = 1'b0;
    always @(posedge clk_vid) if (ce_pix) begin
        vhs_q <= vhs;
        dot   <= (vhs_q && !vhs) ? 9'd0 : (dot == 9'h1FF) ? dot : dot + 9'd1;
        if (dot == 9'd4) vvb_sd <= vvb;
    end

    // --------------------------------------------------------- the module
    wire        m_pin30, m_pin30_dir;

    openFPGA_Pocket_Analogizer #(
        .MASTER_CLK_FREQ (28_000_000),
        .LINE_LENGTH     (448)
    ) u_anz (
        .i_clk            (clk_vid),
        .i_rst            (1'b0),
        .i_ena            (on),
        .video_clk        (clk_vid),
        .analog_video_type(m_vtype),
        .R (vr), .G (vg), .B (vb),
        .Hblank (vhb),    .Vblank (vvb_sd), .BLANKn (vde),
        .Hsync  (vhs),    .Vsync  (vvs),
        .Csync  (~(vhs ^ vvs)),             // active low, serrated in vsync
        .CHROMA_PHASE_INC (phase_inc),
        .PALFLAG          (pal),
        .ce_pix           (ce_pix),
        .scandoubler      (1'b1),
        .fx               ({1'b0, m_lines}),
        .conf_AB          (1'b0),
        .game_cont_type   (snac_ok ? ctype : 5'd0),
        .p1_btn_state     (snac1), .p1_joy_state (),
        .p2_btn_state     (snac2), .p2_joy_state (),
        .p3_btn_state     (),      .p4_btn_state (),
        .i_VIB_SW1 (2'b00), .i_VIB_DAT1 (8'h00), .i_VIB_SW2 (2'b00), .i_VIB_DAT2 (8'h00),
        .busy             (),
        .cart_tran_bank2  (cart_tran_bank2), .cart_tran_bank2_dir (cart_tran_bank2_dir),
        .cart_tran_bank3  (cart_tran_bank3), .cart_tran_bank3_dir (cart_tran_bank3_dir),
        .cart_tran_bank1  (cart_tran_bank1), .cart_tran_bank1_dir (cart_tran_bank1_dir),
        .cart_tran_bank0  (cart_tran_bank0), .cart_tran_bank0_dir (cart_tran_bank0_dir),
        .cart_tran_pin30  (m_pin30),         .cart_tran_pin30_dir (m_pin30_dir),
        .cart_pin30_pwroff_reset (cart_pin30_pwroff_reset),
        .cart_tran_pin31  (cart_tran_pin31), .cart_tran_pin31_dir (cart_tran_pin31_dir),
        .DBG_TX (), .o_stb ()
    );

    // pin30 is only ever an output with the adapter (its SNAC clock 2)
    assign cart_tran_pin30     = on ? m_pin30     : 1'b0;
    assign cart_tran_pin30_dir = on ? m_pin30_dir : 1'bz;

endmodule

`default_nettype wire
