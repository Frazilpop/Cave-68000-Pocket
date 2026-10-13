// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — behavioural stand-ins for the arcadia
// memories (rtl/arcadia/), for Verilator: the same module names, ports and
// generics as the altsyncram and dcfifo wrappers, written as plain arrays.
// Synthesis never sees this file.
//
//   single_port_ram      one clock, byte masks, read data a clock later
//   true_dual_port_ram   two clocks and two widths: the narrower port's
//                        lower address is the wider word's low bits, as
//                        altsyncram lays it out; both ports may write
//   dual_clock_fifo      show-ahead, grey-coded pointers across the clocks
//                        with two-stage synchronisers, as dcfifo

module single_port_ram #(
  parameter ADDR_WIDTH  = 8,
  parameter DATA_WIDTH  = 8,
  parameter DEPTH       = 0,
  parameter MASK_ENABLE = "FALSE"
) (
  input                       clk,
  input                       rd,
  input                       wr,
  input  [ADDR_WIDTH-1:0]     addr,
  input  [DATA_WIDTH/8-1:0]   mask,
  input  [DATA_WIDTH-1:0]     din,
  output reg [DATA_WIDTH-1:0] dout
);
  localparam NUM_WORDS = (DEPTH > 0) ? DEPTH : (1 << ADDR_WIDTH);
  localparam BYTES = DATA_WIDTH / 8;
  reg [DATA_WIDTH-1:0] mem [0:NUM_WORDS-1];
  integer i;
  initial begin
    dout = {DATA_WIDTH{1'b0}};
    for (i = 0; i < NUM_WORDS; i = i + 1) mem[i] = {DATA_WIDTH{1'b0}};
  end
  always @(posedge clk) begin
    if (wr) begin
      for (i = 0; i < BYTES; i = i + 1)
        if (MASK_ENABLE != "TRUE" || mask[i])
          mem[addr][i*8 +: 8] <= din[i*8 +: 8];
    end
    if (rd) begin
      for (i = 0; i < BYTES; i = i + 1)
        dout[i*8 +: 8] <= (wr && (MASK_ENABLE != "TRUE" || mask[i])) ? din[i*8 +: 8] : mem[addr][i*8 +: 8];
    end
  end
endmodule

module true_dual_port_ram #(
  parameter ADDR_WIDTH_A = 8,
  parameter ADDR_WIDTH_B = 8,
  parameter DATA_WIDTH_A = 8,
  parameter DATA_WIDTH_B = 8,
  parameter DEPTH_A      = 0,
  parameter DEPTH_B      = 0,
  parameter MASK_ENABLE  = "FALSE"
) (
  input                           clk_a,
  input                           rd_a,
  input                           wr_a,
  input  [ADDR_WIDTH_A-1:0]       addr_a,
  input  [DATA_WIDTH_A/8-1:0]     mask_a,
  input  [DATA_WIDTH_A-1:0]       din_a,
  output reg [DATA_WIDTH_A-1:0]   dout_a,
  input                           clk_b,
  input                           rd_b,
  input                           wr_b,
  input  [ADDR_WIDTH_B-1:0]       addr_b,
  input  [DATA_WIDTH_B-1:0]       din_b,
  output reg [DATA_WIDTH_B-1:0]   dout_b
);
  localparam integer BYTES_A = DATA_WIDTH_A / 8;
  localparam integer BYTES_B = DATA_WIDTH_B / 8;
  localparam integer NBYTES_A = ((DEPTH_A > 0) ? DEPTH_A : (1 << ADDR_WIDTH_A)) * BYTES_A;
  localparam integer NBYTES_B = ((DEPTH_B > 0) ? DEPTH_B : (1 << ADDR_WIDTH_B)) * BYTES_B;
  localparam integer NBYTES = (NBYTES_A > NBYTES_B) ? NBYTES_A : NBYTES_B;
  reg [7:0] mem [0:NBYTES-1];
  integer i;
  initial begin
    dout_a = {DATA_WIDTH_A{1'b0}};
    dout_b = {DATA_WIDTH_B{1'b0}};
    for (i = 0; i < NBYTES; i = i + 1) mem[i] = 8'd0;
  end
  always @(posedge clk_a) begin
    if (wr_a)
      for (i = 0; i < BYTES_A; i = i + 1)
        if (MASK_ENABLE != "TRUE" || mask_a[i])
          mem[addr_a * BYTES_A + i] <= din_a[i*8 +: 8];
    if (rd_a)
      for (i = 0; i < BYTES_A; i = i + 1)
        dout_a[i*8 +: 8] <= (wr_a && (MASK_ENABLE != "TRUE" || mask_a[i])) ? din_a[i*8 +: 8] : mem[addr_a * BYTES_A + i];
  end
  always @(posedge clk_b) begin
    if (wr_b)
      for (i = 0; i < BYTES_B; i = i + 1)
        mem[addr_b * BYTES_B + i] <= din_b[i*8 +: 8];
    if (rd_b)
      for (i = 0; i < BYTES_B; i = i + 1)
        dout_b[i*8 +: 8] <= wr_b ? din_b[i*8 +: 8] : mem[addr_b * BYTES_B + i];
  end
endmodule

module dual_clock_fifo #(
  parameter DATA_WIDTH = 8,
  parameter DEPTH      = 16
) (
  input  [DATA_WIDTH-1:0] data,
  input                   rdclk,
  input                   rdreq,
  input                   wrclk,
  input                   wrreq,
  output [DATA_WIDTH-1:0] q,
  output                  rdempty,
  output                  wrfull
);
  localparam AW = $clog2(DEPTH);
  reg [DATA_WIDTH-1:0] mem [0:(1<<AW)-1];
  reg [AW:0] wptr = 0, rptr = 0;               // binary, one extra bit
  reg [AW:0] wgray = 0, rgray = 0;
  reg [AW:0] wgray_r1 = 0, wgray_r2 = 0;       // write pointer seen on rdclk
  reg [AW:0] rgray_w1 = 0, rgray_w2 = 0;       // read pointer seen on wrclk
  function [AW:0] gray(input [AW:0] b); gray = b ^ (b >> 1); endfunction
  wire [AW:0] wptr_n = wptr + 1'b1;
  wire [AW:0] rptr_n = rptr + 1'b1;
  wire full_w  = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
  wire empty_r = (rgray == wgray_r2);
  always @(posedge wrclk) begin
    rgray_w1 <= rgray; rgray_w2 <= rgray_w1;
    if (wrreq && !full_w) begin
      mem[wptr[AW-1:0]] <= data;
      wptr <= wptr_n; wgray <= gray(wptr_n);
    end
  end
  always @(posedge rdclk) begin
    wgray_r1 <= wgray; wgray_r2 <= wgray_r1;
    if (rdreq && !empty_r) begin
      rptr <= rptr_n; rgray <= gray(rptr_n);
    end
  end
  assign q       = mem[rptr[AW-1:0]];          // show-ahead
  assign rdempty = empty_r;
  assign wrfull  = full_w;
endmodule
