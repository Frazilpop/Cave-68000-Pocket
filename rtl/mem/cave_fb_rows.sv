// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the sprite frame buffer's DDR queue on two
// row-wide memories, one page per chip
//
// Upstream keeps the sprite frame buffer in DDR, as two 512 KB pages at
// {0x121, page[1:0], 19 bits}: a line of 512 16-bit pixels every 1024 bytes,
// line y at y << 10, pixel x at x << 1. Three things use it, as DDR.sv saw
// them (SpriteFrameBuffer):
//
//   - the line DMA reads the line under the next one in 16-beat bursts
//     (64-bit beats, 64 pixels a burst, eight bursts a line), on a port of
//     its own;
//   - the clear DMA writes zeros over the page about to be drawn, in bursts
//     of up to 64 beats with the address given on beat 0 only, and
//   - the request queue writes the blitter's pixels as single 64-bit beats
//     with a byte mask, four pixels at most, both on the other port.
//
// Here the two pages are the two PSRAM chips (page bit 19 picks the chip),
// and a chip moves a ROW at a time: 16 consecutive words, row aligned, with a
// byte mask on writes (the row ports, pocket_psram_rows on the Pocket). A row
// costs the same few clocks of overhead however few words it carries, so the
// write side gathers beats into one open row and sends it only when a beat
// for another row arrives, when nothing has come for a while, or when the
// read side needs that row. One row write is in flight at a time (the
// writes all go to the page being drawn), so the two chips share its data. The blitter draws along a sprite's lines, so its
// beats arrive in runs on one row and most rows go out whole.
//
// The read side answers a burst row by row: a row outside the 320 x 240
// picture is zeros without touching the chip (the line DMA reads all 512
// pixels of a line), a row inside is one row read. Reads and writes run at
// once: they are on different chips except around a page swap, and where they
// meet at a chip the read goes first, since the beam is waiting for it.
//
// The bitmap word address on a chip is y * 512 + x, as upstream's page holds
// it; rows are 16-word aligned there, so a row never crosses one of the
// PSRAM's own rows.

