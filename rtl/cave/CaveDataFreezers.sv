// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).

module CaveProgramRomReadFreezer(
  input         clock,
  input         reset,
  input         io_targetClock,
  input         io_targetReset,
  input         io_in_rd,
  input  [21:0] io_in_addr,
  output [15:0] io_in_dout,
  output        io_in_valid,
  output        io_out_rd,
  output [21:0] io_out_addr,
  input  [15:0] io_out_dout,
  input         io_out_wait_n,
  input         io_out_valid
);

  // The 68000's program ROM reads, carried from its clock (io_targetClock,
  // 32 MHz) to the memory side's (clock, 96 MHz) and back. The two are
  // zero-phase 3:1 outputs of one PLL, so every rising edge of the CPU's
  // clock is a rising edge of the system's, and a register in either domain
  // may read a register of the other across one system period: a path
  // launched on one rising edge and caught on the next. Nothing here is
  // clocked on a falling edge. The first form of this bridge staged the
  // crossing on the 96 MHz falling edge in both directions, which left each
  // half of it half a period, 5.2 ns, and that half-period held the worst
  // path of every compile: the cache's data into the published word, and
  // the published toggle through Main's DTACK logic.
  //
  // The CPU holds rd and addr for the whole bus cycle, so the system side
  // reads them as they are and turns the level into one request with
  // request_seen_system, cleared when rd drops. The response is published
  // in two ways that reach the CPU on the same edge the half-period staging
  // did: on the period the memory answers (response_arrived), the CPU edge
  // that follows it takes the data straight off io_out_dout; on the edge
  // after, the data and a toggle are registered here and a later CPU edge
  // reads those. The CPU side marks what it has taken by setting its copy of
  // the toggle to the value the toggle is about to have (the published one,
  // inverted when it took the early form), and the next request waits for
  // that copy to equal the toggle, as before.

  localparam STATE_IDLE = 1'b0;
  localparam STATE_WAIT = 1'b1;

  reg        response_toggle_cpu_seen = 1'b0;

  reg        request_seen_system = 1'b0;
  reg        request_active_system = 1'b0;
  reg [21:0] request_addr_system = 22'd0;
  reg        state_reg = STATE_IDLE;
  reg [15:0] response_data_published = 16'd0;
  reg        response_toggle_published = 1'b0;

  wire incoming_request =
    io_in_rd &&
    !request_seen_system &&
    !request_active_system &&
    state_reg == STATE_IDLE &&
    response_toggle_published == response_toggle_cpu_seen;
  wire issue_read =
    request_active_system || incoming_request;
  wire accepted_read =
    issue_read && io_out_wait_n;
  wire response_arrived =
    state_reg == STATE_WAIT && io_out_valid;
  wire response_pending_cpu =
    response_toggle_published != response_toggle_cpu_seen;
  wire response_ready_cpu =
    response_pending_cpu || response_arrived;

  // A rejected first read beat is held through backpressure.
  always @(posedge clock) begin
    if (reset) begin
      request_seen_system <= 1'b0;
      request_active_system <= 1'b0;
      request_addr_system <= 22'd0;
      state_reg <= STATE_IDLE;
      response_data_published <= 16'd0;
      response_toggle_published <= 1'b0;
    end
    else begin
      if (!io_in_rd)
        request_seen_system <= 1'b0;

      if (incoming_request) begin
        request_seen_system <= 1'b1;
        request_addr_system <= io_in_addr;
        if (!io_out_wait_n)
          request_active_system <= 1'b1;
      end

      if (accepted_read) begin
        request_active_system <= 1'b0;
        state_reg <= STATE_WAIT;
      end

      if (response_arrived) begin
        response_data_published <= io_out_dout;
        response_toggle_published <= ~response_toggle_published;
        state_reg <= STATE_IDLE;
      end
    end
  end

  // Main and this register see response_ready_cpu on the same CPU rising
  // edge: Main takes the data, this records the response as taken. An early
  // response and a pending toggle never coincide, as a request is not issued
  // until the toggle has been taken.
  always @(posedge io_targetClock) begin
    if (io_targetReset)
      response_toggle_cpu_seen <= 1'b0;
    else if (response_ready_cpu)
      response_toggle_cpu_seen <= response_toggle_published ^ response_arrived;
  end

  assign io_in_dout = response_arrived ? io_out_dout : response_data_published;
  assign io_in_valid = response_ready_cpu;
  assign io_out_rd = issue_read;
  assign io_out_addr =
    request_active_system ? request_addr_system : io_in_addr;
