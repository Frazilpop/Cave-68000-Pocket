// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).

// Atlus-class sound integration: YMZ280B, DonPachi dual OKI/NMK112, and
// Power Instinct 2 Z80/YM2203/dual OKI/NMK112.
module Sound(
  input         clock,
  input         reset,
  input         io_ctrl_oki_0_wr,
  input  [15:0] io_ctrl_oki_0_din,
  output [15:0] io_ctrl_oki_0_dout,
  input         io_ctrl_oki_1_wr,
  input  [15:0] io_ctrl_oki_1_din,
  output [15:0] io_ctrl_oki_1_dout,
  input         io_ctrl_nmk_wr,
  input  [22:0] io_ctrl_nmk_addr,
  input  [15:0] io_ctrl_nmk_din,
  input         io_ctrl_ymz_rd,
  input         io_ctrl_ymz_wr,
  input  [22:0] io_ctrl_ymz_addr,
  input  [15:0] io_ctrl_ymz_din,
  output [15:0] io_ctrl_ymz_dout,
  input         io_ctrl_req,
  input  [15:0] io_ctrl_data,
  input         io_ctrl_reply_rd,
  output [15:0] io_ctrl_reply,
  output        io_ctrl_reply_empty,
  output        io_ctrl_irq,
  input  [3:0]  io_gameIndex,
  input  [1:0]  io_gameConfig_sound_0_device,
  input         io_options_ym_psg,
  input         io_options_ym_fm,
  input         io_options_oki_0,
  input         io_options_oki_1,
  input  [3:0]  io_options_pwrinst2_oki0_level,
  input  [3:0]  io_options_pwrinst2_oki1_level,
  input         io_options_pwrinst2_headroom,
  input  [3:0]  io_options_pwrinst2_psg_level,
  input  [3:0]  io_options_pwrinst2_fm_level,
  input  [3:0]  io_options_ymz_level,
  output        io_rom_0_rd,
  output [24:0] io_rom_0_addr,
  input  [7:0]  io_rom_0_dout,
  input         io_rom_0_wait_n,
  input         io_rom_0_valid,
  output        io_rom_1_rd,
  output [24:0] io_rom_1_addr,
  input  [7:0]  io_rom_1_dout,
  input         io_rom_1_valid,
  output        io_rom_2_rd,
  output [24:0] io_rom_2_addr,
  input  [7:0]  io_rom_2_dout,
  input         io_rom_2_valid,
  output [63:0] io_debug,
`ifdef CAVE_PWRINST2_SOUND_DIAGNOSTICS
  output [255:0] io_hw_debug,
`endif
  output [15:0] io_audio,
  input         io_ss_hold,
  input         io_ss_capture_request,
  input         io_ss_restore_enable,
  input         io_ss_restore_start,
  input         io_ss_restore_commit,
  input         io_ss_release,
  output        io_ss_capture_done,
  output        io_ss_cpu_idle,
  output        io_ss_restore_commit_done,
  output        io_ss_reconstruction_ready,
  output        io_ss_idle,
  cave_ssbus_if.slave io_ssbus
);
  wire        donpachi;
  wire        pwrinst2;
  wire        soundDeviceIsOki;
  wire        soundDeviceIsYmz;
  wire        soundDeviceIsZ80;
  wire        pwrinst2Z80Sound;

  CaveBoardProfile boardProfile(
    .game_index                  (io_gameIndex),
    .sound_device                (io_gameConfig_sound_0_device),
    .game_is_dfeveron            (),
    .game_is_dodonpachi          (),
    .game_is_donpachi            (donpachi),
    .game_is_esprade             (),
    .game_is_uopoko              (),
    .game_is_guwange             (),
    .game_is_gaia                (),
    .game_is_pwrinst2            (pwrinst2),
    .game_is_plegends            (),
    .board_uses_z80_sound        (),
    .board_is_vertical_clockwise (),
    .sound_is_ymz280b            (soundDeviceIsYmz),
    .sound_is_oki                (soundDeviceIsOki),
    .sound_is_z80                (soundDeviceIsZ80)
  );

  assign pwrinst2Z80Sound = pwrinst2 & soundDeviceIsZ80;

  cave_ssbus_if soundSaveStateOwners[10]();

  reg         reqReg;
  reg         latchHighReadSeen;
  reg         latchLowReadSeen;
  reg  [15:0] dataReg;
  reg  [2:0]  z80BankReg;
  reg         z80IoWrD;
  reg  [7:0]  z80IoWrAddrD;
  reg  [7:0]  z80IoWrDataD;
  reg  [7:0]  replyFifo [0:31];
  reg  [4:0]  replyReadPtr;
  reg  [4:0]  replyWritePtr;
  reg  [5:0]  replyCount;
  integer     replyResetIndex;

  reg  [3:0]  okiBankHiReg;
  reg  [3:0]  okiBankLoReg;
  reg  [15:0] ymzAudioReg;
  reg  [15:0] ym2203PsgAudioReg;
  reg  [15:0] ym2203FmAudioReg;
  reg  [13:0] oki0AudioReg;
  reg  [13:0] oki1AudioReg;

