# The MCU firmware

`mnano/` is MiSTeryNano's BL616 firmware as ZS-256 Nano carries it (and
through it Korvet Nano, PK8000 Nano, UKNC Nano): FreeRTOS, USB host
(keyboard, mouse, joystick), the OSD over SPI, FatFs over the FPGA's SD
card, `sysctrl.c` for the core's values.  This core's additions are
four files and a handful of edits, all marked in the sources:

```
bk.h, bk.c        the keyboard: USB HID -> the БК's КОИ-7 codes and flags
azbk.h, azbk.c    the AZ controller's STM32 side: AZ.INI, the ROMs into the
                  core, the unit images, the commands the FPGA hands over
menu.c            the forms, variables and About text for CORE_ID_BK; az_boot at start;
                  an image chosen in the OSD becomes an AZ unit (menu_bk_mount)
sysctrl.c/.h      CORE_ID_BK = 0x0A, "BK Nano" in core_names[], irq 4 -> az_handle_event()
usb_host.c        keymap[]/modifier[] entries for id 10, kbd_tx_bk() for the keys and
                  the modifiers when core_id == CORE_ID_BK
CMakeLists.txt    azbk.c and bk.c in the source list
```

Core id 10 (`CORE_ID_BK`, `sysctrl.v` answers `0x0A`); every table the
firmware selects by core is indexed by it - `settings_file[]`
(`/bk/bk.ini`), `keymap[]`, `modifier[]`, `core_names[]`.

## The keyboard

The БК's keyboard delivers one 7-bit КОИ-7 code a key, with the РУС/ЛАТ
and СТР states kept in the keyboard, and the АР2 chord sends its
interrupt through vector 274 instead of 60.  All of that is done on the
MCU (`bk.c`, from MiST's `keyboard.sv` rules) and the core gets two
bytes on hid.v's keyboard event: the code and the flags (bit 0 release,
1 АР2, 2 СТОП, 3 СБР, 4 a hotkey).

```
Esc КТ   F1 ПОВТ   F2 ВС   F3 ГРАФ   F5 -!->   F6 ИНД СУ   F7 БЛОК РЕД   F8 ШАГ
F9 СБР (the clear code 014)   F10 / Pause СТОП   F11 the reset key   F12 the OSD
Ins |-->   Del |<--   Home/PgUp/End/PgDn the diagonal arrows
Shift+Enter УСТ ТАБ   Shift+Tab СБР ТАБ
Left Ctrl РУС   Win ЛАТ   Right Ctrl СУ   Alt АР2   Caps Lock СТР
Alt+Win  the AZ hotkey АР2+ЛАТ (the legacy 512/256 switch)
Alt+Left Ctrl  the AZ hotkey АР2+РУС (the palette reset)
```

The two hotkeys reach `azvideo.v` as a one-clock code (since 24 Sep
2026; before that the wire ended in `top.v`): АР2+ЛАТ toggles the BK's
screen between 1 bit a pixel, 512 wide, stretched x2 (the monochrome
output of a real BK) and 2 bits, 256 wide, x4 (the colour one), and
only while 177230 is in one of those two modes; АР2+РУС reloads
palette cells 256-337 - the sixteen legacy sets, the 16-colour set and
the monochrome pair - from the power-up table (`az_palette.v`'s
`reload`, 82 clocks).  That is `bk.h`'s account of the keys, not
checked against MAXIOL's controller.

