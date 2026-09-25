# Progress

What each build showed, what is known not to work, what is next.

## State (19 September 2026, the first day; the board reports below)

(Since then: Dave runs on the board, 23 Sep; the sound plays on the
board, 24 Sep - the sections at the end.  The paragraph below is the
first day's.)

Nothing has been on a board.  Everything below is "builds", "lints",
"simulates" or "meets timing" - never "works".

- **Builds**: `make bitstream` passes the timing gate at 64.8 MHz (Fmax
  67.18 on `clk64`, logic 52% (10703/20736), registers 33%, CLS 71%,
  BSRAM 25/46; the two PR1014 lines are the SPI clock pin and the
  crystal's, as in every sibling); `make fw` builds (442912 bytes);
  `make menu-test` walks the forms with 0 errors; `make lint` is clean
  of errors.  `bin/tang.fs` and `bin/bl616.bin` are that build.
- **Simulates** (`make sim`, the ROM set of `soft/azbk/ROM/`, ANDOS in
  unit 0): the processor starts at 70 ms of machine time; AZBOOT's
  first pass (177346's bits 8:6 clear) beeps 64 times and issues the
  controller's reset; the restart at 180 ms runs the second pass -
  the vector table, the screen clear, the library through TRAP 34 -
  probes the board type by trapping on 177662, and at 335 ms the
  БК-0011М's own monitor draws its "Монитор БК-0011 В1.8" box (the
  legacy 512x256 mode through the AZ's display); AZBOOT then switches
  to the 256-colour mode and by 3.8 s has drawn the AZBK BIOS screen
  ("AZBK Hardware Rev 1.00 BIOS build 330 Firmware HW 18 SW 3.0",
  every line OK, IP/NTP/MAC zeros), and is in its network retries.
  The controller's local commands (RESET, NET, the IP and MAC reads,
  NOP) and the MCU stand-in's time command are exercised; the
  read-after-write check on the SDRAM is clean (58222 words); HDMI
  packets ECC-clean; the frame 1024x768.  Frames: `sim/out/frame_*.ppm`
  of the runs below.
- With the data register held still for a whole read strobe
  (`azctrl.v`; before it every second word of the time buffer was
  skipped and the NTP loop never saw a valid year) the boot goes on:
  the NTP loop ends at its first try with the MCU stand-in's time, the
  BIOS prints the Lan and RTC dates, loads the CMOS block (021/022:
  "load OK"), reads the card's size (056/057: "MicroSD: 15185MB"),
  prints its setup configuration from the EEPROM (BK11M emulation OFF,
  Full AZ Mapper OFF, YM2149, legacy Covox stereo, speaker ON, 48 Hz)
  and at 5.9 s is walking the memory configuration ("000-037k 040-077k
  100-117k 120-137k 140-157k 160k-").
- **ANDOS boots in simulation** (the 14 s run): the memory walk ends,
  AZBOOT selects unit 0 at 9.16 s (command 001, 1600 blocks), reads
  the first 65 blocks of `WRKANDOS2.IMG` through 005/015 (each served
  by the MCU stand-in, none in error), and by 13.8 s ANDOS 3.30 has
  drawn its splash ("Дисковая Операционная Система", the diskette on
  the grid, "Версия 3.30 Copyright 1990-97 А.М.Надёжин, С.Е.Камнев")
  in the legacy 4-colour mode with the 50 Hz interrupt taken every
  frame (191 ticks).  The read-after-write check is clean over 2.8
  million SDRAM words.  71 controller commands in all.
- **Dangerous Dave runs in simulation** (19 Sep, afternoon; the image
  the operator put at `soft/azbk/DISKS/dave.img`, an ANDOS 3.1 disk: ANDOS.SYS,
  DAVE, DAVEDATA.000-027). With `+D0=soft/azbk/DISKS/dave.img`: ANDOS 3.1's
  splash at 21.8 s waits for Space ("ПРОБЕЛ"), Space brings its
  two-panel shell with the `A>` line, `DAVE` and Enter at 26 s starts
  the loader - "AZBK DETECTED, GREAT!", "NVRAM READ OK", "TZ
  UTC+00:00", "ANDOS DETECTED", "LOADING AND UNPACKING DATA..." with a
  progress bar over about 1045 block reads - and from 53 s the game
  itself is on the screen in the 256-colour mode: the GRF Games logo,
  the title picture, the credits with "KT for menu/SPACE to Start" at
  98 s.  `sim/frames/dave-*.png`. Space on the credits and the game
  proper are the run in progress.

- **The ROM path over the link is byte-exact in simulation** (20 Sep):
  `+ROMSPI` sends the whole set (183316 bytes) through SYS CMD 6 as the
  firmware does, the testbench now reads every byte back out of the
  SDRAM model (`verify_image`, 0 wrong), and a 1000 ms run ends in the
  same state as the preloaded one to the bus-cycle counts (`[tb] cpu:`,
  the mapper, the video registers, the debug window).  The first board
  report (20 Sep: "does not start") is therefore not this path.  What
  the simulation cannot see and the board must answer: whether the
  card mounts (the firmware's FatFs has `FF_FS_EXFAT 0` - an exFAT card
  is not read at all, FAT32 only; and the folder must be `/bk/`), the
  MCU link (the OSD on F12), the SDRAM (LED3), and the sink's opinion
  of 1024x768 at 59.8 Hz.  Note that until the firmware's first `R=3`
  the machine runs on an empty SDRAM (`sysctrl.v` resets
  `system_reset` to 0); harmless in simulation, seen only as garbage
  before the logo.

The runs `progress.md` reports:

```
make sim RUN_MS=1000 SIMARGS="+IOTRACE"                          the monitor's box at 0.9 s
make sim RUN_MS=4000 SIMARGS="+AZTRACE +VIDEO_PPM +PPM_FROM=3800" the BIOS screen
make sim RUN_MS=8000 SIMARGS="+AZTRACE +VIDEO_PPM +PPM_FROM=7800" the NTP loop, 16 tries (before the DR fix)
make sim RUN_MS=6000 SIMARGS="+AZTRACE +VIDEO_PPM +PPM_FROM=5800" the BIOS through the CMOS and card size
make sim RUN_MS=14000 SIMARGS="+AZTRACE +VIDEO_PPM +PPM_FROM=13800" ANDOS's splash (about 28 minutes)
build/sim/obj/tb_top +RUN_MS=95000 +NODECODE +D0=soft/azbk/DISKS/dave.img +KEYS=20 +TYPE_MS=22500 \
    +TYPE_STR=dave +TYPE_DELAY=3500 +VIDEO_PPM +PPM_FROM=48000 +PPM_EVERY=300 +PPM_MAX=10
                                                                  Dave's title and credits (about 3.5 hours)
```

A run of that length is best made from a second directory that holds
`build/`, `soft/`, `tang/`, `tools/`, `Makefile`, `sim/tb` and
`sim/stubs` as symlinks and its own `sim/out/` (`../tang-bk-sim2` on
this host), so that two can go at once.

About 8 ms of machine time a wall second (`-O3 -CFLAGS -O2`).

## The second board report (22-23 September 2026), read

The operator's second flash (the 19 Sep `bin/tang.fs`; the firmware
on the board older than `bin/bl616.bin` - its Debug page has a "por"
field the 19 Sep 21:59 `menu.c` no longer prints) gave, with a FAT32
card, the OSD on F12 and LEDs 0, 2 and 5 lit:

```
init 1 por 1 bist 1 fail 0 late 1        the SDRAM initialised, the self-test passed with the late capture
cycle at FFCE, 27624 cycles, 2 resets    the last bus cycle at 177716; the counter runs (mod 65536)
reset 0 init 0 key 0                     the machine is not held
177346 0004 177340 8000                  both at their reset values
177716 0000 177230 1440                  177716's write side never written; the video CSR at reset
AZ: pending 0 done 1 err 0               the controller idle (DONE is its power-up state)
units: /sd/dave.img -                    the OSD's choice at the card's root
```

and the picture: the strip's first row `G G G G R R G R` (memory up,
self-test passed, a bus cycle in the last 50 ms, an I/O write in the
last second, no SPI byte, no card read, not in reset, no ROM byte),
its second row `RRRRR GGG RR GGGGGG` (the self-test passed at phases
5-7 and 10-15; the chosen 12 is the middle of the longer run, with the
late capture), its third `RRRR GGGG` (the last self-test read's low
byte F0, right); the rest of the screen the uninitialised memory in
the reset mode 012100 (1 bit a pixel, doubled: two colours of the
palette's power-up content).  The LEDs agree: 0 = power-on reset
done, 2 = the late capture, 5 = initialised; 3 dark = the self-test
did not fail; 4 dark = not in reset.

What that says: **the processor runs but AZBOOT never did.**  Writing
014000 into 177716 is AZBOOT's second instruction (`platform.md`) and
the write side is 0000; 177346, 177340 and 177230 are at their reset
values; the last cycle's address 177716 is the VM1's HALT flow reading
the start address - the processor restarting for ever (HALT, or a
trap into garbage, then the start address again) on memory that holds
no ROM where it looks.  The two resets are the power-up and the
firmware's `R=3`; AZBOOT's controller reset would be a third.  The
I/O writes are the HALT flow's 177676.  The SDRAM self-test is four
whole words at one row and cannot tell a memory that drops the byte
mask, or a card without `/bk/AZ.INI`, from a good one - and the
firmware's `printf`s go to a serial port nobody read.  So what is not
known is *why* the ROM is not there: the card's layout (`/bk/AZ.INI`
and `/bk/ROM/`; the unit at the card's root suggests the operator's
files are not under `/bk/`), the old firmware, or the memory under
byte-masked writes.

Made for the next flash (23 Sep), so that the board answers that:

- **The firmware reads the ROMs back** over SYS CMD 8 after sending
  them (`sys_peek24`; every word of AZBOOT, one in sixteen of the
  rest, about 0.2 s) and the Debug page's last lines say whether
  AZ.INI was found, how many files went, how many words came back
  wrong and the first wrong one with what was wanted and what came.
  `build.md` ("Reading the board") says how to read the page.
- **The load happens with the machine held in reset** (between
  menu.c's `R=3` and `R=0`, as the simulation always did); before, the
  processor ran on the empty memory while the ROMs arrived.
- **A unit path from the OSD is no longer prefixed**: `az_path()`
  turned the board's `/sd/dave.img` into `/sd/bk/sd/dave.img`
  (`az-test` now mounts an image at the card's root and checks the
  block count).
- **The SDRAM sweep keeps a mask per capture** and chooses the longest
  run of either (one mask could not say which capture 5-7 and 10-15
  belonged to, and the choice could have sat on a capture's edge); the
  strip's third row is now the late mask, the Debug page's "passes"
  line both.  SYS CMD 8 answers a ready byte before the word.
- The testbench sends the ROMs over the link and reads AZBOOT's first
  64 words back over CMD 8 (`+ROMSPI`: 183316 bytes, 0 wrong; 64
  words, 0 wrong, 0 unanswered); the 300 ms run ends where the 19 Sep
  one did (AZBOOT's second pass, 177346 = 000704, 177716 = 014000,
  self-test phase 7 early, masks ffff/0000 against the model).  The
  ten "no acknowledge at 177716 (rd)" lines are in the 19 Sep logs too
  (2472 timeouts in the 14 s run) - AZBOOT's board probe, not new, not
  understood, noted below.
- Builds: `make bitstream` passes the gate - Fmax 65.08 MHz on
  `clk64` at 64.8 (slack 0.067 ns on the VM1's data output through
  the mapper's ROM decode into the controller and the blitter: thin,
  and a path to shorten before anything is added to the bus), logic
  55%, registers 34%, BSRAM 25/46; `make fw` 443568 bytes; `make
  az-test` and `make menu-test` 0 errors; lint clean.  `bin/` is this
  build (0.1.1).  None of it has been on the board.

What the operator is asked for with the next flash: both binaries
(the firmware on the board is not `bin/bl616.bin`); the card's
listing (`/bk/AZ.INI`, `/bk/ROM/`, `/bk/DISKS/`); the Debug page's
ROM lines; the BL616's serial output if a cable is there (`AZ: ...`
lines: "no /sd/bk/AZ.INI", "cannot open", the byte and verify
counts).

## The third and fourth board reports (23 September 2026): the select

With 0.1.1 flashed (both halves, this time by the operator's "flash
companion" / "flash tang" from here) the Debug page said: memory up
(early passes 00E0, late FC00 - the two windows were the two captures
- phase 12 late, the last self-test read F0), ROMs "ini ok, 20 files
179K, 0 missing", "verify 3688 words, 0 bad, 0 unanswered", unit 0
`/sd/bk/DISKS/dave.img` with 1600 blocks; the AZBK BIOS screen drawn;
and then the BK monitor, 177230 = 1481 (the BK's 4-colour mode),
177340 = C000, 177716 = 5802, 177346 = 0184.  The first Debug lines
of the served commands were lost to a bug of mine (`az_boot_line`
formatted every line into one static buffer; the page showed the last
line five times); the second flash of the firmware gave: **"served 28
cmds, 0 rd 0 wr, 0 err", "last 001 001 001 001 blk 0 u1"**.

The cause is in the 337 boot ROM (AZ337, `tools/pdp11dis.py
soft/azbk/ROM/AZ337.ROM 160000 160250`): it writes the unit into the
DR, 001 into the CSR, tests ERR in the very next instruction and goes
on to the block number, 002 and 005 - it never waits for DONE after a
select.  GID's emulator completes the select inside the write.  Ours
sent it to the MCU: a FreeRTOS wake-up and a file open later, the 002
and 005 had arrived while DONE was clear and were dropped (a command
is accepted only with DONE set), the software read an empty buffer,
retried the select, moved to unit 1 and gave up to the monitor.  The
simulation's stand-in answered within the software's dozen
instructions and never showed it.

Fixed in 0.1.2: the select is the FPGA's (`azctrl.v`, local command
001, five clocks), answered from a table of the units' sizes at
buffer word 576 (USIZE) that the firmware writes after AZ.INI and on
every mount and unmount (`az_push_sizes()`); the status's second byte
names the selected unit, and the firmware's read and write open the
file from it.  The testbench's stand-in works the same way (it used to
read the design's DR register directly, so the SPI unit byte was never
proven; now it is).  Lint clean; `make fw` 444720 bytes; `az-test`
(which now also checks the size table goes out with unit 0 = 1600)
and `menu-test` 0 errors; the bitstream meets timing (Fmax 65.32 MHz
on `clk64`, logic 54%, registers 34%, BSRAM 25/46).  The 9.8 s
simulation boots as the 19 Sep one did: the BIOS, then block 0 of
unit 0 at 9.159 s and blocks 12-61 by 9.8 s through the FPGA's own
select and the stand-in's reads of the unit the status byte names (55
commands, 51 block reads, 0 errors; no select reached the stand-in;
config checks 0 wrong; read-after-write 335766 words clean).  The
firmware's serving task also got an 8 KB stack (see the next section).  `bin/` is 0.1.2.  Not yet on the board.

## The fifth board report (23 September 2026): the hang

With 0.1.2 on both halves: the AZBK BIOS, then a hang with a white
square at the top left (the boot's cursor) and **the OSD dead** -
F12 did nothing for five minutes.  The OSD's task shares the SPI bus
with the task that serves the controller (`spi_task`), so that task
holding the bus or the stack-overflow hook stopping the scheduler
takes the OSD with it.  The select had already opened the file from
that task without trouble in 0.1.1, so the read path is the
difference: a seek and a read - and `spi_task`'s stack is the
siblings' 512 words (2 KB), FatFs is built with its 512-byte
long-name buffer on the stack (`FF_USE_LFN 2`), the card layer
printfs a line a sector from the same stack, and no sibling ever ran
FatFs from that task.  Not proven (the board could not be asked);
made for the next firmware: `spi_task` gets 2048 words; the card
layer's two unbounded waits in `sdc_read_sector` (a card that does not
answer spun there for ever with the SPI mutex held) are bounded and
return an error, so a failed read reaches the machine as ERR; the
Debug page shows "sdc timeouts N, read phase P" (1 opening, 2
seeking, 3 reading, 4 sending, 0 done).  `make fw` 445056 bytes, the
host tests clean, `bin/bl616.bin`; flashed from here.  The FPGA
unchanged.

## The sixth board report (23 September 2026): Dave runs, and flashes

With 0.1.2 and the firmware's bigger stack: **ANDOS boots from
`dave.img`, DAVE loads, and the first level plays on the board**
(`soft/current01.jpg`-`current03.jpg`).  The picture flashes at the
frame rate with bands of half-drawn content - other parts of the level,
sprites with streaks - mostly near the top.  Read as the blitter's
automatic run outlasting the vertical blanking: it starts at line 769
and moves a word a memory cycle (a 60 x 60 sprite about 2 ms; a
playfield redraw several), so it is still drawing when the next
frame's fetch begins, and the 60 Hz interrupt fired at line 769
regardless, so the game's handler (page flip, next packet) ran on an
unfinished frame - where GID's emulator executes the packet whole at
the frame's end and interrupts after.

Made (0.1.3): the AZ's 60 Hz interrupt waits for the blitter's run
(`azvideo.v`, `azblit.v`'s `busy`); the strip of squares is out of the
picture (its byte is the Debug page's "act"); the testbench reports
the blitter's runs (count, longest, how many outlast the blanking).
The stand-in checks: lint clean, fw built, host tests clean; the
bitstream and a 4 s boot run were building as this was written, and a
run into the level (112 s of machine time, four hours) is going in
`../tang-bk-sim2` to show the artefact and measure the runs.  Whether
the wait alone cures the flashing is the board's to say: if the game
draws into the displayed page, the drawing shows regardless and the
blitter's speed (32-bit words, bursts) is the next thing.

## The seventh board report (23 September 2026): the fetch

With 0.1.3 (the 60 Hz after the blitter's run) the flashing was "the
same or worse" (`soft/current04.jpg`-`current06.jpg`).  Two of the
photos are the game's static title picture, and against the
simulation's frame of it (`sim/frames/dave-title.png`) they show a
band of vertical stripes some 30 pixels wide at the left edge and a
jagged, "staircase" sky where the simulation's dither is uniform;
the level photos differ between frames in the stairs' rungs and the
bricks at the top-left, with the same left-edge band.  A static
picture rules the blitter out: this is the line fetch.  `azvideo.v`
resets its burst and word counters and switches line buffers at every
line start, but a burst taken just before delivers its remaining
words after the switch; they were written at the new line's first
positions and stepped the word counter, so the line landed one burst
(16 source pixels, 64 on the screen at x4) to the right with the
previous line's last burst at its left - the band, and the stairs
wherever that happened on some lines and not others.  It happens when
the fetch runs close to the line's end, which the processor's cycles
(first in the arbiter) and the late capture (a read is eleven clocks,
not ten) bring about on the board; the simulation's memory model
never ran that late.

Made (0.1.4): a straddling burst's words are drained, not written;
the debug window counts the lines whose fetch did not finish and the
lines a burst straddled (bytes 28-31, the Debug page's "video" line),
so the board can say how often it happens and whether the fetch is
also too slow outright (a short line shows as its tail repeating the
line before).  Lint clean; fw built; host tests clean; the bitstream
meets timing (Fmax 65.38 MHz); the 1 s boot run (`+ROMSPI`) ends as
before - the ROMs over the link and back through CMD 8 with 0 wrong,
config checks 0 wrong, the 256-colour mode at 1 s.  The 60 Hz
wait of 0.1.3 stays: it is GID's order.  Not yet on the board.

## The eighth board report (23 September 2026): the fetch is short

With 0.1.4 (the drain) the title picture was nearly clean and the
game still flashed, and the Debug page said why: **"video: 53341
short lines, 4825 straddled"** - the fetch does not finish most lines,
so a line's tail is the line before's, and the straddles were only
the visible edge of that.  Three layers of whole 512-pixel rows are 96
bursts of eleven clocks (the late capture), with the processor's
cycles ahead of them: more than the line has.

Made (0.1.5): the fetch reads only the visible window of a row - from
the layer's scroll, `1024 >> xs` source pixels' worth of bursts plus
one, wrapping at the row's end - which at the game's x4 is 17 bursts
a layer instead of 32 (`azvideo.v`, `need_bursts`).  The buffer is
indexed by the row's absolute word, so the pixel side is untouched.
Lint clean; the 4 s run to the BIOS screen and the bitstream were
building as this was written.  If the counters still climb, the next
levers are the arbiter (the video ahead of the blitter and the DMA is
already so; ahead of the processor needs a bound on its wait) and the
processor's own bus rate (the missing wait states, defect 1).

## The ninth board report (23 September 2026): the tear

With 0.1.5 the Debug page said "video: 106 short lines, 0 straddled"
over a whole session - the fetch finishes now - and the picture
(`soft/current09.jpg`) is clean except for a horizontal boundary a
third of the way down: above it the wall and the ladder at half
strength, so alternate frames differ there; below it solid.  That is
a tear: the game flips its page in the 60 Hz handler, the interrupt
follows the blitter's run since 0.1.3, the run is some 250 lines (a
scrolling playfield's redraw at a word a cycle is about 6 ms), so the
flip lands there, and the pages are live.  In GID the run is instant
and the flip lands inside the blanking.

Made (0.1.6): under the AZ's 60 Hz mode the pages and horizontal
scrolls are latched at line 768 whatever bit 11 says (`azvideo.v`,
`frame_sync`): a flip is a whole frame later and whole, which is what
GID shows.  A game drawing into the displayed page still shows its
drawing for as long as the run outlasts the blanking; the blitter's
throughput is still the next thing, and the level run in
`../tang-bk-sim2` will say how long the runs are.  Lint clean; the
bitstream and the 4 s run were building as this was written.

## The tenth board report (23 September 2026): a fixed wrong frame

With 0.1.6 (the page latch) the flashing is whole frames now, and the
wrong frame is **the same picture wherever the player is**
(`soft/current10.jpg`, `current11.jpg`): the game's scrolling playfield
alternates with a fixed page - the wallpaper, a window with a face,
the ladder - which does not scroll with the level.  A fixed page the
display alternates with is one of the pages 4 and 034 that a write to
177662 with the BK's screen bit puts into layer 0 (`azvideo.v`,
`wr_662`, unconditionally here), or a page register the game writes
twice a frame.  Not settled: the Debug page gets a "regs" line -
writes since power-up to 177232, 177240/242, 177662, 177664, the
scrolls and 177230, a wrapping byte each (bytes 28-31, 16, 23 of the
debug window) - so two readings a second apart give the rates and
name the register that flaps at the frame rate.  The fetch counters
came out for them.  The VM1 takes IRQ2 once a pulse (it arms on the
low level and fires on the edge, `vm1_qbus_se.sv`), so the 2 ms hold
cannot re-enter a handler; that idea was checked and dropped.

## The eleventh board report (23 September 2026): no register flaps

With 0.1.7 the "regs" line read twice a second apart in the game was
identical: pg0 223, pg12 177, 662 9, 664 13 (the scroll and 177230
counts fell off the 40-column line).  **Not one page or mode write in
a second of play**: the game keeps one set of pages and redraws into
them, and what alternates is the memory's own state - the blit
packet clears the upper layers to the transparent colour and draws
the sky and the objects back, and while it runs the display shows
the wallpaper layer beneath.  MAXIOL's developer notes (thread 5556,
"Блиттер", fetched 23 Sep 2026) say the real hardware is the same
order: "in the frame's blanking a couple of commands with a 3.6-4 KB
sprite fit for certain; for more sprites, buffering is recommended -
display one screen, draw the other, switch"; the blitter has the
lowest memory priority, below the processor, the three layers and the
sound DMA; the automatic run starts at the end of the visible frame;
the recommended technique is to clear a layer and redraw the sprites
in order.  Ours moves a 60x60 sprite in about 0.44 ms - a pair in the
blanking, as theirs.  Dave does not double-buffer; GID executes the
packet whole between two frames, so it never showed.

Then the thread's benchmark images (firmware 18, 22 May 2025, a 60x60
sprite): 2028 fills and 1536 copies a second, 1953 and 1466 with the
layers on.  Ours: a fill in 0.17 ms, a copy in 0.44 ms - **faster
than the real hardware**, whose display costs it only 5%.  So the
speed reading is overturned: a packet the real hardware executes
without visible flicker leaves less of a trace here, not more, and
the operator says the game runs clean on the real hardware.  Either
the packet is small there and something here turns it into a
layer-wide clear, or the flicker is not the blitter's.  The thread's
command format (word 5: the width in words minus one, the rows; word
6: the destination's increment after a row; word 4: the operation
bits) matches GID's, which `azblit.v` follows.

Made (0.1.8): the blitter's runs measured on the board - the run
count, the last run's length and the longest in 64-clock units (a
raster line is 21), the last packet's command count - in the debug
window in place of the phase masks, on the Debug page as "blit: N
runs, last L max M lines, C cmds"; the "regs" line split in two.  A
dozen commands and a few lines acquit the blitter; hundreds and runs
past 37 lines convict the packet.

## The twelfth board report (23 September 2026): the game double-buffers

With 0.1.9, two readings three seconds apart in one session: blitter
runs 204 then 138 (190 in between: one a frame), pg0 writes 39 then 6
(223 in between), pg12 65 then 255 (190), scroll 184 then 52 (124),
the last run 17 lines, and the pages 400/500/2600 in the first
reading, 6500/6600/2600 in the second; the two consecutive frames'
snapshots the same pages both times, and once row0 7 in one frame and
75 in the other.  So: **the game double-buffers** - two sets of pages
for layers 0 and 1, switched live, the hidden set drawn by the
processor (the blit packets are small), the page registers written
every frame and the switch every few frames.  And that convicts the
page latch of 0.1.6: a game that switches live and clears the other
set at once must see its switch applied at once; latched to the next
frame's end, the display kept showing the buffer the game had begun
to clear for up to a frame after every switch - the "fixed wrong
picture" of the tenth report was a just-cleared buffer.  The
interrupt-after-blit of 0.1.3 was the same kind of wrong turn: the
hardware raises the frame interrupt at the frame's end, inside the
blanking, and the game's switch lands there.  Both reverted (0.1.10):
the 60 Hz at line 769, the pages live unless bit 11 - what GID and the
hardware do - now that the fetch faults that confused the earlier
readings (the straddle, the short lines) are gone.  Lint clean; the
bitstream was in its gate as this was written; the firmware unchanged.

## The thirteenth board report (23 September 2026): the 50 Hz timer

With 0.1.10 (the hardware's semantics) the operator's video
(`soft/current1.mp4`) shows a horizontal band of the other page set
moving slowly through the picture, and the two-frame snapshot caught
a switch (frA on 6500/6600, frB on 400/500); 177230 = 869F - mode 7,
three 8-bit layers, 512-pixel rows, x4, bit 11 clear, the pages live.
A band that drifts is a page switch at a raster line that drifts:
the game's handler runs on the "50 Hz" timer, and here that was a
free-running counter at exactly 50 Hz, unrelated to the raster, so
the switch landed at a line moving with the beat between 50 and 59.8
Hz.  The real AZBK's is the "v-sync timer 48Hz" of its BIOS: derived
from the 60 Hz frame, four interrupts in five frames, in the
blanking.  Made (0.1.11): `tick50` is line 769 on four of every five
frames.  Lint clean; the bitstream and a 1 s boot run were building
as this was written; the firmware unchanged.  177346's bits 3 and 2
in the game (asked for) confirm which interrupt it uses.

## The fourteenth board report (23 September 2026): the row count

177346 = 0188 in the game: bit 3 set, bit 2 clear - the game runs on
the AZ's 60 Hz frame interrupt, not the 50 Hz timer, so 0.1.11's
timer change was not its cure (it stays: it is what the hardware
does).  The operator's slowed video (`soft/current2.mp4`, 8x) shows
two complete pictures alternating, no band: one with a brick-wall
texture where the sky should be, the other with the cyan sky, the
tree and the ground the same in both.  Two complete page sets whose
layer-1 content differs: one set never got the sky.  A game that
double-buffers draws the level into both sets once, at the level's
start - the 1416-line run - most cheaply with one big copy per
layer; a layer here is 256 rows (177230's roll of 8), and 256 in a
byte is 0, which `azblit.v` took as "no rows" and skipped
(`if (c_height == 0) st <= S_FETCH`).  The second set's sky layer
kept whatever the memory held.  Made (0.1.12): a row count of 0 is
256 rows.  Lint clean; the bitstream was in its gate as this was
written; the firmware unchanged.  Not proven on the board yet, and
not reproducible in simulation until the level run reaches its
frames (a fresh memory would show the second set's sky as zeros).

## The fifteenth board report (23 September 2026): the pages at 13 MB

The row-count fix changed nothing; the Debug page's write log and
packet did: at raster line 240 the game writes pg2 = 2600, pg1 =
6600, pg0 = 6500, hs1 = 0, vs1 = 96, hs2 = 0, vs2 = 0 (its main loop
switching sets, live), and its per-frame packet clears and redraws
Dave in page 6500 and copies two sprites into 6600 - all into the
set just switched to, so both sets must hold the whole level.  The
largest packet by count (54 commands, a strip of tiles into 6600 at
row 256) was not the level draw.  Then the pages themselves: 6500 and
6600 are 13.3 and 13.5 MB into the AZ's 32 MB, and this board's
SDRAM is 8 MB; the design wrapped the top bits ("2048 pages of the
32 MB's 8192"), and 6600 - 0o4000 = 2600, the backdrop page of layer
2, exactly.  Set B's sky layer and the backdrop were one memory: the
fixed wrong picture, the earlier "other parts of the level", and why
no display change could cure it.  The simulation's level run (the
old design, an empty memory) shows the loading screen's lower half
as overlapping textures the same way.

Made (0.1.15): a page table in `sdram.v` - 8192 pages of 4 KB onto
2048, pages 0-127 one to one, the rest allocated at the first write
from 128 up, reads of unwritten pages zeros, cleared at power-up and
on `cold`; every port and its users widened to the 32 MB (23-bit
32-bit-word addresses: the processor's `mem_word[23:1]`, the display's
`layer_base[23:1]`, the blitter's `a_src/a_dst[23:1]` and its packet
load, the sound DMA's `dma_wadr[23:1]`, the poke's `[23:2]`); the
testbench's read-after-write shadow over the 32 MB; the Debug page's
"pages" count.  A translation costs a cycle two clocks.  The first
build lost ROM bytes in the boot run: the table's clearing sweep at a
cold reset blocked the arbiter for 8192 clocks while the firmware's
bytes arrive over the link every 26 clocks into a 16-deep queue; now
only translated pages wait for the sweep.  Lint clean; the 1 s boot
run clean (the ROMs over the link and back 0 wrong, read-after-write
338399 words 0 wrong, the same state at 1 s); the bitstream meets
timing (Fmax 64.86 MHz - the thinnest yet; logic 58%, BSRAM 35/46).
The 9.8 s ANDOS run boots as before with the table in the path: block
0 of unit 0 at 9.199 s (9.159 before: the translation's cost), 41
block reads by 9.8 s (51 before), 45 commands, 0 errors, config checks
0 wrong, read-after-write 335646 words 0 wrong; the 4 s BIOS run
clean too, the BIOS taking 16 pages.

## The sixteenth board report (23 September 2026): clean, then a stop

With 0.1.15 the picture was clean at last (`soft/current12.jpg`: the
level with no artefact) and the game stopped mid-level with the
processor at 177716 - the HALT loop.  0.1.16 (the pages and wraps on
the Debug page) then gave: pages 1065 of 1920, no wrap - the table
did not run out - and this time a stall at the start with the OSD
frozen for seconds, then play, then a stop with the processor at
0216, a low RAM address: a wait loop, not a crash.  An OSD frozen
for seconds is the serving task holding the SPI bus through its
bounded card waits (one to two seconds a sector that does not come),
so the card path is the suspect: the Debug page's served/error/
timeout lines were asked for.

## Dangerous Dave runs (23 September 2026, evening)

With the page table (0.1.15) the picture was clean; the stops that
followed were the row-count change of 0.1.12 (a command a game
disables by zeroing its rows wrote 256 of them - the blitter's
longest run grew from 1412 lines to 1909 with the same game),
reverted in 0.1.17; the Debug page at a stop had shown the card path
clean (1127 commands, 1105 reads, 0 errors, 0 timeouts) and the
processor in a wait loop.  **With 0.1.17 the game runs on the board:
the level, the player, no flicker, no stop.**  0.1.18 takes the day's
debugging aids out of both halves (the display's write log, the
blitter's packet read and shadow, the counters, SYS 12 and 13); the
bitstream meets timing with room again (Fmax 67.1 MHz, logic 55%,
BSRAM 31/46), the 1 s boot run is clean (the ROMs over the link 0
wrong, config 0 wrong, read-after-write 338399 words 0 wrong), the
firmware built and tested.  Open from the operator: the game's fire
key (the menu is КТ = Esc), and "something happened with sound" -
the symptom asked for.  The simulation's sound output is unchanged
(the ANDOS run: 502725 of 502726 sample frames non-zero).

## Handover (23 September 2026, 22:00)

State: **Dangerous Dave runs on the board** (0.1.17/0.1.18: the level,
the player, no flicker, no stop), flashed as `bin/tang.fs` (SPI
flash) and `bin/bl616.bin`.  Open: (1) the sound is "scratchy noise
instead of game sounds" - the sample DMA, the AYs and the mix were
never verified beyond "not silent"; the two facts asked for (was it
right with the earlier builds; is the title's music right now with
the noise only in-game) split the DMA from the AY path; the testbench
now dumps its output as raw PCM (`+WAV=file +WAV_FROM=ms`, s16le
stereo 44100) and a run to the title with the dump was started and
stopped for the handover - `make sim RUN_MS=58000 SIMARGS="+NODECODE
+D0=soft/azbk/DISKS/dave.img +KEYS=20 +TYPE_MS=22500 +TYPE_STR=dave
+TYPE_DELAY=3500 +WAV=sim/out/title.pcm +WAV_FROM=48000"` (two hours)
gives the waveform to look at.  (2) The game's fire key: the menu is
КТ = Esc; the port's default fire key is unknown.  (3) The Debug page
is back to the machine's state, the page table's count, the units,
the ROM verify and the controller's lines; the day's debug windows
(SYS 12, 13) are out.  (4) Nothing is committed - the whole tree is
untracked since 19 Sep (git.md: ask before committing).  (5) The
operator wants the flash loop automated: the JTAG's "unable to open
ftdi device" after a BL616 flash needs a host udev rule (ModemManager
off the Tang's chip), the BL616's boot mode is hardware; the SRAM
load (`make flash-fpga`) needs no power-cycle.  (6) The simulation's
level run with the old design finished its 16 frames
(`../tang-bk-sim2/sim/out/frame_*.ppm`, the loading screen's aliasing
visible); a run with the page table was not made.

The lessons of the day, all in CLAUDE.md's traps: the memory is 8 MB
against a 32 MB space (the page table); the unit select is the
FPGA's; the fetch's straddle and window; a stand-in faster than the
firmware proves nothing; the row count of 0 is nothing; the 50 Hz is
frame-locked; live pages and the interrupt at line 769 are the
hardware's semantics and the display fixes that departed from them
were wrong turns.

## The sound tests (24 September 2026)

Five ANDOS programs, one a device (`soft/src/`, `make soft-image` ->
`build/SNDTEST.IMG`; `build.md`, `tools.md`), run in the simulation
six at a time (four ms of machine time a wall second with six in
parallel; the runs of 24 Sep typed the name at 21 s and were stopped
at 41 s, every program over by then).  What the
dumps (`+WAV=`, read with `tools/pcmscan.py --skew`) and the screens
showed:

- **The testbench's I2S receiver was a bit early**: at the WS edge it
  took the shift register without the bit on the wire, so every word
  came out shifted right by one with the other side's last bit as its
  sign - a silent machine read as 31238 and a tone as a toggle between
  two values 32767 apart.  That, not the design, is why every dump so
  far "looked like noise"; the sender is standard I2S.  Fixed in
  `tb_top.v`; `pcmscan.py --skew` repairs the old dumps.  The dump's
  rate is 50625 pairs a second (an I2S frame), not 44100.  **Nothing
  here says what the board's noise is.**
- **Silence is a DC of -3060** at the OSD's default volume (-12240 at
  full): the mix centres the AY sum on its mid-scale, and MiSTer's YM
  outputs 0 when silent.  Harmless through a DAC's coupling capacitor
  and the HDMI sink's; it costs a third of the negative headroom.
- **SPKTEST**: a 224 Hz square wave on bit 6 (about 1020 rms at the
  default volume), bit 5 (510) and bit 2 (320) - GID's weights - on
  both sides.  224 Hz for 500 SOB passes a half period says a SOB pass
  is 4.5 us on this processor, not the 2 the programs assumed; the
  sources are recalibrated (`bk.mac`).
- **AYTEST**: chip 1's A on the right, B on both, C on the left, as
  the mix says, each 81% of the window's power; A at 658 Hz because
  the program's period 242 was octal (fixed); then the noise and the
  envelope on A; then chip 2 through 177174 the same way, A on the
  right, B on both.  Both AYs and the mix's sides are right.  (The
  package's own AY_TEST was meant to run beside these and did not: the
  testbench types `_` as a space, so ANDOS got "ay test" and showed
  its shell again.  Its rerun types the codes with `+KEYS2=`.)
- **AY714**: no tone from the BK world's protocol (a word write = the inverted register, a byte write
  = the inverted value), only a shift of the DC.  MiSTer's BK0011M
  (`BK0011M.sv`: `BC(bus_wtbt[1])`, `BDIR(port_write)`,
  `DI(~bus_din[7:0])`) says that protocol is the BK's: the word write
  selects, the low-byte write loads, both from the low byte inverted.
  `azsound.v` decodes the reverse (a high-byte write selects) -
  defect 10.  Form B (the high-byte select, the design's own decode)
  sounded, 658 Hz on the right; form C (the word with bit 14) did not.
- **COVTEST**: the 118 Hz ramp on the left from 177200, on the right
  from 177202, on both from 177204, on the left alone from 177206 as a
  word, on both from 177206 as a byte, on both from 177714 with 177212
  bits 1,0 clear (legacy mono), and on both, the right inverted, with
  bit 0 set (legacy stereo).  (The byte step also wrote 177714 in this
  run, and with the BIOS's "legacy Covox stereo" that put the ramp's
  low byte on the right as a 12 kHz buzz: the program's fault, fixed -
  one register a step.)
- **DMATEST**: the PCM sine at 430 Hz, 99-100% of the power on both
  sides, from page 400 through the page table and window 3; the IMA
  mono sine at 430 Hz from page 401; the IMA stereo with 430 Hz on the
  left and 646 on the right from page 402; the PCM one-shot ends with
  "DONE FLAG SET" and 177160 = 000013; 177170 read 400, 401, 402 while
  each played.  The whole DMA path, as the emulator's software uses
  it, works in simulation.

Afternoon: defects 10 and 11 fixed in `azsound.v` (the 177714 protocol
as MiSTer has it, chip 2 on bit 14 of the word; the AYs through the DC
blocker, silence 0), `make bitstream` passes the gate (0 setup, 0 hold
violations, the two PR1014 lines the SPI clock pin's and the crystal's;
logic 56% (11532/20736), registers 35%, BSRAM 31/46) -> `bin/tang.fs`
12:48; `bin/bl616.bin` is 0.1.19 (the caption only); `make card` stages
`SNDTEST.IMG`.  The six tests rerun on that design with the corrected
receiver from 12:46 (`+RUN_MS=16000`), stopped 15:25 with every
program over.  What they showed, on the design in `bin/tang.fs`:

- Silence is 0 on both sides (a residue of 63 stays on one side after
  a step: the DC blocker's integer leak of y/1024 is nothing below
  1024, a 0.2% dead zone; noted, not changed).
- **SPKTEST**: 504 Hz square waves, bit 6 at 1027 rms, bit 5 at 512,
  bit 2 at 323, all three at 1813 (the sum), the staircase at 126 Hz.
- **AYTEST**: chip 1 A 440 Hz right, B 556 both, C 658 left, the
  chord, the noise (broadband, right), the envelope (440 Hz right
  modulated at ~1.3 Hz); chip 2 the same from 29.5 s.
- **AY714**: form A - the BK world's protocol - A 440 right, B both, C
  left, the chord: **defect 10 is fixed**; form B (the old decode)
  silent; form C (bit 14) plays on chip 2, on the right.
- **COVTEST**: left from 177200, right from 177202, both from 177204,
  the 8-bit word (left, half amplitude), the 8-bit byte (both), the
  legacy mono (both, full); the legacy stereo step was silent because
  the program set 177212 from a clobbered register (bits 3:0 = 1111,
  legacy off): the program's fault, fixed (`LEGACY`), and a unit test
  of `azsound.v` alone (a ramp of word writes to 177714 with 177212 =
  1) puts the ramp on both sides; the rerun of COVTEST alone (15:25,
  the fixed program) played the legacy stereo step on both sides at
  86 Hz, 28.5-29.5 s.  All seven steps right.
- **DMATEST**: as in the morning - PCM, IMA mono, IMA stereo (430
  left, 646 right), the one-shot's DONE, 177170 = 400/401/402.
- The package's AY_TEST (GID's, 2012), rerun with its name typed as
  key codes (`+KEYS2=41595F544553540A +KEYS2_MS=21000`): it runs -
  "Тест1: проверка частотного диапазона. Каналы: A" on screen - and
  sounds from 22 s on through 177714, the BK way: a real BK program's
  AY music on the fixed decode.  (Its sweep leaves B and C at period 0
  with the volume up, so an aliased 20 kHz component sits under the
  sweep; that is the program.)

`bin/bl616.bin` (0.1.19) was flashed to the BL616 at 16:21 (`make
flash-mcu`, verified by SHA); `bin/tang.fs` of 12:48 was written to
the SPI flash at 16:23 (`make flash-fpga-flash`, "Done"; a power-cycle
follows, as `build.md` says).  Its claim before the board speaks:
meets timing, and every sound device plays as the emulator's software
drives it in simulation.

**The board (24 September 2026, 16:30): "sounds are working!
everywhere - in SNDTEST and in dave!"** - the operator, with
`bin/tang.fs` of 12:48 and `bin/bl616.bin` 0.1.19 flashed and
`SNDTEST.IMG` on the card.  Yesterday's "scratchy noise instead of
game sounds" was the 177714 decode (defect 10): Dave's music and
effects drive the AY the BK world's way, through 177714, and every
register write went to the wrong place.  The sound tests and the game
play on the board.  Not yet reported from the board: which of the
five programs' steps sounded as described (the sides, the weights),
the DC blocker's residue, and whether the second AY chip is right
through bit 14 - GID's source still decides that reading.

## F11 holds the machine in reset (24 September 2026, evening)

The operator: "F11 blanks the screen immediately and then OSD works
but even cold reset does not help till tang replug".  F11 is the СБР
(reset) key: the firmware sends flag 3 with a press and again with the
release, and `keyboard.v` keeps it as the level `key_reset`, which
refills `top.v`'s 16 ms reset hold while it is up.  The whole key
event block sat under the `else` of the module's reset - and the
module's reset is the machine's INIT, which the press itself raises.
So the release arrived while the block was disabled, the level never
cleared, the hold never ran out, and the machine sat in reset; the
OSD's cold reset pulses the same hold and cannot clear a level the
keyboard owns.  Fixed: the flagged keys (СТОП, СБР, the hotkeys) are
taken whether or not INIT is up.  The testbench's `+RESETKEY_MS=`
presses and releases the key; the before/after runs are below.

Built 0.1.20: `make bitstream` passes the gate (0 setup, 0 hold;
logic 56%, registers 35%, BSRAM 31/46) -> `bin/tang.fs` 16:50;
`make fw` -> `bin/bl616.bin` 16:53 with the OSD's "Cold reset (AZ)"
entry removed at the operator's request - every reset of this design
is the AZ's cold reset (`top.v`), the two entries did the same thing,
and Reset stays; `make menu-test` walks the ten-entry form with 0
errors.

The reset-key runs (`+RUN_MS=2000 +RESETKEY_MS=2500`, the key pressed
at 2.5 s for 70 ms, a frame at 4.3 s): before the fix the machine
stopped at the press - 583565 bus cycles in 4.57 s, the 2.5 s before
the key, one more reset (3) and a black frame; after it 1018246 cycles,
two more resets (4: the key's, then AZBOOT's own 037 as at power-up)
and the BIOS screen being drawn at 4.3 s.  The hang is reproduced and
gone.  `bin/bl616.bin` 0.1.20 (the menu without "Cold reset (AZ)")
was flashed at 17:16, verified by SHA.

The controller's hotkeys (evening; `mcu.md`): `azvideo.v` takes
keyboard.v's code - АР2+ЛАТ flips the BK's screen between the
monochrome 512 and the colour 256 view, АР2+РУС reloads palette cells
256-337 from the power-up table through `az_palette.v`'s new reload
port.  Checked with `+HOTKEY=n +HOTKEY_MS=345` (the monitor's box on
screen): 1 ms after АР2+ЛАТ 177230 went from 012100 to 012201 (mode 1,
stretch x4); after АР2+РУС two cells spoiled by the testbench (300 =
1234, 337 = 0001) were 0000 and 7fff again.  (A first run sent the key
at 400 ms and AZBOOT's own switch to its 16-colour screen overwrote
the mode within the hold - the check has to land while the legacy
mode is up.)  `make bitstream` 0.1.20 passed the gate (0 setup, 0
hold) at 17:10 and was written to the SPI flash at 17:26 - the F11
fix, the hotkeys and the sound of the morning together.  What the
board shows of F11 and the hotkeys goes here next.

Later: 0.1.21, the firmware only - in РУС the six symbol keys give
their letters (Ъ was untypable), the key map as `keyboard-ru.pdf` /
`keyboard-en.pdf` (`make keyboard`, `tools/keyboard_pdf.py`), the
About page current - flashed to the BL616 at 17:48, verified by SHA.
The FPGA stays at 0.1.20 (17:26).

## MEMTEST clean; the AYs on the Debug page (25 September 2026)

The first MEMTEST was too slow to show anything (a dozen instructions
a word: eight minutes before its first line; the key checked only
between passes); rewritten to three instructions a word, a pass a
minute, dots every 64 pages.  On the board: **thirteen passes, 0
errors** over pages 400-3777 - the processor's path to the SDRAM is
sound, and the memory reading of the night is off the table.

The wall run's full memory dump (`run/davewall3`, 103 s): the in-game
code names no DMA, Covox or AZ AY register (the four 177160 matches
are PC-relative offsets); every game sound is the AY through 177714.
And the state that can outlive a sound is there in the trace: when the
level's jingle ends the engine leaves the mixer at 0 (tone and noise
enabled on all three channels, noise period 0) and relies on the
volumes for silence; an effect that raises a volume without rewriting
the mixer plays with the highest-pitched noise in it - a hump at 5-7.5
kHz after the 0.1.22 filter, which is what `current02.mp4` shows.
Whether that is the engine's own behaviour (then the emulator and a
real BK do it too) or something here leaves the mixer or a volume in
a state the game does not intend, needs the registers on the board.
So 0.1.23 puts them on the Debug page: a shadow of both chips'
sixteen registers in `azsound.v`, a 64-byte debug window, the page
opening with the mixer and volumes decoded.  Unit-tested against
BK-protocol writes to both chips; `make menu-test` clean; `make
bitstream` passes the gate (logic 60% (12419/20736), registers 37%,
BSRAM 32/46).  The testbench still cannot move Dave in the level
(`+SCRIPT` presses reach the keyboard; the game does not walk), so
the bump is the board's to reproduce.  The firmware 0.1.23 was flashed
at 10:26 (SHA verified), the bitstream written to the SPI flash at
10:28.  Its timeout counter no longer
counts the core's own registers (defect 8, closed).

The board with 0.1.23 (10:40): the AY lines read "all zeroes always".
Not the path: the testbench now reads all 64 bytes over the real SPI
protocol and gets both mixers as FF after the boot's reset, as the
shadow holds them.  The page was sampling at the wrong moment - it reads
the window when Debug opens, seconds after F12, by which time the
effect is over and the engine has faded its volumes.  0.1.24 (the
firmware only) reads the window on the menu's show event, the instant
F12 is pressed, and the page shows that snapshot ("F12 AY1 t ABC n
ABC", "v 0 e 0 np 0 env 0") before the live state ("now").  AY2's
mixer should read "t --- n ---" (FF, never written by the game); zeros
there too would mean the bytes are not arriving after all.

The board with 0.1.24 (10:50): at F12 and now alike, AY1 "t ABC n ABC
v 0 e e np 0 env 0", AY2 "t --- n ---" - the bytes arrive (AY2's FF is
the reset value), and AY1 is the engine's resting state: the mixer at
0 (tone and noise enabled everywhere), B and C in envelope mode with
the envelope held at 0, silent.  So the AY holds nothing wrong at rest
and the buzz, if it is the AY, lives only while a sound plays - too
short to catch with a keypress.  The legacy Covox, which this design
feeds from every 177714 write while 177212 bit 1 is clear, was checked
too: rebuilt from the traced refresh writes it makes frame-rate clicks
with half its energy above 10 kHz, not the video's 5-7.5 kHz hump.
0.1.25 adds level meters per source (AY, Covox, speaker, DMA; F12's
0.26 s) and each AY's last sounding state to the Debug page, through
a 128-byte window.  Unit-tested: a tone at volume 12 leaves "snd" with
its registers after the chip goes silent; the Covox meter reads FF
under AY writes with 177212 = 0, the legacy path working as decoded.
`make bitstream` passes the gate (logic 63% (13054/20736), registers
40%, BSRAM 32/46).

The board with 0.1.25 (11:03, `prompts/snd0-3.jpg`): the last sound
AY1 made ("snd") was channel B at a fixed volume of 12 with the mixer
at 0 - tone and noise both enabled on B, the noise at its fastest: an
AY tone gated by noise, the buzz, and the chip playing exactly what it
was told.  The meters read 0 (F12 came after the sound).  The clean
jingle in simulation plays B at volume 12 with B's noise disabled
(mixer 10); so after the bump the mixer the game writes with a sound
has B's noise on.  Photos being "really hard and annoying" (the
operator), 0.1.26 streams the machine's I/O writes to the laptop over
the Tang's own USB serial (`iolog.v`, `tools/iolog.py`, `make log`;
`build.md`).  Tested in simulation end to end (673 records of
AZBOOT's start, none lost, decoded in order) and the AY view on the
wall run's traced writes (the jingle's notes `v 0 12 0 n A-C`, its
end `n ABC v 0 e 0`).  Bitstream through the gate.

