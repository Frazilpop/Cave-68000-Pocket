// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).
//
// Cave 68000 for Analogue Pocket: cut to the YMZ280B path. Upstream's Sound
// also carried DonPachi's two OKI M6295s behind the NMK112 and Power
// Instinct 2's Z80, YM2203 and OKIs; this core plays the YMZ280B games only,
// so those devices, their ROM arbitration, mailbox and savestate wrappers
// are gone, and with them the mixer: the YMZ280B's output is MAME's mono
// speaker as it is. The ports that remain keep upstream's names.

// Atlus-class sound integration: the YMZ280B alone.
module Sound #(
  parameter integer CLOCK_HZ = 32000000,
  parameter integer RATE16_INC = 2500,    // ChannelController's
  parameter integer RATE16_DEN = CLOCK_HZ / 100 * 3
) (
  input         clock,
  input         reset,
  input         io_clock16m,          // gaia and theroes: the chip on 16 MHz
  input         io_pause,             // the board paused: the chip stands still
  input         io_ctrl_ymz_rd,
  input         io_ctrl_ymz_wr,
  input  [22:0] io_ctrl_ymz_addr,
  input  [15:0] io_ctrl_ymz_din,
  output [15:0] io_ctrl_ymz_dout,
  output        io_ctrl_irq,
  output        io_rom_0_rd,
  output [24:0] io_rom_0_addr,
  input  [7:0]  io_rom_0_dout,
  input         io_rom_0_wait_n,
  input         io_rom_0_valid,
  output [15:0] io_audio,             // held between samples
  output        io_audio_valid,       // a new sample (the chip's clock / 192)
  output        io_overrun            // a sample was late
);
  wire [7:0]  ymzCpuDout;
  wire [23:0] ymzRomAddr;

  YMZ280B #(
    .CLOCK_HZ (CLOCK_HZ), .RATE16_INC (RATE16_INC), .RATE16_DEN (RATE16_DEN)
  ) ymz280b (
    .clock          (clock),
    .reset          (reset),
    .io_clock16m    (io_clock16m),
    .io_pause       (io_pause),
    .io_cpu_rd      (io_ctrl_ymz_rd),
    .io_cpu_wr      (io_ctrl_ymz_wr),
    .io_cpu_addr    (io_ctrl_ymz_addr[0]),
    .io_cpu_din     (io_ctrl_ymz_din[7:0]),
    .io_cpu_dout    (ymzCpuDout),
    .io_rom_rd      (io_rom_0_rd),
    .io_rom_addr    (ymzRomAddr),
    .io_rom_dout    (io_rom_0_dout),
    .io_rom_wait_n  (io_rom_0_wait_n),
    .io_rom_valid   (io_rom_0_valid),
    .io_audio_valid (io_audio_valid),
    .io_audio       (io_audio),
    .io_irq         (io_ctrl_irq),
    .io_overrun     (io_overrun)
  );

  assign io_rom_0_addr = {1'b0, ymzRomAddr};
  assign io_ctrl_ymz_dout = {8'h00, ymzCpuDout};
endmodule
