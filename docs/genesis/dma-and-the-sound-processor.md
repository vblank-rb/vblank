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

**A game that plays recordings** asks for the Z80's bus and waits for it before the command that
starts each copy, and gives it back after the copy (S1 step 1, as the games above do).

**Every game** writes the command as two words read from work RAM, the stack (S1 step 2, S2).

**Not done: S1's step 3**, the leading word written again after the copy. Neither game read does
it, and nothing read says what it guards against, so it is left until a source does.

## The pad read

**The controller is read with the Z80 stopped** (S3), in a game that plays recordings: the blank's
interrupt asks for the bus, waits for it, reads the pad (`rt_pad_read`) and lets go
(`Recordings#emit_bus_for_pad`). The version register, also at `$A100xx`, is read only with the
Z80 stopped too (`rt_recordings_send`).

**Every stop the main program makes holds interrupts off** from the request until it lets go
(`Recordings#emit_bus_taken`, `#emit_bus_given_back`), which is S4's "interrupts go off before the
request". So the interrupt never asks for the bus inside one of the main program's stops, and its
own stop is over before the main program runs again. That covers each copy, each write into the
Z80's queue and mailbox, and the version register's read.

**One stop for the whole blank, as Sonic 3 & Knuckles makes, was tried and measured, and not
taken.** The blank's interrupt asked for the bus and left it held through the copies, the buttons
and the music, until the end of the pass's wait. The blank's work here is mostly the 68000 writing
the picture's maps and tiles and playing the music, not copies, so the Z80 stood still for some
sixty samples a frame and a recording played audibly flat, with gaps of whole waves, even with
nothing else going on. Sonic 3 &
Knuckles makes its blank's work almost all copies. Here each copy and each write into the Z80's
memory is a stop of its own, a few instructions long.

**What it costs.** A game that plays recordings carries the interrupt's stop and three
instructions more at each stop of the main program (the status register kept, interrupts held off,
and the status register put back). A game with no recordings builds the same cartridge, byte for
byte: every example built for the Genesis, a game of sprites, a painted one, and one with a song,
a wave and a beep. A recording's pitch does not move measurably.

`test_genesis_dma_guard.rb` holds the code: the pad read between the request and the release, and
every copy's request with interrupts held off.

**Not done:** nothing here ran on a console. The fault S3 describes is not modelled by Genesis Plus
GX, so no test here can hear it; on a console, a game playing a long recording while a player
presses buttons would click without the guard.

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
- **Every FM register the 68000 writes stopped the Z80 too**, for the write and the chip's three
  waits round it. A song's note is some thirty registers. Measured with a wave part playing a note
  every two frames: 398 Hz for 433. See "A song's notes" below.

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

**The Z80 writes two FM registers** (the DAC's and `$27`) every sample. In a game that plays
recordings the 68000 writes no FM register at all ("A song's notes" below).

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

**The pitch.** A recording now plays at its own pitch with one sprite, eighty sprites and a painted
screen alike; `test_genesis_sound.rb` holds each of those to within 2 Hz of the 433.333 Hz recorded.

## A song's notes

Measured on 2026-11-14 the same way, with a wave part playing a note every two frames
(`test_genesis_sound.rb`, `test_a_recording_keeps_every_wave_under_a_song_playing_a_note_every_two_frames`).

### Where the time went

A note sets its voice's every FM register, some thirty of them, and the 68000 wrote each one
itself: it stopped the Z80, waited on the chip's busy bit before the register and before the value,
wrote, named the DAC's register again and let go. With the timers making the time up afterwards,
the DAC stood still through each note's writes and then passed over what they covered, which was
whole waves: the recording crossed its middle at 379.3 Hz over a third of a second, with gaps
between two waves of up to 2.5 waves' length.

### What the console's own games do

Their sound drivers run on the Z80 and write the FM chip themselves (Sonic 3 & Knuckles' `Sound/Z80
Sound Driver.asm`, SGDK's XGM driver): the 68000 hands the Z80 what to play and never touches the
chip. That is what VBlank does now.

### What VBlank does now

- **The FM chip is the Z80's.** In a game that plays recordings, `rt_fm_write` puts each write in a
  queue in the Z80's memory (`Recordings::QUEUE`, 256 entries of three bytes, one byte on each of
  three pages so one count finds an entry), and the Z80 makes one entry between two samples, after
  the timer's flag is cleared, looking at the chip's busy bit first. A new play is an entry of the
  same queue, so a play and the notes round it reach the Z80 in the order the game made them.
- **A write that changes nothing is not queued.** The 68000 keeps each register's last value
  (`Recordings::FM_KEPT`) and drops a write of the same value. A voice playing one instrument changes
  a few registers from note to note, so a note is a few entries, not thirty. The key
  register and the pitch registers are always sent: a key write is a key going down or up, and the
  chip takes a pitch's high byte only as its low byte is written.
- **A sample with an entry takes longer than a tick.** The tick it runs over is one the second
  timer finds missing, so the recording is held one sample longer and then passes over one.
- **The 68000 still stops the Z80 for each entry**, for a few writes into its memory and no chip
  waits ("The pad read" says why not one stop for a frame).
- **PAL.** The chip's clock is a little slower there (53203424 / 7 Hz, `MCLOCK_PAL`), so a timer's
  ticks come further apart. `rt_recordings_send` reads the version register's PAL bit (with the Z80
  stopped, as S3 asks) and makes the step `PAL_STEP_EXTRA` 65536ths longer. Genesis Plus GX plays a
  cartridge whose header names Europe alone as PAL: 429.5 Hz before, 433.0 after.
- **The third FM voice's mode** is the top two bits of `$27`, which the Z80 writes every sample. A
  write of `$27` from the game's side is written into the value of each of the Z80's own writes of it
  (`Recordings::TIMER_WRITES`). Nothing in VBlank sets that mode yet.
- **The answers table** says the Z80 sounds about 13300 samples a second and plays a recording at the
  rate it was recorded. The interpreter still counts a recording's place at 13000 a second, which is
  what the game can tell of it.

### What it costs

| | before | after |
|---|---|---|
| the Z80's program | 422 bytes | 490 bytes, of 8192 |
| the Z80's memory besides | 22 bytes of mailbox | 21 bytes of mailbox and 768 of queue |
| work RAM, a game with recordings | | 1024 bytes more (the registers' last values) |

A game with no recordings builds the same cartridge as before.

**The pitch.** A recording keeps its pitch under a song playing a note every two frames, across two
banks going round, and on a PAL console; `test_genesis_sound.rb` holds each to within 2 Hz of the
433.333 Hz recorded, and the first two to no gap of a quarter more than a wave.

### Not done

- **Nothing ran on hardware.** The Z80 writes three values in a sample that has an entry (the DAC's,
  `$27`, the entry's) and tests the busy bit before the entry's only. Whether a real chip takes the
  DAC's and `$27` every time, spaced by instruction count, is not known from anything read.

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

For the pad read: build a game that loops a long recording of a pure tone and does nothing else,
put it on a console, and press and hold buttons while listening for clicks. For one without that
guard, build from the commit before `Read the pad with the Z80 stopped in Genesis
Recordings#emit_bus_for_pad`.

What the suite can hold is the code the cartridge carries, and it does:
`test/lowering/genesis/vblank/ir/backends/genesis/test_genesis_dma_guard.rb`.
