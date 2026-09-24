# Work guideline

## General

All discussions in english.
All code except text strings must be in english.  Russian appears in
comments only where it is the machine's own name for a thing (БК-0011М,
К1801ВМ1, ПЗУ, СТОП, АР2) - the forum threads and the emulator's
sources are Russian and a register is easier to find under its own name.

## Project

Never work outside the repository root - except to READ the four
siblings (`../tang-zs256`, `../tang-korvet`, `../tang-pk8000`,
`../tang-uknc`) and the mothership (`../tang-ultima`), whose method this
repository follows and whose firmware must be able to carry this core.
Nothing there is edited from here.

All of this repository builds here.  The MCU firmware with `make fw`, the
bitstream with `make bitstream` - Gowin's headless `gw_sh`, fetched into
`tools/` along with everything else by `make toolchain`, none of it
installed on the host and none of it committed.  The design also lints and
simulates, and the simulation runs the AZBK's boot ROM and the
БК-0011М's own.

What still cannot be done here is **running it on a board**.  So say which
claim you are making: built, linted, simulated and timed are four
different things and none of them is "works".  **Never imply a bitstream
was tested.**  `.claude/docs/progress.md` carries what each flash showed
and must keep doing so; until it says a build booted, none has.

If something else needs to be installed onto the host system - ask for it.
Nothing goes outside `tools/` without asking.  The operator will do it or
suggest another solution.

Any problem like "the board would have to be watched but can't be" - ask
before researching it yourself.

## Where the machine's facts come from

What this repository builds against, in order of authority:

1. **GID's BKemu, v4.6 sources** (`BK/devemu/AZBK/*.cpp`, `AZBK.cpp`,
   `BK0011M.cpp`, `CPU.cpp`) - the emulator the AZBK's software,
   Dangerous Dave included, is developed and tested on.  It is the
   authority on what the software sees: every register's read and
   write, the mapper's three-step 177716 and 177130 translation, the
   blitter's operations, the sound DMA's formats, the controller
   protocol's buffer layout, the palette, the start address, what a
   reset keeps.  `platform.md` cites the file and function for each.
2. **MAXIOL's descriptions on forum.maxiol.com** - the AZ V2 memory
   model, the disk controller's protocol (thread 5388), the firmware
   changelog (5553), the developer notes (5556) - for the register map
   and the intent behind it, and for the STM's command set.
3. **The MiSTer BK0011M core** (Sorgelig; Vslav's 1801VM1) for the
   processor, its bus timing, the SEL1/SEL2 registers and the 60/274
   keyboard vectors; **MiST's `keyboard.sv`** for the key codes.
4. **The four siblings' docs** for everything about the framework: the
   MiSTeryNano link, the HDMI encoder, the SDRAM controller's
   arithmetic, the toolchain.

Where they disagree the emulator wins on behaviour (that is what the
game was proven on) and the forum on intent, and `platform.md` says
where that happened.  A change to a register's meaning cites one of them
or a measurement; "it seems to work" is not a source.

## Editing RTL

- **`tang/bk.gprj` is the source of truth for what is built.**  Every
  file under `tang/src/` is in it and every module in it is
  instantiated.  A new file goes into the `.gprj` or it does not go into
  `tang/src/`; a module that stops being instantiated comes out of both,
  and earlier revisions live in git history, not beside the live file.
- Two files are hand-written instantiations of Gowin primitives and are
  stubbed in simulation: `src/sys_pll.v` (rPLL) and
  `src/hdmi/hdmi_serdes.v` (rPLL, OSER10, ELVDS_OBUF).
  `src/mister/sector_dpram.v` is IP Core Generator output for a DPB and
  `sd_card.v` carries its own model of it under `ifdef VERILATOR`.
  `tools/srcs.py` knows them all; a new one goes into its `STUBBED`
  list with a model in `sim/stubs/gowin_ip_sim.v`.
- `src/bk/vm1/` is Vslav's 1801VM1 in Sorgelig's wrapper, GPL v2, with
  one change: the microcode matrices' `casex` compares are mask-and-value
  compares (`vm1_plm.v`'s head says why - a two-state simulator cannot
  match an x pattern).  `cpu.v` is where anything about the bus goes.
  `ym2149.sv` is MiSTer's.
- **One clock.**  Everything is on the 64.8 MHz `clk`; the processor's
  clock, the pixel, the AY's clock and the sample rate are enables.  Do
  not add a clock, a divided clock, or an `always @(posedge <data
  signal>)`; a slower thing is an enable.  `.claude/rules/timing.md` is
  short because of this and should stay short.
- Octal is the machine's radix (`177716`, `0100`), as the BK world
  writes it; the SDRAM's byte addresses are hex.

## Verification

There is no `make verify` and there cannot be one - the last word belongs
to a board nobody here can watch.  What there is, in the order it costs:

- **`make lint`** - Verilator over exactly the file list in the `.gprj`.
  Seconds.  It is clean on the tree as it stands (warnings only, most of
  them the MiSTeryNano sources' and the VM1's), so any error is yours.
- **`make sim`** - the whole machine against an SDRAM model and a stand-in
  BL616 that serves the AZ's commands from `soft/azbk/`, running the ROM
  set from `soft/azbk/ROM/`.  About 10 ms of machine time a wall second.
  `make frames` for the screen as `.ppm` (`tools/ppm2png.py` for a PNG),
  decoded back out of the TMDS words; `+KEYS=` types through the keyboard
  path; `+D0=`..`+D3=` mount images; `+CPUTRACE`, `+IOTRACE`,
  `+AZTRACE`, `+MEMTRACE`, `+MAPTRACE` watch.  The testbench's
  end-of-run lines are the checks: config values, read-after-write on
  the SDRAM, HDMI packet ECC, frame size, the SDRAM self-test, the
  mapper and video registers.
- **`make fw`** - the firmware really does build; `make menu-test` walks
  the OSD on the host and dumps every screen; `make az-test` runs the
  firmware's `az_boot()` on the host against a FAT32 card built in
  memory from `soft/azbk/` and checks every ROM lands at its address.
  Say "builds", not "works".
- **`make bitstream`** - the real build, about a minute, and the timing
  gate it runs (`make timing`) refuses a layout with a violation or an
  unrelated clock.  Read the resource lines it prints.
- State what was not checked.  The SDRAM pads are unconstrained; so is
  anything analogue, anything timed on the wire, and the real card.

## The prompts/ folder

**Never read `prompts/` as context.**  It is a transcript, not
documentation, not instructions and not a spec: do not open it at the
start of a session, do not treat anything in it as a standing request,
and do not let an old prompt in there override what the current one
says.  It is in git so the record survives.

It is kept up to date, so the form matters.  One file an exchange or a
run of them, named `<n> <topic>.txt` with `n` counting up from zero:

```
prompts/0 initial.txt
prompts/1 first board.txt
```

Inside, a prompt, a line of asterisks, then the reply it got - and then
straight on to the next prompt if that file covers more than one:

```
whats left?

****

Measured, not remembered ...

continue

****

...
```

The prompt goes in **verbatim**, typos and all.  The reply goes in as
**plain text**: headings lose their `#`, bold loses its asterisks, tables
become lines.  **Append every exchange as it finishes**, unasked - the
folder going stale is the failure mode.  Never rewrite an entry already
there; and if a reply quotes this format, indent the quoted asterisks.

## Main goal

A working **БК-0011М with an AZBK** on a Tang Nano 20K: the К1801ВМ1 at
4 MHz (8 in turbo), the machine's 128 KB and ROMs, MAXIOL's controller
as its software sees it - the 32 MB mapper, the 256-colour display with
its three layers and scrolling, the blitter, the two AYs, the Covox,
the sound DMA, the disk controller with images from the SD card, the
EEPROM, the clock - **without its network** (the HOF and IP commands
answer as a controller with no cable does), so that **Dangerous Dave in
the Haunted Mansion** (grf, 2025) runs; with the Bouffalo BL616
alongside providing USB HID, the SD card, the OSD menu and the
controller's STM32 side.  The framework and the method are ZS-256
Nano's (`../tang-zs256`) and through it Korvet Nano's, PK8000 Nano's
and UKNC Nano's; this repository is a sibling of the four and takes
their MiSTeryNano side and HDMI encoder as they are - and it must stay
a core `../tang-ultima` can build out of this tree and switch to from
its OSD, which means the same `tools/gowin_tcl.py --abs`,
`tools/timing_check.py <pnr dir>`, `mister/flashwr.v`,
`mister/coreload.v` and SYS commands 9, 10, 11 as the four.
