// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the Pocket's SRAM (AS6C2016-55), for the
// harness: an asynchronous 128K x 16 RAM seen from a register clock.
//
// The servant's pins are registers on clk (clk_cpu here), so the model looks
// at them once a clock and keeps what it saw the clocks before:
//
//   read   the word at a is on dq once a has been on the pins three clocks
//          (93.75 ns: tAA 55 plus the FPGA's ~7 each way, with room), OE#
//          low for two (tOE) and WE# high; until then dq carries DEAD. So a
//          word taken too early is wrong, and the 68000's trace shows it.
//   write  the word is written when WE# goes high, if WE# was low for two
//          clocks or more (tWP 45 ns), OE# high, and the address, data, bytes
//          and the FPGA's drive held from WE#'s fall to a clock after its
//          rise (tAW, tDW, tDH, tWR); else a violation, and nothing written.
//   bus    the FPGA and the part never drive dq on the same clock or on two
//          clocks in a row (a turn-round: tOHZ, tOLZ); else a violation.
//
// It comes up with random data, as the part does, so a servant that did not
// clear it would show. Synthesis never sees this file.

`default_nettype none

module sram_model (
  input  wire        clk,
  input  wire [16:0] a,
  input  wire [15:0] dq_i,          // the FPGA's drive
  input  wire        dq_oe_i,
  input  wire        oe_n,
  input  wire        we_n,
  input  wire        ub_n,
  input  wire        lb_n,
  output wire [15:0] dq_o,          // the part's
  output wire        dq_oe_o,
  output int unsigned violations,
  output int unsigned writes
);
  reg [15:0] mem [0:131071];
  integer i;
  initial begin
    for (i = 0; i < 131072; i = i + 1) mem[i] = 16'($urandom);
    violations = 0;
    writes = 0;
  end

  // what was on the pins at the last two clocks
  reg [16:0] a1, a2;
  reg        oe1, we1, we2, drv1, fdrv1;
  initial begin oe1 = 1'b1; we1 = 1'b1; we2 = 1'b1; drv1 = 1'b0; fdrv1 = 1'b0; end

  assign dq_oe_o = !oe_n && we_n;
  assign dq_o = (a == a1 && a1 == a2 && !oe_n && !oe1 && we_n && we1 && we2) ? mem[a] : 16'hDEAD;

  // a write in progress: what was on the pins when WE# fell
  reg        wlow;
  reg [7:0]  wlen;
  reg [16:0] wa;
  reg [15:0] wd;
  reg [1:0]  wb;
  reg        wbad;
  initial begin wlow = 1'b0; wlen = 8'd0; wbad = 1'b0; end

  // the first few violations, with the clock they were seen on
  longint unsigned clocks = 0;
  always @(posedge clk) clocks <= clocks + 1;
  always @(posedge clk)
    if (violations != 0 && violations <= 4 && violations != $past(violations))
      $display("sram_model: violation %0d at clock %0d", violations, clocks);

  always @(posedge clk) begin
    a1 <= a; a2 <= a1; oe1 <= oe_n; we1 <= we_n; we2 <= we1;
    drv1 <= dq_oe_o; fdrv1 <= dq_oe_i;

    if (dq_oe_i && (dq_oe_o || drv1)) violations <= violations + 1;
    else if (dq_oe_o && fdrv1)        violations <= violations + 1;

    if (!we_n) begin
      if (!wlow) begin
        wlow <= 1'b1; wlen <= 8'd1;
        wa <= a; wd <= dq_i; wb <= {ub_n, lb_n};
        wbad <= !oe_n || !dq_oe_i;
      end else begin
        if (wlen != 8'hff) wlen <= wlen + 8'd1;
        if (a != wa || dq_i != wd || {ub_n, lb_n} != wb || !oe_n || !dq_oe_i) wbad <= 1'b1;
      end
    end else if (wlow) begin
      // WE# went high at the last clock; the pins now are the clock after
      wlow <= 1'b0;
      if (wbad || wlen < 8'd2 || a != wa || !dq_oe_i || dq_i != wd || {ub_n, lb_n} != wb)
        violations <= violations + 1;
      else begin
        if (!wb[1]) mem[wa][15:8] <= wd[15:8];
        if (!wb[0]) mem[wa][7:0]  <= wd[7:0];
        writes <= writes + 1;
      end
    end
  end
endmodule

`default_nettype wire
