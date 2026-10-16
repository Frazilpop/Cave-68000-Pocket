// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — Air Gallet's and Sailor Moon's sound
// board, as MAME has it (cave.cpp's agallet machine, sailormn_sound_map and
// sailormn_sound_portmap at 0.289): a Z80 at 8 MHz, a YM2151 at 4 MHz and two
// OKI M6295s at 2.112 MHz, mono, in place of Sound's YMZ280B.
//
// The Z80 is TV80 (Guy Hutchison's Verilog port of T80, MIT) on a clock
// enable. Its map:
//   0000-3fff  the ROM's first 16 KB, on chip (written as the image is
//              loaded, io_load_*)
//   4000-7fff  a 16 KB bank of the ROM's 32 (port 00), read through a line
//              cache from the sound ROM port
//   c000-dfff  8 KB of RAM, mirrored at e000-ffff
// and its ports:
//   00 w  the bank (& 1f)         10 w  a reply to the 68000 (a 32-entry FIFO)
//   20 r  0 (the flags)           30/40 r  the 68000's 16-bit latch, low/high
//   50/51 the YM2151 (50 reads ff, 51 its status)
//   60 OKI 0, 70 w its banks      80 OKI 1, c0 w its banks
// The latch: a 68000 write sets it and holds NMI until either half is read
// (generic_latch_16); the YM2151's IRQ is the Z80's INT. The 68000 reads the
// FIFO (io_reply, io_reply_rd) and whether it is empty; a reply written to a
// full FIFO is dropped, as MAME drops it.
//
// The Z80 keeps MAME's time. MAME's Z80 makes an access at the start of its
// M-cycle and takes an interrupt or NMI at the first instruction boundary at
// or after the line goes up – a timer's expiry, the 68000's write to the
// latch. TV80 makes its accesses at T1's end at the earliest and decides on
// an interrupt from what it sampled two T-states before the boundary. So the
// Z80 runs a T-state and a clock ahead of the chips (LAG0), its ports make
// each access on the clock after T1's enable (act); INT is shown to it as it
// will be at the boundary the sample decides, the YM2151's timers counted
// ahead (they are all that raises it); and the whole sound board runs SYNC
// clocks behind the board, so that the 68000's command is known that long
// before the sound board's time reaches it, and NMI can be shown early too.
// A reply reaches the 68000 SYNC clocks after MAME's time; MAME's own 68000
// sees a reply only when the scheduler has run the Z80, often much later.
//
// The Z80's T-states fall on every 4th clock. When a read of the banked
// window misses the cache, the Z80 stands still (no enable) until the line
// is in, and then runs on every clock until it has made up the clocks it
// stood, so that what it does at its ports after that lands where MAME's
// does. With the cache two-way and the next line fetched ahead, Air
// Gallet's music misses a few times a minute and Sailor Moon's only in its
// boot checksum.
//
// The YM2151 (rtl/cave/YM2151.sv) has phiM on every 8th clock and counts its
// timers and busy flag on the 8 MHz enable (TSCALE 2); the OKIs are
// SoundOki's engine at 16,000 Hz with cave.cpp's nibble banks; all three
// count from the sound board's reset (MAME's time 0 there, SYNC clocks after
// the board's). The mix is MAME's:
// the YM2151's left and right at 0.30, each OKI at 1.0 (half SoundOki's
// sums), clamped to 16 bits, held, and strobed at 88,200 Hz for the shell's
// resampler.
//
// The sound ROM port's addresses are the Z80's ROM at 0, OKI 0's 2 MB at
// 0x80000 and OKI 1's at 0x280000 (build_rom.py's z80, oki0 and oki1, one
// after another): the cache's line fills and the OKIs' reads share it, a fill
// the Z80 waits for first. One read at a time, its address held until its
// byte is back (CaveSoundRomReadFreezer answers only the address it is
// shown).

