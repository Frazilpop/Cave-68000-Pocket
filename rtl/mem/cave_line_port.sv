// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — one ROM cache's line read on a port of the
// SDRAM controller
//
// Upstream's caches (CaveReadCache) fill a 64-bit line as four 16-bit words:
// `rd` is held in FILL, the read is taken where rd meets wait_n, and the words
// come back one per `valid`, word k from byte addr + 2k. kaneko_sdram reads a
// whole line per request and hands it over at once with a one-cycle `ack`.
// This sits between the two: it takes the read, raises the request, and on
// the ack plays the line back as four valids on consecutive clocks.
//
// The controller latches a request on its RISING edge (kaneko_sdram, REQUEST
// CONTRACT), so `req` drops on the ack and stays low for the four clocks of
// playback before the next read can raise it again. Word 0 goes out on the
// ack's own edge: the layers read their tiles as a fixed-latency stream
// (about 50 clocks of SDRAM latency is all they allow), so every clock counts.

`default_nettype none

module cave_line_port #(
  parameter int unsigned AW = 25        // word address [AW:1]
) (
  input  wire          clk,
  input  wire          rst,

  // the cache's side, upstream's protocol
  input  wire          rd,
  input  wire [31:0]   addr,            // byte address in the image, line aligned
  output wire          wait_n,
  output reg           valid,
  output reg  [15:0]   dout,

  // the controller's side
  output reg           req,
  output reg  [AW:1]   req_addr,
  input  wire          ack,
  input  wire [63:0]   line
);

  reg        busy;                      // a read taken, not yet played back
  reg [2:0]  play;                      // words left to play back
  reg [63:0] buf_line;

  assign wait_n = !busy;

  always @(posedge clk) begin
    valid <= 1'b0;
    if (rst) begin
      busy <= 1'b0;
      req  <= 1'b0;
      play <= 3'd0;
    end else begin
      if (!busy && rd) begin
        busy     <= 1'b1;
        req      <= 1'b1;
        req_addr <= {addr[AW:3], 2'b00};
      end
      if (req && ack) begin
        req      <= 1'b0;
        valid    <= 1'b1;
        dout     <= line[15:0];
        buf_line <= {16'd0, line[63:16]};
        play     <= 3'd3;
      end
      if (play != 3'd0) begin
        valid    <= 1'b1;
        dout     <= buf_line[15:0];
        buf_line <= {16'd0, buf_line[63:16]};
        play     <= play - 3'd1;
        if (play == 3'd1) busy <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
