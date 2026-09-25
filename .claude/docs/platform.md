# The platform: a БК-0011М with an AZBK

What the software sees, and where each fact comes from.  The machine is
Elektronika's БК-0011М (К1801ВМ1 at 4 MHz, 128 KB in eight pages of 16
KB, two ROM pages of BASIC/BOS, the ВП1-037 memory controller with its
screen) with MAXIOL's **AZBK** plugged in: an FPGA-and-STM32 board on the
bus that carries 32 MB, a 256-colour display of its own, a blitter, two
AYs, a Covox, a sound DMA, a disk controller over a MicroSD card, an
EEPROM, a clock - and a network, which this design leaves out.

Radix: octal, as the BK world writes it (`177716`, page `0100`).

## Sources, in order of authority

1. **GID's BKemu v4.6 sources** (`BK/devemu/AZBK/AZBK_*.cpp`, `AZBK.cpp`,
   `BK0011M.cpp`, `CPU.cpp`): what the software sees.  Dangerous Dave
   was developed against this emulator.
2. **forum.maxiol.com**: "Модель управления памятью в AZ V2" (the
   mapper), "Команды контролера AZ" and "Новые команды" (thread 5388,
   the disk protocol), the firmware changelog (5553), the developer
   notes (5556: video layers, the blitter, the sound part).
3. **MiSTer BK0011M** (Sorgelig, Vslav's VM1): the processor and its
   bus, SEL1/SEL2, the keyboard vectors; MiST's `keyboard.sv` for codes.

The one liberty taken is memory: on a real machine the AZ sits beside
the BK's own 128 KB and its ROMs, and answers only the windows it claims.
Here there is one memory (`fpga.md`), so a window the AZ does not claim
falls back to the BK's own page (`azmap.v`), and a "shadow" window
reads and writes the same pages the BK's RAM would.  The emulator's
platform does the same thing behind its AZ model, so the software
cannot tell.

## The processor

К1801ВМ1: the PDP-11 subset without EIS, a 60-clock bus timeout to
vector 4, the radial interrupts IRQ1 (СТОП: the HALT flow through
177716 and vector 4) and IRQ2 (the frame, vector 100), vectored
interrupts through IAKO (60 and 274 the keyboard; 174 the AZ
controller), the internal registers 177700-177717 (the CSR, the error
register, the timer at 177706-177712, SEL2 at 177714 and SEL1 at
177716).  4.05 MHz here (64.8/16), 8.1 in turbo.

**Start**: after DCLO the processor reads 177716 and jumps to bits
15:8 of it with the low byte zero.  The AZ answers that read with
170000 - its start ROM's window - at a cold start (GID: `bSEL1` true
from `ResetCold` until the platform's `SetSel(false)` after the board's
reset; `AZ_716_Out`: `0100200 | 070000`), and 140000 or 100000
afterwards (`0100200 | 040000` when 177346's REVTYPE, 037_OFF and
BK11EMU bits are all set, else `0100200`).  `azmap.v`'s `sel1`.

