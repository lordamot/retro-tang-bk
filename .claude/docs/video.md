# The display

The AZBK draws the whole picture itself from its own memory, in a fixed
VGA frame of 1024x768 at 60 Hz; the БК's own screen is one of its modes
(the legacy 512x256 in the 4-colour or monochrome palettes, page 4 or
034).  Here the frame is the VESA 1024x768 timing at 64.8 MHz:

```
1024 + 24 + 136 + 160 = 1344 clocks a line     hsync negative, 136 wide
 768 +  3 +   6 +  29 =  806 lines a frame     vsync negative, 6 lines
64.8e6 / 1344 / 806 = 59.8 Hz
```

It is not the CEA 60.0 Hz mode (that wants 65.0 MHz, which the PLL
cannot make from 27 exactly); every sink tried on the siblings takes a
VESA mode within a percent, but whether a given one does is a board
question, and a black screen on a board is that before it is anything
else.  `hdmi_tx.v` sends three packets an island (the back porch is
160 clocks) and `ACR_CTS` is 64800 with N 6144 for exactly 48 kHz.

## What is drawn: 177230

Bits 2:0 the mode: 0 = 1 bit/pixel, 1 = 2, 2 = 4, 3 = 8 (256 colours),
4 = three layers of 8 bits (the top opaque pixel wins, 0 transparent),
5..7 as GID's `MakeScreenLine` has them.  Bits 4:3 the line length in
words: 32, 64, 128, 256 (a 256-colour line of 512 pixels is 256 words).
Bits 7:6 the horizontal stretch: every pixel 1, 2, 4 or 8 pixels wide
on the 1024 raster.  Bits 10:9 the vertical: every line 1, 2, 3 or 4
raster lines.  Bit 11: the registers written during a frame take
effect at the next frame (`f_sync`); otherwise they are live, as GID
has them per line and the hardware has them.  (For a few hours on 23
Sep 2026 the pages and horizontal scrolls were latched at the frame's
end under the 60 Hz mode; Dangerous Dave switches its page set live
and clears the other set at once, and the display showed the buffer
just begun to clear for the rest of every frame after a switch.  A
flip must be immediate.)  Bits 15:12 the roll length: the
number of rows the vertical scroll wraps in, as a power of two of the
line count.  177232, 177240, 177242 the pages of layers 0, 1, 2
(4 KB units of the 32 MB); 177244/177246/177250 the vertical scroll of
layers 2, 1, 0 and 177252/177254/177256 the horizontal (in pixels).

The palette: 177234 selects a cell, 177236 writes it (the AZ's own
15-bit form, R5G5B5) and reads it back.  338 cells: 0-255 the 256-colour
palette, 256-319 the sixteen legacy 4-colour sets of the БК-0011М
(177662 bits 11:8 pick one), 320-335 the 16-colour set, 336-337 the
monochrome pair.  The power-up contents are GID's tables, generated
into `az_palette.v` by `tools/palette.py`.

The controller's hotkeys (`mcu.md`): АР2+ЛАТ flips 177230 between
mode 0 with stretch x2 and mode 1 with x4 - the BK's screen as the
monochrome or the colour monitor would show it - when it is in one of
them; АР2+РУС reloads cells 256-337 from the power-up table.

The БК's registers: 177662 (write) bits 11:8 the legacy palette, bit
15 the screen buffer (page 4 or 034), bit 14 the 50 Hz interrupt
enable (active low); 177664 bits 7:0 the vertical scroll (`0330` for
none, the value less 0330 is the first line shown), bit 9 the extended
mode (set: all 256 lines; clear: lines 192-255 dark).

## How it is done here: `azvideo.v`

