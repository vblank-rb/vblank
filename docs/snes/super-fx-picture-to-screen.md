# Super Nintendo: getting a picture the Super FX drew onto the screen

Read, measured and written on 2026-11-11. Nothing here was seen on a real console. Every claim
names its source; where the sources disagree or say nothing, this page says so. No retail
cartridge was traced: the project's notes name no place on this machine where one is kept, so what
the console's own games did comes from published source code and documentation alone.

## The question

A first-person view painted by the Super FX (`draw_column_at` in a routine marked `on_chip: true`),
120 columns 120 high, took 8 frames a pass. Of those, 4 to 5 were spent sending about 17K of
painted tiles and map to video RAM, a vertical blank at a time. Was that the console's limit, or
VBlank's way of doing it?

## What limits the copy

- **The copying engine (DMA) moves 8 master clocks a byte**, and a line is 1364 clocks of which the
  processor is stopped for 40: 165.5 bytes a line. (fullsnes, "SNES DMA Transfers": "fixed 8 master
  cycles per byte for DMA"; SNESdev wiki, "Timing": "1364 master clocks = 341 dot cycles", "The CPU
  pauses for 40 master clocks in the middle of each scanline for DRAM refresh";
  <https://problemkaputt.de/fullsnes.htm>, <https://snes.nesdev.org/wiki/Timing>.)
- **Video RAM takes writes only in the vertical blank or with the screen off.** fullsnes, "SNES PPU
  Control", INIDISP: "7 Forced Blanking (0=Normal, 1=Screen Black)", "In Forced Blank, VRAM, OAM and
  CGRAM can be freely accessed (otherwise it's accessible only during Vblank)."
- **The blank of a 224-line picture is 37 lines**, 225 to 261: 6,123 bytes at most (SNESdev wiki,
  "Timing", the table's NTSC row). Measured in the suite's bsnes on 2026-11-03 with a cartridge
  made to try it: with the screen on 6,005 bytes land in one blank, 165 a line; with the screen off
  for the whole frame, about 43,200.
- **The chip cannot draw while its RAM is being copied.** bsnes,
  `sfc/coprocessor/superfx/memory.cpp`, `SuperFX::read`: `while(!regs.scmr.ran) { step(6); ... }`
  (bsnes at `78474e5d`, <https://github.com/bsnes-emu/bsnes>); fullsnes, SCMR: "RON/RAN can be
  temporarily cleared during GSU operation, this causes the GSU to enter WAIT status".

So a view of 8 bits a pixel 120 lines high in 15 tiles across, 240 tiles, is 15,360 bytes of tiles:
three blanks of a whole-screen picture at the very least, before any map.

## What the console's own games did

### DOOM (primary: the author's source)

Randy Linden's source, <https://github.com/RandalLinden/DOOM-FX> at commit `90af5149`, files under
`source/`:

- **The view is 216 by 144 pixels of 8 bits a pixel**, drawn at half width. `rle.i`: `RLViewCharX
  equ 27`, `RLViewCharY equ 18`. `rlinit.a`, `_RLInitPPU`: `lda #$03 ; Mode3 (BG1 256 Colour/BG2 16
  Colour)`. `rlgsu.a`, `_RLInitGSU`: `lda #%00011111 ; 160 Pixels, GSU has ROM/RAM, 256 Colour`.
  `rldraww.a`, `_RLDrawWallsLow`: each pixel is plotted twice across. The chip's own PLOT writes the
  planes; there is no pass that turns bytes into planes.
- **The screen is off above and below the picture.** `rle.i`: `RLVIntTop equ ((224-RLPixY)/2)-1`
  and `RLVIntBottom equ 224-((224-RLPixY)/2)-1`, lines 23 and 199. `rlirq.a`, `_RLIRQBottom`:
  `lda #$80 ; Disable Display`, then the copies; `_RLIRQTop`: `lda >INIDISP_S ; Enable Display`.
  The picture shows for 176 lines, and about 86 lines of every frame are free for copying (worked
  out from those constants; the source does not say the number).
- **A third of the view is copied each frame.** `rlirq.a`, `_RIBDrawXFer`: nine copies of
  `#(RLViewCharY*64)` bytes, 1,152 each, a column of tiles at a time: 10,368 bytes a frame, 31,104
  for the view. The chip draws one third into one buffer (`rlram7.a`, `_RLGSUChrDef`), waits for it
  to be sent, and draws the next (`rlgsu.a`, `_RLGSUReqDrawA/B/C` wait on the flag `rlfDraw`).
- **Two thirds are sent to tiles that are not on the screen**, and shown by sending the other map
  with the last third (`rle.i`: `vmCHRD ; (SWAP A)`, `vmCHRE ; (SWAP B)`; `rlirq.a`, `_RIBDrawC`,
  "FLIP VIEW BUFFERS"). So a picture is never seen half sent.
- **A picture takes four frames or more.** The bottom interrupt has four phases, one a frame
  (`_RIBPhaseCode`: `_RIBDrawA` to `_RIBDrawD`), and the line that would make them three is
  commented out (`; jmp _RIB3000 ; Convert 4-Phase to 3-Phase`). That is read from the phase logic,
  not stated in the source: 15 pictures a second at best. The source has a table for up to 39
  frames a picture (`rlmisc.a`, `_RLSpeedFPSRatios`).
- **The status bar is a second layer and sprites**, sent only when a number changes (`_RIBDrawA`
  compares `PlayerFace` with `PlayerFaceOld`).

### Star Fox (secondary: no source that may be read was found)

No disassembly-level account was readable. What is published, each marked by its kind:

- 224 by 192 pixels of 4 bits a pixel, 21,504 bytes (tepples and "93143", SNESdev forum,
  <https://forums.nesdev.org/viewtopic.php?t=19162>; no method given).
- Three frames to send a picture, so 20 pictures a second at best, with the screen off above and
  below it ("93143", the same thread: "Black areas above and below the active area can be forced
  blank ... Star Fox caps at 20 fps for this reason"; and
  <https://forums.nesdev.org/viewtopic.php?t=17218>: forced blank "can be used to extend VBlank like
  in Star Fox"). Vitor Vilela, who patches the game, is quoted by a search engine as saying the
  same of the three frames; his page could not be opened.
- Not found: the bytes it copies a frame, the lines it switches off, whether it swaps tiles.

### What others worked out (secondary)

- lidnariq, SNESdev forum, <https://forums.nesdev.org/viewtopic.php?t=20068>: "You can upload 165.5
  bytes per scanline that the PPU is off. This works out to 256x144@30fps at 8bpp, or 256x184@30fps
  at 4bpp."
- Rebecca Heineman on Another World, which has no Super FX
  (<https://fabiensanglard.net/another_world_polygons_SNES/>): the view was cut to 224 by 160
  because "pushing all these bytes from RAM to VRAM was a problem", and "To avoid tearing, a double
  buffer is used in VRAM."

### What this comes to

Every account agrees on the way: **a view smaller than the screen, the screen switched off on the
lines it does not use, and the copy made on those lines as well as in the blank.** DOOM, the one
read at first hand, sends 10,368 bytes a frame that way, nearly twice what a blank holds, and a
whole view of 31,104 bytes in four frames. No game read sent a painted picture a blank at a time
with the whole screen on, which is what VBlank did.

## What VBlank does now

**Where the top and the bottom of a painted screen on a Super FX cartridge are black, the screen is
off there**, and the lines are used for the copy (`Runtime::Letterbox`). It is not a setting: a
game clears to black and paints its view, and the rows of tiles above the first one painted and
below the last are the lines switched off. With the screen off a line is black, and a row of tiles
that all show the clear tile is the clear colour, so the picture is the same picture. The checked
runs hold it to the interpreter's on every pass.

- **The band** of lines kept on is worked out as each pass ends, from the rows the pass marked
  changed (`rt_letterbox_rows`). It is the last pass's rows and this one's together, since the last
  pass is on the screen until this one has arrived.
- **The whole screen stays on** unless the clear colour is black, no fade or tint is in force and
  the camera is where it started.
- **The screen is switched by the console itself**, from a table of lines (HDMA on channel 7,
  writing INIDISP). DOOM uses two interrupts; a table needs none, and goes on while the chip owns
  the cartridge and the processor's interrupt vectors read from work RAM.
- **The copy starts as the screen goes off below the band**, before the blank, and may run through
  the blank to the line before the band's first. `Runtime::Blank`'s routines count that room. The
  pass's wait still ends after the blank's interrupt, so the frames a pass took are counted as
  before.
- **Only the band's rows of the map are sent.** Every row outside it showed the clear tile before
  and shows it still.
- **`rt_paint_prepare` asks about each tile with a byte-wide A and the tile's number kept in X.**

Two things found on the way are fixed with it:

- **The blank's interrupt takes its lines out of the room.** A copy counted before the interrupt
  and made across it ran three lines past what was counted, into the lines shown, and bsnes dropped
  those tiles. The room counted before the blank is now less the interrupt's lines.
  `test_a_big_view_cut_at_any_line_looks_as_on_the_interpreter` fails without it.
- **The first line after the screen goes off is left alone.** fullsnes, INIDISP: "Forced blank
  doesn't apply immediately... so one must wait whatever (maybe a scanline) before VRAM can be freely
  accessed... or is it only vice-versa". Nothing read settles it, and bsnes showed no fault either
  way, so the line is not used.

### The other question: why `rt_paint_prepare` took twice its count

It did not run twice. **A Super FX cartridge's ROM is read at the slow speed** (`Runtime::Boot`,
`fast: false` for that board), 8 master clocks a cycle where a plain cartridge takes 6, and the
loop was about 125 cycles a tile where a count of its instructions had been taken as fewer.
Measured by address (`take_processor_time`): the first instruction of the loop, four cycles long,
cost 32 clocks a tile. For the 240 tiles of the 120 by 120 view that is about 1,010 clocks a tile,
178 lines. The loop is now about 138 lines.

`rt_paint_column`, the console's own routine for a column, was already left out of a cartridge
whose columns are all the chip's (`Lowering::Paint#paints_columns?`); a test holds that now.

## What it costs, before and after

Measured in the suite's bsnes, the cost test's game with its wall moving every pass, over twelve
passes after the first six. A frame is 262 lines.

| | before | after |
|---|---|---|
| 120 columns 120 high, frames a pass | 8.000 | 4.000 |
| 40 columns 40 high, frames a pass | 2 | 1.000 |

Where a pass of the 120 by 120 view goes, in lines:

| | before | after |
|---|---|---|
| the chip painting | 619 | 617 |
| `rt_paint_prepare` | 178 | 138 |
| the routine's own 65816 code (variables across, the map's cells) | 77 | 78 |
| the copy to video RAM | 100 | 100 |
| setting the copies going | 37 | 20 |
| the clear | 16 | 17 |
| waiting | 1,044 | 57 |
| the blank's interrupt | 20 | 7 |
| all | 2,096 | 1,048 |

The copy is 15,360 bytes of tiles and 1,024 of map, sent in one stretch of lines with the screen
off. The view's 16 rows of tiles are lines 49 to 176, so that stretch is 48 lines below the view,
the blank's 37 and 49 above it, 134, of which the first, the last and the interrupt's four are not
counted as room: 128, about 21,000 bytes.

**Against DOOM**: 31,104 bytes of view in four frames or more, 15 pictures a second at best. A
view of 15,360 bytes here is at 15 a second, and it is the chip's painting that holds it there now,
not the copy: the copy would fit a pass of three frames.

## Not done

- **The chip paints 14,400 pixels in 617 lines**, 58 of its clocks a pixel. Three frames a pass
  needs that under about 420 lines.
- **A game that fades to black, changes colours as it runs, or draws text in a picked colour** keeps
  the whole screen on (`Carries#letterboxes?`). The black of the bars would have to follow the
  colours, and the display's brightness is the fade's to set.
- **A pass that changes the band starts its copy at the blank's interrupt**, with the lines above
  the view only, because the table changes in the blank. A view whose top and bottom rows move every
  pass gains less than one that paints the same rows each pass. Such a pass, when it is bigger than
  that room, is seen arriving (one frame, measured: the pass the lines first go off on).
- **A picture bigger than the lines with the screen off is still seen arriving.** DOOM sends to
  tiles off the screen and swaps the map. A painted screen here is 896 tiles of 64 bytes, 56K of
  the 64K of video RAM, so there is no room for a second set; a view held to part of the screen
  would have it.
- **Four bits a pixel.** Star Fox's depth halves the bytes and the chip's writes. A painted screen
  here is always eight.
- **The interrupt's lines are a count, not a measurement, for a game that reads two controllers**:
  twice one controller's.
- **Nothing was seen on a console.** Two things to look for on one: the first line shown after the
  screen comes back on (fullsnes asks whether it "shows garbage pixels"), and the early processor
  revision that is reported to stop when a copy ends as a line-by-line copy begins (not read at
  first hand here).

## How to see it

`VBLANK_CHIP_FRAMES=1 rake test:lowering:snes TEST=test/lowering/snes/vblank/ir/backends/snes/test_snes_chip_columns.rb`
prints the frames a pass of both views. `rom.profile` on a Super FX build says where a pass went;
its waiting share counts the wait for the screen to go off.