## The buzz found (25 September 2026, late morning)

The first board session through the serial log (`build/log/
20260925-112517.bin`, 28 s, 194130 writes, none dropped; the operator
jumping Dave at the house in the last seconds, buzzing): the game
drives nothing but the AY on 177714 (no Covox register, no DMA, no
speaker bit - every 177716 write is the map word 024020), and the AY's
settled states are all clean - the jump is channel B at 11-12 with
its pitch stepping up and B's noise off.  The OSD's "snd" photo had
caught a 30 us transient: the refresh writes the mixer before the
volumes.  So the 4862 sound writes were replayed, at their logged
clocks, into `azsound.v` alone (`tb_replay` in the scratchpad): its
output carried spikes of 13000-16700 on sounds whose clean peak is
1100 - the design's own doing.  With 177212 = 2 (legacy Covox off) the
same stretch peaks at 1441; with the saved setting (1, legacy Covox
stereo) the left channel peaks at 16436 and the right is clean.  The
legacy Covox was playing the AY protocol: the select words' low byte
and the inverted data bytes, eleven a frame during a sound.  AZBOOT
sets 177212 from the saved settings (its only writer, at page 100
offset 5102); the game never touches it; the buzz was there from the
start, on the left, loud when the refresh writes change.

Fixed in 0.1.27: the OSD's Hardware form gains "Covox 177714" ('c'):
Off (default) - 177714 drives the AY alone; "AZ setup" - the old
behaviour.  Replayed: switch off, L peak 1740, R 1143, 0.5% above 5
kHz on both; switch on, L 16436 again.  `make menu-test` clean,
`make bitstream` through the gate (logic 65% (13322/20736), registers
41%, BSRAM 34/46).  What the AY lessons of the two days leave in the
design (the 177714 decode fix, the low-pass before the sampler, the
AY on the Debug page, the serial log) all stays; the 0.1.22 filter was
a real fix to a real alias, only not this buzz.