`default_nettype none

module cave_fb_rows (
  input  wire         clk,
  input  wire         rst,

  // upstream's read port (SpriteFrameBuffer's io_ddrRd_*), 16-beat bursts
  input  wire         rd,
  input  wire [31:0]  rd_addr,
  output reg  [63:0]  rd_dout,
  output wire         rd_wait_n,
  output reg          rd_valid,
  output reg          rd_burst_done,

  // upstream's write port (io_ddr_*)
  input  wire         wr,
  input  wire [31:0]  wr_addr,
  input  wire [7:0]   wr_mask,
  input  wire [63:0]  wr_din,
  input  wire [7:0]   wr_burst_len,
  output wire         wr_wait_n,
  output wire         wr_burst_done,

  // one row port per chip: chip c at [c]
  output reg  [1:0]   row_req,
  output reg  [1:0]   row_we,
  output reg  [43:0]  row_addr,          // chip c at [22*c +: 22], word 0 of the row
  output reg  [255:0] row_wdata,         // both chips: word k at [16k +: 16]
  output reg  [31:0]  row_wmask,         // both chips: one bit a byte
  input  wire [1:0]   row_ack,
  input  wire [511:0] row_rdata,

  // diagnostics: free-running counts, and the longest a read burst waited
  // for its first row since the last clear
  output reg  [15:0]  rows_written,
  output reg  [15:0]  rows_read,
  output reg  [15:0]  rd_wait_max,
  input  wire         diag_clr
);

  localparam int unsigned WIDTH = 320, HEIGHT = 240;
  localparam int unsigned IDLE_FLUSH = 32;  // clocks without a beat before the open row goes

  // ------------------------------------------------------------- read side
  reg         r_busy;
  reg  [31:0] r_addr;                    // the beat being answered
  reg  [7:0]  r_beat;
  reg  [1:0]  r_phase;                   // 0 decide, 1 wait for the row, 2 play
  reg  [255:0] r_row;
  reg  [15:0] r_wait;
  wire        r_chip = r_addr[19];
  wire        r_in   = (r_addr[18:10] < 9'(HEIGHT)) && (r_addr[9:1] < 9'(WIDTH));
  wire        r_want = r_busy && r_phase == 2'd0 && r_in;   // a row read for r_chip
  assign rd_wait_n = !r_busy;

  // ------------------------------------------------------------ write side
  reg         o_valid;                   // the open row
  reg         o_chip;
  reg  [13:0] o_row;                     // {y, x[8:4]}
  reg  [255:0] o_data;
  reg  [31:0] o_mask;
  reg  [5:0]  o_idle;

  // A read waits only for an open row on the very row it reads (that must
  // reach the chip first); otherwise, where the two meet at a chip's free
  // request register, the read takes it and the open row waits.
  wire        w_inflight = |(row_req & row_we);
  wire        r_conflict = o_valid && o_chip == r_chip && o_row == r_addr[18:5];
  wire        r_go   = r_want && !row_req[r_chip] && !r_conflict;
  // the open row may go to its chip this clock
  wire        o_can  = o_valid && !w_inflight && !row_req[o_chip] &&
                       !(r_want && r_chip == o_chip && !r_conflict);
  // a beat can be taken when the open row could make way for it
  assign wr_wait_n = !o_valid || o_can;

  reg         w_inburst;
  reg  [31:0] w_next;                    // the next beat's address in a burst
  reg  [7:0]  w_cnt, w_len;
  wire        w_take  = wr && wr_wait_n;
  wire [31:0] w_a     = w_inburst ? w_next : wr_addr;
  wire [7:0]  w_lenN  = w_inburst ? w_len : wr_burst_len;
  wire        w_last  = (w_cnt == w_lenN - 8'd1) || (w_lenN == 8'd0);
  assign wr_burst_done = w_take && w_last;

  wire        b_chip = w_a[19];
  wire [13:0] b_row  = w_a[18:5];
  wire [1:0]  b_q    = w_a[4:3];         // the quarter of the row the beat fills
  wire        b_hit  = o_valid && (o_chip == b_chip) && (o_row == b_row);
  wire        o_send = o_can && ((w_take && !b_hit) || (!w_take &&
                         ((o_idle == 6'(IDLE_FLUSH)) || (&o_mask) || (r_want && r_conflict))));

  integer k;
  always @(posedge clk) begin
    rd_valid      <= 1'b0;
    rd_burst_done <= 1'b0;
    if (rst) begin
      r_busy       <= 1'b0;
      o_valid      <= 1'b0;
      o_idle       <= 6'd0;
      w_inburst    <= 1'b0;
      w_cnt        <= 8'd0;
      row_req      <= 2'b00;
      rows_written <= 16'd0;
      rows_read    <= 16'd0;
      rd_wait_max  <= 16'd0;
    end else begin
      for (k = 0; k < 2; k = k + 1)
        if (row_req[k] && row_ack[k]) row_req[k] <= 1'b0;

      // ------------------------------------------------------ writes
      if (w_take) begin
        if (!w_inburst) w_len <= wr_burst_len;
        w_next    <= w_a + 32'd8;
        w_inburst <= !w_last;
        w_cnt     <= w_last ? 8'd0 : w_cnt + 8'd1;
        o_idle    <= 6'd0;
        if (b_hit) begin
          for (k = 0; k < 8; k = k + 1)
            if (wr_mask[k]) o_data[64*b_q + 8*k +: 8] <= wr_din[8*k +: 8];
          o_mask[8*b_q +: 8] <= o_mask[8*b_q +: 8] | wr_mask;
        end else begin
          o_valid <= 1'b1;
          o_chip  <= b_chip;
          o_row   <= b_row;
          o_mask  <= {24'd0, wr_mask} << (8 * b_q);
          o_data  <= {192'd0, wr_din} << (64 * b_q);
        end
      end else if (o_send) begin
        o_valid <= 1'b0;
        o_idle  <= 6'd0;
      end else if (o_valid && o_idle != 6'(IDLE_FLUSH)) begin
        o_idle <= o_idle + 6'd1;
      end
      if (o_send) begin
        row_req[o_chip]              <= 1'b1;
        row_we[o_chip]               <= 1'b1;
        row_addr[22*o_chip +: 22]    <= {4'd0, o_row, 4'd0};
        row_wdata                    <= o_data;
        row_wmask                    <= o_mask;
        rows_written                 <= rows_written + 16'd1;
      end

      // ------------------------------------------------------- reads
      if (!r_busy && rd) begin
        r_busy  <= 1'b1;
        r_addr  <= rd_addr;
        r_beat  <= 8'd0;
        r_phase <= 2'd0;
        r_wait  <= 16'd0;
      end
      if (r_busy) begin
        if (r_beat == 8'd0 && r_phase != 2'd2) r_wait <= r_wait + 16'd1;
        case (r_phase)
        2'd0: begin
          if (!r_in) begin
            r_row   <= 256'd0;
            r_phase <= 2'd2;
          end else if (r_go) begin
            row_req[r_chip]           <= 1'b1;
            row_we[r_chip]            <= 1'b0;
            row_addr[22*r_chip +: 22] <= {4'd0, r_addr[18:5], 4'd0};
            rows_read                 <= rows_read + 16'd1;
            r_phase                   <= 2'd1;
          end
        end
        2'd1: if (row_req[r_chip] && row_ack[r_chip]) begin
          r_row   <= row_rdata[256*r_chip +: 256];
          r_phase <= 2'd2;
        end
        default: begin
          if (r_beat == 8'd0 && r_wait > rd_wait_max) rd_wait_max <= r_wait;
          rd_valid <= 1'b1;
          rd_dout  <= r_row[64*r_beat[1:0] +: 64];
          r_beat   <= r_beat + 8'd1;
          r_addr   <= r_addr + 32'd8;
          if (r_beat == 8'd15) begin
            rd_burst_done <= 1'b1;
            r_busy        <= 1'b0;
          end else if (r_beat[1:0] == 2'd3) begin
            r_phase <= 2'd0;
          end
        end
        endcase
      end
      if (diag_clr) rd_wait_max <= 16'd0;
    end
  end

endmodule

`default_nettype wire
