// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the sprite processor's tile bursts on two
// ports of the SDRAM controller
//
// Upstream fetches a sprite tile from DDR as one burst of 16 (4 bpp) or 32
// (8 bpp) 64-bit words: taken where rd meets wait_n, `burstLength` words back
// one per `valid`, `burstDone` with the last. kaneko_sdram serves 64-bit
// lines, one outstanding request per port, so a tile is 16 or 32 line reads.
//
// One port at a time would leave the controller idle for most of each line:
// a request waits for its arbitration, its four READs and the capture
// pipeline before the next can be raised (about twelve clocks for four
// words). Two ports, alternating, keep a second line in the controller while
// the first comes back, and the controller overlaps them (its tagged
// capture). Line i goes to port i & 1; each port holds its line until it is
// its turn, so the words leave in order whichever port the controller served
// first.
//
// Both ports are slack ports at the controller (not URGENT): the layers and
// the 68000 have a line's deadline, the sprites a frame's.

`default_nettype none

module cave_spr_port #(
  parameter int unsigned AW = 25,
  parameter int unsigned PORTS = 2          // 1: every line on port 0
) (
  input  wire              clk,
  input  wire              rst,

  // the sprite processor's side, upstream's DDR protocol
  input  wire              rd,
  input  wire [31:0]       addr,            // byte address in the image, line aligned
  input  wire [7:0]        burst_len,       // 64-bit words: 16 or 32
  output wire              wait_n,
  output reg               valid,
  output reg  [63:0]       dout,
  output reg               burst_done,

  // two controller ports
  output reg  [1:0]        req,
  output reg  [2*AW-1:0]   req_addr,        // port p at [AW*p +: AW], word address
  input  wire [1:0]        ack,
  input  wire [127:0]      line             // port p at [64*p +: 64]
);

  reg        busy;
  reg [AW:1] base;                          // word address of line 0
  reg [7:0]  len;
  reg [7:0]  issued;                        // lines requested
  reg [7:0]  sent;                          // lines delivered
  reg [1:0]  full;                          // port p holds a line not yet delivered
  reg [63:0] held [2];

  assign wait_n = !busy;

  wire       next_p   = (PORTS == 1) ? 1'b0 : issued[0];
  // a port takes its next line once its last one has gone out
  wire       can_issue = busy && (issued != len) && !req[next_p] && !full[next_p];
  wire       out_p    = (PORTS == 1) ? 1'b0 : sent[0];
  wire       can_send = busy && full[out_p];

  integer p;
  always @(posedge clk) begin
    valid      <= 1'b0;
    burst_done <= 1'b0;
    if (rst) begin
      busy <= 1'b0;
      req  <= 2'b00;
      full <= 2'b00;
    end else begin
      if (!busy && rd) begin
        busy   <= 1'b1;
        base   <= {addr[AW:3], 2'b00};
        len    <= burst_len;
        issued <= 8'd0;
        sent   <= 8'd0;
      end

      for (p = 0; p < 2; p = p + 1)
        if (req[p] && ack[p]) begin
          req[p]  <= 1'b0;
          full[p] <= 1'b1;
          held[p] <= line[64*p +: 64];
        end

      if (can_issue) begin
        req[next_p] <= 1'b1;
        req_addr[AW*next_p +: AW] <= base + {issued, 2'b00};
        issued <= issued + 8'd1;
      end

      if (can_send) begin
        valid       <= 1'b1;
        dout        <= held[out_p];
        full[out_p] <= 1'b0;
        sent        <= sent + 8'd1;
        if (sent + 8'd1 == len) begin
          burst_done <= 1'b1;
          busy       <= 1'b0;
        end
      end
    end
  end

endmodule

`default_nettype wire