`ifdef CAVE_ENABLE_DEBUG_OVERLAY
  reg  [7:0]  debugLastSoundCommand;
  reg  [7:0]  debugOki0PhraseCommand;
  reg  [7:0]  debugOki0StartCommand;
  reg  [7:0]  debugOki0StatusRead;
  reg  [7:0]  debugOki0StartChannels;
  reg  [7:0]  debugOki0BusyOverlap;
  reg  [7:0]  debugOki1StatusRead;
  reg  [7:0]  debugOki0RawPage;
  reg  [7:0]  debugOki0MappedPage;
  reg  [7:0]  debugOki0NmkPage;
  reg  [7:0]  debugOki0ReadPhase;
  reg  [7:0]  debugLastNmkWrite;
  reg  [7:0]  debugLastYmReg;
  reg  [7:0]  debugLastYmData;
  reg  [7:0]  debugYmFlags;
  reg  [7:0]  debugYmWriteCount;
  reg  [7:0]  debugYmPsgPeak;
  reg  [7:0]  debugYmFmPeak;
  reg         debugOki0Pending;
  reg         debugCfPending;
  reg         debugCfCaptured;
  reg  [1:0] debugCfPendingAge;
  reg  [28:0] debugCfPageCounter;
  reg  [7:0]  debugCfPhraseCommand;
  reg  [7:0]  debugCfStartCommand;
  reg  [7:0]  debugCfStatusAtStart;
  reg  [7:0]  debugCfOverlap;
  reg  [7:0]  debugCfRawPage;
  reg  [7:0]  debugCfMappedPage;
  reg  [7:0]  debugCfNmkPage;
  reg  [7:0]  debugCfReadPhase;
  reg  [7:0]  debugCfLastNmkWrite;
  reg  [7:0]  debugCfLatchStatus;
  reg  [47:0] debugCfCtrlBytes;
  reg  [47:0] debugCfDecodeBytes;
  reg  [47:0] debugCfTableBytes;
  reg  [47:0] debugCfBodyBytes;
  reg  [2:0]  debugCfPageSelect;
  reg  [31:0] debugOki0Pair0;
  reg  [31:0] debugOki0Pair1;
  reg  [31:0] debugOki0Pair2;
  reg  [31:0] debugOki0Pair3;
  reg  [31:0] debugCfPair0;
  reg  [31:0] debugCfPair1;
  reg  [31:0] debugCfPair2;
  reg  [31:0] debugCfPair3;
  reg  [7:0]  debugCfZ80Flags;
  reg  [7:0]  debugCfZ80IoAddr;
  reg  [7:0]  debugCfZ80IoData;
  reg  [7:0]  debugCfReqStatus;
  reg  [7:0]  debugCfDataHigh;
  reg  [7:0]  debugCfDataLow;
`endif

  wire [15:0] cpuAddr;
  wire [7:0]  cpuDout;
  wire        cpuRd;
  wire        cpuWr;
  wire        cpuRfsh;
  wire        cpuMreq;
  wire        cpuIorq;
  wire        cpuInt;
  wire [15:0] cpuIoAddr = {8'h00, cpuAddr[7:0]};
  wire        ym2203CpuWaitN;
  wire        ym2203QueueFull;

  wire        z80ProgRomSelect = cpuAddr < 16'h8000;
  wire        z80BankRomSelect = (cpuAddr >= 16'h8000) & (cpuAddr < 16'hC000);
  wire        z80RamSelect = cpuAddr >= 16'hE000;
  wire        z80IoWr = pwrinst2Z80Sound & cpuIorq & cpuWr;
  wire        ym2203Access =
    pwrinst2Z80Sound & (cpuIoAddr >= 16'h0040) & (cpuIoAddr < 16'h0042) & cpuIorq;
  wire        ym2203WriteCycle = ym2203Access & cpuWr;
  wire        z80IoWrReady = ~ym2203WriteCycle | ym2203CpuWaitN;
  wire        z80IoWrChanged =
    z80IoWr & ((cpuIoAddr[7:0] != z80IoWrAddrD) | (cpuDout != z80IoWrDataD));
  wire        z80IoWrPulse = z80IoWr & z80IoWrReady & (~z80IoWrD | z80IoWrChanged);

  wire        pwrinst2Oki0Access = pwrinst2Z80Sound & (cpuIoAddr == 16'h0000) & cpuIorq;
  wire        pwrinst2Oki1Access = pwrinst2Z80Sound & (cpuIoAddr == 16'h0008) & cpuIorq;
  wire        pwrinst2NmkWrite =
    pwrinst2Z80Sound & (cpuIoAddr >= 16'h0010) & (cpuIoAddr < 16'h0018) & z80IoWrPulse;
  wire        ym2203Write = ym2203Access & z80IoWrPulse;
  wire        ym2203Read = ym2203Access & cpuRd;
  wire        soundReplyWrite = pwrinst2Z80Sound & (cpuIoAddr == 16'h0050) & z80IoWrPulse;
  wire        latchHighRead = pwrinst2Z80Sound & (cpuIoAddr == 16'h0060) & cpuIorq & cpuRd;
  wire        latchLowRead = pwrinst2Z80Sound & (cpuIoAddr == 16'h0070) & cpuIorq & cpuRd;
  wire        z80BankWrite = pwrinst2Z80Sound & (cpuIoAddr == 16'h0080) & z80IoWrPulse;
  wire        replyPop = io_ctrl_reply_rd & (replyCount != 6'd0);
  wire        replyPush = soundReplyWrite & ((replyCount != 6'd32) | replyPop);
  wire        latchHighReadSeenNext = io_ctrl_req ? 1'b0 : (latchHighReadSeen | latchHighRead);
  wire        latchLowReadSeenNext = io_ctrl_req ? 1'b0 : (latchLowReadSeen | latchLowRead);

  wire [7:0]  soundRamDout;
  wire        soundRamRd = pwrinst2Z80Sound & z80RamSelect & cpuMreq & cpuRd & ~cpuRfsh;
  wire        soundRamWr = pwrinst2Z80Sound & z80RamSelect & cpuMreq & cpuWr;

  wire [7:0]  progRomDout;
  wire        progRomValid;
  wire [7:0]  bankRomDout;
  wire        bankRomValid;
  wire        z80RomRead =
    pwrinst2Z80Sound & cpuMreq & cpuRd & ~cpuRfsh & (z80ProgRomSelect | z80BankRomSelect);
  wire        z80ProgRomArbiterRead =
    pwrinst2Z80Sound & z80ProgRomSelect & cpuMreq & cpuRd & ~cpuRfsh;
  wire        z80BankRomArbiterRead =
    pwrinst2Z80Sound & z80BankRomSelect & cpuMreq & cpuRd & ~cpuRfsh;
  wire        z80RomValid = z80BankRomSelect ? bankRomValid : progRomValid;
  wire        z80WaitN = (~z80RomRead | z80RomValid) & z80IoWrReady;
  wire [7:0]  romOrBankDout =
    z80BankRomSelect & cpuMreq & cpuRd ? bankRomDout : progRomDout;

  wire [7:0]  oki0CpuDout;
  wire        oki0RomRead;
  wire [17:0] oki0RomAddr;
  wire [7:0]  oki0RomDout;
  wire        oki0RomValid;
  wire        oki0AudioValid;
  wire [13:0] oki0Audio;
  wire [47:0] oki0DebugCtrlBytes;
  wire [47:0] oki0DebugDecodeBytes;
  wire [47:0] oki0DebugTableBytes;
  wire [47:0] oki0DebugBodyBytes;
  wire        oki0DebugBodyDone;
  wire [7:0]  oki0DebugBusyState;

  wire [7:0]  oki1CpuDout;
  wire        oki1RomRead;
  wire [17:0] oki1RomAddr;
  wire        oki1AudioValid;
  wire [13:0] oki1Audio;
  wire [47:0] oki1DebugCtrlBytes;
  wire [47:0] oki1DebugDecodeBytes;
  wire [47:0] oki1DebugTableBytes;
  wire [47:0] oki1DebugBodyBytes;
  wire        oki1DebugBodyDone;
  wire [7:0]  oki1DebugBusyState;
  wire [7:0]  donpachiOki0CpuDout;
  wire        donpachiOki0RomRead;
  wire [17:0] donpachiOki0RomAddr;
  wire        donpachiOki0AudioValid;
  wire [13:0] donpachiOki0Audio;
  wire        donpachiOki0SsIdle;
  wire [7:0]  donpachiOki1CpuDout;
  wire        donpachiOki1RomRead;
  wire [17:0] donpachiOki1RomAddr;
  wire        donpachiOki1AudioValid;
  wire [13:0] donpachiOki1Audio;
  wire        donpachiOki1SsIdle;
  wire [7:0]  activeOki0CpuDout =
    donpachi ? donpachiOki0CpuDout : oki0CpuDout;
  wire [7:0]  activeOki1CpuDout =
    donpachi ? donpachiOki1CpuDout : oki1CpuDout;
  wire        activeOki0RomRead =
    donpachi ? donpachiOki0RomRead : oki0RomRead;
  wire        activeOki1RomRead =
    donpachi ? donpachiOki1RomRead : oki1RomRead;
  wire [17:0] activeOki0RomAddr =
    donpachi ? donpachiOki0RomAddr : oki0RomAddr;
  wire [17:0] activeOki1RomAddr =
    donpachi ? donpachiOki1RomAddr : oki1RomAddr;
  wire        activeOki0AudioValid =
    donpachi ? donpachiOki0AudioValid : oki0AudioValid;
  wire        activeOki1AudioValid =
    donpachi ? donpachiOki1AudioValid : oki1AudioValid;
  wire [13:0] activeOki0Audio =
    donpachi ? donpachiOki0Audio : oki0Audio;
  wire [13:0] activeOki1Audio =
    donpachi ? donpachiOki1Audio : oki1Audio;
  wire [7:0]  ymzCpuDout;
  wire        ymzRomRd;
  wire [23:0] ymzRomAddr;
  wire [7:0]  ymzRomDout;
  wire        ymzRomWaitN;
  wire        ymzRomValid;
  wire        ymzAudioValid;
  wire [15:0] ymzAudio;
  wire        ymzIrq;
  wire        ymzSsIdle;

  wire [7:0]  ym2203CpuDout;
  wire        ym2203Irq;
  wire        ym2203AudioValid;
  wire [15:0] ym2203PsgAudio;
  wire [15:0] ym2203FmAudio;
  wire        ym2203SsIdle;
  wire        pwrinst2Z80SsCaptureDone;
  wire        pwrinst2Z80SsCpuIdle;
  wire        pwrinst2Z80SsRestoreCommitDone;
  wire        pwrinst2Z80SsReconstructionReady;
  wire        pwrinst2Oki0SsIdle;
  wire        pwrinst2Oki1SsIdle;
  wire        pwrinst2Oki0RomCacheIdle;
  wire        pwrinst2Oki1RomCacheIdle;
  wire        pwrinst2Oki0MemRead;
  wire [24:0] pwrinst2Oki0MemAddr;
  wire [7:0]  pwrinst2Oki0CacheDout;
  wire        pwrinst2Oki0CacheValid;
  wire        pwrinst2Oki1MemRead;
  wire [24:0] pwrinst2Oki1MemAddr;
  wire [7:0]  pwrinst2Oki1CacheDout;
  wire        pwrinst2Oki1CacheValid;
`ifdef CAVE_ENABLE_DEBUG_OVERLAY
  wire [7:0]  ym2203PsgMagnitude = ym2203PsgAudio[15:8];
  wire [7:0]  ym2203FmMagnitude = ym2203FmAudio[15] ? ~ym2203FmAudio[14:7] : ym2203FmAudio[14:7];
  wire [7:0]  debugLatchStatus = {
    4'hA,
    reqReg,
    latchHighReadSeen,
    latchLowReadSeen,
    replyCount != 6'd0
  };
`endif

  wire        nmkWr = pwrinst2NmkWrite | io_ctrl_nmk_wr;
  wire [22:0] nmkAddr = pwrinst2NmkWrite ? {15'h0000, cpuIoAddr[7:0]} : io_ctrl_nmk_addr;
  wire [15:0] nmkDin = pwrinst2NmkWrite ? {8'h00, cpuDout} : io_ctrl_nmk_din;
  wire [24:0] nmkOki0AddrOut;
  wire [24:0] nmkOki1AddrOut;
  wire [47:0] nmkSsState;
  wire        soundStateRestoreWr;
  wire [31:0] soundStateRestoreAddr;
  wire [15:0] soundStateRestoreData;
  wire        pwrinst2MailboxRestoreWr;
  wire [31:0] pwrinst2MailboxRestoreAddr;
  wire [15:0] pwrinst2MailboxRestoreData;
  wire        donpachiSoundStateEnable =
    io_ss_hold & donpachi & donpachiOki0SsIdle & donpachiOki1SsIdle;
  wire        pwrinst2SoundDevicesIdle =
    pwrinst2Z80SsCpuIdle &
    ym2203SsIdle &
    pwrinst2Oki0SsIdle &
    pwrinst2Oki1SsIdle &
    pwrinst2Oki0RomCacheIdle &
    pwrinst2Oki1RomCacheIdle;
  wire        pwrinst2SoundStateEnable =
    io_ss_hold & pwrinst2Z80Sound & pwrinst2SoundDevicesIdle;
  wire        sharedSoundStateEnable =
    donpachiSoundStateEnable | pwrinst2SoundStateEnable;
  wire        nmkSsWr =
    soundStateRestoreWr & (soundStateRestoreAddr < 32'd8);
  wire [191:0] sharedSoundState = {
    ym2203FmAudioReg,
    ym2203PsgAudioReg,
    {2'd0, oki1AudioReg},
    {2'd0, oki0AudioReg},
    {10'd0, nmkSsState[47:42]},
    {10'd0, nmkSsState[41:36]},
    {10'd0, nmkSsState[35:30]},
    {10'd0, nmkSsState[29:24]},
    {10'd0, nmkSsState[23:18]},
    {10'd0, nmkSsState[17:12]},
    {10'd0, nmkSsState[11:6]},
    {10'd0, nmkSsState[5:0]}
  };
  wire [319:0] pwrinst2MailboxState;
  assign pwrinst2MailboxState[15:0] = dataReg;
  assign pwrinst2MailboxState[31:16] = {
    1'b0,
    z80IoWrAddrD,
    z80IoWrD,
    z80BankReg,
    latchLowReadSeen,
    latchHighReadSeen,
    reqReg
  };
  assign pwrinst2MailboxState[47:32] = {8'd0, z80IoWrDataD};
  assign pwrinst2MailboxState[63:48] = {
    replyCount,
    replyWritePtr,
    replyReadPtr
  };
  genvar pwrinst2ReplyStateIndex;
  generate
    for (pwrinst2ReplyStateIndex = 0;
         pwrinst2ReplyStateIndex < 16;
         pwrinst2ReplyStateIndex = pwrinst2ReplyStateIndex + 1)
        begin : pwrinst2_reply_state
      assign pwrinst2MailboxState[
        ((pwrinst2ReplyStateIndex + 4) * 16) +: 16
      ] = {
        replyFifo[(pwrinst2ReplyStateIndex * 2) + 1],
        replyFifo[pwrinst2ReplyStateIndex * 2]
      };
    end
  endgenerate
  wire [3:0]  oki0Bank = oki0RomAddr[17] ? okiBankHiReg : okiBankLoReg;
  wire [3:0]  oki1Bank = oki1RomAddr[17] ? okiBankHiReg : okiBankLoReg;
  wire [24:0] bankedOki0MappedAddr = {4'h0, oki0Bank, oki0RomAddr[16:0]};
  wire [24:0] bankedOki1MappedAddr = {4'h0, oki1Bank, oki1RomAddr[16:0]};
  wire [24:0] pwrinst2Oki0FixedAddr = {7'h00, oki0RomAddr};
  wire        pwrinst2Oki0TableRegion = oki0RomAddr[17:10] == 8'h00;
  wire        pwrinst2Oki0PagedTable = pwrinst2Z80Sound & pwrinst2Oki0TableRegion;
  wire        pwrinst2Oki0PagedBody = pwrinst2Z80Sound & ~pwrinst2Oki0TableRegion;
  wire [24:0] pwrinst2Oki0DcAddr =
    (pwrinst2Oki0PagedTable | pwrinst2Oki0PagedBody) ? nmkOki0AddrOut :
                                                        pwrinst2Oki0FixedAddr;
  wire [24:0] oki0MappedAddr =
    pwrinst2Z80Sound ? pwrinst2Oki0DcAddr :
    donpachi ? nmkOki0AddrOut :
    bankedOki0MappedAddr;
  wire [24:0] oki1MappedAddr = (donpachi | pwrinst2Z80Sound) ? nmkOki1AddrOut : bankedOki1MappedAddr;
  wire        pwrinst2Oki0TableRead = pwrinst2Z80Sound & oki0RomRead & pwrinst2Oki0TableRegion;
  wire        pwrinst2Oki0BodyRead = pwrinst2Z80Sound & oki0RomRead & (oki0RomAddr[17:10] != 8'h00);
  wire [7:0]  oki0RomData = pwrinst2Z80Sound ? pwrinst2Oki0CacheDout : oki0RomDout;
  wire        oki0RomDataValid = pwrinst2Z80Sound ? pwrinst2Oki0CacheValid : oki0RomValid;
  wire [7:0]  oki1RomData = pwrinst2Z80Sound ? pwrinst2Oki1CacheDout : io_rom_1_dout;
  wire        oki1RomDataValid = pwrinst2Z80Sound ? pwrinst2Oki1CacheValid : io_rom_1_valid;
  wire [15:0] ym2203PsgMix = io_options_ym_psg ? ym2203PsgAudioReg : 16'h0000;
  wire [15:0] ym2203FmMix = io_options_ym_fm ? ym2203FmAudioReg : 16'h0000;
  wire [13:0] oki0Mix = io_options_oki_0 ? oki0AudioReg : 14'h0000;
  wire [13:0] oki1Mix = io_options_oki_1 ? oki1AudioReg : 14'h0000;

  wire        oki0CpuWr = pwrinst2Z80Sound ? (pwrinst2Oki0Access & z80IoWrPulse) : io_ctrl_oki_0_wr;
  wire [7:0]  oki0CpuDin = pwrinst2Z80Sound ? cpuDout : io_ctrl_oki_0_din[7:0];
  wire        oki1CpuWr = pwrinst2Z80Sound ? (pwrinst2Oki1Access & z80IoWrPulse) : io_ctrl_oki_1_wr;
  wire [7:0]  oki1CpuDin = pwrinst2Z80Sound ? cpuDout : io_ctrl_oki_1_din[7:0];
  wire [16:0] oki0CenStep = pwrinst2Z80Sound ? 17'h1800 : 17'h0873;
  wire [16:0] oki1CenStep = pwrinst2Z80Sound ? 17'h1800 : 17'h10E5;
  wire        okiPin7Ss = ~pwrinst2Z80Sound;
  wire        pwrinst2Oki0IgnoreBusyStart = pwrinst2Z80Sound;
  wire        pwrinst2Oki0DuplicateBusyStartFilter = 1'b0;

`ifdef CAVE_PWRINST2_SOUND_DIAGNOSTICS
  reg         hwdiagRomValidD = 1'b0;
  reg  [15:0] hwdiagLastCompletedAddr = 16'd0;
  reg  [31:0] hwdiagRomCompletionCount = 32'd0;
  reg  [15:0] hwdiagIoWriteCount = 16'd0;
  reg  [7:0]  hwdiagActivity = 8'd0;
  reg  [7:0]  hwdiagAudioPeak = 8'd0;
  reg         hwdiagCtrlReqD = 1'b0;
  reg         hwdiagLatchHighD = 1'b0;
  reg         hwdiagLatchLowD = 1'b0;
  reg  [15:0] hwdiagMainReqCount = 16'd0;
  reg  [15:0] hwdiagLastCommand = 16'd0;
  reg  [15:0] hwdiagLatchHighCount = 16'd0;
  reg  [15:0] hwdiagLatchLowCount = 16'd0;
  reg  [7:0]  hwdiagLastIoAddr = 8'd0;
  reg  [7:0]  hwdiagLastIoData = 8'd0;
  reg  [7:0]  hwdiagLastYmRegister = 8'd0;
  reg  [15:0] hwdiagYmKeyOnCount = 16'd0;
  reg         hwdiagOki0PhrasePending = 1'b0;
  reg         hwdiagOki1PhrasePending = 1'b0;
  reg  [15:0] hwdiagOki0StartCount = 16'd0;
  reg  [15:0] hwdiagOki1StartCount = 16'd0;

  wire [15:0] hwdiagAudioMagnitude =
    io_audio[15] ? (~io_audio + 16'd1) : io_audio;
  wire [11:0] hwdiagCurrentFlags = {
    pwrinst2Z80Sound,
    reset,
    z80WaitN,
    z80RomRead,
    z80RomValid,
    io_rom_0_wait_n,
    io_rom_0_valid,
    cpuMreq,
    cpuIorq,
    cpuRd,
    cpuWr,
    reqReg
  };

  always @(posedge clock) begin
    if (reset) begin
      hwdiagRomValidD <= 1'b0;
      hwdiagLastCompletedAddr <= 16'd0;
      hwdiagRomCompletionCount <= 32'd0;
      hwdiagIoWriteCount <= 16'd0;
      hwdiagActivity <= 8'd0;
      hwdiagAudioPeak <= 8'd0;
      hwdiagCtrlReqD <= 1'b0;
      hwdiagLatchHighD <= 1'b0;
      hwdiagLatchLowD <= 1'b0;
      hwdiagMainReqCount <= 16'd0;
      hwdiagLastCommand <= 16'd0;
      hwdiagLatchHighCount <= 16'd0;
      hwdiagLatchLowCount <= 16'd0;
      hwdiagLastIoAddr <= 8'd0;
      hwdiagLastIoData <= 8'd0;
      hwdiagLastYmRegister <= 8'd0;
      hwdiagYmKeyOnCount <= 16'd0;
      hwdiagOki0PhrasePending <= 1'b0;
      hwdiagOki1PhrasePending <= 1'b0;
      hwdiagOki0StartCount <= 16'd0;
      hwdiagOki1StartCount <= 16'd0;
    end
    else begin
      hwdiagRomValidD <= z80RomRead & z80RomValid;
      hwdiagCtrlReqD <= io_ctrl_req;
      hwdiagLatchHighD <= latchHighRead;
      hwdiagLatchLowD <= latchLowRead;

      if (io_ctrl_req && !hwdiagCtrlReqD) begin
        hwdiagMainReqCount <= hwdiagMainReqCount + 16'd1;
        hwdiagLastCommand <= io_ctrl_data;
      end
      if (latchHighRead && !hwdiagLatchHighD)
        hwdiagLatchHighCount <= hwdiagLatchHighCount + 16'd1;
      if (latchLowRead && !hwdiagLatchLowD)
        hwdiagLatchLowCount <= hwdiagLatchLowCount + 16'd1;

      if (z80RomRead && z80RomValid &&
          (!hwdiagRomValidD || cpuAddr != hwdiagLastCompletedAddr)) begin
        hwdiagLastCompletedAddr <= cpuAddr;
        hwdiagRomCompletionCount <= hwdiagRomCompletionCount + 32'd1;
        hwdiagActivity[7] <= 1'b1;
      end

      if (z80IoWrPulse) begin
        hwdiagIoWriteCount <= hwdiagIoWriteCount + 16'd1;
        hwdiagActivity[6] <= 1'b1;
        hwdiagLastIoAddr <= cpuIoAddr[7:0];
        hwdiagLastIoData <= cpuDout;
      end
      if (ym2203Write) begin
        hwdiagActivity[5] <= 1'b1;
        if (!cpuAddr[0])
          hwdiagLastYmRegister <= cpuDout;
        else if ((hwdiagLastYmRegister == 8'h28) &&
                 (cpuDout[7:4] != 4'd0))
          hwdiagYmKeyOnCount <= hwdiagYmKeyOnCount + 16'd1;
      end
      if (oki0CpuWr) begin
        hwdiagActivity[4] <= 1'b1;
        if (cpuDout[7])
          hwdiagOki0PhrasePending <= 1'b1;
        else if (hwdiagOki0PhrasePending) begin
          hwdiagOki0PhrasePending <= 1'b0;
          if (cpuDout[7:4] != 4'd0)
            hwdiagOki0StartCount <= hwdiagOki0StartCount + 16'd1;
        end
      end
      if (oki1CpuWr) begin
        hwdiagActivity[3] <= 1'b1;
        if (cpuDout[7])
          hwdiagOki1PhrasePending <= 1'b1;
        else if (hwdiagOki1PhrasePending) begin
          hwdiagOki1PhrasePending <= 1'b0;
          if (cpuDout[7:4] != 4'd0)
            hwdiagOki1StartCount <= hwdiagOki1StartCount + 16'd1;
        end
      end
      if (ym2203AudioValid &&
          ((ym2203PsgAudio != 16'd0) || (ym2203FmAudio != 16'd0)))
        hwdiagActivity[2] <= 1'b1;
      if (oki0AudioValid && (oki0Audio != 14'd0))
        hwdiagActivity[1] <= 1'b1;
      if (oki1AudioValid && (oki1Audio != 14'd0))
        hwdiagActivity[0] <= 1'b1;

      if (hwdiagAudioMagnitude[15:8] > hwdiagAudioPeak)
        hwdiagAudioPeak <= hwdiagAudioMagnitude[15:8];
    end
  end

  assign io_hw_debug = {
    16'hC5D1,
    io_gameIndex,
    hwdiagCurrentFlags,
    cpuAddr,
    hwdiagLastCompletedAddr,
    hwdiagRomCompletionCount,
    hwdiagIoWriteCount,
    hwdiagActivity,
    hwdiagAudioPeak,
    hwdiagMainReqCount,
    hwdiagLastCommand,
    hwdiagLatchHighCount,
    hwdiagLatchLowCount,
    hwdiagLastIoAddr,
    hwdiagLastIoData,
    hwdiagYmKeyOnCount,
    hwdiagOki0StartCount,
    hwdiagOki1StartCount
  };
`endif

`ifdef CAVE_ENABLE_DEBUG_OVERLAY
  wire [3:0]  debugOki0CurrentBusyOverlap = oki0CpuDout[3:0] & oki0CpuDin[7:4];
  wire        debugOki0BusyStartCapture =
    pwrinst2Z80Sound & oki0CpuWr & debugOki0Pending &
    (debugOki0CurrentBusyOverlap != 4'h0) & ~debugCfPending & ~debugCfCaptured;
  wire [31:0] debugOki0CurrentPair = {
    debugOki0StatusRead,
    {4'hA, debugOki0CurrentBusyOverlap},
    oki0CpuDin,
    debugOki0PhraseCommand
  };
  wire [7:0]  debugZ80Flags = {
    pwrinst2Z80Sound,
    cpuInt,
    ym2203Irq,
    ym2203QueueFull,
    ym2203CpuWaitN,
    latchHighReadSeen,
    latchLowReadSeen,
    (replyCount != 6'd0)
  };
  wire [7:0]  debugReqStatus = {
    reqReg,
    io_ctrl_req,
    latchHighRead,
    latchLowRead,
    soundReplyWrite,
    replyPush,
    replyPop,
    z80BankWrite
  };
  wire [7:0]  debugCfPage = {5'h00, debugCfCaptured ? debugCfPageSelect : 3'd0};
  wire [63:0] debugCfPage0 = {
    debugCfNmkPage,
    debugCfMappedPage,
    debugCfOverlap,
    debugCfStatusAtStart,
    debugCfStartCommand,
    debugCfPhraseCommand,
    8'h00,
    8'hF0
  };
  wire [63:0] debugCfPage1 = {
    debugCfCtrlBytes[47:40],
    debugCfCtrlBytes[39:32],
    debugCfCtrlBytes[31:24],
    debugCfCtrlBytes[23:16],
    debugCfCtrlBytes[15:8],
    debugCfCtrlBytes[7:0],
    8'h01,
    8'hF0
  };
  wire [63:0] debugCfPage2 = {
    debugCfTableBytes[47:40],
    debugCfTableBytes[39:32],
    debugCfTableBytes[31:24],
    debugCfTableBytes[23:16],
    debugCfTableBytes[15:8],
    debugCfTableBytes[7:0],
    8'h02,
    8'hF0
  };
  wire [63:0] debugCfPage3 = {
    debugCfBodyBytes[47:40],
    debugCfBodyBytes[39:32],
    debugCfBodyBytes[31:24],
    debugCfBodyBytes[23:16],
    debugCfBodyBytes[15:8],
    debugCfBodyBytes[7:0],
    8'h03,
    8'hF0
  };
  wire [63:0] debugCfPage4 = {
    debugCfDataLow,
    debugCfDataHigh,
    debugCfReqStatus,
    debugCfZ80IoData,
    debugCfZ80IoAddr,
    debugCfZ80Flags,
    8'h04,
    8'hF0
  };
  wire [63:0] debugCfPage5 = {
    debugCfLatchStatus,
    debugCfLastNmkWrite,
    debugCfReadPhase,
    debugCfNmkPage,
    debugCfMappedPage,
    debugCfRawPage,
    8'h05,
    8'hF0
  };
  wire [63:0] debugCfWord =
    debugCfPage[2:0] == 3'd1 ? debugCfPage1 :
    debugCfPage[2:0] == 3'd2 ? debugCfPage2 :
    debugCfPage[2:0] == 3'd3 ? debugCfPage3 :
    debugCfPage[2:0] == 3'd4 ? debugCfPage4 :
    debugCfPage[2:0] == 3'd5 ? debugCfPage5 :
                                debugCfPage0;
  wire        debugOki0CaptureEnable = debugOki0BusyStartCapture | debugCfPending;
`else
  wire        debugOki0CaptureEnable = 1'b0;
`endif

  wire [7:0] cpuDin =
    pwrinst2Oki0Access & cpuRd ? oki0CpuDout :
    pwrinst2Oki1Access & cpuRd ? oki1CpuDout :
    ym2203Read ? ym2203CpuDout :
    latchHighRead ? dataReg[15:8] :
    latchLowRead ? dataReg[7:0] :
    z80RamSelect & cpuMreq & cpuRd ? soundRamDout :
    romOrBankDout;

  always @(posedge clock) begin
    if (reset) begin
      reqReg <= 1'b0;
      latchHighReadSeen <= 1'b0;
      latchLowReadSeen <= 1'b0;
      dataReg <= 16'h0000;
      z80BankReg <= 3'h0;
      okiBankHiReg <= 4'h0;
      okiBankLoReg <= 4'h0;
      z80IoWrD <= 1'b0;
      z80IoWrAddrD <= 8'h00;
      z80IoWrDataD <= 8'h00;
      replyReadPtr <= 5'd0;
      replyWritePtr <= 5'd0;
      replyCount <= 6'd0;
      for (replyResetIndex = 0;
           replyResetIndex < 32;
           replyResetIndex = replyResetIndex + 1)
        replyFifo[replyResetIndex] <= 8'd0;
`ifdef CAVE_ENABLE_DEBUG_OVERLAY
      debugLastSoundCommand <= 8'h0;
      debugOki0PhraseCommand <= 8'h0;
      debugOki0StartCommand <= 8'h0;
      debugOki0StatusRead <= 8'h0;
      debugOki0StartChannels <= 8'h0;
      debugOki0BusyOverlap <= 8'h0;
      debugOki1StatusRead <= 8'h0;
      debugOki0RawPage <= 8'h0;
      debugOki0MappedPage <= 8'h0;
      debugOki0NmkPage <= 8'h0;
      debugOki0ReadPhase <= 8'h0;
      debugLastNmkWrite <= 8'h0;
      debugLastYmReg <= 8'h0;
      debugLastYmData <= 8'h0;
      debugYmFlags <= 8'h0;
      debugYmWriteCount <= 8'h0;
      debugYmPsgPeak <= 8'h0;
      debugYmFmPeak <= 8'h0;
      debugOki0Pending <= 1'b0;
      debugCfPending <= 1'b0;
      debugCfCaptured <= 1'b0;
      debugCfPendingAge <= 2'b00;
      debugCfPageCounter <= 29'd0;
      debugCfPhraseCommand <= 8'h00;
      debugCfStartCommand <= 8'h00;
      debugCfStatusAtStart <= 8'h00;
      debugCfOverlap <= 8'h00;
      debugCfRawPage <= 8'h00;
      debugCfMappedPage <= 8'h00;
      debugCfNmkPage <= 8'h00;
      debugCfReadPhase <= 8'h00;
      debugCfLastNmkWrite <= 8'h00;
      debugCfLatchStatus <= 8'h00;
      debugCfCtrlBytes <= 48'h000000000000;
      debugCfDecodeBytes <= 48'h000000000000;
      debugCfTableBytes <= 48'h000000000000;
      debugCfBodyBytes <= 48'h000000000000;
      debugCfPageSelect <= 3'd0;
      debugOki0Pair0 <= 32'h00000000;
      debugOki0Pair1 <= 32'h00000000;
      debugOki0Pair2 <= 32'h00000000;
      debugOki0Pair3 <= 32'h00000000;
      debugCfPair0 <= 32'h00000000;
      debugCfPair1 <= 32'h00000000;
      debugCfPair2 <= 32'h00000000;
      debugCfPair3 <= 32'h00000000;
      debugCfZ80Flags <= 8'h00;
      debugCfZ80IoAddr <= 8'h00;
      debugCfZ80IoData <= 8'h00;
      debugCfReqStatus <= 8'h00;
      debugCfDataHigh <= 8'h00;
      debugCfDataLow <= 8'h00;
`endif
    end
    else if (pwrinst2MailboxRestoreWr) begin
      case (pwrinst2MailboxRestoreAddr)
        32'd0: dataReg <= pwrinst2MailboxRestoreData;
        32'd1: begin
          reqReg <= pwrinst2MailboxRestoreData[0];
          latchHighReadSeen <= pwrinst2MailboxRestoreData[1];
          latchLowReadSeen <= pwrinst2MailboxRestoreData[2];
          z80BankReg <= pwrinst2MailboxRestoreData[5:3];
          z80IoWrD <= pwrinst2MailboxRestoreData[6];
          z80IoWrAddrD <= pwrinst2MailboxRestoreData[14:7];
        end
        32'd2:
          z80IoWrDataD <= pwrinst2MailboxRestoreData[7:0];
        32'd3: begin
          replyReadPtr <= pwrinst2MailboxRestoreData[4:0];
          replyWritePtr <= pwrinst2MailboxRestoreData[9:5];
          replyCount <= pwrinst2MailboxRestoreData[15:10];
        end
        default: begin
          if (pwrinst2MailboxRestoreAddr >= 32'd4 &&
              pwrinst2MailboxRestoreAddr < 32'd20) begin
            replyFifo[
              (pwrinst2MailboxRestoreAddr - 32'd4) << 1
            ] <= pwrinst2MailboxRestoreData[7:0];
            replyFifo[
              ((pwrinst2MailboxRestoreAddr - 32'd4) << 1) + 1
            ] <= pwrinst2MailboxRestoreData[15:8];
          end
        end
      endcase
    end
    else if (!io_ss_hold) begin
      z80IoWrD <= z80IoWr & z80IoWrReady;
      if (z80IoWr & z80IoWrReady) begin
        z80IoWrAddrD <= cpuIoAddr[7:0];
        z80IoWrDataD <= cpuDout;
      end

      reqReg <= io_ctrl_req | (reqReg & ~(latchHighRead | latchLowRead));
      latchHighReadSeen <= latchHighReadSeenNext;
      latchLowReadSeen <= latchLowReadSeenNext;

      if (io_ctrl_req)
        dataReg <= io_ctrl_data;

      if (z80BankWrite)
        z80BankReg <= cpuDout[2:0];

      if (~pwrinst2Z80Sound & io_ctrl_nmk_wr) begin
        okiBankHiReg <= io_ctrl_nmk_din[7:4];
        okiBankLoReg <= io_ctrl_nmk_din[3:0];
      end

      if (replyPush) begin
        replyFifo[replyWritePtr] <= cpuDout;
        replyWritePtr <= replyWritePtr + 5'd1;
      end

      if (replyPop)
        replyReadPtr <= replyReadPtr + 5'd1;

      case ({replyPush, replyPop})
        2'b10: replyCount <= replyCount + 6'd1;
        2'b01: replyCount <= replyCount - 6'd1;
        default: begin
        end
      endcase

`ifdef CAVE_ENABLE_DEBUG_OVERLAY
      if (io_ctrl_req)
        debugLastSoundCommand <= io_ctrl_data[7:0];
      else if (io_ctrl_ymz_wr)
        debugLastSoundCommand <= io_ctrl_ymz_din[7:0];
      else if (io_ctrl_oki_1_wr)
        debugLastSoundCommand <= io_ctrl_oki_1_din[7:0];
      else if (io_ctrl_oki_0_wr)
        debugLastSoundCommand <= io_ctrl_oki_0_din[7:0];

      if (pwrinst2NmkWrite)
        debugLastNmkWrite <= cpuDout;
      else if (~pwrinst2Z80Sound & io_ctrl_nmk_wr)
        debugLastNmkWrite <= io_ctrl_nmk_din[7:0];

      if (pwrinst2Oki0Access & cpuRd)
        debugOki0StatusRead <= oki0CpuDout;

      if (pwrinst2Oki1Access & cpuRd)
        debugOki1StatusRead <= oki1CpuDout;

      debugYmFlags[0] <= pwrinst2Z80Sound;
      debugYmFlags[1] <= reqReg;
      debugYmFlags[2] <= z80WaitN;
      if (ym2203QueueFull)
        debugYmFlags[3] <= 1'b1;

      if (ym2203Write) begin
        debugYmFlags[4] <= 1'b1;
        debugYmWriteCount <= debugYmWriteCount + 8'd1;
        if (cpuAddr[0])
          debugLastYmData <= cpuDout;
        else
          debugLastYmReg <= cpuDout;
      end

      if (ym2203AudioValid) begin
        debugYmFlags[5] <= 1'b1;
        if (ym2203PsgMagnitude > debugYmPsgPeak)
          debugYmPsgPeak <= ym2203PsgMagnitude;
        if (ym2203FmMagnitude > debugYmFmPeak)
          debugYmFmPeak <= ym2203FmMagnitude;
        if (ym2203PsgMagnitude != 8'h00)
          debugYmFlags[6] <= 1'b1;
        if (ym2203FmMagnitude != 8'h00)
          debugYmFlags[7] <= 1'b1;
      end

      if (oki0CpuWr) begin
        if (debugOki0Pending) begin
          debugOki0Pair3 <= debugOki0Pair2;
          debugOki0Pair2 <= debugOki0Pair1;
          debugOki0Pair1 <= debugOki0Pair0;
          debugOki0Pair0 <= debugOki0CurrentPair;
          debugOki0StartCommand <= oki0CpuDin;
          debugOki0StartChannels <= {4'h0, oki0CpuDin[7:4]};
          debugOki0BusyOverlap <= {4'h0, debugOki0CurrentBusyOverlap};
          debugOki0Pending <= 1'b0;
        end
        else if (oki0CpuDin[7]) begin
          debugOki0PhraseCommand <= oki0CpuDin;
          debugOki0Pending <= 1'b1;
        end
        else begin
          debugOki0Pending <= 1'b0;
        end
      end

      if (debugOki0BusyStartCapture) begin
        debugCfPending <= 1'b1;
        debugCfCaptured <= 1'b0;
        debugCfPendingAge <= 2'b00;
        debugCfPageCounter <= 29'd0;
        debugCfPhraseCommand <= debugOki0PhraseCommand;
        debugCfStartCommand <= oki0CpuDin;
        debugCfStatusAtStart <= oki0CpuDout;
        debugCfOverlap <= {4'hA, debugOki0CurrentBusyOverlap};
        debugCfRawPage <= debugOki0RawPage;
        debugCfMappedPage <= debugOki0MappedPage;
        debugCfNmkPage <= debugOki0NmkPage;
        debugCfReadPhase <= debugOki0ReadPhase;
        debugCfLastNmkWrite <= debugLastNmkWrite;
        debugCfLatchStatus <= debugLatchStatus;
        debugCfCtrlBytes <= 48'h000000000000;
        debugCfDecodeBytes <= 48'h000000000000;
        debugCfTableBytes <= 48'h000000000000;
        debugCfBodyBytes <= 48'h000000000000;
        debugCfPageSelect <= 3'd0;
        debugCfPair0 <= debugOki0CurrentPair;
        debugCfPair1 <= debugOki0Pair0;
        debugCfPair2 <= debugOki0Pair1;
        debugCfPair3 <= debugOki0Pair2;
        debugCfZ80Flags <= debugZ80Flags;
        debugCfZ80IoAddr <= z80IoWrAddrD;
        debugCfZ80IoData <= z80IoWrDataD;
        debugCfReqStatus <= debugReqStatus;
        debugCfDataHigh <= dataReg[15:8];
        debugCfDataLow <= dataReg[7:0];
      end
      else if (debugCfPending) begin
        if (debugCfPendingAge != 2'b11)
          debugCfPendingAge <= debugCfPendingAge + 2'b01;

        if ((debugCfPendingAge != 2'b00) & oki0DebugBodyDone) begin
          debugCfPending <= 1'b0;
          debugCfCaptured <= 1'b1;
          debugCfRawPage <= debugOki0RawPage;
          debugCfMappedPage <= debugOki0MappedPage;
          debugCfNmkPage <= debugOki0NmkPage;
          debugCfReadPhase <= debugOki0ReadPhase;
          debugCfLastNmkWrite <= debugLastNmkWrite;
          debugCfLatchStatus <= debugLatchStatus;
          debugCfCtrlBytes <= oki0DebugCtrlBytes;
          debugCfDecodeBytes <= oki0DebugDecodeBytes;
          debugCfTableBytes <= oki0DebugTableBytes;
          debugCfBodyBytes <= oki0DebugBodyBytes;
        end
      end
      else if (debugCfCaptured) begin
        debugCfPageCounter <= debugCfPageCounter + 29'd1;
        if (debugCfPageCounter[26:0] == 27'h7ffffff)
          debugCfPageSelect <= (debugCfPageSelect == 3'd5) ? 3'd0 : debugCfPageSelect + 3'd1;
      end

      if (oki0RomRead) begin
        debugOki0RawPage <= {4'hA, oki0RomAddr[17:14]};
        debugOki0MappedPage <= {4'hB, oki0MappedAddr[21:18]};
        debugOki0NmkPage <= {4'hC, nmkOki0AddrOut[21:18]};
        debugOki0ReadPhase <= {4'hD, pwrinst2Oki0TableRead, pwrinst2Oki0BodyRead, oki0RomAddr[17:16]};
      end

`endif
    end

    if (reset)
      ymzAudioReg <= 16'd0;
    else if (io_ss_hold && io_ss_restore_enable &&
             soundDeviceIsYmz && ymzSsIdle)
      // At the canonical idle point the held sample is the clamped YMZ
      // accumulator, so it can be reconstructed without another state word.
      ymzAudioReg <= ymzAudio;
    else if (ymzAudioValid)
      ymzAudioReg <= ymzAudio;

    if (reset) begin
      ym2203PsgAudioReg <= 16'd0;
      ym2203FmAudioReg <= 16'd0;
      oki0AudioReg <= 14'd0;
      oki1AudioReg <= 14'd0;
    end else begin
      if (soundStateRestoreWr &&
          (soundStateRestoreAddr == 32'd10)) begin
        ym2203PsgAudioReg <= soundStateRestoreData;
      end else if (ym2203AudioValid) begin
        ym2203PsgAudioReg <= ym2203PsgAudio;
      end

      if (soundStateRestoreWr &&
          (soundStateRestoreAddr == 32'd11)) begin
        ym2203FmAudioReg <= soundStateRestoreData;
      end else if (ym2203AudioValid) begin
        ym2203FmAudioReg <= ym2203FmAudio;
      end

      if (soundStateRestoreWr &&
          (soundStateRestoreAddr == 32'd8))
        oki0AudioReg <= soundStateRestoreData[13:0];
      else if (activeOki0AudioValid)
        oki0AudioReg <= activeOki0Audio;

      if (soundStateRestoreWr &&
          (soundStateRestoreAddr == 32'd9))
        oki1AudioReg <= soundStateRestoreData[13:0];
      else if (activeOki1AudioValid)
        oki1AudioReg <= activeOki1Audio;
    end
  end

  CaveSoundZ80Cpu #(
    .SS_IDX(8'd32)
  ) cpu (
    .clock                         (clock),
    .reset                         (reset | ~pwrinst2Z80Sound),
    .io_ss_hold                    (io_ss_hold & pwrinst2Z80Sound),
    .io_ss_capture_request         (
      io_ss_capture_request & pwrinst2Z80Sound
    ),
    .io_ss_restore_enable          (
      io_ss_restore_enable & pwrinst2Z80Sound
    ),
    .io_ss_restore_start           (
      io_ss_restore_start & pwrinst2Z80Sound
    ),
    .io_ss_restore_commit          (
      io_ss_restore_commit & pwrinst2Z80Sound
    ),
    .io_ss_release                 (io_ss_release & pwrinst2Z80Sound),
    .io_ss_capture_done            (pwrinst2Z80SsCaptureDone),
    .io_ss_cpu_idle                (pwrinst2Z80SsCpuIdle),
    .io_ss_restore_commit_done     (
      pwrinst2Z80SsRestoreCommitDone
    ),
    .io_ss_reconstruction_ready    (
      pwrinst2Z80SsReconstructionReady
    ),
    .io_addr                       (cpuAddr),
    .io_din                        (cpuDin),
    .io_dout                       (cpuDout),
    .io_rd                         (cpuRd),
    .io_wr                         (cpuWr),
    .io_rfsh                       (cpuRfsh),
    .io_mreq                       (cpuMreq),
    .io_iorq                       (cpuIorq),
    .io_fast_clock                 (1'b1),
    .io_wait_n                     (z80WaitN),
    .io_int                        (cpuInt),
    .io_nmi                        (reqReg),
    .ssbus                         (soundSaveStateOwners[4])
  );

  CaveSaveStateSinglePortRam #(
    .ADDR_WIDTH  (13),
    .DATA_WIDTH  (8),
    .DEPTH       (0),
    .MASK_ENABLE (0),
    .SS_IDX      (8'd33),
    .STREAM_WIDTH(2'd0)
  ) soundRam (
    .clock          (clock),
    .reset          (reset | ~pwrinst2Z80Sound),
    .state_enable   (pwrinst2SoundStateEnable),
    .restore_enable (io_ss_restore_enable & pwrinst2Z80Sound),
    .rd             (soundRamRd),
    .wr             (soundRamWr),
    .addr           (cpuAddr[12:0]),
    .mask           (1'b0),
    .din            (cpuDout),
    .dout           (soundRamDout),
    .blocked_access (),
    .ssbus          (soundSaveStateOwners[5])
  );

  NMK112 nmk (
    .clock           (clock),
    .reset           (reset),
    .io_page_table_0 (pwrinst2Z80Sound),
    .io_page_six_bit (pwrinst2Z80Sound),
    .io_cpu_wr       (nmkWr & ~io_ss_hold),
    .io_cpu_addr     (nmkAddr),
    .io_cpu_din      (nmkDin),
    .io_ss_wr        (nmkSsWr),
    .io_ss_addr      (soundStateRestoreAddr[2:0]),
    .io_ss_din       (soundStateRestoreData[5:0]),
    .io_ss_state     (nmkSsState),
    .io_addr_0_in    ({7'h00, activeOki0RomAddr}),
    .io_addr_0_out   (nmkOki0AddrOut),
    .io_addr_1_in    ({7'h00, activeOki1RomAddr}),
    .io_addr_1_out   (nmkOki1AddrOut)
  );

  CavePwrInst2OkiRomCache pwrinst2_oki_0_rom_cache (
    .clock           (clock),
    .reset           (reset | ~pwrinst2Z80Sound | io_ss_hold),
    .io_client_rd    (oki0RomRead),
    .io_client_addr  (oki0MappedAddr),
    .io_client_dout  (pwrinst2Oki0CacheDout),
    .io_client_valid (pwrinst2Oki0CacheValid),
    .io_mem_rd       (pwrinst2Oki0MemRead),
    .io_mem_addr     (pwrinst2Oki0MemAddr),
    .io_mem_dout     (io_rom_1_dout),
    .io_mem_valid    (io_rom_1_valid),
    .io_idle         (pwrinst2Oki0RomCacheIdle)
  );

  CavePwrInst2OkiRomCache pwrinst2_oki_1_rom_cache (
    .clock           (clock),
    .reset           (reset | ~pwrinst2Z80Sound | io_ss_hold),
    .io_client_rd    (oki1RomRead),
    .io_client_addr  (oki1MappedAddr),
    .io_client_dout  (pwrinst2Oki1CacheDout),
    .io_client_valid (pwrinst2Oki1CacheValid),
    .io_mem_rd       (pwrinst2Oki1MemRead),
    .io_mem_addr     (pwrinst2Oki1MemAddr),
    .io_mem_dout     (io_rom_2_dout),
    .io_mem_valid    (io_rom_2_valid),
    .io_idle         (pwrinst2Oki1RomCacheIdle)
  );

  CavePwrInst2OKIM6295 #(
    .SS_IDX(8'd36),
    .FIR_COEFFS("jt6295_up4_soft.hex"),
    .FIXED_SAMPLE_CLOCK(1)
  ) oki_0 (
    .clock             (clock),
    .reset             (reset | ~pwrinst2Z80Sound),
    .io_cen_step       (oki0CenStep),
    .io_ss             (okiPin7Ss),
    .io_cpu_wr         (oki0CpuWr),
    .io_cpu_din        (oki0CpuDin),
    .io_stretch_cpu_wr (1'b0),
    .io_wait_for_rom   (pwrinst2Z80Sound),
    .io_ignore_busy_start (pwrinst2Oki0IgnoreBusyStart),
    .io_duplicate_busy_start_filter (pwrinst2Oki0DuplicateBusyStartFilter),
    .io_restart_busy_start (1'b0),
    .io_restart_mute_busy_start (1'b0),
    .io_reset_adpcm_on_start (1'b0),
    .io_status_includes_start (1'b1),
    .io_debug_capture_enable (debugOki0CaptureEnable),
    .io_align_ctrl_ok  (pwrinst2Z80Sound),
    .io_cpu_dout       (oki0CpuDout),
    .io_rom_rd         (oki0RomRead),
    .io_rom_addr       (oki0RomAddr),
    .io_rom_cache_addr (oki0MappedAddr),
    .io_rom_dout       (oki0RomData),
    .io_rom_valid      (oki0RomDataValid),
    .io_audio_valid    (oki0AudioValid),
    .io_audio_bits     (oki0Audio),
    .io_debug_ctrl_bytes (oki0DebugCtrlBytes),
    .io_debug_decode_bytes (oki0DebugDecodeBytes),
    .io_debug_table_bytes (oki0DebugTableBytes),
    .io_debug_body_bytes (oki0DebugBodyBytes),
    .io_debug_body_done (oki0DebugBodyDone),
    .io_debug_busy_state (oki0DebugBusyState),
    .io_ss_hold         (io_ss_hold & pwrinst2Z80Sound),
    .io_ss_restore_enable(
      io_ss_restore_enable & pwrinst2Z80Sound
    ),
    .io_ss_idle         (pwrinst2Oki0SsIdle),
    .io_ssbus           (soundSaveStateOwners[8])
  );

  CavePwrInst2OKIM6295 #(
    .SS_IDX(8'd37),
    .FIR_COEFFS("jt6295_up4_soft.hex"),
    .FIXED_SAMPLE_CLOCK(1)
  ) oki_1 (
    .clock             (clock),
    .reset             (reset | ~pwrinst2Z80Sound),
    .io_cen_step       (oki1CenStep),
    .io_ss             (okiPin7Ss),
    .io_cpu_wr         (oki1CpuWr),
    .io_cpu_din        (oki1CpuDin),
    .io_stretch_cpu_wr (1'b0),
    .io_wait_for_rom   (pwrinst2Z80Sound),
    .io_ignore_busy_start (pwrinst2Z80Sound),
    .io_duplicate_busy_start_filter (1'b0),
    .io_restart_busy_start (1'b0),
    .io_restart_mute_busy_start (1'b0),
    .io_reset_adpcm_on_start (1'b0),
    .io_status_includes_start (1'b1),
    .io_debug_capture_enable (1'b0),
    .io_align_ctrl_ok  (pwrinst2Z80Sound),
    .io_cpu_dout       (oki1CpuDout),
    .io_rom_rd         (oki1RomRead),
    .io_rom_addr       (oki1RomAddr),
    .io_rom_cache_addr (oki1MappedAddr),
    .io_rom_dout       (oki1RomData),
    .io_rom_valid      (oki1RomDataValid),
    .io_audio_valid    (oki1AudioValid),
    .io_audio_bits     (oki1Audio),
    .io_debug_ctrl_bytes (oki1DebugCtrlBytes),
    .io_debug_decode_bytes (oki1DebugDecodeBytes),
    .io_debug_table_bytes (oki1DebugTableBytes),
    .io_debug_body_bytes (oki1DebugBodyBytes),
    .io_debug_body_done (oki1DebugBodyDone),
    .io_debug_busy_state (oki1DebugBusyState),
    .io_ss_hold         (io_ss_hold & pwrinst2Z80Sound),
    .io_ss_restore_enable(
      io_ss_restore_enable & pwrinst2Z80Sound
    ),
    .io_ss_idle         (pwrinst2Oki1SsIdle),
    .io_ssbus           (soundSaveStateOwners[9])
  );

  CaveDonPachiOKIM6295 #(
    .SS_IDX   (8'd36),
    .CEN_STEP (17'h0873)
  ) donpachi_oki_0 (
    .clock                (clock),
    .reset                (reset | ~donpachi),
    .io_ss                (1'b1),
    .io_cpu_wr            (donpachi & io_ctrl_oki_0_wr),
    .io_cpu_din           (io_ctrl_oki_0_din[7:0]),
    .io_cpu_dout          (donpachiOki0CpuDout),
    .io_rom_rd            (donpachiOki0RomRead),
    .io_rom_addr          (donpachiOki0RomAddr),
    .io_rom_dout          (oki0RomData),
    .io_rom_valid         (oki0RomDataValid),
    .io_audio_valid       (donpachiOki0AudioValid),
    .io_audio             (donpachiOki0Audio),
    .io_ss_hold           (io_ss_hold & donpachi),
    .io_ss_restore_enable (io_ss_restore_enable & donpachi),
    .io_ss_idle           (donpachiOki0SsIdle),
    .io_ssbus             (soundSaveStateOwners[1])
  );

  CaveDonPachiOKIM6295 #(
    .SS_IDX   (8'd37),
    .CEN_STEP (17'h10E5)
  ) donpachi_oki_1 (
    .clock                (clock),
    .reset                (reset | ~donpachi),
    .io_ss                (1'b1),
    .io_cpu_wr            (donpachi & io_ctrl_oki_1_wr),
    .io_cpu_din           (io_ctrl_oki_1_din[7:0]),
    .io_cpu_dout          (donpachiOki1CpuDout),
    .io_rom_rd            (donpachiOki1RomRead),
    .io_rom_addr          (donpachiOki1RomAddr),
    .io_rom_dout          (oki1RomData),
    .io_rom_valid         (oki1RomDataValid),
    .io_audio_valid       (donpachiOki1AudioValid),
    .io_audio             (donpachiOki1Audio),
    .io_ss_hold           (io_ss_hold & donpachi),
    .io_ss_restore_enable (io_ss_restore_enable & donpachi),
    .io_ss_idle           (donpachiOki1SsIdle),
    .io_ssbus             (soundSaveStateOwners[2])
  );

  YMZ280B ymz280b (
    .clock              (clock),
    .reset              (reset),
    .io_cpu_rd          (io_ctrl_ymz_rd),
    .io_cpu_wr          (io_ctrl_ymz_wr),
    .io_cpu_addr        (io_ctrl_ymz_addr[0]),
    .io_cpu_din         (io_ctrl_ymz_din[7:0]),
    .io_cpu_dout        (ymzCpuDout),
    .io_rom_rd          (ymzRomRd),
    .io_rom_addr        (ymzRomAddr),
    .io_rom_dout        (ymzRomDout),
    .io_rom_wait_n      (ymzRomWaitN),
    .io_rom_valid       (ymzRomValid),
    .io_audio_valid     (ymzAudioValid),
    .io_audio_bits_left (ymzAudio),
    .io_irq             (ymzIrq),
    .io_ss_hold         (io_ss_hold & soundDeviceIsYmz),
    .io_ss_restore_enable(io_ss_restore_enable & soundDeviceIsYmz),
    .io_ss_idle         (ymzSsIdle),
    .io_ssbus           (soundSaveStateOwners[0])
  );

  CaveSaveStateRegisterPort #(
    .WIDTH        (16),
    .COUNT        (12),
    .SS_IDX       (8'd38),
    .STREAM_WIDTH (2'd1)
  ) shared_sound_state (
    .clk            (clock),
    .reset          (reset),
    .state_enable   (sharedSoundStateEnable),
    .restore_enable (
      io_ss_restore_enable & (donpachi | pwrinst2Z80Sound)
    ),
    .capture_data   (sharedSoundState),
    .restore_wr     (soundStateRestoreWr),
    .restore_addr   (soundStateRestoreAddr),
    .restore_data   (soundStateRestoreData),
    .blocked_access (),
    .ssbus          (soundSaveStateOwners[3])
  );

  CaveSaveStateRegisterPort #(
    .WIDTH        (16),
    .COUNT        (20),
    .SS_IDX       (8'd34),
    .STREAM_WIDTH (2'd1)
  ) pwrinst2_mailbox_state (
    .clk            (clock),
    .reset          (reset | ~pwrinst2Z80Sound),
    .state_enable   (pwrinst2SoundStateEnable),
    .restore_enable (io_ss_restore_enable & pwrinst2Z80Sound),
    .capture_data   (pwrinst2MailboxState),
    .restore_wr     (pwrinst2MailboxRestoreWr),
    .restore_addr   (pwrinst2MailboxRestoreAddr),
    .restore_data   (pwrinst2MailboxRestoreData),
    .blocked_access (),
    .ssbus          (soundSaveStateOwners[6])
  );

  CaveSaveStateBusMux #(
    .COUNT (10)
  ) sound_save_state_bus (
    .clk    (clock),
    .owners (soundSaveStateOwners),
    .stream (io_ssbus)
  );

  CavePwrInst2YM2203 #(
    .SS_IDX(8'd35)
  ) ym2203 (
    .clock             (clock),
    .reset             (reset | ~pwrinst2Z80Sound),
    .io_cpu_wr         (ym2203Write),
    .io_cpu_addr       (cpuAddr[0]),
    .io_cpu_din        (cpuDout),
    .io_cpu_dout       (ym2203CpuDout),
    .io_cpu_wait_n     (ym2203CpuWaitN),
    .io_cpu_queue_full (ym2203QueueFull),
    .io_irq            (ym2203Irq),
    .io_audio_valid    (ym2203AudioValid),
    .io_audio_bits_psg (ym2203PsgAudio),
    .io_audio_bits_fm  (ym2203FmAudio),
    .io_ss_hold        (io_ss_hold & pwrinst2Z80Sound),
    .io_ss_restore_enable(
      io_ss_restore_enable & pwrinst2Z80Sound
    ),
    .io_ss_idle        (ym2203SsIdle),
    .io_ssbus          (soundSaveStateOwners[7])
  );

  CaveSoundRomReadArbiter arbiter (
    .clock          (clock),
    .reset          (reset),
    .io_in_0_rd     (soundDeviceIsOki & ~pwrinst2Z80Sound & activeOki0RomRead),
    .io_in_0_addr   (oki0MappedAddr),
    .io_in_0_dout   (oki0RomDout),
    .io_in_0_valid  (oki0RomValid),
    .io_in_1_rd     (soundDeviceIsYmz & ymzRomRd),
    .io_in_1_addr   ({1'b0, ymzRomAddr}),
    .io_in_1_dout   (ymzRomDout),
    .io_in_1_wait_n (ymzRomWaitN),
    .io_in_1_valid  (ymzRomValid),
    .io_in_2_rd     (z80ProgRomArbiterRead),
    .io_in_2_addr   ({9'h000, cpuAddr}),
    .io_in_2_dout   (progRomDout),
    .io_in_2_valid  (progRomValid),
    .io_in_3_rd     (z80BankRomArbiterRead),
    .io_in_3_addr   ({8'h00, z80BankReg, cpuAddr[13:0]}),
    .io_in_3_dout   (bankRomDout),
    .io_in_3_valid  (bankRomValid),
    .io_out_rd      (io_rom_0_rd),
    .io_out_addr    (io_rom_0_addr),
    .io_out_dout    (io_rom_0_dout),
    .io_out_wait_n  (io_rom_0_wait_n),
    .io_out_valid   (io_rom_0_valid)
  );

  AudioMixer io_audio_mixer (
    .clock       (clock),
    .io_pwrinst2 (pwrinst2Z80Sound),
    .io_ymz      (soundDeviceIsYmz),
    .io_legacy_oki (soundDeviceIsOki),
    .io_pwrinst2_oki0_level (io_options_pwrinst2_oki0_level),
    .io_pwrinst2_oki1_level (io_options_pwrinst2_oki1_level),
    .io_pwrinst2_headroom (io_options_pwrinst2_headroom),
    .io_pwrinst2_psg_level (io_options_pwrinst2_psg_level),
    .io_pwrinst2_fm_level  (io_options_pwrinst2_fm_level),
    .io_ymz_level           (io_options_ymz_level),
    .io_in_4     (oki1Mix),
    .io_in_3     (oki0Mix),
    .io_in_2     (pwrinst2Z80Sound ? ym2203FmMix : 16'h0000),
    .io_in_1     (pwrinst2Z80Sound ? ym2203PsgMix : 16'h0000),
    .io_in_0     (soundDeviceIsYmz ? ymzAudioReg : 16'h0000),
    .io_out      (io_audio)
  );

  assign cpuInt = pwrinst2Z80Sound & ym2203Irq;
  assign io_ctrl_irq = soundDeviceIsYmz & ymzIrq;
  assign io_ctrl_oki_0_dout = {8'h00, activeOki0CpuDout};
  assign io_ctrl_oki_1_dout = {8'h00, activeOki1CpuDout};
  assign io_ctrl_ymz_dout = {8'h00, ymzCpuDout};
  assign io_ctrl_reply = (replyCount == 6'd0) ? 16'h00ff : {8'h00, replyFifo[replyReadPtr]};
  assign io_ctrl_reply_empty = replyCount == 6'd0;
  assign io_ss_capture_done =
    pwrinst2Z80Sound ? pwrinst2Z80SsCaptureDone : 1'b1;
  assign io_ss_cpu_idle =
    pwrinst2Z80Sound ? pwrinst2Z80SsCpuIdle : 1'b1;
  assign io_ss_restore_commit_done =
    pwrinst2Z80Sound ? pwrinst2Z80SsRestoreCommitDone : 1'b1;
  assign io_ss_reconstruction_ready =
    pwrinst2Z80Sound ? pwrinst2Z80SsReconstructionReady : 1'b1;
  assign io_ss_idle =
    soundDeviceIsYmz ? ymzSsIdle :
    donpachi ? (donpachiOki0SsIdle & donpachiOki1SsIdle) :
    pwrinst2Z80Sound ? pwrinst2SoundDevicesIdle :
    1'b1;

`ifdef CAVE_ENABLE_DEBUG_OVERLAY
  // Power Instinct 2 OKI0 one-shot capture:
  // MK=F0. Once the first busy-overlap start is seen, PH cycles pages:
  // 00 command/status, 01 decoded start/stop bytes,
  // 02 consumed phrase-table bytes, 03 first body bytes,
  // 04 Z80/latch/YM context, 05 raw/mapped/NMK/read-phase plus context.
  assign io_debug = debugCfWord;
`else
  assign io_debug = 64'd0;
`endif

  assign io_rom_1_rd = pwrinst2Z80Sound ? pwrinst2Oki0MemRead : activeOki1RomRead;
  assign io_rom_1_addr = pwrinst2Z80Sound ? pwrinst2Oki0MemAddr : oki1MappedAddr;
  assign io_rom_2_rd = pwrinst2Z80Sound & pwrinst2Oki1MemRead;
  assign io_rom_2_addr = pwrinst2Oki1MemAddr;
endmodule
