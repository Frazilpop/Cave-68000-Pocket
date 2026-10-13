// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).

module CaveCpuBusStrobes(
  input  wire clock,
  input  wire hold,
  input  wire state_load,
  input  wire [2:0] state_in,
  input  wire as,
  input  wire uds,
  input  wire lds,
  input  wire rw,
  output wire read_strobe,
  output wire write_strobe,
  output wire [2:0] state_out
);

  reg asPrev;
  reg udsPrev;
  reg ldsPrev;

  assign read_strobe = as & ~asPrev & rw;
  assign write_strobe =
    (as & uds & ~udsPrev & ~rw)
    | (as & lds & ~ldsPrev & ~rw);

  always @(posedge clock) begin
    if (state_load) begin
      asPrev <= state_in[2];
      udsPrev <= state_in[1];
      ldsPrev <= state_in[0];
    end
    else if (!hold) begin
      asPrev <= as;
      udsPrev <= uds;
      ldsPrev <= lds;
    end
  end

  assign state_out = {asPrev, udsPrev, ldsPrev};

endmodule

module CaveSoundReplyReadLatch(
  input  wire        clock,
  input  wire        reset,
  input  wire        read_strobe,
  input  wire        fifo_empty,
  input  wire [15:0] fifo_data,
  output wire        fifo_pop,
  output reg  [15:0] cpu_data
);

  assign fifo_pop = read_strobe & ~fifo_empty;

  always @(posedge clock) begin
    if (reset)
      cpu_data <= 16'h00FF;
    else if (read_strobe)
      cpu_data <= fifo_empty ? 16'h00FF : fifo_data;
  end

endmodule

module CaveEepromSerialPins(
  input  wire       clock,
  input  wire       reset,
  input  wire       hold,
  input  wire       state_load,
  input  wire [2:0] state_in,
  input  wire       write_enable,
  input  wire       guwange_layout,
  input  wire [15:0] data,
  output reg        serial_cs,
  output reg        serial_sck,
  output reg        serial_sdi,
  output wire [2:0] state_out
);

  always @(posedge clock) begin
    if (reset) begin
      serial_cs <= 1'b0;
      serial_sck <= 1'b0;
      serial_sdi <= 1'b0;
    end
    else if (state_load) begin
      serial_cs <= state_in[2];
      serial_sck <= state_in[1];
      serial_sdi <= state_in[0];
    end
    else if (!hold && write_enable) begin
      serial_cs <= guwange_layout ? data[5] : data[9];
      serial_sck <= guwange_layout ? data[6] : data[10];
      serial_sdi <= guwange_layout ? data[7] : data[11];
    end
  end

  assign state_out = {serial_cs, serial_sck, serial_sdi};

endmodule

module CaveInputMapper(
  input  wire        game_is_guwange,
  input  wire        game_is_gaia,
  input  wire        eeprom_sdo,
  input  wire        service_active,
  input  wire        coin1_active,
  input  wire        coin2_active,
  input  wire        player0_up,
  input  wire        player0_down,
  input  wire        player0_left,
  input  wire        player0_right,
  input  wire [3:0]  player0_buttons,
  input  wire        player0_start,
  input  wire        player1_up,
  input  wire        player1_down,
  input  wire        player1_left,
  input  wire        player1_right,
  input  wire [3:0]  player1_buttons,
  input  wire        player1_start,
  output wire [15:0] default_p1,
  output wire [15:0] default_p2,
  output wire [15:0] combined_players,
  output wire [15:0] guwange_p1,
  output wire [15:0] input0,
  output wire [15:0] default_or_guwange_p1,
  output wire [15:0] combined_or_guwange_p1,
  output wire [15:0] guwange_system,
  output wire [15:0] gaia_system,
  output wire [15:0] input1,
  output wire [15:0] default_or_guwange_p2,
  output wire [15:0] shared_system
);

  wire [11:0] input0Prefix =
    game_is_gaia
      ? {~player1_buttons,
         ~player1_right,
         ~player1_left,
         ~player1_down,
         ~player1_up,
         ~player0_buttons}
      : {6'h3F,
         ~service_active,
         ~coin1_active,
         ~player0_start,
         ~(player0_buttons[2:0])};

  wire [12:0] sharedSystemPrefix =
    game_is_guwange
      ? {8'hFF, eeprom_sdo, 4'hF}
      : {10'h3F, ~player1_start, ~player0_start, 1'b1};

  assign default_p1 =
    {6'h3F,
     ~service_active,
     ~coin1_active,
     ~player0_start,
     ~(player0_buttons[2:0]),
     ~player0_right,
     ~player0_left,
     ~player0_down,
     ~player0_up};

  assign default_p2 =
    {4'hF,
     eeprom_sdo,
     2'h3,
     ~coin2_active,
     ~player1_start,
     ~(player1_buttons[2:0]),
     ~player1_right,
     ~player1_left,
     ~player1_down,
     ~player1_up};

  assign combined_players =
    {~player1_buttons,
     ~player1_right,
     ~player1_left,
     ~player1_down,
     ~player1_up,
     ~player0_buttons,
     ~player0_right,
     ~player0_left,
     ~player0_down,
     ~player0_up};

  assign guwange_p1 =
    {~(player1_buttons[2:0]),
     ~player1_right,
     ~player1_left,
     ~player1_down,
     ~player1_up,
     ~player1_start,
     ~(player0_buttons[2:0]),
     ~player0_right,
     ~player0_left,
     ~player0_down,
     ~player0_up,
     ~player0_start};

  assign input0 =
    game_is_guwange
      ? guwange_p1
      : {input0Prefix,
         ~player0_right,
         ~player0_left,
         ~player0_down,
         ~player0_up};

  assign default_or_guwange_p1 = game_is_guwange ? guwange_p1 : default_p1;
  assign combined_or_guwange_p1 = game_is_guwange ? guwange_p1 : combined_players;

  assign guwange_system =
    {8'hFF,
     eeprom_sdo,
     4'hF,
     ~service_active,
     ~coin2_active,
     ~coin1_active};

  assign gaia_system =
    {10'h3F,
     ~player1_start,
     ~player0_start,
     1'b1,
     ~service_active,
     ~coin2_active,
     ~coin1_active};

  assign input1 =
    game_is_guwange
      ? guwange_system
      : game_is_gaia ? gaia_system : default_p2;

  assign default_or_guwange_p2 = game_is_guwange ? guwange_system : default_p2;
  assign shared_system =
    {sharedSystemPrefix, ~service_active, ~coin2_active, ~coin1_active};

