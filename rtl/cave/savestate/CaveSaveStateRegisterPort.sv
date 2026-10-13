// Streams a packed set of small registers without allocating a shadow memory.
module CaveSaveStateRegisterPort #(
    parameter integer WIDTH = 64,
    parameter integer COUNT = 1,
    parameter [7:0] SS_IDX = 8'd0,
    parameter [1:0] STREAM_WIDTH = 2'd3
) (
    input wire                       clk,
    input wire                       reset,
    input wire                       state_enable,
    input wire                       restore_enable,
    input wire [(WIDTH*COUNT)-1:0]   capture_data,
    output reg                       restore_wr,
    output reg [31:0]                restore_addr,
    output reg [WIDTH-1:0]           restore_data,
    output reg                       blocked_access,
    cave_ssbus_if.slave              ssbus
);

wire selected = ssbus.select == SS_IDX;
wire requested = selected && !ssbus.query && (ssbus.read || ssbus.write);
wire address_valid = ssbus.addr < COUNT;

reg [63:0] read_data;
always @* begin
    read_data = 64'd0;
    if (address_valid)
        read_data[WIDTH-1:0] =
            capture_data[(ssbus.addr * WIDTH) +: WIDTH];
end

always_ff @(posedge clk) begin
    if (reset) begin
        ssbus.data_out <= 64'd0;
        ssbus.ack <= 1'b0;
        restore_wr <= 1'b0;
        restore_addr <= 32'd0;
        restore_data <= {WIDTH{1'b0}};
        blocked_access <= 1'b0;
    end else begin
        ssbus.ack <= 1'b0;
        restore_wr <= 1'b0;
        blocked_access <= 1'b0;

        if (selected && ssbus.query) begin
            ssbus.data_out <= {SS_IDX, 22'd0, STREAM_WIDTH, 32'(COUNT)};
            ssbus.ack <= 1'b1;
        end else if (requested && !state_enable) begin
            ssbus.data_out <= 64'd0;
            ssbus.ack <= 1'b1;
            blocked_access <= 1'b1;
        end else if (requested) begin
            if (ssbus.read) begin
                ssbus.data_out <= read_data;
            end else if (ssbus.write && restore_enable && address_valid) begin
                restore_wr <= 1'b1;
                restore_addr <= ssbus.addr;
                restore_data <= ssbus.data[WIDTH-1:0];
            end
            ssbus.ack <= 1'b1;
        end
    end
end

endmodule
