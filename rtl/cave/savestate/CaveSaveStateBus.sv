// Cave-local save-state bus, adapted from the MiSTer Taito F2/IGS PGM model.
interface cave_ssbus_if();
    logic [63:0] data;
    logic [31:0] addr;
    logic [7:0]  select;
    logic        write;
    logic        read;
    logic        query;
    logic [63:0] data_out;
    logic        ack;

    function logic access(input [7:0] idx);
        return (select == idx) && !query && (read || write);
    endfunction

    task setup(
        input [7:0]  idx,
        input [31:0] count,
        input [1:0]  width
    );
        ack <= 1'b0;
        if ((select == idx) && query) begin
            data_out <= {idx, 22'd0, width, count};
            ack <= 1'b1;
        end
    endtask

    task read_response(input [7:0] idx, input [63:0] value);
        if (select == idx) begin
            data_out <= value;
            ack <= 1'b1;
        end
    endtask

    task write_ack(input [7:0] idx);
        if (select == idx)
            ack <= 1'b1;
    endtask

    modport master(
        output data, addr, select, write, read, query,
        input data_out, ack
    );

    modport slave(
        input data, addr, select, write, read, query,
        output data_out, ack,
        import access, setup, read_response, write_ack
    );
endinterface

module CaveSaveStateBusMux #(
    parameter integer COUNT = 4
) (
    input wire clk,
    cave_ssbus_if.master owners[COUNT],
    cave_ssbus_if.slave stream
);

logic [63:0] owner_data [0:COUNT-1];
logic        owner_ack  [0:COUNT-1];

genvar gi;
generate
    for (gi = 0; gi < COUNT; gi = gi + 1) begin : gen_owner
        always @* begin
            owner_ack[gi] = owners[gi].ack;
            owner_data[gi] = owners[gi].data_out;

            owners[gi].data = stream.data;
            owners[gi].addr = stream.addr;
            owners[gi].select = stream.select;
            owners[gi].write = stream.write;
            owners[gi].read = stream.read;
            owners[gi].query = stream.query;
        end
    end
endgenerate

integer i;
always_ff @(posedge clk) begin
    stream.data_out <= 64'd0;
    stream.ack <= 1'b0;

    for (i = 0; i < COUNT; i = i + 1) begin
        if (owner_ack[i]) begin
            stream.data_out <= owner_data[i];
            stream.ack <= 1'b1;
        end
    end
end

endmodule