**The HALT flow** (a timeout on the vector push, a double bus error):
the VM1 writes 177716 with bit 3 set and the PSW to 177676, then
restarts through 177716 (GID `SystemInterrupt`: "this is what raises
the vector-4 interrupt").  177676 is not a register anywhere; here it
is a word of the fallback ROM page and the write is answered and
dropped, so the flow completes instead of looping.

**AZBOOT's first pass**: the start ROM at 170000 stores vector 4,
writes 014000 into 177716, reads 177346's bits 8:6 - zero at power-up -
beeps 64 times on bit 6 of 177716 and issues controller command 037.
That resets the machine; the second pass finds 177352 = 014000 and the
bits set, and boots.  `progress.md` has the trace.

## 177716, both ways

Read (`cpu.v`, GID `BK0011M.cpp`/`AZ_716_Out`): bits 15:8 the start
address (above), bit 7 = 1 (no EIS), bit 6 = no key down, bit 2 the
"written since last read" flag.

Write with bit 11 clear: bits 6, 5, 2 the speaker (weighted as GID's
`SetSpeaker`: bits 6, 5, 2 and 2 again as 4, shifted left 9), bit 7
the tape motor, bit 12 masks the СТОП key (`cpu.v`'s `stop_block`).
The AZ takes the same three bits as its speaker unless 177212 bit 2
says not to.

Write with bit 11 set (`azmap.v`, GID `AZ_716_In`): the BK-0011M's
memory word, translated in three registered steps as the hardware does
it (latch, precompute, apply).  Window 0 (40000-77777) gets pages
`(bits 14:12) * 4 + 0..3`; window 1 (100000-137777) gets the BASIC/BOS
ROM pages `0124 0125 0122 0123` if bit 1, `0126 0127 0130 0131` if bit
0, else `(bits 10:8) * 4 + 0..3`; the static block 0-37777 is always
pages `030-033`.  Windows 0-7's active bits become 037_OFF (177346 bit
9) and their shadow bits its inverse; windows 8-11 are active when the
ROMs were asked for and 177346 bit 5 (ROM11) allows, or no external
ROM (bits 3, 4) was asked for and 037_OFF is set; shadow when nothing
was asked for and 037_OFF is clear.  The word is kept as 177352.  If
177346 bit 15 (SMK_WND1) is set the SMK's mapping owns windows 8-11
instead.

## The mapper: 177300-177352

Sixteen windows of 4 KB, each a 13-bit page number (`177300 + 2n`) of
the 32 MB, an active bit in 177340, a read-only bit in 177342, a shadow
bit in 177344.  Physical pages: 0-037 the BK's own 128 KB (page 030-033
its fixed block), 040-077 the controller's (040 the logo, 076 the
screenshot header, 077 the CMOS block), 0100-0177 the ROM slots (slot
n = page 0100+n, byte address `0x40000 + n*4096`, never writable),
0200-0377 the SMK-512's 512 KB, 0400 onward free RAM (2048 pages of
the 8 MB here; the address wraps).

