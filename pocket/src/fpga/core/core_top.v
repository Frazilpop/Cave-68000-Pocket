// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket — the core top level
//
// Instantiated by Analogue's apf_top. Everything Pocket-specific lives here and
// in the pocket_* modules beside it; the board (rtl/top/cave68000_mem.sv: the
// board and its memory adapters) knows nothing of APF, pins or the bridge.
//
// CLOCKS (pocket_plls.v has the derivation)
//
//   clk_74a        74.25 MHz  APF bridge, pad bus, I2S; both PLLs' reference
//   clk            96 MHz     the memories and their servants, the sprite
//                             processor and frame buffer, the loader, the save
//   clk_cpu        32 MHz     the 68000 side, the YMZ280B, the inputs, the
//                             sound's resampler; 3:1 with clk, phase-aligned
//   clk_sdram_ps   96 MHz     180 degrees, forwarded to dram_clk
//   clk_vid        28 MHz     the layers, the mixer, the video timing, the
//                             overlay (second PLL)
//   clk_pix         7 MHz     APF video bus; clk_pix90 its 90-degree copy
//
// clk, clk_cpu and clk_sdram_ps come from one VCO and are timed against each
// other; so are clk_vid and the two pixel clocks, on the other. The two
// groups, and clk_74a, meet only through synchronisers, dcfifos and dual-clock
// RAMs (upstream's inside the board, the APF ones here), and
// core_constraints.sdc cuts exactly those.
//
// BRIDGE MAP
//
//   0x00000000-   ROM image data slot -> SDRAM          pocket_rom_loader
//   0x20000000-   EEPROM save slot, 128 bytes, r/w      pocket_nvram
//   0xF0000000    game id (instance JSON memory_writes) r/w
//   0xF1000000-   options (interact.json)               r/w, see below
//   0xF8000000-   APF command bridge                    core_bridge_cmd
//
// DATA SLOTS (dist/Cores/frazilpop.Cave 68000/data.json), in table order:
//
//   [0] id 0  instance JSON (APF requires the instance slot to come first)
//   [1] id 1  <set>.rom at 0x00000000
//   [2] id 2  <set>.sav at 0x20000000, nonvolatile, 128 bytes

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable,

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,

///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,

output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
//
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig

);

localparam SDR_COL = 10;                    // AS4C32M16MSA: 8192 x 1024 x 4
localparam SDR_AW  = 2 + 13 + SDR_COL;      // 25: word address [25:1], 64 MB
localparam NP      = 7;                     // the board's SDRAM read ports
// One more at the controller than the board has: port NP is the shell's own
// SDRAM read-back check (see DIAGNOSTICS below). The board never sees it.
localparam NPS     = NP + 1;

// ============================================================ unused pins
// As Analogue's template leaves them.

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;

// The SRAM is not used: the 68000's work RAM stays in block RAM, where
// upstream has it. Every control held inactive, the bus let go.
assign sram_a    = 17'd0;
assign sram_dq   = 16'hzzzz;
assign sram_oe_n = 1'b1;
assign sram_we_n = 1'b1;
assign sram_ub_n = 1'b1;
assign sram_lb_n = 1'b1;

// ================================================================= clocks
wire clk, clk_cpu, clk_sdram_ps, clk_vid, clk_pix, clk_pix90;
wire pll_core_locked, pll_video_locked;

pocket_pll_core u_pll_core (
    .refclk       ( clk_74a ),
    .clk          ( clk ),
    .clk_cpu      ( clk_cpu ),
    .clk_sdram_ps ( clk_sdram_ps ),
    .locked       ( pll_core_locked )
);

pocket_pll_video u_pll_video (
    .refclk    ( clk_74a ),
    .clk_vid   ( clk_vid ),
    .clk_pix   ( clk_pix ),
    .clk_pix90 ( clk_pix90 ),
    .locked    ( pll_video_locked )
);

// ================================================================= resets
//
//   sdram_rst_n   clk, PLL lock only. kaneko_sdram's reset is synchronous (so
//                 its pins pack into I/O cells) and it runs its own power-up
//                 sequence; it must never be reset again after that.
//   rst_por       clk, both PLLs locked: the loader, the PSRAM servants (whose
//                 power-up and calibration run once), the save slot.
//   board_rst     clk: rst_por, or APF holding the core in reset (from boot
//                 to [0011 Reset Exit], and again from [0010 Reset Enter]), or
//                 the Reset action. Taken into
//                 clk_cpu by a register (the two are aligned) and into
//                 clk_vid by a synchroniser. The board adds !rom_loaded.

wire plls_locked = pll_core_locked & pll_video_locked;
wire plls_locked_74;                        // clk_74a
synch_3 s_lock74 (.i(plls_locked), .o(plls_locked_74), .clk(clk_74a), .rise(), .fall());

wire locked_96;
synch_3 s_lock96 (.i(pll_core_locked), .o(locked_96), .clk(clk), .rise(), .fall());
wire sdram_rst_n = locked_96;

