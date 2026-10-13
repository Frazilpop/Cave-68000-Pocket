// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — kaneko_sdram with the banks interleaved
//
// kaneko_sdram takes the bank from the top of the word address, so a bank is
// 32 MB and every set but guwange and esprade lives in bank 0 whole: the
// program, the samples, three layers and the sprites, each read at its own
// place, share one open row, and nearly every transfer is a row miss
// (precharge, activate, then the read). Upstream had its sprites in DDR and
// never met this; here the sprite fetch runs beside the layers and the
// layers' line reads waited up to 77 clocks for it (sim/ddonpach, ddonpach's
// ranking screen), late enough to show as wrong 8-pixel pieces of layer 2.
//
// So the address is permuted on the way in: the two bits above the column
// (2 KB) become the bank, and the bank bits move into the row. Consecutive
// 2 KB pieces of every region land in the four banks in turn, each bank keeps
// its own open row (the controller tracks one per bank), and readers in
// different places mostly stop evicting each other. The permutation is a
// bijection applied to every port and the loader alike, so nothing outside
// can tell the image is laid out differently in the chip.

`default_nettype none

module cave_sdram #(
  parameter int unsigned COL_BITS = 10,
  parameter int unsigned NP       = 8,
  parameter logic [NP-1:0] URGENT = '1,
  parameter int unsigned T_RC     = 11,
  parameter int unsigned T_REFI   = 700,
  parameter int unsigned REF_DEFER = 256,
  parameter int unsigned INIT_NOP = 25000,
  parameter int unsigned ACK_HOLD = 1,
  parameter int unsigned AW       = 2 + 13 + COL_BITS   // derived: leave it
) (
  input  wire                 clk,
  input  wire                 rst_n,
  output wire                 ready,
  input  wire [1:0]           rd_lat_sel,

  output wire                 sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n,
  output wire [1:0]           sd_ba,
  output wire [12:0]          sd_a,
  output wire [1:0]           sd_dqm,
  output wire [15:0]          sd_dq_o,
  output wire                 sd_dq_oe,
  input  wire [15:0]          sd_dq_i,

  input  wire                 wr_req,
  input  wire [AW:1]          wr_addr,
  input  wire [15:0]          wr_din,
  input  wire [1:0]           wr_be,
  output wire                 wr_ack,

  input  wire [NP-1:0]        p_req,
  input  wire [NP*AW-1:0]     p_addr,      // port p at [AW*p +: AW]
  output wire [NP*64-1:0]     p_dout,      // port p at [64*p +: 64]
  output wire [NP-1:0]        p_ack
);

  // {bank, row, column} = {a[COL+2:COL+1], a[AW:COL+3], a[COL:1]}
  function automatic [AW:1] remap(input [AW:1] a);
    remap = {a[COL_BITS+2:COL_BITS+1], a[AW:COL_BITS+3], a[COL_BITS:1]};
  endfunction

  logic [NP-1:0][AW:1] pa;
  logic [NP-1:0][63:0] pd;
  genvar i;
  generate
    for (i = 0; i < NP; i = i + 1) begin : port
      assign pa[i] = remap(p_addr[AW*i +: AW]);
      assign p_dout[64*i +: 64] = pd[i];
    end
  endgenerate

  kaneko_sdram #(
    .COL_BITS (COL_BITS), .NP (NP), .URGENT (URGENT),
    .T_RC (T_RC), .T_REFI (T_REFI), .REF_DEFER (REF_DEFER), .INIT_NOP (INIT_NOP), .ACK_HOLD (ACK_HOLD)
  ) sdram (
    .clk (clk), .rst_n (rst_n), .ready (ready), .rd_lat_sel (rd_lat_sel),
    .sd_cke (sd_cke), .sd_cs_n (sd_cs_n), .sd_ras_n (sd_ras_n), .sd_cas_n (sd_cas_n),
    .sd_we_n (sd_we_n), .sd_ba (sd_ba), .sd_a (sd_a), .sd_dqm (sd_dqm),
    .sd_dq_o (sd_dq_o), .sd_dq_oe (sd_dq_oe), .sd_dq_i (sd_dq_i),
    .wr_req (wr_req), .wr_addr (remap(wr_addr)), .wr_din (wr_din), .wr_be (wr_be), .wr_ack (wr_ack),
    .p_req (p_req), .p_we ('0), .p_addr (pa), .p_din ('0), .p_be ('1),
    .p_dout (pd), .p_ack (p_ack), .dbg_req (), .dbg_grant ()
  );

endmodule

`default_nettype wire
