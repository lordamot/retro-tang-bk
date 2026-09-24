# The FPGA design

One clock, one memory, one bus.  `top.v` instantiates everything;
`tang/bk.gprj` lists every file and is the source of truth for what
is built (`tools/srcs.py` reads it for lint and simulation,
`tools/gowin_tcl.py` for the bitstream).

```
tang/src/
  top.v                the machine: the clock, the resets, the bus, the memory path,
                       the debug window, the LEDs
  sys_pll.v            rPLL: 27 MHz -> 64.8 (IDIV 5, FBDIV 12: VCO 518.4 / 8) and
                       its 90-degree copy for the SDRAM pad
  i2s_tx.v             the I2S output to the dock's DAC
  bk/cpu.v             the К1801ВМ1's glue: enables, the reset sequencer, SEL1/SEL2,
                       the vector interrupt controller, the data-in OR
  bk/vm1/              Vslav's 1801VM1 model in Sorgelig's wrapper (GPL v2)
  bk/sdram.v           the SDRAM controller and arbiter: five ports, refresh, the self-test
  bk/azmap.v           the AZBK mapper (177300-177352, the 177716 and 177130 translation,
                       the fallback to the machine's own memory)
  bk/keyboard.v        177660/177662, the 60/274 vectors, the СТОП and СБР keys
  bk/azvideo.v         the display (video.md): raster, registers, fetch, pipeline, IRQ2
  bk/az_palette.v      the palette RAM with its power-up contents (tools/palette.py)
  bk/azblit.v          the blitter (177270/177272)
  bk/azsound.v         two YM2149s, the Covox, the sound DMA with its ADPCM decoder,
                       the speaker, the mixer
  bk/ym2149.sv         MiSTer's AY/YM
  bk/azctrl.v          the disk controller's registers (177220-177226), its buffer, the
                       local commands, the MCU's SPI target
  bk/azmisc.v          177550 random, 177370 version, 177560-177566 RS-232, 177130/2, 177176
  bk/poke.v            SYS CMD 6/8: the MCU's bytes into the SDRAM (the ROMs), a peek
  mister/              MiSTeryNano's link: mcu_spi.v (five targets), sysctrl.v, hid.v,
                       osd_u8g2.v, sd_card.v (+ sd_rw, sdcmd_ctrl, sector_dpram),
                       flashwr.v and coreload.v (tang-ultima's)
  hdmi/                the HDMI encoder with audio (hdmi_tx, hdmi_packet, tmds_channel,
                       hdmi_serdes)
```

## The clock

`clk` is 64.8 MHz: the VESA 1024x768 pixel clock (65.0 MHz nominal,
64.8 is what 27 x 12 / 5 gives; 59.8 Hz).  Everything is on it.  The
processor takes a positive enable every sixteen clocks and a negative
one eight later (4.05 MHz, the БК-0011М's 4 MHz within a percent; every
eight in turbo, 8.1 MHz); the pixel is the clock; the AY's 1.7 MHz is an
enable every 38; the sound DMA's 44100 Hz is a 24-bit phase
accumulator; the I2S bit clock is a registered output toggled every
twenty clocks (1.62 MHz, 50.6 kHz frames - the DAC does not mind, the
HDMI path resamples to 48 kHz on its own).  The HDMI serial clock (324
MHz) is `hdmi_serdes.v`'s own rPLL.  `timing.md` has the rules.

## The resets

