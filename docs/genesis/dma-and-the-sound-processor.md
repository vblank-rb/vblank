# Sega Genesis: a copy by the video chip while the sound processor reads the cartridge

Read and written on 2026-11-11. Nothing here was seen on a real console. Every claim names its
source; where the sources disagree or say nothing, this page says so.

## The two processors and the one bus

The 68000 runs the game. The Z80 runs the program that plays a recording
(`Runtime::Recordings#driver`): it reads one byte of the recording out of the cartridge for each
sample, about thirteen thousand times a second, through a window at `$8000-$FFFF` of its own
memory onto the 68000's bus.

The video chip can copy a block from the cartridge or from work RAM into video memory by itself
(DMA). It takes the 68000's bus for the length of the copy. VBlank starts two such copies, both
from work RAM, and no others (`grep COMMAND_DMA lib/vblank/ir/backends/genesis`):

| copy | where | from |
|---|---|---|
| the sprite table, every pass | `Runtime::Tiles#emit_sprite_rows_copied_by_chip` | the notes in work RAM |
| a painted screen's changed tiles | `Runtime::Paint#emit_upload_dma` | the picture's copy in work RAM |

Both go through `Runtime::Picture#emit_dma_started`. VBlank starts no fill and no copy inside video
memory.

## What Sega told its developers

**S1. Addendum 4, item 1, "Regarding The DMA"**, in Sega of America's *Genesis Technical
Bulletins* (scan, PDF page 18, between Bulletin #5 of November 26, 1990 and Bulletin #6 of April 2,
1991; the addendum carries no date of its own):
<https://segaretro.org/images/2/27/GenesisTechnicalBulletins.pdf>

> When using DMA's other than *FILL VRAM* and *VRAM COPY*, use the following method to program:
> 1) Send a bus request to the Z80.
> 2) Base the DMA destination address set section in RAM.
> 3) Rewrite the one leading word of data after the end of the DMA.
>
> 1) and 2) are used in all cases, except FILL VRAM and VRAM COPY.
> 3) is used for WRAM to VRAM, WRAM to COLOR RAM, and WRAM to VSRAM.

It gives no reason and does not say what goes wrong. It makes no exception for a copy from work
RAM: steps 1 and 2 are "all cases", and step 3 is for work RAM alone.

**S2. Genesis Technical Overview 1.00 (1991), section 7, "DMA TRANSFER"** (text of the scan):
<https://archive.org/stream/Genesis_Technical_Overview_v1.00_1991_Sega_US/Genesis_Technical_Overview_v1.00_1991_Sega_US_djvu.txt>

> The 68K is stopped during memory to VRAM/CRAM/VSRAM DMA, but the Z80 continues to run as long
> as it does not attempt access to the 68K memory space.

> In the case of ROM to VRAM transfers, a hardware feature causes occasional failure of DMA unless
> the following two conditions are observed: --The destination address write (to address $C00004)
> must be a word write. --The final write must use the work RAM.

Section 7 says nothing of the Z80's bus request. Its section 4, "Z80 CONTROL", gives the bus
request as the way to reach the Z80's memory: write `$0100` to `$A11100`, wait for bit 8 to read
0, and write `$0000` to let go.

**S3. Addendum 3, item 1, "When The Z80 Cannot Do A 68000 Bus Access"** (same scan, PDF pages
13-14), and **Bulletin #4, September 7, 1990, "Reading the controller pads"** (PDF page 7): a
68000 access to `$A100xx` (the controller ports) just before a Z80 access to the 68000's bus
shortens the Z80's bus cycle, and "the Z80 cannot read or write good data". The fix given is a
bus request round every access to `$A100xx`.

**S4. Bulletin #3, August 2, 1990** (PDF page 4): a bus request in the main routine and another
in an interrupt break each other; interrupts go off before the request.