wire both_96;
synch_3 s_both96 (.i(plls_locked), .o(both_96), .clk(clk), .rise(), .fall());
reg [7:0] por_cnt = 8'd0;
always @(posedge clk)
    if (!both_96)              por_cnt <= 8'd0;
    else if (por_cnt != 8'hff) por_cnt <= por_cnt + 8'd1;
wire rst_por = (por_cnt != 8'hff);

wire reset_n;                               // clk_74a, from core_bridge_cmd
wire reset_n_96;
synch_3 s_rstn96 (.i(reset_n), .o(reset_n_96), .clk(clk), .rise(), .fall());

// ================================================================== bridge
//
// Writes are broadcast: the two data_loaders inside pocket_rom_loader and
// pocket_nvram pick out their own regions; the registers below pick out
// theirs. Reads are muxed and REGISTERED: APF buffers bridge reads and allows
// the data until the next read strobe, which is many cycles of clk_74a.

wire [31:0] cmd_bridge_rd_data;
wire [31:0] nv_bridge_rd;

// ---- settings written by APF (instance JSON, interact.json)
//
// Every field is laid out so that ZERO IS THE DEFAULT: APF writes persisted
// interact values only when there are some, so on a first boot the core's
// reset value IS the setting.
//
//   0xF0000000 [2:0]   game: CaveGameConfig's index, as the instance JSON
//                      writes it: 0 feversos, dfeveron; 1 ddonpach(j);
//                      3 esprade(j, jo); 4 uopoko(j); 5 guwange(s);
//                      6 gaia, theroes(a)
//   0xF1000000         write 1: Test Mode, an action: one press of the
//                      board's test button (a 1 ms pulse; upstream stretches
//                      its edge into a press of 2.5 s, which the games take
//                      as a tap: MAME's picture is the same for a 3-frame
//                      and a 144-frame press). In the game it opens the test
//                      menu; in the menu it leaves it, and that is when the
//                      EEPROM games write the settings changed there (seen in
//                      MAME on dfeveron: a change is only on screen until
//                      then). Resetting the game instead would lose them.
//                      The action is selected with the Pocket's menu open,
//                      and under the menu the 68000 is halted while the
//                      stretcher runs on, so a press made then was over
//                      before the game ran again (build 7: nothing
//                      happened). The press waits for the menu to close
//                      (and for no reset to be running) before it is made.
//                      Every DIP is held at MAME's default: the EEPROM games
//                      keep their settings in the EEPROM (the test menu sets
//                      them), and gaia's and theroes's DSW word is 0xfffb.
//   0xF100000C         write: reset the game (1 ms)
//   0xF1000014 [0]     diagnostic overlay (pocket_diag), see DIAGNOSTICS

reg  [2:0]  game_74  = 3'd0;
wire        osnotify_inmenu;                //   APF's menu open (core_bridge_cmd, clk_74a)
reg         test_pend = 1'b0;               //   a press waiting for the menu to close
reg  [16:0] test_cnt  = 17'd0;              //   1 ms, as the reset
wire        test_74  = (test_cnt != 17'd0);
reg         diag_74  = 1'b0;
reg  [16:0] hrst_cnt = 17'd0;               //   1 ms at 74.25 MHz = 74,250
wire        hrst_74  = (hrst_cnt != 17'd0);

always @(posedge clk_74a) begin
    if (hrst_cnt != 17'd0) hrst_cnt <= hrst_cnt - 17'd1;
    if (test_cnt != 17'd0) test_cnt <= test_cnt - 17'd1;
    if (test_pend && !osnotify_inmenu && !hrst_74) begin
        test_pend <= 1'b0;
        test_cnt  <= 17'd74250;
    end
    if (bridge_wr) begin
        case (bridge_addr)
        32'hF0000000: begin
            game_74 <= bridge_wr_data[2:0];
            // a new game is taken with the board in reset (the .sdc relies on it)
            if (bridge_wr_data[2:0] != game_74) hrst_cnt <= 17'd74250;
        end
        32'hF1000000: if (bridge_wr_data[0]) test_pend <= 1'b1;
        32'hF100000C: hrst_cnt <= 17'd74250;
        32'hF1000014: diag_74  <= bridge_wr_data[0];
        default: ;
        endcase
    end
end

always @(posedge clk_74a) begin
    casez (bridge_addr)
    32'h2???????: bridge_rd_data <= nv_bridge_rd;
    32'hF0000000: bridge_rd_data <= {29'd0, game_74};
    32'hF1000014: bridge_rd_data <= {31'd0, diag_74};
    32'hF8??????: bridge_rd_data <= cmd_bridge_rd_data;
    default:      bridge_rd_data <= 32'd0;
    endcase
end

// ---- the APF command bridge, as the template wires it
wire            status_boot_done  = plls_locked_74;
// "Setup" means ready to take memory writes, which here means the SDRAM has
// finished its power-up sequence.
wire            mem_ready;
wire            mem_ready_74;
synch_3 s_memrdy74 (.i(mem_ready), .o(mem_ready_74), .clk(clk_74a), .rise(), .fall());
wire            status_setup_done = plls_locked_74 & mem_ready_74;
wire            status_running    = reset_n;

wire            dataslot_requestread;
wire    [15:0]  dataslot_requestread_id;
wire            dataslot_requestread_ack = 1;
wire            dataslot_requestread_ok  = 1;

wire            dataslot_requestwrite;
wire    [15:0]  dataslot_requestwrite_id;
wire    [31:0]  dataslot_requestwrite_size;
wire            dataslot_requestwrite_ack = 1;
wire            dataslot_requestwrite_ok  = 1;

wire            dataslot_update;
wire    [15:0]  dataslot_update_id;
wire    [31:0]  dataslot_update_size;

wire            dataslot_allcomplete;

wire     [31:0] rtc_epoch_seconds;
wire     [31:0] rtc_date_bcd;
wire     [31:0] rtc_time_bcd;
wire            rtc_valid;

wire            savestate_supported   = 1'b0;
wire    [31:0]  savestate_addr        = 32'd0;
wire    [31:0]  savestate_size        = 32'd0;
wire    [31:0]  savestate_maxloadsize = 32'd0;

wire            savestate_start;
wire            savestate_start_ack   = 1'b0;
wire            savestate_start_busy  = 1'b0;
wire            savestate_start_ok    = 1'b0;
wire            savestate_start_err   = 1'b0;

wire            savestate_load;
wire            savestate_load_ack    = 1'b0;
wire            savestate_load_busy   = 1'b0;
wire            savestate_load_ok     = 1'b0;
wire            savestate_load_err    = 1'b0;


wire            target_dataslot_read      = 1'b0;
wire            target_dataslot_write     = 1'b0;
wire            target_dataslot_getfile   = 1'b0;
wire            target_dataslot_openfile  = 1'b0;

wire            target_dataslot_ack;
wire            target_dataslot_done;
wire    [2:0]   target_dataslot_err;

wire    [15:0]  target_dataslot_id         = 16'd0;
wire    [31:0]  target_dataslot_slotoffset = 32'd0;
wire    [31:0]  target_dataslot_bridgeaddr = 32'd0;
wire    [31:0]  target_dataslot_length     = 32'd0;

wire    [31:0]  target_buffer_param_struct = 32'd0;
wire    [31:0]  target_buffer_resp_struct  = 32'd0;

// THE SAVE FILE'S SIZE. APF writes back as many bytes as the Dataslot
// ID/Size table says, and when no .sav existed yet that entry is zero — the
// game would save into the EEPROM and nothing would ever reach the card. So
// the core keeps writing 128 into the size word of the save slot's entry,
// which is table index 2 (data.json order), word 2*2+1.
reg     [9:0]   datatable_addr;
reg             datatable_wren;
reg     [31:0]  datatable_data;
wire    [31:0]  datatable_q;

always @(posedge clk_74a) begin
    datatable_addr <= 10'd5;
    datatable_wren <= 1'b1;
    datatable_data <= 32'd128;
end

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),

    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),

    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),

    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);