endmodule

module CaveEepromDataFreezer(
  input         clock,
  input         reset,
  input         io_targetClock,
  input         io_in_rd,
  input         io_in_wr,
  input  [6:0]  io_in_addr,
  input  [15:0] io_in_din,
  output [15:0] io_in_dout,
  output        io_in_wait_n,
  output        io_in_valid,
  output        io_out_rd,
  output        io_out_wr,
  output [6:0]  io_out_addr,
  output [15:0] io_out_din,
  input  [15:0] io_out_dout,
  input         io_out_wait_n,
  input         io_out_valid
);

  reg        target_clock_toggle = 1'b0;
  reg        target_clock_toggle_staged = 1'b0;
  reg        target_clock_toggle_sync;
  reg        target_clock_toggle_d;
  reg        response_clock_toggle_staged = 1'b0;
  reg        response_clock_toggle_d;
  reg        request_rd_staged = 1'b0;
  reg        request_wr_staged = 1'b0;
  reg [6:0]  request_addr_staged = 7'd0;
  reg [15:0] request_din_staged = 16'd0;
  reg        request_rd_system;
  reg        request_wr_system;
  reg [6:0]  request_addr_system;
  reg [15:0] request_din_system;
  reg [6:0]  request_addr_armed;
  reg [15:0] request_din_armed;
  reg        wait_n_latched;
  reg        valid_latched;
  reg [15:0] data_latched;
  reg        data_latched_valid;
  reg        request_read_armed;
  reg        request_write_armed;
  reg        pending_read;
  reg        pending_write;
  reg        clear_read_d;

  wire       request_boundary =
    target_clock_toggle_sync ^ target_clock_toggle_d;
  wire       clear =
    response_clock_toggle_staged ^ response_clock_toggle_d;
  wire       wait_n = io_out_wait_n | (wait_n_latched & ~clear);
  wire       valid = io_out_valid | (valid_latched & ~clear);
  wire       clear_read = clear & clear_read_d;
  wire       output_read = request_read_armed;
  wire       output_write = request_write_armed;
  wire       accepted_read = output_read & io_out_wait_n;
  wire       accepted_write = output_write & io_out_wait_n;
  wire       arm_read =
    request_boundary & request_rd_system & ~request_read_armed &
      ~pending_read & ~valid;
  wire       arm_write =
    request_boundary & request_wr_system & ~request_write_armed &
      ~pending_write;

  always @(posedge io_targetClock) begin
    if (reset)
      target_clock_toggle <= 1'b0;
    else
      target_clock_toggle <= ~target_clock_toggle;
  end

  always @(negedge io_targetClock) begin
    if (reset) begin
      target_clock_toggle_staged <= 1'b0;
      request_rd_staged <= 1'b0;
      request_wr_staged <= 1'b0;
      request_addr_staged <= 7'd0;
      request_din_staged <= 16'd0;
    end
    else begin
      target_clock_toggle_staged <= target_clock_toggle;
      request_rd_staged <= io_in_rd;
      request_wr_staged <= io_in_wr;
      request_addr_staged <= io_in_addr;
      request_din_staged <= io_in_din;
    end
  end

  // Retire a held response only after the target rising edge has sampled it.
  // The 96 MHz falling edge is safely separated from the related 32 MHz edge.
  always @(negedge clock) begin
    if (reset)
      response_clock_toggle_staged <= 1'b0;
    else
      response_clock_toggle_staged <= target_clock_toggle;
  end

  always @(posedge clock) begin
    if (reset) begin
      target_clock_toggle_sync <= 1'b0;
      target_clock_toggle_d <= 1'b0;
      response_clock_toggle_d <= 1'b0;
      request_rd_system <= 1'b0;
      request_wr_system <= 1'b0;
      request_addr_system <= 7'd0;
      request_din_system <= 16'd0;
      request_addr_armed <= 7'd0;
      request_din_armed <= 16'd0;
      wait_n_latched <= 1'b0;
      valid_latched <= 1'b0;
      data_latched <= 16'd0;
      data_latched_valid <= 1'b0;
      request_read_armed <= 1'b0;
      request_write_armed <= 1'b0;
      pending_read <= 1'b0;
      pending_write <= 1'b0;
      clear_read_d <= 1'b0;
    end
    else begin
      target_clock_toggle_sync <= target_clock_toggle_staged;
      target_clock_toggle_d <= target_clock_toggle_sync;
      response_clock_toggle_d <= response_clock_toggle_staged;
      request_rd_system <= request_rd_staged;
      request_wr_system <= request_wr_staged;
      request_addr_system <= request_addr_staged;
      request_din_system <= request_din_staged;
      if (io_out_valid)
        data_latched <= io_out_dout;
      if (accepted_read)
        request_read_armed <= 1'b0;
      else if (arm_read)
        request_read_armed <= 1'b1;
      if (accepted_write)
        request_write_armed <= 1'b0;
      else if (arm_write)
        request_write_armed <= 1'b1;
      if (arm_read | arm_write) begin
        request_addr_armed <= request_addr_system;
        request_din_armed <= request_din_system;
      end
      clear_read_d <= valid;
      wait_n_latched <= io_out_wait_n | (~clear & wait_n_latched);
      valid_latched <= io_out_valid | (~clear & valid_latched);
      data_latched_valid <= io_out_valid | (~clear & data_latched_valid);
      pending_read <= accepted_read | (~clear_read & pending_read);
      pending_write <= accepted_write | (~clear & pending_write);
    end
  end // always @(posedge)

  assign io_in_dout = (data_latched_valid & ~clear) ? data_latched : io_out_dout;
  assign io_in_wait_n = wait_n;
  assign io_in_valid = valid;
  assign io_out_rd = output_read;
  assign io_out_wr = output_write;
  assign io_out_addr = request_addr_armed;
  assign io_out_din = request_din_armed;

