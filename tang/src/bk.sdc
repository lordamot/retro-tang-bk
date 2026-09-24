//========================================================================
// Timing constraints for bk (BK Nano on the Tang Nano 20K).
//========================================================================
// The design has ONE internal clock, and that is the whole point of its
// clocking: 64.8 MHz out of the PLL, everything on it, the processor's
// clock and the AY's counted as enables of it (top.v).  The HDMI serial
// clock is derived by the tool itself from the rPLL in hdmi_serdes.v
// with this clock as its reference (324 MHz, generated), and the MCU's
// SPI clock is asynchronous to all of it and crosses through the
// handshake in mcu_spi.v.  ZS-256 Nano's three lines, with the period
// changed (.claude/rules/timing.md).
//
// The tool's own derived clock on the PLL pin is replaced by the named
// one below, because timing_check.py wants the name.  Only CLKOUT
// reaches logic; CLKOUTP goes to the SDRAM pad alone.
//========================================================================

create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk27}]
create_clock -name clk64 -period 15.432 -waveform {0 7.716} [get_pins {pll/rpll_inst/CLKOUT}]

//------------------------------------------------------------------------
// The MCU's SPI link.  m0s[3] is the BL616's SPI clock, 20 MHz
// (mnano/spi.c), into a general I/O pin: PR1014 in the log says so and
// timing_check.py knows the net.  Mode 1: the MCU sets up MOSI and reads
// MISO on the FALLING edge, the FPGA shifts MOSI in on the falling edge
// and drives MISO on the rising one.  The delays are the BL616's, not
// measured: 5 ns out, 5 ns of setup, 2 ns of cable each way, as bounds.
//------------------------------------------------------------------------
create_clock -name spi_clk -period 50 -waveform {0 25} [get_ports {m0s[3]}]
set_input_delay  -clock spi_clk -clock_fall -max 7 [get_ports {m0s[1] m0s[2]}]
set_input_delay  -clock spi_clk -clock_fall -min 1 [get_ports {m0s[1] m0s[2]}]
set_output_delay -clock spi_clk -clock_fall -max 7 [get_ports {m0s[0]}]
set_output_delay -clock spi_clk -clock_fall -min -1 [get_ports {m0s[0]}]

// The SPI domain is asynchronous to the board and the crossing in
// mcu_spi.v is a handshake: spi_data_in is written on the SPI edge that
// raises spi_data_in_ready, and clk64 reads it two flops after seeing
// that flag, by which time it has been stable for three SPI bit times.
set_clock_groups -asynchronous -group [get_clocks {spi_clk}] -group [get_clocks {clk27 clk64}]

//------------------------------------------------------------------------
// Left undone, in the order worth doing: set_input_delay/set_output_delay
// on the SDRAM bus (64.8 MHz with a 90-degree output clock: sdram.v's
// header has the arithmetic, the pads are not analysed), and on the
// TMDS pins.
//========================================================================