// ======================================================== settings -> clk
wire [2:0]  game;
wire        host_rst, diag_opt, test_opt;

pocket_sync_bus #(.W(3), .INIT(3'd0)) s_cfg96 (
    .clk (clk),
    .d   ({hrst_74, diag_74, test_74}),
    .q   ({host_rst, diag_opt, test_opt})
);

// THE GAME ID is written by the instance JSON before APF lets the core out of
// reset, and writing a different one resets the game (above), so it never
// changes while the board runs. The board reads it in all three of its
// clock domains, and core_constraints.sdc cuts the paths from this register.
pocket_sync_bus #(.W(3), .INIT(3'd0)) s_game96 (
    .clk (clk),
    .d   (game_74),
    .q   (game)
);

reg  board_rst = 1'b1;
always @(posedge clk) board_rst <= rst_por | ~reset_n_96 | host_rst;

// clk_cpu is aligned with clk (3:1, one VCO): a register is the crossing
reg  rst_cpu = 1'b1;
always @(posedge clk_cpu) rst_cpu <= board_rst;
wire rst_vid;
synch_3 s_rstvid (.i(board_rst), .o(rst_vid), .clk(clk_vid), .rise(), .fall());

// The board's DSW for gaia and theroes, MAME's default (active low): English,
// 1 coin 1 credit, demo sounds on, 3 lives, bonus life, medium difficulty.
// The EEPROM games ignore it.
localparam [15:0] DSW = 16'hfffb;

// ================================================================== inputs
//
// The pad bus is on clk_74a. Each button is an independent level, so a
// per-bit synchroniser into the 68000's clock is enough: a press that lands
// one cycle earlier on one bit than another is invisible to a game polling
// at 57 Hz.
//
//   p1/p2 = {b4,b3,b2,b1,right,left,down,up} is exactly key[7:0]:
//   up, down, left, right, A (button 1, shot), B (button 2, bomb), X (button
//   3), Y (button 4, gaia and theroes). Select is the coin, Start is start.
wire [15:0] k1, k2;
synch_3 #(.WIDTH(16)) s_k1 (.i(cont1_key[15:0]), .o(k1), .clk(clk_cpu), .rise(), .fall());
synch_3 #(.WIDTH(16)) s_k2 (.i(cont2_key[15:0]), .o(k2), .clk(clk_cpu), .rise(), .fall());

wire [7:0] in_p1    = k1[7:0];
wire [7:0] in_p2    = k2[7:0];
wire [1:0] in_coin  = {k2[14], k1[14]};
wire [1:0] in_start = {k2[15], k1[15]};

wire test_cpu;
synch_3 s_test (.i(test_opt), .o(test_cpu), .clk(clk_cpu), .rise(), .fall());

// Pause: the game is paused while the Pocket's own menu is open (APF's OS
// notify, host command 0x00B0), and the picture behind the menu is blacked
// out (after the overlay, below).
wire inmenu_cpu, inmenu_vid;
synch_3 s_inmenu_cpu (.i(osnotify_inmenu), .o(inmenu_cpu), .clk(clk_cpu), .rise(), .fall());
synch_3 s_inmenu_vid (.i(osnotify_inmenu), .o(inmenu_vid), .clk(clk_vid), .rise(), .fall());

