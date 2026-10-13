module CaveCpuResetBridge(
  input  clock,
  input  cpu_reset,
  input  mem_ready_async,
  input  recovery_reset,
  output cpu_domain_reset
);
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg memReadySync0 = 1'b0;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg memReadySync1 = 1'b0;

  always @(posedge clock) begin
    if (cpu_reset) begin
      memReadySync0 <= 1'b0;
      memReadySync1 <= 1'b0;
    end
    else begin
      memReadySync0 <= mem_ready_async;
      memReadySync1 <= memReadySync0;
    end
  end

  assign cpu_domain_reset = cpu_reset | recovery_reset | ~memReadySync1;
endmodule