Access (GID `MemoryManager`, plus this design's fallback): active ->
readable, writable unless read-only or a ROM page; shadow (and not
active) -> the same page, readable and writable; neither -> the BK's
own memory: pages 030-033 for windows 0-3, the 177716 page for 4-7 and
8-11 (or the BASIC/BOS ROM pages), the 324/325 ROM pages 0120-0123 for
12-15.  A write to a ROM page is answered and dropped; an access nobody
answers times out to vector 4.

177346, the control word: bit 15 SMK_WND1 (the SMK owns window 1), 14
REVTYPE (read-only: the 037 revision, from the configuration; 0 here as
GID's default `m_bAZWin1Off`), 13 SMK_WND1_REV, 12 BRDTYPE (BK-0010),
11 BK11EMU, 10 014_OFF, 9 037_OFF, 5 ROM11, 3 V100 (the 60 Hz frame
interrupt), 2 50HZ (the 50 Hz one), bits 2:0 the hardware type (4 at
power-up).  A write keeps REVTYPE and bits 1:0.  `ResetCold` (command
037, the OSD's cold reset, power-up) clears SMK_WND1, V100, 014_OFF,
037_OFF and REVTYPE, clears every window, and maps page 0100 into
window 15 - and nothing else, so the 700 AZBOOT wrote survives.

177350/177352: copies of the last SMK mode word and the last 177716
memory word.  The SMK's 177130: a write of 6 arms it, the next word is
the mode (bits 6:4) and the page (bits 10, 3, 2, 0); the mode table -
Start, Std10, OZU10, All, Std11, OZU11, HLT10, HLT11 - is MAXIOL's
"STATE_DOUT_reg_az_130_pre" as `azmap.v` has it; bit 4 of the word
says whether the SMK also takes windows 8-11.

## The display: 177230-177256, 177662, 177664

`video.md`.  In short: 177230 mode (bits 2:0 the bits per pixel and
the layer count, 4:3 the line length in words 32/64/128/256, 7:6 the
horizontal stretch, 10:9 the vertical, 11 "synced" (registers take
effect at the frame), 15:12 the roll length); 177232, 177240, 177242
the three layers' pages; 177244/177246/177250 vertical and
177252/177254/177256 horizontal scroll (layers 2, 1, 0); 177234 the
palette cell, 177236 its value (R5G5B5 through the AZ's own
conversion), 338 cells: 0-255 the 256-colour palette, 256-319 the
sixteen legacy 4-colour sets, 320-335 the 16-colour set, 336-337
monochrome.  177662 (write): bits 11:8 the legacy palette number, bit
15 the screen buffer (page 4 or 034 - the BK's second screen), bit 14
enables the BK's 50 Hz interrupt when clear.  177664: bits 7:0 the
vertical scroll (`0330` = none), bit 9 the extended mode - set, all 256
lines are shown; clear, the lines beyond the first 192 are dark.

## The blitter: 177270, 177272

177270: bits 7:0 the number of eight-word commands in the packet (0
stops everything), 14 automatic (run at the frame end) or manual, 12
start now (write-only), 15 busy (read-only), 9 the packet is being
read.  177272: the page the packet starts at.  A command is eight
words: the operation and flags, the source page, the source offset, the
destination page, the destination offset, the width in words, the
height in rows, the line pitch (or Y word).  Operations 0-5: copy, copy
with overlay (a zero byte is transparent), copy under (the destination's
zero bytes are filled), fill, save the background, restore it; flag
bits 0/1 read source/destination, 2 no-op, 6 swap the halves, 9/10
mirror horizontally/vertically.  A row count of 0 is nothing, as
GID's code has it (for a few hours on 23 Sep 2026 it was 256 rows,
and Dangerous Dave, which zeroes the rows of commands it disables,
stopped at random points).  `azblit.v` follows GID's `AZ_Blitter`
step for step.

## Sound: 177160-177212, 177714, 177716

`azsound.v`'s header is the register list.  177160 control (bit 0
start, 1 one-shot, 2 stop, 3 done, 4 keep the ADPCM state across a
loop, 11:9 the format: 0 PCM 16-bit mono, 4 IMA ADPCM mono, 5 IMA
stereo), 177162 the start page, 177164/177166 the length in words (24
bits), 177170 the current page (read-only); the sample rate is 44100
Hz.  177172/177173 AY1 address/data, 177174/177175 AY2 (byte
registers; a word write is address low, data high).  177200/177202
Covox 16-bit left/right, 177204 both, 177206 8-bit (left low, right
high; a byte write is both).  177212: bit 0 legacy Covox stereo, 1
legacy Covox off, 2 speaker off, 3 AY8910 instead of YM2149.  177714
written: the AY access of the BK world - a word write selects the
register, a byte write loads it, both inverted, both from the low byte
(MiSTer's `BK0011M.sv`: `BC = bus_wtbt[1]`, `DI = ~bus_din[7:0]`; the
package's AY_TEST does exactly that) - and the legacy 8-bit Covox, but only when the OSD's "Covox 177714" is set to "AZ setup" as well as 177212 allowing it: fed both, an AY game's register writes play through the Covox as a click train (the "bzzzt" of 25 Sep 2026); a real БК has one device on its port, and MiSTer's BK0011M makes them exclusive.
GID's `~word & 0140000` picks the chip; here bit 14 of the written
word set means chip 2, clear chip 1, a reading to check against GID's
source (until 24 Sep 2026 a high-byte write was taken as the select
and BK-world AY music was silent).  The mix is MAXIOL's: right = A + B
of both AYs, left = C + B, plus everything else.

## The keyboard: 177660, 177662, 177714

`keyboard.v`: 177660 bit 6 the interrupt mask (R/W), bit 7 a code is
ready (read-only, cleared by reading 177662); 177662 the 7-bit КОИ-7
code; vector 60, or 274 for АР2 and the keys that imply it (ПОВТ, ГРАФ,
ИНД СУ, БЛОК РЕД, ШАГ, -!->); СТОП is IRQ1; bit 6 of 177716 says a key
is down.  The codes and the РУС/ЛАТ/СТР rules are MiST's
`keyboard.sv`, applied on the MCU (`mcu.md`).  177714 read: the
joystick, GID's default bits (up 1, right 2, down 4, left 010, A 020,
fire 040, alt-fire 0100, B 0200), from the USB joystick when the OSD
allows.

## The controller: 177220-177226

`azctrl.v`'s header is the whole account.  CSR 177220: bits 5:0 the
command, 6 IE, 7 DONE, 14 BIG, 15 ERR; a command is accepted only with
DONE set, and while it runs DR (177222) is not answered (a timeout, as
MAXIOL says).  **A select (001) must therefore complete at once**: the
337 boot ROM (AZ337 at 160314) writes the unit into the DR, 001 into
the CSR, tests ERR in the very next instruction and goes on to the
block number, 002 and 005 without waiting for DONE - GID's emulator
completes the select inside the write, MAXIOL's controller evidently
as fast.  Served by the MCU (a task wake-up and a file open) the
select was still pending when the 002 and 005 arrived, they were
dropped, the software read an empty buffer and the third board (23
Sep 2026) sat in the BK monitor; so the select is the FPGA's, from a
table of the units' sizes the MCU keeps in the buffer (USIZE, 576),
as GID's own is from its image list.  The commands are GID's
`AZBK_ctrl.h` list: 000 RESET,
001 SETUNI, 002/012 the block number, 003/013 the HFS catalogue, 004/014
mount/unmount, 005 READ, 006 WRITE, 007/017 the size, 010 NET (with IE
it only clears it), 011 the units table, 015 READ_BUF, 016 WRITE_BUF,
020 the diagnostic word, 021/024 the EEPROM, 022/023 the I/O block,
027 the feature word (0x1204), 030 NOP, 031-036 and 042 the clock, 037
reset the machine, 040/041/043 the IP and MAC (empty here), 044 a
screenshot (unimplemented: ERR), 047 and 050-057 the file commands.
The buffer's regions and the split between the FPGA and the MCU are in
`azctrl.v`; the MCU's side, including the HOF's "no connection"
answers, in `mnano/azbk.c`.  A finished READ or WRITE with IE set
interrupts through vector 174.

The STM's version is 18 (177370 answers 18 for the FPGA too, GID's
`FPGA_version`), which is what Dangerous Dave checks for.

## Small registers

177550 a random word (a 128-bit LFSR); 177370 the FPGA version;
177560-177566 an RS-232 nobody is on; 177130/177132 the BK's disk
controller (zeros); 177176/177177 the OPL2 of firmware 18 (zeros).

## Interrupts

IRQ2: the BK's 50 Hz when 177662 bit 14 is clear; the AZ's 50 Hz when
177346 bits 3 and 2 are both set; its 60 Hz (the AZ's own frame, at
raster line 769) when bit 3 is set and bit 2 clear (GID `AZBK.cpp`).
The "50 Hz" is the AZBK's "v-sync timer 48Hz" (the BIOS's name for
it): four interrupts in every five 60 Hz frames, each at line 769
like the 60 Hz - derived from the frame, so a handler's page switch
lands in the blanking.  (Until 23 Sep 2026 it was a free-running
counter at exactly 50 Hz, and Dangerous Dave's page switches drifted
through the picture with the beat between 50 and 59.8 Hz.)
Vector 174 from the controller; 60/274 from the keyboard; IRQ1 from
СТОП unless 177716 bit 12 masks it.

## What is left out

The network: the HOF (hall of fame) upload commands answer with the
JSON a controller without a connection returns, the IP and MAC are
zeros, DHCP is nothing.  The screenshot command (044) answers ERR.
The RS-232 has nobody on it.  The BK-0010 emulation mode (177346 bit
12, the 10_* ROMs) is mapped but not exercised.
