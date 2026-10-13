// SPDX-License-Identifier: MIT
// Copyright (c) 2020 Josh Bassett
//
// nullobject's arcadia true_dual_port_ram, the VHDL wrapper round Intel's
// altsyncram, written out in SystemVerilog for this port (see
// single_port_ram.sv). Port B may be a different width from port A; the
// narrower port's lower address is the wider word's low bits, as altsyncram
// has it.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

module true_dual_port_ram #(
  parameter ADDR_WIDTH_A = 8,
  parameter ADDR_WIDTH_B = 8,
  parameter DATA_WIDTH_A = 8,
  parameter DATA_WIDTH_B = 8,
  parameter DEPTH_A      = 0,
  parameter DEPTH_B      = 0,
  parameter MASK_ENABLE  = "FALSE"
) (
  input                         clk_a,
  input                         rd_a,
  input                         wr_a,
  input  [ADDR_WIDTH_A-1:0]     addr_a,
  input  [DATA_WIDTH_A/8-1:0]   mask_a,
  input  [DATA_WIDTH_A-1:0]     din_a,
  output [DATA_WIDTH_A-1:0]     dout_a,
  input                         clk_b,
  input                         rd_b,
  input                         wr_b,
  input  [ADDR_WIDTH_B-1:0]     addr_b,
  input  [DATA_WIDTH_B-1:0]     din_b,
  output [DATA_WIDTH_B-1:0]     dout_b
);
  localparam NUM_WORDS_A = (DEPTH_A > 0) ? DEPTH_A : (1 << ADDR_WIDTH_A);
  localparam NUM_WORDS_B = (DEPTH_B > 0) ? DEPTH_B : (1 << ADDR_WIDTH_B);

  generate
    if (MASK_ENABLE == "TRUE") begin : masked
      altsyncram #(
        .address_reg_b                 ("CLOCK1"),
        .byte_size                     (8),
        .clock_enable_input_a          ("BYPASS"),
        .clock_enable_input_b          ("BYPASS"),
        .clock_enable_output_a         ("BYPASS"),
        .clock_enable_output_b         ("BYPASS"),
        .indata_reg_b                  ("CLOCK1"),
        .intended_device_family        ("Cyclone V"),
        .lpm_type                      ("altsyncram"),
        .numwords_a                    (NUM_WORDS_A),
        .numwords_b                    (NUM_WORDS_B),
        .operation_mode                ("BIDIR_DUAL_PORT"),
        .outdata_aclr_a                ("NONE"),
        .outdata_aclr_b                ("NONE"),
        .outdata_reg_a                 ("UNREGISTERED"),
        .outdata_reg_b                 ("UNREGISTERED"),
        .power_up_uninitialized        ("FALSE"),
        .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ"),
        .width_a                       (DATA_WIDTH_A),
        .width_b                       (DATA_WIDTH_B),
        .width_byteena_a               (DATA_WIDTH_A/8),
        .width_byteena_b               (1),
        .widthad_a                     (ADDR_WIDTH_A),
        .widthad_b                     (ADDR_WIDTH_B),
        .wrcontrol_wraddress_reg_b     ("CLOCK1")
      ) altsyncram_component (
        .address_a (addr_a),
        .address_b (addr_b),
        .clock0    (clk_a),
        .clock1    (clk_b),
        .data_a    (din_a),
        .data_b    (din_b),
        .byteena_a (mask_a),
        .rden_a    (rd_a),
        .wren_a    (wr_a),
        .rden_b    (rd_b),
        .wren_b    (wr_b),
        .q_a       (dout_a),
        .q_b       (dout_b),
        .aclr0 (1'b0), .aclr1 (1'b0), .addressstall_a (1'b0), .addressstall_b (1'b0), .byteena_b (1'b1),
        .clocken0 (1'b1), .clocken1 (1'b1), .clocken2 (1'b1), .clocken3 (1'b1), .eccstatus ()
      );
    end
    else begin : unmasked
      altsyncram #(
        .address_reg_b                 ("CLOCK1"),
        .clock_enable_input_a          ("BYPASS"),
        .clock_enable_input_b          ("BYPASS"),
        .clock_enable_output_a         ("BYPASS"),
        .clock_enable_output_b         ("BYPASS"),
        .indata_reg_b                  ("CLOCK1"),
        .intended_device_family        ("Cyclone V"),
        .lpm_type                      ("altsyncram"),
        .numwords_a                    (NUM_WORDS_A),
        .numwords_b                    (NUM_WORDS_B),
        .operation_mode                ("BIDIR_DUAL_PORT"),
        .outdata_aclr_a                ("NONE"),
        .outdata_aclr_b                ("NONE"),
        .outdata_reg_a                 ("UNREGISTERED"),
        .outdata_reg_b                 ("UNREGISTERED"),
        .power_up_uninitialized        ("FALSE"),
        .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ"),
        .width_a                       (DATA_WIDTH_A),
        .width_b                       (DATA_WIDTH_B),
        .width_byteena_a               (1),
        .width_byteena_b               (1),
        .widthad_a                     (ADDR_WIDTH_A),
        .widthad_b                     (ADDR_WIDTH_B),
        .wrcontrol_wraddress_reg_b     ("CLOCK1")
      ) altsyncram_component (
        .address_a (addr_a),
        .address_b (addr_b),
        .clock0    (clk_a),
        .clock1    (clk_b),
        .data_a    (din_a),
        .data_b    (din_b),
        .rden_a    (rd_a),
        .wren_a    (wr_a),
        .rden_b    (rd_b),
        .wren_b    (wr_b),
        .q_a       (dout_a),
        .q_b       (dout_b),
        .aclr0 (1'b0), .aclr1 (1'b0), .addressstall_a (1'b0), .addressstall_b (1'b0), .byteena_a (1'b1), .byteena_b (1'b1),
        .clocken0 (1'b1), .clocken1 (1'b1), .clocken2 (1'b1), .clocken3 (1'b1), .eccstatus ()
      );
    end
  endgenerate
endmodule
