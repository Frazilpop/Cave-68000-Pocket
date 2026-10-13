// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — a multi-bit crossing for slow settings
//
// For values that change rarely and are read continuously: the game id, the
// DIP word, the option bits, the SDRAM capture select. They are written on
// clk_74a by APF and used on the core or SDRAM clock.
//
// A plain two-flop synchroniser per bit is safe for each bit on its own, but a
// word whose bits change together can arrive in pieces — for a cycle the far
// side may see half the old value and half the new. Here every bit goes
// through two flops and the output only takes a value that has been seen,
// whole, on two consecutive cycles. A change in flight is never stable for two
// samples, so a torn word is never passed on. The cost is two cycles of
// latency on a value that changes when a person presses a menu button.

`default_nettype none

module pocket_sync_bus #(
    parameter int unsigned W = 1,
    parameter logic [W-1:0] INIT = '0
)(
    input  wire          clk,
    input  wire [W-1:0]  d,          // from another clock domain
    output logic [W-1:0] q = INIT
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [W-1:0] s1 = INIT;
    logic [W-1:0] s2 = INIT, s3 = INIT;

    always_ff @(posedge clk) begin
        s1 <= d;
        s2 <= s1;
        s3 <= s2;
        if (s2 == s3) q <= s3;
    end
endmodule

`default_nettype wire
