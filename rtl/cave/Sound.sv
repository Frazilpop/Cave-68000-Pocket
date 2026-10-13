// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).
//
// Cave 68000 for Analogue Pocket: cut to the YMZ280B path. Upstream's Sound
// also carried DonPachi's two OKI M6295s behind the NMK112 and Power
// Instinct 2's Z80, YM2203 and OKIs; this core plays the YMZ280B games only,
// so those devices, their ROM arbitration, mailbox and savestate wrappers
// are gone. The ports that remain keep upstream's names.

// Atlus-class sound integration: the YMZ280B alone.
module Sound(
  input         clock,
  input         reset,
  input         io_ctrl_ymz_rd,
  input         io_ctrl_ymz_wr,
  input  [22:0] io_ctrl_ymz_addr,
  input  [15:0] io_ctrl_ymz_din,
  output [15:0] io_ctrl_ymz_dout,
  output        io_ctrl_irq,
  input  [3:0]  io_options_ymz_level,
  output        io_rom_0_rd,
  output [24:0] io_rom_0_addr,
  input  [7:0]  io_rom_0_dout,
  input         io_rom_0_wait_n,
  input         io_rom_0_valid,
  output [15:0] io_audio,
  input         io_ss_hold,
  input         io_ss_restore_enable,
  output        io_ss_idle,
  cave_ssbus_if.slave io_ssbus
);
  reg  [15:0] ymzAudioReg;

  wire [7:0]  ymzCpuDout;
  wire [23:0] ymzRomAddr;
  wire        ymzAudioValid;
  wire [15:0] ymzAudio;
  wire        ymzIrq;
  wire        ymzSsIdle;

  always @(posedge clock) begin
    if (reset)
      ymzAudioReg <= 16'd0;
    else if (io_ss_hold && io_ss_restore_enable && ymzSsIdle)
      // At the canonical idle point the held sample is the clamped YMZ
      // accumulator, so it can be reconstructed without another state word.
      ymzAudioReg <= ymzAudio;
    else if (ymzAudioValid)
      ymzAudioReg <= ymzAudio;
  end

  YMZ280B ymz280b (
    .clock              (clock),
    .reset              (reset),
    .io_cpu_rd          (io_ctrl_ymz_rd),
    .io_cpu_wr          (io_ctrl_ymz_wr),
    .io_cpu_addr        (io_ctrl_ymz_addr[0]),
    .io_cpu_din         (io_ctrl_ymz_din[7:0]),
    .io_cpu_dout        (ymzCpuDout),
    .io_rom_rd          (io_rom_0_rd),
    .io_rom_addr        (ymzRomAddr),
    .io_rom_dout        (io_rom_0_dout),
    .io_rom_wait_n      (io_rom_0_wait_n),
    .io_rom_valid       (io_rom_0_valid),
    .io_audio_valid     (ymzAudioValid),
    .io_audio_bits_left (ymzAudio),
    .io_irq             (ymzIrq),
    .io_ss_hold         (io_ss_hold),
    .io_ss_restore_enable(io_ss_restore_enable),
    .io_ss_idle         (ymzSsIdle),
    .io_ssbus           (io_ssbus)
  );

  AudioMixer io_audio_mixer (
    .clock       (clock),
    .io_pwrinst2 (1'b0),
    .io_ymz      (1'b1),
    .io_legacy_oki (1'b0),
    .io_pwrinst2_oki0_level (4'd0),
    .io_pwrinst2_oki1_level (4'd0),
    .io_pwrinst2_headroom (1'b0),
    .io_pwrinst2_psg_level (4'd0),
    .io_pwrinst2_fm_level  (4'd0),
    .io_ymz_level           (io_options_ymz_level),
    .io_in_4     (14'd0),
    .io_in_3     (14'd0),
    .io_in_2     (16'h0000),
    .io_in_1     (16'h0000),
    .io_in_0     (ymzAudioReg),
    .io_out      (io_audio)
  );

  assign io_rom_0_addr = {1'b0, ymzRomAddr};
  assign io_ctrl_irq = ymzIrq;
  assign io_ctrl_ymz_dout = {8'h00, ymzCpuDout};
  assign io_ss_idle = ymzSsIdle;
endmodule
