// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — DonPachi's sound: two OKI M6295s behind
// the NMK112, as MAME has them (okim6295.cpp, okiadpcm.cpp, nmk112.cpp at
// 0.289; cave.cpp's donpachi machine), in place of Sound's YMZ280B.
//
// The chips. OKI 0 runs on 4.220 MHz / 4, OKI 1 on 4.220 MHz / 2, pin 7 high:
// a sample every 132 clocks, which MAME makes whole rates, 7,992 and 15,984
// Hz. Sample n of a chip is begun at (n + 1) / rate, counted on clk_cpu from
// reset (999 / 2,000,000 a 32 MHz clock for OKI 1; OKI 0 every other one of
// its samples): MAME brings a chip's stream up to sample floor(t * rate)
// before it takes an access at t, so an access on the clock a sample is
// begun lands after it. A command byte with bit 7 picks a phrase; the next
// starts it on the voices in its top nibble that are not playing, at the
// volume in its low nibble, if the phrase table's start is below its stop; a
// byte without bit 7 (no phrase pending) stops the voices in bits 3-6. A
// voice plays a nibble a sample, high nibble first, through the OKI ADPCM,
// times its volume (0x20 = 0 dB), and stops after 2 * (stop - start + 1)
// nibbles. A chip's sample is the sum of its voices, MAME's value * 32 *
// 2048.
//
// The NMK112: eight bank registers, four a chip, each picking the 64 KB page
// of one quarter of the chip's 256 KB; OKI 1's phrase table (its first 1 KB)
// is paged by the same registers a 256-byte quarter at a time (OKI 0 is not
// paged). Pages are data & 31 on OKI 0 and data & 63 on OKI 1; the image
// (tools/pocket/build_rom.py) holds OKI 0's 2 MB and then OKI 1's 4 MB with
// MAME's fold of pages 48-63 onto 32-47 already made, so a page is page * 64
// KB. A bank write takes effect at once; MAME's lands at the chip's next
// stream update instead (an access or its 20 ms update), which is the same
// unless a voice is playing out of the quarter switched.
//
// One engine plays everything, in the order it happened: each sample begun,
// each command byte, each bank write goes into a queue, and the engine takes
// them one at a time – a sample reads a byte for each voice playing, a start
// the phrase's six table bytes, through the one ROM port. The status the
// 68000 reads cannot wait for that, so it is kept apart, as MAME would
// answer at that moment: a start sets its voices' bits at the write, a stop
// clears them, and a sample begun clears those of the voices it ends (known
// from the engine's counts before the sample is played). A phrase whose
// start is not below its stop (MAME plays nothing) leaves its bits set until
// the engine finds it out, a few clocks later.
//
// The output: OKI 0 at 1.6 and OKI 1 at 1.0 (cave.cpp's routes) into MAME's
// 16-bit speaker, 0.8 and 0.5 of the sums (0.8 as 205 / 256), clamped; held,
// and strobed at 88,200 Hz (2646 / 960,000 a clock) for the shell's
// resampler, which takes the YMZ280B's rate.