`ifdef CAVE_ESPRADE_SERVICE_DIAGNOSTICS
  reg        espradeSourceReadPrev = 1'b0;
  reg [7:0]  espradeSourceReadCount = 8'd0;
  reg [27:0] espradeSourceReadAddrs = 28'd0;
  reg [7:0]  espradeArmReadCount = 8'd0;
  reg [27:0] espradeArmSystemAddrs = 28'd0;
  reg [27:0] espradeArmStagedAddrs = 28'd0;
  reg [7:0]  espradeAcceptedReadCount = 8'd0;
  reg [27:0] espradeAcceptedReadAddrs = 28'd0;
  reg [7:0]  espradeResponseCount = 8'd0;
  reg [63:0] espradeResponseData = 64'd0;

  always @(posedge io_targetClock) begin
    if (reset) begin
      espradeSourceReadPrev <= 1'b0;
      espradeSourceReadCount <= 8'd0;
      espradeSourceReadAddrs <= 28'd0;
    end
    else begin
      espradeSourceReadPrev <= io_in_rd;
      if (io_in_rd && !espradeSourceReadPrev) begin
        case (espradeSourceReadCount)
          8'd0: espradeSourceReadAddrs[27:21] <= io_in_addr;
          8'd1: espradeSourceReadAddrs[20:14] <= io_in_addr;
          8'd2: espradeSourceReadAddrs[13:7] <= io_in_addr;
          8'd3: espradeSourceReadAddrs[6:0] <= io_in_addr;
          default: begin
          end
        endcase
        espradeSourceReadCount <= espradeSourceReadCount + 8'd1;
      end
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      espradeArmReadCount <= 8'd0;
      espradeArmSystemAddrs <= 28'd0;
      espradeArmStagedAddrs <= 28'd0;
      espradeAcceptedReadCount <= 8'd0;
      espradeAcceptedReadAddrs <= 28'd0;
      espradeResponseCount <= 8'd0;
      espradeResponseData <= 64'd0;
    end
    else begin
      if (arm_read) begin
        case (espradeArmReadCount)
          8'd0: begin
            espradeArmSystemAddrs[27:21] <= request_addr_system;
            espradeArmStagedAddrs[27:21] <= request_addr_staged;
          end
          8'd1: begin
            espradeArmSystemAddrs[20:14] <= request_addr_system;
            espradeArmStagedAddrs[20:14] <= request_addr_staged;
          end
          8'd2: begin
            espradeArmSystemAddrs[13:7] <= request_addr_system;
            espradeArmStagedAddrs[13:7] <= request_addr_staged;
          end
          8'd3: begin
            espradeArmSystemAddrs[6:0] <= request_addr_system;
            espradeArmStagedAddrs[6:0] <= request_addr_staged;
          end
          default: begin
          end
        endcase
        espradeArmReadCount <= espradeArmReadCount + 8'd1;
      end

      if (accepted_read) begin
        case (espradeAcceptedReadCount)
          8'd0: espradeAcceptedReadAddrs[27:21] <= io_out_addr;
          8'd1: espradeAcceptedReadAddrs[20:14] <= io_out_addr;
          8'd2: espradeAcceptedReadAddrs[13:7] <= io_out_addr;
          8'd3: espradeAcceptedReadAddrs[6:0] <= io_out_addr;
          default: begin
          end
        endcase
        espradeAcceptedReadCount <= espradeAcceptedReadCount + 8'd1;
      end

      if (io_out_valid) begin
        case (espradeResponseCount)
          8'd0: espradeResponseData[63:48] <= io_out_dout;
          8'd1: espradeResponseData[47:32] <= io_out_dout;
          8'd2: espradeResponseData[31:16] <= io_out_dout;
          8'd3: espradeResponseData[15:0] <= io_out_dout;
          default: begin
          end
        endcase
        espradeResponseCount <= espradeResponseCount + 8'd1;
      end
    end
  end

  wire [255:0] espradeFreezerProbe = {
    16'hE514,
    4'd1,
    espradeSourceReadCount,
    espradeArmReadCount,
    espradeAcceptedReadCount,
    espradeResponseCount,
    espradeSourceReadAddrs,
    espradeArmSystemAddrs,
    espradeArmStagedAddrs,
    espradeAcceptedReadAddrs,
    espradeResponseData,
    io_in_addr,
    request_addr_staged,
    request_addr_system,
    request_addr_armed
  };
  wire [0:0] espradeFreezerSource;

  altsource_probe #(
    .sld_auto_instance_index ("NO"),
    .sld_instance_index      (7),
    .instance_id             ("EEF"),
    .probe_width             (256),
    .source_width            (1),
    .source_initial_value    ("0"),
    .enable_metastability    ("NO")
  ) espradeFreezerDiagnosticsProbe (
    .probe  (espradeFreezerProbe),
    .source (espradeFreezerSource)
  );
`endif
endmodule