## The board says it works; the instruments out (25 September 2026)

0.1.27 flashed at 13:21/13:25: "works!" - the jump, the landing and
the bump sound clean.  At the operator's word the OSD's Debug page and
the serial I/O log come out again (0.1.28): the Debug entry, its F12
snapshot, the AY shadow, the level meters, the 64/128-byte window
(SYS CMD 7 back to 32 bytes, read by the testbench's end-of-run
line), `iolog.v`, `tools/iolog.py`, `make log`, the testbench's
`+UARTLOG=`.  The Tang's UART is the core loader's alone again (the
operator has other plans for it).  A short boot in simulation after
the removal: configuration, SDRAM, HDMI and I2S checks as before.
Flashed: the firmware 0.1.28 at 13:31 (SHA verified), the bitstream
(logic 58%, through the gate) to the SPI flash at 13:33.

## What the first boot found (all fixed, all in CLAUDE.md's traps)

1. The VM1's `casex` microcode matrices match nothing in Verilator -
   the processor aborted every microcycle.  Mask-and-value compares.
2. The SDRAM read capture was a clock late against the model
   (`cap0` 3, not 4); the self-test failed and `init` never came.
3. The video port re-requested a burst in flight and had priority:
   the processor starved.  One request at a time; the processor first.
4. An unclaimed window was a hole: AZBOOT's vector-4 store and the
   VM1's HALT-flow write to 177676 looped for ever.  The BK's own
   memory behind unclaimed windows; ROM writes answered and dropped.