// ========================================================= ROM -> SDRAM
wire allcomplete_96;
synch_3 s_allc96 (.i(dataslot_allcomplete), .o(allcomplete_96), .clk(clk), .rise(), .fall());

wire              ldr_wr_req, ldr_wr_ack;
wire [SDR_AW:1]   ldr_wr_addr;
wire [15:0]       ldr_wr_din;
wire [1:0]        ldr_wr_be;
wire              dl_wr;
wire [SDR_AW:1]   dl_addr;
wire [15:0]       dl_data;
wire              rom_loaded;
wire              ldr_overflow;

pocket_rom_loader #(.SDR_AW(SDR_AW)) u_loader (
    .clk_74a             (clk_74a),
    .bridge_wr           (bridge_wr),
    .bridge_endian_little(bridge_endian_little),
    .bridge_addr         (bridge_addr),
    .bridge_wr_data      (bridge_wr_data),

    .clk                 (clk),
    .rst                 (rst_por),
    .mem_ready           (mem_ready),
    .allcomplete_s       (allcomplete_96),

    .wr_req              (ldr_wr_req),
    .wr_addr             (ldr_wr_addr),
    .wr_din              (ldr_wr_din),
    .wr_be               (ldr_wr_be),
    .wr_ack              (ldr_wr_ack),

    .dl_wr               (dl_wr),
    .dl_addr             (dl_addr),
    .dl_data             (dl_data),
    .rom_loaded          (rom_loaded),
    .overflow            (ldr_overflow)
);

// ================================================================== SDRAM
//
// kaneko_sdram (alphanu1's, as Mille Miglia has it, with the refresh deferred
// for the layers) behind cave_sdram, which interleaves the banks. It runs on
// clk, the clock the board's memory side runs on, so its ports are the
// board's directly (ACK_HOLD 1). Two Pocket differences, both at the pins:
//
//   - The Pocket's SDRAM has no CS# pin (it is tied active on the board).
//     kaneko_sdram never issues DESELECT — every command it encodes has
//     cs_n = 0 — so dropping sd_cs_n loses nothing.
//   - dram_clk is clk_sdram_ps forwarded through a DDIO output register
//     rather than routed to the pin as a clock.

// Port NP (the last) is the shell's read-back check (DIAGNOSTICS below);
// the board owns 0..NP-1.
wire [NPS-1:0]         rom_req;
wire [NPS*SDR_AW-1:0]  rom_addr;
wire [NPS-1:0]         rom_ack;
wire [NPS*64-1:0]      rom_dout;

// READ CAPTURE DEPTH (kaneko_sdram rd_lat_sel), fixed at CL+2.
//
// kaneko_sdram's encoding is 0 -> CL+1, 1 -> CL+0, 2 -> CL+2, 3 -> CL+3: the
// pin is sampled into dq_r (cap_depth - 1) edges after the READ command.
// CL+2 is what Mille Miglia measured on the Pocket (9 Oct 2026) with this
// controller at this clock and this forwarded 180-degree device clock: CL+3,
// the paper figure, returned the line shifted one word early. The overlay's
// counters 6/7 and flag 7 check it on every frame.
wire [1:0] rd_lat_sel = 2'd2;       // CL+2

wire        sd_cs_n_unused;
wire        sd_dq_oe;
wire [15:0] sd_dq_o;
assign dram_dq = sd_dq_oe ? sd_dq_o : 16'bZ;