module CaveSoundRomReadFreezer(
  input         clock,
  input         reset,
  input         io_targetClock,
  input         io_hold_response,
  input         io_in_rd,
  input  [24:0] io_in_addr,
  output [7:0]  io_in_dout,
  output        io_in_wait_n,
  output        io_in_valid,
  output        io_out_rd,
  output [24:0] io_out_addr,
  input  [7:0]  io_out_dout,
  input         io_out_wait_n,
  input         io_out_valid
);

  localparam [1:0] STATE_IDLE = 2'd0;
  localparam [1:0] STATE_ISSUE = 2'd1;
  localparam [1:0] STATE_WAIT = 2'd2;

  reg        request_toggle_target = 1'b0;
  reg [24:0] request_addr_target = 25'd0;
  reg        pending_read = 1'b0;
  reg        request_armed_target = 1'b1;
  reg        response_toggle_target_sync0 = 1'b0;
  reg        response_toggle_target_sync1 = 1'b0;
  reg        response_toggle_target_seen = 1'b0;
  reg [7:0]  response_data_target = 8'd0;
  reg [24:0] response_addr_target = 25'd0;
  reg        response_valid_target = 1'b0;

  reg        request_toggle_system_sync0 = 1'b0;
  reg        request_toggle_system_sync1 = 1'b0;
  reg        request_toggle_system_seen = 1'b0;
  reg [24:0] request_addr_system = 25'd0;
  reg [1:0]  state_reg = STATE_IDLE;
  reg [7:0]  response_data_system = 8'd0;
  reg [24:0] response_addr_system = 25'd0;
  reg        response_toggle_system = 1'b0;

  wire       new_request_system =
    request_toggle_system_sync1 != request_toggle_system_seen;

  wire       response_matches_target =
    response_valid_target && io_in_rd &&
    (response_addr_target == io_in_addr);

  // The request and response payloads remain stable while their toggles cross
  // the clock boundary. The Z80/OKI path holds a tagged response until the
  // reader advances; existing YMZ clients retain their pulse handshake.
  always @(posedge io_targetClock) begin
    if (reset) begin
      request_toggle_target <= 1'b0;
      request_addr_target <= 25'd0;
      pending_read <= 1'b0;
      request_armed_target <= 1'b1;
      response_toggle_target_sync0 <= 1'b0;
      response_toggle_target_sync1 <= 1'b0;
      response_toggle_target_seen <= 1'b0;
      response_data_target <= 8'd0;
      response_addr_target <= 25'd0;
      response_valid_target <= 1'b0;
    end
    else begin
      response_toggle_target_sync0 <= response_toggle_system;
      response_toggle_target_sync1 <= response_toggle_target_sync0;

      if (io_hold_response) begin
        if (response_valid_target &&
            (!io_in_rd || response_addr_target != io_in_addr))
          response_valid_target <= 1'b0;

        if (io_in_rd && !pending_read && !response_matches_target) begin
          request_addr_target <= io_in_addr;
          request_toggle_target <= ~request_toggle_target;
          pending_read <= 1'b1;
        end
      end
      else begin
        response_valid_target <= 1'b0;

        if (!io_in_rd || io_in_addr != request_addr_target)
          request_armed_target <= 1'b1;

        if (io_in_rd && request_armed_target && !pending_read) begin
          request_addr_target <= io_in_addr;
          request_toggle_target <= ~request_toggle_target;
          pending_read <= 1'b1;
          request_armed_target <= 1'b0;
        end
      end

      if (response_toggle_target_sync1 != response_toggle_target_seen) begin
        response_toggle_target_seen <= response_toggle_target_sync1;
        response_data_target <= response_data_system;
        response_addr_target <= response_addr_system;
        response_valid_target <= io_hold_response
          ? io_in_rd && (response_addr_system == io_in_addr)
          : response_addr_system == io_in_addr;
        pending_read <= 1'b0;
      end
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      request_toggle_system_sync0 <= 1'b0;
      request_toggle_system_sync1 <= 1'b0;
      request_toggle_system_seen <= 1'b0;
      request_addr_system <= 25'd0;
      state_reg <= STATE_IDLE;
      response_data_system <= 8'd0;
      response_addr_system <= 25'd0;
      response_toggle_system <= 1'b0;
    end
    else begin
      request_toggle_system_sync0 <= request_toggle_target;
      request_toggle_system_sync1 <= request_toggle_system_sync0;

      case (state_reg)
        STATE_IDLE: begin
          if (new_request_system) begin
            request_toggle_system_seen <= request_toggle_system_sync1;
            request_addr_system <= request_addr_target;
            state_reg <= STATE_ISSUE;
          end
        end

        STATE_ISSUE: begin
          if (io_out_wait_n)
            state_reg <= STATE_WAIT;
        end

        STATE_WAIT: begin
          if (io_out_valid) begin
            response_data_system <= io_out_dout;
            response_addr_system <= request_addr_system;
            response_toggle_system <= ~response_toggle_system;
            state_reg <= STATE_IDLE;
          end
        end

        default: state_reg <= STATE_IDLE;
      endcase
    end
  end

  assign io_in_dout = response_data_target;
  assign io_in_wait_n = ~pending_read;
  assign io_in_valid =
    io_hold_response ? response_matches_target : response_valid_target;
  assign io_out_rd = state_reg == STATE_ISSUE;
  assign io_out_addr = request_addr_system;
endmodule