5. The fallback page numbers were shifted (`{9'o03, w}` is 014, not
   030); the start address was 174000, not 170000; the mapper's read
   index used bit 6; 177230-177256 were not decoded (the first
   register write after the vector table timed out); the start flag
   cleared at the read's start.  Each one a quiet death two bus cycles
   later, found with `+CPUTRACE` and `tools/pdp11dis.py`.
6. Gowin: `dma_csr` driven from two blocks (EX2000), the buffer and
   palette RAM ports reading and writing in one clock (PA2122), the
   ADPCM decoder at 17.8 ns (72 setup violations).  A flag register, the
   read-or-write port pattern, a three-stage pipeline.

## The landing's buzz (24 September 2026, night)

The operator, with 0.1.20 on the board: a keypress in Dangerous Dave
clicks as it should, but when Dave lands "there is parasite bzzzt
sound, which actually now accompanies all game sounds" until a reset -
"something accumulated and overloaded".  `prompts/current.mp4`'s
sound track: broadband bursts, no period, 5000-6400 peak against a
1500-peak game tone, one at every sound event after the first landing.

The game's in-game sound is the AY the BK world's way (found through
the memory dump of a simulation run - the overlays on the disk are
compressed, so static reading of the files shows only the intro's
DMA): the frame interrupt maps page 703 in at 100000 and calls the
music engine, whose refresh writes registers 0-10 every frame with a
word select and a byte load through R0 = 177714 (`100702`), exactly
the protocol of the afternoon's fix; the simulation plays its tones
cleanly (786, 530, 518 Hz at 71-73 s).  Registers 11-13 stay what the
silence routine (`13302`) left: zero.