`default_nettype none

module SoundOki (
  input  wire        clock,           // clk_cpu, 32 MHz
  input  wire        reset,
  input  wire        io_pause,        // the board paused: no sample begun
  input  wire        io_oki_0_wr,
  input  wire [7:0]  io_oki_0_din,
  output wire [7:0]  io_oki_0_dout,
  input  wire        io_oki_1_wr,
  input  wire [7:0]  io_oki_1_din,
  output wire [7:0]  io_oki_1_dout,
  input  wire        io_nmk_wr,
  input  wire [2:0]  io_nmk_addr,
  input  wire [7:0]  io_nmk_din,
  output wire        io_rom_rd,
  output wire [24:0] io_rom_addr,     // byte address in the sample region
  input  wire [7:0]  io_rom_dout,
  input  wire        io_rom_wait_n,
  input  wire        io_rom_valid,
  output reg  [15:0] io_audio,        // held between strobes
  output reg         io_audio_valid,  // 88,200 Hz
  output reg         io_overrun,      // the queue overflowed or a sample came late
  // each chip's sample as it is made, for the harness
  output reg         io_sample_valid_0,
  output reg         io_sample_valid_1,
  output reg  signed [19:0] io_sample_0,
  output reg  signed [19:0] io_sample_1
);

  // ----------------------------------------------------------- the rates
  reg  [20:0] rateAcc;                // OKI 1's samples: 999 / 2,000,000
  reg         okiPhase;               // OKI 0 on every other one
  wire [20:0] rateNext = rateAcc + 21'd999;
  wire        tick1 = !io_pause && rateNext >= 21'd2000000;
  wire        tick0 = tick1 && okiPhase;

  reg  [19:0] outAcc;                 // the output strobe: 2646 / 960,000
  wire [19:0] outNext = outAcc + 20'd2646;

  // --------------------------------------------------- the voices' state
  reg         vPlaying [0:7];         // index {chip, voice}
  reg  [17:0] vBase    [0:7];
  reg  [19:0] vSample  [0:7];
  reg  [19:0] vCount   [0:7];
  reg  [5:0]  vVolume  [0:7];
  reg  signed [11:0] vSignal [0:7];
  reg  [5:0]  vStep    [0:7];
  reg  [7:0]  bank     [0:7];         // the NMK112
  reg  [6:0]  command  [0:1];         // the phrase picked, if commandSet
  reg  [1:0]  commandSet;

  // ---------------------------------------------- the status, kept apart
  reg  [3:0]  busy [0:1];             // what a status read answers
  reg  [3:0]  pendingStart [0:1];     // started, not yet taken by the engine
  reg  [1:0]  statusCommandSet;

  // the voices a sample begun now ends: playing, and this nibble their last
  function automatic [3:0] endsNow(input c);
    integer k;
    begin
      for (k = 0; k < 4; k = k + 1)
        endsNow[k] = vPlaying[{c, k[1:0]}] &&
                     (vSample[{c, k[1:0]}] + 20'd1 >= vCount[{c, k[1:0]}]);
    end
  endfunction

  wire [3:0] end0 = tick0 ? (endsNow(1'b0) & ~pendingStart[0]) : 4'h0;
  wire [3:0] end1 = tick1 ? (endsNow(1'b1) & ~pendingStart[1]) : 4'h0;

  // a read on the clock a sample is begun sees it begun
  assign io_oki_0_dout = {4'hf, busy[0] & ~end0};
  assign io_oki_1_dout = {4'hf, busy[1] & ~end1};

  // ------------------------------------------------------------ the queue
  // {kind, which, data}: kind 0 a sample begun (which[1:0]: the chips), 1 a
  // command byte (which[0]: the chip), 2 a bank write (which: the register)
  localparam [1:0] Q_TICK = 2'd0, Q_CMD = 2'd1, Q_BANK = 2'd2;
  reg  [12:0] queue [0:15];
  reg  [3:0]  qWr, qRd;
  reg  [4:0]  qCount;

  wire        pushTick = tick1;
  wire        pushAcc  = io_oki_0_wr || io_oki_1_wr || io_nmk_wr;
  wire [12:0] tickEntry = {Q_TICK, 1'b0, tick1, tick0, 8'h00};
  wire [12:0] accEntry  = io_nmk_wr   ? {Q_BANK, io_nmk_addr, io_nmk_din} :
                          io_oki_1_wr ? {Q_CMD, 3'd1, io_oki_1_din} :
                                        {Q_CMD, 3'd0, io_oki_0_din};

  // ----------------------------------------------------------- the engine
  localparam [2:0] S_IDLE = 3'd0, S_VOICE = 3'd1, S_READ = 3'd2,
                   S_TABLE = 3'd3, S_START = 3'd4;
  reg  [2:0]  state;
  reg  [12:0] ev;                     // the entry being played
  reg         chip;
  reg  [1:0]  voice;
  reg         tickBoth;               // both chips to play for this sample
  reg  signed [19:0] acc;
  reg  [2:0]  tableIndex;
  reg  [47:0] phraseBytes;            // the phrase's six table bytes
  reg  [17:0] readAddr;               // the chip's own address
  reg         romPending;

  wire [2:0]  vi = {chip, voice};
  wire        pop = state == S_IDLE && qCount != 5'd0;

  // the NMK112: the chip's address to the image's
  wire [1:0]  quarter  = readAddr[17:16];
  wire        inTable  = readAddr[17:10] == 8'h00;
  wire [7:0]  bankReg0 = bank[{1'b0, quarter}];
  wire [7:0]  bankReg1 = bank[{1'b1, inTable ? readAddr[9:8] : quarter}];
  wire [24:0] mapped   = chip ? (25'h200000 + {3'd0, bankReg1[5:0], readAddr[15:0]})
                              : {4'd0, bankReg0[4:0], readAddr[15:0]};

  // the ADPCM step size, floor(16 * 1.1^step)
  function automatic [10:0] stepval(input [5:0] s);
    case (s)
      6'd0: stepval = 11'd16;    6'd1: stepval = 11'd17;    6'd2: stepval = 11'd19;
      6'd3: stepval = 11'd21;    6'd4: stepval = 11'd23;    6'd5: stepval = 11'd25;
      6'd6: stepval = 11'd28;    6'd7: stepval = 11'd31;    6'd8: stepval = 11'd34;
      6'd9: stepval = 11'd37;    6'd10: stepval = 11'd41;   6'd11: stepval = 11'd45;
      6'd12: stepval = 11'd50;   6'd13: stepval = 11'd55;   6'd14: stepval = 11'd60;
      6'd15: stepval = 11'd66;   6'd16: stepval = 11'd73;   6'd17: stepval = 11'd80;
      6'd18: stepval = 11'd88;   6'd19: stepval = 11'd97;   6'd20: stepval = 11'd107;
      6'd21: stepval = 11'd118;  6'd22: stepval = 11'd130;  6'd23: stepval = 11'd143;
      6'd24: stepval = 11'd157;  6'd25: stepval = 11'd173;  6'd26: stepval = 11'd190;
      6'd27: stepval = 11'd209;  6'd28: stepval = 11'd230;  6'd29: stepval = 11'd253;
      6'd30: stepval = 11'd279;  6'd31: stepval = 11'd307;  6'd32: stepval = 11'd337;
      6'd33: stepval = 11'd371;  6'd34: stepval = 11'd408;  6'd35: stepval = 11'd449;
      6'd36: stepval = 11'd494;  6'd37: stepval = 11'd544;  6'd38: stepval = 11'd598;
      6'd39: stepval = 11'd658;  6'd40: stepval = 11'd724;  6'd41: stepval = 11'd796;
      6'd42: stepval = 11'd876;  6'd43: stepval = 11'd963;  6'd44: stepval = 11'd1060;
      6'd45: stepval = 11'd1166; 6'd46: stepval = 11'd1282; 6'd47: stepval = 11'd1411;
      default: stepval = 11'd1552;
    endcase
  endfunction

  // the voice's next nibble through the ADPCM
  wire [3:0]  nibble   = vSample[vi][0] ? io_rom_dout[3:0] : io_rom_dout[7:4];
  wire [10:0] sv       = stepval(vStep[vi]);
  wire [12:0] mag      = (nibble[2] ? {2'd0, sv} : 13'd0) +
                         (nibble[1] ? {3'd0, sv[10:1]} : 13'd0) +
                         (nibble[0] ? {4'd0, sv[10:2]} : 13'd0) +
                         {5'd0, sv[10:3]};
  wire signed [13:0] sum = {{2{vSignal[vi][11]}}, vSignal[vi]} +
                           (nibble[3] ? -$signed({1'b0, mag}) : $signed({1'b0, mag}));
  wire signed [11:0] newSignal = (sum > 14'sd2047)  ? 12'sd2047 :
                                 (sum < -14'sd2048) ? 12'h800 : sum[11:0];
  wire signed [7:0]  shift = nibble[2] ? $signed({5'd0, nibble[1:0], 1'b0} + 8'd2) : -8'sd1;
  wire signed [7:0]  stepSum = $signed({2'b00, vStep[vi]}) + shift;
  wire [5:0]  newStep = (stepSum > 8'sd48) ? 6'd48 : (stepSum < 8'sd0) ? 6'd0 : stepSum[5:0];
  wire signed [18:0] product = newSignal * $signed({1'b0, vVolume[vi]});

  // the phrase's start and stop, and which voices it starts
  wire [17:0] phraseStart = {phraseBytes[41:40], phraseBytes[39:32], phraseBytes[31:24]};
  wire [17:0] phraseStop  = {phraseBytes[17:16], phraseBytes[15:8], phraseBytes[7:0]};
  wire [3:0]  startMask   = ev[7:4];
  wire [18:0] phraseLength = {1'b0, phraseStop} - {1'b0, phraseStart} + 19'd1;
  wire        phraseNone  = !(phraseStart < phraseStop);

  // the mix: OKI 0 * 0.8 + OKI 1 * 0.5, clamped
  wire signed [27:0] mix0 = io_sample_0 * 28'sd205;
  wire signed [20:0] mix  = $signed(mix0[27:8]) + $signed({io_sample_1[19], io_sample_1[19:1]});
  wire [15:0] mixClamped  = (mix > 21'sd32767) ? 16'h7fff : (mix < -21'sd32768) ? 16'h8000 : mix[15:0];

  integer i;
  always @(posedge clock) begin
    io_audio_valid <= 1'b0;
    io_sample_valid_0 <= 1'b0;
    io_sample_valid_1 <= 1'b0;
    io_overrun <= 1'b0;
    if (reset) begin
      rateAcc <= 21'd0;
      okiPhase <= 1'b0;
      outAcc <= 20'd0;
      for (i = 0; i < 8; i = i + 1) begin
        vPlaying[i] <= 1'b0;  vBase[i] <= 18'd0;   vSample[i] <= 20'd0;
        vCount[i] <= 20'd0;   vVolume[i] <= 6'd0;  vSignal[i] <= 12'sd0;
        vStep[i] <= 6'd0;     bank[i] <= 8'd0;
      end
      command[0] <= 7'd0;  command[1] <= 7'd0;  commandSet <= 2'b00;
      busy[0] <= 4'h0;     busy[1] <= 4'h0;
      pendingStart[0] <= 4'h0;  pendingStart[1] <= 4'h0;
      statusCommandSet <= 2'b00;
      qWr <= 4'd0;  qRd <= 4'd0;  qCount <= 5'd0;
      state <= S_IDLE;
      romPending <= 1'b0;
      io_audio <= 16'h0000;
      io_sample_0 <= 20'sd0;
      io_sample_1 <= 20'sd0;
    end else begin
      // ------------------------------------------------------ the rates
      if (!io_pause) begin
        rateAcc <= tick1 ? rateNext - 21'd2000000 : rateNext;
        if (tick1)
          okiPhase <= ~okiPhase;
      end
      outAcc <= (outNext >= 20'd960000) ? outNext - 20'd960000 : outNext;
      if (outNext >= 20'd960000) begin
        io_audio <= mixClamped;
        io_audio_valid <= 1'b1;
      end

      // ------------------------------------------------------ the status
      // the sample begun first, then the access
      begin : status
        reg [3:0] b0, b1, p0, p1;
        reg [1:0] cs;
        b0 = busy[0] & ~end0;
        b1 = busy[1] & ~end1;
        p0 = pendingStart[0];
        p1 = pendingStart[1];
        cs = statusCommandSet;
        // a start the engine has taken: no longer pending, and if the phrase
        // plays nothing, its voices not busy after all
        if (state == S_START && !chip) begin
          if (phraseNone)
            b0 = b0 & ~(startMask & p0);
          p0 = p0 & ~startMask;
        end
        if (state == S_START && chip) begin
          if (phraseNone)
            b1 = b1 & ~(startMask & p1);
          p1 = p1 & ~startMask;
        end
        if (io_oki_0_wr) begin
          if (cs[0]) begin
            p0 = p0 | (io_oki_0_din[7:4] & ~b0);
            b0 = b0 | io_oki_0_din[7:4];
            cs[0] = 1'b0;
          end else if (io_oki_0_din[7])
            cs[0] = 1'b1;
          else
            b0 = b0 & ~io_oki_0_din[6:3];
        end
        if (io_oki_1_wr) begin
          if (cs[1]) begin
            p1 = p1 | (io_oki_1_din[7:4] & ~b1);
            b1 = b1 | io_oki_1_din[7:4];
            cs[1] = 1'b0;
          end else if (io_oki_1_din[7])
            cs[1] = 1'b1;
          else
            b1 = b1 & ~io_oki_1_din[6:3];
        end
        busy[0] <= b0;
        busy[1] <= b1;
        pendingStart[0] <= p0;
        pendingStart[1] <= p1;
        statusCommandSet <= cs;
      end

      // ------------------------------------------------------- the queue
      if (pushTick && pushAcc) begin
        queue[qWr] <= tickEntry;
        queue[qWr + 4'd1] <= accEntry;
        qWr <= qWr + 4'd2;
      end else if (pushTick) begin
        queue[qWr] <= tickEntry;
        qWr <= qWr + 4'd1;
      end else if (pushAcc) begin
        queue[qWr] <= accEntry;
        qWr <= qWr + 4'd1;
      end
      qCount <= qCount + {4'd0, pushTick} + {4'd0, pushAcc} - {4'd0, pop};
      if (qCount + {4'd0, pushTick} + {4'd0, pushAcc} > 5'd16)
        io_overrun <= 1'b1;
      if (pop)
        qRd <= qRd + 4'd1;

      // ------------------------------------------------------ the engine
      case (state)
        S_IDLE:
          if (pop) begin
            ev <= queue[qRd];
            case (queue[qRd][12:11])
              Q_TICK: begin
                // a sample still queued behind another is late
                if (qCount > 5'd8)
                  io_overrun <= 1'b1;
                chip <= !queue[qRd][8];        // OKI 0 first when both
                tickBoth <= queue[qRd][8] && queue[qRd][9];
                voice <= 2'd0;
                acc <= 20'sd0;
                state <= S_VOICE;
              end
              Q_CMD: begin
                chip <= queue[qRd][8];
                if (commandSet[queue[qRd][8]]) begin
                  commandSet[queue[qRd][8]] <= 1'b0;
                  tableIndex <= 3'd0;
                  readAddr <= {8'd0, command[queue[qRd][8]], 3'd0};
                  state <= S_TABLE;
                end else if (queue[qRd][7]) begin
                  command[queue[qRd][8]] <= queue[qRd][6:0];
                  commandSet[queue[qRd][8]] <= 1'b1;
                end else begin
                  for (i = 0; i < 4; i = i + 1)
                    if (queue[qRd][3 + i])
                      vPlaying[{queue[qRd][8], i[1:0]}] <= 1'b0;
                end
              end
              default:
                bank[queue[qRd][10:8]] <= queue[qRd][7:0];
            endcase
          end

        // a sample: each voice of the chip in turn
        S_VOICE:
          if (vPlaying[vi]) begin
            readAddr <= vBase[vi] + vSample[vi][18:1];
            state <= S_READ;
          end else if (voice == 2'd3)
            finishChip(acc);
          else
            voice <= voice + 2'd1;

        S_READ:
          if (io_rom_valid && romPending) begin
            vSignal[vi] <= newSignal;
            vStep[vi] <= newStep;
            vSample[vi] <= vSample[vi] + 20'd1;
            if (vSample[vi] + 20'd1 >= vCount[vi])
              vPlaying[vi] <= 1'b0;
            if (voice == 2'd3)
              finishChip(acc + {{1{product[18]}}, product});
            else begin
              acc <= acc + {{1{product[18]}}, product};
              voice <= voice + 2'd1;
              state <= S_VOICE;
            end
          end

        // a start: the phrase's six bytes, then the voices
        S_TABLE:
          if (io_rom_valid && romPending) begin
            phraseBytes <= {phraseBytes[39:0], io_rom_dout};
            readAddr <= readAddr + 18'd1;
            tableIndex <= tableIndex + 3'd1;
            if (tableIndex == 3'd5)
              state <= S_START;
          end

        S_START: begin
          for (i = 0; i < 4; i = i + 1)
            if (startMask[i] && !vPlaying[{chip, i[1:0]}] && !phraseNone) begin
              vPlaying[{chip, i[1:0]}] <= 1'b1;
              vBase[{chip, i[1:0]}] <= phraseStart;
              vSample[{chip, i[1:0]}] <= 20'd0;
              vCount[{chip, i[1:0]}] <= {phraseLength, 1'b0};
              vSignal[{chip, i[1:0]}] <= 12'sd0;
              vStep[{chip, i[1:0]}] <= 6'd0;
              vVolume[{chip, i[1:0]}] <= volume(ev[3:0]);
            end
          state <= S_IDLE;
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

  // a chip's sample done: out, and on to the other chip if both
  task automatic finishChip(input signed [19:0] total);
    begin
      if (chip) begin
        io_sample_1 <= total;
        io_sample_valid_1 <= 1'b1;
      end else begin
        io_sample_0 <= total;
        io_sample_valid_0 <= 1'b1;
      end
      if (tickBoth && !chip) begin
        chip <= 1'b1;
        voice <= 2'd0;
        acc <= 20'sd0;
        state <= S_VOICE;
      end else
        state <= S_IDLE;
    end
  endtask

  // the volume steps: 0, -3.2, -6, -9.2, -12, -14.5, -18, -20.5, -24 dB, then
  // silence (x / 0x20)
  function automatic [5:0] volume(input [3:0] v);
    case (v)
      4'd0: volume = 6'h20;  4'd1: volume = 6'h16;  4'd2: volume = 6'h10;
      4'd3: volume = 6'h0b;  4'd4: volume = 6'h08;  4'd5: volume = 6'h06;
      4'd6: volume = 6'h04;  4'd7: volume = 6'h03;  4'd8: volume = 6'h02;
      default: volume = 6'h00;
    endcase
  endfunction

  assign io_rom_rd   = (state == S_READ || state == S_TABLE) && !romPending;
  assign io_rom_addr = mapped;
endmodule

`default_nettype wire
