# Changelog

## 0.1.28 (25 September 2026)

The buzz confirmed gone on the board ("works!").  The instruments that
found it come out again: the OSD's Debug page (with the AY shadow, the
level meters, the F12 snapshot and the 128-byte debug window - SYS
command 7 is back to its 32 bytes, which the testbench still reads),
and the serial I/O log (`iolog.v`, `tools/iolog.py`, `make log`) - the
Tang's UART is the core loader's alone again.  What stays: the Covox
177714 switch, the AY decode and filter, the sound tests, the F11 and
hotkey fixes, the key map.

## 0.1.27 (25 September 2026)

Dangerous Dave's "bzzzt" is gone.  The legacy Covox and the AY share
the БК's port 177714, and this design fed both whenever 177212 enabled
the Covox - which AZBOOT does from the saved settings ("legacy Covox
stereo").  An AY game's register writes, eleven select words and
inverted data bytes a frame during a sound, then played through the
Covox as a click train on the left channel.  Found by logging the
board's writes over the new serial line and replaying them into the
sound module: peaks of 16400 against a clean 1700.  The Hardware menu
gains "Covox 177714": Off (the default) gives the port to the AY
alone, as a real БК with an AY interface has it (MiSTer's BK0011M
makes the two exclusive); "AZ setup" is the old behaviour, for a
program that plays samples through the legacy Covox.  The AZ's own
Covox at 177200-177206 is not affected.  FPGA and firmware.

## 0.1.26 (25 September 2026)

The I/O log: every write the machine makes to its I/O page, with a
timestamp, streamed out of the Tang Nano's own USB serial at 2 Mbaud
(`tang/src/bk/iolog.v`, pin 69 shared with tang-ultima's loader), and
`tools/iolog.py` / `make log` on the laptop to decode it live - by
default the two AYs, a line per change of a mixer, a volume or the
noise period, with `NOISE ON x` for a channel playing with its noise
enabled.  Tested end to end in simulation (`+UARTLOG=`: AZBOOT's
writes decoded in order, none lost) and on the game's own AY writes.
The FPGA only.

## 0.1.25 (25 September 2026)

Two more instruments on the Debug page, both from the F12 moment: a
level meter per sound source (the AY sum, the Covox, the speaker, the
DMA: peak to peak over the last 0.26 s), which says which device is
making a noise; and each AY as it was the last time a channel had a
fixed volume ("snd"), so the chip's state during a sound can be read
after it. The debug window is 128 bytes. FPGA and firmware.

## 0.1.24 (25 September 2026)

The Debug page's AY lines come from the moment F12 opened the menu
(the firmware reads the debug window on the menu's show event), then
the live state under "now": opened seconds later, the page had only
ever seen the silence after an effect.  The firmware only.

## 0.1.23 (25 September 2026)

The OSD's Debug page opens with both AYs as the machine left them:
which tones and noises the mixer enables, the three volumes (`e` for
the envelope), the noise period and the envelope shape, and further
down all sixteen registers and the selected one - from a shadow in
`azsound.v` written on the strobes that load the chips, through a
debug window widened to 64 bytes (`sysctrl.v`, `top.v`).  An
instrument for the buzz after Dave hits a ceiling, which MEMTEST
(thirteen clean passes on the board) has taken off the memory.
MEMTEST itself is fast now: a pass a minute, dots as it goes.

## 0.1.22 (24 September 2026)

The AY's "bzzzt": the chip's channel outputs were sampled raw at 44.1
kHz, so a short-period tone - inaudible on the chip, and what a game
leaves on a channel it is not using - aliased into a full-amplitude
broadband hash under every sound (Dangerous Dave's landing on the
board).  Each side's AY sum now goes through a 10 kHz low-pass at the
clock rate and a box average over the sample period: a period-1 tone
from 3115 to 75 peak to peak, a 3.3 kHz one untouched.  The FPGA;
the firmware changes in its caption only.  The test disk gains
MEMTEST, a soak of the free memory through window 3 (25 Sep).

## 0.1.21 (24 September 2026)

The keyboard: in РУС the six symbol keys the БК keeps letters on give
the letter - `[` Ш, `]` Щ, `\` Э, Shift+6 Ч, Shift+2 Ю, Shift+] Ъ -
as the БК's own keyboard does (before, they needed Shift and Ъ could
not be typed at all).  The map on a picture of the БК's keyboard,
with the function keys and the controller's hotkeys explained:
`keyboard-ru.pdf`, `keyboard-en.pdf` (`make keyboard`).  The OSD's
About page says the version and what the machine is and does now
(it had the first day's text).  The firmware only.

## 0.1.20 (24 September 2026)

F11 (the СБР key) no longer holds the machine in reset until a replug:
`keyboard.v` took key events only while the machine was not in reset,
and the key's own press starts one, so its release was dropped and the
reset level stayed up.  The flagged keys are now taken during a reset.
The testbench gets `+RESETKEY_MS=`.  The OSD's "Cold reset (AZ)" entry
is gone: every reset of this design is the AZ's cold reset, and the
two did the same thing.  The controller's two hotkeys do something:
Alt+Win (АР2+ЛАТ) switches the BK's screen between the monochrome
512 and the colour 256 view, Alt+Left Ctrl (АР2+РУС) puts the legacy
palettes back; the firmware sent them all along.

## 0.1.19 (24 September 2026)

The sound tests: `soft/src/`, five ANDOS programs, one a device - the
speaker, the two AYs through 177172/177174, the AY through 177714 in
its three write forms, the Covox and the sound DMA - assembled with
macro11 (`make soft`, `tools/fetch.sh` fetches it) and put on a copy
of the package's ANDOS as `build/SNDTEST.IMG` (`make soft-image`,
`tools/andosput.py`, `tools/binlink.py`); `tools/pcmscan.py` reads the
testbench's sound dump.  What they found, fixed: the AY through
177714 is now the BK world's protocol (a word write selects the
register, a low-byte write loads it, both inverted - MiSTer's
BK0011M; before, a high-byte write was the select and BK-world AY
music was silent), with bit 14 of the word naming chip 2; the mix's
silence is 0 (the AYs go through the DC blocker; it was a DC of
-12240); the testbench's I2S receiver took every word a bit early,
which is why every dump looked like noise.  No change to the firmware
beyond the caption.  On the board: the sound plays, in the tests and
in Dangerous Dave - the 177714 decode was yesterday's "scratchy
noise".

## 0.1.18 (23 September 2026)

Dangerous Dave runs on the board.  The debugging aids of the day come
out: the display's write log, the blitter's packet read and shadow,
the register and run counters (SYS commands 12 and 13); the Debug
page keeps the machine's state, the page table's count, the units,
the ROM verify and the controller's service lines.

## 0.1.17 (23 September 2026)

A blitter row count of 0 is nothing again, as GID has it: the 0.1.12
reading of it as 256 rows made a command a game disables by zeroing
its rows write 256 of them, and the game stopped at random points
once the picture was clean.  The Debug page shows the card lines
before the display's log and the packets.

## 0.1.16 (23 September 2026)

The picture is clean with the page table; the game then stopped
mid-level with the processor in its HALT loop.  The allocator counts
its wraps, and the Debug page shows the pages given out and the wraps
on their own line.

## 0.1.15 (23 September 2026)

The AZBK's 32 MB onto the chip's 8 MB through a page table: pages
0-127 one to one, the rest given physical pages at their first write,
reads of unwritten pages zeros, cleared by the cold reset.  The top
bits used to wrap, and Dangerous Dave's page set at 13 MB shared
memory with its backdrop - the flickering of its first level, through
nine builds that fixed other things.

## 0.1.14 (23 September 2026)

The board's Debug page read the game: it switches its page set at
raster line 240 from its main loop and draws each frame's sprites
into the set just switched to; the per-frame packet is a clear, a
copy and two more copies.  The level-drawing packet is the one that
matters and it is gone by then, so the blitter keeps a shadow of the
largest packet ever loaded, readable through command 13 with address
bit 12; the Debug page shows its count and first eight commands.

## 0.1.13 (23 September 2026)

The picture still alternates after the row-count fix.  The Debug page
now shows the last eight page and scroll writes with the raster line
of each (the second debug window) and the last blit packet's first
four commands (SYS command 13 reads the blitter's command buffer):
what the game writes, and when, instead of guesses.

## 0.1.12 (23 September 2026)

A blitter row count of 0 is 256 rows.  It did nothing, so the
level's initial copy into the game's second page set never happened
and the board alternated the finished set with one whose sky layer
was leftover memory.

## 0.1.11 (23 September 2026)

The "50 Hz" interrupt (the BK's and the AZ's timer) is the AZBK's
frame-locked 48 Hz: four of every five frames, at the end of the
visible part.  It was a free-running 50 Hz, and a game switching its
pages on it did so at a raster line drifting with the beat.

## 0.1.10 (23 September 2026)

The game double-buffers by switching its page set live and clearing
the other set at once; the page latch of 0.1.6 kept the just-cleared
buffer on the screen for a frame after every switch.  Reverted, and
the interrupt-after-blit of 0.1.3 with it: the 60 Hz at the frame's
end and live pages, as the hardware has them.

## 0.1.9 (23 September 2026)

The blitter's runs are short in the game (17 lines) and the picture
still alternates.  A second debug window (SYS command 12) holds the
fetch's addresses at line 300 of two consecutive frames - pages, rows,
scrolls, mode - and the Debug page shows both, to tell the display's
addressing from the memory's content.

## 0.1.8 (23 September 2026)

MAXIOL's benchmark says the real blitter is slower than ours, and the
game is said to run clean there.  The blitter's runs are measured on
the board: the Debug page's "blit" line (runs, the last and the
longest in lines, the packet's command count); the "regs" line is
split in two.

## 0.1.7 (23 September 2026)

The board alternates the playfield with one fixed page.  The Debug
page's "video" line becomes "regs": writes since power-up to each of
the display's registers, to name the one written every frame.

## 0.1.6 (23 September 2026)

The fetch finishes its lines now (106 short in a session) and the
board tore a third of the way down instead: the page flip in the 60
Hz handler, which follows the blitter's run, landed mid-frame on live
pages.  Under the AZ's 60 Hz mode the pages and horizontal scrolls
are latched at the frame's end whatever bit 11 says.

## 0.1.5 (23 September 2026)

The board's Debug page in the game: 53341 short lines.  The fetch
reads only the visible window of a layer's row now (from its scroll,
`1024 >> xs` pixels' worth of bursts plus one, wrapping), half the
work at the game's x4.

## 0.1.4 (23 September 2026)

The title picture flickered on the board with a band at the left:
the line fetch.

- A read burst still in flight at a display line's end has its
  remaining words dropped; they were written at the next line's first
  positions and shifted the line by a burst.
- The debug window counts the display lines whose fetch did not
  finish and the lines a burst straddled; the Debug page's "video"
  line.

## 0.1.3 (23 September 2026)

Dangerous Dave's first level plays on the board, flashing half-drawn
frames.

- The AZ's 60 Hz interrupt is raised after the blitter's automatic
  run ends, not at line 769 regardless: GID's order.
- The serving task's stack is 8 KB (the first block read overflowed
  the siblings' 2 KB: FatFs's long-name buffer and the card layer's
  printfs from that task hung the MCU with the OSD dead); the card
  layer's two waits are bounded and a failed read reaches the machine
  as ERR; the Debug page shows the card timeouts and the read's phase.
- The strip of squares is out of the picture; its byte and the
  activity bits are on the Debug page ("act").
- The testbench counts the blitter's runs and how many outlast the
  vertical blanking.

## 0.1.2 (23 September 2026)

The third board's report: the ROMs verified, the AZBK BIOS on the
screen, and the machine in the BK monitor with "served 28 cmds, 0 rd,
last 001 001 001 001" - the select served by the MCU was still pending
when AZ337's boot code, which does not wait for it, wrote the block
number and the read, and those were dropped.

- The unit select (001) is done in the FPGA from a table of unit sizes
  (USIZE, buffer word 576) the firmware writes after AZ.INI and on
  every mount and unmount; the status's second byte names the selected
  unit and the firmware's read and write use it, opening the file at
  the first read.  The testbench's stand-in works the same way, so the
  SPI unit byte is proven there too.
- The Debug page's lines have a buffer each (the first flash showed
  the last line five times); the served line carries the last block
  read's service time.

## 0.1.1 (23 September 2026)

The first board's report read, and the next flash made to answer it.
Still nothing has booted on a board.

- The board (22 Sep): the memory initialised (self-test passed at
  phases 5-7 and 10-15, chose 12 with the late capture), the processor
  cycling with the mapper's and the display's registers at their reset
  values and its last cycle at 177716 - restarting for ever on memory
  without a ROM; the screen the uninitialised memory in the reset
  mode; the firmware on the board older than `bin/bl616.bin`.
- The firmware verifies the ROMs it loaded by reading them back over
  SYS command 8 (`sys_peek24`; all of AZBOOT, one word in sixteen of
  the rest) and the Debug page says whether AZ.INI was found, what was
  sent and what came back wrong; the load now happens with the machine
  held in reset (between `R=3` and `R=0`); a path the OSD chose
  (`/sd/...`) is no longer prefixed with `/bk/` (unit 0 had become
  `/sd/bk/sd/dave.img`).
- The SDRAM sweep keeps a mask for each capture and chooses the longest
  run of either; the strip's third row is the late mask; the debug
  window carries both.  SYS command 8 answers a ready byte before the
  word.  The testbench reads AZBOOT's first 64 words back over the link
  (`+ROMSPI`) and checks them.

## 0.1.0 (19 September 2026)

The first tree.  Nothing has been on a board.

- The БК-0011М: Vslav's 1801VM1 (Sorgelig's wrapper, MiSTer BK0011M)
  at 4.05 MHz on a 64.8 MHz clock, turbo 8.1; 177716 both ways; the
  keyboard from USB as КОИ-7 codes with the РУС/ЛАТ and СТР state on the
  MCU; the 50 Hz frame interrupt; the joystick on 177714.
- The AZBK as GID's BKemu v4.6 models it: the mapper (177300-177352,
  the 177716 and 177130 translation, the machine's own memory behind an
  unclaimed window), the display (1024x768 at 59.8 Hz over HDMI, the
  modes of 177230, three layers, scrolling, the 338-entry palette), the
  blitter, two YM2149s, the Covox, the sound DMA (PCM and IMA ADPCM),
  the speaker, the disk controller (177220-177226) with its commands
  split between the FPGA and the BL616 (units from images on the card,
  the EEPROM, a software clock, the file commands), 177550/177370/the
  RS-232 stubs.  No network: the HOF and IP commands answer as a
  controller without a cable.
- The firmware: core id 10, `/bk/` on the card, AZ.INI read at start,
  the ROM set and the logo sent into the SDRAM, the OSD's four unit
  selectors, Reset, Cold reset, CPU speed, Joystick, Volume, About,
  Debug, Save settings.
- Builds (`make bitstream`: logic 52%, BSRAM 25/46), lints, the menu
  test walks the forms with 0 errors, the firmware builds, the
  bitstream meets timing (Fmax 67.2 MHz on the 64.8 MHz clock). In
  simulation AZBOOT runs its two passes, the machine's monitor boots,
  the AZBK BIOS screen is drawn, ANDOS 3.30 boots from the image in
  unit 0 to its splash at 13.8 s of machine time, and Dangerous Dave,
  started from ANDOS 3.1's shell on the operator's `soft/azbk/DISKS/dave.img`,
  loads its data and shows its logo, title and credits by 98 s.
