// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).

module CaveTileRomClockCrossing(
  input         clock,
  input         reset,
  input         io_targetClock,
  input         io_block_new_requests,
  input         io_in_rd,
  input  [31:0] io_in_addr,
  output [63:0] io_in_dout,
  output        io_out_rd,
  output [31:0] io_out_addr,
  input  [63:0] io_out_dout,
  input         io_out_wait_n,
  input         io_out_valid,
  output        io_idle
);
  wire addr_fifo_enq_ready_unused;
  wire data_fifo_enq_ready_unused;
  wire addr_fifo_deq_valid;
  wire data_fifo_deq_valid;

  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg blockTarget0;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg blockTarget1;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg blockSystem0;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg blockSystem1;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg dataValidSystem0;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg dataValidSystem1;
  reg [4:0] outstandingReg;
  reg [2:0] idleCountReg;

  wire acceptedRequest = addr_fifo_deq_valid & io_out_wait_n;
  wire acceptedResponse = io_out_valid;
  wire rawIdle =
    blockSystem1 &
    ~addr_fifo_deq_valid &
    ~dataValidSystem1 &
    (outstandingReg == 5'd0);

  always @(posedge io_targetClock) begin
    if (reset) begin
      blockTarget0 <= 1'b0;
      blockTarget1 <= 1'b0;
    end
    else begin
      blockTarget0 <= io_block_new_requests;
      blockTarget1 <= blockTarget0;
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      blockSystem0 <= 1'b0;
      blockSystem1 <= 1'b0;
      dataValidSystem0 <= 1'b0;
      dataValidSystem1 <= 1'b0;
      outstandingReg <= 5'd0;
      idleCountReg <= 3'd0;
    end
    else begin
      blockSystem0 <= blockTarget1;
      blockSystem1 <= blockSystem0;
      dataValidSystem0 <= data_fifo_deq_valid;
      dataValidSystem1 <= dataValidSystem0;

      case ({acceptedRequest, acceptedResponse})
        2'b10: outstandingReg <= outstandingReg + 5'd1;
        2'b01: begin
          if (outstandingReg != 5'd0)
            outstandingReg <= outstandingReg - 5'd1;
        end
        default: outstandingReg <= outstandingReg;
      endcase

      if (!rawIdle)
        idleCountReg <= 3'd0;
      else if (!(&idleCountReg))
        idleCountReg <= idleCountReg + 3'd1;
    end
  end

  CaveDualClockFIFO #(
    .DATA_WIDTH (32),
    .DEPTH      (4)
  ) addr_fifo (
    .write_clock (io_targetClock),
    .read_clock  (clock),
    .deq_ready   (io_out_wait_n),
    .deq_valid   (addr_fifo_deq_valid),
    .deq_bits    (io_out_addr),
    .enq_ready   (addr_fifo_enq_ready_unused),
    .enq_valid   (io_in_rd & ~blockTarget1),
    .enq_bits    (io_in_addr)
  );

  CaveDualClockFIFO #(
    .DATA_WIDTH (64),
    .DEPTH      (4)
  ) data_fifo (
    .write_clock (clock),
    .read_clock  (io_targetClock),
    .deq_ready   (1'b1),
    .deq_valid   (data_fifo_deq_valid),
    .deq_bits    (io_in_dout),
    .enq_ready   (data_fifo_enq_ready_unused),
    .enq_valid   (io_out_valid),
    .enq_bits    (io_out_dout)
  );

  assign io_out_rd = addr_fifo_deq_valid;
  assign io_idle = &idleCountReg;
endmodule
