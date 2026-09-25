# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in
this repository.

## Project overview

This is **BK Nano** - the **БК-0011М** (Elektronika's home computer of
1990: a К1801ВМ1 at 4 MHz, 128 KB, BASIC and BOS in ROM) with MAXIOL's
**AZBK** controller as its software sees it - the 32 MB mapper, the
256-colour 1024x768 display with three layers, the blitter, two AYs,
the Covox, the sound DMA, the disk controller on images from an SD card,
the EEPROM, the clock - **without the network** - reimplemented on a
**Tang Nano 20K** (Gowin GW2AR-18C), with a **Bouffalo BL616** board
alongside it providing USB HID, the SD card, the on-screen menu and the
controller's STM32 side.  The aim is that **Dangerous Dave in the
Haunted Mansion** (grf's port for БК0011М+AZBK, 2025) runs.  It is a
sibling of **ZS-256 Nano** (`../tang-zs256`), **Korvet Nano**
(`../tang-korvet`), **PK8000 Nano** (`../tang-pk8000`) and **UKNC Nano**
(`../tang-uknc`): the MiSTeryNano side, the HDMI encoder, the SDRAM
controller's arithmetic, the toolchain, the Makefile and the method are
taken from there, and the machine itself is new.  It is built to be a
core of **Tang Ultima** (`../tang-ultima`), which switches one board
between the machines from the OSD.  Started 19 Sep 2026.

Two halves, two toolchains, and **both build here**:

```
tang/     the FPGA design      - make bitstream  (gw_sh, headless Gowin, ~1 min)
mnano/    the BL616 firmware   - make fw
bin/      the two shipped binaries, both rebuilt from these sources
sim/      testbench, SDRAM model and the stand-ins for the vendor primitives
tools/    the fetched toolchain - make toolchain, ~8 GB, not committed (scripts are)
soft/     soft/azbk/: the AZBK card package - AZ.INI, the ROM set, the disk images;
          soft/src/: the sound tests, one ANDOS program a device (make soft-image)
```

`make lint` and `make sim` are the cheap checks; `make bitstream` is the
real one.  `make help` lists the rest.  **What cannot be done here is
running it on a board.  Nothing has been on a board yet.**  See
`.claude/docs/progress.md` for what each build showed; anything built is
untested on the board until it says otherwise there.  So "it builds",
"it lints", "it boots in simulation" and "it meets timing" are four
different claims, none of them is "it works", and you should say which
one you are making.

The machine, as implemented: Vslav's 1801VM1 on a 64.8 MHz clock with
its processor clock as enables (4.05 MHz, 8.1 in turbo); one SDRAM
behind a five-port arbiter holding the BK's memory, the controller's,
the ROM set (loaded from the card by the firmware) and the free 8 MB;
the AZ mapper with the BK's own memory behind the windows it does not
claim; the display fetched line by line into BSRAM and drawn at
1024x768 over HDMI; the blitter and the sound DMA on their own memory
ports; the controller's commands split between the FPGA (the pointers,
the buffer, the clock reads, the network stubs) and the MCU (the card,
the clock, the ini); the keyboard from USB as КОИ-7 codes with the
РУС/ЛАТ state on the MCU.

Key documentation: `.claude/docs/platform.md` (the machine: every
register, the mapper, the start address, the HALT flow, where the facts
come from), `.claude/docs/fpga.md` (the implementation: the clock, the
bus, the memory, the files), `.claude/docs/video.md` (the display),
`.claude/docs/mcu.md` (the firmware, the keymap, the menu letters, the
controller's MCU side), `.claude/docs/build.md` (both toolchains, the
Makefile, what lint and simulation cover, flashing, reading the board),
`.claude/docs/tools.md` (`tools/` and `soft/azbk/`),
`.claude/docs/progress.md` (state, defects, what is next).  Follow
`.claude/rules/guideline.md`, `.claude/rules/git.md` and
`.claude/rules/timing.md`.

## Traps worth remembering

- **`tang/bk.gprj` is the source of truth for what gets built.**  Every
  file under `tang/src/` is in it and every module in it is
  instantiated; keep it that way.  `tools/srcs.py` reads it for lint
  and sim, `tools/gowin_tcl.py` for the bitstream.
- **There is one clock, and everything is a phase of it.**  `clk` is
  64.8 MHz; the processor's clock is `cpu.v`'s enables, `hcnt`/`vcnt`
  the raster.  Do not add a clock, a divided clock, or a flop clocked
  by a data signal; every memory access goes through `sdram.v`'s
  arbiter.
- **The VM1 model's microcode matrices are mask-and-value compares
  here, not `casex`.**  Vslav's `vm1_plm.v` compares a function
  argument holding x bits; a two-state simulator matches nothing and
  the processor aborts every microcycle (the first evening).  The
  rewrite synthesises to the same logic; do not put the `casex` back.
