// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).

module CaveMain68kCpu #(
  parameter [7:0] SS_IDX = 8'd2,
  parameter integer SS_RESET_CYCLES = 32
) (
  input         clock,
  input         reset,
  input         io_halt,
  input         io_ss_hold,
  input         io_ss_capture_request,
  input         io_ss_restore_enable,
  input         io_ss_restore_start,
  input         io_ss_restore_commit,
  input         io_ss_release,
  output        io_ss_capture_done,
  output        io_ss_cpu_idle,
  output reg    io_ss_restore_commit_done,
  output reg    io_ss_reconstruction_ready,
  output        io_as,
  output        io_rw,
  output        io_uds,
  output        io_lds,
  input         io_dtack,
  input         io_vpa,
  input  [2:0]  io_ipl,
  output [2:0]  io_fc,
  output [22:0] io_addr,
  input  [15:0] io_din,
  output [15:0] io_dout,
  cave_ssbus_if.slave ssbus
);
  reg phi1_enable;
  reg phi2_enable;

  localparam [31:0] SS_CONTEXT_TAG = 32'h3638_4b31; // "68K1"

  wire raw_as_n;
  wire raw_uds_n;
  wire raw_lds_n;
  wire raw_rw;
  wire raw_fc0;
  wire raw_fc1;
  wire raw_fc2;
  wire [22:0] raw_addr;
  wire [15:0] raw_dout;
  wire [23:0] raw_byte_addr = {raw_addr, 1'b0};
  wire raw_bus_active = !raw_as_n && (!raw_uds_n || !raw_lds_n);

  reg capture_request_d = 1'b0;
  reg ss_override_active = 1'b0;
  reg ss_capture_done_reg = 1'b0;
  reg ss_exit_armed = 1'b0;
  reg ss_special_seen = 1'b0;
  reg ss_normal_fetch_seen = 1'b0;
  reg [31:0] ss_saved_ssp = 32'd0;
  reg [31:0] ss_restore_ssp = 32'd0;
  reg ss_restore_context_loaded = 1'b0;
  reg ss_restore_pending = 1'b0;
  reg ss_restore_reset = 1'b0;
  reg ss_restore_vectors = 1'b0;
  reg [15:0] ss_reset_count = 16'd0;
  reg ss_hold_active = 1'b0;

  wire ss_handler_cs = ss_override_active && raw_bus_active &&
                       (raw_byte_addr[23:8] == 16'hff00);
  wire ss_reset_vector_cs = ss_restore_vectors && raw_bus_active &&
                            (raw_byte_addr < 24'h000008);
  wire ss_irq_vector_cs = ss_override_active && raw_bus_active && raw_rw &&
                          ((raw_byte_addr == 24'h00007c) ||
                           (raw_byte_addr == 24'h00007e));
  wire ss_special_cs = ss_handler_cs || ss_reset_vector_cs || ss_irq_vector_cs;

  wire ss_normal_program_fetch = ss_override_active && ss_exit_armed &&
                                 raw_bus_active && raw_rw && raw_fc1 &&
                                 !raw_fc0 && !ss_special_cs;
  wire ss_context_valid = ss_restore_context_loaded &&
                          (ss_restore_ssp != 0) &&
                          (ss_restore_ssp[31:24] == 0) &&
                          !ss_restore_ssp[0];

  wire [2:0] cpu_ipl = (io_ss_capture_request && !ss_capture_done_reg)
                     ? 3'b111 : io_ipl;
  wire halt_n = ~(io_halt && !ss_override_active);
  wire dtack_n = ~(ss_special_cs ? 1'b1 : io_dtack);
  wire vpa_n = ~(ss_special_cs ? 1'b0 : io_vpa);
  wire ss_clock_hold = ss_hold_active || (io_ss_hold && !raw_bus_active);

  reg [15:0] ss_special_data;

  function [15:0] ss_handler_word;
    input [3:0] index;
    begin
      case (index)
        4'h0: ss_handler_word = 16'h48e7;
        4'h1: ss_handler_word = 16'hfffe;
        4'h2: ss_handler_word = 16'h4e6e;
        4'h3: ss_handler_word = 16'h2f0e;
        4'h4: ss_handler_word = 16'h4df9;
        4'h5: ss_handler_word = 16'h00ff;
        4'h6: ss_handler_word = 16'h0000;
        4'h7: ss_handler_word = 16'h2c8f;
        4'h8: ss_handler_word = 16'h2c5f;
        4'h9: ss_handler_word = 16'h4e66;
        4'ha: ss_handler_word = 16'h4cdf;
        4'hb: ss_handler_word = 16'h7fff;
        4'hc: ss_handler_word = 16'h4e73;
        default: ss_handler_word = 16'h4e71;
      endcase
    end
  endfunction

  always @* begin
    if (ss_handler_cs) begin
      ss_special_data = ss_handler_word(raw_byte_addr[4:1]);
    end else if (ss_reset_vector_cs) begin
      case (raw_byte_addr[2:1])
        2'd0: ss_special_data = ss_restore_ssp[31:16];
        2'd1: ss_special_data = ss_restore_ssp[15:0];
        2'd2: ss_special_data = 16'h00ff;
        default: ss_special_data = 16'h0008;
      endcase
    end else if (ss_irq_vector_cs) begin
      ss_special_data = raw_byte_addr[1] ? 16'h0000 : 16'h00ff;
    end else begin
      ss_special_data = 16'hffff;
    end
  end

  always @(posedge clock) begin
    if (reset)
      phi1_enable <= 1'b0;
    else
      phi1_enable <= ~phi1_enable;

    phi2_enable <= phi1_enable;
  end

  always @(posedge clock) begin
    if (reset || !io_ss_hold)
      ss_hold_active <= 1'b0;
    else if (!raw_bus_active)
      ss_hold_active <= 1'b1;
  end

  // Save-state owner for the tagged supervisor stack pointer. The remaining
  // architectural state is in the private interrupt frame stored in work RAM.
  always @(posedge clock) begin
    ssbus.ack <= 1'b0;

    if (reset) begin
      ssbus.data_out <= 64'd0;
      ss_restore_ssp <= 32'd0;
      ss_restore_context_loaded <= 1'b0;
    end else if (io_ss_restore_start) begin
      ss_restore_ssp <= 32'd0;
      ss_restore_context_loaded <= 1'b0;
    end else if ((ssbus.select == SS_IDX) && ssbus.query) begin
      ssbus.data_out <= {SS_IDX, 22'd0, 2'd3, 32'd1};
      ssbus.ack <= 1'b1;
    end else if ((ssbus.select == SS_IDX) && ssbus.read && !ssbus.query) begin
      ssbus.data_out <= {SS_CONTEXT_TAG, ss_saved_ssp};
      ssbus.ack <= 1'b1;
    end else if ((ssbus.select == SS_IDX) && ssbus.write && !ssbus.query) begin
      if (io_ss_restore_enable) begin
        if (ssbus.data[63:32] == SS_CONTEXT_TAG) begin
          ss_restore_ssp <= ssbus.data[31:0];
          ss_restore_context_loaded <= 1'b1;
        end else begin
          ss_restore_ssp <= 32'd0;
          ss_restore_context_loaded <= 1'b0;
        end
      end
      ssbus.ack <= 1'b1;
    end
  end

  always @(posedge clock) begin
    if (reset) begin
      capture_request_d <= 1'b0;
      ss_override_active <= 1'b0;
      ss_capture_done_reg <= 1'b0;
      ss_exit_armed <= 1'b0;
      ss_special_seen <= 1'b0;
      ss_normal_fetch_seen <= 1'b0;
      ss_saved_ssp <= 32'd0;
      ss_restore_pending <= 1'b0;
      ss_restore_reset <= 1'b0;
      ss_restore_vectors <= 1'b0;
      ss_reset_count <= 16'd0;
      io_ss_restore_commit_done <= 1'b0;
      io_ss_reconstruction_ready <= 1'b1;
    end else begin
      capture_request_d <= io_ss_capture_request;
      io_ss_restore_commit_done <= 1'b0;

      if (io_ss_capture_request && !capture_request_d) begin
        ss_override_active <= 1'b1;
        ss_capture_done_reg <= 1'b0;
        ss_exit_armed <= 1'b0;
        io_ss_reconstruction_ready <= 1'b0;
      end

      if (!ss_special_cs)
        ss_special_seen <= 1'b0;
      else if (!ss_special_seen) begin
        ss_special_seen <= 1'b1;
        if (ss_handler_cs && !raw_rw) begin
          if (raw_byte_addr == 24'hff0000)
            ss_saved_ssp[31:16] <= raw_dout;
          if (raw_byte_addr == 24'hff0002) begin
            ss_saved_ssp[15:0] <= raw_dout;
            ss_exit_armed <= 1'b1;
            if (io_ss_capture_request)
              ss_capture_done_reg <= 1'b1;
          end
        end
      end

      if (!ss_normal_program_fetch) begin
        ss_normal_fetch_seen <= 1'b0;
      end else if (io_dtack && !ss_normal_fetch_seen) begin
        ss_normal_fetch_seen <= 1'b1;
        ss_override_active <= 1'b0;
        ss_restore_vectors <= 1'b0;
        ss_capture_done_reg <= 1'b0;
        ss_exit_armed <= 1'b0;
        io_ss_reconstruction_ready <= 1'b1;
      end

      if (io_ss_restore_commit && ss_context_valid) begin
        ss_restore_pending <= 1'b1;
        io_ss_restore_commit_done <= 1'b1;
        io_ss_reconstruction_ready <= 1'b0;
      end

      if (io_ss_release && ss_restore_pending) begin
        ss_restore_pending <= 1'b0;
        ss_restore_reset <= 1'b1;
        ss_restore_vectors <= 1'b1;
        ss_override_active <= 1'b1;
        ss_exit_armed <= 1'b0;
        ss_reset_count <= 16'd0;
      end else if (ss_restore_reset) begin
        if (ss_reset_count + 16'd1 >= SS_RESET_CYCLES) begin
          ss_restore_reset <= 1'b0;
          ss_reset_count <= 16'd0;
        end else begin
          ss_reset_count <= ss_reset_count + 16'd1;
        end
      end
    end
  end

  fx68k cpu (
    .clk      (clock),
    .enPhi1   (phi1_enable && !ss_clock_hold && !ss_restore_pending),
    .enPhi2   (phi2_enable && !ss_clock_hold && !ss_restore_pending),
    .extReset (reset || ss_restore_reset),
    .pwrUp    (reset || ss_restore_reset),
    .HALTn    (halt_n),
    .ASn      (raw_as_n),
    .eRWn     (raw_rw),
    .UDSn     (raw_uds_n),
    .LDSn     (raw_lds_n),
    .DTACKn   (dtack_n),
    .BERRn    (1'b1),
    .E        (),
    .VPAn     (vpa_n),
    .VMAn     (),
    .BRn      (1'b1),
    .BGn      (),
    .BGACKn   (1'b1),
    .oRESETn  (),
    .oHALTEDn (),
    .IPL0n    (~cpu_ipl[0]),
    .IPL1n    (~cpu_ipl[1]),
    .IPL2n    (~cpu_ipl[2]),
    .FC0      (raw_fc0),
    .FC1      (raw_fc1),
    .FC2      (raw_fc2),
    .eab      (raw_addr),
    .iEdb     (ss_special_cs ? ss_special_data : io_din),
    .oEdb     (raw_dout)
  );

  assign io_as = ~raw_as_n && !ss_special_cs;
  assign io_rw = raw_rw;
  assign io_uds = ~raw_uds_n && !ss_special_cs;
  assign io_lds = ~raw_lds_n && !ss_special_cs;
  assign io_fc = {raw_fc2, raw_fc1, raw_fc0};
  assign io_addr = raw_addr;
  assign io_dout = raw_dout;
  assign io_ss_capture_done = ss_capture_done_reg;
  assign io_ss_cpu_idle = io_ss_hold
                        ? (ss_hold_active && !raw_bus_active)
                        : !raw_bus_active;
endmodule

module CaveSoundZ80Cpu #(
  parameter [7:0] SS_IDX = 8'd32,
  parameter integer SS_RESET_CYCLES = 4
) (
  input         clock,
  input         reset,
  input         io_ss_hold,
  input         io_ss_capture_request,
  input         io_ss_restore_enable,
  input         io_ss_restore_start,
  input         io_ss_restore_commit,
  input         io_ss_release,
  output        io_ss_capture_done,
  output        io_ss_cpu_idle,
  output reg    io_ss_restore_commit_done,
  output reg    io_ss_reconstruction_ready,
  output [15:0] io_addr,
  input  [7:0]  io_din,
  output [7:0]  io_dout,
  output        io_rd,
  output        io_wr,
  output        io_rfsh,
  output        io_mreq,
  output        io_iorq,
  input         io_fast_clock,
  input         io_wait_n,
  input         io_int,
  input         io_nmi,
  cave_ssbus_if.slave ssbus
);
  localparam [31:0] SS_CONTEXT_TAG = 32'h5a38_3031; // "Z801"
  localparam [2:0] SS_PHASE_RUN = 3'd0;
  localparam [2:0] SS_PHASE_HELD = 3'd1;
  localparam [2:0] SS_PHASE_RESET = 3'd2;
  localparam [2:0] SS_PHASE_DIR = 3'd3;
  localparam [2:0] SS_PHASE_STEP = 3'd4;

  reg [2:0] clock_divider;
  reg [2:0] ss_phase = SS_PHASE_RUN;
  reg [15:0] ss_reset_count = 16'd0;
  reg ss_hold_active = 1'b0;
  reg ss_capture_done_reg = 1'b0;
  reg ss_release_guard = 1'b0;
  reg [211:0] ss_saved_registers = 212'd0;
  reg [24:0] ss_saved_aux = 25'd0;
  reg [2:0] ss_saved_divider = 3'd0;
  reg [211:0] ss_restore_registers = 212'd0;
  reg [24:0] ss_restore_aux = 25'd0;
  reg [2:0] ss_restore_divider = 3'd0;
  reg [4:0] ss_restore_word_valid = 5'd0;
  reg ss_restore_tag_valid = 1'b0;

  wire divider_clock_enable =
    io_fast_clock ? &clock_divider[1:0] : &clock_divider;
  wire ss_core_reset = reset | (ss_phase == SS_PHASE_RESET);
  wire ss_dir_set = ss_phase == SS_PHASE_DIR;
  wire ss_restore_context_valid =
    ss_restore_tag_valid && (&ss_restore_word_valid);

  wire mreq_n;
  wire iorq_n;
  wire rd_n;
  wire wr_n;
  wire rfsh_n;
  reg adapter_mreq_n = 1'b1;
  reg adapter_iorq_n = 1'b1;
  reg adapter_rd_n = 1'b1;
  reg adapter_wr_n = 1'b1;
  reg [7:0] adapter_di_reg = 8'd0;

  wire raw_m1_n;
  wire raw_iorq;
  wire raw_no_read;
  wire raw_write;
  wire raw_rfsh_n;
  wire raw_halt_n;
  wire [15:0] raw_addr;
  wire [7:0] raw_dout;
  wire [2:0] raw_mcycle;
  wire [2:0] raw_tstate;
  wire raw_int_cycle_n;
  wire [211:0] raw_registers;
  wire [24:0] raw_aux;
  wire raw_bus_active = !adapter_mreq_n || !adapter_iorq_n;
  wire raw_canonical_boundary =
    !raw_m1_n && (raw_mcycle == 3'd1) && (raw_tstate == 3'd1);
  wire ss_stop_request =
    !ss_release_guard &&
    ((io_ss_capture_request && !ss_capture_done_reg) || io_ss_hold);
  wire ss_freeze_now =
    (ss_phase == SS_PHASE_RUN) && ss_stop_request &&
    raw_canonical_boundary && !raw_bus_active;
  wire cpu_clock_enable =
    (ss_phase == SS_PHASE_STEP) ||
    ((ss_phase == SS_PHASE_RUN) && !ss_freeze_now &&
     divider_clock_enable);
  wire cpu_interrupt_enable =
    (ss_phase == SS_PHASE_RUN) && !ss_stop_request;

  always @(posedge clock) begin
    if (ss_core_reset) begin
      adapter_rd_n <= 1'b1;
      adapter_wr_n <= 1'b1;
      adapter_iorq_n <= 1'b1;
      adapter_mreq_n <= 1'b1;
      adapter_di_reg <= 8'd0;
    end else if (cpu_clock_enable) begin
      adapter_rd_n <= 1'b1;
      adapter_wr_n <= 1'b1;
      adapter_iorq_n <= 1'b1;
      adapter_mreq_n <= 1'b1;

      if (raw_mcycle == 3'd1) begin
        if ((raw_tstate == 3'd1) ||
            ((raw_tstate == 3'd2) && !io_wait_n)) begin
          adapter_rd_n <= !raw_int_cycle_n;
          adapter_mreq_n <= !raw_int_cycle_n;
          adapter_iorq_n <= raw_int_cycle_n;
        end
        if (raw_tstate == 3'd3)
          adapter_mreq_n <= 1'b0;
      end else begin
        if (((raw_tstate == 3'd1) ||
             ((raw_tstate == 3'd2) && !io_wait_n)) &&
            !raw_no_read && !raw_write) begin
          adapter_rd_n <= 1'b0;
          adapter_iorq_n <= !raw_iorq;
          adapter_mreq_n <= raw_iorq;
        end

        if (((raw_tstate == 3'd1) ||
             ((raw_tstate == 3'd2) && !io_wait_n)) &&
            raw_write) begin
          adapter_wr_n <= 1'b0;
          adapter_iorq_n <= !raw_iorq;
          adapter_mreq_n <= raw_iorq;
        end
      end

      if ((raw_tstate == 3'd2) && io_wait_n)
        adapter_di_reg <= io_din;
    end
  end

  CaveT80SaveState #(
    .Mode   (0),
    .IOWait (1)
  ) cpu (
    .RESET_n    (~ss_core_reset),
    .CLK_n      (clock),
    .CEN        (cpu_clock_enable),
    .WAIT_n     (io_wait_n),
    .INT_n      (~(io_int & cpu_interrupt_enable)),
    .NMI_n      (~(io_nmi & cpu_interrupt_enable)),
    .BUSRQ_n    (1'b1),
    .M1_n       (raw_m1_n),
    .IORQ       (raw_iorq),
    .NoRead     (raw_no_read),
    .Write      (raw_write),
    .RFSH_n     (raw_rfsh_n),
    .HALT_n     (raw_halt_n),
    .BUSAK_n    (),
    .A          (raw_addr),
    .DInst      (io_din),
    .DI         (adapter_di_reg),
    .DO         (raw_dout),
    .MC         (raw_mcycle),
    .TS         (raw_tstate),
    .IntCycle_n (raw_int_cycle_n),
    .IntE       (),
    .Stop       (),
    .out0       (1'b0),
    .REG        (raw_registers),
    .DIRSet     (ss_dir_set),
    .DIR        (ss_restore_registers),
    .SS_AUX     (raw_aux),
    .DIR_AUX    (ss_restore_aux)
  );

  always @(posedge clock) begin
    io_ss_restore_commit_done <= 1'b0;

    if (reset) begin
      clock_divider <= 3'd0;
      ss_phase <= SS_PHASE_RUN;
      ss_reset_count <= 16'd0;
      ss_hold_active <= 1'b0;
      ss_capture_done_reg <= 1'b0;
      ss_release_guard <= 1'b0;
      ss_saved_registers <= 212'd0;
      ss_saved_aux <= 25'd0;
      ss_saved_divider <= 3'd0;
      io_ss_restore_commit_done <= 1'b0;
      io_ss_reconstruction_ready <= 1'b1;
    end else begin
      if (io_ss_restore_start)
        io_ss_reconstruction_ready <= 1'b0;

      if (!io_ss_capture_request && !io_ss_hold)
        ss_release_guard <= 1'b0;

      case (ss_phase)
        SS_PHASE_RUN: begin
          if (!ss_freeze_now)
            clock_divider <= clock_divider + 3'd1;

          if (ss_freeze_now) begin
            ss_phase <= SS_PHASE_HELD;
            ss_hold_active <= 1'b1;
            if (io_ss_capture_request && !ss_capture_done_reg) begin
              ss_saved_registers <= raw_registers;
              ss_saved_aux <= raw_aux;
              ss_saved_divider <= clock_divider;
              ss_capture_done_reg <= 1'b1;
            end
          end
        end

        SS_PHASE_HELD: begin
          if (io_ss_restore_commit && ss_restore_context_valid) begin
            ss_phase <= SS_PHASE_RESET;
            ss_reset_count <= 16'd0;
            io_ss_reconstruction_ready <= 1'b0;
          end else if (io_ss_release) begin
            ss_phase <= SS_PHASE_RUN;
            ss_hold_active <= 1'b0;
            ss_capture_done_reg <= 1'b0;
            ss_release_guard <= 1'b1;
            io_ss_reconstruction_ready <= 1'b1;
          end
        end

        SS_PHASE_RESET: begin
          if (ss_reset_count + 16'd1 >= SS_RESET_CYCLES) begin
            ss_phase <= SS_PHASE_DIR;
            ss_reset_count <= 16'd0;
          end else begin
            ss_reset_count <= ss_reset_count + 16'd1;
          end
        end

        SS_PHASE_DIR: begin
          clock_divider <= ss_restore_divider;
          ss_phase <= SS_PHASE_STEP;
        end

        SS_PHASE_STEP: begin
          ss_phase <= SS_PHASE_HELD;
          io_ss_restore_commit_done <= 1'b1;
          io_ss_reconstruction_ready <= 1'b1;
        end

        default: begin
          ss_phase <= SS_PHASE_RUN;
          ss_hold_active <= 1'b0;
          ss_capture_done_reg <= 1'b0;
          io_ss_reconstruction_ready <= 1'b1;
        end
      endcase
    end
  end

  always @(posedge clock) begin
    ssbus.ack <= 1'b0;

    if (reset) begin
      ssbus.data_out <= 64'd0;
      ss_restore_registers <= 212'd0;
      ss_restore_aux <= 25'd0;
      ss_restore_divider <= 3'd0;
      ss_restore_word_valid <= 5'd0;
      ss_restore_tag_valid <= 1'b0;
    end else if (io_ss_restore_start) begin
      ss_restore_registers <= 212'd0;
      ss_restore_aux <= 25'd0;
      ss_restore_divider <= 3'd0;
      ss_restore_word_valid <= 5'd0;
      ss_restore_tag_valid <= 1'b0;
    end else if ((ssbus.select == SS_IDX) && ssbus.query) begin
      ssbus.data_out <= {SS_IDX, 22'd0, 2'd3, 32'd5};
      ssbus.ack <= 1'b1;
    end else if ((ssbus.select == SS_IDX) &&
                 ssbus.read && !ssbus.query) begin
      case (ssbus.addr)
        32'd0: ssbus.data_out <= {
          SS_CONTEXT_TAG, 4'd0, ss_saved_divider, ss_saved_aux
        };
        32'd1: ssbus.data_out <= ss_saved_registers[63:0];
        32'd2: ssbus.data_out <= ss_saved_registers[127:64];
        32'd3: ssbus.data_out <= ss_saved_registers[191:128];
        32'd4: ssbus.data_out <= {44'd0, ss_saved_registers[211:192]};
        default: ssbus.data_out <= 64'd0;
      endcase
      ssbus.ack <= 1'b1;
    end else if ((ssbus.select == SS_IDX) &&
                 ssbus.write && !ssbus.query) begin
      if (io_ss_restore_enable) begin
        case (ssbus.addr)
          32'd0: begin
            ss_restore_tag_valid <= ssbus.data[63:32] == SS_CONTEXT_TAG;
            ss_restore_divider <= ssbus.data[27:25];
            ss_restore_aux <= ssbus.data[24:0];
            ss_restore_word_valid[0] <= 1'b1;
          end
          32'd1: begin
            ss_restore_registers[63:0] <= ssbus.data;
            ss_restore_word_valid[1] <= 1'b1;
          end
          32'd2: begin
            ss_restore_registers[127:64] <= ssbus.data;
            ss_restore_word_valid[2] <= 1'b1;
          end
          32'd3: begin
            ss_restore_registers[191:128] <= ssbus.data;
            ss_restore_word_valid[3] <= 1'b1;
          end
          32'd4: begin
            ss_restore_registers[211:192] <= ssbus.data[19:0];
            ss_restore_word_valid[4] <= 1'b1;
          end
          default: begin
          end
        endcase
      end
      ssbus.ack <= 1'b1;
    end
  end

  assign mreq_n = adapter_mreq_n;
  assign iorq_n = adapter_iorq_n;
  assign rd_n = adapter_rd_n;
  assign wr_n = adapter_wr_n;
  assign rfsh_n = raw_rfsh_n;

  assign io_addr = raw_addr;
  assign io_dout = raw_dout;
  assign io_rd = ~rd_n & !ss_hold_active;
  assign io_wr = ~wr_n & !ss_hold_active;
  assign io_rfsh = ~rfsh_n & !ss_hold_active;
  assign io_mreq = ~mreq_n & !ss_hold_active;
  assign io_iorq = ~iorq_n & !ss_hold_active;
  assign io_ss_capture_done = ss_capture_done_reg;
  assign io_ss_cpu_idle = ss_hold_active && !raw_bus_active;
endmodule