endmodule

module CavePauseToggle(
  input  wire clock,
  input  wire reset,
  input  wire hold,
  input  wire state_load,
  input  wire [1:0] state_in,
  input  wire pause_pressed,
  output reg  pause_active,
  output wire [1:0] state_out
);

  reg pausePressedPrev;

  always @(posedge clock) begin
    if (reset) begin
      pause_active <= 1'b0;
      pausePressedPrev <= 1'b0;
    end
    else if (state_load) begin
      pausePressedPrev <= state_in[1];
      pause_active <= state_in[0];
    end
    else if (!hold) begin
      pausePressedPrev <= pause_pressed;
      pause_active <= (pause_pressed & ~pausePressedPrev) ^ pause_active;
    end
  end

  assign state_out = {pausePressedPrev, pause_active};

endmodule

module CavePulseStretcher #(
  parameter integer COUNTER_WIDTH = 22,
  parameter [COUNTER_WIDTH-1:0] TERMINAL_COUNT = {COUNTER_WIDTH{1'b1}}
)(
  input  wire clock,
  input  wire reset,
  input  wire hold,
  input  wire state_load,
  input  wire [COUNTER_WIDTH+1:0] state_in,
  input  wire signal_in,
  output reg  pulse_active,
  output wire [COUNTER_WIDTH+1:0] state_out
);

  reg [COUNTER_WIDTH-1:0] counter;
  reg                     signalPrev;

  wire counterDone = counter == TERMINAL_COUNT;
  wire risingEdge = signal_in & ~signalPrev;

  always @(posedge clock) begin
    if (reset) begin
      counter <= {COUNTER_WIDTH{1'b0}};
      // Absorb a trigger already asserted during reset instead of inventing an edge.
      signalPrev <= signal_in;
      pulse_active <= 1'b0;
    end
    else if (state_load) begin
      counter <= state_in[COUNTER_WIDTH+1:2];
      signalPrev <= state_in[1];
      pulse_active <= state_in[0];
    end
    else if (!hold) begin
      signalPrev <= signal_in;
      if (pulse_active)
        counter <=
          counterDone
            ? {COUNTER_WIDTH{1'b0}}
            : counter + {{(COUNTER_WIDTH - 1){1'b0}}, 1'b1};
      pulse_active <= ~(pulse_active & counterDone) & (risingEdge | pulse_active);
    end
  end

  assign state_out = {counter, signalPrev, pulse_active};

endmodule

module CaveVBlankTracker(
  input  wire clock,
  input  wire hold,
  input  wire state_load,
  input  wire [3:0] state_in,
  input  wire vblank,
  output wire rising,
  output wire falling,
  output wire [3:0] state_out
);

  reg vblankPipe0;
  reg vblankPipe1;
  reg vblankRisingDelay;
  reg vblankPrevious;

  assign rising = vblankPipe1 & ~vblankRisingDelay;
  assign falling = ~vblankPipe1 & vblankPrevious;

  always @(posedge clock) begin
    if (state_load) begin
      vblankPipe0 <= state_in[3];
      vblankPipe1 <= state_in[2];
      vblankRisingDelay <= state_in[1];
      vblankPrevious <= state_in[0];
    end
    else if (!hold) begin
      vblankPipe0 <= vblank;
      vblankPipe1 <= vblankPipe0;
      vblankRisingDelay <= vblankPipe1;
      vblankPrevious <= vblankPipe1;
    end
  end

  assign state_out =
    {vblankPipe0, vblankPipe1, vblankRisingDelay, vblankPrevious};

endmodule
