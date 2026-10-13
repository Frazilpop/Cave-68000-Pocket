// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).
//
// Cave 68000 for Analogue Pocket: the pixel's position is carried as a
// running sum (accX, accY below) instead of multiplied out every pixel: the
// span times the zoom, added to the start, was one 96 MHz cycle from the
// column counter to posReg_x and the tag RAM's read address, and missed it
// by half a nanosecond on the Pocket's part. The far edge's product comes
// from SpriteProcessor with the sprite (io_config_bits_sprite_far_*). The
// overdraw test compares both candidate tags before choosing between them.

module SpriteBlitter(
  input         clock,
  input         reset,
  input         io_enable,
  input         io_frameStart,
  output        io_busy,
  output        io_config_ready,
  input         io_config_valid,
  input  [1:0]  io_config_bits_sprite_priority,
  input  [5:0]  io_config_bits_sprite_colorCode,
  input         io_config_bits_sprite_hFlip,
  input         io_config_bits_sprite_vFlip,
  input  [17:0] io_config_bits_sprite_pos_x,
  input  [17:0] io_config_bits_sprite_pos_y,
  input  [7:0]  io_config_bits_sprite_cols,
  input  [7:0]  io_config_bits_sprite_rows,
  input  [15:0] io_config_bits_sprite_zoom_x,
  input  [15:0] io_config_bits_sprite_zoom_y,
  input  [27:0] io_config_bits_sprite_far_x,      // (cols * 16 - 1) * zoom_x
  input  [27:0] io_config_bits_sprite_far_y,      // (rows * 16 - 1) * zoom_y
  input         io_config_bits_hFlip,
  input  [8:0]  io_video_regs_size_x,
  input  [8:0]  io_video_regs_size_y,
  output        io_pixelData_ready,
  input         io_pixelData_valid,
  input  [7:0]  io_pixelData_bits_0,
  input  [7:0]  io_pixelData_bits_1,
  input  [7:0]  io_pixelData_bits_2,
  input  [7:0]  io_pixelData_bits_3,
  input  [7:0]  io_pixelData_bits_4,
  input  [7:0]  io_pixelData_bits_5,
  input  [7:0]  io_pixelData_bits_6,
  input  [7:0]  io_pixelData_bits_7,
  input  [7:0]  io_pixelData_bits_8,
  input  [7:0]  io_pixelData_bits_9,
  input  [7:0]  io_pixelData_bits_10,
  input  [7:0]  io_pixelData_bits_11,
  input  [7:0]  io_pixelData_bits_12,
  input  [7:0]  io_pixelData_bits_13,
  input  [7:0]  io_pixelData_bits_14,
  input  [7:0]  io_pixelData_bits_15,
  output        io_frameBuffer_wr,
  output [16:0] io_frameBuffer_addr,
  output [15:0] io_frameBuffer_din,
  input         io_frameBuffer_wait_n
);
  wire       pisoRead;
  wire       pisoWrite;
  wire       pisoEmpty;
  wire       pisoAlmostEmpty;
  wire [7:0] pisoPixel;

  reg         busyReg;
  reg  [1:0]  configReg_sprite_priority;
  reg  [5:0]  configReg_sprite_colorCode;
  reg         configReg_sprite_hFlip;
  reg         configReg_sprite_vFlip;
  reg  [17:0] configReg_sprite_pos_x;
  reg  [17:0] configReg_sprite_pos_y;
  reg  [7:0]  configReg_sprite_cols;
  reg  [7:0]  configReg_sprite_rows;
  reg  [15:0] configReg_sprite_zoom_x;
  reg  [15:0] configReg_sprite_zoom_y;
  reg         configReg_hFlip;

  reg  [11:0] x;
  reg  [11:0] y;
  reg  [19:0] posReg_x;
  reg  [19:0] posReg_y;
  reg  [1:0]  penReg_priority;
  reg  [5:0]  penReg_palette;
  reg  [7:0]  penReg_color;
  reg         validReg;

  reg  [1:0]  frameBufferWriteCount;
  reg  [16:0] frameBufferWriteAddr0;
  reg  [16:0] frameBufferWriteAddr1;
  reg  [15:0] frameBufferWriteDin0;
  reg  [15:0] frameBufferWriteDin1;

  wire frameBufferInputReady = frameBufferWriteCount != 2'd2;
  wire blitAdvance = busyReg & ~pisoEmpty & frameBufferInputReady;
  wire xAtEnd =
    x == 12'({configReg_sprite_cols, 4'h0} - 12'h1) | configReg_sprite_cols == 8'h0;
  wire xWrap = blitAdvance & xAtEnd;
  wire yAtEnd =
    y == 12'({configReg_sprite_rows, 4'h0} - 12'h1) | configReg_sprite_rows == 8'h0;
  wire blitDone = xWrap & yAtEnd;
  wire configReady = (~busyReg | blitDone) & ~tagClearing;
  wire latchConfig = configReady & io_config_valid;

  // The position is the sprite's start (SpriteProcessor: whole pixels, as
  // MAME's sprite013 places it), and the k-th pixel from the start lands at
  // start + k * zoom / 256 - counted from the far edge of the source when
  // the sprite is flipped, as the 013 draws it. That is pos + span * zoom,
  // span = x (or cols * 16 - 1 - x flipped); x moves one at a time, so the
  // sum is kept as it goes: accX is always pos + span(x) * zoom, modulo
  // 2^28, starting each row at startX (pos, or pos + the far edge flipped)
  // and stepping by the zoom, down when flipped. The same for y.
  reg  [27:0] accX, accY;
  reg  [27:0] startX, startY;
  wire [27:0] newStartX =
    28'({{10{io_config_bits_sprite_pos_x[17]}}, io_config_bits_sprite_pos_x}
        + (io_config_bits_sprite_hFlip ? io_config_bits_sprite_far_x : 28'h0));
  wire [27:0] newStartY =
    28'({{10{io_config_bits_sprite_pos_y[17]}}, io_config_bits_sprite_pos_y}
        + (io_config_bits_sprite_vFlip ? io_config_bits_sprite_far_y : 28'h0));
  wire [27:0] stepX = configReg_sprite_hFlip ? 28'(28'h0 - {12'h0, configReg_sprite_zoom_x})
                                             : {12'h0, configReg_sprite_zoom_x};
  wire [27:0] stepY = configReg_sprite_vFlip ? 28'(28'h0 - {12'h0, configReg_sprite_zoom_y})
                                             : {12'h0, configReg_sprite_zoom_y};
  wire [27:0] adjustedX = accX;
  wire [27:0] adjustedY = accY;

  wire pixelDataReady = frameBufferInputReady & (pisoEmpty | pisoAlmostEmpty);
  wire [19:0] maxVisibleX = {11'h0, 9'(io_video_regs_size_x - 9'h1)};
  wire [19:0] maxVisibleY = {11'h0, 9'(io_video_regs_size_y - 9'h1)};
  // Shrunk, several source pixels land on one screen pixel, and the 013
  // keeps the last one it draws: it draws a flipped sprite from the far
  // edge of the source. The source comes here from the near edge, so on a
  // flipped axis the first opaque pixel at a spot is the one to keep. Each
  // screen column remembers the source row that last wrote it (rows are
  // numbered through the frame, from 1, and the tags are cleared at its
  // start); a run is the rows of one sprite that land on one screen row.
  // A pixel is skipped where its own row wrote already (flipped across) or
  // an earlier row of its run did (flipped down).
  reg  [18:0] rowTags [0:511];
  reg  [18:0] rowTagOut;
  reg  [9:0]  tagClearAddr;
  wire        tagClearing = ~tagClearAddr[9];
  reg  [18:0] rowSeq;           // the row x and y are on
  reg  [18:0] rowSeqP;          // the row of the pixel in posReg
  reg  [18:0] runStartReg;      // the first row of the run before it
  reg  [19:0] prevRowY;         // where the row before it landed
  reg         rowFirstP;        // the pixel in posReg is its row's first
  reg         spriteFirstP;     // ... and that row its sprite's first
  reg         newSprite;
  reg         hFlipP;
  reg         vFlipP;
  reg  [8:0]  lastTagAddr;
  reg  [18:0] lastTagData;
  reg         lastTagValid;
  // (a row that starts a run has no earlier row in it: the comparisons with
  // the run's start run beside the test for a new one)
  wire        newRunP = rowFirstP & (spriteFirstP | posReg_y != prevRowY);
  wire [18:0] runStartP = newRunP ? rowSeqP : runStartReg;
  // The pixel's tag is the last one written if it was written to this very
  // column, else the tag RAM's; both are held against the rows beside the
  // choice rather than after it (the 96 MHz path is shorter that way, on the
  // Pocket's part).
  wire        tagBypass = lastTagValid & lastTagAddr == posReg_x[8:0];
  wire        ovLast =
    (hFlipP & lastTagData == rowSeqP)
    | (vFlipP & ~newRunP & lastTagData >= runStartReg & lastTagData < rowSeqP);
  wire        ovRam =
    (hFlipP & rowTagOut == rowSeqP)
    | (vFlipP & ~newRunP & rowTagOut >= runStartReg & rowTagOut < rowSeqP);
  wire overdrawn = tagBypass ? ovLast : ovRam;
  wire pixelVisible =
    posReg_x <= maxVisibleX
    & posReg_y <= maxVisibleY
    & validReg
    & (|penReg_color)
    & ~overdrawn;

  wire [16:0] normalFrameBufferAddr = 17'({posReg_y[7:0], 9'h0} + posReg_x[16:0]);
  wire [16:0] flippedFrameBufferAddr =
    17'({8'(8'(io_video_regs_size_y[7:0] - posReg_y[7:0]) - 8'h1), 9'h0}
        + 17'(17'({8'h0, io_video_regs_size_x} - posReg_x[16:0]) - 17'h1));
  wire [16:0] frameBufferInputAddr =
    configReg_hFlip ? flippedFrameBufferAddr : normalFrameBufferAddr;
  wire [15:0] frameBufferInputDin = {penReg_priority, penReg_palette, penReg_color};
  wire        frameBufferInputValid = io_enable & pixelVisible;
  wire        frameBufferInputFire = frameBufferInputValid & frameBufferInputReady;
  wire        frameBufferOutputValid = frameBufferWriteCount != 2'd0;
  wire        frameBufferOutputFire = frameBufferOutputValid & io_frameBuffer_wait_n;

  always @(posedge clock) begin
    if (reset) begin
      busyReg <= 1'b0;
      x <= 12'h0;
      y <= 12'h0;
      validReg <= 1'b0;
    end
    else begin
      busyReg <= latchConfig | ~blitDone & busyReg;
      if (blitAdvance)
        x <= xAtEnd ? 12'h0 : 12'(x + 12'h1);
      if (xWrap)
        y <= yAtEnd ? 12'h0 : 12'(y + 12'h1);
    end

    // the running sums, in step with x and y (a new sprite starts at 0, 0:
    // it is taken only when the last one has wrapped both)
    if (latchConfig) begin
      startX <= newStartX;
      startY <= newStartY;
      accX   <= newStartX;
      accY   <= newStartY;
    end
    else begin
      if (blitAdvance)
        accX <= xAtEnd ? startX : 28'(accX + stepX);
      if (xWrap)
        accY <= yAtEnd ? startY : 28'(accY + stepY);
    end

    if (reset)
      tagClearAddr <= 10'h200;
    else if (io_frameStart)
      tagClearAddr <= 10'h000;
    else if (tagClearing)
      tagClearAddr <= 10'(tagClearAddr + 10'h1);
    if (tagClearing)
      rowTags[tagClearAddr[8:0]] <= 19'h0;
    else if (frameBufferInputFire)
      rowTags[posReg_x[8:0]] <= rowSeqP;
    if (frameBufferInputReady)
      rowTagOut <= rowTags[adjustedX[16:8]];

    if (reset | io_frameStart)
      lastTagValid <= 1'b0;
    else if (frameBufferInputFire)
      lastTagValid <= 1'b1;
    if (frameBufferInputFire) begin
      lastTagAddr <= posReg_x[8:0];
      lastTagData <= rowSeqP;
    end

    if (reset | io_frameStart)
      rowSeq <= 19'h1;
    else if (xWrap)
      rowSeq <= 19'(rowSeq + 19'h1);
    if (reset | latchConfig)
      newSprite <= 1'b1;
    else if (frameBufferInputReady & ~pisoEmpty)
      newSprite <= 1'b0;
    if (~reset & frameBufferInputReady) begin
      rowSeqP <= rowSeq;
      hFlipP <= configReg_sprite_hFlip;
      vFlipP <= configReg_sprite_vFlip;
      runStartReg <= runStartP;
      rowFirstP <= rowSeq != rowSeqP;
      if (rowSeq != rowSeqP) begin
        prevRowY <= posReg_y;
        spriteFirstP <= newSprite;
      end
    end

    if (latchConfig) begin
      configReg_sprite_priority <= io_config_bits_sprite_priority;
      configReg_sprite_colorCode <= io_config_bits_sprite_colorCode;
      configReg_sprite_hFlip <= io_config_bits_sprite_hFlip;
      configReg_sprite_vFlip <= io_config_bits_sprite_vFlip;
      configReg_sprite_pos_x <= io_config_bits_sprite_pos_x;
      configReg_sprite_pos_y <= io_config_bits_sprite_pos_y;
      configReg_sprite_cols <= io_config_bits_sprite_cols;
      configReg_sprite_rows <= io_config_bits_sprite_rows;
      configReg_sprite_zoom_x <= io_config_bits_sprite_zoom_x;
      configReg_sprite_zoom_y <= io_config_bits_sprite_zoom_y;
      configReg_hFlip <= io_config_bits_hFlip;
    end

    if (~reset & frameBufferInputReady) begin
      posReg_x <= adjustedX[27:8];
      posReg_y <= adjustedY[27:8];
      penReg_priority <= configReg_sprite_priority;
      penReg_palette <= configReg_sprite_colorCode;
      penReg_color <= pisoPixel;
      validReg <= ~pisoEmpty;
    end

    if (reset | ~io_enable) begin
      frameBufferWriteCount <= 2'd0;
      frameBufferWriteAddr0 <= 17'd0;
      frameBufferWriteAddr1 <= 17'd0;
      frameBufferWriteDin0 <= 16'd0;
      frameBufferWriteDin1 <= 16'd0;
    end
    else begin
      case ({frameBufferInputFire, frameBufferOutputFire})
        2'b01: begin
          if (frameBufferWriteCount == 2'd2) begin
            frameBufferWriteAddr0 <= frameBufferWriteAddr1;
            frameBufferWriteDin0 <= frameBufferWriteDin1;
          end
          frameBufferWriteCount <= frameBufferWriteCount - 2'd1;
        end
        2'b10: begin
          if (frameBufferWriteCount == 2'd0) begin
            frameBufferWriteAddr0 <= frameBufferInputAddr;
            frameBufferWriteDin0 <= frameBufferInputDin;
          end
          else begin
            frameBufferWriteAddr1 <= frameBufferInputAddr;
            frameBufferWriteDin1 <= frameBufferInputDin;
          end
          frameBufferWriteCount <= frameBufferWriteCount + 2'd1;
        end
        2'b11: begin
          frameBufferWriteAddr0 <= frameBufferInputAddr;
          frameBufferWriteDin0 <= frameBufferInputDin;
        end
        default: begin
        end
      endcase
    end
  end

  assign pisoRead = busyReg & frameBufferInputReady;
  assign pisoWrite = pixelDataReady & io_pixelData_valid;

  CaveSpritePixelShiftBuffer pixelShiftBuffer (
    .clock            (clock),
    .reset            (reset),
    .io_rd            (pisoRead),
    .io_wr            (pisoWrite),
    .io_isEmpty       (pisoEmpty),
    .io_isAlmostEmpty (pisoAlmostEmpty),
    .io_din_0         (io_pixelData_bits_0),
    .io_din_1         (io_pixelData_bits_1),
    .io_din_2         (io_pixelData_bits_2),
    .io_din_3         (io_pixelData_bits_3),
    .io_din_4         (io_pixelData_bits_4),
    .io_din_5         (io_pixelData_bits_5),
    .io_din_6         (io_pixelData_bits_6),
    .io_din_7         (io_pixelData_bits_7),
    .io_din_8         (io_pixelData_bits_8),
    .io_din_9         (io_pixelData_bits_9),
    .io_din_10        (io_pixelData_bits_10),
    .io_din_11        (io_pixelData_bits_11),
    .io_din_12        (io_pixelData_bits_12),
    .io_din_13        (io_pixelData_bits_13),
    .io_din_14        (io_pixelData_bits_14),
    .io_din_15        (io_pixelData_bits_15),
    .io_dout          (pisoPixel)
  );

  assign io_busy = busyReg | (io_enable & frameBufferOutputValid);
  assign io_config_ready = configReady;
  assign io_pixelData_ready = pixelDataReady;
  assign io_frameBuffer_wr = io_enable & ~reset & frameBufferOutputValid;
  assign io_frameBuffer_addr = frameBufferWriteAddr0;
  assign io_frameBuffer_din = frameBufferWriteDin0;
endmodule
