// This file is a Codex-assisted rewrite based on the original work of
// Josh Bassett (nullobject).

// Signed audio mixer with fixed-point gain and 16-bit output clipping.
module AudioMixer (
  input         clock,
  input         io_pwrinst2,
  input         io_ymz,
  input         io_legacy_oki,
  input  [3:0]  io_pwrinst2_oki0_level,
  input  [3:0]  io_pwrinst2_oki1_level,
  input         io_pwrinst2_headroom,
  input  [3:0]  io_pwrinst2_psg_level,
  input  [3:0]  io_pwrinst2_fm_level,
  input  [3:0]  io_ymz_level,
  input  [13:0] io_in_4,
  input  [13:0] io_in_3,
  input  [15:0] io_in_2,
  input  [15:0] io_in_1,
  input  [15:0] io_in_0,
  output [15:0] io_out
);
  localparam signed [34:0] MIN_SAMPLE = -35'sd32768;
  localparam signed [34:0] MAX_SAMPLE =  35'sd32767;

  wire [19:0] audio_levels_async = {
    io_ymz_level,
    io_pwrinst2_fm_level,
    io_pwrinst2_psg_level,
    io_pwrinst2_oki1_level,
    io_pwrinst2_oki0_level
  };
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg [19:0] audio_levels_meta = 20'd0;
  (* preserve, useioff = 0, altera_attribute = {"-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS"} *)
  reg [19:0] audio_levels_sync = 20'd0;
  reg [19:0] audio_levels_confirm = 20'd0;
  reg [19:0] audio_levels_stable = 20'd0;

  // Menu fields originate on clk_sys. Accept a new packed value only after two
  // synchronized samples match so a multi-bit transition cannot set a mixed gain.
  always @(posedge clock) begin
    audio_levels_meta <= audio_levels_async;
    audio_levels_sync <= audio_levels_meta;
    audio_levels_confirm <= audio_levels_sync;
    if (audio_levels_confirm == audio_levels_sync)
      audio_levels_stable <= audio_levels_confirm;
  end

  wire [3:0] pwrinst2_oki0_level = audio_levels_stable[3:0];
  wire [3:0] pwrinst2_oki1_level = audio_levels_stable[7:4];
  wire [3:0] pwrinst2_psg_level  = audio_levels_stable[11:8];
  wire [3:0] pwrinst2_fm_level   = audio_levels_stable[15:12];
  wire [3:0] ymz_level           = audio_levels_stable[19:16];

  function automatic signed [31:0] apply_boost;
    input signed [31:0] base;
    input [3:0] level;
    reg signed [12:0] scale;
    reg signed [44:0] product;
    begin
      case (level)
        4'd1: scale = 13'sd1126;
        4'd2: scale = 13'sd1229;
        4'd3: scale = 13'sd1331;
        4'd4: scale = 13'sd1434;
        4'd5: scale = 13'sd1536;
        4'd6: scale = 13'sd1638;
        4'd7: scale = 13'sd1741;
        4'd8: scale = 13'sd1843;
        4'd9: scale = 13'sd1946;
        4'd10: scale = 13'sd2048;
        default: scale = 13'sd1024;
      endcase
      product = base * scale;
      apply_boost = product >>> 10;
    end
  endfunction

  wire signed [18:0] channel_1_sample = $signed({{3{io_in_1[15]}}, io_in_1});
  wire signed [21:0] channel_3_sample = $signed({{6{io_in_3[13]}}, io_in_3, 2'b00});

  wire signed [18:0] channel_1_gain =
    channel_1_sample + (channel_1_sample <<< 1);
  wire signed [21:0] channel_3_gain =
    (channel_3_sample <<< 4) + (channel_3_sample <<< 3) + (channel_3_sample <<< 1);

  wire signed [25:0] legacy_mix_sum =
    $signed({{6{io_in_0[15]}}, io_in_0, 4'b0000})
    + $signed({{7{channel_1_gain[18]}}, channel_1_gain})
    + $signed({{6{io_in_2[15]}}, io_in_2, 4'b0000})
    + $signed({{4{channel_3_gain[21]}}, channel_3_gain})
    + $signed({{6{io_in_4[13]}}, io_in_4, 6'b000000});
  wire signed [28:0] legacy_mix_ext = {{3{legacy_mix_sum[25]}}, legacy_mix_sum};
  wire signed [28:0] legacy_scaled_sum = legacy_mix_ext >>> 4;
  wire signed [34:0] legacy_default_sum =
    $signed({{6{legacy_scaled_sum[28]}}, legacy_scaled_sum});

  wire signed [31:0] legacy_ymz_base =
    $signed({{3{legacy_scaled_sum[28]}}, legacy_scaled_sum});
  wire signed [31:0] legacy_ymz_gain = apply_boost(legacy_ymz_base, ymz_level);
  wire signed [34:0] legacy_ymz_sum =
    $signed({{3{legacy_ymz_gain[31]}}, legacy_ymz_gain});

  wire signed [31:0] legacy_other_pre =
    $signed({{12{io_in_0[15]}}, io_in_0, 4'b0000})
    + $signed({{13{channel_1_gain[18]}}, channel_1_gain})
    + $signed({{12{io_in_2[15]}}, io_in_2, 4'b0000});
  wire signed [31:0] legacy_oki0_pre =
    $signed({{10{channel_3_gain[21]}}, channel_3_gain});
  wire signed [31:0] legacy_oki1_pre =
    $signed({{12{io_in_4[13]}}, io_in_4, 6'b000000});
  wire signed [31:0] legacy_oki0_gain =
    apply_boost(legacy_oki0_pre, pwrinst2_oki0_level);
  wire signed [31:0] legacy_oki1_gain =
    apply_boost(legacy_oki1_pre, pwrinst2_oki1_level);
  wire signed [34:0] legacy_oki_pre_sum =
    $signed({{3{legacy_other_pre[31]}}, legacy_other_pre})
    + $signed({{3{legacy_oki0_gain[31]}}, legacy_oki0_gain})
    + $signed({{3{legacy_oki1_gain[31]}}, legacy_oki1_gain});
  wire signed [34:0] legacy_oki_sum = legacy_oki_pre_sum >>> 4;

  wire ymz_boost_enabled = io_ymz && (ymz_level >= 4'd1) && (ymz_level <= 4'd10);
  wire legacy_oki_boost_enabled = io_legacy_oki &&
    (((pwrinst2_oki0_level >= 4'd1) && (pwrinst2_oki0_level <= 4'd10)) ||
     ((pwrinst2_oki1_level >= 4'd1) && (pwrinst2_oki1_level <= 4'd10)));
  wire signed [34:0] legacy_selected_sum =
    ymz_boost_enabled ? legacy_ymz_sum :
    legacy_oki_boost_enabled ? legacy_oki_sum :
                               legacy_default_sum;

  wire signed [18:0] pwrinst2_psg_sample = $signed({3'b000, io_in_1});
  wire signed [18:0] pwrinst2_fm_sample = $signed({{3{io_in_2[15]}}, io_in_2});
  wire signed [18:0] pwrinst2_oki0_sample = $signed({{3{io_in_3[13]}}, io_in_3, 2'b00});
  wire signed [18:0] pwrinst2_oki1_sample = $signed({{3{io_in_4[13]}}, io_in_4, 2'b00});
  wire signed [31:0] pwrinst2_oki0_base =
    $signed({{13{pwrinst2_oki0_sample[18]}}, pwrinst2_oki0_sample});
  wire signed [31:0] pwrinst2_oki1_base =
    $signed({{13{pwrinst2_oki1_sample[18]}}, pwrinst2_oki1_sample});
  wire signed [31:0] pwrinst2_psg_base =
    $signed({{13{pwrinst2_psg_sample[18]}}, pwrinst2_psg_sample});
  wire signed [31:0] pwrinst2_fm_base =
    $signed({{13{pwrinst2_fm_sample[18]}}, pwrinst2_fm_sample});
  // Zero boost preserves the MiSTer-devel FPGA-path compensation. MAME's
  // routing is PSG A/B/C at 0.40, FM at 0.80, OKI0 at 0.80, and OKI1 at 1.00;
  // these anchors account for the implementations' differing raw scales.
  // Shared headroom divides the anchors by four after per-path boost.
  wire signed [31:0] pwrinst2_psg_anchor = pwrinst2_psg_base <<< 1;
  wire signed [31:0] pwrinst2_fm_anchor = pwrinst2_fm_base <<< 4;
  wire signed [31:0] pwrinst2_oki0_anchor = pwrinst2_oki0_base <<< 3;
  wire signed [31:0] pwrinst2_oki1_anchor =
    (pwrinst2_oki1_base <<< 2) + (pwrinst2_oki1_base <<< 1);
  wire signed [31:0] pwrinst2_psg_gain =
    apply_boost(pwrinst2_psg_anchor, pwrinst2_psg_level);
  wire signed [31:0] pwrinst2_fm_gain =
    apply_boost(pwrinst2_fm_anchor, pwrinst2_fm_level);
  wire signed [31:0] pwrinst2_oki0_gain =
    apply_boost(pwrinst2_oki0_anchor, pwrinst2_oki0_level);
  wire signed [31:0] pwrinst2_oki1_gain =
    apply_boost(pwrinst2_oki1_anchor, pwrinst2_oki1_level);
  wire signed [34:0] pwrinst2_mix_sum =
    $signed({{3{pwrinst2_psg_gain[31]}}, pwrinst2_psg_gain})
    + $signed({{3{pwrinst2_fm_gain[31]}}, pwrinst2_fm_gain})
    + $signed({{3{pwrinst2_oki0_gain[31]}}, pwrinst2_oki0_gain})
    + $signed({{3{pwrinst2_oki1_gain[31]}}, pwrinst2_oki1_gain});
  wire signed [34:0] pwrinst2_scaled_sum =
    io_pwrinst2_headroom ? (pwrinst2_mix_sum >>> 2) : (pwrinst2_mix_sum >>> 1);

  wire signed [34:0] scaled_sum =
    io_pwrinst2 ? pwrinst2_scaled_sum :
                  legacy_selected_sum;
  wire signed [34:0] clipped_low = scaled_sum < MIN_SAMPLE ? MIN_SAMPLE : scaled_sum;
  wire signed [34:0] clipped = clipped_low < MAX_SAMPLE ? clipped_low : MAX_SAMPLE;

  reg signed [34:0] audio_reg;

  always @(posedge clock)
    audio_reg <= clipped;

  assign io_out = audio_reg[15:0];
endmodule
