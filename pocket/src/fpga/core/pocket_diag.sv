// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — diagnostic overlay
//
// WHY THIS EXISTS. The first build on a real Pocket came up black, and a
// black screen says nothing: no video signal, a core still held in reset, a
// ROM that never finished loading, SDRAM returning garbage to the 68000 and
// a 68000 that crashed on its first fetch all look the same. This draws the
// shell's own state over the picture, in the shell, needing nothing from the
// board but its timing strobes, so it is visible whenever the Pocket is
// receiving video at all.
//
// It sits between the board and pocket_video and is combinational on the
// board's pixel: the strobes already arrive aligned with r/g/b on ce_pix, and
// a registered overlay would be one pixel late. The x/y it needs are rebuilt
// from hblank/vblank, so it does not depend on the board exporting counters.
//
// WHAT IT DRAWS (320 x 240, coordinates in the visible window)
//
//   y 1..6     sixteen flag cells, 12 px wide on a 16 px pitch, flag[0] at
//              the left. GREEN = 1, RED = 0.
//   y 16..47   eight counters as "<j> <8 hex digits>" in 8x8 text, white on
//              black: counters 0-3 down the left column (x 0..79), 4-7 down
//              the right (x 160..239). Nibbles are printed most significant
//              first.
//
// `bars` replaces the board's picture with eight vertical colour bars so a
// live video path is unmistakable even when the board draws nothing.
//
// Only the hex digits have glyphs (IBM CP437 8x8), because that is all the
// overlay prints.