`init` is `sdram.v`'s word that the memory exists (PLL lock, 65536
clocks of settling, the JEDEC steps, the self-test).  The MiSTeryNano
side then counts 2^23 clocks (`mist_rst`, 130 ms); `cpu_rst_req` is
that, or the OSD's reset bit, or a 16 ms hold raised by the
controller's command 037, the OSD's cold reset or the СБР key.  `cold`
is one clock at the rising edge of `cpu_rst_req`: the mapper's
`ResetCold`, the controller's and the blitter's reset.  `cpu.v`'s
`vm1_reset` then holds DCLO for 5 ms and ACLO for 70 ms after the
request drops (MiSTer's widths at this clock), so the processor's
first cycle comes 75 ms after the release, and its RESET instruction
(`cpu_init`) resets the keyboard, the sound and the timer, not the AZ
(which ignores INIT, as GID says).

## The bus

The VM1's Q-bus as `cpu.v` presents it: `sync` with `adr` for the
cycle, `stb` (a level: `din_out` or the two-clock-delayed `dout_out`,
MiSTer's `dout_delay[2]`) with `we` and the byte lanes `wtbt`, `dout`
the processor's word, `din` the OR of every device's word (each drives
zeros when not addressed), `ack` the OR of their levels; `wr_stb` and
`rd_stb` one-clock pulses on the strobe's first clock.  The
acknowledge is registered on the bus enable (`ce_bus_2`), the data-in
a clock later; a cycle nobody acknowledges times out in the processor
after 60 of its clocks (vector 4).  `is_io` is 177000-177777; the
processor's own 177700-177717 answer inside the VM1 (SEL1 and SEL2
with the outside's data through `cpu_psel`).

Device decode: `keyboard.v` 177660/177662; `azvideo.v` 177230-177256,
177662 (write), 177664; `azblit.v` 177270/177272; `azsound.v`
177160-177176, 177200-177212; `azctrl.v` 177220-177226; `azmap.v`
177300-177352 (registered writes on `wr_stb`, reads through
`top.v`'s `sel_mapr`); `azmisc.v` the rest.  A block-style compare
(`adr[15:5] == ...`) has to respect the 32-byte boundaries: 177230-
177256 straddle one (found 19 Sep 2026 - the video registers were not
answered and the first boot died on 177240).

## The memory

One SDRAM, 8 MB, 32 bits wide, behind `sdram.v`: an arbiter with five
ports and a fixed priority - the processor (`c`: one 32-bit word, byte
lanes; the 16-bit word is picked by address bit 1), the video (`v`:
bursts of four words), the sound DMA (`d`), the blitter (`b`), the
MCU's loader (`p`) - and a refresh every 1000 clocks.  A cycle is
ACTIVE, then READ or WRITE with auto-precharge two clocks later; a read
is ten clocks (the words on the bus from the fourth clock, captured
through a registered `dq_in` from the fifth: `cap0 = 3`, or 4 when the
self-test chose the late capture), a write six.  CAS latency 2, burst
length 4, the mode word `0_1_00_010_0_010` (no write burst).  The chip
is clocked by the PLL's phase-shifted copy (`psda`), and the phase is
not fixed: the siblings' 90 degrees failed at 64.8 MHz, so at power-up
the controller sweeps all sixteen phases, at each one re-initialising
the chip and running its self-test (four patterns written and read
back at one row) with the early capture and then with the late one,
and keeps two masks, `ok_early` and `ok_late`, of the phases that
passed.  The longest run of passing phases in either mask decides:
its middle is the phase, its mask the capture (`cap_late`), and the
final initialisation runs the test once more there (falling back to
the other capture once) before `init`.  About 3 ms.  The two masks
are the strip's second and third rows and the debug window's bytes
20-21 and 24-25; the first board (22 Sep 2026) showed two windows,
5-7 and 10-15, in the one mask there was then, and could not say
which capture either belonged to - hence the two.

The processor comes first in the arbiter (19 Sep 2026: with the video
first the processor starved and every cycle timed out - the video's
fetch had re-requested a burst still in flight, and even fixed it has
the whole line for its bursts, the processor a 60-clock timeout).

The physical address: `azmap.v` gives a 13-bit page for the window,
`{page, adr[11:1]}` is the 16-bit word, its bits 21:1 the SDRAM's
32-bit word.  The AZBK's space is 32 MB, 8192 pages of 4 KB; the chip
has 2048, and between them `sdram.v` keeps a page table (23 Sep 2026):
pages 0-127 (the БК's memory, the ROMs, the logo) map one to one, any
other page gets the next free physical page at its first write, in
order from 128 up, and a read of a page never written answers zeros
without a memory cycle.  The table is cleared at power-up and by the
AZ's cold reset (`cold`), a translation costs a cycle two clocks, and
the pages given out (`alloc_next` - 128, of 1920) are on the Debug
page.  Until then the top bits simply wrapped, and Dangerous Dave,
which keeps one of its two page sets at 13 MB, had that set's sky
layer in the same memory as its backdrop: the flickering of the
first level on the board, through nine builds of display fixes.  The
ROMs are at pages 0100-0177 (byte `0x40000 + slot * 4096`), the logo
at page 040 (`0x20000`), the БК's own pages at 0-037: nothing is in
the bitstream, `poke.v` gets it from the MCU at start.

The memory path (`top.v`): a memory access is `is_mem && stb && ok`;
`mem_pend` raises the port's request, `c_take` clears it, `c_ack`
sets `mem_done` (the acknowledge) with the word; a write the mapper
answers but drops (a ROM page) sets `mem_done` at once.

## The controller's MCU side

`azctrl.v` holds the registers and the 8192-word buffer (BSRAM, two
ports: the processor's and the local commands' on A, the MCU's on B;
each port reads or writes in a clock, never both - Gowin's DPB has no
read-old-data mode, PA2122) and does the commands that need no card
itself; the others raise `int_in` bit 4 to the MCU, which serves them
over SPI target 4 (`mcu.md`).  `sd_card.v`'s image slots are unused:
its core-side ports are tied off, it is the MCU's card reader only.

## The debug window

SYS CMD 7 reads 32 bytes of `dbg_bus`: 0 the marker A5; 1 {init,
por}; 2 {late, fail, done} of the memory; 3 the controller's {pending,
done, err}; 4 {reset, init}; 5 a key down; 6-7 the last bus cycle's
address; 8-9 177716's write side; 10-11 177340; 12-13 177230; 14-15
177346; 16 writes to the scrolls; 17 the reset count; 18 the
blitter's runs; 19 and bit 0 of 26 the last packet's command count;
20-21 the last run's length and 24-25 the longest, in 64-clock units;
22 the SDRAM clock phase chosen; 23 writes to 177230; 27 the activity
byte; 28-31 writes to 177232, 177240/242, 177662, 177664 (a wrapping
byte each).  (The phase masks, the cycle count and the self-test's
last byte were here until 23 Sep 2026 and came out for the blitter's
figures once the memory was known good.)  `mcu.md` says how the OSD
shows them.  SYS CMD 8 is
the read back of one 32-bit word (`poke.v`'s peek port): the firmware
verifies the ROMs it loaded through it.

## Resources and timing

`progress.md` carries what each build showed.  The last figures: see
there.  The BSRAM budget: the controller's buffer (8), the blitter's
command buffer (4), the six line buffers (6), the palette (1),
`sd_card.v`'s sector (1), the OSD (1), `flashwr.v`'s (1), the SDRAM's
nothing.