Letters: a lower-case ASCII letter minus `rus ^ caps`, an upper-case one
plus it, where `rus` is 0x20 in ЛАТ and 0 in РУС; in РУС the six symbol
keys the БК keeps letters on give the letter, as its own keyboard does:
`[` Ш (0173), `]` Щ (0175), `\` Э (0174), `^` Ч (0176), `@` Ю (0140),
`}` Ъ (0177 - no ASCII key sends it otherwise; until 24 Sep 2026 Ъ could
not be typed and the other five needed Shift); with СУ the low five
bits.  The joystick is sysctrl's byte on 177714 (GID's default bits:
up 1, right 2, down 4, left 010, A 020, fire 040, alt-fire 0100, B
0200), when the OSD's Joystick is on.

## The OSD

`menu.c`'s `main_form_bk`: AZ0..AZ3 (file selectors on slots 0-3 with
`.img`, `.bkd`, `.dsk`), Reset ('R': 1 then 0; every reset of this
design is the AZ's cold reset too, `top.v`, so the separate "Cold reset
(AZ)" entry of 24 Sep morning is gone - it did the same thing; menu.c's
own cold boot at start is 'R' = 3 then 0, which `sysctrl.v` also turns
into the controller's cold pulse), Hardware (CPU 4/8 MHz 'T', Joystick
'j', Covox 177714 'c' - Off (default) or AZ setup, Volume 'A'), About, Debug, Save settings.  The letters are
`sysctrl.v`'s; a menu value is three edits: the letter in the form
string, `variables_bk[]`, and `sysctrl.v`.  `make menu-test` walks the
forms on the host.

An image chosen for AZn is not a `sd_card.v` slot: `menu_bk_mount()`
remembers the name for the settings and calls `az_set_unit(n, path)`,
so the controller's unit n is that file.  At start `az_boot()` reads
`AZ.INI` first and the saved images override its D0..D3.  "No Disk"
unmounts.

The Debug page (SYS CMD 7, `top.v`'s `dbg_bus`; removed from the OSD in 0.1.28, the window stays for the testbench; tone and noise letters for what the mixer enables, the volumes with `e` for the envelope, the noise period, the envelope shape; four lines a screen,
scrolled): the memory's state and the SDRAM clock phase chosen, the
phases the self-test passed at with each capture, the last bus cycle's
address and the cycle and reset counts, the reset chain,
177346/177340/177716/177230, the controller's pending/done/error bits,
the first two units' paths, and then `az_boot_line()`'s: whether
AZ.INI was read, the ROM files sent and missing, and the read-back
verify - words read back through SYS CMD 8, how many wrong, how many
the core never answered, and the first wrong word with what was wanted
and what came.  `build.md` ("Reading the board") says what the values
mean when the machine does not boot.

## The controller's STM32 side: `azbk.c`

At start (`az_boot`, between menu.c's `R=3` and its `R=0`, so the
machine is held in reset with the AZ cold-reset while its ROMs arrive;
until 23 Sep 2026 the load came before the `R=3` and the processor ran
on the empty memory meanwhile): `/bk/AZ.INI` is parsed - `[ROM]`
`Rnn=path` lines, `[LOGO]` `L=path`, `[DISKS]` `Dn=path`, `[BOOT]`
`Dn` - each ROM goes into the SDRAM at byte `0x40000 + nn * 4096` and
the logo at `0x20000` through SYS CMD 6 (`sys_poke24`: three address
bytes, then the bytes, 512 a transaction, `poke.v` at the other end),
and is then read back through SYS CMD 8 (`sys_peek24`: three address
bytes, a pause of a few microseconds for the arbiter, a ready byte,
the four bytes of the word, low byte first; not ready is tried twice
more with longer pauses) against the file - every word of R00
(AZBOOT), one in sixteen of the rest, about a fifth of a second - and
the counts go to the serial log and the Debug page (`az_boot_line`).
The units table is filled (path, size in blocks from FatFs).
`/bk/eeprom.dat` is the EEPROM image.  A path `0:/x` or `x` is
`/bk/x`; a path that already starts with `/sd/` (the OSD's file
selector gives those) is taken as it is - until 23 Sep 2026 it was
prefixed too, and the first board's unit 0 was `/sd/bk/sd/dave.img`.

On the FPGA's interrupt (sysctrl's `int_in` bit 4, `pending & 0x10` in
`sysctrl.c`), `az_handle_event()` reads the pending command over SPI
target 4 (`azctrl.v`'s header has the bytes) and serves it: READ/WRITE
(256 words through the buffer's IOBUF, of the unit the status byte
names - the select itself is the FPGA's, answered from the size table
the firmware keeps at USIZE with `az_push_sizes()` after AZ.INI, after
every mount and unmount; the file is opened at the first read, FatFs
with a cluster map per open unit), the units table (011:
32 entries of 198 words - name, flags, size), the EEPROM (021/024 in
CMOS), the clock (031/042 fill the timestamp from a software clock the
machine can set with 034; 032/033 the FPGA does itself), the HFS
catalogue and mounts (003/013/004/014), the file commands (047, 050-055,
056), the screenshot (044: ERR).  The network ones that reach the MCU
answer as a controller without a cable: the HOF upload returns the JSON
`{"status":"CONNECTION_ERROR"}`.  Every command ends with "done" (04):
the flags, the DR pointers and counts to set (and five bytes the FPGA
no longer reads, once the unit's size and number).

Blocks are 512 bytes; the images are raw (`.img`, `.bkd`, `.dsk`).
There is no write protection beyond the file system's.

## The SD card

The card is in the Tang's slot and `sd_card.v` reads it; the firmware's
FatFs goes through that module over SPI.  Unlike the siblings nothing
goes the other way: `sd_card.v`'s image slots are unused here (its core
ports are tied off in `top.v`), because the AZ's disk is a command
protocol, not a sector port - the MCU reads the image file and writes
the words into the controller's buffer.

## The SPI link

Mode 1, 20 MHz, five targets by the first byte (0 SYS, 1 HID, 2 OSD, 3
SDC, 4 AZ); `mcu_spi.v` takes it through a handshake into the 64.8 MHz
domain.  `-DM0S_DOCK=1` picks the pinout in `spi.c` that matches the
seven wires in `README.md`.  UKNC Nano's `.claude/docs/mcu.md` has the
byte-level protocol of the first four; SYS CMD 6 has three address
bytes (as ZS-256 Nano's), CMD 7 is the debug window, CMD 8 a peek (a
ready byte, then the word - this core's own, no sibling has one), CMD
9, 10 and 11 are tang-ultima's (`../tang-ultima/CLAUDE.md`) and the same
as in the siblings; target 4 is `azctrl.v`'s.

## For tang-ultima

What that firmware needs from here to carry this core: `bk.h`, `bk.c`,
`azbk.h`, `azbk.c`, the forms, variables and About text in `menu.c`
with `menu_bk_mount()`/`menu_bk_boot()`, `settings_file[10]`, the
`kbd_tx_bk()` branches in `usb_host.c`, `az_handle_event()` on irq 4
in `sysctrl.c`, and `CORE_ID_BK` in every table.  `ultima_cores[]` gets
`{ CORE_ID_BK, "BK Nano", "bk", "bk.ini" }` and the Makefile's `CORES`
gets `bk` with `DIR_bk := $(ROOT)/../tang-bk-epta` and `NAME_bk := bk`.
The card folder is `/bk/` in both cases.