`default_nettype none

module pocket_diag (
    input  wire         clk,          // the board's video clock (28 MHz), with ce_pix
    input  wire         ce_pix,
    input  wire         hblank, vblank,
    input  wire [7:0]   r_in, g_in, b_in,

    input  wire         enable,       // draw flags and counters
    input  wire         bars,         // colour bars instead of the picture
    input  wire [15:0]  flags,
    input  wire [255:0] cnt,          // counter j at [32*j +: 32]

    output wire [7:0]   r_out, g_out, b_out
);

    // --------------------------------------------------------- position
    // x and y of the pixel on the inputs during this ce_pix. x restarts in
    // every horizontal blank, y in vertical blank and steps at the end of
    // every active line.
    reg [8:0] x = 9'd0;
    reg [8:0] y = 9'd0;
    reg       hb_q = 1'b1;
    always @(posedge clk) if (ce_pix) begin
        hb_q <= hblank;
        x <= hblank ? 9'd0 : x + 9'd1;
        if (vblank)               y <= 9'd0;
        else if (hblank && !hb_q) y <= y + 9'd1;
    end

    // --------------------------------------------------------------- font
    function automatic [7:0] glyph(input [3:0] d, input [2:0] row);
        case ({d, row})
        7'h00: glyph = 8'h7C; 7'h01: glyph = 8'hC6; 7'h02: glyph = 8'hCE; 7'h03: glyph = 8'hDE;
        7'h04: glyph = 8'hF6; 7'h05: glyph = 8'hE6; 7'h06: glyph = 8'h7C; 7'h07: glyph = 8'h00;
        7'h08: glyph = 8'h30; 7'h09: glyph = 8'h70; 7'h0A: glyph = 8'h30; 7'h0B: glyph = 8'h30;
        7'h0C: glyph = 8'h30; 7'h0D: glyph = 8'h30; 7'h0E: glyph = 8'hFC; 7'h0F: glyph = 8'h00;
        7'h10: glyph = 8'h78; 7'h11: glyph = 8'hCC; 7'h12: glyph = 8'h0C; 7'h13: glyph = 8'h38;
        7'h14: glyph = 8'h60; 7'h15: glyph = 8'hCC; 7'h16: glyph = 8'hFC; 7'h17: glyph = 8'h00;
        7'h18: glyph = 8'h78; 7'h19: glyph = 8'hCC; 7'h1A: glyph = 8'h0C; 7'h1B: glyph = 8'h38;
        7'h1C: glyph = 8'h0C; 7'h1D: glyph = 8'hCC; 7'h1E: glyph = 8'h78; 7'h1F: glyph = 8'h00;
        7'h20: glyph = 8'h1C; 7'h21: glyph = 8'h3C; 7'h22: glyph = 8'h6C; 7'h23: glyph = 8'hCC;
        7'h24: glyph = 8'hFE; 7'h25: glyph = 8'h0C; 7'h26: glyph = 8'h1E; 7'h27: glyph = 8'h00;
        7'h28: glyph = 8'hFC; 7'h29: glyph = 8'hC0; 7'h2A: glyph = 8'hF8; 7'h2B: glyph = 8'h0C;
        7'h2C: glyph = 8'h0C; 7'h2D: glyph = 8'hCC; 7'h2E: glyph = 8'h78; 7'h2F: glyph = 8'h00;
        7'h30: glyph = 8'h38; 7'h31: glyph = 8'h60; 7'h32: glyph = 8'hC0; 7'h33: glyph = 8'hF8;
        7'h34: glyph = 8'hCC; 7'h35: glyph = 8'hCC; 7'h36: glyph = 8'h78; 7'h37: glyph = 8'h00;
        7'h38: glyph = 8'hFC; 7'h39: glyph = 8'hCC; 7'h3A: glyph = 8'h0C; 7'h3B: glyph = 8'h18;
        7'h3C: glyph = 8'h30; 7'h3D: glyph = 8'h30; 7'h3E: glyph = 8'h30; 7'h3F: glyph = 8'h00;
        7'h40: glyph = 8'h78; 7'h41: glyph = 8'hCC; 7'h42: glyph = 8'hCC; 7'h43: glyph = 8'h78;
        7'h44: glyph = 8'hCC; 7'h45: glyph = 8'hCC; 7'h46: glyph = 8'h78; 7'h47: glyph = 8'h00;
        7'h48: glyph = 8'h78; 7'h49: glyph = 8'hCC; 7'h4A: glyph = 8'hCC; 7'h4B: glyph = 8'h7C;
        7'h4C: glyph = 8'h0C; 7'h4D: glyph = 8'h18; 7'h4E: glyph = 8'h70; 7'h4F: glyph = 8'h00;
        7'h50: glyph = 8'h30; 7'h51: glyph = 8'h78; 7'h52: glyph = 8'hCC; 7'h53: glyph = 8'hCC;
        7'h54: glyph = 8'hFC; 7'h55: glyph = 8'hCC; 7'h56: glyph = 8'hCC; 7'h57: glyph = 8'h00;
        7'h58: glyph = 8'hFC; 7'h59: glyph = 8'h66; 7'h5A: glyph = 8'h66; 7'h5B: glyph = 8'h7C;
        7'h5C: glyph = 8'h66; 7'h5D: glyph = 8'h66; 7'h5E: glyph = 8'hFC; 7'h5F: glyph = 8'h00;
        7'h60: glyph = 8'h3C; 7'h61: glyph = 8'h66; 7'h62: glyph = 8'hC0; 7'h63: glyph = 8'hC0;
        7'h64: glyph = 8'hC0; 7'h65: glyph = 8'h66; 7'h66: glyph = 8'h3C; 7'h67: glyph = 8'h00;
        7'h68: glyph = 8'hF8; 7'h69: glyph = 8'h6C; 7'h6A: glyph = 8'h66; 7'h6B: glyph = 8'h66;
        7'h6C: glyph = 8'h66; 7'h6D: glyph = 8'h6C; 7'h6E: glyph = 8'hF8; 7'h6F: glyph = 8'h00;
        7'h70: glyph = 8'hFE; 7'h71: glyph = 8'h62; 7'h72: glyph = 8'h68; 7'h73: glyph = 8'h78;
        7'h74: glyph = 8'h68; 7'h75: glyph = 8'h62; 7'h76: glyph = 8'hFE; 7'h77: glyph = 8'h00;
        7'h78: glyph = 8'hFE; 7'h79: glyph = 8'h62; 7'h7A: glyph = 8'h68; 7'h7B: glyph = 8'h78;
        7'h7C: glyph = 8'h68; 7'h7D: glyph = 8'h60; 7'h7E: glyph = 8'hF0; 7'h7F: glyph = 8'h00;
        default: glyph = 8'h00;
        endcase
    endfunction

    // ---------------------------------------------------------- flags row
    wire        in_flags = enable && (y >= 9'd1) && (y < 9'd7) &&
                           (x[8:4] < 5'd16) && (x[3:0] < 4'd12);
    wire        flag_on  = flags[x[7:4]];

    // ------------------------------------------------------- counter rows
    wire        col      = (x >= 9'd160);
    wire [8:0]  xr       = col ? x - 9'd160 : x;             // 0..159
    wire        in_text  = enable && (y >= 9'd16) && (y < 9'd48) && (xr < 9'd80);
    wire [1:0]  row_k    = y[4:3] - 2'd2;                     // (y-16)>>3
    wire [2:0]  ctr      = {col, row_k};                      // counter index j
    wire [3:0]  ch       = xr[6:3];                           // character 0..9
    wire [2:0]  ccol     = xr[2:0];
    wire [31:0] val      = cnt[32*ctr +: 32];
    wire [2:0]  nib      = 3'd7 - (ch[2:0] - 3'd2);           // digit ch-2, MS first
    wire [3:0]  digit    = (ch == 4'd0) ? {1'b0, ctr} : val[4*nib +: 4];
    wire        blank_ch = (ch == 4'd1);
    wire [7:0]  g_row    = glyph(digit, y[2:0]);
    wire        text_on  = !blank_ch && g_row[3'd7 - ccol];

    // ---------------------------------------------------------- bars
    // White, yellow, cyan, green, magenta, red, blue, dark grey: 40 px each.
    reg [23:0] bar;
    always @(*) begin
        case (x / 9'd40)
        9'd0: bar = 24'hFFFFFF; 9'd1: bar = 24'hFFFF00;
        9'd2: bar = 24'h00FFFF; 9'd3: bar = 24'h00FF00;
        9'd4: bar = 24'hFF00FF; 9'd5: bar = 24'hFF0000;
        9'd6: bar = 24'h0000FF; default: bar = 24'h404040;
        endcase
    end

    // ---------------------------------------------------------- output
    wire [23:0] base = bars ? bar : {r_in, g_in, b_in};
    wire [23:0] pix  = in_flags ? (flag_on ? 24'h008000 : 24'h800000)
                     : in_text  ? (text_on ? 24'h707070 : 24'h000000)
                     : base;
    assign {r_out, g_out, b_out} = pix;

endmodule

`default_nettype wire