`default_nettype none

module SoundZ80 #(
  parameter integer SETS_LOG2 = 7,      // the cache: two ways of 2^SETS_LOG2 8-byte lines
  parameter integer LAG0 = 8,           // the Z80 starts LAG0 - 3 clocks ahead of the chips
  parameter integer SYNC = 16           // the sound board's time this many clocks behind the board's
) (
  input  wire        clock,             // clk_cpu, 32 MHz
  input  wire        reset,
  input  wire        io_pause,          // the board paused: everything stands still

  // the ROM's first 16 KB, as the image is loaded
  input  wire        io_load_clock,
  input  wire        io_load_wr,
  input  wire [12:0] io_load_addr,      // word address in the Z80's ROM
  input  wire [15:0] io_load_data,      // [7:0] the even byte, as the SDRAM holds the image

  // the 68000's side
  input  wire        io_cmd_wr,         // a one-clock strobe
  input  wire [15:0] io_cmd_data,
  input  wire        io_reply_rd,       // the head of the FIFO taken
  output wire [15:0] io_reply,
  output wire        io_reply_empty,

  // the sound ROM port: one byte a read
  output wire        io_rom_rd,
  output wire [24:0] io_rom_addr,
  input  wire [7:0]  io_rom_dout,
  input  wire        io_rom_wait_n,
  input  wire        io_rom_valid,

  // audio
  output reg  [15:0] io_audio,          // held between strobes
  output reg         io_audio_valid,    // 88,200 Hz
  output reg         io_overrun,        // an OKI sample late, or the YM2151's queue full

  // the harness's taps: each access the Z80 makes, on the clock it is made
  output reg         dbg_act,           // an access made at the ports' time (see act)
  output reg         dbg_acc,           // the access's data taken
  output reg         dbg_acc_io,
  output reg         dbg_acc_wr,
  output reg         dbg_acc_m1,
  output reg  [15:0] dbg_acc_addr,
  output reg  [7:0]  dbg_acc_data,
  output reg  [7:0]  dbg_acc_late,      // clocks behind the Z80's own time
  output reg  [39:0] dbg_acc_time,      // the sound board's clock the access was made on, less dbg_acc_late
  output wire        dbg_ym_sample,
  output wire signed [15:0] dbg_ym_left,
  output wire signed [15:0] dbg_ym_right,
  output wire        dbg_oki_sv0,
  output wire        dbg_oki_sv1,
  output wire signed [19:0] dbg_oki_s0,
  output wire signed [19:0] dbg_oki_s1,
  output wire        dbg_hold           // the Z80 standing for the banked ROM
);

  // ------------------------------------------------------------- the clocks
  // The sound board's reset ends SYNC clocks after the board's; its time
  // (stime, MAME's time on the sound board) counts from there.
  reg  [4:0]  syncCnt;
  reg         sreset;
  always @(posedge clock)
    if (reset) begin
      syncCnt <= 5'd0;
      sreset <= 1'b1;
    end else if (syncCnt != SYNC[4:0] - 5'd1)
      syncCnt <= syncCnt + 5'd1;
    else
      sreset <= 1'b0;

  // phiM on every 8th clock, the 8 MHz enable on every 4th, from reset
  reg  [2:0] cnt;
  reg  [39:0] stime;
  wire       phiM = !io_pause && cnt == 3'd0;
  wire       ce8  = !io_pause && cnt[1:0] == 2'd0;
  always @(posedge clock)
    if (sreset) begin
      cnt <= 3'd0;
      stime <= 40'd0;
    end else if (!io_pause) begin
      cnt <= cnt + 3'd1;
      stime <= stime + 40'd1;
    end

  // The Z80's enable: lag counts the clocks it is behind its own time, plus
  // 3; a T-state is due when lag reaches 3.
  reg  [7:0] lag;
  wire       hold;
  wire       cenZ = !io_pause && !hold && lag >= 8'd3;
  always @(posedge clock)
    if (sreset)         lag <= LAG0[7:0];
    else if (!io_pause) lag <= lag + 8'd1 - (cenZ ? 8'd4 : 8'd0);

  // ---------------------------------------------------------------- the Z80
  wire        m1_n, iorq, no_read, write, halt_n, intcycle_n;
  wire [15:0] A;
  wire [7:0]  dout;
  wire [6:0]  mc, ts;
  reg  [7:0]  di;
  reg  [7:0]  diReg;
  reg         nmiPending;
  wire        ymIrq;
  wire        intAhead;

  tv80_core #(.Mode (0), .IOWait (1)) z80 (
    .reset_n    (!sreset),
    .clk        (clock),
    .cen        (cenZ),
    .wait_n     (1'b1),
    .int_n      (!intAhead),
    .nmi_n      (!nmiPending),
    .busrq_n    (1'b1),
    .dinst      (di),
    .di         (diReg),
    .m1_n       (m1_n),
    .iorq       (iorq),
    .no_read    (no_read),
    .write      (write),
    .rfsh_n     (),
    .halt_n     (halt_n),
    .busak_n    (),
    .A          (A),
    .dout       (dout),
    .mc         (mc),
    .ts         (ts),
    .intcycle_n (intcycle_n),
    .IntE       (),
    .stop       ()
  );

  // What the M-cycle is (tv80s's decode): an opcode fetch (or the interrupt
  // acknowledge) in M1, else a read or a write unless the cycle is internal.
  // Its data is taken on the enable that ends T2 (take). MAME makes an
  // access at the start of its M-cycle, before the cycle's clocks; the ports
  // here make it on the clock after T1's enable (act), the first on which
  // the address, the direction and a write's data are all out, and the Z80
  // runs a T-state ahead of the chips (LAG0) so that this clock is MAME's.
  // What an I/O read gets is taken from the port then and held for T2.
  wire isM1    = mc[0];
  wire isIack  = isM1 && !intcycle_n;
  wire isRead  = isM1 ? intcycle_n : (!no_read && !write);
  wire isWrite = !isM1 && write;
  wire isIo    = !isM1 && iorq;
  wire inT2    = ts[2];
  wire memRd   = inT2 && isRead && !isIo;
  wire take    = cenZ && inT2 && (isRead || isWrite || isIack);
  wire memWr   = take && !isIo && isWrite;
  reg  act, t1Seen;
  reg  [7:0] actLate;
  always @(posedge clock)
    if (sreset) begin
      act <= 1'b0;
      t1Seen <= 1'b0;
      actLate <= 8'd0;
    end else begin
      act <= cenZ && ts[1] && !t1Seen;
      if (cenZ) begin
        t1Seen <= ts[1];
        if (ts[1] && !t1Seen)
          actLate <= lag - 8'd3;
      end
    end
  wire ioRd    = act && isIo && isRead;
  wire ioWr    = act && isIo && isWrite;
  wire [7:0] port = A[7:0];

  // ----------------------------------------------------------- the memories
  // The fixed 16 KB, written on the loader's clock
  reg  [15:0] fixedRom [0:8191];
  reg  [15:0] fixedQ;
  always @(posedge io_load_clock)
    if (io_load_wr) fixedRom[io_load_addr] <= io_load_data;
  always @(posedge clock)
    fixedQ <= fixedRom[A[13:1]];

  // the 8 KB of RAM
  reg  [7:0]  ram [0:8191];
  reg  [7:0]  ramQ;
  always @(posedge clock) begin
    if (memWr && A[15:14] == 2'b11)
      ram[A[12:0]] <= dout;
    ramQ <= ram[A[12:0]];
  end

  reg  [1:0]  regionQ;
  reg         byteQ;
  always @(posedge clock) begin
    regionQ <= A[15:14];
    byteQ <= A[0];
  end

  // ------------------------------------------------------ the banked window
  // Two ways of 2^SETS_LOG2 lines of 8 bytes; a line is the ROM's byte
  // address [18:3], its set the low bits, its tag the rest.
  localparam integer SETS = 1 << SETS_LOG2;
  localparam integer TW = 16 - SETS_LOG2;
  reg  [4:0]  bank;
  wire [18:0] romAddr = {bank, A[13:0]};
  wire [15:0] zLine   = romAddr[18:3];
  wire [15:0] nLine   = zLine + 16'd1;

  (* ramstyle = "MLAB, no_rw_check" *) reg [TW:0] tag0 [0:SETS-1];   // {valid, tag}
  (* ramstyle = "MLAB, no_rw_check" *) reg [TW:0] tag1 [0:SETS-1];
  reg  [SETS-1:0] lru;                  // the way to fill next
  reg  [7:0]  lineData [0:2*SETS*8-1];
  reg  [7:0]  lineQ;

  wire [SETS_LOG2-1:0] zSet = zLine[SETS_LOG2-1:0];
  wire [TW-1:0]        zTag = zLine[15:SETS_LOG2];
  wire [SETS_LOG2-1:0] nSet = nLine[SETS_LOG2-1:0];
  wire [TW-1:0]        nTag = nLine[15:SETS_LOG2];
  wire zHit0 = tag0[zSet] == {1'b1, zTag};
  wire zHit1 = tag1[zSet] == {1'b1, zTag};
  wire zHit  = zHit0 || zHit1;
  wire nHit  = tag0[nSet] == {1'b1, nTag} || tag1[nSet] == {1'b1, nTag};
  wire inWindow = A[15:14] == 2'b01;

  // the line fill: 8 byte reads on the port
  reg         filling, fillDemand, fillPending;
  reg  [15:0] fillLine;
  reg         fillWay;
  reg  [2:0]  fillCount;
  reg         pfValid;
  reg  [15:0] pfLine;
  reg         initDone;
  reg  [SETS_LOG2-1:0] initSet;
  wire [SETS_LOG2-1:0] fillSet = fillLine[SETS_LOG2-1:0];

  reg  hitQ;
  always @(posedge clock) begin
    lineQ <= lineData[{zHit1, zSet, romAddr[2:0]}];
    hitQ <= zHit;
  end

  // the Z80 in T2 of a read of the window whose byte is not out of the cache
  wire windowRd = memRd && inWindow;
  assign hold = windowRd && !(hitQ && zHit);
  assign dbg_hold = hold;

  wire fillingZ = filling && fillLine == zLine;
  wire fillingN = filling && fillLine == nLine;
  wire demand   = windowRd && !zHit && !fillingZ;

  // ------------------------------------------------------ the port, shared
  wire        okiRd;
  wire [24:0] okiAddr;
  wire        okiValid;
  reg         romBusy;
  reg         romOwnerFill;
  wire        fillWants = filling && !fillPending;
  wire        selFill = !romBusy && fillWants && (fillDemand || !okiRd);
  wire        selOki  = !romBusy && !selFill && okiRd;
  reg  [24:0] romAddrHeld;               // the read outstanding, held till its byte is back
  assign io_rom_rd   = selFill || selOki;
  assign io_rom_addr = romBusy ? romAddrHeld : selFill ? {6'd0, fillLine, fillCount} : okiAddr;
  wire        okiWait_n = selOki && io_rom_wait_n;
  assign okiValid = io_rom_valid && romBusy && !romOwnerFill;
  wire        fillValid = io_rom_valid && romBusy && romOwnerFill;

  always @(posedge clock) begin
    if (sreset) begin
      romBusy <= 1'b0;
      romOwnerFill <= 1'b0;
    end else begin
      if (io_rom_rd && io_rom_wait_n) begin
        romBusy <= 1'b1;
        romOwnerFill <= selFill;
        romAddrHeld <= io_rom_addr;
      end else if (io_rom_valid)
        romBusy <= 1'b0;
    end
  end

  // ------------------------------------------------------------ the cache
  always @(posedge clock) begin
    if (sreset) begin
      filling <= 1'b0;
      fillDemand <= 1'b0;
      fillPending <= 1'b0;
      pfValid <= 1'b0;
      initDone <= 1'b0;
      initSet <= {SETS_LOG2{1'b0}};
      lru <= {SETS{1'b0}};
    end else if (!initDone) begin
      initSet <= initSet + 1'd1;
      if (initSet == SETS[SETS_LOG2-1:0] - 1'd1)
        initDone <= 1'b1;
    end else begin
      // the next line, wanted when the Z80 reads a line
      if (take && !isIo && isRead && inWindow && !nHit && !fillingN) begin
        pfValid <= 1'b1;
        pfLine <= nLine;
      end
      if (take && !isIo && isRead && inWindow)
        lru[zSet] <= !zHit1;

      if (!filling) begin
        if (demand || pfValid) begin
          filling <= 1'b1;
          fillDemand <= demand;
          fillLine <= demand ? zLine : pfLine;
          fillCount <= 3'd0;
          if (demand) begin
            // the next line too, after this one
            if (!nHit) begin
              pfValid <= 1'b1;
              pfLine <= nLine;
            end
          end else
            pfValid <= 1'b0;
          // the way not used last, its tag cleared (the tags' write port, below)
          fillWay <= lru[victimSet];
          lru[victimSet] <= !lru[victimSet];
        end
      end else begin
        if (selFill && io_rom_wait_n)
          fillPending <= 1'b1;
        if (fillValid) begin
          fillPending <= 1'b0;
          fillCount <= fillCount + 3'd1;
          if (fillCount == 3'd7)
            filling <= 1'b0;
        end
      end
    end
  end

  always @(posedge clock)
    if (fillValid)
      lineData[{fillWay, fillSet, fillCount}] <= io_rom_dout;

  // the tags' one write port: cleared at reset, a victim's cleared when its
  // fill begins, written when the fill's last byte is in
  wire [SETS_LOG2-1:0] victimSet = demand ? zSet : pfLine[SETS_LOG2-1:0];
  reg                  tagWe0, tagWe1;
  reg  [SETS_LOG2-1:0] tagWa;
  reg  [TW:0]          tagWd;
  always @* begin
    tagWe0 = 1'b0;
    tagWe1 = 1'b0;
    tagWa  = fillSet;
    tagWd  = {1'b1, fillLine[15:SETS_LOG2]};
    if (!initDone) begin
      tagWe0 = 1'b1;
      tagWe1 = 1'b1;
      tagWa  = initSet;
      tagWd  = {(TW+1){1'b0}};
    end else if (!filling && (demand || pfValid)) begin
      tagWe0 = !lru[victimSet];
      tagWe1 = lru[victimSet];
      tagWa  = victimSet;
      tagWd  = {(TW+1){1'b0}};
    end else if (filling && fillValid && fillCount == 3'd7) begin
      tagWe0 = !fillWay;
      tagWe1 = fillWay;
    end
  end
  always @(posedge clock) begin
    if (tagWe0) tag0[tagWa] <= tagWd;
    if (tagWe1) tag1[tagWa] <= tagWd;
  end

  // ----------------------------------------------------- the 68000's side
  // The command, written on the board's time, goes down a line of SYNC
  // clocks to the sound board's (68000 commands are 50 us apart at least).
  reg  [SYNC-1:0] cmdLine;
  reg  [15:0] cmdHeld;
  always @(posedge clock)
    if (reset)
      cmdLine <= {SYNC{1'b0}};
    else if (!io_pause) begin
      cmdLine <= {cmdLine[SYNC-2:0], io_cmd_wr};
      if (io_cmd_wr)
        cmdHeld <= io_cmd_data;
    end

  reg  [15:0] latch;
  reg  [7:0]  fifo [0:31];
  reg  [4:0]  wptr, rptr;
  reg         empty;
  wire        push = ioWr && port == 8'h10;
  wire        pushOk = push && (empty || wptr != rptr);
  wire        pop = io_reply_rd && !empty;
  wire [4:0]  rptrNext = rptr + {4'd0, pop};

  assign io_reply = {8'h00, fifo[rptr]};
  assign io_reply_empty = empty;

  always @(posedge clock) begin
    if (sreset) begin
      latch <= 16'h0000;
      nmiPending <= 1'b0;
      wptr <= 5'd0;
      rptr <= 5'd0;
      empty <= 1'b1;
      bank <= 5'd0;
    end else begin
      if (ioRd && (port == 8'h30 || port == 8'h40))
        nmiPending <= 1'b0;
      // MAME runs the Z80 up to the command's time rounded down to the
      // Z80's own cycle (its scheduler counts whole cycles), then writes the
      // latch and raises NMI: so both count from up to 3 clocks before the
      // command, and NMI is shown 9 clocks earlier still, as the Z80
      // samples it
      if (cmdLine[SYNC-14])
        nmiPending <= 1'b1;
      if (cmdLine[SYNC-5])
        latch <= cmdHeld;
      if (pushOk) begin
        fifo[wptr] <= dout;
        wptr <= wptr + 5'd1;
      end
      rptr <= rptrNext;
      empty <= pushOk ? 1'b0 : pop ? (rptrNext == wptr) : empty;
      if (ioWr && port == 8'h00)
        bank <= dout[4:0];
    end
  end

  // -------------------------------------------------------------- the chips
  wire [7:0]  ymDout;
  wire        ymSample, ymOverrun;
  wire signed [15:0] ymLeft, ymRight;
  wire        tmrArmA, tmrArmB;
  wire [23:0] tmrCntA, tmrCntB;

  // INT as it will be at the boundary the Z80's sample on this enable
  // decides, 9 clocks on in its own time (fewer when it is behind): raised
  // already, or a timer expiring by then. A timer expires on its count-th
  // 8 MHz enable from now.
  wire signed [9:0]  ahead = 10'sd12 - $signed({2'b00, lag});
  wire        [1:0]  toCe8 = 2'd0 - cnt[1:0];
  wire        [26:0] offA  = {25'd0, toCe8} + {1'b0, tmrCntA, 2'b00} - 27'd4;
  wire        [26:0] offB  = {25'd0, toCe8} + {1'b0, tmrCntB, 2'b00} - 27'd4;
  wire        soonA = tmrArmA && tmrCntA != 24'd0 && !ahead[9] && offA <= {17'd0, ahead};
  wire        soonB = tmrArmB && tmrCntB != 24'd0 && !ahead[9] && offB <= {17'd0, ahead};
  assign intAhead = ymIrq || soonA || soonB;
  YM2151 #(.TSCALE (2)) ym2151 (
    .clock      (clock),
    .reset      (sreset),
    .cen        (phiM),
    .cen_t      (ce8),
    .io_wr      (ioWr && port[7:1] == 7'h28),
    .io_a0      (A[0]),
    .io_din     (dout),
    .io_dout    (ymDout),
    .io_irq     (ymIrq),
    .io_sample  (ymSample),
    .io_left    (ymLeft),
    .io_right   (ymRight),
    .io_ct      (),
    .io_tmr_a_arm (tmrArmA),
    .io_tmr_a_cnt (tmrCntA),
    .io_tmr_b_arm (tmrArmB),
    .io_tmr_b_cnt (tmrCntB),
    .io_overrun (ymOverrun)
  );

  wire [7:0]  okiDout0, okiDout1;
  wire        okiSv0, okiSv1, okiOverrun;
  wire signed [19:0] okiS0, okiS1;
  SoundOki #(
    .RATE_NUM  (1),
    .RATE_DEN  (2000),
    .BOTH      (1),
    .PAGED     (1),
    .OKI0_BASE (25'h080000),
    .OKI1_BASE (25'h280000)
  ) oki (
    .clock             (clock),
    .reset             (sreset),
    .io_pause          (io_pause),
    .io_oki_0_wr       (ioWr && port == 8'h60),
    .io_oki_0_din      (dout),
    .io_oki_0_dout     (okiDout0),
    .io_oki_1_wr       (ioWr && port == 8'h80),
    .io_oki_1_din      (dout),
    .io_oki_1_dout     (okiDout1),
    .io_nmk_wr         (ioWr && (port == 8'h70 || port == 8'hc0)),
    .io_nmk_addr       ({port[7], 2'b00}),
    .io_nmk_din        (dout),
    .io_rom_rd         (okiRd),
    .io_rom_addr       (okiAddr),
    .io_rom_dout       (io_rom_dout),
    .io_rom_wait_n     (okiWait_n),
    .io_rom_valid      (okiValid),
    .io_audio          (),
    .io_audio_valid    (),
    .io_overrun        (okiOverrun),
    .io_sample_valid_0 (okiSv0),
    .io_sample_valid_1 (okiSv1),
    .io_sample_0       (okiS0),
    .io_sample_1       (okiS1)
  );

  assign dbg_ym_sample = ymSample;
  assign dbg_ym_left   = ymLeft;
  assign dbg_ym_right  = ymRight;
  assign dbg_oki_sv0   = okiSv0;
  assign dbg_oki_sv1   = okiSv1;
  assign dbg_oki_s0    = okiS0;
  assign dbg_oki_s1    = okiS1;

  // ------------------------------------------------- what the Z80 reads
  reg  [7:0] ioIn, ioQ;
  always @* begin
    case (port)
      8'h30:          ioIn = latch[7:0];
      8'h40:          ioIn = latch[15:8];
      8'h50, 8'h51:   ioIn = ymDout;
      8'h60:          ioIn = okiDout0;
      8'h80:          ioIn = okiDout1;
      default:        ioIn = 8'h00;     // 20 and the ports not read
    endcase
  end
  always @(posedge clock)
    if (ioRd)
      ioQ <= ioIn;

  always @* begin
    if (isIack)
      di = 8'hff;                       // no vector on the bus
    else if (isIo)
      di = ioQ;
    else
      case (regionQ)
        2'b00:   di = byteQ ? fixedQ[15:8] : fixedQ[7:0];
        2'b01:   di = lineQ;
        2'b11:   di = ramQ;
        default: di = 8'h00;
      endcase
  end

  always @(posedge clock)
    if (sreset)
      diReg <= 8'h00;
    else if (cenZ && inT2 && !write && !no_read)
      diReg <= di;

  // ----------------------------------------------------------------- the mix
  // 0.30 (L + R) as 19,661 / 65,536, and half each OKI's sum
  reg  signed [15:0] ymL, ymR;
  reg  signed [19:0] oki0, oki1;
  wire signed [16:0] ymSum  = {ymL[15], ymL} + {ymR[15], ymR};
  wire signed [32:0] ymProd = ymSum * 33'sd19661;
  wire signed [21:0] mix = $signed(ymProd[32:16]) +
                           $signed({{2{oki0[19]}}, oki0[19:1]}) +
                           $signed({{2{oki1[19]}}, oki1[19:1]});
  wire [15:0] mixClamped = (mix > 22'sd32767) ? 16'h7fff : (mix < -22'sd32768) ? 16'h8000 : mix[15:0];

  reg  [19:0] outAcc;                   // 2646 / 960,000 a clock
  wire [19:0] outNext = outAcc + 20'd2646;

  always @(posedge clock) begin
    io_audio_valid <= 1'b0;
    io_overrun <= 1'b0;
    if (sreset) begin
      ymL <= 16'sd0;  ymR <= 16'sd0;
      oki0 <= 20'sd0; oki1 <= 20'sd0;
      outAcc <= 20'd0;
      io_audio <= 16'h0000;
    end else begin
      if (ymSample) begin
        ymL <= ymLeft;
        ymR <= ymRight;
      end
      if (okiSv0) oki0 <= okiS0;
      if (okiSv1) oki1 <= okiS1;
      outAcc <= (outNext >= 20'd960000) ? outNext - 20'd960000 : outNext;
      if (outNext >= 20'd960000) begin
        io_audio <= mixClamped;
        io_audio_valid <= 1'b1;
      end
      if (okiOverrun || ymOverrun)
        io_overrun <= 1'b1;
    end
  end

  // ------------------------------------------------------------ the taps
  always @(posedge clock) begin
    dbg_act <= act && !isIack;
    dbg_acc <= take && !isIack;
    dbg_acc_io <= isIo;
    dbg_acc_wr <= isWrite;
    dbg_acc_m1 <= isM1;
    dbg_acc_addr <= A;
    dbg_acc_data <= isWrite ? dout : di;
    dbg_acc_late <= actLate;
    if (act)
      dbg_acc_time <= stime - {32'd0, actLate};
  end
endmodule

`default_nettype wire
