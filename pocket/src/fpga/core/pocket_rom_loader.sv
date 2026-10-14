// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — APF data slot -> SDRAM, and `rom_loaded`
//
// The .rom image is loaded by APF at bridge address 0, four bytes per bridge
// write, on clk_74a. Byte n of the file goes to SDRAM byte n, so SDRAM word w = {byte 2w+1, byte 2w}.
//
// THREE STAGES, EACH FOR ONE REASON
//
// 1. data_loader (agg23, MIT, third_party/pocket-utils) crosses the bridge
//    writes into the core clock's domain (96 MHz) through a dcfifo and splits each 32-bit
//    write into two 16-bit words, low half first, at byte addresses 4k and
//    4k+2. With bridge_endian_little = 0 it byte-swaps first, so the low half
//    is {byte 4k+1, byte 4k} — exactly the SDRAM word the layout asks for.
//
// 2. A small FIFO, because data_loader has no back-pressure. It emits a word
//    every WRITE_MEM_CLOCK_DELAY cycles whether or not anything is ready for
//    it, while an SDRAM write occasionally waits behind a refresh or a row
//    change. APF delivers about one bridge word per microsecond (~96 core
//    cycles, two SDRAM words), so eight entries is generous; overflow is
//    counted rather than assumed away.
//
// 3. The writer, on the SDRAM controller's write port: request held as a
//    level until the one-cycle acknowledge, then dropped for at least one
//    cycle so the controller sees a fresh rising edge for the next word (it
//    latches on the edge — see kaneko_sdram's REQUEST CONTRACT).
//
// The board snoops every word as it is ACKNOWLEDGED (dl_wr/dl_addr/dl_data),
// i.e. once it is really in SDRAM, so anything the board derives from the
// stream describes what the memory holds.
//
// WHEN IS THE ROM LOADED
//
// APF sends [008F Data slot access all complete] after its last slot write
// (core_bridge_cmd raises dataslot_allcomplete). That command arrives over the
// same bridge, several bridge transactions after the last data word, so by
// the time it is seen here the data is already in the FIFOs or written. It is
// still not trusted alone: rom_loaded waits for the command AND an empty
// pipeline held for QUIET cycles. Once high it stays high — APF clears
// allcomplete again for the shutdown read-out, and the ROM is still there.

`default_nettype none

module pocket_rom_loader #(
    parameter int unsigned SDR_AW = 25,
    parameter int unsigned QUIET  = 1024
)(
    input  wire              clk_74a,
    input  wire              bridge_wr,
    input  wire              bridge_endian_little,
    input  wire [31:0]       bridge_addr,
    input  wire [31:0]       bridge_wr_data,

    input  wire              clk,            // 96 MHz
    input  wire              rst,            // power-on only
    input  wire              mem_ready,      // SDRAM initialised
    input  wire              allcomplete_s,  // dataslot_allcomplete, synchronised

    // the SDRAM controller's write port (cave_sdram)
    output reg               wr_req,
    output reg  [SDR_AW:1]   wr_addr,
    output reg  [15:0]       wr_din,
    output wire [1:0]        wr_be,
    input  wire              wr_ack,

    // board snoop
    output reg               dl_wr,
    output wire [SDR_AW:1]   dl_addr,
    output wire [15:0]       dl_data,
    output reg               rom_loaded,

    output reg               overflow        // sticky; for debugging only
);

    // ------------------------------------------------------- 74 -> 96 MHz
    wire        ld_wr;
    wire [27:0] ld_addr;
    wire [15:0] ld_data;

    data_loader #(
        .ADDRESS_MASK_UPPER_4 (4'h0),
        .ADDRESS_SIZE         (28),
        .WRITE_MEM_CLOCK_DELAY(8),
        .WRITE_MEM_EN_CYCLE_LENGTH(1),
        .OUTPUT_WORD_SIZE     (2)
    ) u_loader (
        .clk_74a             (clk_74a),
        .clk_memory          (clk),
        .bridge_wr           (bridge_wr),
        .bridge_endian_little(bridge_endian_little),
        .bridge_addr         (bridge_addr),
        .bridge_wr_data      (bridge_wr_data),
        .write_en            (ld_wr),
        .write_addr          (ld_addr),
        .write_data          (ld_data)
    );

    // ------------------------------------------------------------- FIFO
    localparam int unsigned FW = SDR_AW + 16;   // {word address, data}

    reg [FW-1:0] fifo [8];
    reg [3:0]    wp, rp;                         // one extra bit: full vs empty
    wire         f_empty = (wp == rp);
    wire         f_full  = (wp[2:0] == rp[2:0]) && (wp[3] != rp[3]);

    // Byte addresses beyond the SDRAM are dropped rather than wrapped.
    wire in_range = (ld_addr[27:SDR_AW+1] == '0);

    always @(posedge clk) begin
        if (rst) begin
            wp       <= '0;
            overflow <= 1'b0;
        end else if (ld_wr && in_range) begin
            if (f_full) overflow <= 1'b1;
            else begin
                fifo[wp[2:0]] <= {ld_addr[SDR_AW:1], ld_data};
                wp <= wp + 4'd1;
            end
        end
    end

    // ----------------------------------------------------------- writer
    assign wr_be   = 2'b11;
    assign dl_addr = wr_addr;
    assign dl_data = wr_din;

    reg [$clog2(QUIET+1)-1:0] quiet;

    always @(posedge clk) begin
        dl_wr <= 1'b0;
        if (rst) begin
            rp         <= '0;
            wr_req     <= 1'b0;
            quiet      <= '0;
            rom_loaded <= 1'b0;
        end else begin
            if (wr_req) begin
                if (wr_ack) begin
                    wr_req <= 1'b0;     // low for at least this one cycle
                    dl_wr  <= 1'b1;
                end
            end else if (!f_empty && mem_ready && !dl_wr) begin
                // `!dl_wr` is the cycle wr_req spends low after an ack.
                {wr_addr, wr_din} <= fifo[rp[2:0]];
                rp     <= rp + 4'd1;
                wr_req <= 1'b1;
            end

            if (!allcomplete_s || !f_empty || wr_req || ld_wr)
                quiet <= '0;
            else if (quiet != QUIET[$bits(quiet)-1:0])
                quiet <= quiet + 1'b1;
            else
                rom_loaded <= 1'b1;
        end
    end

endmodule

`default_nettype wire
