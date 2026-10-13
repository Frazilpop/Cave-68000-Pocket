// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — behavioural model of one AS1C8M16PL PSRAM
// (die 0), for the harness
//
// Enough of the part for pocket_psram_rows: asynchronous writes (the address
// taken while ADV# is low, the data when WE# rises), the CRE-controlled BCR
// write, and synchronous bursts once BCR[15] is 0: the address taken at the
// rising clock where ADV# and CE# are low, then a word a clock from the
// LAT_W-th rising after it (writes, with UB#/LB#) or driven after the
// LAT_R-th (reads), until CE# goes high. The latencies are parameters
// because the servant measures them at boot; the harness can move them to
// prove that it does.
//
// Clocked on the servant's own clock rather than cram_clk: every pin is a
// register on that clock, so a rising edge of cram_clk is seen here one clock
// after the servant launched it, with the other pins as they were at that
// rise, and the data driven here reaches the servant's capture register on
// the clock after, two clocks after the launch, as on the board.
//
// Violations it reports: a burst with the part still asynchronous, CE# held
// low past tCEM (4 us, at 96 MHz), DQ driven by both sides.

`default_nettype none

module psram_model #(
  parameter int unsigned LAT_W = 4,
  parameter int unsigned LAT_R = 4,
  parameter int unsigned DQ_DELAY = 0,         // clocks more before read data shows: a long round trip
  parameter int unsigned T_CEM = 384           // clocks of the servant's clock
) (
  input  wire          clk,
  input  wire [21:16]  a,
  input  wire [15:0]   dq_i,
  input  wire          dq_oe_i,
  output wire [15:0]   dq_o,
  output wire          dq_oe_o,
  input  wire          cram_clk,
  input  wire          adv_n,
  input  wire          cre,
  input  wire          ce0_n,
  input  wire          oe_n,
  input  wire          we_n,
  input  wire          ub_n,
  input  wire          lb_n,

  output int unsigned  violations,
  output reg  [15:0]   bcr
);

  reg [15:0] mem [0:(1 << 22) - 1] /*verilator public_flat_rw*/;

  reg        clk_q, we_q;
  reg [21:0] a_async;
  reg [21:0] b_addr;
  reg        b_on, b_we;
  reg [5:0]  b_k;
  int        ce_low;

  reg [15:0] dq_m, dq_d;
  reg        oe_m, oe_d;
  assign dq_o    = DQ_DELAY ? dq_d : dq_m;
  assign dq_oe_o = DQ_DELAY ? oe_d : oe_m;
  always @(posedge clk) begin
    dq_d <= dq_m;
    oe_d <= oe_m;
  end

  initial begin
    bcr = 16'h9D1F; violations = 0; clk_q = 0; we_q = 1; b_on = 0;
    oe_m = 0; dq_m = 0; oe_d = 0; dq_d = 0; ce_low = 0;
  end

  wire rise = cram_clk && !clk_q;
  wire sync = !bcr[15];

  always @(posedge clk) begin
    clk_q <= cram_clk;
    we_q  <= we_n;

    if (!ce0_n) begin
      ce_low <= ce_low + 1;
      if (ce_low == int'(T_CEM)) begin
        violations <= violations + 1;
        $display("PSRAM: CE# low past tCEM");
      end
    end else ce_low <= 0;

    if (dq_oe_o && dq_oe_i) begin
      violations <= violations + 1;
      $display("PSRAM: both sides drive DQ");
    end

    if (ce0_n) begin
      b_on <= 1'b0;
      oe_m <= 1'b0;
    end

    // asynchronous: the address while ADV# is low, the data at WE#'s rise
    if (!ce0_n && !adv_n && !rise) a_async <= {a, dq_i};
    if (we_n && !we_q && !b_on) begin
      if (cre) begin
        if (a_async[19:18] == 2'b10) bcr <= a_async[15:0];
      end else begin
        if (!ub_n) mem[a_async][15:8] <= dq_i[15:8];
        if (!lb_n) mem[a_async][7:0]  <= dq_i[7:0];
      end
    end

    // synchronous bursts
    if (rise && !ce0_n) begin
      if (!adv_n) begin
        if (!sync) begin
          violations <= violations + 1;
          $display("PSRAM: a clocked access with the part asynchronous");
        end
        b_on   <= 1'b1;
        b_we   <= !we_n;
        b_addr <= {a, dq_i};
        b_k    <= 6'd1;
      end else if (b_on) begin
        b_k <= b_k + 6'd1;
        if (b_we && b_k >= 6'(LAT_W)) begin
          if (!ub_n) mem[b_addr + 22'(b_k - 6'(LAT_W))][15:8] <= dq_i[15:8];
          if (!lb_n) mem[b_addr + 22'(b_k - 6'(LAT_W))][7:0]  <= dq_i[7:0];
        end
        if (!b_we && b_k >= 6'(LAT_R)) begin
          dq_m <= mem[b_addr + 22'(b_k - 6'(LAT_R))];
          oe_m <= !oe_n;
        end
      end
    end
  end

endmodule

`default_nettype wire
