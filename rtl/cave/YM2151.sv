// SPDX-License-Identifier: GPL-3.0-or-later
//
// Cave 68000 for Analogue Pocket: the Yamaha YM2151 (OPM) of Air Gallet's
// and Sailor Moon's sound board, written to MAME's model of the chip – ymfm's
// ym2151 (ymfm_opm.cpp, ymfm_fm.ipp) – so that it plays what MAME plays,
// sample for sample. The die's pipeline is not followed: ymfm makes a sample
// whole, each channel's operators clocked and then computed one after
// another, each modulating the next within the same sample, and that is what
// is done here, one operator at a time on a fast clock.
//
// After ymfm:
//   * a register write marks every channel modified, and the next sample
//     begins with a "prepare" – each operator's key state clocked from its
//     key-on bits, a channel counted active while any of its operators is out
//     of release or under attenuation 0x380 – as does every 4,097th sample
//     with no write between; a channel not active is not output (it matters
//     for the noise, which has no quiet cut-off);
//   * the envelope on a 3-sample divider with ymfm's increment table; attack
//     att -= ceil((att + 1) * inc / 16), ymfm's (~att * inc) >> 4 on a 16-bit
//     attenuation; rates 62 and 63 jump to 0 only at a key on;
//   * the phase from ymfm's key-code table (David Viens'), DT2 in 64ths of a
//     semitone, PM by shifts, then DT1 and MUL;
//   * the LFO's four waves and the noise LFSR (clocked twice a sample); the
//     noise wave reads a 256-entry table written one step ahead, kept here as
//     the three entries that can be read;
//   * each channel's sum to the left and right as RL says, then the YM3012's
//     10.3 floating point (roundtrip_fp);
//   * the timers, busy flag and IRQ as MAME's device runs them: timer A
//     (1024 - TA) x 64 phiM clocks from the write that loads it, timer B
//     16 x (256 - TB) samples less the samples made mod 16, busy for 64 phiM
//     clocks after a data write.
//
// A sample is begun on every 64th phiM clock (cen). A write that comes while
// one is being made waits in a queue until it is done, so it lands on the
// sample MAME lands it on (MAME brings the stream up to a write's time
// first); the timer registers (10-12, 14) take a write at once. A sample
// takes 270 clocks: the board gives it 512 (8 a phiM clock).
//
// The tables (sine, power, phase step, envelope increment, detune) are
// ymfm's, which carries this licence:
//
//   BSD 3-Clause License
//
//   Copyright (c) 2021, Aaron Giles
//   All rights reserved.
//
//   Redistribution and use in source and binary forms, with or without
//   modification, are permitted provided that the following conditions are
//   met:
//
//   1. Redistributions of source code must retain the above copyright
//      notice, this list of conditions and the following disclaimer.
//
//   2. Redistributions in binary form must reproduce the above copyright
//      notice, this list of conditions and the following disclaimer in the
//      documentation and/or other materials provided with the distribution.
//
//   3. Neither the name of the copyright holder nor the names of its
//      contributors may be used to endorse or promote products derived from
//      this software without specific prior written permission.
//
//   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
//   IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
//   TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
//   PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
//   HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
//   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
//   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
//   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
//   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
//   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

module YM2151 #(
  parameter integer TSCALE = 1          // cen_t pulses to a phiM clock
) (
  input                    clock,
  input                    reset,
  input                    cen,         // phiM, the chip's clock
  input                    cen_t,       // counts the timers and the busy flag
  input                    io_wr,
  input                    io_a0,
  input             [7:0]  io_din,
  output            [7:0]  io_dout,     // the status (a0 = 1), else ff
  output                   io_irq,
  output reg               io_sample,   // io_left and io_right are a new sample
  output reg signed [15:0] io_left,
  output reg signed [15:0] io_right,
  output            [1:0]  io_ct,       // register 1b's top two bits
  output reg               io_overrun   // a sample due before the last was done, or the queue full
);
  localparam integer TK = 64 * TSCALE;  // cen_t pulses in a sample

  localparam [1:0] EG_ATT = 2'd0, EG_DEC = 2'd1, EG_SUS = 2'd2, EG_REL = 2'd3;

  localparam [3:0] S_INIT = 4'd0,  S_IDLE = 4'd1,
                   S_L0   = 4'd2,  S_L1   = 4'd3,  S_L2 = 4'd4,
                   S_C0   = 4'd5,  S_C1   = 4'd6,  S_C2 = 4'd7,  S_C3 = 4'd8,  S_C4 = 4'd9,
                   S_O0   = 4'd10, S_O1   = 4'd11, S_O2 = 4'd12, S_O3 = 4'd13,
                   S_FIN  = 4'd14;

  // ---------------------------------------------------------------- registers
  reg  [7:0] addr;
  reg  [7:0] rTest, rNoise, rTaHi, rTb, rMode, rLfrq, rCtw;
  reg  [1:0] rTaLo;
  reg  [6:0] rAmd, rPmd;
  reg  [7:0] rCon [0:7];                // 20: RL, FB, CON
  reg  [6:0] rKc  [0:7];                // 28
  reg  [5:0] rKf  [0:7];                // 30, bits 7:2
  reg  [6:0] rPms [0:7];                // 38: PMS 6:4, AMS 1:0
  (* ramstyle = "MLAB" *)
  reg  [6:0] rDtMul  [0:31];            // 40: DT1 6:4, MUL 3:0
  (* ramstyle = "MLAB" *)
  reg  [6:0] rTl     [0:31];            // 60
  (* ramstyle = "MLAB" *)
  reg  [7:0] rKsAr   [0:31];            // 80: KS 7:6, AR 4:0
  (* ramstyle = "MLAB" *)
  reg  [7:0] rAmD1r  [0:31];            // a0: AMS-EN 7, D1R 4:0
  (* ramstyle = "MLAB" *)
  reg  [7:0] rDt2D2r [0:31];            // c0: DT2 7:6, D2R 4:0
  (* ramstyle = "MLAB" *)
  reg  [7:0] rD1lRr  [0:31];            // e0: D1L 7:4, RR 3:0
  reg [31:0] liveN, liveC;              // key-on bits: written, CSM
  reg        modified;

  // each operator: {key, state, attenuation, phase}; these and the operator
  // registers in MLABs, the M10Ks kept for the tables
  (* ramstyle = "MLAB" *)
  reg [32:0] ost [0:31];

  // ------------------------------------------------------------ engine state
  reg  [3:0] st;
  reg  [2:0] c;                         // channel
  reg  [1:0] i;                         // operator of the channel, in ymfm's order
  wire [4:0] slot = {i[0], i[1], c};    // M1 c, C1 c+16, M2 c+8, C2 c+24
  reg  [4:0] initSlot;
  reg  [5:0] pc;                        // phiM clocks, mod 64
  reg        due;
  reg  [3:0] total;                     // samples begun, mod 16

  // ------------------------------------------------------- the write queue
  reg [15:0] q [0:3];
  reg  [1:0] qWr, qRd;
  reg  [2:0] qCnt;
  wire       wrData   = io_wr & io_a0;
  wire       timerReg = addr == 8'h10 || addr == 8'h11 || addr == 8'h12 || addr == 8'h14;
  wire       push     = wrData & ~timerReg;
  wire       apply    = st == S_IDLE && qCnt != 3'd0;
  wire       start    = st == S_IDLE && due && qCnt == 3'd0;
  wire [7:0] wa       = q[qRd][15:8];
  wire [7:0] wd       = q[qRd][7:0];

  always @(posedge clock) begin
    if (push) q[qWr] <= {addr, io_din};
    if (reset) begin
      qWr <= 2'd0; qRd <= 2'd0; qCnt <= 3'd0;
    end else begin
      if (push) qWr <= qWr + 2'd1;
      if (apply) qRd <= qRd + 2'd1;
      qCnt <= qCnt + {2'd0, push} - {2'd0, apply};
    end
  end

  // ------------------------------------------------- timers, busy and status
  reg [23:0] cntA, cntB;
  reg        runA, runB, flagA, flagB, csmPend;
  reg [15:0] busyCnt;
  wire [10:0] perA  = 11'd1024 - {1'b0, rTaHi, rTaLo};
  wire [12:0] perB  = {1'b0, 8'd255 - rTb, 4'd0} + 13'd16;  // 16 x (256 - TB)
  wire        expA  = cen_t && runA && cntA == 24'd1;
  wire        expB  = cen_t && runB && cntB == 24'd1;
  wire        busy  = busyCnt > 16'd1 || (busyCnt == 16'd1 && !cen_t);
  wire  [7:0] status = {busy, 5'd0, flagB | (expB & rMode[3]), flagA | (expA & rMode[2])};
  assign io_dout = io_a0 ? status : 8'hff;
  assign io_irq  = flagA | flagB;
  assign io_ct   = rCtw[7:6];

  wire wrMode = wrData && addr == 8'h14;

  always @(posedge clock) begin
    if (reset) begin
      rTaHi <= 8'd0; rTaLo <= 2'd0; rTb <= 8'd0; rMode <= 8'd0;
      runA <= 1'b0; runB <= 1'b0; flagA <= 1'b0; flagB <= 1'b0; csmPend <= 1'b0;
      cntA <= 24'd0; cntB <= 24'd0; busyCnt <= 16'd0;
    end else begin
      if (wrData) busyCnt <= TK[15:0];
      else if (cen_t && busyCnt != 16'd0) busyCnt <= busyCnt - 16'd1;

      if (expA) begin
        if (rMode[2]) flagA <= 1'b1;
        if (rMode[7]) csmPend <= 1'b1;
        cntA <= perA * TK;
      end else if (cen_t && runA) cntA <= cntA - 24'd1;
      if (expB) begin
        if (rMode[3]) flagB <= 1'b1;
        cntB <= perB * TK;
      end else if (cen_t && runB) cntB <= cntB - 24'd1;
      if (st == S_IDLE && csmPend) csmPend <= 1'b0;

      if (wrData && addr == 8'h10) rTaHi <= io_din;
      if (wrData && addr == 8'h11) rTaLo <= io_din[1:0];
      if (wrData && addr == 8'h12) rTb   <= io_din;
      if (wrMode) begin
        // engine_mode_write: the flags reset, then timer B, then timer A
        rMode <= io_din;
        if (io_din[5]) flagB <= 1'b0;
        if (io_din[4]) flagA <= 1'b0;
        if (io_din[1] && !runB) begin
          runB <= 1'b1;
          cntB <= (perB - {9'd0, total}) * TK;
        end else if (!io_din[1]) runB <= 1'b0;
        if (io_din[0] && !runA) begin
          runA <= 1'b1;
          cntA <= perA * TK;
        end else if (!io_din[0]) runA <= 1'b0;
      end
    end
  end

  // ----------------------------------------------------------------- tables
  function [5:0] effRate(input [5:0] raw, input [4:0] ksr);
    reg [6:0] s;
    begin
      s = {1'b0, raw} + {2'b0, ksr};
      effRate = raw == 6'd0 ? 6'd0 : s > 7'd63 ? 6'd63 : s[5:0];
    end
  endfunction

  function [31:0] incRow(input [5:0] rate);
    case (rate)
      6'd0: incRow = 32'h00000000;
      6'd1: incRow = 32'h00000000;
      6'd2: incRow = 32'h10101010;
      6'd3: incRow = 32'h10101010;
      6'd4: incRow = 32'h10101010;
      6'd5: incRow = 32'h10101010;
      6'd6: incRow = 32'h11101110;
      6'd7: incRow = 32'h11101110;
      6'd8: incRow = 32'h10101010;
      6'd9: incRow = 32'h10111010;
      6'd10: incRow = 32'h11101110;
      6'd11: incRow = 32'h11111110;
      6'd12: incRow = 32'h10101010;
      6'd13: incRow = 32'h10111010;
      6'd14: incRow = 32'h11101110;
      6'd15: incRow = 32'h11111110;
      6'd16: incRow = 32'h10101010;
      6'd17: incRow = 32'h10111010;
      6'd18: incRow = 32'h11101110;
      6'd19: incRow = 32'h11111110;
      6'd20: incRow = 32'h10101010;
      6'd21: incRow = 32'h10111010;
      6'd22: incRow = 32'h11101110;
      6'd23: incRow = 32'h11111110;
      6'd24: incRow = 32'h10101010;
      6'd25: incRow = 32'h10111010;
      6'd26: incRow = 32'h11101110;
      6'd27: incRow = 32'h11111110;
      6'd28: incRow = 32'h10101010;
      6'd29: incRow = 32'h10111010;
      6'd30: incRow = 32'h11101110;
      6'd31: incRow = 32'h11111110;
      6'd32: incRow = 32'h10101010;
      6'd33: incRow = 32'h10111010;
      6'd34: incRow = 32'h11101110;
      6'd35: incRow = 32'h11111110;
      6'd36: incRow = 32'h10101010;
      6'd37: incRow = 32'h10111010;
      6'd38: incRow = 32'h11101110;
      6'd39: incRow = 32'h11111110;
      6'd40: incRow = 32'h10101010;
      6'd41: incRow = 32'h10111010;
      6'd42: incRow = 32'h11101110;
      6'd43: incRow = 32'h11111110;
      6'd44: incRow = 32'h10101010;
      6'd45: incRow = 32'h10111010;
      6'd46: incRow = 32'h11101110;
      6'd47: incRow = 32'h11111110;
      6'd48: incRow = 32'h11111111;
      6'd49: incRow = 32'h21112111;
      6'd50: incRow = 32'h21212121;
      6'd51: incRow = 32'h22212221;
      6'd52: incRow = 32'h22222222;
      6'd53: incRow = 32'h42224222;
      6'd54: incRow = 32'h42424242;
      6'd55: incRow = 32'h44424442;
      6'd56: incRow = 32'h44444444;
      6'd57: incRow = 32'h84448444;
      6'd58: incRow = 32'h84848484;
      6'd59: incRow = 32'h88848884;
      6'd60: incRow = 32'h88888888;
      6'd61: incRow = 32'h88888888;
      6'd62: incRow = 32'h88888888;
      6'd63: incRow = 32'h88888888;
      default: incRow = 32'h0;
    endcase
  endfunction

  function [14:0] dtRow(input [4:0] keycode);
    case (keycode)
      5'd0: dtRow = {5'd2, 5'd1, 5'd0};
      5'd1: dtRow = {5'd2, 5'd1, 5'd0};
      5'd2: dtRow = {5'd2, 5'd1, 5'd0};
      5'd3: dtRow = {5'd2, 5'd1, 5'd0};
      5'd4: dtRow = {5'd2, 5'd2, 5'd1};
      5'd5: dtRow = {5'd3, 5'd2, 5'd1};
      5'd6: dtRow = {5'd3, 5'd2, 5'd1};
      5'd7: dtRow = {5'd3, 5'd2, 5'd1};
      5'd8: dtRow = {5'd4, 5'd2, 5'd1};
      5'd9: dtRow = {5'd4, 5'd3, 5'd1};
      5'd10: dtRow = {5'd4, 5'd3, 5'd1};
      5'd11: dtRow = {5'd5, 5'd3, 5'd1};
      5'd12: dtRow = {5'd5, 5'd4, 5'd2};
      5'd13: dtRow = {5'd6, 5'd4, 5'd2};
      5'd14: dtRow = {5'd6, 5'd4, 5'd2};
      5'd15: dtRow = {5'd7, 5'd5, 5'd2};
      5'd16: dtRow = {5'd8, 5'd5, 5'd2};
      5'd17: dtRow = {5'd8, 5'd6, 5'd3};
      5'd18: dtRow = {5'd9, 5'd6, 5'd3};
      5'd19: dtRow = {5'd10, 5'd7, 5'd3};
      5'd20: dtRow = {5'd11, 5'd8, 5'd4};
      5'd21: dtRow = {5'd12, 5'd8, 5'd4};
      5'd22: dtRow = {5'd13, 5'd9, 5'd4};
      5'd23: dtRow = {5'd14, 5'd10, 5'd5};
      5'd24: dtRow = {5'd16, 5'd11, 5'd5};
      5'd25: dtRow = {5'd17, 5'd12, 5'd6};
      5'd26: dtRow = {5'd19, 5'd13, 5'd6};
      5'd27: dtRow = {5'd20, 5'd14, 5'd7};
      5'd28: dtRow = {5'd22, 5'd16, 5'd8};
      5'd29: dtRow = {5'd22, 5'd16, 5'd8};
      5'd30: dtRow = {5'd22, 5'd16, 5'd8};
      5'd31: dtRow = {5'd22, 5'd16, 5'd8};
      default: dtRow = 15'h0;
    endcase
  endfunction

  wire [7:0]  sinAddr, powAddr;
  wire [9:0]  phAddr;
  reg  [11:0] sinQ, phQ;
  reg  [9:0]  powQ;
  always @(posedge clock) begin
    case (sinAddr)
      8'd0: sinQ <= 12'h859;
      8'd1: sinQ <= 12'h6c3;
      8'd2: sinQ <= 12'h607;
      8'd3: sinQ <= 12'h58b;
      8'd4: sinQ <= 12'h52e;
      8'd5: sinQ <= 12'h4e4;
      8'd6: sinQ <= 12'h4a6;
      8'd7: sinQ <= 12'h471;
      8'd8: sinQ <= 12'h443;
      8'd9: sinQ <= 12'h41a;
      8'd10: sinQ <= 12'h3f5;
      8'd11: sinQ <= 12'h3d3;
      8'd12: sinQ <= 12'h3b5;
      8'd13: sinQ <= 12'h398;
      8'd14: sinQ <= 12'h37e;
      8'd15: sinQ <= 12'h365;
      8'd16: sinQ <= 12'h34e;
      8'd17: sinQ <= 12'h339;
      8'd18: sinQ <= 12'h324;
      8'd19: sinQ <= 12'h311;
      8'd20: sinQ <= 12'h2ff;
      8'd21: sinQ <= 12'h2ed;
      8'd22: sinQ <= 12'h2dc;
      8'd23: sinQ <= 12'h2cd;
      8'd24: sinQ <= 12'h2bd;
      8'd25: sinQ <= 12'h2af;
      8'd26: sinQ <= 12'h2a0;
      8'd27: sinQ <= 12'h293;
      8'd28: sinQ <= 12'h286;
      8'd29: sinQ <= 12'h279;
      8'd30: sinQ <= 12'h26d;
      8'd31: sinQ <= 12'h261;
      8'd32: sinQ <= 12'h256;
      8'd33: sinQ <= 12'h24b;
      8'd34: sinQ <= 12'h240;
      8'd35: sinQ <= 12'h236;
      8'd36: sinQ <= 12'h22c;
      8'd37: sinQ <= 12'h222;
      8'd38: sinQ <= 12'h218;
      8'd39: sinQ <= 12'h20f;
      8'd40: sinQ <= 12'h206;
      8'd41: sinQ <= 12'h1fd;
      8'd42: sinQ <= 12'h1f5;
      8'd43: sinQ <= 12'h1ec;
      8'd44: sinQ <= 12'h1e4;
      8'd45: sinQ <= 12'h1dc;
      8'd46: sinQ <= 12'h1d4;
      8'd47: sinQ <= 12'h1cd;
      8'd48: sinQ <= 12'h1c5;
      8'd49: sinQ <= 12'h1be;
      8'd50: sinQ <= 12'h1b7;
      8'd51: sinQ <= 12'h1b0;
      8'd52: sinQ <= 12'h1a9;
      8'd53: sinQ <= 12'h1a2;
      8'd54: sinQ <= 12'h19b;
      8'd55: sinQ <= 12'h195;
      8'd56: sinQ <= 12'h18f;
      8'd57: sinQ <= 12'h188;
      8'd58: sinQ <= 12'h182;
      8'd59: sinQ <= 12'h17c;
      8'd60: sinQ <= 12'h177;
      8'd61: sinQ <= 12'h171;
      8'd62: sinQ <= 12'h16b;
      8'd63: sinQ <= 12'h166;
      8'd64: sinQ <= 12'h160;
      8'd65: sinQ <= 12'h15b;
      8'd66: sinQ <= 12'h155;
      8'd67: sinQ <= 12'h150;
      8'd68: sinQ <= 12'h14b;
      8'd69: sinQ <= 12'h146;
      8'd70: sinQ <= 12'h141;
      8'd71: sinQ <= 12'h13c;
      8'd72: sinQ <= 12'h137;
      8'd73: sinQ <= 12'h133;
      8'd74: sinQ <= 12'h12e;
      8'd75: sinQ <= 12'h129;
      8'd76: sinQ <= 12'h125;
      8'd77: sinQ <= 12'h121;
      8'd78: sinQ <= 12'h11c;
      8'd79: sinQ <= 12'h118;
      8'd80: sinQ <= 12'h114;
      8'd81: sinQ <= 12'h10f;
      8'd82: sinQ <= 12'h10b;
      8'd83: sinQ <= 12'h107;
      8'd84: sinQ <= 12'h103;
      8'd85: sinQ <= 12'hff;
      8'd86: sinQ <= 12'hfb;
      8'd87: sinQ <= 12'hf8;
      8'd88: sinQ <= 12'hf4;
      8'd89: sinQ <= 12'hf0;
      8'd90: sinQ <= 12'hec;
      8'd91: sinQ <= 12'he9;
      8'd92: sinQ <= 12'he5;
      8'd93: sinQ <= 12'he2;
      8'd94: sinQ <= 12'hde;
      8'd95: sinQ <= 12'hdb;
      8'd96: sinQ <= 12'hd7;
      8'd97: sinQ <= 12'hd4;
      8'd98: sinQ <= 12'hd1;
      8'd99: sinQ <= 12'hcd;
      8'd100: sinQ <= 12'hca;
      8'd101: sinQ <= 12'hc7;
      8'd102: sinQ <= 12'hc4;
      8'd103: sinQ <= 12'hc1;
      8'd104: sinQ <= 12'hbe;
      8'd105: sinQ <= 12'hbb;
      8'd106: sinQ <= 12'hb8;
      8'd107: sinQ <= 12'hb5;
      8'd108: sinQ <= 12'hb2;
      8'd109: sinQ <= 12'haf;
      8'd110: sinQ <= 12'hac;
      8'd111: sinQ <= 12'ha9;
      8'd112: sinQ <= 12'ha7;
      8'd113: sinQ <= 12'ha4;
      8'd114: sinQ <= 12'ha1;
      8'd115: sinQ <= 12'h9f;
      8'd116: sinQ <= 12'h9c;
      8'd117: sinQ <= 12'h99;
      8'd118: sinQ <= 12'h97;
      8'd119: sinQ <= 12'h94;
      8'd120: sinQ <= 12'h92;
      8'd121: sinQ <= 12'h8f;
      8'd122: sinQ <= 12'h8d;
      8'd123: sinQ <= 12'h8a;
      8'd124: sinQ <= 12'h88;
      8'd125: sinQ <= 12'h86;
      8'd126: sinQ <= 12'h83;
      8'd127: sinQ <= 12'h81;
      8'd128: sinQ <= 12'h7f;
      8'd129: sinQ <= 12'h7d;
      8'd130: sinQ <= 12'h7a;
      8'd131: sinQ <= 12'h78;
      8'd132: sinQ <= 12'h76;
      8'd133: sinQ <= 12'h74;
      8'd134: sinQ <= 12'h72;
      8'd135: sinQ <= 12'h70;
      8'd136: sinQ <= 12'h6e;
      8'd137: sinQ <= 12'h6c;
      8'd138: sinQ <= 12'h6a;
      8'd139: sinQ <= 12'h68;
      8'd140: sinQ <= 12'h66;
      8'd141: sinQ <= 12'h64;
      8'd142: sinQ <= 12'h62;
      8'd143: sinQ <= 12'h60;
      8'd144: sinQ <= 12'h5e;
      8'd145: sinQ <= 12'h5c;
      8'd146: sinQ <= 12'h5b;
      8'd147: sinQ <= 12'h59;
      8'd148: sinQ <= 12'h57;
      8'd149: sinQ <= 12'h55;
      8'd150: sinQ <= 12'h53;
      8'd151: sinQ <= 12'h52;
      8'd152: sinQ <= 12'h50;
      8'd153: sinQ <= 12'h4e;
      8'd154: sinQ <= 12'h4d;
      8'd155: sinQ <= 12'h4b;
      8'd156: sinQ <= 12'h4a;
      8'd157: sinQ <= 12'h48;
      8'd158: sinQ <= 12'h46;
      8'd159: sinQ <= 12'h45;
      8'd160: sinQ <= 12'h43;
      8'd161: sinQ <= 12'h42;
      8'd162: sinQ <= 12'h40;
      8'd163: sinQ <= 12'h3f;
      8'd164: sinQ <= 12'h3e;
      8'd165: sinQ <= 12'h3c;
      8'd166: sinQ <= 12'h3b;
      8'd167: sinQ <= 12'h39;
      8'd168: sinQ <= 12'h38;
      8'd169: sinQ <= 12'h37;
      8'd170: sinQ <= 12'h35;
      8'd171: sinQ <= 12'h34;
      8'd172: sinQ <= 12'h33;
      8'd173: sinQ <= 12'h31;
      8'd174: sinQ <= 12'h30;
      8'd175: sinQ <= 12'h2f;
      8'd176: sinQ <= 12'h2e;
      8'd177: sinQ <= 12'h2d;
      8'd178: sinQ <= 12'h2b;
      8'd179: sinQ <= 12'h2a;
      8'd180: sinQ <= 12'h29;
      8'd181: sinQ <= 12'h28;
      8'd182: sinQ <= 12'h27;
      8'd183: sinQ <= 12'h26;
      8'd184: sinQ <= 12'h25;
      8'd185: sinQ <= 12'h24;
      8'd186: sinQ <= 12'h23;
      8'd187: sinQ <= 12'h22;
      8'd188: sinQ <= 12'h21;
      8'd189: sinQ <= 12'h20;
      8'd190: sinQ <= 12'h1f;
      8'd191: sinQ <= 12'h1e;
      8'd192: sinQ <= 12'h1d;
      8'd193: sinQ <= 12'h1c;
      8'd194: sinQ <= 12'h1b;
      8'd195: sinQ <= 12'h1a;
      8'd196: sinQ <= 12'h19;
      8'd197: sinQ <= 12'h18;
      8'd198: sinQ <= 12'h17;
      8'd199: sinQ <= 12'h17;
      8'd200: sinQ <= 12'h16;
      8'd201: sinQ <= 12'h15;
      8'd202: sinQ <= 12'h14;
      8'd203: sinQ <= 12'h14;
      8'd204: sinQ <= 12'h13;
      8'd205: sinQ <= 12'h12;
      8'd206: sinQ <= 12'h11;
      8'd207: sinQ <= 12'h11;
      8'd208: sinQ <= 12'h10;
      8'd209: sinQ <= 12'hf;
      8'd210: sinQ <= 12'hf;
      8'd211: sinQ <= 12'he;
      8'd212: sinQ <= 12'hd;
      8'd213: sinQ <= 12'hd;
      8'd214: sinQ <= 12'hc;
      8'd215: sinQ <= 12'hc;
      8'd216: sinQ <= 12'hb;
      8'd217: sinQ <= 12'ha;
      8'd218: sinQ <= 12'ha;
      8'd219: sinQ <= 12'h9;
      8'd220: sinQ <= 12'h9;
      8'd221: sinQ <= 12'h8;
      8'd222: sinQ <= 12'h8;
      8'd223: sinQ <= 12'h7;
      8'd224: sinQ <= 12'h7;
      8'd225: sinQ <= 12'h7;
      8'd226: sinQ <= 12'h6;
      8'd227: sinQ <= 12'h6;
      8'd228: sinQ <= 12'h5;
      8'd229: sinQ <= 12'h5;
      8'd230: sinQ <= 12'h5;
      8'd231: sinQ <= 12'h4;
      8'd232: sinQ <= 12'h4;
      8'd233: sinQ <= 12'h4;
      8'd234: sinQ <= 12'h3;
      8'd235: sinQ <= 12'h3;
      8'd236: sinQ <= 12'h3;
      8'd237: sinQ <= 12'h2;
      8'd238: sinQ <= 12'h2;
      8'd239: sinQ <= 12'h2;
      8'd240: sinQ <= 12'h2;
      8'd241: sinQ <= 12'h1;
      8'd242: sinQ <= 12'h1;
      8'd243: sinQ <= 12'h1;
      8'd244: sinQ <= 12'h1;
      8'd245: sinQ <= 12'h1;
      8'd246: sinQ <= 12'h1;
      8'd247: sinQ <= 12'h1;
      8'd248: sinQ <= 12'h0;
      8'd249: sinQ <= 12'h0;
      8'd250: sinQ <= 12'h0;
      8'd251: sinQ <= 12'h0;
      8'd252: sinQ <= 12'h0;
      8'd253: sinQ <= 12'h0;
      8'd254: sinQ <= 12'h0;
      8'd255: sinQ <= 12'h0;
      default: sinQ <= 12'h0;
    endcase
  end
  always @(posedge clock) begin
    case (powAddr)
      8'd0: powQ <= 10'h3fa;
      8'd1: powQ <= 10'h3f5;
      8'd2: powQ <= 10'h3ef;
      8'd3: powQ <= 10'h3ea;
      8'd4: powQ <= 10'h3e4;
      8'd5: powQ <= 10'h3df;
      8'd6: powQ <= 10'h3da;
      8'd7: powQ <= 10'h3d4;
      8'd8: powQ <= 10'h3cf;
      8'd9: powQ <= 10'h3c9;
      8'd10: powQ <= 10'h3c4;
      8'd11: powQ <= 10'h3bf;
      8'd12: powQ <= 10'h3b9;
      8'd13: powQ <= 10'h3b4;
      8'd14: powQ <= 10'h3ae;
      8'd15: powQ <= 10'h3a9;
      8'd16: powQ <= 10'h3a4;
      8'd17: powQ <= 10'h39f;
      8'd18: powQ <= 10'h399;
      8'd19: powQ <= 10'h394;
      8'd20: powQ <= 10'h38f;
      8'd21: powQ <= 10'h38a;
      8'd22: powQ <= 10'h384;
      8'd23: powQ <= 10'h37f;
      8'd24: powQ <= 10'h37a;
      8'd25: powQ <= 10'h375;
      8'd26: powQ <= 10'h370;
      8'd27: powQ <= 10'h36a;
      8'd28: powQ <= 10'h365;
      8'd29: powQ <= 10'h360;
      8'd30: powQ <= 10'h35b;
      8'd31: powQ <= 10'h356;
      8'd32: powQ <= 10'h351;
      8'd33: powQ <= 10'h34c;
      8'd34: powQ <= 10'h347;
      8'd35: powQ <= 10'h342;
      8'd36: powQ <= 10'h33d;
      8'd37: powQ <= 10'h338;
      8'd38: powQ <= 10'h333;
      8'd39: powQ <= 10'h32e;
      8'd40: powQ <= 10'h329;
      8'd41: powQ <= 10'h324;
      8'd42: powQ <= 10'h31f;
      8'd43: powQ <= 10'h31a;
      8'd44: powQ <= 10'h315;
      8'd45: powQ <= 10'h310;
      8'd46: powQ <= 10'h30b;
      8'd47: powQ <= 10'h306;
      8'd48: powQ <= 10'h302;
      8'd49: powQ <= 10'h2fd;
      8'd50: powQ <= 10'h2f8;
      8'd51: powQ <= 10'h2f3;
      8'd52: powQ <= 10'h2ee;
      8'd53: powQ <= 10'h2e9;
      8'd54: powQ <= 10'h2e5;
      8'd55: powQ <= 10'h2e0;
      8'd56: powQ <= 10'h2db;
      8'd57: powQ <= 10'h2d6;
      8'd58: powQ <= 10'h2d2;
      8'd59: powQ <= 10'h2cd;
      8'd60: powQ <= 10'h2c8;
      8'd61: powQ <= 10'h2c4;
      8'd62: powQ <= 10'h2bf;
      8'd63: powQ <= 10'h2ba;
      8'd64: powQ <= 10'h2b5;
      8'd65: powQ <= 10'h2b1;
      8'd66: powQ <= 10'h2ac;
      8'd67: powQ <= 10'h2a8;
      8'd68: powQ <= 10'h2a3;
      8'd69: powQ <= 10'h29e;
      8'd70: powQ <= 10'h29a;
      8'd71: powQ <= 10'h295;
      8'd72: powQ <= 10'h291;
      8'd73: powQ <= 10'h28c;
      8'd74: powQ <= 10'h288;
      8'd75: powQ <= 10'h283;
      8'd76: powQ <= 10'h27f;
      8'd77: powQ <= 10'h27a;
      8'd78: powQ <= 10'h276;
      8'd79: powQ <= 10'h271;
      8'd80: powQ <= 10'h26d;
      8'd81: powQ <= 10'h268;
      8'd82: powQ <= 10'h264;
      8'd83: powQ <= 10'h25f;
      8'd84: powQ <= 10'h25b;
      8'd85: powQ <= 10'h257;
      8'd86: powQ <= 10'h252;
      8'd87: powQ <= 10'h24e;
      8'd88: powQ <= 10'h249;
      8'd89: powQ <= 10'h245;
      8'd90: powQ <= 10'h241;
      8'd91: powQ <= 10'h23c;
      8'd92: powQ <= 10'h238;
      8'd93: powQ <= 10'h234;
      8'd94: powQ <= 10'h230;
      8'd95: powQ <= 10'h22b;
      8'd96: powQ <= 10'h227;
      8'd97: powQ <= 10'h223;
      8'd98: powQ <= 10'h21e;
      8'd99: powQ <= 10'h21a;
      8'd100: powQ <= 10'h216;
      8'd101: powQ <= 10'h212;
      8'd102: powQ <= 10'h20e;
      8'd103: powQ <= 10'h209;
      8'd104: powQ <= 10'h205;
      8'd105: powQ <= 10'h201;
      8'd106: powQ <= 10'h1fd;
      8'd107: powQ <= 10'h1f9;
      8'd108: powQ <= 10'h1f5;
      8'd109: powQ <= 10'h1f0;
      8'd110: powQ <= 10'h1ec;
      8'd111: powQ <= 10'h1e8;
      8'd112: powQ <= 10'h1e4;
      8'd113: powQ <= 10'h1e0;
      8'd114: powQ <= 10'h1dc;
      8'd115: powQ <= 10'h1d8;
      8'd116: powQ <= 10'h1d4;
      8'd117: powQ <= 10'h1d0;
      8'd118: powQ <= 10'h1cc;
      8'd119: powQ <= 10'h1c8;
      8'd120: powQ <= 10'h1c4;
      8'd121: powQ <= 10'h1c0;
      8'd122: powQ <= 10'h1bc;
      8'd123: powQ <= 10'h1b8;
      8'd124: powQ <= 10'h1b4;
      8'd125: powQ <= 10'h1b0;
      8'd126: powQ <= 10'h1ac;
      8'd127: powQ <= 10'h1a8;
      8'd128: powQ <= 10'h1a4;
      8'd129: powQ <= 10'h1a0;
      8'd130: powQ <= 10'h19c;
      8'd131: powQ <= 10'h199;
      8'd132: powQ <= 10'h195;
      8'd133: powQ <= 10'h191;
      8'd134: powQ <= 10'h18d;
      8'd135: powQ <= 10'h189;
      8'd136: powQ <= 10'h185;
      8'd137: powQ <= 10'h181;
      8'd138: powQ <= 10'h17e;
      8'd139: powQ <= 10'h17a;
      8'd140: powQ <= 10'h176;
      8'd141: powQ <= 10'h172;
      8'd142: powQ <= 10'h16f;
      8'd143: powQ <= 10'h16b;
      8'd144: powQ <= 10'h167;
      8'd145: powQ <= 10'h163;
      8'd146: powQ <= 10'h160;
      8'd147: powQ <= 10'h15c;
      8'd148: powQ <= 10'h158;
      8'd149: powQ <= 10'h154;
      8'd150: powQ <= 10'h151;
      8'd151: powQ <= 10'h14d;
      8'd152: powQ <= 10'h149;
      8'd153: powQ <= 10'h146;
      8'd154: powQ <= 10'h142;
      8'd155: powQ <= 10'h13e;
      8'd156: powQ <= 10'h13b;
      8'd157: powQ <= 10'h137;
      8'd158: powQ <= 10'h134;
      8'd159: powQ <= 10'h130;
      8'd160: powQ <= 10'h12c;
      8'd161: powQ <= 10'h129;
      8'd162: powQ <= 10'h125;
      8'd163: powQ <= 10'h122;
      8'd164: powQ <= 10'h11e;
      8'd165: powQ <= 10'h11b;
      8'd166: powQ <= 10'h117;
      8'd167: powQ <= 10'h114;
      8'd168: powQ <= 10'h110;
      8'd169: powQ <= 10'h10c;
      8'd170: powQ <= 10'h109;
      8'd171: powQ <= 10'h106;
      8'd172: powQ <= 10'h102;
      8'd173: powQ <= 10'hff;
      8'd174: powQ <= 10'hfb;
      8'd175: powQ <= 10'hf8;
      8'd176: powQ <= 10'hf4;
      8'd177: powQ <= 10'hf1;
      8'd178: powQ <= 10'hed;
      8'd179: powQ <= 10'hea;
      8'd180: powQ <= 10'he7;
      8'd181: powQ <= 10'he3;
      8'd182: powQ <= 10'he0;
      8'd183: powQ <= 10'hdc;
      8'd184: powQ <= 10'hd9;
      8'd185: powQ <= 10'hd6;
      8'd186: powQ <= 10'hd2;
      8'd187: powQ <= 10'hcf;
      8'd188: powQ <= 10'hcc;
      8'd189: powQ <= 10'hc8;
      8'd190: powQ <= 10'hc5;
      8'd191: powQ <= 10'hc2;
      8'd192: powQ <= 10'hbe;
      8'd193: powQ <= 10'hbb;
      8'd194: powQ <= 10'hb8;
      8'd195: powQ <= 10'hb5;
      8'd196: powQ <= 10'hb1;
      8'd197: powQ <= 10'hae;
      8'd198: powQ <= 10'hab;
      8'd199: powQ <= 10'ha8;
      8'd200: powQ <= 10'ha4;
      8'd201: powQ <= 10'ha1;
      8'd202: powQ <= 10'h9e;
      8'd203: powQ <= 10'h9b;
      8'd204: powQ <= 10'h98;
      8'd205: powQ <= 10'h94;
      8'd206: powQ <= 10'h91;
      8'd207: powQ <= 10'h8e;
      8'd208: powQ <= 10'h8b;
      8'd209: powQ <= 10'h88;
      8'd210: powQ <= 10'h85;
      8'd211: powQ <= 10'h82;
      8'd212: powQ <= 10'h7e;
      8'd213: powQ <= 10'h7b;
      8'd214: powQ <= 10'h78;
      8'd215: powQ <= 10'h75;
      8'd216: powQ <= 10'h72;
      8'd217: powQ <= 10'h6f;
      8'd218: powQ <= 10'h6c;
      8'd219: powQ <= 10'h69;
      8'd220: powQ <= 10'h66;
      8'd221: powQ <= 10'h63;
      8'd222: powQ <= 10'h60;
      8'd223: powQ <= 10'h5d;
      8'd224: powQ <= 10'h5a;
      8'd225: powQ <= 10'h57;
      8'd226: powQ <= 10'h54;
      8'd227: powQ <= 10'h51;
      8'd228: powQ <= 10'h4e;
      8'd229: powQ <= 10'h4b;
      8'd230: powQ <= 10'h48;
      8'd231: powQ <= 10'h45;
      8'd232: powQ <= 10'h42;
      8'd233: powQ <= 10'h3f;
      8'd234: powQ <= 10'h3c;
      8'd235: powQ <= 10'h39;
      8'd236: powQ <= 10'h36;
      8'd237: powQ <= 10'h33;
      8'd238: powQ <= 10'h30;
      8'd239: powQ <= 10'h2d;
      8'd240: powQ <= 10'h2a;
      8'd241: powQ <= 10'h28;
      8'd242: powQ <= 10'h25;
      8'd243: powQ <= 10'h22;
      8'd244: powQ <= 10'h1f;
      8'd245: powQ <= 10'h1c;
      8'd246: powQ <= 10'h19;
      8'd247: powQ <= 10'h16;
      8'd248: powQ <= 10'h14;
      8'd249: powQ <= 10'h11;
      8'd250: powQ <= 10'he;
      8'd251: powQ <= 10'hb;
      8'd252: powQ <= 10'h8;
      8'd253: powQ <= 10'h6;
      8'd254: powQ <= 10'h3;
      8'd255: powQ <= 10'h0;
      default: powQ <= 10'h0;
    endcase
  end
  always @(posedge clock) begin
    case (phAddr)
      10'd0: phQ <= 12'h513;
      10'd1: phQ <= 12'h514;
      10'd2: phQ <= 12'h515;
      10'd3: phQ <= 12'h516;
      10'd4: phQ <= 12'h517;
      10'd5: phQ <= 12'h518;
      10'd6: phQ <= 12'h519;
      10'd7: phQ <= 12'h51a;
      10'd8: phQ <= 12'h51c;
      10'd9: phQ <= 12'h51d;
      10'd10: phQ <= 12'h51e;
      10'd11: phQ <= 12'h51f;
      10'd12: phQ <= 12'h521;
      10'd13: phQ <= 12'h522;
      10'd14: phQ <= 12'h523;
      10'd15: phQ <= 12'h524;
      10'd16: phQ <= 12'h526;
      10'd17: phQ <= 12'h527;
      10'd18: phQ <= 12'h528;
      10'd19: phQ <= 12'h529;
      10'd20: phQ <= 12'h52a;
      10'd21: phQ <= 12'h52b;
      10'd22: phQ <= 12'h52c;
      10'd23: phQ <= 12'h52d;
      10'd24: phQ <= 12'h52f;
      10'd25: phQ <= 12'h530;
      10'd26: phQ <= 12'h531;
      10'd27: phQ <= 12'h532;
      10'd28: phQ <= 12'h534;
      10'd29: phQ <= 12'h535;
      10'd30: phQ <= 12'h536;
      10'd31: phQ <= 12'h537;
      10'd32: phQ <= 12'h539;
      10'd33: phQ <= 12'h53a;
      10'd34: phQ <= 12'h53b;
      10'd35: phQ <= 12'h53c;
      10'd36: phQ <= 12'h53d;
      10'd37: phQ <= 12'h53e;
      10'd38: phQ <= 12'h53f;
      10'd39: phQ <= 12'h540;
      10'd40: phQ <= 12'h542;
      10'd41: phQ <= 12'h543;
      10'd42: phQ <= 12'h544;
      10'd43: phQ <= 12'h545;
      10'd44: phQ <= 12'h547;
      10'd45: phQ <= 12'h548;
      10'd46: phQ <= 12'h549;
      10'd47: phQ <= 12'h54a;
      10'd48: phQ <= 12'h54c;
      10'd49: phQ <= 12'h54d;
      10'd50: phQ <= 12'h54e;
      10'd51: phQ <= 12'h54f;
      10'd52: phQ <= 12'h551;
      10'd53: phQ <= 12'h552;
      10'd54: phQ <= 12'h553;
      10'd55: phQ <= 12'h554;
      10'd56: phQ <= 12'h556;
      10'd57: phQ <= 12'h557;
      10'd58: phQ <= 12'h558;
      10'd59: phQ <= 12'h559;
      10'd60: phQ <= 12'h55b;
      10'd61: phQ <= 12'h55c;
      10'd62: phQ <= 12'h55d;
      10'd63: phQ <= 12'h55e;
      10'd64: phQ <= 12'h560;
      10'd65: phQ <= 12'h561;
      10'd66: phQ <= 12'h562;
      10'd67: phQ <= 12'h563;
      10'd68: phQ <= 12'h565;
      10'd69: phQ <= 12'h566;
      10'd70: phQ <= 12'h567;
      10'd71: phQ <= 12'h568;
      10'd72: phQ <= 12'h56a;
      10'd73: phQ <= 12'h56b;
      10'd74: phQ <= 12'h56c;
      10'd75: phQ <= 12'h56d;
      10'd76: phQ <= 12'h56f;
      10'd77: phQ <= 12'h570;
      10'd78: phQ <= 12'h571;
      10'd79: phQ <= 12'h572;
      10'd80: phQ <= 12'h574;
      10'd81: phQ <= 12'h575;
      10'd82: phQ <= 12'h576;
      10'd83: phQ <= 12'h577;
      10'd84: phQ <= 12'h579;
      10'd85: phQ <= 12'h57a;
      10'd86: phQ <= 12'h57b;
      10'd87: phQ <= 12'h57c;
      10'd88: phQ <= 12'h57e;
      10'd89: phQ <= 12'h57f;
      10'd90: phQ <= 12'h580;
      10'd91: phQ <= 12'h581;
      10'd92: phQ <= 12'h583;
      10'd93: phQ <= 12'h584;
      10'd94: phQ <= 12'h585;
      10'd95: phQ <= 12'h586;
      10'd96: phQ <= 12'h588;
      10'd97: phQ <= 12'h589;
      10'd98: phQ <= 12'h58a;
      10'd99: phQ <= 12'h58b;
      10'd100: phQ <= 12'h58d;
      10'd101: phQ <= 12'h58e;
      10'd102: phQ <= 12'h58f;
      10'd103: phQ <= 12'h590;
      10'd104: phQ <= 12'h592;
      10'd105: phQ <= 12'h593;
      10'd106: phQ <= 12'h595;
      10'd107: phQ <= 12'h596;
      10'd108: phQ <= 12'h597;
      10'd109: phQ <= 12'h598;
      10'd110: phQ <= 12'h59a;
      10'd111: phQ <= 12'h59b;
      10'd112: phQ <= 12'h59d;
      10'd113: phQ <= 12'h59e;
      10'd114: phQ <= 12'h59f;
      10'd115: phQ <= 12'h5a0;
      10'd116: phQ <= 12'h5a2;
      10'd117: phQ <= 12'h5a3;
      10'd118: phQ <= 12'h5a4;
      10'd119: phQ <= 12'h5a5;
      10'd120: phQ <= 12'h5a7;
      10'd121: phQ <= 12'h5a8;
      10'd122: phQ <= 12'h5a9;
      10'd123: phQ <= 12'h5aa;
      10'd124: phQ <= 12'h5ac;
      10'd125: phQ <= 12'h5ad;
      10'd126: phQ <= 12'h5ae;
      10'd127: phQ <= 12'h5af;
      10'd128: phQ <= 12'h5b2;
      10'd129: phQ <= 12'h5b3;
      10'd130: phQ <= 12'h5b4;
      10'd131: phQ <= 12'h5b5;
      10'd132: phQ <= 12'h5b7;
      10'd133: phQ <= 12'h5b8;
      10'd134: phQ <= 12'h5b9;
      10'd135: phQ <= 12'h5ba;
      10'd136: phQ <= 12'h5bc;
      10'd137: phQ <= 12'h5bd;
      10'd138: phQ <= 12'h5bf;
      10'd139: phQ <= 12'h5c0;
      10'd140: phQ <= 12'h5c1;
      10'd141: phQ <= 12'h5c2;
      10'd142: phQ <= 12'h5c4;
      10'd143: phQ <= 12'h5c5;
      10'd144: phQ <= 12'h5c7;
      10'd145: phQ <= 12'h5c8;
      10'd146: phQ <= 12'h5c9;
      10'd147: phQ <= 12'h5ca;
      10'd148: phQ <= 12'h5cc;
      10'd149: phQ <= 12'h5cd;
      10'd150: phQ <= 12'h5ce;
      10'd151: phQ <= 12'h5cf;
      10'd152: phQ <= 12'h5d1;
      10'd153: phQ <= 12'h5d2;
      10'd154: phQ <= 12'h5d4;
      10'd155: phQ <= 12'h5d5;
      10'd156: phQ <= 12'h5d6;
      10'd157: phQ <= 12'h5d7;
      10'd158: phQ <= 12'h5d9;
      10'd159: phQ <= 12'h5da;
      10'd160: phQ <= 12'h5dd;
      10'd161: phQ <= 12'h5de;
      10'd162: phQ <= 12'h5df;
      10'd163: phQ <= 12'h5e0;
      10'd164: phQ <= 12'h5e2;
      10'd165: phQ <= 12'h5e3;
      10'd166: phQ <= 12'h5e5;
      10'd167: phQ <= 12'h5e6;
      10'd168: phQ <= 12'h5e8;
      10'd169: phQ <= 12'h5e9;
      10'd170: phQ <= 12'h5ea;
      10'd171: phQ <= 12'h5eb;
      10'd172: phQ <= 12'h5ed;
      10'd173: phQ <= 12'h5ee;
      10'd174: phQ <= 12'h5f0;
      10'd175: phQ <= 12'h5f1;
      10'd176: phQ <= 12'h5f3;
      10'd177: phQ <= 12'h5f4;
      10'd178: phQ <= 12'h5f5;
      10'd179: phQ <= 12'h5f6;
      10'd180: phQ <= 12'h5f8;
      10'd181: phQ <= 12'h5f9;
      10'd182: phQ <= 12'h5fb;
      10'd183: phQ <= 12'h5fc;
      10'd184: phQ <= 12'h5fe;
      10'd185: phQ <= 12'h5ff;
      10'd186: phQ <= 12'h600;
      10'd187: phQ <= 12'h601;
      10'd188: phQ <= 12'h603;
      10'd189: phQ <= 12'h604;
      10'd190: phQ <= 12'h606;
      10'd191: phQ <= 12'h607;
      10'd192: phQ <= 12'h609;
      10'd193: phQ <= 12'h60a;
      10'd194: phQ <= 12'h60b;
      10'd195: phQ <= 12'h60c;
      10'd196: phQ <= 12'h60e;
      10'd197: phQ <= 12'h60f;
      10'd198: phQ <= 12'h611;
      10'd199: phQ <= 12'h612;
      10'd200: phQ <= 12'h614;
      10'd201: phQ <= 12'h615;
      10'd202: phQ <= 12'h616;
      10'd203: phQ <= 12'h617;
      10'd204: phQ <= 12'h619;
      10'd205: phQ <= 12'h61a;
      10'd206: phQ <= 12'h61c;
      10'd207: phQ <= 12'h61d;
      10'd208: phQ <= 12'h61f;
      10'd209: phQ <= 12'h620;
      10'd210: phQ <= 12'h621;
      10'd211: phQ <= 12'h622;
      10'd212: phQ <= 12'h624;
      10'd213: phQ <= 12'h625;
      10'd214: phQ <= 12'h627;
      10'd215: phQ <= 12'h628;
      10'd216: phQ <= 12'h62a;
      10'd217: phQ <= 12'h62b;
      10'd218: phQ <= 12'h62c;
      10'd219: phQ <= 12'h62d;
      10'd220: phQ <= 12'h62f;
      10'd221: phQ <= 12'h630;
      10'd222: phQ <= 12'h632;
      10'd223: phQ <= 12'h633;
      10'd224: phQ <= 12'h636;
      10'd225: phQ <= 12'h637;
      10'd226: phQ <= 12'h638;
      10'd227: phQ <= 12'h639;
      10'd228: phQ <= 12'h63b;
      10'd229: phQ <= 12'h63c;
      10'd230: phQ <= 12'h63e;
      10'd231: phQ <= 12'h63f;
      10'd232: phQ <= 12'h641;
      10'd233: phQ <= 12'h642;
      10'd234: phQ <= 12'h644;
      10'd235: phQ <= 12'h645;
      10'd236: phQ <= 12'h647;
      10'd237: phQ <= 12'h648;
      10'd238: phQ <= 12'h649;
      10'd239: phQ <= 12'h64a;
      10'd240: phQ <= 12'h64d;
      10'd241: phQ <= 12'h64e;
      10'd242: phQ <= 12'h64f;
      10'd243: phQ <= 12'h650;
      10'd244: phQ <= 12'h652;
      10'd245: phQ <= 12'h653;
      10'd246: phQ <= 12'h655;
      10'd247: phQ <= 12'h656;
      10'd248: phQ <= 12'h658;
      10'd249: phQ <= 12'h659;
      10'd250: phQ <= 12'h65b;
      10'd251: phQ <= 12'h65c;
      10'd252: phQ <= 12'h65e;
      10'd253: phQ <= 12'h65f;
      10'd254: phQ <= 12'h660;
      10'd255: phQ <= 12'h661;
      10'd256: phQ <= 12'h665;
      10'd257: phQ <= 12'h666;
      10'd258: phQ <= 12'h667;
      10'd259: phQ <= 12'h668;
      10'd260: phQ <= 12'h66a;
      10'd261: phQ <= 12'h66b;
      10'd262: phQ <= 12'h66d;
      10'd263: phQ <= 12'h66e;
      10'd264: phQ <= 12'h670;
      10'd265: phQ <= 12'h671;
      10'd266: phQ <= 12'h673;
      10'd267: phQ <= 12'h674;
      10'd268: phQ <= 12'h676;
      10'd269: phQ <= 12'h677;
      10'd270: phQ <= 12'h678;
      10'd271: phQ <= 12'h679;
      10'd272: phQ <= 12'h67c;
      10'd273: phQ <= 12'h67d;
      10'd274: phQ <= 12'h67f;
      10'd275: phQ <= 12'h680;
      10'd276: phQ <= 12'h682;
      10'd277: phQ <= 12'h683;
      10'd278: phQ <= 12'h685;
      10'd279: phQ <= 12'h686;
      10'd280: phQ <= 12'h688;
      10'd281: phQ <= 12'h689;
      10'd282: phQ <= 12'h68b;
      10'd283: phQ <= 12'h68c;
      10'd284: phQ <= 12'h68e;
      10'd285: phQ <= 12'h68f;
      10'd286: phQ <= 12'h691;
      10'd287: phQ <= 12'h692;
      10'd288: phQ <= 12'h695;
      10'd289: phQ <= 12'h696;
      10'd290: phQ <= 12'h698;
      10'd291: phQ <= 12'h699;
      10'd292: phQ <= 12'h69b;
      10'd293: phQ <= 12'h69c;
      10'd294: phQ <= 12'h69e;
      10'd295: phQ <= 12'h69f;
      10'd296: phQ <= 12'h6a1;
      10'd297: phQ <= 12'h6a2;
      10'd298: phQ <= 12'h6a4;
      10'd299: phQ <= 12'h6a5;
      10'd300: phQ <= 12'h6a7;
      10'd301: phQ <= 12'h6a8;
      10'd302: phQ <= 12'h6aa;
      10'd303: phQ <= 12'h6ab;
      10'd304: phQ <= 12'h6ad;
      10'd305: phQ <= 12'h6ae;
      10'd306: phQ <= 12'h6b0;
      10'd307: phQ <= 12'h6b1;
      10'd308: phQ <= 12'h6b3;
      10'd309: phQ <= 12'h6b4;
      10'd310: phQ <= 12'h6b6;
      10'd311: phQ <= 12'h6b7;
      10'd312: phQ <= 12'h6b9;
      10'd313: phQ <= 12'h6ba;
      10'd314: phQ <= 12'h6bc;
      10'd315: phQ <= 12'h6bd;
      10'd316: phQ <= 12'h6bf;
      10'd317: phQ <= 12'h6c0;
      10'd318: phQ <= 12'h6c2;
      10'd319: phQ <= 12'h6c3;
      10'd320: phQ <= 12'h6c6;
      10'd321: phQ <= 12'h6c7;
      10'd322: phQ <= 12'h6c9;
      10'd323: phQ <= 12'h6ca;
      10'd324: phQ <= 12'h6cc;
      10'd325: phQ <= 12'h6cd;
      10'd326: phQ <= 12'h6cf;
      10'd327: phQ <= 12'h6d0;
      10'd328: phQ <= 12'h6d2;
      10'd329: phQ <= 12'h6d4;
      10'd330: phQ <= 12'h6d5;
      10'd331: phQ <= 12'h6d7;
      10'd332: phQ <= 12'h6d8;
      10'd333: phQ <= 12'h6da;
      10'd334: phQ <= 12'h6db;
      10'd335: phQ <= 12'h6dd;
      10'd336: phQ <= 12'h6df;
      10'd337: phQ <= 12'h6e0;
      10'd338: phQ <= 12'h6e2;
      10'd339: phQ <= 12'h6e3;
      10'd340: phQ <= 12'h6e5;
      10'd341: phQ <= 12'h6e6;
      10'd342: phQ <= 12'h6e8;
      10'd343: phQ <= 12'h6e9;
      10'd344: phQ <= 12'h6eb;
      10'd345: phQ <= 12'h6ed;
      10'd346: phQ <= 12'h6ee;
      10'd347: phQ <= 12'h6f0;
      10'd348: phQ <= 12'h6f1;
      10'd349: phQ <= 12'h6f3;
      10'd350: phQ <= 12'h6f4;
      10'd351: phQ <= 12'h6f6;
      10'd352: phQ <= 12'h6f9;
      10'd353: phQ <= 12'h6fa;
      10'd354: phQ <= 12'h6fc;
      10'd355: phQ <= 12'h6fd;
      10'd356: phQ <= 12'h6ff;
      10'd357: phQ <= 12'h701;
      10'd358: phQ <= 12'h702;
      10'd359: phQ <= 12'h704;
      10'd360: phQ <= 12'h706;
      10'd361: phQ <= 12'h707;
      10'd362: phQ <= 12'h709;
      10'd363: phQ <= 12'h70a;
      10'd364: phQ <= 12'h70c;
      10'd365: phQ <= 12'h70e;
      10'd366: phQ <= 12'h70f;
      10'd367: phQ <= 12'h711;
      10'd368: phQ <= 12'h713;
      10'd369: phQ <= 12'h714;
      10'd370: phQ <= 12'h716;
      10'd371: phQ <= 12'h717;
      10'd372: phQ <= 12'h719;
      10'd373: phQ <= 12'h71b;
      10'd374: phQ <= 12'h71c;
      10'd375: phQ <= 12'h71e;
      10'd376: phQ <= 12'h720;
      10'd377: phQ <= 12'h721;
      10'd378: phQ <= 12'h723;
      10'd379: phQ <= 12'h724;
      10'd380: phQ <= 12'h726;
      10'd381: phQ <= 12'h728;
      10'd382: phQ <= 12'h729;
      10'd383: phQ <= 12'h72b;
      10'd384: phQ <= 12'h72d;
      10'd385: phQ <= 12'h72e;
      10'd386: phQ <= 12'h730;
      10'd387: phQ <= 12'h731;
      10'd388: phQ <= 12'h733;
      10'd389: phQ <= 12'h735;
      10'd390: phQ <= 12'h736;
      10'd391: phQ <= 12'h738;
      10'd392: phQ <= 12'h73a;
      10'd393: phQ <= 12'h73b;
      10'd394: phQ <= 12'h73d;
      10'd395: phQ <= 12'h73e;
      10'd396: phQ <= 12'h740;
      10'd397: phQ <= 12'h742;
      10'd398: phQ <= 12'h743;
      10'd399: phQ <= 12'h745;
      10'd400: phQ <= 12'h748;
      10'd401: phQ <= 12'h749;
      10'd402: phQ <= 12'h74b;
      10'd403: phQ <= 12'h74c;
      10'd404: phQ <= 12'h74e;
      10'd405: phQ <= 12'h750;
      10'd406: phQ <= 12'h751;
      10'd407: phQ <= 12'h753;
      10'd408: phQ <= 12'h755;
      10'd409: phQ <= 12'h757;
      10'd410: phQ <= 12'h758;
      10'd411: phQ <= 12'h75a;
      10'd412: phQ <= 12'h75c;
      10'd413: phQ <= 12'h75d;
      10'd414: phQ <= 12'h75f;
      10'd415: phQ <= 12'h760;
      10'd416: phQ <= 12'h763;
      10'd417: phQ <= 12'h764;
      10'd418: phQ <= 12'h766;
      10'd419: phQ <= 12'h767;
      10'd420: phQ <= 12'h769;
      10'd421: phQ <= 12'h76b;
      10'd422: phQ <= 12'h76c;
      10'd423: phQ <= 12'h76e;
      10'd424: phQ <= 12'h770;
      10'd425: phQ <= 12'h772;
      10'd426: phQ <= 12'h773;
      10'd427: phQ <= 12'h775;
      10'd428: phQ <= 12'h777;
      10'd429: phQ <= 12'h778;
      10'd430: phQ <= 12'h77a;
      10'd431: phQ <= 12'h77b;
      10'd432: phQ <= 12'h77e;
      10'd433: phQ <= 12'h77f;
      10'd434: phQ <= 12'h781;
      10'd435: phQ <= 12'h783;
      10'd436: phQ <= 12'h785;
      10'd437: phQ <= 12'h786;
      10'd438: phQ <= 12'h788;
      10'd439: phQ <= 12'h78a;
      10'd440: phQ <= 12'h78c;
      10'd441: phQ <= 12'h78d;
      10'd442: phQ <= 12'h78f;
      10'd443: phQ <= 12'h791;
      10'd444: phQ <= 12'h793;
      10'd445: phQ <= 12'h794;
      10'd446: phQ <= 12'h796;
      10'd447: phQ <= 12'h798;
      10'd448: phQ <= 12'h79a;
      10'd449: phQ <= 12'h79b;
      10'd450: phQ <= 12'h79d;
      10'd451: phQ <= 12'h79f;
      10'd452: phQ <= 12'h7a1;
      10'd453: phQ <= 12'h7a2;
      10'd454: phQ <= 12'h7a4;
      10'd455: phQ <= 12'h7a6;
      10'd456: phQ <= 12'h7a8;
      10'd457: phQ <= 12'h7a9;
      10'd458: phQ <= 12'h7ab;
      10'd459: phQ <= 12'h7ad;
      10'd460: phQ <= 12'h7af;
      10'd461: phQ <= 12'h7b0;
      10'd462: phQ <= 12'h7b2;
      10'd463: phQ <= 12'h7b4;
      10'd464: phQ <= 12'h7b7;
      10'd465: phQ <= 12'h7b8;
      10'd466: phQ <= 12'h7ba;
      10'd467: phQ <= 12'h7bc;
      10'd468: phQ <= 12'h7be;
      10'd469: phQ <= 12'h7bf;
      10'd470: phQ <= 12'h7c1;
      10'd471: phQ <= 12'h7c3;
      10'd472: phQ <= 12'h7c5;
      10'd473: phQ <= 12'h7c6;
      10'd474: phQ <= 12'h7c8;
      10'd475: phQ <= 12'h7ca;
      10'd476: phQ <= 12'h7cc;
      10'd477: phQ <= 12'h7cd;
      10'd478: phQ <= 12'h7cf;
      10'd479: phQ <= 12'h7d1;
      10'd480: phQ <= 12'h7d3;
      10'd481: phQ <= 12'h7d4;
      10'd482: phQ <= 12'h7d6;
      10'd483: phQ <= 12'h7d8;
      10'd484: phQ <= 12'h7da;
      10'd485: phQ <= 12'h7db;
      10'd486: phQ <= 12'h7dd;
      10'd487: phQ <= 12'h7df;
      10'd488: phQ <= 12'h7e1;
      10'd489: phQ <= 12'h7e3;
      10'd490: phQ <= 12'h7e5;
      10'd491: phQ <= 12'h7e6;
      10'd492: phQ <= 12'h7e8;
      10'd493: phQ <= 12'h7ea;
      10'd494: phQ <= 12'h7ec;
      10'd495: phQ <= 12'h7ed;
      10'd496: phQ <= 12'h7f0;
      10'd497: phQ <= 12'h7f1;
      10'd498: phQ <= 12'h7f3;
      10'd499: phQ <= 12'h7f5;
      10'd500: phQ <= 12'h7f7;
      10'd501: phQ <= 12'h7f9;
      10'd502: phQ <= 12'h7fb;
      10'd503: phQ <= 12'h7fc;
      10'd504: phQ <= 12'h7ff;
      10'd505: phQ <= 12'h800;
      10'd506: phQ <= 12'h802;
      10'd507: phQ <= 12'h804;
      10'd508: phQ <= 12'h806;
      10'd509: phQ <= 12'h808;
      10'd510: phQ <= 12'h80a;
      10'd511: phQ <= 12'h80b;
      10'd512: phQ <= 12'h80e;
      10'd513: phQ <= 12'h80f;
      10'd514: phQ <= 12'h811;
      10'd515: phQ <= 12'h813;
      10'd516: phQ <= 12'h815;
      10'd517: phQ <= 12'h817;
      10'd518: phQ <= 12'h819;
      10'd519: phQ <= 12'h81a;
      10'd520: phQ <= 12'h81d;
      10'd521: phQ <= 12'h81e;
      10'd522: phQ <= 12'h820;
      10'd523: phQ <= 12'h822;
      10'd524: phQ <= 12'h824;
      10'd525: phQ <= 12'h826;
      10'd526: phQ <= 12'h828;
      10'd527: phQ <= 12'h829;
      10'd528: phQ <= 12'h82c;
      10'd529: phQ <= 12'h82d;
      10'd530: phQ <= 12'h82f;
      10'd531: phQ <= 12'h831;
      10'd532: phQ <= 12'h833;
      10'd533: phQ <= 12'h835;
      10'd534: phQ <= 12'h837;
      10'd535: phQ <= 12'h838;
      10'd536: phQ <= 12'h83b;
      10'd537: phQ <= 12'h83c;
      10'd538: phQ <= 12'h83e;
      10'd539: phQ <= 12'h840;
      10'd540: phQ <= 12'h842;
      10'd541: phQ <= 12'h844;
      10'd542: phQ <= 12'h846;
      10'd543: phQ <= 12'h847;
      10'd544: phQ <= 12'h84a;
      10'd545: phQ <= 12'h84b;
      10'd546: phQ <= 12'h84d;
      10'd547: phQ <= 12'h84f;
      10'd548: phQ <= 12'h851;
      10'd549: phQ <= 12'h853;
      10'd550: phQ <= 12'h855;
      10'd551: phQ <= 12'h856;
      10'd552: phQ <= 12'h859;
      10'd553: phQ <= 12'h85b;
      10'd554: phQ <= 12'h85d;
      10'd555: phQ <= 12'h85e;
      10'd556: phQ <= 12'h861;
      10'd557: phQ <= 12'h862;
      10'd558: phQ <= 12'h864;
      10'd559: phQ <= 12'h866;
      10'd560: phQ <= 12'h869;
      10'd561: phQ <= 12'h86a;
      10'd562: phQ <= 12'h86c;
      10'd563: phQ <= 12'h86e;
      10'd564: phQ <= 12'h870;
      10'd565: phQ <= 12'h872;
      10'd566: phQ <= 12'h874;
      10'd567: phQ <= 12'h875;
      10'd568: phQ <= 12'h878;
      10'd569: phQ <= 12'h87a;
      10'd570: phQ <= 12'h87c;
      10'd571: phQ <= 12'h87d;
      10'd572: phQ <= 12'h880;
      10'd573: phQ <= 12'h881;
      10'd574: phQ <= 12'h883;
      10'd575: phQ <= 12'h885;
      10'd576: phQ <= 12'h889;
      10'd577: phQ <= 12'h88a;
      10'd578: phQ <= 12'h88c;
      10'd579: phQ <= 12'h88e;
      10'd580: phQ <= 12'h890;
      10'd581: phQ <= 12'h892;
      10'd582: phQ <= 12'h894;
      10'd583: phQ <= 12'h895;
      10'd584: phQ <= 12'h898;
      10'd585: phQ <= 12'h89a;
      10'd586: phQ <= 12'h89c;
      10'd587: phQ <= 12'h89d;
      10'd588: phQ <= 12'h8a0;
      10'd589: phQ <= 12'h8a1;
      10'd590: phQ <= 12'h8a3;
      10'd591: phQ <= 12'h8a5;
      10'd592: phQ <= 12'h8a8;
      10'd593: phQ <= 12'h8aa;
      10'd594: phQ <= 12'h8ac;
      10'd595: phQ <= 12'h8ae;
      10'd596: phQ <= 12'h8af;
      10'd597: phQ <= 12'h8b2;
      10'd598: phQ <= 12'h8b3;
      10'd599: phQ <= 12'h8b6;
      10'd600: phQ <= 12'h8b8;
      10'd601: phQ <= 12'h8ba;
      10'd602: phQ <= 12'h8bc;
      10'd603: phQ <= 12'h8be;
      10'd604: phQ <= 12'h8bf;
      10'd605: phQ <= 12'h8c2;
      10'd606: phQ <= 12'h8c3;
      10'd607: phQ <= 12'h8c6;
      10'd608: phQ <= 12'h8c9;
      10'd609: phQ <= 12'h8cb;
      10'd610: phQ <= 12'h8cd;
      10'd611: phQ <= 12'h8cf;
      10'd612: phQ <= 12'h8d0;
      10'd613: phQ <= 12'h8d3;
      10'd614: phQ <= 12'h8d4;
      10'd615: phQ <= 12'h8d7;
      10'd616: phQ <= 12'h8d9;
      10'd617: phQ <= 12'h8db;
      10'd618: phQ <= 12'h8dd;
      10'd619: phQ <= 12'h8df;
      10'd620: phQ <= 12'h8e0;
      10'd621: phQ <= 12'h8e3;
      10'd622: phQ <= 12'h8e4;
      10'd623: phQ <= 12'h8e7;
      10'd624: phQ <= 12'h8e9;
      10'd625: phQ <= 12'h8eb;
      10'd626: phQ <= 12'h8ed;
      10'd627: phQ <= 12'h8ef;
      10'd628: phQ <= 12'h8f0;
      10'd629: phQ <= 12'h8f3;
      10'd630: phQ <= 12'h8f4;
      10'd631: phQ <= 12'h8f7;
      10'd632: phQ <= 12'h8f9;
      10'd633: phQ <= 12'h8fb;
      10'd634: phQ <= 12'h8fd;
      10'd635: phQ <= 12'h8ff;
      10'd636: phQ <= 12'h900;
      10'd637: phQ <= 12'h903;
      10'd638: phQ <= 12'h904;
      10'd639: phQ <= 12'h907;
      10'd640: phQ <= 12'h90b;
      10'd641: phQ <= 12'h90d;
      10'd642: phQ <= 12'h90f;
      10'd643: phQ <= 12'h911;
      10'd644: phQ <= 12'h912;
      10'd645: phQ <= 12'h915;
      10'd646: phQ <= 12'h916;
      10'd647: phQ <= 12'h919;
      10'd648: phQ <= 12'h91b;
      10'd649: phQ <= 12'h91d;
      10'd650: phQ <= 12'h91f;
      10'd651: phQ <= 12'h921;
      10'd652: phQ <= 12'h922;
      10'd653: phQ <= 12'h925;
      10'd654: phQ <= 12'h926;
      10'd655: phQ <= 12'h929;
      10'd656: phQ <= 12'h92c;
      10'd657: phQ <= 12'h92e;
      10'd658: phQ <= 12'h930;
      10'd659: phQ <= 12'h932;
      10'd660: phQ <= 12'h933;
      10'd661: phQ <= 12'h936;
      10'd662: phQ <= 12'h937;
      10'd663: phQ <= 12'h93a;
      10'd664: phQ <= 12'h93c;
      10'd665: phQ <= 12'h93e;
      10'd666: phQ <= 12'h940;
      10'd667: phQ <= 12'h942;
      10'd668: phQ <= 12'h943;
      10'd669: phQ <= 12'h946;
      10'd670: phQ <= 12'h947;
      10'd671: phQ <= 12'h94a;
      10'd672: phQ <= 12'h94e;
      10'd673: phQ <= 12'h950;
      10'd674: phQ <= 12'h952;
      10'd675: phQ <= 12'h954;
      10'd676: phQ <= 12'h955;
      10'd677: phQ <= 12'h958;
      10'd678: phQ <= 12'h959;
      10'd679: phQ <= 12'h95c;
      10'd680: phQ <= 12'h95e;
      10'd681: phQ <= 12'h960;
      10'd682: phQ <= 12'h962;
      10'd683: phQ <= 12'h964;
      10'd684: phQ <= 12'h967;
      10'd685: phQ <= 12'h96a;
      10'd686: phQ <= 12'h96b;
      10'd687: phQ <= 12'h96e;
      10'd688: phQ <= 12'h971;
      10'd689: phQ <= 12'h973;
      10'd690: phQ <= 12'h975;
      10'd691: phQ <= 12'h977;
      10'd692: phQ <= 12'h978;
      10'd693: phQ <= 12'h97b;
      10'd694: phQ <= 12'h97c;
      10'd695: phQ <= 12'h97f;
      10'd696: phQ <= 12'h981;
      10'd697: phQ <= 12'h983;
      10'd698: phQ <= 12'h985;
      10'd699: phQ <= 12'h987;
      10'd700: phQ <= 12'h98a;
      10'd701: phQ <= 12'h98d;
      10'd702: phQ <= 12'h98e;
      10'd703: phQ <= 12'h991;
      10'd704: phQ <= 12'h994;
      10'd705: phQ <= 12'h996;
      10'd706: phQ <= 12'h998;
      10'd707: phQ <= 12'h99a;
      10'd708: phQ <= 12'h99b;
      10'd709: phQ <= 12'h99e;
      10'd710: phQ <= 12'h99f;
      10'd711: phQ <= 12'h9a2;
      10'd712: phQ <= 12'h9a4;
      10'd713: phQ <= 12'h9a6;
      10'd714: phQ <= 12'h9a8;
      10'd715: phQ <= 12'h9aa;
      10'd716: phQ <= 12'h9ad;
      10'd717: phQ <= 12'h9b0;
      10'd718: phQ <= 12'h9b1;
      10'd719: phQ <= 12'h9b4;
      10'd720: phQ <= 12'h9b8;
      10'd721: phQ <= 12'h9ba;
      10'd722: phQ <= 12'h9bc;
      10'd723: phQ <= 12'h9be;
      10'd724: phQ <= 12'h9bf;
      10'd725: phQ <= 12'h9c2;
      10'd726: phQ <= 12'h9c3;
      10'd727: phQ <= 12'h9c6;
      10'd728: phQ <= 12'h9c8;
      10'd729: phQ <= 12'h9ca;
      10'd730: phQ <= 12'h9cc;
      10'd731: phQ <= 12'h9ce;
      10'd732: phQ <= 12'h9d1;
      10'd733: phQ <= 12'h9d4;
      10'd734: phQ <= 12'h9d5;
      10'd735: phQ <= 12'h9d8;
      10'd736: phQ <= 12'h9dc;
      10'd737: phQ <= 12'h9de;
      10'd738: phQ <= 12'h9e0;
      10'd739: phQ <= 12'h9e2;
      10'd740: phQ <= 12'h9e3;
      10'd741: phQ <= 12'h9e6;
      10'd742: phQ <= 12'h9e7;
      10'd743: phQ <= 12'h9ea;
      10'd744: phQ <= 12'h9ec;
      10'd745: phQ <= 12'h9ee;
      10'd746: phQ <= 12'h9f0;
      10'd747: phQ <= 12'h9f2;
      10'd748: phQ <= 12'h9f5;
      10'd749: phQ <= 12'h9f8;
      10'd750: phQ <= 12'h9f9;
      10'd751: phQ <= 12'h9fc;
      10'd752: phQ <= 12'ha01;
      10'd753: phQ <= 12'ha03;
      10'd754: phQ <= 12'ha05;
      10'd755: phQ <= 12'ha07;
      10'd756: phQ <= 12'ha08;
      10'd757: phQ <= 12'ha0b;
      10'd758: phQ <= 12'ha0c;
      10'd759: phQ <= 12'ha0f;
      10'd760: phQ <= 12'ha11;
      10'd761: phQ <= 12'ha13;
      10'd762: phQ <= 12'ha15;
      10'd763: phQ <= 12'ha17;
      10'd764: phQ <= 12'ha1a;
      10'd765: phQ <= 12'ha1d;
      10'd766: phQ <= 12'ha1e;
      10'd767: phQ <= 12'ha21;
      default: phQ <= 12'h0;
    endcase
  end

  // ------------------------------------------- operator registers and state
  wire       opWe = st == S_INIT || (apply && wa[7:6] != 2'b00 && wa[7:5] != 3'b001);
  wire [4:0] opWa = st == S_INIT ? initSlot : wa[4:0];
  wire [7:0] opWd = st == S_INIT ? 8'd0 : wd;
  wire [2:0] opWf = st == S_INIT ? 3'd0 : wa[7:5];  // 0 = every field (init)
  reg  [6:0] qDtMul, qTl;
  reg  [7:0] qKsAr, qAmD1r, qDt2D2r, qD1lRr;
  reg [32:0] qOst;
  reg        ostWe;
  reg  [4:0] ostWa;
  reg [32:0] ostWd;

  always @(posedge clock) begin
    if (opWe && (opWf == 3'd0 || opWf == 3'd2)) rDtMul [opWa] <= opWd[6:0];
    if (opWe && (opWf == 3'd0 || opWf == 3'd3)) rTl    [opWa] <= opWd[6:0];
    if (opWe && (opWf == 3'd0 || opWf == 3'd4)) rKsAr  [opWa] <= opWd;
    if (opWe && (opWf == 3'd0 || opWf == 3'd5)) rAmD1r [opWa] <= opWd;
    if (opWe && (opWf == 3'd0 || opWf == 3'd6)) rDt2D2r[opWa] <= opWd;
    if (opWe && (opWf == 3'd0 || opWf == 3'd7)) rD1lRr [opWa] <= opWd;
    qDtMul  <= rDtMul [slot];
    qTl     <= rTl    [slot];
    qKsAr   <= rKsAr  [slot];
    qAmD1r  <= rAmD1r [slot];
    qDt2D2r <= rDt2D2r[slot];
    qD1lRr  <= rD1lRr [slot];
    if (ostWe) ost[ostWa] <= ostWd;
    qOst <= ost[slot];
  end

  // ------------------------------------------------------ engine registers
  reg [24:0] lfsr;
  reg  [7:0] ncnt;
  reg        nstate;
  reg [29:0] lfoCnt;
  reg  [7:0] lfoPrev, rdPrev, wrPrev, t0, lfoN, rdNoise;
  reg  [7:0] am8, pm8;
  reg  [7:0] lfoAm;
  reg signed [7:0] lfoPm;
  reg  [1:0] ecl;
  reg [13:0] ech;
  reg        envTick;
  reg [12:0] pcnt;
  reg        prep;
  reg  [7:0] active;
  reg        actAcc;
  reg signed [13:0] fb0 [0:7];
  reg signed [13:0] fb1 [0:7];
  reg signed [13:0] fbin [0:7];
  reg signed [18:0] accL, accR;

  // the operator being clocked
  reg  [5:0] rA, rD, rS, rR;            // effective rates
  reg  [9:0] sus;
  reg signed [5:0] det;
  reg  [4:0] mulx;
  reg  [2:0] phSh;
  reg        s1Key;
  reg  [1:0] s1State;
  reg  [9:0] s1Att;
  reg [19:0] s1Phase;
  reg  [1:0] s2State;
  reg  [5:0] s2Rate;
  reg  [3:0] s2Inc;
  reg        s2Do;
  reg [16:0] base;
  reg  [9:0] s3Att;
  reg [21:0] step;

  // the channel's four operators, for the output
  reg  [9:0] phx  [0:3];
  reg  [9:0] attx [0:3];
  reg  [6:0] tlx  [0:3];
  reg        amx  [0:3];
  reg signed [13:0] opo [0:3];
  reg        sign, quiet;
  reg  [9:0] envT;
  reg  [4:0] xsh;

  // ----------------------------------------------- combinational: clocking
  wire [6:0] kc      = rKc[c];
  wire [5:0] kf      = rKf[c];
  wire [2:0] pms     = rPms[c][6:4];
  wire [1:0] ams     = rPms[c][1:0];
  wire [4:0] keycode = kc[6:2];
  wire [4:0] ksr     = keycode >> (~qKsAr[7:6]);
  wire [5:0] cA      = effRate({qKsAr[4:0], 1'b0}, ksr);
  wire [5:0] cD      = effRate({qAmD1r[4:0], 1'b0}, ksr);
  wire [5:0] cS      = effRate({qDt2D2r[4:0], 1'b0}, ksr);
  wire [5:0] cR      = effRate({qD1lRr[3:0], 2'b10}, ksr);
  wire [3:0] d1l     = qD1lRr[7:4];
  wire [14:0] dtr    = dtRow(keycode);
  wire [4:0] dtMag   = qDtMul[5:4] == 2'd0 ? 5'd0 : qDtMul[5:4] == 2'd1 ? dtr[4:0] :
                       qDtMul[5:4] == 2'd2 ? dtr[9:5] : dtr[14:10];
  wire signed [5:0] cDet = qDtMul[6] ? -$signed({1'b0, dtMag}) : $signed({1'b0, dtMag});

  // prepare: the key state clocked
  wire       keyNow  = liveN[slot] | liveC[slot];
  reg        pKey;
  reg  [1:0] pState;
  reg  [9:0] pAtt;
  reg [19:0] pPhase;
  always @* begin
    pKey = qOst[32]; pState = qOst[31:30]; pAtt = qOst[29:20]; pPhase = qOst[19:0];
    if (prep && keyNow != qOst[32]) begin
      pKey = keyNow;
      if (keyNow) begin
        if (pState != EG_ATT) begin
          pState = EG_ATT;
          pPhase = 20'd0;
          if (cA >= 6'd62) pAtt = 10'd0;
        end
      end else if (pState != EG_REL) pState = EG_REL;
    end
  end
  wire pActive = pState != EG_REL || pAtt < 10'h380;
  wire [17:0] bd = {1'b0, base} + {{12{det[5]}}, det};   // never negative
  wire [19:0] newPhase = s1Phase + step[19:0];

  // the phase step's key code, DT2 and PM
  reg signed [11:0] pmTerm, delta;
  reg signed [12:0] effF, e;
  reg  [3:0] blk;
  reg  [9:0] cIdx;
  reg  [2:0] cSh;
  always @* begin
    case (pms)
      3'd0: pmTerm = 12'sd0;
      3'd1: pmTerm = $signed({{4{lfoPm[7]}}, lfoPm}) >>> 5;
      3'd2: pmTerm = $signed({{4{lfoPm[7]}}, lfoPm}) >>> 4;
      3'd3: pmTerm = $signed({{4{lfoPm[7]}}, lfoPm}) >>> 3;
      3'd4: pmTerm = $signed({{4{lfoPm[7]}}, lfoPm}) >>> 2;
      3'd5: pmTerm = $signed({{4{lfoPm[7]}}, lfoPm}) >>> 1;
      3'd6: pmTerm = {{3{lfoPm[7]}}, lfoPm, 1'b0};
      default: pmTerm = {{2{lfoPm[7]}}, lfoPm, 2'b0};
    endcase
    case (qDt2D2r[7:6])
      2'd0: delta = pmTerm;
      2'd1: delta = pmTerm + 12'sd384;
      2'd2: delta = pmTerm + 12'sd500;
      default: delta = pmTerm + 12'sd608;
    endcase
    effF = $signed({3'b000, kc[3:0] - {2'b00, kc[3:2]}, kf}) + {delta[11], delta};
    blk  = {1'b0, kc[6:4]};
    cIdx = effF[9:0];
    cSh  = ~blk[2:0];
    e    = effF;
    if (effF < 0) begin
      e = effF + 13'sd768;
      if (blk == 4'd0) begin cIdx = 10'd0; cSh = 3'd7; end
      else begin blk = blk - 4'd1; cIdx = e[9:0]; cSh = ~blk[2:0]; end
    end else if (effF >= 13'sd768) begin
      e = effF - 13'sd768;
      if (e >= 13'sd768) begin blk = blk + 4'd1; e = e - 13'sd768; end
      if (blk >= 4'd7) begin cIdx = 10'd767; cSh = 3'd0; end
      else begin blk = blk + 4'd1; cIdx = e[9:0]; cSh = ~blk[2:0]; end
    end
  end

  assign phAddr = cIdx;

  // the envelope: transitions, rate and increment
  reg  [1:0] eState;
  reg  [5:0] eRate;
  reg [28:0] eShifted;
  reg  [2:0] eRel;
  reg [31:0] eRow;
  always @* begin
    eState = s1State;
    if (envTick && eState == EG_ATT && s1Att == 10'd0) eState = EG_DEC;
    if (envTick && eState == EG_DEC && s1Att >= sus) eState = EG_SUS;
    case (eState)
      EG_ATT:  eRate = rA;
      EG_DEC:  eRate = rD;
      EG_SUS:  eRate = rS;
      default: eRate = rR;
    endcase
    eShifted = {15'd0, ech} << eRate[5:2];
    eRel     = eRate[5:2] <= 4'd11 ? eShifted[13:11] : ech[2:0];
    eRow     = incRow(eRate);
  end
  wire [3:0] eInc = eRow[{eRel, 2'b00} +: 4];

  // ------------------------------------------------- combinational: output
  wire [2:0] alg = rCon[c][2:0];
  wire [2:0] fbk = rCon[c][5:3];
  reg  [9:0] algRow;  // op2in 0, op3in 3:1, op4in 6:4, outputs O1 7, O2 8, O3 9
  always @* begin
    case (alg)
      3'd0: algRow = {3'b000, 3'd3, 3'd2, 1'd1};
      3'd1: algRow = {3'b000, 3'd3, 3'd5, 1'd0};
      3'd2: algRow = {3'b000, 3'd6, 3'd2, 1'd0};
      3'd3: algRow = {3'b000, 3'd7, 3'd0, 1'd1};
      3'd4: algRow = {3'b010, 3'd3, 3'd0, 1'd1};
      3'd5: algRow = {3'b110, 3'd1, 3'd1, 1'd1};
      3'd6: algRow = {3'b110, 3'd0, 3'd0, 1'd1};
      default: algRow = {3'b111, 3'd0, 3'd0, 1'd0};
    endcase
  end
  function signed [14:0] opSel(input [2:0] k, input signed [13:0] o1, input signed [13:0] o2,
                               input signed [13:0] o3);
    case (k)
      3'd1: opSel = o1;
      3'd2: opSel = o2;
      3'd3: opSel = o3;
      3'd5: opSel = o1 + o2;
      3'd6: opSel = o1 + o3;
      3'd7: opSel = o2 + o3;
      default: opSel = 15'sd0;
    endcase
  endfunction
  reg signed [14:0] modSrc, mod;
  always @* begin
    case (i)
      2'd0: modSrc = fb0[c] + fb1[c];
      2'd1: modSrc = opSel({2'b00, algRow[0]}, opo[0], opo[1], opo[2]);
      2'd2: modSrc = opSel(algRow[3:1], opo[0], opo[1], opo[2]);
      default: modSrc = opSel(algRow[6:4], opo[0], opo[1], opo[2]);
    endcase
    if (i == 2'd0) mod = fbk == 3'd0 ? 15'sd0 : modSrc >>> (4'd10 - {1'b0, fbk});
    else mod = modSrc >>> 1;
  end
  wire [9:0]  oPhase = phx[i] + mod[9:0];
  assign      sinAddr = oPhase[8] ? ~oPhase[7:0] : oPhase[7:0];
  wire [9:0]  amOff  = ams == 2'd0 ? 10'd0 : {2'b00, lfoAm} << (ams - 2'd1);
  wire [11:0] envSum = {2'b00, attx[i]} + (amx[i] ? {2'b00, amOff} : 12'd0) + {2'b00, tlx[i], 3'b000};
  wire [12:0] xAtt   = {1'b0, sinQ} + {1'b0, envT, 2'b00};
  assign      powAddr = xAtt[7:0];
  wire [12:0] vol    = {1'b1, powQ, 2'b00} >> xsh;
  wire        noiseOp = i == 2'd3 && c == 3'd7 && rNoise[7];
  wire [10:0] nVol   = {envT ^ 10'h3ff, 1'b0};
  wire signed [13:0] oVal = noiseOp ? (nstate ? -$signed({3'b000, nVol}) : $signed({3'b000, nVol})) :
                            quiet ? 14'sd0 : sign ? -$signed({1'b0, vol}) : $signed({1'b0, vol});
  wire signed [15:0] chOut = opo[3] + (algRow[7] ? opo[0] : 14'sd0) + (algRow[8] ? opo[1] : 14'sd0)
                                    + (algRow[9] ? opo[2] : 14'sd0);

  // the noise and LFO for this sample
  wire [7:0]  nFreq = {3'b000, rNoise[4:0] ^ 5'h1f};
  wire [24:0] l1    = {lfsr[23:0], lfsr[16] ^ lfsr[13] ^ 1'b1};
  wire [24:0] l2    = {l1[23:0], l1[16] ^ l1[13] ^ 1'b1};
  wire        n1    = ncnt >= nFreq;
  wire [7:0]  ncnt1 = n1 ? 8'd0 : ncnt + 8'd1;
  wire        n2    = ncnt1 >= nFreq;
  wire [29:0] lfoNext = rTest[1] ? 30'd0 : lfoCnt + ({25'd0, 1'b1, rLfrq[3:0]} << rLfrq[7:4]);
  wire [7:0]  lfoIdx  = lfoNext[29:22];

  // YM3012: the 10.3 floating point and back
  function signed [15:0] roundtrip(input signed [18:0] v);
    reg signed [15:0] s;
    reg [14:0] scan;
    reg [2:0]  drop;
    begin
      s = v < -19'sd32768 ? -16'sd32768 : v > 19'sd32767 ? 16'sd32767 : v[15:0];
      scan = s[14:0] ^ {15{s[15]}};
      drop = scan[14] ? 3'd6 : scan[13] ? 3'd5 : scan[12] ? 3'd4 : scan[11] ? 3'd3 :
             scan[10] ? 3'd2 : scan[9] ? 3'd1 : 3'd0;
      // ymfm returns a clipped value as it is
      roundtrip = v < -19'sd32768 || v > 19'sd32767 ? s : s & ~((16'sd1 <<< drop) - 16'sd1);
    end
  endfunction

  // ------------------------------------------------------------ the engine
  always @(posedge clock) begin
    io_sample <= 1'b0;
    ostWe <= 1'b0;
    if (reset) begin
      st <= S_INIT; initSlot <= 5'd0;
      addr <= 8'd0; rTest <= 8'd0; rNoise <= 8'd0; rLfrq <= 8'd0; rCtw <= 8'd0;
      rAmd <= 7'd0; rPmd <= 7'd0;
      liveN <= 32'd0; liveC <= 32'd0; modified <= 1'b1;
      pc <= 6'd0; due <= 1'b0; total <= 4'd0;
      lfsr <= 25'd1; ncnt <= 8'd0; nstate <= 1'b0; lfoCnt <= 30'd0;
      lfoPrev <= 8'd0; rdPrev <= 8'd0; wrPrev <= 8'd0; t0 <= 8'd0;
      ecl <= 2'd0; ech <= 14'd0; pcnt <= 13'd0; active <= 8'hff;
      io_left <= 16'sd0; io_right <= 16'sd0; io_overrun <= 1'b0;
      accL <= 19'sd0; accR <= 19'sd0;
      c <= 3'd0; i <= 2'd0;
    end else begin
      if (io_wr && !io_a0) addr <= io_din;
      if (push && qCnt == 3'd4 && !apply) io_overrun <= 1'b1;

      if (cen) pc <= pc + 6'd1;

      // a queued write
      if (apply) begin
        modified <= 1'b1;
        case (wa)
          8'h01: rTest <= wd;
          8'h08: begin
            liveN[{2'b00, wd[2:0]}] <= wd[3];
            liveN[{2'b10, wd[2:0]}] <= wd[4];
            liveN[{2'b01, wd[2:0]}] <= wd[5];
            liveN[{2'b11, wd[2:0]}] <= wd[6];
          end
          8'h0f: rNoise <= wd;
          8'h18: rLfrq <= wd;
          8'h19: if (wd[7]) rPmd <= wd[6:0]; else rAmd <= wd[6:0];
          8'h1b: rCtw <= wd;
          default: ;
        endcase
        if (wa[7:5] == 3'b001) begin
          case (wa[4:3])
            2'd0: rCon[wa[2:0]] <= wd;
            2'd1: rKc [wa[2:0]] <= wd[6:0];
            2'd2: rKf [wa[2:0]] <= wd[7:2];
            default: rPms[wa[2:0]] <= wd[6:0];
          endcase
        end
      end
      if (st == S_IDLE && csmPend) begin
        liveC <= 32'hffffffff;
        modified <= 1'b1;
      end

      case (st)
        S_INIT: begin
          ostWe <= 1'b1; ostWa <= initSlot; ostWd <= {1'b0, EG_REL, 10'h3ff, 20'd0};
          rCon[initSlot[2:0]] <= 8'hc0; rKc[initSlot[2:0]] <= 7'd0;
          rKf[initSlot[2:0]] <= 6'd0; rPms[initSlot[2:0]] <= 7'd0;
          fb0[initSlot[2:0]] <= 14'sd0; fb1[initSlot[2:0]] <= 14'sd0; fbin[initSlot[2:0]] <= 14'sd0;
          initSlot <= initSlot + 5'd1;
          if (initSlot == 5'd31) st <= S_IDLE;
        end

        S_IDLE: if (start) begin
          due <= 1'b0;
          total <= total + 4'd1;
          st <= S_L0;
        end

        // ymfm's fm_engine_base::clock: prepare?, the envelope counter,
        // clock_noise_and_lfo
        S_L0: begin
          prep <= modified || pcnt >= 13'd4096;
          pcnt <= (modified || pcnt >= 13'd4096) ? 13'd0 : pcnt + 13'd1;
          modified <= 1'b0;
          if (ecl == 2'd2) begin ecl <= 2'd0; ech <= ech + 14'd1; envTick <= 1'b1; end
          else begin ecl <= ecl + 2'd1; envTick <= 1'b0; end
          lfsr <= l2;
          if (n1) nstate <= l1[17];
          if (n2) nstate <= l2[17];
          ncnt <= n2 ? 8'd0 : ncnt1 + 8'd1;
          lfoCnt <= lfoNext;
          lfoN <= lfoIdx;
          rdNoise <= lfoIdx == lfoPrev ? rdPrev : lfoIdx == lfoPrev + 8'd1 ? wrPrev : t0;
          st <= S_L1;
        end
        S_L1: begin
          rdPrev <= rdNoise; wrPrev <= lfsr[24:17]; lfoPrev <= lfoN;
          if (lfoN == 8'd255) t0 <= lfsr[24:17];
          case (rCtw[1:0])
            2'd0: begin am8 <= ~lfoN; pm8 <= lfoN; end
            2'd1: begin am8 <= lfoN[7] ? 8'h00 : 8'hff; pm8 <= lfoN[7] ? 8'h80 : 8'h7f; end
            2'd2: begin
              am8 <= lfoN[7] ? {lfoN[6:0], 1'b0} : {~lfoN[6:0], 1'b0};
              pm8 <= lfoN[6] ? (lfoN[7] ? {lfoN[6:0], 1'b0} : {~lfoN[6:0], 1'b0})
                             : ~(lfoN[7] ? {lfoN[6:0], 1'b0} : {~lfoN[6:0], 1'b0});
            end
            default: begin am8 <= rdNoise; pm8 <= rdNoise; end
          endcase
          st <= S_L2;
        end
        S_L2: begin
          lfoAm <= ({8'd0, am8} * {9'd0, rAmd}) >> 7;
          lfoPm <= ($signed({{8{pm8[7]}}, pm8}) * $signed({9'd0, rPmd})) >>> 7;
          c <= 3'd0; i <= 2'd0;
          st <= S_C0;
        end

        // an operator clocked (fm_operator::prepare, ::clock); its registers
        // and state are read at slot
        S_C0: begin
          if (i == 2'd0) begin fb0[c] <= fb1[c]; fb1[c] <= fbin[c]; end
          st <= S_C1;
        end
        S_C1: begin
          rA <= cA; rD <= cD; rS <= cS; rR <= cR;
          sus <= {d1l == 4'hf, d1l, 5'd0};
          det <= cDet;
          mulx <= qDtMul[3:0] == 4'd0 ? 5'd1 : {qDtMul[3:0], 1'b0};
          s1Key <= pKey; s1State <= pState; s1Att <= pAtt; s1Phase <= pPhase;
          if (prep) begin
            liveC[slot] <= 1'b0;
            actAcc <= (i == 2'd0 ? 1'b0 : actAcc) | pActive;
            if (i == 2'd3) active[c] <= actAcc | pActive;
          end
          phSh <= cSh;
          tlx[i] <= qTl; amx[i] <= qAmD1r[7];
          st <= S_C2;
        end
        S_C2: begin
          s2State <= eState; s2Rate <= eRate; s2Inc <= eInc;
          s2Do <= envTick && eShifted[10:0] == 11'd0;
          base <= {phQ, 5'd0} >> phSh;
          st <= S_C3;
        end
        S_C3: begin
          s3Att <= s1Att;
          if (s2Do) begin
            if (s2State == EG_ATT) begin
              if (s2Rate < 6'd62)
                s3Att <= s1Att - (({4'd0, s1Att} + 14'd1) * {10'd0, s2Inc} + 14'd15 >> 4);
            end else
              s3Att <= ({1'b0, s1Att} + {7'd0, s2Inc}) >= 11'd1024 ? 10'h3ff : s1Att + {6'd0, s2Inc};
          end
          step <= ({5'd0, bd} * {18'd0, mulx}) >> 1;
          st <= S_C4;
        end
        S_C4: begin
          ostWe <= 1'b1; ostWa <= slot;
          ostWd <= {s1Key, s2State, s3Att, newPhase};
          phx[i] <= newPhase[19:10];
          attx[i] <= s3Att;
          i <= i + 2'd1;
          st <= i == 2'd3 ? S_O0 : S_C0;
        end

        // the channel's operators computed (fm_channel::output_4op)
        S_O0: begin
          sign <= oPhase[9];
          quiet <= attx[i] > 10'h380;
          envT <= envSum > 12'h3ff ? 10'h3ff : envSum[9:0];
          st <= S_O1;
        end
        S_O1: begin
          xsh <= xAtt[12:8];
          st <= S_O2;
        end
        S_O2: begin
          opo[i] <= oVal;
          if (i == 2'd0 && active[c]) fbin[c] <= oVal;
          i <= i + 2'd1;
          st <= i == 2'd3 ? S_O3 : S_O0;
        end
        S_O3: begin
          if (active[c] && rCon[c][6]) accL <= accL + {{3{chOut[15]}}, chOut};
          if (active[c] && rCon[c][7]) accR <= accR + {{3{chOut[15]}}, chOut};
          c <= c + 3'd1;
          st <= c == 3'd7 ? S_FIN : S_C0;
        end
        S_FIN: begin
          io_left <= roundtrip(accL);
          io_right <= roundtrip(accR);
          io_sample <= 1'b1;
          accL <= 19'sd0; accR <= 19'sd0;
          st <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
      if (cen && pc == 6'd0) begin
        if (due) io_overrun <= 1'b1;
        due <= 1'b1;
      end
    end
  end
endmodule