The mechanism is not state but aliasing: the YM's channel outputs step
at up to 106 kHz (a period of 1) and the mix sampled them raw at 44.1
kHz, so a short-period tone - inaudible on the chip, and what BK
software leaves on a channel it is not using - comes out as a
full-amplitude broadband hash.  A unit test of `azsound.v` (a
period-1 tone on channel A at volume 15): 3115 peak to peak at the
output, as much as a 440 Hz one (3092).  AY_TEST's run of the
afternoon had shown the same thing as a 20 kHz component under its
sweep, taken then for the program's doing.  Fixed: each side's channel
sum goes through a first-order low-pass at the clock rate (a leaky
integrator of 1/1024 a clock, 10 kHz) and is then averaged over the
sample period (1470 clocks, a box with nulls at the multiples of 44.1
kHz).  Measured: period 1 -> 75, period 2 -> 153, period 4 (13 kHz) ->
635, period 16 (3.3 kHz) 3098 -> 2814, period 242 (440 Hz) 3092 ->
2956.  A second box after the sampler was tried first and did nothing:
the aliasing had already happened.  Built as 0.1.22: `make bitstream`
passes the gate (0 setup, 0 hold; logic 57% (11715/20736), registers
35%, BSRAM 32/46) -> `bin/tang.fs` 21:59; `bin/bl616.bin` 0.1.22 is the
caption only.  The firmware was flashed at 23:01 (SHA verified), the
bitstream written to the SPI flash at 23:04.

