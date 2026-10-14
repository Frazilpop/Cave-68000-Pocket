// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 (Pocket): the YMZ280B (rtl/cave/Sound.sv) on its own, for
// sim/ymz280b/tb_ymz280b.cpp, with whether a sample is being worked on.

`default_nettype none

module tb_ymz280b_top (
  input  wire        clock,
  input  wire        reset,
  input  wire        clock16m,
  input  wire        cpu_rd, cpu_wr, cpu_addr,
  input  wire [7:0]  cpu_din,
  output wire [7:0]  cpu_dout,
  output wire        irq,
  output wire        rom_rd,
  output wire [23:0] rom_addr,
  input  wire [7:0]  rom_dout,
  input  wire        rom_wait_n, rom_valid,
  output wire [15:0] audio,
  output wire        audio_valid,
  output wire        overrun,
  output wire        busy,
  output wire        will_begin     // the next edge begins a sample
);
  wire [15:0] dout;
  wire [24:0] addr;

  // the 16 MHz chip at MAME's whole 83333 Hz, so MAME's 20 ms updates fall
  // on the same samples
  Sound #(.CLOCK_HZ (32000000), .RATE16_INC (83333), .RATE16_DEN (32000000)) sound (
    .clock            (clock),
    .reset            (reset),
    .io_clock16m      (clock16m),
    .io_pause         (1'b0),
    .io_ctrl_ymz_rd   (cpu_rd),
    .io_ctrl_ymz_wr   (cpu_wr),
    .io_ctrl_ymz_addr ({22'd0, cpu_addr}),
    .io_ctrl_ymz_din  ({8'd0, cpu_din}),
    .io_ctrl_ymz_dout (dout),
    .io_ctrl_irq      (irq),
    .io_rom_0_rd      (rom_rd),
    .io_rom_0_addr    (addr),
    .io_rom_0_dout    (rom_dout),
    .io_rom_0_wait_n  (rom_wait_n),
    .io_rom_0_valid   (rom_valid),
    .io_audio         (audio),
    .io_audio_valid   (audio_valid),
    .io_overrun       (overrun)
  );

  assign cpu_dout = dout[7:0];
  assign rom_addr = addr[23:0];
  assign busy = sound.ymz280b.channelCtrl.state != 4'd0;
  assign will_begin = sound.ymz280b.channelCtrl.state == 4'd0 &&
                      (sound.ymz280b.channelCtrl.tickPending || sound.ymz280b.channelCtrl.tick) &&
                      sound.ymz280b.queueCount == 4'd0;
endmodule

`default_nettype wire