A raster counter (`hcnt`, `vcnt`) on the 64.8 MHz clock makes the
syncs and the data enable.  Every display line is fetched during the
raster line before it: all layers, as many 32-bit words as the line
needs (the line length in 16-bit words, halved), in bursts of four
words from `sdram.v`'s video port - one request at a time, the next
raised when the burst's four words have landed - into one of two sets
of three line buffers of 128 x 32 bits (BSRAM); the pipeline reads the
other set.  The row each layer fetches is a counter that starts the
frame at `scroll mod roll` (a subtraction loop run in the vertical
blanking, `mod_run`) and steps every `ys` display lines, wrapping at
the roll length; the word address is `page << 11 + row << (5 + llen)`.

The pixel pipeline is five stages ahead of the pixel it produces
(`PD = 4` plus the palette read): the horizontal position with the
layer's scroll, divided by the stretch, gives the word and the bit
field; the mode's rule turns the bits of up to three layers into a
palette index (a 256-colour byte, a legacy 2-bit pair through the
177662 set, a 4-bit nibble through the 16-colour set, a bit through the
monochrome pair); the palette RAM's second port gives R5G5B5, widened to
8 bits a channel by replicating the top bits.  Lines beyond the legacy
192 are black when 177664 bit 9 is clear; outside the active area the
pipeline emits black.

The capture at line 768: the "synced" registers are copied for the
next frame, and the row counters are reloaded.  Two things that are
not the display live here because they are the raster's: the frame
interrupt (IRQ2: the БК's 50 Hz when 177662 bit 14 is clear, the AZ's
50 Hz when 177346 bits 3 and 2 are set - both the frame-locked 48 Hz,
four of every five frames at line 769 - and its 60 Hz - the frame
itself, line 769 - when bit 3 is set and bit 2 clear; a level held 2
ms) and
the one-clock `frame_end` at line 769 that starts the blitter's
automatic run.  The 60 Hz is raised at line 769 itself, as MAXIOL's
controller raises it; for a few hours on 23 Sep 2026 it waited for
the blitter's run to end, on the reading that GID interrupts after
executing the packet, and that put a game's page flip mid-frame - a
wrong turn, reverted (`progress.md`, the twelfth board report).

The diagnostic strip of squares that the picture's corner carried
until 23 Sep 2026 is gone; its bits are the debug window's byte 27
(`top.v`).

A burst still in flight at the line's end: its remaining words arrive
after the buffers have switched and the counters reset, and until 23
Sep 2026 they were written at the new line's first positions and
stepped the word counter - the whole line one burst to the right, the
previous line's last burst at its left edge.  That was the first
board's flickering band at the left and its lines shifted by a burst
wherever the fetch ran close to the line's end under load (the CPU's
cycles come first in the arbiter; the simulation's ideal memory never
ran that late).  Such words are dropped now (`drain`), and the debug
window counts the lines whose fetch did not finish (`lines_short`) and
the lines a burst straddled (`lines_straddle`): the Debug page's
"video" line.

Only the visible window of a row is fetched (23 Sep 2026): the
pipeline shows `1024 >> xs` source pixels from the layer's scroll on,
so the bursts run from the scroll's word, as many as that width needs
plus one for the misalignment, wrapping at the row's end; the buffer
is indexed by the row's absolute word, so the pixel side is unchanged.
At the game's x4 that is 17 bursts of a 512-pixel row instead of 32;
at x2 or x1 it is the whole row as before.  The board's fetch had not
finished most of its lines (the Debug page: "53341 short lines" in
the game) with three whole rows a line.

Bandwidth: a 256-colour line of 512 pixels is 128 words, 32 bursts of
ten clocks (eleven with the late capture); three layers are 96 bursts, 960 of the line's 1344 clocks.
The processor's port has priority over the video's (a processor cycle
is one access a few of its clocks and must not time out; the fetch has
the rest of the line), so the worst case - three layers, the processor
and the blitter all busy - is the fetch not finishing a line, which
would show as the line's tail repeating the previous line's.  It has
not been seen in simulation; it is a thing to watch for on a board.

## The OSD

MiSTeryNano's `osd_u8g2.v`, 128x64 doubled, over the picture, as the
siblings have it.
