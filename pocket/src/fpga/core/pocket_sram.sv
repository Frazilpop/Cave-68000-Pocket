// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the 68000's own RAM in the Pocket's SRAM
//
// On the Z80 build (Air Gallet, Sailor Moon) the board's RAMs and the Z80
// sound board do not fit the chip's 308 M10K blocks (357 asked for). The
// 68000's work RAM (64 KB) and Sailor Moon's three layer scratchpads (10 KB
// each) are RAM only the 68000 reads, one access at a time: cave68000's xram
// port, served here from the Pocket's SRAM, 112 blocks fewer.
//
// THE PART. AS6C2016-55: 128K x 16 asynchronous SRAM, 55 ns. No chip select
// reaches the FPGA (it is tied active on the board); OE# frames a read, WE#
// a write, UB#/LB# pick the bytes. Only the low 64K words are used.
//
// WHEN THE 68000 TAKES ITS DATA. A block RAM in Main answered on the clock
// after the read strobe (the strobe is the first clock of AS), and the
// 68000 takes the word on the third: in the harness, data good from two
// clocks after the strobe passes every access of both games, from three it
// does not. A read started on the strobe would need 55 ns of the part, about
// 7 of clock-to-pin and pin-to-register, and a register – the word in on the
// fourth clock. So the address is not taken on the strobe: it goes to the
// pins on every clock, as the 68000 drives it, which is a clock before AS,
// and OE# is low between writes. The word on the pins is taken into dout on
// every clock. On the strobe's clock E0 the pins have had the address since
// E0-1; dout takes it at E0+2, 93.75 ns later, where ~62 are needed: the
// 68000 reads it at E0+3 as it read the block RAM's. (The harness's
// sram_model passes on a word only once its address has been on the pins for
// three clocks, so a read that came too soon would show in the trace.)
//
// A WRITE, from the strobe's clock E0 (UDS/LDS, its data and mask valid):
//   E0    OE# high, the write's address, data and bytes held from here
//   E0+1  data on the pins, UB#/LB#, WE# low
//   E0+3  WE# high: low 62.5 ns (tWP 45); the address 93 ns before it
//         (tAW 50), the data 62 (tDW 25)
//   E0+4  data and bytes held a clock past WE# (tDH, tWR 0), then released;
//         the address follows the 68000 again
//   E0+5  OE# low
// The SRAM's outputs are off from E0 (tOHZ) before the data goes on, and the
// data is off a clock before OE# comes back. A read after a write has its
// address on the pins from E0+4 and its word good at E0+7; the 68000's next
// read strobe is at E0+5 at the earliest (E0+3 after it is E0+8).
//
// POWER-ON. A block RAM came up zero, and so did MAME's RAM the traces were
// held to; the SRAM comes up with anything in it (or another core's data).
// After rst every word is written zero, ~10 ms, before ready: the shell
// holds the board until it is. A reset of the game alone leaves the RAM as
// it is, as it left the block RAMs.
//
// The .sdc cuts these pins (core_constraints.sdc): with no clock at the part
// to time against, the margins are the clock counts above; every pin is a
// register in its I/O cell (ap_core.qsf), so clock-to-pin is the cell's.

`default_nettype none

module pocket_sram (
    input  wire        clk,             // clk_cpu, 32 MHz
    input  wire        rst,             // power-on: clears the RAM
    output reg         ready,

    // the board's xram port (cave68000)
    input  wire        rd,              // unused: the address is read anyway
    input  wire        wr,
    input  wire [15:0] addr,
    input  wire [1:0]  mask,            // [1] the upper byte
    input  wire [15:0] din,
    output reg  [15:0] dout,

    // pins
    output reg  [16:0] sram_a,
    output reg  [15:0] sram_dq_o,
    output reg         sram_dq_oe = 1'b0,
    input  wire [15:0] sram_dq_i,
    output reg         sram_oe_n = 1'b1,    // from configuration: no write, no
    output reg         sram_we_n = 1'b1,    // drive, before the clock runs
    output reg         sram_ub_n = 1'b1,
    output reg         sram_lb_n = 1'b1
);

    localparam [2:0] S_IDLE = 3'd0,     // following the 68000's address
                     S_W1   = 3'd1,     // E0+1: data on, WE# low
                     S_W2   = 3'd2,     // E0+2
                     S_W3   = 3'd3,     // E0+3: WE# high
                     S_W4   = 3'd4,     // E0+4: data off
                     S_CLR  = 3'd5;     // power-on: the next word to clear

    reg [2:0]  state;
    reg [15:0] wd;
    reg [1:0]  wm;
    reg [15:0] ca;                      // the clear's address
    reg        clearing;

    always @(posedge clk) begin
        dout <= sram_dq_i;
        if (rst) begin
            state      <= S_CLR;
            clearing   <= 1'b1;
            ready      <= 1'b0;
            ca         <= 16'd0;
            sram_a     <= 17'd0;
            sram_dq_oe <= 1'b0;
            sram_oe_n  <= 1'b1;
            sram_we_n  <= 1'b1;
            sram_ub_n  <= 1'b1;
            sram_lb_n  <= 1'b1;
        end else begin
            case (state)
            S_IDLE: begin
                sram_a    <= {1'b0, addr};
                sram_oe_n <= 1'b0;
                sram_ub_n <= 1'b0;
                sram_lb_n <= 1'b0;
                if (wr) begin                       // E0
                    sram_oe_n <= 1'b1;
                    wd        <= din;
                    wm        <= mask;
                    state     <= S_W1;
                end
            end
            S_CLR: begin                            // as a write's E0
                sram_a <= {1'b0, ca};
                wd     <= 16'd0;
                wm     <= 2'b11;
                state  <= S_W1;
            end
            S_W1: begin
                sram_dq_o  <= wd;
                sram_dq_oe <= 1'b1;
                sram_ub_n  <= ~wm[1];
                sram_lb_n  <= ~wm[0];
                sram_we_n  <= 1'b0;
                state      <= S_W2;
            end
            S_W2: state <= S_W3;
            S_W3: begin
                sram_we_n <= 1'b1;
                state     <= S_W4;
            end
            S_W4: begin
                sram_dq_oe <= 1'b0;
                sram_ub_n  <= 1'b0;
                sram_lb_n  <= 1'b0;
                if (clearing) begin
                    ca <= ca + 16'd1;
                    if (ca == 16'hFFFF) begin
                        clearing <= 1'b0;
                        ready    <= 1'b1;
                        sram_a   <= {1'b0, addr};
                        state    <= S_IDLE;
                    end else
                        state    <= S_CLR;
                end else begin
                    sram_a <= {1'b0, addr};         // OE# low on the next clock (S_IDLE)
                    state  <= S_IDLE;
                end
            end
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
