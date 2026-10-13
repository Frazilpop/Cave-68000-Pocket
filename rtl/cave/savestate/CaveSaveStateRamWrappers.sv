// Cave-local wrappers that add save-state ownership to existing RAM primitives.
module CaveSaveStateSinglePortRam #(
    parameter integer ADDR_WIDTH = 8,
    parameter integer DATA_WIDTH = 8,
    parameter integer DEPTH = 0,
    parameter integer MASK_ENABLE = 0,
    parameter [7:0] SS_IDX = 8'd0,
    parameter [1:0] STREAM_WIDTH = DATA_WIDTH == 8 ? 2'd0 :
                                         DATA_WIDTH == 16 ? 2'd1 :
                                         DATA_WIDTH == 32 ? 2'd2 : 2'd3
) (
    input wire clock,
    input wire reset,
    input wire state_enable,
    input wire restore_enable,
    input wire rd,
    input wire wr,
    input wire [ADDR_WIDTH-1:0] addr,
    input wire [(DATA_WIDTH/8)-1:0] mask,
    input wire [DATA_WIDTH-1:0] din,
    output wire [DATA_WIDTH-1:0] dout,
    output wire blocked_access,
    cave_ssbus_if.slave ssbus
);

wire ram_rd;
wire ram_wr;
wire [(DATA_WIDTH/8)-1:0] ram_mask;
wire [ADDR_WIDTH-1:0] ram_addr;
wire [DATA_WIDTH-1:0] ram_din;

CaveSaveStateRamPort #(
    .WIDTH        (DATA_WIDTH),
    .ADDR_WIDTH   (ADDR_WIDTH),
    .WE_WIDTH     (DATA_WIDTH/8),
    .SS_IDX       (SS_IDX),
    .STREAM_WIDTH (STREAM_WIDTH)
) saveStatePort (
    .clk            (clock),
    .reset          (reset),
    .state_enable   (state_enable),
    .restore_enable (restore_enable),
    .normal_rd      (rd),
    .normal_wr      (wr),
    .normal_mask    (mask),
    .normal_addr    (addr),
    .normal_data    (din),
    .ram_rd         (ram_rd),
    .ram_wr         (ram_wr),
    .ram_mask       (ram_mask),
    .ram_addr       (ram_addr),
    .ram_data       (ram_din),
    .ram_q          (dout),
    .blocked_access (blocked_access),
    .ssbus          (ssbus)
);

CaveSinglePortRam #(
    .ADDR_WIDTH  (ADDR_WIDTH),
    .DATA_WIDTH  (DATA_WIDTH),
    .DEPTH       (DEPTH),
    .MASK_ENABLE (MASK_ENABLE)
) ram (
    .clock (clock),
    .rd    (ram_rd),
    .wr    (ram_wr),
    .addr  (ram_addr),
    .mask  (ram_mask),
    .din   (ram_din),
    .dout  (dout)
);

endmodule

module CaveSaveStateTrueDualPortRam #(
    parameter integer ADDR_WIDTH_A = 8,
    parameter integer ADDR_WIDTH_B = 8,
    parameter integer DATA_WIDTH_A = 8,
    parameter integer DATA_WIDTH_B = 8,
    parameter integer DEPTH_A = 0,
    parameter integer DEPTH_B = 0,
    parameter integer MASK_ENABLE = 0,
    parameter [7:0] SS_IDX = 8'd0,
    parameter [1:0] STREAM_WIDTH = DATA_WIDTH_A == 8 ? 2'd0 :
                                         DATA_WIDTH_A == 16 ? 2'd1 :
                                         DATA_WIDTH_A == 32 ? 2'd2 : 2'd3
) (
    input wire clock_a,
    input wire reset,
    input wire state_enable,
    input wire restore_enable,
    input wire rd_a,
    input wire wr_a,
    input wire [ADDR_WIDTH_A-1:0] addr_a,
    input wire [(DATA_WIDTH_A/8)-1:0] mask_a,
    input wire [DATA_WIDTH_A-1:0] din_a,
    output wire [DATA_WIDTH_A-1:0] dout_a,
    input wire clock_b,
    input wire rd_b,
    input wire [ADDR_WIDTH_B-1:0] addr_b,
    output wire [DATA_WIDTH_B-1:0] dout_b,
    output wire blocked_access,
    cave_ssbus_if.slave ssbus
);

wire ram_rd_a;
wire ram_wr_a;
wire [(DATA_WIDTH_A/8)-1:0] ram_mask_a;
wire [ADDR_WIDTH_A-1:0] ram_addr_a;
wire [DATA_WIDTH_A-1:0] ram_din_a;

CaveSaveStateRamPort #(
    .WIDTH        (DATA_WIDTH_A),
    .ADDR_WIDTH   (ADDR_WIDTH_A),
    .WE_WIDTH     (DATA_WIDTH_A/8),
    .SS_IDX       (SS_IDX),
    .STREAM_WIDTH (STREAM_WIDTH)
) saveStatePort (
    .clk            (clock_a),
    .reset          (reset),
    .state_enable   (state_enable),
    .restore_enable (restore_enable),
    .normal_rd      (rd_a),
    .normal_wr      (wr_a),
    .normal_mask    (mask_a),
    .normal_addr    (addr_a),
    .normal_data    (din_a),
    .ram_rd         (ram_rd_a),
    .ram_wr         (ram_wr_a),
    .ram_mask       (ram_mask_a),
    .ram_addr       (ram_addr_a),
    .ram_data       (ram_din_a),
    .ram_q          (dout_a),
    .blocked_access (blocked_access),
    .ssbus          (ssbus)
);

CaveTrueDualPortRam #(
    .ADDR_WIDTH_A (ADDR_WIDTH_A),
    .ADDR_WIDTH_B (ADDR_WIDTH_B),
    .DATA_WIDTH_A (DATA_WIDTH_A),
    .DATA_WIDTH_B (DATA_WIDTH_B),
    .DEPTH_A      (DEPTH_A),
    .DEPTH_B      (DEPTH_B),
    .MASK_ENABLE  (MASK_ENABLE)
) ram (
    .clock_a (clock_a),
    .rd_a    (ram_rd_a),
    .wr_a    (ram_wr_a),
    .addr_a  (ram_addr_a),
    .mask_a  (ram_mask_a),
    .din_a   (ram_din_a),
    .dout_a  (dout_a),
    .clock_b (clock_b),
    .rd_b    (rd_b),
    .addr_b  (addr_b),
    .dout_b  (dout_b)
);

endmodule
