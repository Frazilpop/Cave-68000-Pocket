// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — one sprite frame-buffer page on one PSRAM
// chip, a 16-word row at a time, in synchronous burst mode
//
// THE PART. AS1C8M16PL-70 (Alliance, CellularRAM 1.5 AD-MUX): the low sixteen
// address bits share the DQ pins and are latched by ADV#; two 8 MB dies behind
// one set of pins, CE0# and CE1#. A page of the frame buffer is 240 lines of
// 512 words, in die 0; CE1# is never used.
//
// WHY BURSTS. Asynchronously every word costs a full 70 ns cycle, so a page's
// worth of writes (the clear, then the blitter's ~76,000-222,000 pixels a
// frame on the busiest screens) would not fit a 17.4 ms frame. In
// synchronous burst mode a row of up to 16 words is one address phase, the
// latency, and a word a clock.
//
// THE CLOCK. The chip is clocked at 48 MHz, half of clk, from a register
// that toggles beside the others (`cram_clk`, a data pin like any other).
// Every output changes on the clk edge where cram_clk falls and is sampled by
// the chip one clk period (10.4 ns) later on its rise: setup and hold of
// 10.4 ns each against the part's 3 and 2. Read data comes out tACLK (9 ns at
// 48 MHz) after a rising edge and stays until 2 ns after the next one, so it
// is valid at the FPGA from ~(d + 9) to ~(d + 22.8) ns after the edge that
// launched the rise, d being the round trip of the pins and board (cram_clk
// leaves from a fabric register, so d can be several nanoseconds). It is
// captured either 20.8 ns after that edge (phase 0, inside the window for d
// from -2 to +11 ns) or 31.2 ns after it (phase 1, d from +8 to +22): the
// boot measures which, with the latency. Nothing here needs a phase-shifted
// clock, and the .sdc cuts these pins with that margin written down rather
// than timing them.
//
// THE MODE. BCR = 0x5C1F: synchronous burst (BCR[15] = 0), fixed latency
// (BCR[14] = 1) with latency code 3 (four clocks, which the datasheet allows
// up to 52 MHz), WAIT active high and asserted during the delay, half drive,
// no wrap, continuous burst. Fixed latency means the first word comes at the
// same clock every time, refresh collisions included, so WAIT is not needed;
// a burst ends by taking CE# high. The datasheet's figures leave the exact
// clock of the first word open by one either way, so it is MEASURED at boot
// rather than assumed (below), for reads and writes separately.
//
// BOOT. After the part's 150 us power-up:
//   1. sixteen known words are written asynchronously (the part powers up
//      asynchronous, with the clock held low) at a test row;
//   2. the BCR is written (CRE high, the value on the address lines);
//   3. the test row is read as a burst with each candidate read latency and
//      capture phase until one returns the sixteen words: rd_lat, rd_ph;
//   4. a second pattern is burst-written with each candidate write latency and
//      read back with rd_lat until one comes back whole: that is wr_lat;
//   5. the picture's rows (240 lines x 20 rows) are written with zeros, so
//      the first frames show no garbage; then `ready`.
// If no latency works, `cal_fail` is set and the servant runs with the
// datasheet's figure; the overlay shows both latencies and the flag.
//
// THE PORT (fbN): req held until a one-cycle ack, with addr, wdata and wmask
// held with it (they are read as the burst goes, not copied); a write sends
// only the words its byte mask touches, as one burst from the first to the
// last of them, with UB#/LB# high for the bytes it leaves alone; a read
// returns all sixteen words, word k at [16k +: 16], valid from the ack until
// the next request.

