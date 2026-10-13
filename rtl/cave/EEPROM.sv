// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).

module EEPROM(
  input         clock,
  input         reset,
  input         io_ss_hold,
  input         io_ss_restore_enable,
  output        io_ss_idle,
  cave_ssbus_if.slave io_ssbus,
  output        io_mem_rd,
  output        io_mem_wr,
  output [6:0]  io_mem_addr,
  output [15:0] io_mem_din,
  input  [15:0] io_mem_dout,
  input         io_mem_wait_n,
  input         io_mem_valid,
  input         io_serial_cs,
  input         io_serial_sck,
  input         io_serial_sdi,
  output        io_serial_sdo
);
  localparam [2:0] STATE_IDLE      = 3'd0;
  localparam [2:0] STATE_START     = 3'd1;
  localparam [2:0] STATE_COMMAND   = 3'd2;
  localparam [2:0] STATE_READ      = 3'd3;
  localparam [2:0] STATE_READ_WAIT = 3'd4;
  localparam [2:0] STATE_WRITE     = 3'd5;
  localparam [2:0] STATE_SHIFT_IN  = 3'd6;
  localparam [2:0] STATE_SHIFT_OUT = 3'd7;

  reg  [2:0]  stateReg;
  reg  [16:0] counterReg;
  reg  [5:0]  addrReg;
  reg  [15:0] dataReg;
  reg  [1:0]  opcodeReg;
  reg         serialReg;
  reg         writeAllReg;
  reg         writeEnableReg;
  reg         sckPrev;

  reg  [2:0]  stateNext;
  reg  [16:0] counterNext;
  reg  [5:0]  addrNext;
  reg  [15:0] dataNext;
  reg  [1:0]  opcodeNext;
  reg         serialNext;
  reg         writeAllNext;
  reg         writeEnableNext;

  wire        ssRestoreWr;
  wire [31:0] ssRestoreAddr;
  wire [63:0] ssRestoreData;
  wire        ssStateEnable;
  wire [63:0] ssCaptureData = {
    16'h4545,
    stateReg,
    counterReg,
    addrReg,
    dataReg,
    opcodeReg,
    serialReg,
    writeAllReg,
    writeEnableReg,
    sckPrev
  };

  wire sckRising = io_serial_sck & ~sckPrev;
  wire commandDone = counterReg[0];

  wire readCommand = opcodeReg == 2'd2;
  wire writeCommand = opcodeReg == 2'd1 && writeEnableReg;
  wire eraseCommand = opcodeReg == 2'd3 && writeEnableReg;
  wire writeAllCommand = opcodeReg == 2'd0 && addrReg[4:3] == 2'd1 && writeEnableReg;
  wire eraseAllCommand = opcodeReg == 2'd0 && addrReg[4:3] == 2'd2 && writeEnableReg;
  wire enableWriteCommand = opcodeReg == 2'd0 && addrReg[4:3] == 2'd3;
  wire disableWriteCommand = opcodeReg == 2'd0 && addrReg[4:3] == 2'd0;

  always @(*) begin
    stateNext = stateReg;
    counterNext = counterReg;
    addrNext = addrReg;
    dataNext = dataReg;
    opcodeNext = opcodeReg;
    serialNext = serialReg;
    writeAllNext = writeAllReg;
    writeEnableNext = writeEnableReg;

    if ((stateReg == STATE_COMMAND || stateReg == STATE_SHIFT_IN || stateReg == STATE_SHIFT_OUT)
        && sckRising)
      counterNext = {1'b0, counterReg[16:1]};

    case (stateReg)
      STATE_IDLE: begin
        counterNext = 17'h00080;
        addrNext = 6'h00;
        dataNext = 16'hFFFF;
        serialNext = 1'b1;
        writeAllNext = 1'b0;
        if (io_serial_cs)
          stateNext = STATE_START;
      end

      STATE_START: begin
        if (sckRising && io_serial_sdi)
          stateNext = STATE_COMMAND;
      end

      STATE_COMMAND: begin
        if (sckRising) begin
          opcodeNext = addrReg[5:4];
          addrNext = {addrReg[4:0], io_serial_sdi};

          if (commandDone) begin
            if (readCommand) begin
              counterNext = 17'h10000;
              serialNext = 1'b0;
              stateNext = STATE_READ;
            end
            else if (writeCommand) begin
              counterNext = 17'h08000;
              stateNext = STATE_SHIFT_IN;
            end
            else if (eraseCommand) begin
              stateNext = STATE_WRITE;
            end
            else if (writeAllCommand) begin
              counterNext = 17'h08000;
              addrNext = 6'h00;
              writeAllNext = 1'b1;
              stateNext = STATE_SHIFT_IN;
            end
            else if (eraseAllCommand) begin
              addrNext = 6'h00;
              writeAllNext = 1'b1;
              stateNext = STATE_WRITE;
            end
            else if (enableWriteCommand) begin
              writeEnableNext = 1'b1;
              stateNext = STATE_IDLE;
            end
            else if (disableWriteCommand) begin
              writeEnableNext = 1'b0;
              stateNext = STATE_IDLE;
            end
            else begin
              stateNext = STATE_IDLE;
            end
          end
        end
      end

      STATE_READ: begin
        if (io_mem_valid) begin
          dataNext = io_mem_dout;
          stateNext = STATE_SHIFT_OUT;
        end
        else if (io_mem_wait_n) begin
          stateNext = STATE_READ_WAIT;
        end
      end

      STATE_READ_WAIT: begin
        if (io_mem_valid) begin
          dataNext = io_mem_dout;
          stateNext = STATE_SHIFT_OUT;
        end
      end

      STATE_WRITE: begin
        if (io_mem_wait_n) begin
          addrNext = addrReg + 6'h01;
          if (!writeAllReg || &addrReg)
            stateNext = STATE_IDLE;
        end
      end

      STATE_SHIFT_IN: begin
        if (sckRising) begin
          serialNext = 1'b0;
          dataNext = {dataReg[14:0], io_serial_sdi};
          if (commandDone)
            stateNext = STATE_WRITE;
        end
      end

      STATE_SHIFT_OUT: begin
        if (sckRising) begin
          dataNext = {dataReg[14:0], 1'b0};
          serialNext = dataReg[15];
          if (commandDone)
            stateNext = STATE_IDLE;
        end
      end
    endcase

    if (!io_serial_cs)
      stateNext = STATE_IDLE;
  end

  always @(posedge clock) begin
    if (reset) begin
      stateReg <= STATE_IDLE;
      counterReg <= 17'h00000;
      addrReg <= 6'h00;
      dataReg <= 16'hFFFF;
      opcodeReg <= 2'h0;
      serialReg <= 1'b1;
      writeAllReg <= 1'b0;
      writeEnableReg <= 1'b0;
      sckPrev <= 1'b0;
    end
    else if (ssRestoreWr && ssRestoreData[63:48] == 16'h4545) begin
      stateReg <= ssRestoreData[47:45];
      counterReg <= ssRestoreData[44:28];
      addrReg <= ssRestoreData[27:22];
      dataReg <= ssRestoreData[21:6];
      opcodeReg <= ssRestoreData[5:4];
      serialReg <= ssRestoreData[3];
      writeAllReg <= ssRestoreData[2];
      writeEnableReg <= ssRestoreData[1];
      sckPrev <= ssRestoreData[0];
    end
    else if (!ssStateEnable) begin
      stateReg <= stateNext;
      counterReg <= counterNext;
      addrReg <= addrNext;
      dataReg <= dataNext;
      opcodeReg <= opcodeNext;
      serialReg <= serialNext;
      writeAllReg <= writeAllNext;
      writeEnableReg <= writeEnableNext;
      sckPrev <= io_serial_sck;
    end
  end

  assign io_ss_idle =
    stateReg != STATE_READ &&
    stateReg != STATE_READ_WAIT &&
    stateReg != STATE_WRITE;
  assign ssStateEnable = io_ss_hold & io_ss_idle;

  CaveSaveStateRegisterPort #(
    .WIDTH        (64),
    .COUNT        (1),
    .SS_IDX       (8'd25),
    .STREAM_WIDTH (2'd3)
  ) saveState (
    .clk            (clock),
    .reset          (reset),
    .state_enable   (ssStateEnable),
    .restore_enable (io_ss_restore_enable),
    .capture_data   (ssCaptureData),
    .restore_wr     (ssRestoreWr),
    .restore_addr   (ssRestoreAddr),
    .restore_data   (ssRestoreData),
    .blocked_access (),
    .ssbus          (io_ssbus)
  );

  assign io_mem_rd = stateReg == STATE_READ;
  assign io_mem_wr = stateReg == STATE_WRITE;
  assign io_mem_addr = {addrReg, 1'b0};
  assign io_mem_din = dataReg;
  assign io_serial_sdo = serialReg;

`ifdef CAVE_ESPRADE_SERVICE_DIAGNOSTICS
  reg [7:0]  espradeReadCommandCount = 8'd0;
  reg [7:0]  espradeReadResponseCount = 8'd0;
  reg [3:0]  espradeActiveReadSlot = 4'd0;
  reg [3:0]  espradeShiftBitCount = 4'd0;
  reg        espradeShiftWordDone = 1'b0;
  reg [21:0] espradeReadResponse0 = 22'd0;
  reg [21:0] espradeReadResponse1 = 22'd0;
  reg [21:0] espradeReadResponse2 = 22'd0;
  reg [21:0] espradeReadResponse3 = 22'd0;
  reg [15:0] espradeShiftWord0 = 16'd0;
  reg [15:0] espradeShiftWord1 = 16'd0;
  reg [15:0] espradeShiftWord2 = 16'd0;
  reg [15:0] espradeShiftWord3 = 16'd0;

  always @(posedge clock) begin
    if (reset) begin
      espradeReadCommandCount <= 8'd0;
      espradeReadResponseCount <= 8'd0;
      espradeActiveReadSlot <= 4'd0;
      espradeShiftBitCount <= 4'd0;
      espradeShiftWordDone <= 1'b0;
      espradeReadResponse0 <= 22'd0;
      espradeReadResponse1 <= 22'd0;
      espradeReadResponse2 <= 22'd0;
      espradeReadResponse3 <= 22'd0;
      espradeShiftWord0 <= 16'd0;
      espradeShiftWord1 <= 16'd0;
      espradeShiftWord2 <= 16'd0;
      espradeShiftWord3 <= 16'd0;
    end
    else begin
      if (stateReg == STATE_COMMAND && sckRising &&
          commandDone && readCommand) begin
        espradeActiveReadSlot <= espradeReadCommandCount[3:0];
        espradeReadCommandCount <= espradeReadCommandCount + 8'd1;
      end

      if (io_mem_valid) begin
        espradeReadResponseCount <= espradeReadResponseCount + 8'd1;
        espradeShiftBitCount <= 4'd0;
        espradeShiftWordDone <= 1'b0;
        case (espradeActiveReadSlot)
          4'd0: begin
            espradeReadResponse0 <= {addrReg, io_mem_dout};
            espradeShiftWord0 <= 16'd0;
          end
          4'd1: begin
            espradeReadResponse1 <= {addrReg, io_mem_dout};
            espradeShiftWord1 <= 16'd0;
          end
          4'd2: begin
            espradeReadResponse2 <= {addrReg, io_mem_dout};
            espradeShiftWord2 <= 16'd0;
          end
          4'd3: begin
            espradeReadResponse3 <= {addrReg, io_mem_dout};
            espradeShiftWord3 <= 16'd0;
          end
          default: begin
          end
        endcase
      end

      if (stateReg == STATE_SHIFT_OUT && sckRising &&
          !espradeShiftWordDone) begin
        espradeShiftBitCount <= espradeShiftBitCount + 4'd1;
        if (espradeShiftBitCount == 4'hF)
          espradeShiftWordDone <= 1'b1;
        case (espradeActiveReadSlot)
          4'd0: espradeShiftWord0 <=
            {espradeShiftWord0[14:0], dataReg[15]};
          4'd1: espradeShiftWord1 <=
            {espradeShiftWord1[14:0], dataReg[15]};
          4'd2: espradeShiftWord2 <=
            {espradeShiftWord2[14:0], dataReg[15]};
          4'd3: espradeShiftWord3 <=
            {espradeShiftWord3[14:0], dataReg[15]};
          default: begin
          end
        endcase
      end
    end
  end

  wire [255:0] espradeEepromProbe = {
    16'hE512,
    4'd1,
    {1'b0, stateReg},
    espradeReadResponseCount,
    espradeReadResponse0,
    espradeReadResponse1,
    espradeReadResponse2,
    espradeReadResponse3,
    espradeShiftWord0,
    espradeShiftWord1,
    espradeShiftWord2,
    espradeShiftWord3,
    espradeReadCommandCount,
    espradeShiftWordDone,
    espradeShiftBitCount,
    espradeActiveReadSlot,
    {
      2'd0,
      counterReg,
      addrReg,
      dataReg,
      opcodeReg,
      serialReg,
      writeAllReg,
      writeEnableReg,
      sckPrev,
      io_serial_cs,
      io_serial_sck,
      io_serial_sdi,
      io_serial_sdo,
      io_mem_rd,
      io_mem_wait_n,
      io_mem_valid,
      io_ss_hold
    }
  };
  wire [0:0] espradeEepromSource;

  altsource_probe #(
    .sld_auto_instance_index ("NO"),
    .sld_instance_index      (5),
    .instance_id             ("ESE"),
    .probe_width             (256),
    .source_width            (1),
    .source_initial_value    ("0"),
    .enable_metastability    ("NO")
  ) espradeEepromDiagnosticsProbe (
    .probe  (espradeEepromProbe),
    .source (espradeEepromSource)
  );
`endif
endmodule