- **The processor comes first in the SDRAM arbiter, the video second.**
  With the video first the processor starved (every cycle timed out);
  the video fetch has the whole line for its bursts.  `azvideo.v`'s
  fetch raises one request at a time (`inflight`).
- **A window the AZ does not claim is the BK's own memory**, not a
  hole: pages 030-033 under 0-37777, the 177716 page under 40000-77777
  and 100000-137777, the 324/325 ROM pages under 140000-177777, and a
  write into ROM is answered and dropped.  AZBOOT's first instruction
  after the stack pointer stores vector 4 while window 0 is still off,
  and the VM1's HALT flow writes 177676; without the fallback both
  loop forever.  `platform.md`.
- **The start address is 170000 only until the processor has read
  it.**  `azmap.v`'s `sel1` is set by a cold reset and cleared at the
  end of the first read of 177716; after that 177716 reads as 140000
  or 100000 (GID's `AZ_716_Out`).  Clear it at the read's start and the
  word changes under the read: the machine starts at 100000.
- **AZBOOT's first pass ends in a controller reset on purpose**: it
  beeps 64 times and issues command 037 when 177346's bits 8:6 are
  zero; the second pass boots.  The 037 goes through `rst_hold` to
  `cpu_rst_req`, and `cold` (its rising edge) is the mapper's
  `ResetCold`, which keeps those bits.  Two resets at power-up are
  normal; four are the check failing.
- **Block-style address compares must respect 32-byte boundaries**:
  177230-177256 straddle one (`azvideo.v` indexes from 177200); the
  mapper's read index is `adr[5:1]`, not `adr[6:1]` (177300's own bit
  6 is set).  Both were found by the first boot dying quietly.