cave_sdram #(
    .COL_BITS (SDR_COL),
    .NP       (NPS),
    // The layers' tile reads (ports 2-4) are the only ones with a deadline:
    // the layer processors take their pixels from whatever has come back
    // about 76 clocks after a tile's address (sim/ddonpach). The program,
    // the samples and the sprites wait; so does the read-back check.
    .URGENT   (8'b0001_1100),
    // 8192 rows per 64 ms = one refresh per 7.8 us = 750 cycles at 96 MHz;
    // 700 keeps margin for a refresh deferred behind the layers.
    .T_REFI   (700),
    .REF_DEFER(256),
    // T_RC is what kaneko_sdram waits after AUTO REFRESH, so it must cover
    // tRFC (80 ns for this family): 11 = 115 ns.
    .T_RC     (11),
    // JEDEC power-up: 200 us of NOP before the first command; the init
    // sequence counts down from here and starts at 400, so 25000 is 256 us.
    .INIT_NOP (25000),
    .ACK_HOLD (1)
) u_sdram (
    .clk       (clk),
    .rst_n     (sdram_rst_n),
    .ready     (mem_ready),
    .rd_lat_sel(rd_lat_sel),

    .sd_cke    (dram_cke),
    .sd_cs_n   (sd_cs_n_unused),
    .sd_ras_n  (dram_ras_n),
    .sd_cas_n  (dram_cas_n),
    .sd_we_n   (dram_we_n),
    .sd_ba     (dram_ba),
    .sd_a      (dram_a),
    .sd_dqm    (dram_dqm),
    .sd_dq_o   (sd_dq_o),
    .sd_dq_oe  (sd_dq_oe),
    .sd_dq_i   (dram_dq),

    .wr_req    (ldr_wr_req), .wr_addr(ldr_wr_addr), .wr_din(ldr_wr_din),
    .wr_be     (ldr_wr_be),  .wr_ack (ldr_wr_ack),

    // NOBODY READS SDRAM UNTIL THE ROM IS IN IT: readers running during the
    // download starve the loader's writes. Requesters hold req until
    // acknowledged, so masking here parks them until rom_loaded rises.
    .p_req     (rom_loaded ? rom_req : {NPS{1'b0}}),
    .p_addr    (rom_addr),
    .p_dout    (rom_dout),
    .p_ack     (rom_ack)
);

pin_ddio_clk u_dram_clk (
    .datain_h ( 1'b1 ),
    .datain_l ( 1'b0 ),
    .outclock ( clk_sdram_ps ),
    .dataout  ( dram_clk )
);

// ================================================================== PSRAM
//
// The sprite frame buffer: page 0 on CRAM0, page 1 on CRAM1, a 16-word row at
// a time in synchronous bursts (pocket_psram_rows, which also measures the
// parts' latency at power-up and clears the picture).
wire [1:0]   row_req, row_we, row_ack;
wire [43:0]  row_addr;
wire [255:0] row_wdata;
wire [511:0] row_rdata;
wire [31:0]  row_wmask;
wire [1:0]   ps_ready, ps_fail;
wire [2:0]   ps0_rl, ps0_wl, ps1_rl, ps1_wl;
wire         ps0_rp, ps1_rp;

wire [15:0]  cram0_dq_o, cram1_dq_o;
wire         cram0_dq_oe, cram1_dq_oe;
assign cram0_dq = cram0_dq_oe ? cram0_dq_o : 16'hzzzz;
assign cram1_dq = cram1_dq_oe ? cram1_dq_o : 16'hzzzz;

pocket_psram_rows u_fb0 (
    .clk        (clk),         .rst       (rst_por),
    .req        (row_req[0]),  .we        (row_we[0]),  .addr (row_addr[0 +: 22]),
    .wdata      (row_wdata),   .wmask (row_wmask),
    .ack        (row_ack[0]),  .rdata     (row_rdata[0 +: 256]),
    .ready      (ps_ready[0]), .cal_fail  (ps_fail[0]), .rd_lat (ps0_rl), .rd_ph (ps0_rp), .wr_lat (ps0_wl),
    .cram_a     (cram0_a),     .cram_dq_o (cram0_dq_o), .cram_dq_oe (cram0_dq_oe),
    .cram_dq_i  (cram0_dq),    .cram_clk  (cram0_clk),  .cram_adv_n (cram0_adv_n),
    .cram_cre   (cram0_cre),   .cram_ce0_n(cram0_ce0_n), .cram_ce1_n(cram0_ce1_n),
    .cram_oe_n  (cram0_oe_n),  .cram_we_n (cram0_we_n),
    .cram_ub_n  (cram0_ub_n),  .cram_lb_n (cram0_lb_n)
);

pocket_psram_rows u_fb1 (
    .clk        (clk),         .rst       (rst_por),
    .req        (row_req[1]),  .we        (row_we[1]),  .addr (row_addr[22 +: 22]),
    .wdata      (row_wdata),   .wmask (row_wmask),
    .ack        (row_ack[1]),  .rdata     (row_rdata[256 +: 256]),
    .ready      (ps_ready[1]), .cal_fail  (ps_fail[1]), .rd_lat (ps1_rl), .rd_ph (ps1_rp), .wr_lat (ps1_wl),
    .cram_a     (cram1_a),     .cram_dq_o (cram1_dq_o), .cram_dq_oe (cram1_dq_oe),
    .cram_dq_i  (cram1_dq),    .cram_clk  (cram1_clk),  .cram_adv_n (cram1_adv_n),
    .cram_cre   (cram1_cre),   .cram_ce0_n(cram1_ce0_n), .cram_ce1_n(cram1_ce1_n),
    .cram_oe_n  (cram1_oe_n),  .cram_we_n (cram1_we_n),
    .cram_ub_n  (cram1_ub_n),  .cram_lb_n (cram1_lb_n)
);

// ================================================================= EEPROM
wire [5:0]  nv_addr;
wire [15:0] nv_din, nv_dout;
wire        nv_we, nv_dirty, nv_dirty_clr;

pocket_nvram u_nvram (
    .clk_74a             (clk_74a),
    .bridge_wr           (bridge_wr),
    .bridge_rd           (bridge_rd),
    .bridge_endian_little(bridge_endian_little),
    .bridge_addr         (bridge_addr),
    .bridge_wr_data      (bridge_wr_data),
    .bridge_rd_word      (nv_bridge_rd),
    .clk                 (clk),
    .nv_addr             (nv_addr),
    .nv_din              (nv_din),
    .nv_we               (nv_we),
    .nv_dout             (nv_dout),
    .nv_dirty            (nv_dirty),
    .nv_dirty_clr        (nv_dirty_clr)
);

// ================================================================== board
//
// The 68000 is let go once the image is in the SDRAM and both frame buffer
// chips are ready (they are long before the image has loaded).
wire        ce_pix, hs, vs, hblank, vblank_b, de;
wire [7:0]  r, g, b;
wire [15:0] snd;
wire        snd_sample, snd_overrun, spr_swap, cpu_as;
wire        diag_clr;
wire [15:0] fb_rows_written, fb_rows_read, fb_rd_wait_max;
wire        board_loaded = rom_loaded & (&ps_ready);

cave68000_mem #(.AW(SDR_AW)) u_board (
    .clk        (clk),      .rst     (board_rst),
    .clk_cpu    (clk_cpu),  .rst_cpu (rst_cpu),
    .clk_vid    (clk_vid),  .rst_vid (rst_vid),
    .rom_loaded (board_loaded),
    .game       (game),

    .p1         (in_p1),    .p2      (in_p2),
    .coin       (in_coin),  .start   (in_start),
    .service    (test_cpu),
    .pause      (inmenu_cpu),
    .dsw        (DSW),

    .rom_req    (rom_req[NP-1:0]),
    .rom_addr   (rom_addr[NP*SDR_AW-1:0]),
    .rom_ack    (rom_ack[NP-1:0]),
    .rom_dout   (rom_dout[NP*64-1:0]),

    .row_req    (row_req),  .row_we  (row_we),  .row_addr (row_addr),
    .row_wdata  (row_wdata), .row_wmask (row_wmask),
    .row_ack    (row_ack),  .row_rdata (row_rdata),

    .dl_wr      (dl_wr),    .dl_addr (dl_addr), .dl_data (dl_data),

    .nv_addr    (nv_addr),  .nv_din  (nv_din),  .nv_we   (nv_we),
    .nv_dout    (nv_dout),  .nv_dirty(nv_dirty), .nv_dirty_clr (nv_dirty_clr),

    .ce_pix     (ce_pix),
    .hs         (hs),       .vs      (vs),
    .hblank     (hblank),   .vblank  (vblank_b), .de (de),
    .r          (r),        .g       (g),       .b       (b),

    .snd        (snd),      .snd_sample (snd_sample), .snd_overrun (snd_overrun),

    .spr_swap   (spr_swap),
    .cpu_as     (cpu_as),
    .diag_clr   (diag_clr),
    .fb_rows_written (fb_rows_written),
    .fb_rows_read    (fb_rows_read),
    .fb_rd_wait_max  (fb_rd_wait_max)
);

// ============================================================ DIAGNOSTICS
//
// pocket_diag draws the shell's state over the picture (its header says
// what, where). It is on whenever the menu's "Diagnostic overlay" is, and on
// its own while the ROM is not yet loaded, when colour bars stand in for the
// picture: a core that never gets past loading says so on screen instead of
// staying black.
//
// Flags (left to right, green = 1):
//   0 both PLLs locked      1 SDRAM initialised (mem_ready)
//   2 APF reset released    3 APF "all slots loaded" seen
//   4 rom_loaded            5 loader FIFO overflowed (should stay red)
//   6 board in reset        7 SDRAM read-back of words 0-3 == what was written
//   8 overlay option on     9 blinks about once a second (frame counter)
//   10-12 game id
//   13 frame buffer chip 0 ready and its latencies measured (red: the
//      measurement failed, or it never came up)
//   14 the same for chip 1
//   15 a sound sample came late (the YMZ280B's snd_overrun; should stay red)
//
// Counters (hex):
//   0 high half: frames the 68000 stood still under the Pocket's menu (the
//     menu open and no bus cycle all frame), since the core started;
//     low half: the PSRAMs' measured latencies: chip 1 write, read, chip 0
//     write, read, one digit each (the datasheet says 4); a read digit of 8
//     or more is latency + 8, read at the later capture phase
//     (pocket_psram_rows)
//   1 high half: the longest a layer tile line waited for the SDRAM, request
//     to acknowledge, clocks of 96 MHz (the layers allow ~76 in all);
//     low half: the longest wait of a program line, the same
//   2 high half: the longest a sprite tile line waited; low half: the
//     longest a frame buffer line read waited for its first row
//   3 high half: frame buffer rows written in the last frame; low: rows read
//   4 the longest sprite draw, a page swap to the last row written after it,
//     clocks of 96 MHz (a frame is 1,671,168)
//   5 high half: times the Pocket's menu was opened (APF's OS notify, host
//     command 0x00B0), since the core started; low half: sprite tile lines
//     read from the SDRAM in the last frame
//   6 the 68000's waits in the last frame: clk_cpu clocks its bus cycles
//     held AS beyond a cycle with no wait states (a frame is 557,056)
//   7 the most of those in one frame (a peak)
//
// Peaks and flag 15 hold until the overlay is turned OFF in the menu
// (diag_clr), so the routine is: overlay on to see the baseline, off to
// clear, play until the hitch, overlay on and photograph.
//
// The read-back is port NP of the controller: once per frame, after
// rom_loaded, it reads line 0 (the 68000's reset vector) and flag 7 holds it
// against the loader's copy.
wire        mem_ready_96;
synch_3 s_memrdy96 (.i(mem_ready), .o(mem_ready_96), .clk(clk), .rise(), .fall());
wire        allcomplete_s = allcomplete_96;

reg  [15:0] exp_w0 = 16'd0, exp_w1 = 16'd0, exp_w2 = 16'd0, exp_w3 = 16'd0;
reg         diag_opt_q = 1'b0;
assign      diag_clr = diag_opt_q & ~diag_opt;      // overlay turned off
reg  [NPS-1:0] req_q = {NPS{1'b0}};
reg  [15:0] w_cnt [0:NPS-1];
reg  [15:0] w_layer = 16'd0, w_prog = 16'd0, w_spr = 16'd0;
reg         f_late = 1'b0;
reg  [63:0] rb_line = 64'd0;
reg         rb_req  = 1'b0;
reg  [2:0]  vb_s    = 3'd0;                 // vblank, into clk
reg  [7:0]  frame   = 8'd0;
reg  [2:0]  swap_s  = 3'd0;                 // the page swap (clk_cpu, aligned)
reg  [31:0] since_swap = 32'd0, draw_t = 32'd0, draw_max = 32'd0;
reg  [15:0] rw_q    = 16'd0;
reg  [15:0] rows_w_at = 16'd0, rows_r_at = 16'd0, rows_w_f = 16'd0, rows_r_f = 16'd0;
reg  [15:0] lines_f = 16'd0, lines_n = 16'd0;
reg         late_q  = 1'b0;
wire        rb_ack  = rom_ack[NP];
wire        vb_rise = vb_s[1] & ~vb_s[2];
assign rom_req[NP]  = rb_req;
assign rom_addr[NP*SDR_AW +: SDR_AW] = {SDR_AW{1'b0}};

integer p;
always @(posedge clk) begin
    diag_opt_q <= diag_opt;
    vb_s   <= {vb_s[1:0], vblank_b};
    swap_s <= {swap_s[1:0], spr_swap};
    late_q <= snd_overrun;
    req_q  <= rom_req;

    // request-to-acknowledge waits: a request is a level, raised once per
    // transfer and dropped on its acknowledge
    for (p = 0; p < NPS; p = p + 1)
        if (rom_req[p]) w_cnt[p] <= (rom_req[p] && !req_q[p]) ? 16'd1 : w_cnt[p] + 16'd1;

    if (board_rst || diag_clr) begin
        w_layer <= 16'd0; w_prog <= 16'd0; w_spr <= 16'd0;
        f_late <= 1'b0; draw_max <= 32'd0;
    end else begin
        for (p = 2; p <= 4; p = p + 1)
            if (rom_req[p] && w_cnt[p] > w_layer) w_layer <= w_cnt[p];
        if (rom_req[0] && w_cnt[0] > w_prog) w_prog <= w_cnt[0];
        for (p = 5; p <= 6; p = p + 1)
            if (rom_req[p] && w_cnt[p] > w_spr) w_spr <= w_cnt[p];
        if (late_q) f_late <= 1'b1;
        if (draw_t > draw_max) draw_max <= draw_t;
    end

    // the sprite draw: the time from a swap to the last row written after it
    if (swap_s[1] && !swap_s[2])        since_swap <= 32'd0;
    else if (since_swap != 32'hFFFF_FFFF) since_swap <= since_swap + 32'd1;
    rw_q <= fb_rows_written;
    if (fb_rows_written != rw_q) draw_t <= since_swap;
    lines_n <= lines_n + {15'd0, rom_req[5] & ~req_q[5]} + {15'd0, rom_req[6] & ~req_q[6]};

    if (dl_wr && dl_addr[SDR_AW:3] == {(SDR_AW-2){1'b0}}) begin
        case (dl_addr[2:1])
        2'd0: exp_w0 <= dl_data;
        2'd1: exp_w1 <= dl_data;
        2'd2: exp_w2 <= dl_data;
        2'd3: exp_w3 <= dl_data;
        endcase
    end
    if (vb_rise) begin
        frame     <= frame + 8'd1;
        rows_w_f  <= fb_rows_written - rows_w_at;
        rows_r_f  <= fb_rows_read - rows_r_at;
        rows_w_at <= fb_rows_written;
        rows_r_at <= fb_rows_read;
        lines_f   <= lines_n;
        lines_n   <= {15'd0, rom_req[5] & ~req_q[5]} + {15'd0, rom_req[6] & ~req_q[6]};
    end
    if (rb_req) begin
        if (rb_ack) begin
            rb_req  <= 1'b0;
            rb_line <= rom_dout[NP*64 +: 64];
        end
    end else if (rom_loaded && vb_rise) begin
        rb_req <= 1'b1;
    end
end

// The 68000's waits, on clk_cpu. A bus cycle with no wait states holds AS
// for CPU_AS_ZW clocks of clk_cpu; every clock more is one the 68000 spent
// waiting on its memories (the program behind the SDRAM's cache, above all),
// time the board's own ROMs never cost it, and in a busy scene time the game
// may not have to spare. The menu's count and the frames the 68000 stood
// still under it show whether the pause took.
localparam [5:0] CPU_AS_ZW = 6'd5;

wire        vb_cpu, diag_clr_cpu;
synch_3 s_vb_cpu   (.i(vblank_b), .o(vb_cpu), .clk(clk_cpu), .rise(), .fall());
synch_3 s_diag_cpu (.i(diag_opt), .o(), .clk(clk_cpu), .rise(), .fall(diag_clr_cpu));
reg         vb_cpu_q = 1'b0, inmenu_q = 1'b0, as_seen = 1'b0;
reg  [5:0]  as_len   = 6'd0;
reg  [31:0] cw_n = 32'd0, cw_f = 32'd0, cw_max = 32'd0;
reg  [15:0] menu_opens = 16'd0, menu_frames = 16'd0;
wire        cw_tick = cpu_as && (as_len >= CPU_AS_ZW);

always @(posedge clk_cpu) begin
    vb_cpu_q <= vb_cpu;
    inmenu_q <= inmenu_cpu;
    as_len   <= !cpu_as ? 6'd0 : (as_len == 6'h3f) ? as_len : as_len + 6'd1;
    if (inmenu_cpu && !inmenu_q) menu_opens <= menu_opens + 16'd1;
    if (vb_cpu && !vb_cpu_q) begin
        cw_f    <= cw_n;
        cw_n    <= {31'd0, cw_tick};
        if (cw_n > cw_max) cw_max <= cw_n;
        if (inmenu_cpu && !as_seen && menu_frames != 16'hFFFF) menu_frames <= menu_frames + 16'd1;
        as_seen <= cpu_as;
    end else begin
        if (cw_tick) cw_n <= cw_n + 32'd1;
        if (cpu_as)  as_seen <= 1'b1;
    end
    if (rst_cpu || diag_clr_cpu) cw_max <= 32'd0;
end

wire [63:0] exp_line = {exp_w3, exp_w2, exp_w1, exp_w0};
wire [15:0] diag_flags = {f_late, ps_ready[1] & ~ps_fail[1], ps_ready[0] & ~ps_fail[0],
                          game, frame[5], diag_opt,
                          (rb_line == exp_line), board_rst, ldr_overflow, rom_loaded,
                          allcomplete_s, reset_n_96, mem_ready_96, both_96};
wire [255:0] diag_cnt = {cw_max, cw_f,
                         menu_opens, lines_f,
                         draw_max,
                         rows_w_f, rows_r_f,
                         w_spr, fb_rd_wait_max,
                         w_layer, w_prog,
                         menu_frames, 1'b0, ps1_wl, ps1_rp, ps1_rl, 1'b0, ps0_wl, ps0_rp, ps0_rl};

// Into the video clock for the overlay: values that change a few times a
// frame and are only read off the screen, so a word is let through whole
// once it has held for two clocks (pocket_sync_bus).
wire [15:0]  flags_v;
wire [255:0] cnt_v;
wire         diag_on_v, loaded_v;
pocket_sync_bus #(.W(16 + 256 + 2)) s_diag (
    .clk (clk_vid),
    .d   ({diag_flags, diag_cnt, diag_opt, rom_loaded}),
    .q   ({flags_v,    cnt_v,    diag_on_v, loaded_v})
);

wire [7:0]  dr, dg, db, mr, mg, mb;
pocket_diag u_diag (
    .clk    (clk_vid),
    .ce_pix (ce_pix),
    .hblank (hblank),
    .vblank (vblank_b),
    .r_in   (r), .g_in (g), .b_in (b),
    .enable (diag_on_v | ~loaded_v),
    .bars   (~loaded_v),
    .flags  (flags_v),
    .cnt    (cnt_v),
    .r_out  (dr), .g_out (dg), .b_out (db)
);

// Black behind the Pocket's menu: the game is paused under it.
assign {mr, mg, mb} = inmenu_vid ? 24'd0 : {dr, dg, db};

// ================================================================== video
//
// The scaler mode by game (video.json): 0 the board's 320 x 240 as it is,
// for Uo Poko; 1 the same turned for the vertical games (DoDonPachi, ESP
// Ra.De., Guwange, Fever SOS); 2 the 320 x 224 picture of Gaia Crusaders
// and Thunder Heroes.
wire [2:0] game_v;
pocket_sync_bus #(.W(3)) s_game_v (.clk (clk_vid), .d (game), .q (game_v));
wire [2:0] scaler_slot = (game_v == 3'd6) ? 3'd2 :
                         (game_v == 3'd4) ? 3'd0 : 3'd1;

assign video_rgb_clock    = clk_pix;
assign video_rgb_clock_90 = clk_pix90;

pocket_video u_video (
    .clk       (clk_vid),
    .ce_pix    (ce_pix),
    .hs        (hs),
    .vs        (vs),
    .hblank    (hblank),
    .vblank    (vblank_b),
    .r         (mr),
    .g         (mg),
    .b         (mb),
    .slot      (scaler_slot),
    .clk_vid   (clk_pix),
    .video_rgb (video_rgb),
    .video_de  (video_de),
    .video_hs  (video_hs),
    .video_vs  (video_vs),
    .video_skip(video_skip)
);

// ================================================================== audio
//
// The YMZ280B's mono samples at its own rate (88,200 Hz; 83,333 on gaia and
// theroes) through a low-pass and a 48 kHz resampler on clk_cpu
// (pocket_audio_resample), then to both channels. sound_i2s (agg23, MIT)
// generates MCLK/SCLK/LRCK from clk_74a as Analogue's example does and moves
// each new sample across through a small dcfifo.
wire signed [15:0] snd48;
reg  rate16m = 1'b0;
always @(posedge clk_cpu) rate16m <= (game == 3'd6);

pocket_audio_resample u_resample (
    .clk        (clk_cpu),
    .rst        (rst_cpu),
    .rate16m    (rate16m),
    .in_valid   (snd_sample),
    .in_sample  (snd),
    .out_sample (snd48),
    .out_valid  ()
);

sound_i2s #(
    .CHANNEL_WIDTH(16),
    .SIGNED_INPUT (1)
) u_i2s (
    .clk_74a   (clk_74a),
    .clk_audio (clk_cpu),
    .audio_l   (snd48),
    .audio_r   (snd48),
    .audio_mclk(audio_mclk),
    .audio_lrck(audio_lrck),
    .audio_dac (audio_dac)
);

endmodule

`default_nettype wire