`default_nettype none

module pocket_psram_rows #(
  parameter real         CLOCK_MHZ = 96.0,
  parameter logic [15:0] BCR       = 16'h5C1F,
  parameter int unsigned LAT_DEF   = 4,       // the datasheet's reading of code 3
  parameter int unsigned CLEAR_LINES = 240,
  parameter int unsigned CLEAR_ROWS  = 20     // rows of 16 words from x = 0
) (
  input  wire          clk,
  input  wire          rst,                   // power-on only

  // the board's side (one fbN port of cave_fb_rows)
  input  wire          req,
  input  wire          we,
  input  wire [21:0]   addr,                  // word 0 of the row, 16-word aligned
  input  wire [255:0]  wdata,
  input  wire [31:0]   wmask,                 // one bit a byte
  output reg           ack,
  output wire [255:0]  rdata,

  output reg           ready,
  output reg           cal_fail,
  output reg  [2:0]    rd_lat,
  output reg           rd_ph,
  output reg  [2:0]    wr_lat,

  // pins (DQ split; the tri-state is at the top)
  output reg  [21:16]  cram_a,
  output reg  [15:0]   cram_dq_o,
  output reg           cram_dq_oe,
  input  wire [15:0]   cram_dq_i,
  output reg           cram_clk,
  output reg           cram_adv_n,
  output reg           cram_cre,
  output reg           cram_ce0_n,
  output reg           cram_ce1_n,
  output reg           cram_oe_n,
  output reg           cram_we_n,
  output reg           cram_ub_n,
  output reg           cram_lb_n
);

  // ------------------------------------------------------------- the clock
  // `run` lets cram_clk toggle; an update edge is one where cram_clk is (or
  // stays) low after it, and every pin but the clock changes only there.
  reg  run;
  wire upd = !(run && !cram_clk);           // cram_clk goes (or stays) low at this edge

  // read data, captured at every edge; at an update edge it holds what the
  // chip drove after the rising edge two device clocks back (see THE CLOCK)
  reg [15:0] dq_r, dq_p;                    // dq_p: the same a clock later (phase 1)
  always @(posedge clk) begin
    dq_r <= cram_dq_i;
    dq_p <= dq_r;
  end

  // ------------------------------------------------------------ operations
  localparam [3:0] O_NONE = 4'd0, O_AWR = 4'd1, O_BCR = 4'd2, O_RD = 4'd3, O_WR = 4'd4;
  reg [3:0]   op;
  reg [5:0]   n;                            // device clocks (or, async, clk cycles) into the op
  reg [21:0]  op_addr;
  reg [1:0]   op_src;                       // a write's data: 0 the port's, 1 a test pattern, 2 zeros
  reg [15:0]  op_aw;                        // an asynchronous write's word
  reg [31:0]  op_wmask;
  reg [3:0]   op_s, op_cnt;                 // a write's first word and its word count - 1
  reg [255:0] op_rdata;
  reg [2:0]   op_lat;
  reg         op_ph;
  reg         op_done, op_done_d;
  reg         m_a, m_b;                     // the row read back is test pattern a / b

  // first and last words a write's mask touches
  wire [15:0] wwords;
  genvar gw;
  generate for (gw = 0; gw < 16; gw = gw + 1) begin : ww
    assign wwords[gw] = |op_wmask[2*gw +: 2];
  end endgenerate
  reg [3:0] w_first, w_last;
  integer q;
  always @(*) begin
    w_first = 4'd0; w_last = 4'd0;
    for (q = 15; q >= 0; q = q - 1) if (wwords[q]) w_first = q[3:0];
    for (q = 0; q < 16; q = q + 1)  if (wwords[q]) w_last  = q[3:0];
  end

  // ------------------------------------------------------------ the boot
  localparam int unsigned T_PU = int'(CLOCK_MHZ * 160.0);   // > 150 us
  localparam [21:0] T_ROW = 22'h20_0000;                     // test rows, far from the picture

  localparam [3:0] B_PU = 4'd0, B_SEED = 4'd1, B_BCR = 4'd2, B_RCAL = 4'd3,
                   B_WCAL_W = 4'd4, B_WCAL_R = 4'd5, B_CLEAR = 4'd6, B_RUN = 4'd7,
                   B_CRE = 4'd8;
  reg [3:0]  boot;
  reg [15:0] pu_cnt;
  reg [4:0]  seed_i;
  reg [2:0]  try_lat;
  reg        try_ph;
  reg [8:0]  clr_line;
  reg [4:0]  clr_row;

  function automatic [15:0] pat_a(input [3:0] i);   // the async seed
    pat_a = {i, ~i, 4'hA, i} ^ 16'h1234;
  endfunction
  function automatic [15:0] pat_b(input [3:0] i, input [2:0] l);  // a write try's pattern
    pat_b = {l, 1'b1, ~i, i, 4'h5} ^ 16'h0F0F;
  endfunction
  function automatic [255:0] pat_a_row();
    integer j;
    for (j = 0; j < 16; j = j + 1) pat_a_row[16*j +: 16] = pat_a(j[3:0]);
  endfunction
  function automatic [255:0] pat_b_row(input [2:0] l);
    integer j;
    for (j = 0; j < 16; j = j + 1) pat_b_row[16*j +: 16] = pat_b(j[3:0], l);
  endfunction

  localparam [2:0] LAT_MIN = 3'd2, LAT_MAX = 3'd7;
  wire [255:0] op_wdata = (op_src == 2'd1) ? pat_b_row(op_lat) :
                          (op_src == 2'd2) ? 256'd0 : wdata;
  wire [5:0] rd_k0 = {3'd0, op_lat} + 6'd2 + {5'd0, op_ph};   // the clock of a read's word 0

  // ---------------------------------------------------------------- start
  task automatic start(input [3:0] o, input [21:0] a, input [1:0] src, input [15:0] aw,
                       input [31:0] m, input [2:0] l, input ph);
    op       <= o;
    n        <= 6'd0;
    op_addr  <= a;
    op_src   <= src;
    op_aw    <= aw;
    op_wmask <= m;
    op_lat   <= l;
    op_ph    <= ph;
  endtask

  // The read-back compares are registered: the calibration acts on them the
  // clock after the read is done (op_done_d), when op_rdata has settled.
  always @(posedge clk) begin
    m_a       <= op_rdata == pat_a_row();
    m_b       <= op_rdata == pat_b_row(try_lat);
    op_done_d <= op_done;
  end
  assign rdata = op_rdata;

  integer k;
  always @(posedge clk) begin
    ack     <= 1'b0;
    op_done <= 1'b0;

    if (rst) begin
      run        <= 1'b0;
      cram_clk   <= 1'b0;
      cram_adv_n <= 1'b1;
      cram_cre   <= 1'b0;
      cram_ce0_n <= 1'b1;
      cram_ce1_n <= 1'b1;
      cram_oe_n  <= 1'b1;
      cram_we_n  <= 1'b1;
      cram_ub_n  <= 1'b1;
      cram_lb_n  <= 1'b1;
      cram_dq_oe <= 1'b0;
      cram_dq_o  <= 16'd0;
      cram_a     <= 6'd0;
      op         <= O_NONE;
      boot       <= B_PU;
      pu_cnt     <= 16'd0;
      ready      <= 1'b0;
      cal_fail   <= 1'b0;
      rd_lat     <= 3'(LAT_DEF);
      rd_ph      <= 1'b0;
      wr_lat     <= 3'(LAT_DEF);
    end else begin
      cram_clk <= run && !cram_clk;

      // --------------------------------------------- the operation in hand
      if (upd) case (op)
        // An asynchronous write, the clock held low, counted in clk cycles:
        // ADV# low with the address at 0 and high at 1, the data from 2, WE#
        // and CE# high at 8 (83 ns of WE#, against tWP 45 and tAW 70), the
        // bus let go at 9. The BCR write is the same with CRE high around it
        // and the register's value on the address lines.
        O_AWR, O_BCR: begin
          n <= n + 6'd1;
          case (n)
          6'd0: begin
            cram_ce0_n <= 1'b0; cram_adv_n <= 1'b0; cram_we_n <= 1'b0;
            cram_oe_n  <= 1'b1; cram_ub_n  <= 1'b0; cram_lb_n <= 1'b0;
            cram_a     <= (op == O_BCR) ? 6'b00_10_00 : op_addr[21:16];
            cram_dq_o  <= (op == O_BCR) ? BCR : op_addr[15:0];
            cram_dq_oe <= 1'b1;
          end
          6'd1: cram_adv_n <= 1'b1;
          6'd2: cram_dq_o  <= op_aw;
          6'd8: begin cram_we_n <= 1'b1; cram_ce0_n <= 1'b1; end
          6'd9: begin
            cram_dq_oe <= 1'b0; cram_ub_n <= 1'b1; cram_lb_n <= 1'b1;
            cram_cre   <= 1'b0;
            op <= O_NONE; op_done <= 1'b1;
          end
          default: ;
          endcase
        end

        // A burst write, counted in device clocks: the address at 0 with
        // ADV#, CE# and WE# low; word i of the run at op_lat + i with its
        // byte enables; CE# high (and the bus let go) the clock after the last.
        O_WR: begin
          n <= n + 6'd1;
          if (n == 6'd0) begin
            cram_ce0_n <= 1'b0; cram_adv_n <= 1'b0; cram_we_n <= 1'b0;
            cram_oe_n  <= 1'b1; cram_ub_n  <= 1'b1; cram_lb_n <= 1'b1;
            cram_a     <= op_addr[21:16];
            cram_dq_o  <= op_addr[15:0] + {12'd0, w_first};
            cram_dq_oe <= 1'b1;
            op_s       <= w_first;
            op_cnt     <= w_last - w_first;
          end else begin
            cram_adv_n <= 1'b1;
            if (n >= {3'd0, op_lat} && n <= {3'd0, op_lat} + {2'd0, op_cnt}) begin
              cram_dq_o <= op_wdata[16*(op_s + 4'(n - {3'd0, op_lat})) +: 16];
              cram_ub_n <= !op_wmask[2*(op_s + 4'(n - {3'd0, op_lat})) + 1];
              cram_lb_n <= !op_wmask[2*(op_s + 4'(n - {3'd0, op_lat}))];
            end else if (n == {3'd0, op_lat} + {2'd0, op_cnt} + 6'd1) begin
              cram_ce0_n <= 1'b1; cram_we_n <= 1'b1;
              cram_ub_n  <= 1'b1; cram_lb_n <= 1'b1;
              cram_dq_oe <= 1'b0;
            end else if (n == {3'd0, op_lat} + {2'd0, op_cnt} + 6'd2) begin
              op <= O_NONE; op_done <= 1'b1;      // a clock of CE# high: tCBPH
            end
          end
        end

        // A burst read of the whole row: the address at 0, OE# low and the bus
        // let go at 1; the word the chip drives after clock j is in dq_r at
        // clock j + 2 (phase 0), or in dq_p at clock j + 3 (phase 1), so word
        // i is taken at op_lat + i + 2 + phase. CE# goes high after the last,
        // and one more clock lets the chip off the bus.
        O_RD: begin
          n <= n + 6'd1;
          if (n == 6'd0) begin
            cram_ce0_n <= 1'b0; cram_adv_n <= 1'b0; cram_we_n <= 1'b1;
            cram_oe_n  <= 1'b1; cram_ub_n  <= 1'b0; cram_lb_n <= 1'b0;
            cram_a     <= op_addr[21:16];
            cram_dq_o  <= op_addr[15:0];
            cram_dq_oe <= 1'b1;
          end else begin
            if (n == 6'd1) begin
              cram_adv_n <= 1'b1; cram_dq_oe <= 1'b0; cram_oe_n <= 1'b0;
            end
            if (n >= rd_k0 && n <= rd_k0 + 6'd15)
              op_rdata[16*(4'(n - rd_k0)) +: 16] <= op_ph ? dq_p : dq_r;
            if (n == rd_k0 + 6'd15) begin
              cram_ce0_n <= 1'b1; cram_oe_n <= 1'b1;
              cram_ub_n  <= 1'b1; cram_lb_n <= 1'b1;
            end
            if (n == rd_k0 + 6'd16) begin
              op <= O_NONE; op_done <= 1'b1;
            end
          end
        end

        default: ;
      endcase

      // ------------------------------------------------------- the boot
      if (op == O_NONE && !op_done) case (boot)
        B_PU: begin
          if (pu_cnt == 16'(T_PU)) begin
            boot   <= B_SEED;
            seed_i <= 5'd0;
          end else pu_cnt <= pu_cnt + 16'd1;
        end
        B_SEED: begin
          if (seed_i == 5'd16) begin
            cram_cre <= 1'b1;                       // ahead of CE#, held through the write
            pu_cnt   <= 16'd0;
            boot     <= B_CRE;
          end else begin
            start(O_AWR, T_ROW + {18'd0, seed_i[3:0]}, 2'd0, pat_a(seed_i[3:0]), 32'd3, 3'd0, 1'b0);
            seed_i <= seed_i + 5'd1;
          end
        end
        B_CRE: begin
          if (pu_cnt == 16'd3) begin
            start(O_BCR, 22'd0, 2'd0, 16'd0, 32'd0, 3'd0, 1'b0);
            boot <= B_BCR;
          end else pu_cnt <= pu_cnt + 16'd1;
        end
        B_BCR: begin
          run     <= 1'b1;
          try_lat <= LAT_MIN;
          try_ph  <= 1'b0;
          start(O_RD, T_ROW, 2'd0, 16'd0, 32'd0, LAT_MIN, 1'b0);
          boot    <= B_RCAL;
        end
        default: ;
      endcase

      if (op_done_d) case (boot)
        B_RCAL: begin
          if (m_a) begin
            rd_lat  <= try_lat;
            rd_ph   <= try_ph;
            try_lat <= LAT_MIN;
            start(O_WR, T_ROW + 22'h10, 2'd1, 16'd0, 32'hFFFF_FFFF, LAT_MIN, 1'b0);
            boot    <= B_WCAL_W;
          end else if (try_lat == LAT_MAX && try_ph) begin
            cal_fail <= 1'b1;
            boot     <= B_CLEAR;
            clr_line <= 9'd0; clr_row <= 5'd0;
          end else if (!try_ph) begin
            try_ph  <= 1'b1;
            start(O_RD, T_ROW, 2'd0, 16'd0, 32'd0, try_lat, 1'b1);
          end else begin
            try_lat <= try_lat + 3'd1;
            try_ph  <= 1'b0;
            start(O_RD, T_ROW, 2'd0, 16'd0, 32'd0, try_lat + 3'd1, 1'b0);
          end
        end
        B_WCAL_W: begin
          start(O_RD, T_ROW + 22'h10, 2'd0, 16'd0, 32'd0, rd_lat, rd_ph);
          boot <= B_WCAL_R;
        end
        B_WCAL_R: begin
          if (m_b) begin
            wr_lat   <= try_lat;
            boot     <= B_CLEAR;
            clr_line <= 9'd0; clr_row <= 5'd0;
          end else if (try_lat == LAT_MAX) begin
            cal_fail <= 1'b1;
            boot     <= B_CLEAR;
            clr_line <= 9'd0; clr_row <= 5'd0;
          end else begin
            try_lat <= try_lat + 3'd1;
            start(O_WR, T_ROW + 22'h10, 2'd1, 16'd0, 32'hFFFF_FFFF, try_lat + 3'd1, 1'b0);
            boot    <= B_WCAL_W;
          end
        end
        default: ;
      endcase

      // the picture cleared, a row at a time
      if (boot == B_CLEAR && op == O_NONE && !op_done) begin
        if (clr_line == 9'(CLEAR_LINES)) begin
          boot  <= B_RUN;
          ready <= 1'b1;
        end else begin
          start(O_WR, {4'd0, clr_line, clr_row, 4'd0}, 2'd2, 16'd0, 32'hFFFF_FFFF, wr_lat, 1'b0);
          if (clr_row == 5'(CLEAR_ROWS - 1)) begin
            clr_row  <= 5'd0;
            clr_line <= clr_line + 9'd1;
          end else clr_row <= clr_row + 5'd1;
        end
      end

      // ------------------------------------------------- the board's rows
      if (boot == B_RUN) begin
        if (op_done) ack <= 1'b1;
        if (op == O_NONE && !op_done && !ack && req) begin
          if (we && wmask == 32'd0) ack <= 1'b1;   // nothing to write
          else start(we ? O_WR : O_RD, addr, 2'd0, 16'd0, wmask, we ? wr_lat : rd_lat, rd_ph);
        end
      end
    end
  end

endmodule

`default_nettype wire
