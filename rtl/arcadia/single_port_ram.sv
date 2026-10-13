// SPDX-License-Identifier: MIT
// Copyright (c) 2020 Josh Bassett
//
// nullobject's arcadia single_port_ram, the VHDL wrapper round Intel's
// altsyncram, written out in SystemVerilog for this port so one language
// covers synthesis (Quartus) and the harness takes a behavioural model of
// the same name (sim/models/). The generics, ports and altsyncram settings
// are the VHDL's.
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

module single_port_ram #(
  parameter ADDR_WIDTH  = 8,
  parameter DATA_WIDTH  = 8,
  parameter DEPTH       = 0,
  parameter MASK_ENABLE = "FALSE"
) (
  input                       clk,
  input                       rd,
  input                       wr,
  input  [ADDR_WIDTH-1:0]     addr,
  input  [DATA_WIDTH/8-1:0]   mask,
  input  [DATA_WIDTH-1:0]     din,
  output [DATA_WIDTH-1:0]     dout
);
  localparam NUM_WORDS = (DEPTH > 0) ? DEPTH : (1 << ADDR_WIDTH);

  generate
    if (MASK_ENABLE == "TRUE") begin : masked
      altsyncram #(
        .byte_size                     (8),
        .clock_enable_input_a          ("BYPASS"),
        .clock_enable_output_a         ("BYPASS"),
        .intended_device_family        ("Cyclone V"),
        .lpm_hint                      ("ENABLE_RUNTIME_MOD=NO"),
        .lpm_type                      ("altsyncram"),
        .numwords_a                    (NUM_WORDS),
        .operation_mode                ("SINGLE_PORT"),
        .outdata_aclr_a                ("NONE"),
        .outdata_reg_a                 ("UNREGISTERED"),
        .power_up_uninitialized        ("FALSE"),
        .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
        .width_a                       (DATA_WIDTH),
        .width_byteena_a               (DATA_WIDTH/8),
        .widthad_a                     (ADDR_WIDTH)
      ) altsyncram_component (
        .address_a (addr),
        .clock0    (clk),
        .data_a    (din),
        .byteena_a (mask),
        .rden_a    (rd),
        .wren_a    (wr),
        .q_a       (dout),
        .aclr0 (1'b0), .aclr1 (1'b0), .address_b (1'b1), .addressstall_a (1'b0), .addressstall_b (1'b0),
        .byteena_b (1'b1), .clock1 (1'b1), .clocken0 (1'b1), .clocken1 (1'b1), .clocken2 (1'b1), .clocken3 (1'b1),
        .data_b (1'b1), .eccstatus (), .q_b (), .rden_b (1'b1), .wren_b (1'b0)
      );
    end
    else begin : unmasked
      altsyncram #(
        .clock_enable_input_a          ("BYPASS"),
        .clock_enable_output_a         ("BYPASS"),
        .intended_device_family        ("Cyclone V"),
        .lpm_hint                      ("ENABLE_RUNTIME_MOD=NO"),
        .lpm_type                      ("altsyncram"),
        .numwords_a                    (NUM_WORDS),
        .operation_mode                ("SINGLE_PORT"),
        .outdata_aclr_a                ("NONE"),
        .outdata_reg_a                 ("UNREGISTERED"),
        .power_up_uninitialized        ("FALSE"),
        .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
        .width_a                       (DATA_WIDTH),
        .width_byteena_a               (1),
        .widthad_a                     (ADDR_WIDTH)
      ) altsyncram_component (
        .address_a (addr),
        .clock0    (clk),
        .data_a    (din),
        .rden_a    (rd),
        .wren_a    (wr),
        .q_a       (dout),
        .aclr0 (1'b0), .aclr1 (1'b0), .address_b (1'b1), .addressstall_a (1'b0), .addressstall_b (1'b0),
        .byteena_a (1'b1), .byteena_b (1'b1), .clock1 (1'b1), .clocken0 (1'b1), .clocken1 (1'b1), .clocken2 (1'b1), .clocken3 (1'b1),
        .data_b (1'b1), .eccstatus (), .q_b (), .rden_b (1'b1), .wren_b (1'b0)
      );
    end
  endgenerate
endmodule
