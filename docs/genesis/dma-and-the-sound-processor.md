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

**The recording was already late, and still is.** The pitch falls as the copy grows with or without
the guard, because a Z80 that wants the cartridge during a copy waits for the copy to end (S2, and
both emulators). Eighty sprites cost one percent. A painted screen whose copies run past the blank,
where the chip copies far more slowly, plays the recording a tenth flat, nearly two semitones. The
console's own games have the same loss and do not hide it; SGDK's read-ahead driver is the known
way to hide it, and is not built here.

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
