// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).

// Shared synchronous-read memory used by the retired Chisel memory wrappers.
//
// Cave 68000 for Analogue Pocket: RAMSTYLE passes Quartus's ramstyle through
// ("AUTO" lets it choose, as before), so the small ROM caches can sit in MLABs
// and leave the M10K blocks to the Pocket shell.
module CaveSyncReadMem #(
  parameter ADDR_WIDTH = 1,
  parameter DATA_WIDTH = 8,
  parameter DEPTH = (1 << ADDR_WIDTH),
  parameter RAMSTYLE = "AUTO"
) (
  input  [ADDR_WIDTH-1:0] read_addr,
  input                   read_en,
  input                   read_clk,
  output [DATA_WIDTH-1:0] read_data,
  input  [ADDR_WIDTH-1:0] write_addr,
  input                   write_en,
  input                   write_clk,
  input  [DATA_WIDTH-1:0] write_data
);
  reg                  read_en_d;
  reg [ADDR_WIDTH-1:0] read_addr_d;

  always @(posedge read_clk) begin
    read_en_d <= read_en;
    read_addr_d <= read_addr;
  end

  // the attribute takes a literal, hence the two branches
  generate
    if (RAMSTYLE == "MLAB") begin : mlab
      (* ramstyle = "MLAB, no_rw_check" *) reg [DATA_WIDTH-1:0] memory [0:DEPTH-1];
      always @(posedge write_clk) begin
        if (write_en)
          memory[write_addr] <= write_data;
      end
      assign read_data = read_en_d ? memory[read_addr_d] : {DATA_WIDTH{1'bx}};
    end
    else begin : auto
      reg [DATA_WIDTH-1:0] memory [0:DEPTH-1];
      always @(posedge write_clk) begin
        if (write_en)
          memory[write_addr] <= write_data;
      end
      assign read_data = read_en_d ? memory[read_addr_d] : {DATA_WIDTH{1'bx}};
    end
  endgenerate
endmodule
