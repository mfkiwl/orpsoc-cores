//
// Copyright 2011-2015 Jeff Bush
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

`include "defines.sv"

module de2_115_top(
    input                       clk50,

    // Buttons
    input                       reset_btn,    // KEY[0]

    // Der blinkenlights
    output logic[17:0]          red_led,
    output logic[8:0]           green_led,
    output logic[6:0]           hex0,
    output logic[6:0]           hex1,
    output logic[6:0]           hex2,
    output logic[6:0]           hex3,

    // UART
    output                      uart_tx,
    input                       uart_rx,

    // SDRAM
    output                      dram_clk,
    output                      dram_cke,
    output                      dram_cs_n,
    output                      dram_ras_n,
    output                      dram_cas_n,
    output                      dram_we_n,
    output [1:0]                dram_ba,
    output [12:0]               dram_addr,
    output [3:0]                dram_dqm,
    inout [31:0]                dram_dq,

    // VGA
    output [7:0]                vga_r,
    output [7:0]                vga_g,
    output [7:0]                vga_b,
    output                      vga_clk,
    output                      vga_blank_n,
    output                      vga_hs,
    output                      vga_vs,
    output                      vga_sync_n,

    // SD card
    output                      sd_clk,
    inout                       sd_cmd,
    inout[3:0]                  sd_dat,

    // PS/2
    inout                       ps2_clk,
    inout                       ps2_data);

    parameter  bootrom = "../../../software/bootrom/boot.hex";

    localparam BOOT_ROM_BASE = 32'hfffee000;
    localparam UART_BAUD = 921600;
    localparam CLOCK_RATE = 50000000;

    /*AUTOLOGIC*/
    // Beginning of automatic wires (for undeclared instantiated-module outputs)
    logic               perf_dram_page_hit;     // From sdram_controller of sdram_controller.v
    logic               perf_dram_page_miss;    // From sdram_controller of sdram_controller.v
    logic               processor_halt;         // From nyuzi of nyuzi.v
    // End of automatics

    axi4_interface axi_bus_m[1:0]();
    axi4_interface axi_bus_s[1:0]();
    logic reset;
    logic clk;
    io_bus_interface uart_io_bus();
    io_bus_interface sdcard_io_bus();
    io_bus_interface ps2_io_bus();
    io_bus_interface vga_io_bus();
    io_bus_interface nyuzi_io_bus();
    enum logic[1:0] {
        IO_UART,
        IO_SDCARD,
        IO_PS2
    } io_read_source;

    assign clk = clk50;

    nyuzi #(.RESET_PC(BOOT_ROM_BASE)) nyuzi(
        .interrupt_req(0),
        .axi_bus(axi_bus_s[0]),
        .io_bus(nyuzi_io_bus),
        .*);

    axi_interconnect #(.M1_BASE_ADDRESS(BOOT_ROM_BASE)) axi_interconnect(
        .axi_bus_m(axi_bus_m),
        .axi_bus_s(axi_bus_s),
        .*);

    synchronizer reset_synchronizer(
        .clk(clk),
        .reset(0),
        .data_o(reset),
        .data_i(!reset_btn));    // Reset button goes low when pressed

    // Boot ROM.  Execution starts here. The boot ROM path is relative
    // to the directory that the synthesis tool is invoked from (this
    // directory).
    axi_rom #(.FILENAME(bootrom)) boot_rom(
        .axi_bus(axi_bus_m[1]),
        .*);

    sdram_controller #(
        .DATA_WIDTH(32),
        .ROW_ADDR_WIDTH(13),
        .COL_ADDR_WIDTH(10),

        // 50 Mhz = 20ns clock.  Each value is clocks of delay minus one.
        // Timing values based on datasheet for A3V64S40ETP SDRAM parts
        // on the DE2-115 board.
        .T_REFRESH(390),            // 64 ms / 8192 rows = 7.8125 uS
        .T_POWERUP(10000),          // 200 us
        .T_ROW_PRECHARGE(1),        // 21 ns
        .T_AUTO_REFRESH_CYCLE(3),   // 75 ns
        .T_RAS_CAS_DELAY(1),        // 21 ns
        .T_CAS_LATENCY(1)           // 21 ns (2 cycles)
    ) sdram_controller(
        .axi_bus(axi_bus_m[0]),
        .*);

    // We always access the full word width, so hard code these to active (low)
    assign dram_dqm = 4'b0000;

    vga_controller #(.BASE_ADDRESS('h110)) vga_controller(
        .io_bus(vga_io_bus),
        .axi_bus(axi_bus_s[1]),
        .*);

`ifdef WITH_LOGIC_ANALYZER
    logic[87:0] capture_data;
    logic capture_enable;
    logic trigger;
    logic[31:0] event_count;

    assign capture_data = {};
    assign capture_enable = 1;
    assign trigger = event_count == 120;

    logic_analyzer #(.CAPTURE_WIDTH_BITS($bits(capture_data)),
        .CAPTURE_SIZE(128),
        .BAUD_DIVIDE(CLOCK_RATE / UART_BAUD)) logic_analyzer(.*);

    always_ff @(posedge clk, posedge reset)
    begin
        if (reset)
            event_count <= 0;
        else if (capture_enable)
            event_count <= event_count + 1;
    end
