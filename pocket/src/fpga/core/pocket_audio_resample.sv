// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the YMZ280B's samples, 88.2 kHz, to the
// Pocket's 48 kHz
//
// The board puts out one sample at the chip's own rate (88,200 Hz; 83,333 on
// gaia and theroes, whose chip runs at 16 MHz), held between strobes. The
// Pocket's I2S (sound_i2s) takes a sample at 48 kHz. Holding the board's value
// and letting the I2S pick it up would fold everything between 24 and 44 kHz
// back into the audible band, and the chip's output has plenty there (its
// voices are interpolated to 88.2 kHz from sample rates up to 44 kHz). So:
//
//   1. a 47-tap low-pass at the input rate (tools/pocket/audio_fir.py: flat
//      to 16 kHz, -2.5 dB at 20, -37 dB at 24, below -68 dB from 26 kHz),
//      one multiply-accumulate a clock after each input sample (47 of the
//      ~363 clocks between samples);
//   2. 48 kHz output times from a 3/2000 accumulator on the 32 MHz clock
//      (exactly 48 kHz: the PLL makes clk_cpu 32.000 MHz), and at each the
//      filtered stream linearly interpolated at that time (one sample late,
//      which is just a delay). After the low-pass the interpolation's own
//      images sit above 68 kHz and are down by more than 20 dB before they
//      fold to 20 kHz and above.
//
// The output is held between out_valid strobes, for sound_i2s.

`default_nettype none

module pocket_audio_resample (
  input  wire               clk,            // clk_cpu, 32 MHz
  input  wire               rst,
  input  wire               rate16m,        // the chip on 16 MHz: 83,333 Hz in
  input  wire               in_valid,
  input  wire signed [15:0] in_sample,
  output reg  signed [15:0] out_sample,
  output reg                out_valid
);

  // tools/pocket/audio_fir.py: 47 taps, Kaiser beta 6.0, cut 21000 Hz at 88200 Hz;
  // symmetric, tap k = tap 46 - k; 1.0 = 2^17
  function automatic signed [17:0] coef(input [4:0] k);
    case (k)
      5'd0: coef = 18'sd4;
      5'd1: coef = 18'sd54;
      5'd2: coef = 18'sd0;
      5'd3: coef = -18'sd147;
      5'd4: coef = -18'sd33;
      5'd5: coef = 18'sd303;
      5'd6: coef = 18'sd126;
      5'd7: coef = -18'sd534;
      5'd8: coef = -18'sd327;
      5'd9: coef = 18'sd845;
      5'd10: coef = 18'sd700;
      5'd11: coef = -18'sd1224;
      5'd12: coef = -18'sd1330;
      5'd13: coef = 18'sd1651;
      5'd14: coef = 18'sd2346;
      5'd15: coef = -18'sd2089;
      5'd16: coef = -18'sd3983;
      5'd17: coef = 18'sd2497;
      5'd18: coef = 18'sd6814;
      5'd19: coef = -18'sd2828;
      5'd20: coef = -18'sd12937;
      5'd21: coef = 18'sd3045;
      5'd22: coef = 18'sd41382;
      5'd23: coef = 18'sd62402;
      default: coef = 18'sd0;
    endcase
  endfunction

  // ------------------------------------------------------------ the FIR
  (* ramstyle = "MLAB, no_rw_check" *) reg signed [15:0] ring [0:63];
  reg  [5:0]         wp;                   // where the next sample goes
  reg  [5:0]         tap;                  // 0..46 while running
  reg                run, run_q;
  reg  signed [15:0] x_q;
  reg  signed [17:0] c_q;
  reg  signed [39:0] acc;
  reg                last_q, last_qq;
  reg  signed [15:0] z_cur, z_prev;        // the last two filtered samples

  wire [5:0] rd_ptr = wp - 6'd1 - tap;     // x[n - tap]
  wire [4:0] ci     = (tap < 6'd24) ? tap[4:0] : 5'(6'd46 - tap);

  wire signed [39:0] acc_r = acc + 40'sd65536;            // round at 2^17
  wire signed [22:0] z_wide = acc_r[39:17];

  always @(posedge clk) begin
    if (rst) begin
      wp <= 6'd0; run <= 1'b0; run_q <= 1'b0; last_q <= 1'b0; last_qq <= 1'b0;
      acc <= 40'sd0; z_cur <= 16'sd0; z_prev <= 16'sd0;
    end else begin
      // the multiply-accumulate pipeline: read, then multiply-add
      x_q    <= ring[rd_ptr];
      c_q    <= coef(ci);
      run_q  <= run;
      last_q <= run && tap == 6'd46;
      last_qq <= last_q;
      if (run_q) acc <= acc + x_q * c_q;

      if (in_valid) begin
        ring[wp] <= in_sample;
        wp  <= wp + 6'd1;
        tap <= 6'd0;
        run <= 1'b1;
        acc <= 40'sd0;
      end else if (run) begin
        if (tap == 6'd46) run <= 1'b0;
        tap <= tap + 6'd1;
      end

      if (last_qq) begin
        z_prev <= z_cur;
        z_cur  <= (z_wide > 23'sd32767) ? 16'sd32767 :
                  (z_wide < -23'sd32768) ? -16'sd32768 : z_wide[15:0];
      end
    end
  end

  // ---------------------------------------------------- the 48 kHz side
  // clocks since the last filtered sample, and the input period's
  // reciprocal: frac = since * 2^24 / period, kept to 16 bits
  reg  [9:0]  since;
  reg  [10:0] tick_acc;
  wire [15:0] k_rate = rate16m ? 16'd43691 : 16'd46242;   // 2^24 / (32e6 / rate)
  wire [25:0] frac_w = since * k_rate;                     // 2^24 = one period
  wire [15:0] frac   = (frac_w[25:24] != 2'd0) ? 16'hFFFF : frac_w[23:8];
  wire signed [16:0] diff = {z_cur[15], z_cur} - {z_prev[15], z_prev};
  wire signed [33:0] step = diff * $signed({1'b0, frac});
  // between z_prev and z_cur, so it fits 16 bits
  wire signed [16:0] interp = {z_prev[15], z_prev} + step[32:16];

  always @(posedge clk) begin
    out_valid <= 1'b0;
    if (rst) begin
      since <= 10'd0; tick_acc <= 11'd0; out_sample <= 16'sd0;
    end else begin
      since <= last_qq ? 10'd0 : (since == 10'h3FF ? since : since + 10'd1);
      if (tick_acc >= 11'd1997) begin
        tick_acc   <= tick_acc + 11'd3 - 11'd2000;
        out_valid  <= 1'b1;
        out_sample <= interp[15:0];
      end else
        tick_acc <= tick_acc + 11'd3;
    end
  end

endmodule

`default_nettype wire
