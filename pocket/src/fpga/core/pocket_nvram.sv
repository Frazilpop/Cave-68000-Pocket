// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the 93C46 EEPROM as an APF nonvolatile slot
//
// THE SLOT. 128 bytes at bridge 0x20000000, marked nonvolatile in data.json.
// APF writes the save file in at boot, while the core is in reset, and reads
// it back out on shutdown (after [0010 Reset Enter], then [0080 Data slot
// request read]). Both directions are on clk_74a; the EEPROM lives in the
// board on the 96 MHz clock.
//
// FILE FORMAT. The nv port's word w is bytes {2w+1, 2w} of the file. The
// board's store (cave_eeprom_store) swaps each word on that port, so the file
// is the 93C46 big-endian per word: byte for byte the EEPROM file in MAME's
// zip. (MAME's own .nv is the same words little-endian, each pair swapped.)
//
// IN: boot writes. Bridge writes in 0x2xxxxxxx come through a second
// data_loader (agg23, MIT) — the same dcfifo crossing the ROM uses — as 16-bit
// words on the 96 MHz clock, and go straight into the board's nv_* port.
//
// OUT: shutdown reads, and why they are served from a SHADOW.
//
// Reading the board's EEPROM directly from clk_74a would need a request
// crossing in, a read, and the data crossing back, inside the bridge's read
// window. Instead the 96 MHz side keeps a copy that the 74 MHz side can read
// at any time:
//
//   - a scanner walks the 64 words through the board's nv_dout (one-cycle
//     latency, as the contract says), two cycles a word, 128 cycles a pass —
//     2.7 us — forever;
//   - it compares each word with the shadow and writes the shadow ONLY when
//     they differ;
//   - the shadow is a dual-clock block RAM, written on clk, read on clk_74a.
//
// A dual-clock RAM is a safe crossing for every word except one being written
// at the instant it is read, and here that cannot happen when it matters. The
// shadow changes only when the EEPROM does; the EEPROM changes only when the
// 68000 writes it; and APF reads the slot only after Reset Enter, when the
// 68000 is held. By then the scanner has had at least one full pass (2.7 us
// against the tens of microseconds APF spends between Reset Enter and its
// first slot read) and then has nothing left to write. The shadow is static
// for every read that matters.
//
// The shadow is one RAM per half of a 32-bit bridge word (even and odd EEPROM
// words), so a bridge read is one lookup on each with no sequencing.
//
// nv_dirty: APF flushes nonvolatile slots only at shutdown, so it has no use
// for a "changed" flag. It is acknowledged as soon as it rises. (A core could
// push the file out early with Target command [0184 Data slot write]; nothing
// here does that yet.)

`default_nettype none

module pocket_nvram (
    input  wire        clk_74a,
    input  wire        bridge_wr,
    input  wire        bridge_rd,
    input  wire        bridge_endian_little,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    output wire [31:0] bridge_rd_word,  // the word of the last read strobe's address, held

    input  wire        clk,             // 96 MHz
    output wire [5:0]  nv_addr,
    output wire [15:0] nv_din,
    output wire        nv_we,
    input  wire [15:0] nv_dout,
    input  wire        nv_dirty,
    output reg         nv_dirty_clr
);

    // ------------------------------------------------- boot writes, 74 -> 96
    wire        ld_wr;
    wire [27:0] ld_addr;
    wire [15:0] ld_data;

    data_loader #(
        .ADDRESS_MASK_UPPER_4 (4'h2),
        .ADDRESS_SIZE         (28),
        .WRITE_MEM_CLOCK_DELAY(4),
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

    // Only the 128 bytes the EEPROM has; anything beyond is dropped rather
    // than wrapped onto word 0.
    wire ld_hit = ld_wr && (ld_addr[27:7] == 21'd0);

    // ------------------------------------------------------------ scanner
    reg  [5:0] scan_i = 6'd0;
    reg        phase  = 1'b0;          // 0: present address, 1: compare/write
    reg        valid  = 1'b0;          // the address presented last cycle was ours

    // A boot write takes the port for its one cycle; the scanner's read that
    // cycle is void and simply repeats.
    assign nv_we   = ld_hit;
    assign nv_addr = ld_hit ? ld_addr[6:1] : scan_i;
    assign nv_din  = ld_data;

    wire [15:0] sh_q_even, sh_q_odd;
    wire [15:0] sh_q   = scan_i[0] ? sh_q_odd : sh_q_even;
    wire        sh_wr  = phase && valid && (sh_q != nv_dout);

    always @(posedge clk) begin
        nv_dirty_clr <= nv_dirty;
        if (!phase) begin
            valid <= !ld_hit;
            phase <= 1'b1;
        end else begin
            phase <= 1'b0;
            // Advance only past a word that was really compared.
            if (valid) scan_i <= scan_i + 6'd1;
        end
    end

    // ------------------------------------------------------------ shadow
    wire [15:0] b_even, b_odd;

    // APF's bridge reads are buffered by one word (io_bridge_peripheral's
    // header): a read returns the bus value as it stands, then strobes
    // bridge_rd to start the read of its own address, whose word APF takes
    // from the next read. APF's command handler (core_bridge_cmd) works the
    // same way, latching on the strobe. So the address is taken on the
    // strobe and its word held until the next one. Following bridge_addr
    // instead (as this did) answered each read with the word after the one
    // APF wanted: every shutdown wrote the file out rotated by one 32-bit
    // word, the first four bytes at the end (seen on the card, 14 Oct: one
    // word for ddonpach after one launch, three for dfeveron after three).
    reg [4:0] rd_a = 5'd0;
    always @(posedge clk_74a)
        if (bridge_rd && bridge_addr[31:28] == 4'h2) rd_a <= bridge_addr[6:2];

    bram_block_dp #(.DATA(16), .ADDR(5)) u_even (
        .a_clk(clk),     .a_wr(sh_wr && !scan_i[0]), .a_addr(scan_i[5:1]),
        .a_din(nv_dout), .a_dout(sh_q_even),
        .b_clk(clk_74a), .b_wr(1'b0), .b_addr(rd_a),
        .b_din(16'd0),   .b_dout(b_even)
    );

    bram_block_dp #(.DATA(16), .ADDR(5)) u_odd (
        .a_clk(clk),     .a_wr(sh_wr &&  scan_i[0]), .a_addr(scan_i[5:1]),
        .a_din(nv_dout), .a_dout(sh_q_odd),
        .b_clk(clk_74a), .b_wr(1'b0), .b_addr(rd_a),
        .b_din(16'd0),   .b_dout(b_odd)
    );

    // Bridge bytes are big-endian (bridge_endian_little = 0): file byte 4k is
    // [31:24]. File bytes 4k..4k+3 are even-word low, even-word high, odd-word
    // low, odd-word high.
    reg [31:0] rd_word;
    always @(posedge clk_74a)
        rd_word <= {b_even[7:0], b_even[15:8], b_odd[7:0], b_odd[15:8]};
    assign bridge_rd_word = rd_word;

endmodule

`default_nettype wire
