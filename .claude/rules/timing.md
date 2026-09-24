# Timing rules

Why this file exists: UKNC Nano's three layouts of 2 Sep 2026 behaved
three ways on the board because paths between clocks the tool had not
been told about were placed differently each time.  PK8000 Nano was
clocked the way it is - one clock, everything else a phase of it - so
that that cannot happen, and this design keeps that exactly, at 64.8 MHz
(the AZBK's own 1024x768 pixel clock; ZS-256 Nano's was 42).

## The invariants

- **One internal clock.**  `clk` is the PLL's 64.8 MHz and every flop is
  on it.  The К1801ВМ1's 4.05 MHz is a pair of one-clock enables every
  sixteen clocks (`cpu.v`: positive at 0, negative at 8; every eight in
  turbo); the pixel is the clock itself; the AY's 1.7 MHz is an enable
  every 38; the 44.1 kHz sample is an enable every 1470; the I2S bit
  clock is a registered output toggled by a counter and clocks nothing
  inside the chip.  The PLL's phase-shifted copy goes to the SDRAM pad
  and to nothing else.
- **Two clocks the tool knows about, and no more.**  `bk.sdc` declares
  `clk27` (the crystal), `clk64` (the PLL output, on its pin - the name
  `timing_check.py` requires) and `spi_clk` (the BL616's SPI clock on
  `m0s[3]`, asynchronous, crossed in `mcu_spi.v` by a handshake).  The
  HDMI serial clock (324 MHz) the tool derives itself from the rPLL in
  `hdmi_serdes.v`.  A layout is not accepted while the log carries
  `TA1132` (a clock the SDC did not declare) or `TA1117` (two clocks it
  could not relate).
- **No flop is clocked by a data signal.**  `always @(posedge <thing>)`
  where the thing is a register bit, a pulse, a compare, a counter bit -
  none exist here, and `PR1014` in the log on any net but `m0s[3]`
  (the SPI clock pin) fails the gate.  A slower thing is an enable on
  `clk`.  The VM1 model's two `posedge reset`/`posedge mjres` blocks are
  asynchronous resets of registers on `clk`, which the tool treats as
  such, not as clocks.
- **No false paths, no relaxed constraints, to make a report green.**
  The one `set_clock_groups` is the SPI domain, and the SDC says why.
  A new one needs the same paragraph.

## The gate

`make bitstream` runs `tools/timing_check.py` after place-and-route and
does **not** copy the bitstream to `bin/` if it fails.  `make timing`
runs the check alone on the last report.  It fails on: any setup
violation; any hold violation not excused by name in the script; `TA1132`,
`TA1117`, `TA2000`, `TA2003`, `TA2004` in the log; a `PR1014` beyond the
SPI clock pin; any of the named clocks missing.  The one named exception
is UKNC Nano's (the OSD enable onto a video register's reset pin) and it
may never fire here; if it does, read it before keeping it.

A red gate is information, not an obstacle: it says which path a new
layout would have rolled the dice on.  Fix the path or the constraint,
never the check.

## When adding hardware

1. It goes on `clk`.  If it needs a slower rate, it gets an enable from
   `cpu.v`'s `ce_bus`, the raster's `hcnt` or a counter of its own, and
   a comment saying which.
2. If it talks to the processor, it decodes `sync`/`adr` and answers
   `stb` with a level `ack` and its word on `dout` (zero when not
   addressed - the words are ORed in `top.v`), using `wr_stb`/`rd_stb`
   for side effects.  If it needs the SDRAM, it gets a port of
   `sdram.v`'s arbiter - never a path around it.
3. If it brings its own clock (a card interface, a serial line), that
   clock is a `create_clock` in the SDC, in an asynchronous group, and
   every crossing is a synchroniser or a handshake with a comment at the
   crossing.  Nothing here does this yet; `mcu_spi.v` is the worked
   example.
4. Build.  Read the gate's output, then the clock table in
   `tang/impl/pnr/bk_tr_content.html`: three clocks and the derived
   serial one, nothing else.
5. Only then flash - and say "meets timing", which is a different claim
   from "works".
