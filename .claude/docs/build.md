# Building and flashing

Two binaries, two toolchains.  What ships prebuilt is:

```
bin/tang.fs      the FPGA bitstream   (make bitstream)
bin/bl616.bin    the MCU firmware     (make fw, copied by hand)
```

A user who only wants to run the machine flashes those two, puts the
`soft/azbk/` folder on the card as `/bk/`, and needs no toolchain at
all.  That is the point of committing them.

**Both halves build on this host.**  Everything they need lives under
`tools/`, fetched by `make toolchain` - about 8 GB including Gowin -
nothing is installed on the host and `tools/` is in `.gitignore`.  On
this machine `tools/` was made as hard links into `../tang-zs256/tools/`
(19 Sep 2026), itself hard links through Korvet Nano's into PK8000
Nano's - the same content at no cost in disk; a clone elsewhere runs
`make toolchain`.

```
make toolchain   fetch the toolchain into tools/  (~8 GB, once)
make lint        Verilator over the whole design - the fast check, seconds
make sim         run the machine (RUN_MS=1500; ~10 ms a second)
make frames      the same, writing video frames as .ppm (PPM_FROM=1200)
make wave        the same, dumping a VCD, then open it (WAVE_MS=2)
make bitstream   build the FPGA bitstream -> bin/tang.fs (about a minute)
make timing      the timing gate alone, on the last PnR report
make fw          build the BL616 firmware -> build/fw/bl616.bin
make menu-test   the OSD menu on the host: every form walked, screens as PNG
make az-test     the firmware's ROM load on the host: AZ.INI, FatFs, the pokes checked
make card        stage soft/azbk/ as build/card/bk and say what goes where
make palette     regenerate tang/src/bk/az_palette.v from tools/palette.py
make flash-fpga  openFPGALoader the shipped bitstream to SRAM
make flash-mcu   flash the firmware over UART (COMX=/dev/ttyACM0)
```

`SIMARGS="+CPUTRACE +TRACE_MS=100"` and the like pass plusargs to the
simulator; `sim/tb/tb_top.v`'s header lists them.

## The FPGA half

Toolchain: **Gowin EDA Education edition**, V1.9.11.03, in
`tools/gowin/`.  `make bitstream` drives its headless shell with a Tcl
generated from `tang/bk.gprj` and the IDE's own
`tang/impl/bk_process_config.json` (`tools/gowin_tcl.py`), so the
command line and an IDE build read the same list and options.  The
result is `tang/impl/pnr/bk.fs`, copied to `bin/tang.fs` when the
timing gate passes.  `gw_sh`'s three quirks - its bundled libraries
fight a current Linux, its option names differ from the IDE's, and
`-use_sspi_as_gpio 1` is not optional - are handled by `tools/fetch.sh`
and the Makefile; UKNC Nano's `.claude/docs/build.md` has the account.

The timing gate (`tools/timing_check.py`, `.claude/rules/timing.md`)
wants `clk27`, `clk64` and `spi_clk` in the report, no violations, no
undeclared or unrelated clock.  `../tang-ultima` runs the same two
scripts out of its own build directory (`gowin_tcl.py --abs`,
`timing_check.py <pnr dir>`).

## What lint and simulation cover