- **Gowin's DPB has no read-old-data write mode (PA2122)** and its
  synthesis refuses a register driven from two always blocks (EX2000).
  An inferred RAM port here reads or writes in a clock, never both
  (`if (we) mem[a] <= d; else q <= mem[a];`), and a flag two blocks
  want is two registers ORed on the read (`azsound.v`'s `dma_done`).
- **The ADPCM decoder is a three-clock pipeline** (`azsound.v`): the
  table lookup, three adds and a clamp in one clock was 17.8 ns at a
  15.4 ns period.  A sample is every 1470 clocks; there is no hurry.
- **The ROMs are not in the bitstream.**  The firmware reads
  `/bk/AZ.INI` and sends each `Rnn=` file to SDRAM byte `0x40000 +
  nn*4096` and the logo to `0x20000` over SYS CMD 6 (three address
  bytes) between menu.c's `R=3` and `R=0`, so the machine is held in
  reset meanwhile, and reads them back over CMD 8 (all of AZBOOT, one
  word in sixteen of the rest) - the counts go to the firmware's
  serial log (the OSD's Debug page that also showed them went in 0.1.28).  The simulation preloads the SDRAM model from `soft/azbk/ROM/`
  (`+ROMDIR=`, `+NOROM`; `+ROMSPI` sends them over the link instead).
  No ROM set, no machine: a processor that runs with 177716's write
  side at 0000 (AZBOOT's second instruction writes 014000 there) and
  its last cycle at 177716 is restarting for ever on memory without
  one (`build.md`).
- **The AZBK's space is 32 MB and the chip has 8: `sdram.v` maps
  pages.**  Pages 0-127 are one to one, the rest are given physical
  pages at their first write, reads of unwritten pages are zeros, the
  table is cleared by the AZ's cold reset.  Before it the top bits
  wrapped, and Dangerous Dave's page set at 13 MB (pages 6500/6600)
  landed on its own backdrop (page 2600): a whole day of display
  fixes chased that.  A page above 0o3777 with the old wrap was the
  tell (the Debug page that showed a game's pages went in 0.1.28).
- **A display line's fetch can straddle the line's end** when the
  processor keeps the memory busy, and the burst's late words must be
  dropped, not written at the next line's start (`azvideo.v`'s
  `drain`; the first board: a flickering band at the left, lines
  shifted by a burst).  The simulation's memory model is ideal and
  never ran that late; a board shows it as a band at the left edge
  (the Debug page's counter of it went in 0.1.28).
- **The unit select (001) is the FPGA's, not the MCU's.**  AZ337's
  boot code writes 001 and goes straight on to 002 and 005 without
  waiting for DONE; a command written while DONE is clear is dropped.
  Served over the link the select was still pending, the 002/005 fell
  on the floor and the board sat in the BK monitor ("served 28 cmds, 0
  rd, last 001 001 001 001").  `azctrl.v` answers it from the size
  table the firmware keeps at USIZE (`az_push_sizes()`); the status's
  second byte names the unit for a read.  The simulation's stand-in
  answered within the software's dozen instructions and hid it - a
  stand-in that answers faster than the firmware can proves nothing
  about a command the software does not wait for.
- **A unit path from the OSD is already `/sd/...`** and `az_path()`
  leaves it alone; only AZ.INI's `0:/x` and `x` forms get `/sd/bk/`
  in front.  The first board's unit 0 was `/sd/bk/sd/dave.img`.
- **The SDRAM clock phase is swept at power-up**, each of the sixteen
  with both captures, into two masks (`ok_early`, `ok_late`: the
  strip's second and third rows; SYS CMD 7's bytes 20-21 and 24-25); the
  middle of the longest run of either is the phase and capture.  The
  first board passed at 5-7 and 10-15 and chose 12 late.
- **The firmware's core id is 10** (`CORE_ID_BK`), and every table the
  firmware selects by core is indexed by it - `settings_file[]`,
  `keymap[]`, `modifier[]`, `core_names[]`.  A menu value is three
  edits: the letter in the form string, `variables_bk[]`, and
  `sysctrl.v`.  'R' is a button whose value 3 is also the AZ's cold
  reset; 'S' is Save.  The AZ units are not `sd_card.v` slots: the OSD's
  file selector calls `az_set_unit()`.
- **`hdmi_tx.v` sends THREE packets an island here** (the back porch
  is 160 clocks) and `ACR_CTS` is 64800 for exactly 48 kHz.  Changing
  the raster's blanking means checking `DI_PKTS` against it.
- **The display is 1024x768 at 59.8 Hz** (64.8 MHz, not the CEA 65.0),
  a VESA mode within a percent.  Whether a given sink takes this is a
  board question, and a black screen on a board is that before it is
  anything else.
- **`tools/` on this host is hard links into `../tang-zs256/tools/`**
  (through Korvet Nano's and PK8000 Nano's).  Same files, same inodes;
  an in-place edit to one is an edit to all.  Nothing in `tools/` is
  edited in place - a new toolchain version is a fresh fetch.
- **Flashing the FPGA is replug, flash, power-cycle - in that order**,
  and the BL616 must be in boot mode (hold BOOT, tap RESET, release
  BOOT).  `.claude/docs/build.md`.
- **The network is deliberately absent.**  AZBOOT retries its DHCP
  four times with a 290 ms delay each (about 1.2 s of machine time)
  before it goes on, and its NTP loop (up to sixteen tries) ends at the
  first because the controller's clock answers with a valid year; that
  is the ROM's behaviour without a cable, not a defect.  The HOF
  commands answer "no connection".
- **`soft/azbk/DISKS/dave.img` is the operator's copy of Dangerous Dave** (an ANDOS
  3.1 disk: `DAVE` is started from the shell's `A>` line after Space
  on the splash). A run to its credits is 95 s of machine time, about
  3.5 hours; `+NODECODE` and a second run directory (`build.md`) make
  that bearable.
- **177714 is one port with two devices on it: the AY and the legacy
  Covox.**  Fed both, an AY game's register writes play through the
  Covox as a buzz (Dave, 24-25 Sep: two days of wrong theories).  The
  OSD's "Covox 177714" gates the Covox off by default.  What found it
  was the board's I/O writes, logged over the Tang's UART and replayed
  into `azsound.v` alone (0.1.26-0.1.27, removed again in 0.1.28; git
  history has it) - worth rebuilding the next time a board symptom
  resists photos.
- **The AY's outputs must be filtered before they are sampled.**  The
  YM steps at up to 106 kHz and the mix samples at 44.1 kHz; taken raw,
  a period-1 tone - what a game leaves on an unused channel - is a
  full-amplitude hash (Dave's landing, 24 Sep: "bzzzt" until reset).
  `azsound.v` low-passes at the clock rate and box-averages over the
  sample period; a filter after the sampler cannot help.
- **A key that causes a reset must be handled during the reset.**
  `keyboard.v`'s СБР level is set by the press and cleared by the
  release; its event block once sat under `else` of the module's reset,
  which is INIT, which the press raises - so the release was dropped and
  F11 held the board in reset until a replug (24 Sep).  Anything that
  drives the reset chain is taken outside the reset clause.
- **The AY on 177714 is the BK's protocol, not the AZ's**: a word write
  selects the register, a byte write loads it, both inverted from the
  low byte (MiSTer's BK0011M, the package's AY_TEST).  Decoded the
  other way round it is silent and nothing else tells you; `soft/src/`'s
  AY714 plays each form and says which sounded.
- **An ANDOS program is headerless and its load address is the
  directory entry's time field** (1000 for DAVE and every utility,
  30000 for Dave's data files): `tools/andosput.py` writes it there,
  `tools/binlink.py` makes the file, and macro11 opens an `.INCLUDE`
  relative to its working directory, so `make soft` assembles in
  `build/soft/`.  `tools.md`.
- **`prompts/` is a transcript, not context.**  Never read it at the
  start of a session; append every exchange as it finishes, in the form
  `.claude/rules/guideline.md` gives.
