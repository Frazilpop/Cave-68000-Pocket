// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).
//
// Cave 68000 for Analogue Pocket: the register side redone to take writes as
// MAME's ymz280b.cpp does (write_to_register), since the channels now play
// as MAME's do (ChannelController): a key on starts a voice only on the
// rising edge of its key bit with key-on enabled, a key off or the enable
// cleared stops it, setting the enable again restarts the looping voices
// still keyed on, and a mode of 0 reads as key off; and to tell a voice's end
// when MAME does: its timer runs out just after the access that brought the
// stream up to date, or at the sound manager's 20 ms update, and a key on or
// off of the voice before then (or the enable cleared) cancels it. A write
// that comes while the voices are being played waits for them, in a queue:
// sample n is begun at (n + 1) / rate, so MAME, which brings the stream up
// to floor(t * rate) first, has such a write land on sample n + 1, like one
// made between samples; the ends are told after the queue is through. The
// save-state ports are gone (the Pocket has no save states).

// Yamaha YMZ280B: the 68000's side, the voice registers and the status.
module YMZ280B #(
  parameter integer CLOCK_HZ = 32000000,  // the clock, a multiple of 100 Hz
  parameter integer RATE16_INC = 2500,    // ChannelController's
  parameter integer RATE16_DEN = CLOCK_HZ / 100 * 3
) (
  input         clock,
  input         reset,
  input         io_clock16m,          // the chip on 16 MHz (gaia, theroes), not 16.9344
  input         io_pause,             // the board paused: no sample begun
  input         io_cpu_rd,
  input         io_cpu_wr,
  input         io_cpu_addr,
  input  [7:0]  io_cpu_din,
  output [7:0]  io_cpu_dout,
  output        io_rom_rd,
  output [23:0] io_rom_addr,
  input  [7:0]  io_rom_dout,
  input         io_rom_wait_n,
  input         io_rom_valid,
  output        io_audio_valid,
  output [15:0] io_audio,
  output        io_irq,
  output        io_overrun            // a sample was not done when the next was due
);
  reg [7:0]  addrReg;
  reg [7:0]  dataReg;
  reg [7:0]  statusReg;
  reg [7:0]  irqMaskReg;
  reg        irqEnableReg;
  reg        keyOnEnableReg;

  // the voices, as MAME keeps them
  reg [8:0]  fnum      [0:7];
  reg [7:0]  level     [0:7];
  reg [3:0]  pan       [0:7];
  reg        looping   [0:7];
  reg        keyOn     [0:7];
  reg [23:0] startAddr [0:7];
  reg [23:0] loopStart [0:7];
  reg [23:0] loopEnd   [0:7];
  reg [23:0] stopAddr  [0:7];
  reg [7:0]  playing;
  reg [7:0]  restart;               // keyed on, the channel not yet told
  reg [7:0]  ended;                 // at their end, not yet told
  reg        tellPending;           // an access or the 20 ms update, the ends not yet told

  // the data writes, in order, applied while the voices are not being played
  reg [15:0] queue [0:7];
  reg [2:0]  queueWr, queueRd;
  reg [3:0]  queueCount;
  wire       channelBusy;
  wire       writeAddr  = io_cpu_wr & ~io_cpu_addr;
  wire       writeData  = io_cpu_wr & io_cpu_addr;
  wire       readStatus = io_cpu_rd & io_cpu_addr;
  wire       access     = writeData | readStatus;
  wire       update20;

  wire        apply  = !channelBusy && queueCount != 4'd0;
  wire [7:0]  wReg   = queue[queueRd][15:8];
  wire [7:0]  wData  = queue[queueRd][7:0];
  wire        tell   = tellPending && !channelBusy && queueCount == 4'd0;

  wire [2:0] v = wReg[4:2];
  wire [7:0] keyData = (wData[6:5] == 2'd0) ? {1'b0, wData[6:0]} : wData;

  wire       channelEnded;
  wire [2:0] endedIndex;
  wire       restartTaken;
  wire [2:0] restartIndex;

  integer i;
  always @(posedge clock) begin
    if (reset) begin
      addrReg <= 8'h00;
      dataReg <= 8'h00;
      statusReg <= 8'h00;
      irqMaskReg <= 8'h00;
      irqEnableReg <= 1'b0;
      keyOnEnableReg <= 1'b0;
      playing <= 8'h00;
      restart <= 8'h00;
      ended <= 8'h00;
      tellPending <= 1'b0;
      queueWr <= 3'd0;
      queueRd <= 3'd0;
      queueCount <= 4'd0;
      for (i = 0; i < 8; i = i + 1) begin
        fnum[i] <= 9'd0;      level[i] <= 8'd0;     pan[i] <= 4'd0;
        looping[i] <= 1'b0;   keyOn[i] <= 1'b0;
        startAddr[i] <= 24'd0; loopStart[i] <= 24'd0;
        loopEnd[i] <= 24'd0;   stopAddr[i] <= 24'd0;
      end
    end else begin
      // the channels: a voice taken back to its start, a voice at its end
      // (which stops it unless it was keyed on again since)
      if (restartTaken)
        restart[restartIndex] <= 1'b0;
      if (channelEnded && !restart[endedIndex])
        playing[endedIndex] <= 1'b0;

      // the ends found so far told after an access (and its write) or the
      // 20 ms update
      tellPending <= access || update20 || (tellPending && !tell);
      ended <= (tell ? 8'h00 : ended) |
               (channelEnded ? (8'h01 << endedIndex) : 8'h00);

      if (writeAddr)
        addrReg <= io_cpu_din;

      if (readStatus)
        dataReg <= statusReg;
      statusReg <= (readStatus ? 8'h00 : statusReg) | (tell ? ended : 8'h00);

      if (writeData) begin
        queue[queueWr] <= {addrReg, io_cpu_din};
        queueWr <= queueWr + 3'd1;
      end
      if (apply)
        queueRd <= queueRd + 3'd1;
      queueCount <= queueCount + {3'd0, writeData} - {3'd0, apply};

      if (apply) begin
        if (~wReg[7]) begin
          case ({wReg[6:5], wReg[1:0]})
            4'b00_00: fnum[v][7:0] <= wData;
            4'b00_01: begin
              fnum[v][8] <= wData[0];
              looping[v] <= wData[4];
              keyOn[v] <= keyData[7];
              if (!keyOn[v] && keyData[7] && keyOnEnableReg) begin
                playing[v] <= 1'b1;
                restart[v] <= 1'b1;
                ended[v] <= 1'b0;
              end else if (keyOn[v] && !keyData[7]) begin
                playing[v] <= 1'b0;
                ended[v] <= 1'b0;
              end
            end
            4'b00_10: level[v] <= wData;
            4'b00_11: pan[v] <= wData[3:0];
            4'b01_00: startAddr[v][23:16] <= wData;
            4'b01_01: loopStart[v][23:16] <= wData;
            4'b01_10: loopEnd[v][23:16]   <= wData;
            4'b01_11: stopAddr[v][23:16]  <= wData;
            4'b10_00: startAddr[v][15:8]  <= wData;
            4'b10_01: loopStart[v][15:8]  <= wData;
            4'b10_10: loopEnd[v][15:8]    <= wData;
            4'b10_11: stopAddr[v][15:8]   <= wData;
            4'b11_00: startAddr[v][7:0]   <= wData;
            4'b11_01: loopStart[v][7:0]   <= wData;
            4'b11_10: loopEnd[v][7:0]     <= wData;
            4'b11_11: stopAddr[v][7:0]    <= wData;
          endcase
        end else if (wReg == 8'hFE)
          irqMaskReg <= wData;
        else if (wReg == 8'hFF) begin
          irqEnableReg <= wData[4];
          keyOnEnableReg <= wData[7];
          if (keyOnEnableReg && !wData[7]) begin
            playing <= 8'h00;
            ended <= 8'h00;
          end
          else if (!keyOnEnableReg && wData[7])
            for (i = 0; i < 8; i = i + 1)
              if (keyOn[i] && looping[i])
                playing[i] <= 1'b1;
        end
      end
    end
  end

  // what the channel controller reads of the voice it is on
  wire [2:0] ch;
  ChannelController #(
    .CLOCK_HZ (CLOCK_HZ), .RATE16_INC (RATE16_INC), .RATE16_DEN (RATE16_DEN)
  ) channelCtrl (
    .clock          (clock),
    .reset          (reset),
    .io_clock16m    (io_clock16m),
    .io_access      (access),
    .io_update      (update20),
    .io_hold        (queueCount != 4'd0),
    .io_pause       (io_pause),
    .io_busy        (channelBusy),
    .io_index       (ch),
    .io_fnum        (fnum[ch]),
    .io_level       (level[ch]),
    .io_pan         (pan[ch]),
    .io_looping     (looping[ch]),
    .io_keyOn       (keyOn[ch]),
    .io_playing     (playing[ch]),
    .io_restart     (restart[ch]),
    .io_startAddr   (startAddr[ch]),
    .io_loopStart   (loopStart[ch]),
    .io_loopEnd     (loopEnd[ch]),
    .io_stopAddr    (stopAddr[ch]),
    .io_restartTaken(restartTaken),
    .io_restartIndex(restartIndex),
    .io_ended       (channelEnded),
    .io_endedIndex  (endedIndex),
    .io_audio_valid (io_audio_valid),
    .io_audio       (io_audio),
    .io_overrun     (io_overrun),
    .io_rom_rd      (io_rom_rd),
    .io_rom_addr    (io_rom_addr),
    .io_rom_dout    (io_rom_dout),
    .io_rom_wait_n  (io_rom_wait_n),
    .io_rom_valid   (io_rom_valid)
  );

  assign io_cpu_dout = dataReg;
  assign io_irq = irqEnableReg & (|(statusReg & irqMaskReg));
endmodule