**The board with 0.1.22 (23:10): "that does not work"** -
`prompts/current02.mp4`.  And the operator's clarification: the sound
is right at first; the parasite starts when Dave jumps against the
house wall to the upper limit ("when dave cant jump higher") and from
then on rides under every sound; rare wrong frames flash too.  So it is
state after all, set by that one event, and the aliasing fix was
right but beside the point.  What the two videos' sound tracks say
(band energies of a burst): 0.1.20 - 0.1-2.5k 7%, 2.5-5k 19%, 5-7.5k
39%, 7.5-10k 8%, 10-15k 6%, 15-22k 21%; 0.1.22 - 22/20/44/11/2/2%.
Not white noise: a hump at 5-7.5 kHz with the strongest line at
6.9-7.5 kHz in both, and 0.1.22's filter only took the part above 10
kHz.  A tone of period 14-16 on some channel, or the envelope cycling
at 3.3 kHz (its second harmonic) - not the noise generator.

The engine, from the dump: the image it refreshes every frame had
(idle, 80 s) mixer 0 (noise enabled on A, B, C), noise period 0, vol A
0, vol B 0xD0 (envelope mode), vol C 0, B's period 206; the envelope
registers 11-13 are never written by the refresh (registers 0-10 only)
and stay 0 from the silence routine, so B in envelope mode is B held
silent - the model holds shape 0 at 0 as the chip does.  Three effect
slots at 100466/100470/100472 with a priority rule (`100076`); the key
list at 14360: Up (032) is the jump, Space (040) the fire, the letters
E S A D.  The testbench got `+SCRIPT=<file>` (presses and releases at
times, so a key can be held) and a run walks Dave to the house wall
and jumps there twenty times with every sound-register write traced,
the sound dumped and the memory dumped: `run/davewall`, launched
23:21, due about 03:50.  Whether the buzz appears in simulation
decides whether it is the design's or the board's.

