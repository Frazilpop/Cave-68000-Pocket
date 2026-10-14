// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).
//
// Cave 68000 for Analogue Pocket: rewritten to play the voices as MAME's
// ymz280b.cpp does, sample for sample, since upstream's differed from it in
// the loop and end points (taken one byte late), the ADPCM rounding, a key
// on (which cleared the interpolation), the level ((level + 1) / 512 against
// MAME's level / 256) and the pan; and to keep the output rate exact (the
// chip's clock / 192, by a fractional counter, for either chip clock) where
// upstream divided its clock by 363. Upstream's AudioPipeline, AudioMixer
// and the save-state ports are gone.

// YMZ280B: the eight voices, one after another, once per output sample.
//
// MAME plays the chip in stream updates: one before every register write
// and status read the 68000 makes (a register select is not one) and one
// every 20 ms of machine time from the sound manager. Three things happen
// only at an update's start or end, so the board keeps the same points (an
// access marks the next sample begun – a write made while the voices are
// being played waits for them, YMZ280B.sv – and the 20 ms count from reset
// the next sample after it):
//
//   * a voice found not playing with its last two samples zero at an
//     update's start is silent until the next, its interpolation point back
//     at 1 (so a key on starts afresh); one that falls silent within an
//     update goes on being stepped through zeros;
//   * after a sample's end, the samples taken are the last one times 15/16,
//     again and again (MAME's ramp to zero), to the end of the update; then
//     zeros;
//   * the end is told (the status bit, the IRQ) just after the access that
//     ended the update and its write, or at the 20 ms update (io_update;
//     YMZ280B.sv).
//
// Per voice and sample, as MAME's sound_stream_update:
//
//   * unless silent, the output is prev + (curr - prev) * pos / 512 and pos
//     advances by fnum + 1; when it passes 512 the next sample is taken –
//     decoded from the ROM while the voice plays, else 0, or the ramp – and,
//     when the point was at 1 already, the taking comes first;
//   * the output, times the left and the right level (MAME's update_volumes)
//     and halved, is added to the sample. The sum over the voices and both
//     sides, divided by 256, is the mono speaker MAME mixes (16 bits).
//
// The 4-bit ADPCM as MAME decodes it: positions count nibbles, high nibble
// first; the loop start is remembered the first time through, the loop end
// and the end are exclusive, and the loop is taken only while keyed on. The
// 8- and 16-bit PCM modes play as ADPCM (no game of this board uses them).
module ChannelController #(
  parameter integer CLOCK_HZ = 32000000,
  // the 16 MHz chip's rate as RATE16_INC / RATE16_DEN a clock: by default
  // 83333.3 Hz; sim/ymz280b sets MAME's whole 83333 to hold gaia to MAME's
  // 20 ms updates sample for sample
  parameter integer RATE16_INC = 2500,
  parameter integer RATE16_DEN = CLOCK_HZ / 100 * 3
) (
  input         clock,
  input         reset,
  input         io_clock16m,
  input         io_access,         // a register write or status read: MAME's update
  output        io_update,         // MAME's 20 ms update
  input         io_hold,           // writes waiting: begin no sample
  input         io_pause,          // the board paused: the chip's time stands still
  output        io_busy,           // the voices being played
  output [2:0]  io_index,          // the voice whose registers are read
  input  [8:0]  io_fnum,
  input  [7:0]  io_level,
  input  [3:0]  io_pan,
  input         io_looping,
  input         io_keyOn,
  input         io_playing,
  input         io_restart,
  input  [23:0] io_startAddr,
  input  [23:0] io_loopStart,
  input  [23:0] io_loopEnd,
  input  [23:0] io_stopAddr,
  output        io_restartTaken,
  output [2:0]  io_restartIndex,
  output        io_ended,
  output [2:0]  io_endedIndex,
  output        io_audio_valid,
  output [15:0] io_audio,
  output        io_overrun,
  output        io_rom_rd,
  output [23:0] io_rom_addr,
  input  [7:0]  io_rom_dout,
  input         io_rom_wait_n,
  input         io_rom_valid
);
  // ---------------------------------------------------------- the sample rate
  // clock / 192 of a 16.9344 or a 16 MHz chip, in steps of 6400 Hz of chip
  // clock: 2646 or 2500 a clock against 192 * CLOCK_HZ / 6400
  localparam integer RATE_DEN = CLOCK_HZ / 100 * 3;
  reg  [31:0] rateAcc;
  wire [31:0] rateInc = io_clock16m ? RATE16_INC : 32'd2646;
  wire [31:0] rateDen = io_clock16m ? RATE16_DEN : RATE_DEN;
  wire [31:0] rateSum = rateAcc + rateInc;
  wire        tick = !io_pause && rateSum >= rateDen;
  reg         tickPending;

  // ------------------------------------------------- MAME's stream updates
  localparam integer UPDATE_CLOCKS = CLOCK_HZ / 50;
  reg  [31:0] updateCount;
  wire        update20 = !io_pause && updateCount == UPDATE_CLOCKS - 1;
  reg         boundary;            // an update since the last sample begun
  reg         updateStart;         // this sample begins an update

  // ------------------------------------------------------------ the voices
  // position (nibbles, 25), signal, step, the loop's signal and step, looped,
  // prev, curr, the interpolation point (10), ramping
  reg [24:0] vPosition   [0:7];
  reg [15:0] vSignal     [0:7];
  reg [14:0] vStep       [0:7];
  reg [15:0] vLoopSignal [0:7];
  reg [14:0] vLoopStep   [0:7];
  reg        vLooped     [0:7];
  reg [15:0] vPrev       [0:7];
  reg [15:0] vCurr       [0:7];
  reg [9:0]  vPos        [0:7];
  reg        vRamp       [0:7];
  reg        vSilent     [0:7];

  localparam [3:0] S_IDLE   = 4'd0,
                   S_LATCH  = 4'd1,
                   S_CHECK  = 4'd2,
                   S_TAKE   = 4'd3,
                   S_FETCH  = 4'd4,
                   S_SHIFT  = 4'd5,
                   S_EMIT2  = 4'd6,
                   S_LEVEL  = 4'd7,
                   S_SUM    = 4'd8,
                   S_WRITE  = 4'd9;
  reg [3:0]  state;
  reg [2:0]  index;

  // the voice being played
  reg [24:0] position;
  reg signed [15:0] signal, loopSignal;
  reg [14:0] step, loopStep;
  reg        looped;
  reg signed [15:0] prev, curr;
  reg [9:0]  pos;
  reg        ramp;
  reg        playing;
  reg        emitted;
  reg        ended;
  reg        silent;
  reg signed [15:0] interp;
  reg signed [15:0] next;
  reg signed [24:0] left, right;
  reg signed [28:0] acc;
  reg [15:0] audioReg;
  reg        audioValidReg;
  reg        overrunReg;
  reg        romPending;

  // ---------------------------------------------------------- the datapath
  // prev + floor((curr - prev) * pos / 512): MAME's (prev * (512 - pos) +
  // curr * pos) >> 9
  wire signed [16:0] slope = {curr[15], curr} - {prev[15], prev};
  wire signed [27:0] slopePos = slope * $signed({1'b0, pos});
  wire signed [15:0] lerp = 16'(prev + 16'(slopePos >>> 9));

  // MAME's update_volumes
  wire [10:0] panScaled = {3'd0, io_level} *
                          (io_pan < 4'd8 ? {7'd0, io_pan - 4'd1} : {7'd0, 4'd15 - io_pan});
  wire [7:0]  panLevel = 8'(({13'd0, panScaled} * 24'd1171) >> 13);    // / 7, exact to 1530
  wire [7:0]  volLeft  = (io_pan <= 4'd8) ? io_level : panLevel;
  wire [7:0]  volRight = (io_pan >= 4'd8) ? io_level :
                         (io_pan == 4'd0) ? 8'd0 : panLevel;

  // trunc(interp * vol / 2), as C divides
  wire signed [24:0] prodLeft  = interp * $signed({1'b0, volLeft});
  wire signed [24:0] prodRight = interp * $signed({1'b0, volRight});
  wire signed [24:0] halfLeft  = (prodLeft  + (prodLeft[24]  ? 25'sd1 : 25'sd0)) >>> 1;
  wire signed [24:0] halfRight = (prodRight + (prodRight[24] ? 25'sd1 : 25'sd0)) >>> 1;

  // the ADPCM nibble at the position, high first
  wire [3:0]  nibble = position[0] ? io_rom_dout[3:0] : io_rom_dout[7:4];
  wire [3:0]  diffMag = {nibble[2:0], 1'b1};                       // 1, 3 .. 15
  wire signed [20:0] diffProd = $signed({1'b0, step}) * $signed({1'b0, diffMag});
  wire signed [20:0] delta = nibble[3] ? -(diffProd >>> 3) : (diffProd >>> 3);  // trunc(step * diff / 8)
  wire signed [17:0] signalSum = {{2{signal[15]}}, signal} + 18'(delta);
  wire signed [15:0] newSignal = signalSum > 18'sd32767 ? 16'sd32767 :
                                 signalSum < -18'sd32768 ? -16'sd32768 : signalSum[15:0];
  reg  [9:0]  indexScale;
  always @(*) begin
    case (nibble[2:0])
      3'd4:    indexScale = 10'h133;
      3'd5:    indexScale = 10'h199;
      3'd6:    indexScale = 10'h200;
      3'd7:    indexScale = 10'h266;
      default: indexScale = 10'h0e6;
    endcase
  end
  wire [24:0] stepProd = step * indexScale;
  wire [16:0] stepScaled = stepProd[24:8];
  wire [14:0] newStep = stepScaled > 17'h6000 ? 15'h6000 :
                        stepScaled < 17'h007f ? 15'h007f : stepScaled[14:0];

  // the position after the nibble, the loop and the end, as MAME's
  // generate_adpcm takes them
  wire [24:0] position1   = position + 25'd1;
  wire [24:0] loopStart2  = {io_loopStart, 1'b0};
  wire [24:0] loopEnd2    = {io_loopEnd, 1'b0};
  wire [24:0] stop2       = {io_stopAddr, 1'b0};
  wire        atLoopStart = io_looping && position1 == loopStart2 && !looped;
  wire        takeLoop    = io_looping && position1 >= loopEnd2 && io_keyOn;
  wire [24:0] position2   = takeLoop ? loopStart2 : position1;
  wire        atEnd       = position2 >= stop2;

  // MAME's ramp to zero: t * 15 / 16, towards zero
  wire signed [16:0] curr17 = curr;
  wire [16:0] currMag = curr17[16] ? 17'(-curr17) : 17'(curr17);
  wire [19:0] rampMag = {3'd0, currMag} * 20'd15;
  wire signed [15:0] rampNext = curr[15] ? -$signed({1'b0, rampMag[18:4]}) : $signed({1'b0, rampMag[18:4]});

  // the output: the sum over 256, towards zero, held to 16 bits
  wire signed [28:0] accOut = (acc + (acc[28] ? 29'sd255 : 29'sd0)) >>> 8;
  wire [15:0] audioOut = accOut > 29'sd32767 ? 16'h7fff :
                         accOut < -29'sd32768 ? 16'h8000 : accOut[15:0];

  wire [9:0] stepSize = (io_fnum[7:0] + 10'd1);   // ADPCM: fnum & 0xff, + 1

  integer i;
  always @(posedge clock) begin
    if (reset) begin
      state <= S_IDLE;
      index <= 3'd0;
      rateAcc <= 32'd0;
      tickPending <= 1'b0;
      acc <= 29'sd0;
      audioReg <= 16'h0000;
      audioValidReg <= 1'b0;
      overrunReg <= 1'b0;
      romPending <= 1'b0;
      updateCount <= 32'd0;
      boundary <= 1'b0;
      updateStart <= 1'b0;
      for (i = 0; i < 8; i = i + 1) begin
        vPosition[i] <= 25'd0;  vSignal[i] <= 16'd0;  vStep[i] <= 15'h7f;
        vLoopSignal[i] <= 16'd0; vLoopStep[i] <= 15'h7f; vLooped[i] <= 1'b0;
        vPrev[i] <= 16'd0;  vCurr[i] <= 16'd0;  vPos[i] <= 10'd512;  vRamp[i] <= 1'b0;
        vSilent[i] <= 1'b1;
      end
    end else begin
      audioValidReg <= 1'b0;
      overrunReg <= 1'b0;
      // paused (the Pocket's menu, with the 68000 halted), no sample is
      // begun and the 20 ms updates wait: the one under way is finished, the
      // output holds it, and the music takes up where it was
      if (!io_pause) begin
        rateAcc <= tick ? rateSum - rateDen : rateSum;
        updateCount <= update20 ? 32'd0 : updateCount + 32'd1;
      end
      if (io_access || update20)
        boundary <= 1'b1;
      if (tick) begin
        tickPending <= 1'b1;
        if (tickPending || state != S_IDLE)
          overrunReg <= 1'b1;
      end

      case (state)
        S_IDLE:
          if ((tickPending || tick) && !io_hold) begin
            // the last sample out, the next begun
            tickPending <= 1'b0;
            audioReg <= audioOut;
            audioValidReg <= 1'b1;
            acc <= 29'sd0;
            index <= 3'd0;
            // an access now still comes before the sample; the 20 ms
            // update falls at its start, so after it
            updateStart <= boundary || io_access;
            boundary <= update20;
            state <= S_LATCH;
          end

        S_LATCH: begin
          // a key on since: the decoder back to the start (MAME keeps the
          // interpolation going)
          if (io_restart) begin
            position <= {io_startAddr, 1'b0};
            signal <= 16'sd0;  loopSignal <= 16'sd0;
            step <= 15'h7f;    loopStep <= 15'h7f;
            looped <= 1'b0;
          end else begin
            position <= vPosition[index];
            signal <= vSignal[index];  loopSignal <= vLoopSignal[index];
            step <= vStep[index];      loopStep <= vLoopStep[index];
            looped <= vLooped[index];
          end
          prev <= vPrev[index];
          curr <= vCurr[index];
          pos <= vPos[index];
          ramp <= vRamp[index] & ~io_playing & ~updateStart;
          playing <= io_playing;
          // silent from an update's start to its end
          silent <= updateStart ? (!io_playing && vPrev[index] == 16'd0 && vCurr[index] == 16'd0)
                                : vSilent[index];
          ended <= 1'b0;
          state <= S_CHECK;
        end

        S_CHECK: begin
          emitted <= 1'b0;
          if (silent) begin
            pos <= 10'd512;
            state <= S_WRITE;
          end else if (pos < 10'd512) begin
            interp <= lerp;
            emitted <= 1'b1;
            pos <= pos + stepSize;
            state <= (pos + stepSize >= 10'd512) ? S_TAKE : S_LEVEL;
          end else
            state <= S_TAKE;
        end

        S_TAKE: begin
          pos <= pos - 10'd512;
          if (playing)
            state <= S_FETCH;
          else begin
            next <= ramp ? rampNext : 16'sd0;
            if (ramp && rampNext == 16'sd0)
              ramp <= 1'b0;
            state <= S_SHIFT;
          end
        end

        S_FETCH:
          if (io_rom_valid && romPending) begin
            next <= newSignal;
            signal <= newSignal;
            step <= newStep;
            if (atLoopStart) begin
              loopSignal <= newSignal;
              loopStep <= newStep;
            end
            if (takeLoop) begin
              signal <= atLoopStart ? newSignal : loopSignal;
              step <= atLoopStart ? newStep : loopStep;
              looped <= 1'b1;
            end
            position <= position2;
            if (atEnd) begin
              ended <= 1'b1;
              playing <= 1'b0;
              ramp <= 1'b1;
            end
            state <= S_SHIFT;
          end

        S_SHIFT: begin
          prev <= curr;
          curr <= next;
          state <= emitted ? S_LEVEL : S_EMIT2;
        end

        S_EMIT2: begin
          interp <= lerp;
          pos <= pos + stepSize;
          state <= S_LEVEL;
        end

        S_LEVEL: begin
          left <= halfLeft;
          right <= halfRight;
          state <= S_SUM;
        end

        S_SUM: begin
          acc <= acc + 29'(left) + 29'(right);
          state <= S_WRITE;
        end

        S_WRITE: begin
          vPosition[index] <= position;
          vSignal[index] <= signal;  vLoopSignal[index] <= loopSignal;
          vStep[index] <= step;      vLoopStep[index] <= loopStep;
          vLooped[index] <= looped;
          vPrev[index] <= prev;
          vCurr[index] <= curr;
          vPos[index] <= pos;
          vRamp[index] <= ramp;
          vSilent[index] <= silent;
          index <= index + 3'd1;
          state <= (index == 3'd7) ? S_IDLE : S_LATCH;
        end

        default:
          state <= S_IDLE;
      endcase

      // the ROM: one read at a time, taken when wait_n allows
      if (io_rom_rd && io_rom_wait_n)
        romPending <= 1'b1;
      if (io_rom_valid)
        romPending <= 1'b0;
    end
  end

  assign io_update = update20;
  assign io_busy = state != S_IDLE;
  assign io_index = index;
  assign io_restartTaken = state == S_LATCH && io_restart;
  assign io_restartIndex = index;
  assign io_ended = state == S_WRITE && ended;
  assign io_endedIndex = index;
  assign io_audio_valid = audioValidReg;
  assign io_audio = audioReg;
  assign io_overrun = overrunReg;
  assign io_rom_rd = state == S_FETCH && !romPending;
  assign io_rom_addr = position[24:1];
endmodule
