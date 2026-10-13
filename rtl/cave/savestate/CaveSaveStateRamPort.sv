// Multiplexes a synchronous RAM port only while its normal owner is quiesced.
module CaveSaveStateRamPort #(
    parameter integer WIDTH = 16,
    parameter integer ADDR_WIDTH = 10,
    parameter integer WE_WIDTH = (WIDTH + 7) / 8,
    parameter [7:0] SS_IDX = 8'd0,
    parameter [1:0] STREAM_WIDTH = 2'd1
) (
    input wire                      clk,
    input wire                      reset,
    input wire                      state_enable,
    input wire                      restore_enable,

    input wire                      normal_rd,
    input wire                      normal_wr,
    input wire [WE_WIDTH-1:0]       normal_mask,
    input wire [ADDR_WIDTH-1:0]     normal_addr,
    input wire [WIDTH-1:0]          normal_data,

    output wire                     ram_rd,
    output wire                     ram_wr,
    output wire [WE_WIDTH-1:0]      ram_mask,
    output wire [ADDR_WIDTH-1:0]    ram_addr,
    output wire [WIDTH-1:0]         ram_data,
    input wire [WIDTH-1:0]          ram_q,

    output reg                      blocked_access,
    cave_ssbus_if.slave             ssbus
);

localparam [31:0] WORD_COUNT = 32'd1 << ADDR_WIDTH;

wire selected = ssbus.select == SS_IDX;
wire requested = selected && !ssbus.query && (ssbus.read || ssbus.write);
wire access = state_enable && requested;

assign ram_addr = access ? ssbus.addr[ADDR_WIDTH-1:0] : normal_addr;
assign ram_data = access ? ssbus.data[WIDTH-1:0] : normal_data;
assign ram_rd = access ? ssbus.read : (state_enable ? 1'b0 : normal_rd);
assign ram_wr = access ? (ssbus.write && restore_enable) :
                (state_enable ? 1'b0 : normal_wr);
assign ram_mask = access ? {WE_WIDTH{ssbus.write && restore_enable}} :
                  normal_mask;

reg read_pending = 1'b0;

always_ff @(posedge clk) begin
    if (reset) begin
        ssbus.data_out <= 64'd0;
        ssbus.ack <= 1'b0;
        blocked_access <= 1'b0;
        read_pending <= 1'b0;
    end else begin
        ssbus.ack <= 1'b0;
        blocked_access <= 1'b0;

        if (!state_enable)
            read_pending <= 1'b0;

        if (read_pending) begin
            ssbus.data_out <= {{(64-WIDTH){1'b0}}, ram_q};
            ssbus.ack <= 1'b1;
            read_pending <= 1'b0;
        end else if (selected && ssbus.query) begin
            ssbus.data_out <= {SS_IDX, 22'd0, STREAM_WIDTH, WORD_COUNT};
            ssbus.ack <= 1'b1;
            read_pending <= 1'b0;
        end else if (requested && !state_enable) begin
            ssbus.data_out <= 64'd0;
            ssbus.ack <= 1'b1;
            blocked_access <= 1'b1;
            read_pending <= 1'b0;
        end else if (access) begin
            if (ssbus.write)
                ssbus.ack <= 1'b1;
            else if (ssbus.read)
                read_pending <= 1'b1;
        end
    end
end

endmodule