(The operator reorganised `soft/` at 19:55: the game image is
`soft/azbk/DISKS/dave.img` now, the media files are gone, the package's
DISKS/ is trimmed and carries `SNDTEST.IMG`.  Every run launched after
that with the old `+D0=soft/dave.img` booted into BASIC for want of a
disk - the game run of 20:46 and the first two wall runs - and their
trace filters had also dropped 177714.  The wall run that counts is
`run/davewall3`, launched 03:22 on the new path with the full filter,
due about 07:30.  `make card` no longer stages the image separately,
`make soft-image` keeps the package's `SNDTEST.IMG` current.)

What `run/davewall3` showed (25 Sep, 07:00, at 86 s of its 103): the
level's jingle from 81.2 to 83.2 s exactly as the engine writes it -
B's period changing note by note (fd, 87, 67, c9, af, ce), its volume
0x0c during a note and 0 between, the mixer 0x10/0x12 (B's tone gated
off between notes) - and after it the engine leaves the mixer at 0
(noise enabled on all three), the noise period 0, B in envelope mode
(0xd0), the envelope at shape 0 held at 0: silence, as in the
simulation's dump of the night.  The jumps and the held Right did
nothing - Dave stands where the level put him at 86 s - so the
testbench's keys are not driving the game the way the board's keyboard
does (the splash's Space and the typed name do work; the game reads
177716 bit 6 for a held key and 177662 through its own vector-60
handler), and the run does not reproduce the bump.  During the whole
window nothing wrote a sound register but the jingle: no DMA, no
speaker, no Covox.  So the buzz the board makes on a landing has no
register write behind it in this design, appears at one game event
and comes with rare wrong frames: that is the game's state or its
register image being corrupted on the board - memory, not sound.
`MEMTEST` is on the test disk for exactly that: pages 400-3777 through
window 3, a pattern a pass, the mismatch count and the first one on
screen.  A count above zero on the board names the SDRAM path (the
capture phase, the late-burst drain) rather than any sound module.
The other reading, a real second-chip write through bit 14 of a
177714 word, is ruled out by the trace: every select the game writes
is 0003xx.

## Defects and open questions

1. **The BIOS reports the processor as "6MHz"** (its timer loop
   measures the bus): the SDRAM answers a cycle in about ten clocks and
   the ВП1-037's wait states are not modelled, so the machine runs
   faster than a real БК-0011М.  Software with timing loops (music,
   games) will run fast.  A wait-state model in `top.v`'s memory path
   (hold `mem_done` to the real cycle length) is the fix; not decided.
   The same loop reports the 50 Hz as 48 Hz.
2. **The network retries take about 1.2 s of machine time** at every
   boot (four DHCP tries of 290 ms); the NTP loop ends at its first
   try because the controller's clock answers (GID does the same).
   That is AZBOOT's behaviour without a cable.
3. Not yet seen: the units table (011 - AZBOOT boots `[BOOT]` without
   it), a block write (006), the joystick, the OSD's unit selection
   through `az_set_unit()`.  (ANDOS's shell, the blitter, the sound
   DMA's PCM and IMA mono, the AYs through 177172/177174, the speaker
   and the Covox have been seen in simulation since; the sound tests
   of 24 Sep.)
4. Dangerous Dave's image (`soft/azbk/DISKS/dave.img`, from hof.maxiol.com after
   registration) is not the package's: it is the operator's copy,
   kept for the simulation.