The other bulletins (to #20, 1993) say nothing more about DMA and the Z80. Bulletin #12 is about a
reset during a DMA.

## What collides, and what is spoiled

Sega's text does not say. The three accounts found:

- **SGDK** (`inc/config.h`, `HALT_Z80_ON_DMA`, commit `2a8ddf55`,
  <https://github.com/Stephane-D/SGDK>): "Some Megadrive models need it to prevent some possible
  DMA transfer corruption or even 68000 memory or Z80 invalid data fetch in very rare case. This
  actually happen when Z80 access the main BUS exactly at same time you trigger a DMA operation."
- **Kabuto's hardware notes** (v1.5, one person's tests on one early console, mirrored at
  <https://plutiedev.com/mirror/kabuto-hardware-notes>): a Z80 that wants the bus during a DMA
  waits for the DMA to end; and, marked as recalled from memory, "If the Z80 tries to access ROM
  while the VDP is doing a DMA from 68k RAM this can lead to corruption of RAM contents", "one of
  the reasons Sega advised developers to pause the Z80 before doing DMA". He puts it at about once
  a day in an ordinary game, and every few seconds in a test made to provoke it.
- **Sega** (S1) gives the rule only.

So: a copy from work RAM is exposed, by every account, and Kabuto's names that case above all. The
accounts disagree on what is spoiled (the copy, work RAM, or the Z80's read), and none is a
measurement published with its method. Which console revisions do it is not in any source read.

**The first word of a copy from work RAM** is Sega's step 3. Nothing read says what happens to that
word, or whether steps 1 and 2 make step 3 unnecessary.

**The 128K boundary** is a different matter: the chip counts its source address inside one 128K
block and wraps at its end (SGDK `src/dma.c`, `DMA_queueDma`, "DMA works on 64 KWord bank"; the
Sonic 3 & Knuckles disassembly's `Add_To_DMA_Queue`). Work RAM is the top 64K of the last block, so
a copy from work RAM cannot cross one.

## What the emulators model

Neither emulator read models the fault. Both model the Z80 waiting.

- **Genesis Plus GX**, the emulator the suite plays in (the libretro fork at `f27655b5`, and
  upstream at `2499cd3e`, <https://github.com/ekeeke/Genesis-Plus-GX>): `core/memz80.c`,
  `z80_request_68k_bus_access`: a Z80 access to the window during a DMA from the 68000's bus moves
  the Z80 on to the DMA's end, and every such access costs both processors a little time. Nothing
  is corrupted.
- **BlastEm** (mirror at `ec73825e`, <https://github.com/libretro/blastem>): `genesis.c`,
  `z80_read_bank`: while the bus is busy the Z80 is moved on to the 68000's time, and each read
  costs both processors time. `read_dma_value` carries the note "TODO: Figure out what happens when
  you try to DMA from weird adresses like IO or banked Z80 area". Nothing is corrupted.
- Exodus and Nuked-MD were not read.

So no test in an emulator can fail for want of the guard, in this suite or in BlastEm.

## What a console's own games do

**Sonic 3 & Knuckles** (public disassembly, commit `73de97c6`,
<https://github.com/sonicretro/skdisasm>), whose Z80 plays recordings out of the cartridge:

- `stopZ80` (`sonic3k.macros.asm`) writes `$100` to the bus request and loops until bit 0 reads 0;
  `startZ80` writes 0.
- Its blank routine (`VInt_8`, `sonic3k.asm`) stops the Z80 once, reads the pads, copies the
  palette, the scroll table and the sprite table by DMA from work RAM, runs its queue of other
  DMAs, and only then starts the Z80: one stop for the whole of the blank's work.
- `dma68kToVDP` writes the last word of the command from a word of work RAM (`DMA_trigger_word`),
  quoting S2. It does not rewrite a leading word afterwards (S1's step 3).
- Its Z80 program (`Sound/Z80 Sound Driver.asm`, `zPlayDigitalAudio`) paces each sample with a
  counted loop. It has no clock and does nothing to make up the time it was stopped: a recording
  simply runs late by the length of each stop.

**Sonic the Hedgehog** (commit `3b6986eb`, <https://github.com/sonicretro/s1disasm>) does the same:
`stopZ80` and `waitZ80` before, `startZ80` after, and `writeVRAM` writing the last word from work
RAM (`Macros.asm`).

**SGDK** stops the Z80 round a DMA unless told not to (`DMA_doDma`), with the last word written
from memory "to avoid possible failure on some MD". For recordings that must not run late it has a
second way: the 68000 sets a flag in the Z80's memory and its XGM driver keeps off the bus, playing
from samples it read ahead (`Z80_setBusProtection`, `inc/z80_ctrl.h`).

## What VBlank does

**A game with no recordings** is not exposed: its Z80 is held stopped from power-on
(`Runtime::Boot#emit_sound_quiet`) and never reaches for the bus. It carries no bus request at its
copies.

**A game that plays recordings** asks for the Z80's bus and waits for it just before the word that
starts each copy, and gives it back after the copy (S1 step 1, as the games above do).

**Every game** writes the command as two words read from work RAM, the stack (S1 step 2, S2).

**Not done: S1's step 3**, the leading word written again after the copy. Neither game read does
it, and nothing read says what it guards against.

**Not done: a bus request round the pad read** (S3). `Runtime::Frame`'s `rt_buttons_now` reads
`$A10003` in the blank's interrupt with the Z80 running. By S3 a recording's byte can be misread at
that moment, which would be heard as a click. Guarding it means a bus request inside an interrupt,
which S4 says must then be kept apart from the main routine's requests.

## What the guard costs

Measured in Genesis Plus GX at `f27655b5`, a tiled game moving its sprites every pass with a
thirty-sample recording looping at 13000 samples a second (a 433.333 Hz square wave), over 120
frames.

| | 68000 cycles a frame, before | with the Z80 stopped | and the command from RAM | pitch before | pitch after |
|---|---|---|---|---|---|
| 24 sprites, no recording | 14268.571 | 14268.571 | 14292.571 | | |
| 80 sprites, no recording | 42183.571 | 42183.571 | 42207.571 | | |
| 1 sprite, recording (no copy) | 5096.467 | 5096.467 | 5096.467 | 425.681 Hz | 425.681 Hz |
| 24 sprites, recording | 16750.171 | 16827.505 | 16851.988 | 423.453 Hz | 424.012 Hz |
| 80 sprites, recording | 44664.705 | 44741.838 | 44764.813 | 421.484 Hz | 420.461 Hz |
| painted, sixteen tiles a pass, recording | 87714.729 | 88837.486 | 89304.426 | 389.456 Hz | 384.262 Hz |

The stop itself is about 77 cycles a copy. It changes the recording's pitch by a quarter of one
percent or less in the tiled game, either way.

**The recording was late, with or without the guard.** The pitch in that table falls as the copy
grows, because a Z80 that wants the cartridge during a copy waits for the copy to end (S2, and both
emulators). Eighty sprites cost one percent. A painted screen whose copies ran past the blank, where
the chip copies far more slowly, played the recording a tenth flat, nearly two semitones. The next
section is what was done about it.

## Keeping a recording's pitch through the stops

Measured the same day, the same way (Genesis Plus GX at `f27655b5`, the same games, 120 frames, the
pitch from the first upward crossing of the sound's middle to the last).

### Where the time went

The Z80's program counted its own cycles from one sample to the next, so every stop made the
recording late by its length, and nothing made it up.

- **The program itself was slow.** A sample took it 280 cycles with the emulator's three for a read
  of the cartridge, against the 275 that 13000 samples a second asks: 425.7 Hz for 433.3 with
  nothing else going on.
- **The sprite table's copy** holds the Z80 for the copy's length, once a frame, in the blank:
  about three lines of the screen for eighty sprites (640 bytes at the blank's 205 bytes a line),
  which is the one percent.
- **A painted screen's copies were not in the blank at all.** Looking through the marks of 1120
  tiles for the changed ones took the 68000 about 27000 cycles, 56 lines, and the blank is 38. So
  the sixteen copies began as the picture was being drawn, where the chip copies 18 bytes a line,
  and held the Z80 for about 50 lines each time the picture was sent.
- **Every FM register the 68000 writes stops the Z80 too**, for the write and the chip's three
  waits round it. A song's note is some thirty registers. Measured with a wave part playing a note
  every two frames: 398 Hz for 433. This one is not fixed here; see "Not done".

### What others do, and what it costs

- **Count cycles and lose the time.** Sonic 3 & Knuckles (above). Costs nothing; plays flat.
- **Read ahead, and keep off the bus.** SGDK's XGM driver (`src/snd/drv_xgm.s80` at `2a8ddf55`)
  keeps 1024 bytes of the Z80's 8192 as a ring of samples (`PCM_BUFFER0`-`PCM_BUFFER3`, `$1800`-
  `$1BFF`), fills it from the cartridge between samples, and sounds one sample from it every 254
  cycles, 14 kHz. The 68000 sets a byte in the Z80's memory before its copies and clears it after
  (`PROTECT_ARG`, `Z80_setBusProtection` in `src/z80_ctrl.c`, called round `DMA_flushQueue` in
  `src/sys.c`), and while it is set the driver sounds what it has and reads nothing. `inc/z80_ctrl.h`
  says of it: "the success of the operation is not 100% garantee". Mega PCM 2
  (<https://github.com/vladikcomper/MegaPCM>, README) does the same with no flag: "Zero-config DMA
  protection (no extra flags to set and unset, simply don't stop Z80 on DMA's)", and "can survive up
  to 24 Kb (!) of DMA transfers".
  **Both need the Z80 running through the copy**, which is what S1 says not to allow. SGDK's own
  default stops it (`HALT_Z80_ON_DMA 1`, `inc/config.h`: turning it off is "at your own risk"), and
  a Z80 that is stopped sounds nothing from any buffer. So reading ahead buys nothing while the
  guard stands, and costs an eighth of the Z80's memory.
- **Time the samples by a clock that runs through a stop.** The FM chip has two timers. Sega's
  manual gives their lengths ("Genesis Sound Software Manual", from page 88 of S2's scan: timer A lasts
  "18 * (1024 - TIMER A) microseconds", timer B "288 * (256 - TIMER B ) microseconds", register
  `$27` starts them and clears their flags, and "No one at Sega has used the timer feature"). The
  figures are for a round 8 MHz; the tick is 144 cycles of the chip's clock (Genesis Plus GX,
  `core/sound/ym2612.c`, `INTERNAL_TIMER_A`, counted once a sample of the chip's), which is the
  68000's, 53693175 / 7 Hz on NTSC (`MCLOCK_NTSC`, `core/system.h`): 18.77 microseconds, and timer
B's is sixteen of those. They are
  read at the chip's own address in the Z80's memory, not through the 68000's bus.
- **Count the screen's lines.** The Z80 can read the video chip's line counter, but through the
  68000's bus, which is the access S1 and S3 are about. Not taken.

### What VBlank does now

**The Z80 sounds a sample on each tick of timer A**, set to four ticks: 13316.8 samples a second.
A play's step is worked out for that rate, so a recording keeps the rate it was recorded at. The
gap between two samples no longer depends on how long the work between them took.

**The samples a stop covered are passed over.** A timer's flag says a tick came, not how many. Timer
B is set to come round with every 256th tick of timer A; the program counts the samples it sounds in
a byte, and what the byte is short of 256 when timer B's flag shows is the number of ticks a stop
covered. It moves on that many samples without sounding them. The DAC holds its last sample through
a stop, as it does in the console's own games, and the recording is back where the clock says within
256 samples (19 ms). A shortfall over 127 is not believed, so a stop of more than about 9 ms in one
round is not made up.

**The guard is unchanged**: a bus request round every copy, as S1 says. The program still reads each
sample from the cartridge as it sounds it, so when it reads has not changed and nothing about S1
has. A read-ahead that kept off the bus during a copy would still be bound by S1, which makes no
exception for a Z80 that promises not to look.

**The Z80 now writes two FM registers** (the DAC's and `$27`), and the 68000 can stop it between
naming one and writing it. The Z80 notes the register it is on in its mailbox before naming it, and
the 68000 names that one again before letting go (`Recordings#emit_bus_given_back`).

**The chip's busy time.** Genesis Plus GX holds the chip busy for 32 of its cycles after each value
written (`core/sound/sound.c`, `YM2612_Write`), a third of a sample. The program's two values a
sample are laid out more than that apart, and it does not test the busy bit between them. Whether a
real chip takes both every time is not known from anything read.

**A painted screen's changed tiles are found before the blank and only copied in it**
(`Paint#emit_upload_find`): each run of tiles is queued as the seven words the video chip is sent,
as the console's own games queue theirs (`Add_To_DMA_Queue` in the Sonic 3 & Knuckles disassembly,
`DMA_queueDma` in SGDK), up to 32 runs and 100 tiles a blank. Sending sixteen runs takes about 18
lines of the blank with a recording playing and 13 without.

### What it costs

| | before | after |
|---|---|---|
| the Z80's program | 206 bytes | 422 bytes, of 8192 |
| the Z80's mailbox | 20 bytes | 22 bytes |
| the Z80's time for a sample | 280 cycles, measured | at most 254 of the 269 between two ticks, by a count of its instructions |
| work RAM, a painted game | | 452 bytes more (the queue) |
| cartridge code, a painted game (`animate`, `fonts`, `grid_cursor`, `pixels`, `sprite_mover`) | | 116 bytes more each |
| 68000 cycles a frame, painted, sixteen tiles a pass, recording | 89304.426 | 89386.635 |
| 68000 cycles a frame, painted, no recording | 85289.143 | 85789.143 |
| 68000 cycles a frame, 80 sprites, recording | 44764.813 | 44765.921 |

A game with no recordings and no painted screen builds the same cartridge as before.

### The pitch, before and after

| | before | after |
|---|---|---|
| 1 sprite, recording | 425.681 Hz | 433.484 Hz |
| 24 sprites, recording | 424.012 Hz | 433.500 Hz |
| 80 sprites, recording | 420.461 Hz | 433.529 Hz |
| painted, sixteen tiles a pass, recording | 384.262 Hz | 433.119 Hz |

The recording is 433.333 Hz. `test_genesis_sound.rb` holds the first, third and fourth to within
2 Hz.

### Not done

- **A song's FM writes still hold the Z80 long enough to hear.** The timers make the time up, but a
  note's thirty writes are thirty stops in a row, some milliseconds with the DAC standing still. The
  fix is on the 68000's side: one stop for a note's writes, or fewer waits inside it
  (`Sound`'s `rt_fm_write`).
- **PAL.** The chip's clock is a little slower there (53203424 / 7 Hz, `MCLOCK_PAL`), so a recording plays about
  one percent flat. The step is worked out for NTSC.
- **The answers table still says 13000 samples a second**, which is the rate the interpreter counts
  a recording's place at. The Z80 sounds 13316.8.

## How to see it

No emulator read can show the fault. On a real console:

1. Build a game with many sprites moving every pass and a recording looping, for the Genesis. The
   guarded cartridge is what `main` builds; for one without the guard, build from the commit before
   `Stop the Z80 round a DMA in Genesis Picture#emit_dma_started`.
2. Put each on a flash cartridge and play it on an early console (the fault is reported of "some"
   models, unnamed; Kabuto's tests were on a Model 1).
3. Leave each running and watch the sprites, for hours: a sprite in the wrong place or of the wrong
   shape for one frame is the fault. By Kabuto's figure an ordinary game shows it about once a day,
   so a short watch that shows nothing proves nothing.

What the suite can hold is the code the cartridge carries, and it does:
`test/lowering/genesis/vblank/ir/backends/genesis/test_genesis_dma_guard.rb`.