`make lint` runs Verilator over exactly the `.gprj`'s list with the
stubs standing in.  It is clean but for warnings, most of them the
MiSTeryNano sources' and the VM1 model's (timescale, unused bits,
widths, the model's multiply-driven `plir`/`mj` bits); any error is
yours.

`make az-test` (`mnano/az_test.c`) is the firmware's side of the boot
on the host: FatFs on an in-memory FAT32 volume filled from
`soft/azbk/` (and `../../soft/azbk/DISKS/dave.img` as `DISKS/DAVE.IMG`) the way the card
is laid out, `az_boot()` run against it, the SYS command 6 stream
checked against the ROM files in a model of the SDRAM, the units
against `AZ.INI`.  `+ROMSPI` on the simulation is the FPGA's side of
the same stream.

`make sim` builds the whole machine into a Verilator binary against a
functional SDRAM model (32 bits wide) and a stand-in BL616 that speaks
the real SPI protocol - the MiSTeryNano targets and the AZ target, on
which it serves the controller's commands from `soft/azbk/` the way
`mnano/azbk.c` does (the unit images `+D0=`..`+D3=`, the EEPROM
`+EEPROM=`, the software clock) - preloads the model with the ROM set
from `soft/azbk/ROM/` at the pages `AZ.INI` gives them (`+ROMDIR=`,
`+NOROM`), and runs the machine.  The testbench's end-of-run lines are
the checks:

```
[tb] config checks: 0 wrong                     the OSD values landed in sysctrl
[tb] cpu: N bus cycles, ... timeouts, vectors   the processor runs; bus errors are counted
[tb] mapper: 177346 .. 177340 .. windows 8-15   what the machine set its mapper to
[tb] video: 177230 .. pages .. 177664           the display registers
[tb] az: N commands (reads, writes, errors)     the controller was used
[tb] read-after-write: N checked, 0 wrong       every SDRAM word read back as written
[tb] sdram self-test: done 1, fail 0, late 0    the controller's own four words
[tb] debug (CMD 7): ...                         the debug window's bytes
[tb] hdmi: ... 0 ecc errors                     the data islands are well formed
[tb] hdmi frame: 1024 x 768                     the raster is what video.md says
```

The SDRAM model is FUNCTIONAL: it tracks rows and serves words, checks
no timing, and drives read data the way the chip does with the
90-degree clock.  Nothing here says anything about the real card, the
real SDRAM pads, the HDMI PHY or a monitor's opinion of the mode.

What the boot looks like in simulation (`progress.md` has the runs):
the processor starts at 70 ms of machine time (the VM1's DCLO and ACLO
timers), AZBOOT beeps for 25 ms and asks the controller for a cold
reset (its first pass sets 177346's bits 8:6), the restart at 180 ms
runs AZBOOT's second pass - the vector table, the screen clear, the
library through TRAP 34 - and the machine's own monitor after it.
`+CPUTRACE` (with `+TRACE_MS=`) prints every bus cycle with its data,
`+IOTRACE` the register accesses, `+AZTRACE` the served commands,
`+MEMTRACE`/`+CYCTRACE=<us>` a memory cycle clock by clock,
`+MAPTRACE` the mapper's control word and the resets, `+RSTTRACE` the
reset chain, `+CORETRACE` the VM1's microcode registers.
`tools/pdp11dis.py` disassembles a ROM to follow a trace.

On this host the simulation runs at about 10 ms of machine time a
second.  Runs are independent: run them in parallel from separate
directories that hold `build/`, `soft/` and `tang/` as symlinks and an
empty `sim/out/`, since the testbench writes its frames to `sim/out/`
relative to where it runs.

## The sound tests

`soft/src/` is five ANDOS programs, one a sound device, so that a
board (or the simulation) can be made to play each device alone and
say on the screen what it is playing: `SPKTEST` (177716's speaker
bits), `AYTEST` (both AYs through 177172/177174), `AY714` (the AY the
BK world's way, through 177714, in three write forms), `COVTEST` (the
Covox registers and the legacy one on 177714), `DMATEST` (the sound
DMA: PCM 16-bit, IMA ADPCM mono and stereo, looping and one-shot, from
pages 400-402 loaded through window 3).  `tools.md` has the details.

```
make soft          assemble them (tools/macro11, fetched by make toolchain)
make soft-image    put them on a copy of WRKANDOS2.IMG: build/SNDTEST.IMG
```

`make card` stages the image as `DISKS/SNDTEST.IMG`; mount it as AZ0
from the OSD (or name it in `AZ.INI`), and at the `A>` line type the
program's name.  In the simulation:

```
build/sim/obj/tb_top +RUN_MS=20000 +NODECODE +D0=build/SNDTEST.IMG \
    +KEYS=20 +TYPE_MS=18000 +TYPE_STR=dmatest +TYPE_DELAY=3000 \
    +WAV=sim/out/dmatest.pcm +WAV_FROM=20000 \
    +VIDEO_PPM +PPM_FROM=17000 +PPM_EVERY=60 +PPM_MAX=40
python3 tools/pcmscan.py sim/out/dmatest.pcm --from 20000
```

(Space at 18 s takes ANDOS off its splash, the name is typed 3 s
later, and `+RUN_MS` counts from that last key, not from power-on, so
20000 ends the run at about 41 s; the frames are the screen once a
second, the scan says what sounds when, on which side, at what
frequency.  About 10 ms of machine time a wall second alone, 4 with
six running at once: two to three hours a program.)  What a run of each showed is in `progress.md`.

## The MCU half

The Bouffalo SDK (`master_legacy`) plus a T-Head RISC-V GCC, both in
`tools/`; `make fw` builds `mnano/` into `build/fw/bl616.bin` and it is
copied on to `bin/` by hand.  The three things UKNC Nano settled to make
that work (the SDK branch, the host-tool patch, the two `-D`s through
`BOARD`) are still in `tools/fetch.sh` and the Makefile and still
needed.  The version in the OSD's caption is the first line of
`VERSION`, read by `mnano/CMakeLists.txt` into `CORE_VERSION`.

## Flashing

**Tang Nano 20K**: `make flash-fpga` (SRAM, gone at power-off) or
`make flash-fpga-flash` (the SPI flash), then **power-cycle the board**
- `openFPGALoader -f -r` writes the flash and reports success but does
not reliably reconfigure the chip.  Once anything has opened
`/dev/ttyUSB*` the next flash fails with `ftdi_usb_reset failed` and
only replugging the cable clears it.  Replug, flash, power-cycle, in
that order.

**BL616**: hold BOOT, tap RESET, release BOOT; the chip enumerates as a
serial port (`/dev/ttyACM0`); `make flash-mcu COMX=/dev/ttyACM0` (needs
`dialout`; `sg dialout -c '...'` works without a relogin).  `BFLB IMG
LOAD HANDSHAKE FAIL` means the port opened and nothing answered: not in
boot mode, or the wrong port.  Press RST afterwards.

## Reading the board

The six LEDs, lit when the thing is true (`top.v`'s last lines; the
board's LEDs are active low and the assignments invert):

```
LED0  the power-on reset has finished (lit 200 ms after the memory is up)
LED1  the AZ controller has a command pending for the MCU
LED2  an SD transfer is busy - or, at boot, the SDRAM self-test chose
      the late capture
LED3  the SDRAM self-test FAILED both captures
LED4  the machine is held in reset
LED5  the SDRAM is initialised
```

A healthy start is LED5 then LED0 coming on, LED4 going out, and 3
dark (2 lit at boot only says the late capture was chosen, which is
fine); the AZ's logo or the machine's monitor is on the screen within
a second of the firmware releasing the reset.  The Debug page's
"act" byte (bits: the memory initialised, its self-test not failed, a
bus cycle in the last 50 ms, an I/O write in the last second, an SPI
byte in the last second, a card read in the last second, the processor
not in reset, a ROM byte in the last second) and its "passes" masks
(the sixteen SDRAM clock phases the self-test passed at, early capture
and late) were a strip of squares in the picture's corner until 23 Sep
2026.  The OSD on F12 says whether the MCU link works, and needs no memory;
its Debug page (`mcu.md`) says whether the memory is up and at which
phase, where the processor is, what the mapper holds, whether the
controller is waiting on the MCU, and whether the ROMs went into the
memory and read back right.

How to read the Debug page when the machine does not boot: 177716's
write side at 0000 with the cycle count moving means the processor
runs but AZBOOT never did - writing 014000 there is its second
instruction (`platform.md`), and 177346 at 0004, 177340 at 8000 and
177230 at 1440 are the reset values that agree; the last cycle's
address at FFCE (177716) is the VM1's HALT flow reading the start
address, i.e. the processor restarting for ever on memory that holds
no ROM.  Then the ROM lines say whether AZ.INI was found and whether
what was sent came back: "NO AZ.INI" is the card's layout
(`/bk/AZ.INI`), "bad" words are the memory.

## The SD card

FAT32.  The firmware reads it through the FPGA's `sd_card.v` and keeps
everything of this machine under `/bk/`: `AZ.INI` (the controller's
configuration - the ROM set, the logo, the disk images, the boot unit),
`ROM/` (the ROM set), `DISKS/` (the images `AZ.INI` names, and any the
OSD mounts), `eeprom.dat` (the controller's settings, written by
SETUP), `bk.ini` (the OSD's settings).  `make card` stages `soft/azbk/`
as `build/card/bk/`.  Under `../tang-ultima` it is the same `/bk/`.