5. The screenshot command (044) answers ERR; the BK-0010 mode is
   mapped, not tried; the RS-232 has nobody on it.
6. The display is 59.8 Hz, not 60.0; the AZ's 60 Hz interrupt is the
   frame.  Whether a sink takes the mode is a board question.
7. Three layers, the processor and the blitter all busy could exceed
   a line's memory bandwidth (`video.md`); not seen, not proven either.
8. ~~Reads of 177716 time out in simulation~~ - they never did: the
   core answers 177700-177716 itself (`cpu.v`'s `psel`) and the
   testbench's timeout counter only saw the external ack, so every poll
   of 177716 counted (1.47 million in a 103 s game run, 240 a frame;
   the game's vector 4 points at data and is never taken).  The
   counter excludes the core's own registers since 25 Sep 2026.
9. The critical path (slack 0.067 ns at 64.8 MHz) runs from the VM1's
   data output through `azmap.v`'s ROM decode into `azctrl.v` and
   `azblit.v`: the bus's write data fanned into every peripheral's
   decode in one clock.  A register on the data bus, or the decode
   from `sync`'s address a clock earlier, before the next thing lands
   on it.
10. **The AY through 177714 was decoded the wrong way round**
    (`azsound.v`, fixed 24 Sep 2026 afternoon): MiSTer's BK0011M and
    the BK's own software (AY_TEST on WRKANDOS2.IMG) select the
    register with a word write and load it with a low-byte write, both
    inverted from the low byte; the design took a high-byte write as
    the select, so BK-world AY music was silent.  Now as MiSTer has
    it; the chip select is bit 14 of the written word (set: chip 2),
    a reading of GID's `~word & 0140000` that still wants his source.
    Found by the sound tests.
11. The mix's silence was -12240 (a third of the negative headroom):
    the AY sum was centred on a mid-scale the YM never idles at.  Fixed
    24 Sep: the AYs go through the DC blocker with the Covox and the
    speaker, and silence is 0.

## Next

- The game's fire key (the menu is КТ = Esc; the port's default fire
  key is unknown), and the rare wrong frames the operator saw during
  the buzz hunt - not yet looked at.
- The chip select through 177714 bit 14 against GID's source; the DC
  blocker's dead zone (a fractional accumulator); `AZ.INI` names disks
  the trimmed package no longer carries.
- The processor's bus rate (defect 1: no wait states).
- `../tang-ultima`: add the core (`mcu.md`'s last section says what).
- The testbench's scripted keys reach the keyboard but do not move
  Dave in the level - the way into simulating the game's input.