`else
    uart #(.BASE_ADDRESS(24), .CLOCKS_PER_BIT(CLOCK_RATE / UART_BAUD)) uart(
        .io_bus(uart_io_bus),
        .*);
`endif

`ifdef BITBANG_SDMMC
    gpio_controller #(.BASE_ADDRESS('h58), .NUM_PINS(6)) gpio_controller(
        .io_bus(sdcard_io_bus),
        .gpio_value({sd_clk, sd_cmd, sd_dat}),
        .*);
`else
    spi_controller #(.BASE_ADDRESS('h44)) spi_controller(
        .io_bus(sdcard_io_bus),
        .spi_clk(sd_clk),
        .spi_cs_n(sd_dat[3]),
        .spi_miso(sd_dat[0]),
        .spi_mosi(sd_cmd),
        .*);
`endif

    ps2_controller #(.BASE_ADDRESS('h38)) ps2_controller(
        .io_bus(ps2_io_bus),
        .*);

    always_ff @(posedge clk, posedge reset)
    begin
        if (reset)
        begin
            red_led <= 0;
            green_led <= 0;
            hex0 <= 7'b1111111;
            hex1 <= 7'b1111111;
            hex2 <= 7'b1111111;
            hex3 <= 7'b1111111;
        end
        else
        begin
            if (nyuzi_io_bus.write_en)
            begin
                case (nyuzi_io_bus.address)
                    'h00: red_led <= nyuzi_io_bus.write_data[17:0];
                    'h04: green_led <= nyuzi_io_bus.write_data[8:0];
                    'h08: hex0 <= nyuzi_io_bus.write_data[6:0];
                    'h0c: hex1 <= nyuzi_io_bus.write_data[6:0];
                    'h10: hex2 <= nyuzi_io_bus.write_data[6:0];
                    'h14: hex3 <= nyuzi_io_bus.write_data[6:0];
                endcase
            end
        end
    end

    assign uart_io_bus.read_en = nyuzi_io_bus.read_en;
    assign uart_io_bus.write_en = nyuzi_io_bus.write_en;
    assign uart_io_bus.write_data = nyuzi_io_bus.write_data;
    assign uart_io_bus.address = nyuzi_io_bus.address;
    assign ps2_io_bus.read_en = nyuzi_io_bus.read_en;
    assign ps2_io_bus.write_en = nyuzi_io_bus.write_en;
    assign ps2_io_bus.write_data = nyuzi_io_bus.write_data;
    assign ps2_io_bus.address = nyuzi_io_bus.address;
    assign sdcard_io_bus.read_en = nyuzi_io_bus.read_en;
    assign sdcard_io_bus.write_en = nyuzi_io_bus.write_en;
    assign sdcard_io_bus.write_data = nyuzi_io_bus.write_data;
    assign sdcard_io_bus.address = nyuzi_io_bus.address;
    assign vga_io_bus.read_en = nyuzi_io_bus.read_en;
    assign vga_io_bus.write_en = nyuzi_io_bus.write_en;
    assign vga_io_bus.write_data = nyuzi_io_bus.write_data;
    assign vga_io_bus.address = nyuzi_io_bus.address;

    always_ff @(posedge clk)
    begin
        case (nyuzi_io_bus.address)
            'h18, 'h1c: io_read_source <= IO_UART;
`ifdef BITBANG_SDMMC
            'h5c: io_read_source <= IO_SDCARD;
`else
            'h48, 'h4c: io_read_source <= IO_SDCARD;
`endif
            'h38, 'h3c: io_read_source <= IO_PS2;
        endcase
    end

    always_comb
    begin
        case (io_read_source)
            IO_UART: nyuzi_io_bus.read_data = uart_io_bus.read_data;
            IO_SDCARD: nyuzi_io_bus.read_data = sdcard_io_bus.read_data;
            IO_PS2: nyuzi_io_bus.read_data = ps2_io_bus.read_data;
            default: nyuzi_io_bus.read_data = 0;
        endcase
    end
endmodule

// Local Variables:
// verilog-library-flags:("-y ../../core" "-y ../../testbench" "-y ../common")
// verilog-auto-inst-param-value: t
// End:
