# Tools and the software

The toolchain is fetched into `tools/` and driven from the `Makefile`;
`.claude/docs/build.md` says what builds here.  Beside it there is a
handful of small scripts, all committed (force-added past the `/tools/`
ignore line), and the machine's software under `soft/azbk/`.

## `tools/`

| script | what |
|---|---|
| `fetch.sh` | fetches the toolchain (oss-cad-suite, CMake, Ninja, the RISC-V GCC, the Bouffalo SDK, Gowin EDA Education, gh), patches the SDK's host-tool selection, shadows Gowin's stale bundled libraries.  UKNC Nano's |
| `srcs.py` | prints the design's source list out of `tang/bk.gprj`; `--ip` the stubbed files, `--cst`, `--sdc` |
| `gowin_tcl.py` | emits `tang/build.tcl` for `gw_sh`, from the same `.gprj` and the IDE's process config; `--abs` and `--multiboot-addr` for tang-ultima |
| `timing_check.py` | the timing gate (`.claude/rules/timing.md`); takes a PnR directory for tang-ultima.  Wants `clk27`, `clk64`, `spi_clk` |
| `palette.py` | writes `tang/src/bk/az_palette.v`: the AZBK's 338-entry palette (the 256 colours, the 16x4 legacy sets, the 16-colour and the two monochrome sets) as R5G5B5, from the emulator's tables.  `make palette` |
| `pdp11dis.py` | a small PDP-11 disassembler for the ROMs: `tools/pdp11dis.py soft/azbk/ROM/azboot.ROM 170000 170000 64` |
| `ppm2png.py` | the simulation's `.ppm` frames as PNG (`-s 2` scales down) |
| `osd_png.py` | the OSD test's text dumps -> PNG |
| `macro11/` | the MACRO-11 cross-assembler (shattered/macro11, cloned and built by `fetch.sh`), for `soft/src/`.  It opens an `.INCLUDE` relative to its working directory, so the Makefile assembles in `build/soft/` |
| `binlink.py` | a macro11 object (one `.ASECT` at 1000) -> a headerless ANDOS program: the TXT records laid out, the RLD entries applied, the transfer address checked to be the base.  UKNC Nano's `savlink.py` without the `.SAV` block 0 |
| `andosput.py` | puts files onto an ANDOS disk image (FAT12), the load address in the directory entry's time field where ANDOS keeps it; `--list` prints an image's root with those addresses |
| `tonegen.py` | the sample tables `dmatest.mac` plays (a PCM sine, an IMA mono and an IMA stereo sine), with the IMA coder checked against a mirror of `azsound.v`'s decoder |
| `pcmscan.py` | a testbench `+WAV=` dump window by window: RMS, DC, the strongest frequency of each side |
| `keyboard_pdf.py` | the PC keys drawn on `prompts/bk-keyboard.png` with a legend, Russian or English (`make keyboard` -> `keyboard-ru.pdf`, `keyboard-en.pdf` at the root).  Pillow only, one raster page, the way mc0511-elite's `control_pdf.py` does it; the mapping is `mnano/bk.c`'s |

## `soft/src/`

The sound tests, one program a device, MACRO-11 for `tools/macro11`
(`make soft`, `make soft-image`; `build.md`).  `bk.mac` is what they
share: `PRINT` (the monitor's EMT 16), `DELAY` (a SOB loop, 4.5 us a
pass at 4.05 MHz as measured in simulation, so every pitch here is
"about"), `SECOND`, and the
`RUNTIME` macro with the routines, the end (EMT 6 for a key, then
`JMP @#100000` as the package's own AY_TEST leaves) and the СТОП
vector (4) through the program's `QUIET`.

| program | plays |
|---|---|
| `spktest.mac` | 177716 bit 6, bit 5, bit 2, all three, then a staircase through the eight combinations (the AZ weights the bits) |
| `aytest.mac` | chip 1 then chip 2 through 177172/177174 (a word: register low, value high): A 440 Hz, B 554, C 659, the chord, noise on A, an envelope on A.  A is right, C left in the AZ's mix |
| `ay714.mac` | the AY through 177714: form A the BK world's (a word = ~register, a byte = ~value, as AY_TEST on WRKANDOS2.IMG does), form B the register as a byte to 177715, form C form A with bit 14 set (GID's chip select) |
| `covtest.mac` | a ~110 Hz sawtooth on 177200 (left), 177202 (right), 177204 (both), 177206 as a word (8-bit left) and as a byte (both), then 177714 with 177212 bits 1,0 clear (legacy mono) and bit 0 set (stereo, right inverted) |
| `dmatest.mac` | the DMA: PCM 16-bit mono 430 Hz, IMA ADPCM mono 430 Hz, IMA stereo (left 430, right 646 Hz), each two seconds looping from pages 400/401/402 (loaded through window 3, which is put back), then PCM once with the DONE bit polled; 177170 and 177160 printed after each |

ANDOS facts the tools rest on, measured on `WRKANDOS2.IMG` and
`../../soft/azbk/DISKS/dave.img`: the disk is FAT12 (800 KB, 4 sectors a cluster, 112
root entries), a program is headerless, and its load address is the
directory entry's time field - 1000 for DAVE, AY_TEST and every
utility, 30000 for `DAVEDATA.*`, 177777 for `ANDOS.SYS`; typing the
name loads the file there and jumps to it.  ANDOS accepts the name in
lower case.

## `soft/azbk/`

MAXIOL's card package for the AZBK (the `AZBK.7z` beside GID's emulator,
gid.pdp-11.ru), as it goes onto the card under `/bk/`:

| file | what |
|---|---|
| `AZ.INI` | the controller's configuration in MAXIOL's format: `[ROM]` `Rnn=` the ROM slots, `[LOGO]` the logo, `[DISKS]` `Dn=` the unit images, `[BOOT]` the unit to boot.  A path `0:/...` is `/bk/...` on the card |
| `ROM/azboot.ROM` | slot 0 (page 0100): the AZ's start ROM at 170000 - the beep-and-reset first pass, the vector table, the library loader, the logo, the boot |
| `ROM/AZLIB00..03.ROM` | slots 1-4: the AZ library, reached through TRAP 34 with window 14 switched to the page |
| `ROM/AZ337.ROM` | slot 8 (page 0110): the disk controller's ROM at 160000, the БК-0011М's 0337 as the AZ has it |
| `ROM/11M_324.ROM`, `325` | slots 16, 18 (pages 0120-0123): the БК-0011М's BOS and MSTD, what an unclaimed 140000-177777 falls back to |
| `ROM/11M_327..330.ROM` | slots 20-26 (pages 0124-0133): the BASIC and BOS pages the 177716 word maps into 100000-137777 |
| `ROM/10_017.ROM`.. | slots 28-38: the БК-0010's ROMs, for its emulation mode |
| `ROM/SETUP.ROM` | slot 56: the controller's setup program |
| `ROM/AZLOGO.RAW` | 48 KB: the start logo, at page 040 (byte 0x20000) |
| `DISKS/WRKANDOS2.IMG` | ANDOS, the boot unit `AZ.INI` names as D0 |
| `DISKS/*.IMG`, `.BKD`, `.DSK` | the other images the package ships (a games disk, MKDOS, RT-11, a toolkit, the AZ's own disk) |
| `eeprom.dat` | the controller's 512 bytes of settings |

Dangerous Dave's image is not here: it is downloaded from
hof.maxiol.com after registering, goes into `DISKS/`, and `AZ.INI` (or
the OSD) names it as a unit.

Nothing is built into the bitstream: the firmware loads the ROMs and
the logo from the card at start (`mcu.md`), and the simulation reads
them from here.
