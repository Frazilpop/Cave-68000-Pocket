// Streams each 65-128 bit RAM record as two 64-bit words while reusing the
// quiesced native RAM port. A restore commits only after both halves arrive.
module CaveSaveStateWideRamPort #(
    parameter integer WIDTH = 121,
    parameter integer ADDR_WIDTH = 3,
    parameter [7:0] SS_IDX = 8'd30
) (
    input wire                    clk,
    input wire                    reset,
    input wire                    state_enable,
    input wire                    restore_enable,

    input wire                    normal_rd,
    input wire                    normal_wr,
    input wire [ADDR_WIDTH-1:0]   normal_addr,
    input wire [WIDTH-1:0]        normal_data,

    output wire                   ram_rd,
    output wire                   ram_wr,
    output wire [ADDR_WIDTH-1:0]  ram_addr,
    output wire [WIDTH-1:0]       ram_data,
    input wire [WIDTH-1:0]        ram_q,

    output reg                    blocked_access,
    cave_ssbus_if.slave           ssbus
);

localparam [31:0] RECORD_COUNT = 32'd1 << ADDR_WIDTH;
localparam [31:0] WORD_COUNT = RECORD_COUNT << 1;

wire selected = ssbus.select == SS_IDX;
wire requested = selected && !ssbus.query && (ssbus.read || ssbus.write);
wire access = state_enable && requested && ssbus.addr < WORD_COUNT;
wire [ADDR_WIDTH-1:0] access_addr = ssbus.addr[ADDR_WIDTH:1];
wire access_high = ssbus.addr[0];

reg [63:0] restore_low = 64'd0;
reg [ADDR_WIDTH-1:0] restore_low_addr = {ADDR_WIDTH{1'b0}};
reg restore_low_valid = 1'b0;
reg read_pending = 1'b0;
reg read_pending_high = 1'b0;

wire restore_record =
    access && ssbus.write && access_high && restore_enable &&
    restore_low_valid && restore_low_addr == access_addr;

assign ram_rd = access ? ssbus.read : (state_enable ? 1'b0 : normal_rd);
assign ram_wr = access ? restore_record : (state_enable ? 1'b0 : normal_wr);
assign ram_addr = access ? access_addr : normal_addr;
assign ram_data = access
    ? {ssbus.data[WIDTH-65:0], restore_low}
    : normal_data;

always @(posedge clk) begin
    if (reset) begin
        restore_low <= 64'd0;
        restore_low_addr <= {ADDR_WIDTH{1'b0}};
        restore_low_valid <= 1'b0;
        read_pending <= 1'b0;
        read_pending_high <= 1'b0;
        blocked_access <= 1'b0;
        ssbus.data_out <= 64'd0;
        ssbus.ack <= 1'b0;
    end else begin
        ssbus.ack <= 1'b0;
        blocked_access <= 1'b0;

        if (!state_enable) begin
            read_pending <= 1'b0;
            restore_low_valid <= 1'b0;
        end

        if (read_pending) begin
            ssbus.data_out <= read_pending_high
                ? {{(128-WIDTH){1'b0}}, ram_q[WIDTH-1:64]}
                : ram_q[63:0];
            ssbus.ack <= 1'b1;
            read_pending <= 1'b0;
        end else if (selected && ssbus.query) begin
            ssbus.data_out <= {SS_IDX, 22'd0, 2'd3, WORD_COUNT};
            ssbus.ack <= 1'b1;
        end else if (requested && !state_enable) begin
            ssbus.data_out <= 64'd0;
            ssbus.ack <= 1'b1;
            blocked_access <= 1'b1;
        end else if (requested && ssbus.addr >= WORD_COUNT) begin
            ssbus.data_out <= 64'd0;
            ssbus.ack <= 1'b1;
        end else if (access && ssbus.read) begin
            read_pending <= 1'b1;
            read_pending_high <= access_high;
        end else if (access && ssbus.write) begin
            if (!access_high && restore_enable) begin
                restore_low <= ssbus.data;
                restore_low_addr <= access_addr;
                restore_low_valid <= 1'b1;
            end
            if (access_high)
                restore_low_valid <= 1'b0;
            ssbus.ack <= 1'b1;
        end
    end
end

endmodule
