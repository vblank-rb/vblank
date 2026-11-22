# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # A game's recordings (`play_sample`, `stop_sample`, a song's recorded part).
          #
          # The FM chip's sixth voice can be a speaker held by hand: with its DAC on, the chip plays whatever
          # byte it was last told in register $2A, so a recording is a byte written thirteen thousand times a
          # second. That is far too often for the 68000, with a game to run, so it is the sound processor's
          # one job: the Z80 is sent a little program at power-on (#driver), which reads the recording from
          # the cartridge through its window onto the 68000's memory and writes one byte after another, and
          # the game goes on. A Genesis sounds one recording at a time.
          #
          # How the two talk. The 68000 can write into the Z80's memory only after asking for its bus, which
          # stops the Z80 for that moment. It leaves what to play in the mailbox at the top of that memory
          # (MAILBOX), and puts an entry in the queue beside it (QUEUE) saying so, which the Z80 looks at
          # between samples. The FM chip is the Z80's alone in a game that plays recordings: the 68000's
          # writes to it are entries in the same queue (Sound's rt_fm_write), and the Z80 makes one a
          # sample, between the DAC's writes. The console's own sound drivers do the same, so the 68000
          # never stops the Z80 for longer than it takes to write a few bytes into its memory.
          #
          # The count is the interpreter's. What the game can tell of a recording (the log saying it came
          # round again, the place coming free at its end) follows where it has got to, so the 68000 keeps
          # that as the interpreter's mixer does, in whole samples and 65536ths, moved on once a frame by
          # the samples a frame reads (Console::SampleClock.on_voices).
          #
          # A song's recorded part plays its notes in the same place, by the interpreter's rule
          # (Reference::Mixer#start_music_note): the part's own, while it still sounds a note; the place if it
          # is free; or the sound in it, if that ranks below the song. With neither, the note is not played. A
          # rest gives the part's place back, and so does the tune stopping.
          module Recordings
            # A play's row of "recording_plays", in bytes.
            START = 0 # Where the recording is in the cartridge, a long
            LENGTH = 4 # A long, as are the next two
            BACK = 8
            ADVANCE = 12 # Whole samples a frame
            ADVANCE_FRACTION = 16 # Its fraction, in 65536ths
            LOGGED = 18 # The number of its entry in the sound log
            NAME = 20
            STEP = 22 # Samples of the recording a sample of the Z80's, in 256ths
            ROW_BYTES = 24
            # ...and in a game with a recorded note off the middle (SIDES), the speakers it plays from, as the
            # FM chip's register $B6 of its second part keeps them for the sixth voice, which the DAC is.
            SIDE = 24
            # ...nought in a glide's row where the glide names no side and keeps the note's.
            SIDE_KEPT = 0
            ROW_BYTES_WITH_SIDE = 26

            # The place's state, in bytes.
            PLACE = "rt recordings place"
            HELD = 0 # Which recording, its number plus one, nought when the place is free
            POSITION = 2 # A long, and FRACTION its 65536ths
            FRACTION = 6
            PLACE_LENGTH = 8
            PLACE_BACK = 12
            PLACE_ADVANCE = 16
            PLACE_ADVANCE_FRACTION = 20
            PLACE_LOGGED = 22
            # ...and whose it is: nought for the game's own, a part's OWNER number for a song's (its place among
            # the song's recorded parts, one up), and for a sound effect's the same in the low byte under the
            # effect's number, one up (EFFECT_OWNER and over); and the rank it holds the place at, nought for
            # the game's own, which rank below every song.
            OWNER = 24
            RANK = 26
            PLACE_BYTES = 28
            EFFECT_OWNER = 0x100

            # A row's LOGGED for a note of a song: nothing is logged as it comes round again.
            NOT_LOGGED = 0xFFFF
            # Each of the last Frame::STEPS_KEPT passes' recording as its wait ended, a word each, by the
            # pass's number less its multiples of STEPS_KEPT.
            KEPT_BY_PASS = "rt recordings kept by pass"
            # What could not be played (Reference::Mixer#drops): how many plays and notes found the place
            # busy, and whether a song's held it at one of those moments.
            DROPS = "rt recordings drops"
            DROPS_MUSIC = "rt recordings drops music"
            OWNER_ASKING = "rt recordings owner asking"

            ALL = 0xFFFF

            # The Z80's side. Everything it reads is in its own memory, at QUEUE and MAILBOX on.
            MAILBOX = 0x1F00
            QUEUE_WRITTEN = 0 # How far the 68000 has written the queue, a byte that goes round
            PLAYS = 1 # Nought to go quiet
            AT = 2 # Where to start, in the window: two bytes, low first
            BANK = 4 # The window's place in the cartridge, two bytes
            END_AT = 6 # Where it ends, the same way
            END_BANK = 8
            LOOP_AT = 10 # Where it goes back to, the same way
            LOOP_BANK = 12
            Z80_STEP = 14 # 256ths, two bytes
            LOOPS = 16
            # The two flags that keep the Z80 off the cartridge while the 68000 reads the controllers
            # (#emit_z80_kept_off_for_pad): set by the 68000 while it reads, and set by the Z80 while it
            # may be reading the cartridge.
            BLOCK = 17
            UNSAFE = 18

            QUEUE_READ = 20 # How far the Z80 has read the queue, the same way

            # The Z80's own copy of what the play it is making reads, taken from the mailbox as the play
            # starts, so a mailbox the 68000 has filled for the next play changes nothing of this one; and
            # the bank the window shows.
            PLAYING = 0x1F20
            PLAYING_FIELDS = (END_AT..LOOPS) # Copied from the mailbox as they are
            PLAYING_END_AT = 0
            PLAYING_END_BANK = 2
            PLAYING_LOOP_AT = 4
            PLAYING_LOOP_BANK = 6
            PLAYING_LOOPS = 10
            PLAYING_BANK_NOW = 11
            PLAYING_OWED = 13 # Samples a stop covered, not yet passed over
            PLAYING_SILENCE_LEFT = 14 # Chunks of silence to copy before the reader is past the end
            PLAYING_MODE = 15 # MODE_COPIED, MODE_DIRECT or MODE_IDLE
            PLAYING_BACK = 16 # How far back the recording goes round, two bytes: END_AT less LOOP_AT
            # How the play under way is read: copied ahead into FIFO, read from the cartridge sample by
            # sample (a play of DIRECT_STEP whole samples a step or more), or none.
            MODE_COPIED = 0
            MODE_DIRECT = 1
            MODE_IDLE = 2
            # The step, in whole samples, from which a play is read straight from the cartridge. The Z80
            # copies a little over two bytes ahead in each sample's time (#driver), so a play stepping
            # further would run FIFO dry; read sample by sample, as the program did before it read ahead,
            # it plays at any step.
            DIRECT_STEP = 2
            # UNSAFE while a play is read straight from the cartridge: the Z80 reads it on every tick and
            # never looks at BLOCK, so the 68000 stops it for the controllers' read instead.
            UNSAFE_STOPPED = 0xFF
            # PLAYING_LOOPS once a recording played once has ended and silence is copied after it.
            LOOPS_SILENCE = 3

            # The recording read ahead (#driver): 256 bytes of the Z80's memory on a page of their own, so
            # one byte is where in them, and it goes round by itself. The Z80 copies more in from the
            # cartridge while it holds fewer than FIFO_FULL not yet sounded, FIFO_CHUNK at a time, and
            # FIFO_FIRST_CHUNKS of them before a play's first sample.
            FIFO = 0x1B00
            FIFO_FULL = 128
            FIFO_CHUNK = 8
            FIFO_FIRST_CHUNKS = 4
            # Chunks of silence copied after a recording played once before the Z80 goes quiet: by then
            # the reader is past the recording's end, since the copy is never more than FIFO_FULL and a
            # chunk ahead of it.
            SILENCE_CHUNKS = (FIFO_FULL / FIFO_CHUNK) + 2
            # Passing over the samples a stop covered stops while the reader is this near what has been
            # copied, so it never reads past it.
            FIFO_KEPT_BEHIND = 8
            # How long the 68000 waits before asking again when the Z80 was reading the cartridge as it
            # asked it to keep off, in turns of a one-instruction loop: longer than the Z80 takes over a
            # chunk.
            UNSAFE_WAIT = 64
            # The instruction the 68000 writes into the Z80's program when it has put an entry in the
            # queue (RST 8, a call to the Z80's address 8, which goes on to where the queue's entry is
            # taken), and the one the Z80 writes back once the queue is empty (NOP). The Z80 writes RST 16
            # into its own ticks the same way while it owes samples a stop covered.
            ENTRY_CALL = 0xCF
            ENTRY_CALL_AT = 8
            ENTRY_OWED = 0xD7
            ENTRY_OWED_AT = 16
            ENTRY_NONE = 0x00

            # The queue: what the Z80 is asked to do, in order, an entry at each of 256 places that go
            # round. An entry is three bytes, each on a page of its own so one count finds all three:
            # which of the FM chip's two parts it is for (its ports are two along for the second), the
            # register and the value; or PLAY_ENTRY in the first, for a new play in the mailbox.
            QUEUE = 0x1C00
            QUEUE_PLACES = 256
            REGISTER_PAGE = 0x100
            VALUE_PAGE = 0x200
            PLAY_ENTRY = 0x80
            # ...or GLIDE_ENTRY, in a game whose notes glide: the play goes on from where it is, at the
            # step in the mailbox (#emit_glide).
            GLIDE_ENTRY = 0x81
            # Kept in a game with a recorded note that glides, whose runtime then carries what moves one.
            GLIDES = "rt recordings glides"
            # ...and in a game with a recorded note off the middle of the speakers, whose rows name a side.
            SIDES = "rt recordings sides"
            SECOND_PART = 2
            # How long the 68000 lets the Z80 run when the queue is full, in turns of a two-instruction
            # loop: more than a sample's time, in which the Z80 takes an entry.
            QUEUE_FULL_WAIT = 64
            # Each FM register's last value, a word each by its number (the second part's from $100), and
            # NOT_KEPT for one never written (Sound#emit_fm_write_queued).
            FM_KEPT = "rt recordings fm kept"
            FM_REGISTERS = 0x200
            NOT_KEPT = 0xFFFF
            # The pitch registers, $A0 to $AF of either part: a register whose number, with these bits
            # kept, is PITCH_REGISTERS.
            PITCH_REGISTERS_MASK = 0xF0
            PITCH_REGISTERS = 0xA0

            Z80_MEMORY = 0xA00000
            WINDOW = 0x8000 # Where the window starts in the Z80's memory, and how much it shows

            # The Z80's clock for a sample is the FM chip's first timer (#driver). A timer of that chip
            # counts in ticks of 144 cycles of the chip's clock, which is the 68000's: an NTSC console's
            # crystal divided by seven. A PAL console's crystal is a little slower, so the same ticks
            # come a little further apart there, and a play's step is made that much longer (PAL_STEP_EXTRA).
            FM_CLOCK_HZ = 53_693_175 / 7r
            PAL_FM_CLOCK_HZ = 53_203_424 / 7r
            # What a step is made longer by on a PAL console, in 65536ths of itself.
            PAL_STEP_EXTRA = ((FM_CLOCK_HZ / PAL_FM_CLOCK_HZ - 1) * 65_536).round
            PAL_CONSOLE_BIT = 6 # Of the version register: set on a PAL console
            TIMER_TICK_CLOCKS = 144
            TICKS_A_SAMPLE = 4 # The first timer's length: a sample
            SAMPLES_A_SECOND = FM_CLOCK_HZ / (TIMER_TICK_CLOCKS * TICKS_A_SAMPLE)
            # The second timer's length in samples: one of its ticks is sixteen of the first's, so it
            # comes round with every 256th sample exactly, and a count of samples kept in a byte is
            # back at nought as it does.
            SAMPLES_A_CHECK = 256
            TIMER_A = 1024 - TICKS_A_SAMPLE # Ten bits, registers $24 (the top eight) and $25
            TIMER_B = 256 - (SAMPLES_A_CHECK * TICKS_A_SAMPLE / 16) # Register $26
            TIMERS = 0x27 # The register that starts the timers and clears their flags
            TIMERS_STOPPED = 0x30 # Neither counting, both flags cleared
            TIMERS_COUNTING = 0x0F # Both counting and raising their flags
            SAMPLE_TICK_SEEN = 0x1F # ...and the first timer's flag cleared
            BOTH_TICKS_SEEN = 0x3F # ...and both flags cleared
            # The same register holds the third FM voice's mode in its top two bits, so every write the
            # Z80 makes to it carries the mode the game last gave: the 68000 writes the mode into each
            # of the Z80's writes (TIMER_WRITES, the labels of their values in #driver) as it asks for it.
            MODE_BITS = 0xC0
            TIMER_WRITES = { stopped: TIMERS_STOPPED, counting: TIMERS_COUNTING, sample_tick_seen: SAMPLE_TICK_SEEN,
                             chunk_tick_seen: SAMPLE_TICK_SEEN, both_ticks_seen: BOTH_TICKS_SEEN,
                             direct_counting: TIMERS_COUNTING, direct_tick_seen: SAMPLE_TICK_SEEN,
                             direct_both_ticks_seen: BOTH_TICKS_SEEN }.freeze

            module_function

            # A play's step for the Z80, in 256ths of a sample of the recording: +step+ is the
            # interpreter's, in 65536ths for each of the +voice_hz+ samples a second it mixes, and the
            # Z80 sounds SAMPLES_A_SECOND on an NTSC console.
            def z80_step(step, voice_hz) = [(step * voice_hz / SAMPLES_A_SECOND / 256).round, 0xFFFF].min

            # +glides+ for a game with a recorded note that glides (`glides: true`), whose runtime then
            # carries what bends one (#emit_glide) and its sound processor takes a new step mid-play.
            # +sides+ for a game with a recorded note off the middle of the speakers, whose rows then name
            # the speakers each play is heard from (SIDE), and whose places set them.
            def reserve(memory, glides: false, sides: false)
              memory.reserve(GLIDES, 2) if glides
              memory.reserve(SIDES, 2) if sides
              memory.reserve(PLACE, PLACE_BYTES)
              memory.reserve(KEPT_BY_PASS, Frame::STEPS_KEPT * 2)
              [DROPS, DROPS_MUSIC, OWNER_ASKING].each { |name| memory.reserve(name, 2) }
              memory.reserve(FM_KEPT, FM_REGISTERS * 2)
            end

            # A play's row, for "recording_plays": +start+ a label. +side+, in a game with SIDES, is the
            # speakers' bits it plays from (ChipWrites::BOTH_SPEAKERS and its two), and nil in any other.
            def emit_row(asm, start:, length:, back:, advance:, logged:, name:, step:, side: nil)
              asm.data_longs(start)
              asm.data_longs(length, back, advance >> 16)
              asm.data_words(advance & 0xFFFF, logged, name, step)
              asm.data_words(side) if side
            end

            # How long a row is in a game with or without SIDES.
            def row_bytes(memory) = memory.reserved?(SIDES) ? ROW_BYTES_WITH_SIDE : ROW_BYTES

            def emit(asm, memory)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              glides = memory.reserved?(GLIDES)
              emit_start(asm, at, glides: glides)
              rows = row_bytes(memory)
              sides = memory.reserved?(SIDES)
              emit_play(asm, at, rows, sides: sides)
              emit_note(asm, at, rows)
              emit_glide(asm, at, rows, sides: sides) if glides
              emit_stop(asm, at)
              emit_frame(asm, at)
              emit_mail(asm, at)
              emit_kept_for_pass(asm, memory, at)
              emit_z80_kept_off_for_pad(asm)
            end

            # Stopping the Z80. The 68000 stops it for two things: a copy by the video chip, and a write into
            # the Z80's memory. A read of the controllers' ports, which the console's maker says must not
            # come just before a Z80 read of the cartridge (S3 in docs/genesis/dma-and-the-sound-processor.md),
            # does not stop it: the Z80 is asked to keep off the cartridge for the read, and plays on from
            # what it has read ahead (rt_z80_kept_off_for_pad). The controllers are read in the blank's
            # interrupt, which asks for the bus to ask that, and the same bulletins say a request made in
            # an interrupt breaks one the main program has made (S4). So the main program holds
            # interrupts off from asking for the bus until it lets go: the interrupt never comes inside one
            # of its stops, and a stop of the interrupt's own is over before the main program runs again.
            #
            # A stop for each, not one for the whole blank. Sonic 3 & Knuckles stops its Z80 once in the
            # blank and makes every copy and the controller's read inside that one stop. That was tried
            # here and measured: the blank's work here is mostly the 68000 writing the picture's maps and
            # tiles itself and playing the music, not copies, so one stop for all of it held the DAC still
            # for some sixty samples a frame and lost waves of a recording playing alone. Each copy and
            # each write into the Z80's memory is a stop of its own, a few instructions long.

            # The Z80's bus asked for and waited for, with interrupts held off, the status register kept on
            # the stack for #emit_bus_given_back. Every register is left alone.
            def emit_bus_taken(asm)
              asm.move_from_sr(asm.pre(M68000::SP))
              asm.ori_to_sr(Frame::INTERRUPTS_OFF_BITS)
              emit_bus_requested(asm)
            end

            # The Z80 let go, and interrupts let in again as they were.
            def emit_bus_given_back(asm)
              emit_bus_released(asm)
              asm.move_to_sr(asm.post(M68000::SP))
            end

            # The Z80's bus asked for and waited for, there and then.
            def emit_bus_requested(asm)
              h = Console::GenesisHardware
              asm.move(:w, asm.imm(h::Z80_REQUEST), asm.abs_l(h::Z80_BUS_REQUEST))
              label = "rt_bus_wait_#{asm.here}"
              asm.label(label)
              asm.btst(0, asm.abs_l(h::Z80_BUS_REQUEST))
              asm.branch(:ne, label)
            end

            # The Z80 let go, there and then.
            def emit_bus_released(asm) = asm.clr(:w, asm.abs_l(Console::GenesisHardware::Z80_BUS_REQUEST))

            # rt_z80_kept_off_for_pad: in the blank's interrupt, the controllers read (Frame's rt_pad_read)
            # with the Z80 kept off the cartridge but still playing. D0 is used.
            #
            # A read of the Team Player takes several lines of the screen. Stopping the Z80 for all of it,
            # as for the one pad, held the DAC still and then passed over what the stop covered, which was
            # heard as a wobble in a recording. So the Z80 is not stopped. It keeps a few hundred samples
            # of the recording in its own memory (#driver), and the 68000 asks it to read no more from the
            # cartridge while the ports are read. That is how Sega's GEMS sound driver kept its samples
            # playing (GEMS.A, _gemsdmastart and _gemsdmaend; its Z80 side is XFER68K), and how the X-Band
            # modem's GameLib reads a Team Player (controls.c, _ControllerVBL).
            #
            # The handshake, in GEMS's order. With the bus held for a moment, the 68000 sets BLOCK and reads
            # UNSAFE, which the Z80 sets before it looks at BLOCK and copies a chunk, and clears after. If
            # UNSAFE was set, the Z80 may be in the middle of a chunk, so the 68000 lets go, waits a little
            # longer than a chunk takes, and asks again. Once it reads UNSAFE clear, the Z80 will see BLOCK
            # before it reads the cartridge again, so the ports are read. Then BLOCK is cleared.
            #
            # A play stepping DIRECT_STEP samples or more is read from the cartridge on every tick and not
            # copied ahead (#driver), and its UNSAFE is UNSAFE_STOPPED: the Z80 is kept stopped through the
            # read instead, as before it read ahead.
            def emit_z80_kept_off_for_pad(asm)
              block = asm.abs_l(Z80_MEMORY + MAILBOX + BLOCK)
              asm.label("rt_z80_kept_off_for_pad")
              emit_bus_requested(asm)
              asm.move(:b, asm.imm(1), block)
              asm.move(:b, asm.abs_l(Z80_MEMORY + MAILBOX + UNSAFE), asm.d(0))
              asm.cmp(:b, asm.imm(UNSAFE_STOPPED), asm.d(0))
              asm.branch(:eq, "rt_z80_kept_off_for_pad_stopped")
              emit_bus_released(asm)
              asm.tst(:b, asm.d(0))
              asm.branch(:eq, "rt_z80_kept_off_for_pad_read")
              asm.move(:w, asm.imm(UNSAFE_WAIT), asm.d(0))
              asm.label("rt_z80_kept_off_for_pad_wait")
              asm.dbra(asm.d(0), "rt_z80_kept_off_for_pad_wait")
              asm.bra("rt_z80_kept_off_for_pad")
              asm.label("rt_z80_kept_off_for_pad_read")
              asm.jsr(asm.abs_l("rt_pad_read"))
              emit_bus_requested(asm)
              asm.label("rt_z80_kept_off_for_pad_let_back")
              asm.clr(:b, block)
              emit_bus_released(asm)
              asm.rts
              asm.label("rt_z80_kept_off_for_pad_stopped")
              asm.jsr(asm.abs_l("rt_pad_read"))
              asm.bra("rt_z80_kept_off_for_pad_let_back")
            end

            # rt_z80_queued(register, value, part in D3): an entry put in the Z80's queue, the bus held.
            # D2 and A1 are used. A full queue is let go of for a little while, the Z80 taking entries
            # meanwhile, until there is a place. The Z80's program is then told there is an entry: the
            # instruction at each of +entry_ats+ in it, where its sample loops look, is made a call to where
            # an entry is taken (ENTRY_CALL).
            def emit_queued(asm, entry_ats)
              mail = ->(field) { asm.abs_l(Z80_MEMORY + MAILBOX + field) }
              asm.label("rt_z80_queued")
              asm.move(:b, mail.call(QUEUE_READ), asm.d(2))
              asm.sub(:b, mail.call(QUEUE_WRITTEN), asm.d(2))
              asm.subq(:b, 1, asm.d(2))
              asm.branch(:ne, "rt_z80_queued_room") # the places free, less the one kept empty
              emit_bus_released(asm)
              asm.move(:w, asm.imm(QUEUE_FULL_WAIT), asm.d(2))
              asm.label("rt_z80_queued_full")
              asm.dbra(asm.d(2), "rt_z80_queued_full")
              emit_bus_requested(asm)
              asm.bra("rt_z80_queued")
              asm.label("rt_z80_queued_room")
              asm.moveq(0, asm.d(2))
              asm.move(:b, mail.call(QUEUE_WRITTEN), asm.d(2))
              asm.lea(asm.abs_l(Z80_MEMORY + QUEUE), asm.a(1))
              asm.lea(asm.idx(1, 0, 2, :w), asm.a(1))
              asm.move(:b, asm.d(3), asm.ind(1))
              asm.move(:b, asm.d(0), asm.disp(1, REGISTER_PAGE))
              asm.move(:b, asm.d(1), asm.disp(1, VALUE_PAGE))
              asm.addq(:b, 1, asm.d(2))
              asm.move(:b, asm.d(2), mail.call(QUEUE_WRITTEN))
              entry_ats.each { |entry_at| asm.move(:b, asm.imm(ENTRY_CALL), asm.abs_l(Z80_MEMORY + entry_at)) }
              asm.rts
            end

            # rt_recordings_start, as the game starts: the Z80's program copied into its memory and started,
            # its queue empty, the bus held all the while (Runtime::Boot has held it since power-on); and no
            # FM register's value kept yet.
            def emit_start(asm, at, glides: false)
              h = Console::GenesisHardware
              program = driver(glides: glides)
              asm.label("rt_recordings_start")
              asm.lea(at.call(FM_KEPT), asm.a(0))
              asm.move(:w, asm.imm(FM_REGISTERS - 1), asm.d(0))
              asm.label("rt_recordings_start_unkept")
              asm.move(:w, asm.imm(NOT_KEPT), asm.post(0))
              asm.dbra(asm.d(0), "rt_recordings_start_unkept")
              asm.lea(asm.abs_l("rt_z80_program"), asm.a(0))
              asm.lea(asm.abs_l(Z80_MEMORY), asm.a(1))
              asm.move(:w, asm.imm(program.length - 1), asm.d(0))
              asm.label("rt_recordings_start_next")
              asm.move(:b, asm.post(0), asm.post(1))
              asm.dbra(asm.d(0), "rt_recordings_start_next")
              [QUEUE_WRITTEN, QUEUE_READ, PLAYS, BLOCK, UNSAFE].each { |field| asm.clr(:b, asm.abs_l(Z80_MEMORY + MAILBOX + field)) }
              asm.clr(:w, asm.abs_l(h::Z80_RESET))
              8.times { asm.nop }
              asm.move(:w, asm.imm(h::Z80_REQUEST), asm.abs_l(h::Z80_RESET))
              asm.clr(:w, asm.abs_l(h::Z80_BUS_REQUEST))
              asm.rts

              # The DAC on, which takes the sixth FM voice from the game for good, and heard on both speakers.
              asm.label("rt_recordings_on")
              asm.move(:w, asm.imm(ChipWrites::DAC_ON), asm.d(0))
              asm.move(:w, asm.imm(0x80), asm.d(1))
              asm.jsr(asm.abs_l("rt_fm_write"))
              asm.move(:w, asm.imm(0x100 | (ChipWrites::SPEAKERS + 2)), asm.d(0))
              asm.move(:w, asm.imm(ChipWrites::BOTH_SPEAKERS), asm.d(1))
              asm.jmp(asm.abs_l("rt_fm_write"))

              asm.label("rt_z80_program")
              asm.data_bytes(program.code)
              asm.data_bytes(0) if program.length.odd?
              emit_queued(asm, %i[entry_looked_for direct_entry_looked_for].map { |label| program.address_of(label) })
            end

            # rt_recordings_play(row): the play's entry logged, and the recording in the place from its start
            # (Reference::Mixer#start) if it is free. With it busy, the play is dropped, as the mixer drops it.
            def emit_play(asm, at, rows, sides: false)
              asm.label("rt_recordings_play")
              asm.mulu(asm.imm(rows), asm.d(0))
              asm.lea(asm.abs_l("recording_plays"), asm.a(0))
              asm.lea(asm.idx(0, 0, 0), asm.a(4))
              asm.move(:w, asm.disp(4, LOGGED), asm.d(0))
              asm.jsr(asm.abs_l("rt_sound_log"))
              asm.tst(:w, at.call(PLACE, HELD))
              asm.branch(:ne, "rt_recordings_drop")
              asm.clr(:w, at.call(PLACE, OWNER))
              asm.clr(:w, at.call(PLACE, RANK))

              # rt_recordings_take: the row A4 points at into the place, from the recording's start, sent to the
              # Z80. D0 = 1 after.
              asm.label("rt_recordings_take")
              asm.move(:w, asm.disp(4, NAME), asm.d(0))
              asm.addq(:w, 1, asm.d(0))
              asm.move(:w, asm.d(0), at.call(PLACE, HELD))
              asm.clr(:l, at.call(PLACE, POSITION))
              asm.clr(:w, at.call(PLACE, FRACTION))
              asm.move(:l, asm.disp(4, LENGTH), at.call(PLACE, PLACE_LENGTH))
              asm.move(:l, asm.disp(4, BACK), at.call(PLACE, PLACE_BACK))
              asm.move(:l, asm.disp(4, ADVANCE), at.call(PLACE, PLACE_ADVANCE))
              asm.move(:w, asm.disp(4, ADVANCE_FRACTION), at.call(PLACE, PLACE_ADVANCE_FRACTION))
              asm.move(:w, asm.disp(4, LOGGED), at.call(PLACE, PLACE_LOGGED))
              emit_side_queued(asm) if sides
              asm.jsr(asm.abs_l("rt_recordings_send"))
              asm.moveq(1, asm.d(0))
              asm.rts

              # rt_recordings_drop: a play or a note found no place (Reference::Mixer#record_drop): counted,
              # with whether a song held the place. D0 = nought.
              asm.label("rt_recordings_drop")
              asm.addq(:w, 1, at.call(DROPS))
              asm.tst(:w, at.call(PLACE, OWNER))
              asm.branch(:eq, "rt_recordings_drop_done")
              asm.move(:w, asm.imm(1), at.call(DROPS_MUSIC))
              asm.label("rt_recordings_drop_done")
              asm.moveq(0, asm.d(0))
              asm.rts
            end

            # rt_recordings_note(row, owner, rank): a note of a song's or effect's recorded part played in the
            # place by the interpreter's rule (the note above). D0 = 1 when it found it, nought when not.
            # rt_recordings_note_release(owner): the place +owner+'s part sounds a note in, if it does, freed;
            # D0 = 1 when it had it. rt_recordings_sounding_for(owner): D0 = 1 when +owner+'s part sounds a
            # note now, which a new music volume reaches (a Genesis plays a recording at one loudness, so
            # only the log hears it). rt_recordings_release_music: a song's note freed; a sound effect's is
            # the effect's.
            def emit_note(asm, at, rows)
              asm.label("rt_recordings_note")
              asm.mulu(asm.imm(rows), asm.d(0))
              asm.lea(asm.abs_l("recording_plays"), asm.a(0))
              asm.lea(asm.idx(0, 0, 0), asm.a(4))
              asm.tst(:w, at.call(PLACE, HELD))
              asm.branch(:eq, "rt_recordings_note_found") # free
              asm.cmp(:w, at.call(PLACE, OWNER), asm.d(1))
              asm.branch(:eq, "rt_recordings_note_found") # the part's own note, taken over
              asm.cmp(:w, at.call(PLACE, RANK), asm.d(2))
              asm.branch(:ls, "rt_recordings_drop") # not below the note
              asm.label("rt_recordings_note_found")
              asm.move(:w, asm.d(1), at.call(PLACE, OWNER))
              asm.move(:w, asm.d(2), at.call(PLACE, RANK))
              asm.jmp(asm.abs_l("rt_recordings_take"))

              asm.label("rt_recordings_sounding_for")
              asm.tst(:w, at.call(PLACE, HELD))
              asm.branch(:eq, "rt_recordings_none")
              asm.cmp(:w, at.call(PLACE, OWNER), asm.d(0))
              asm.branch(:ne, "rt_recordings_none")
              asm.moveq(1, asm.d(0))
              asm.rts

              asm.label("rt_recordings_note_release")
              asm.tst(:w, at.call(PLACE, HELD))
              asm.branch(:eq, "rt_recordings_none")
              asm.cmp(:w, at.call(PLACE, OWNER), asm.d(0))
              asm.branch(:ne, "rt_recordings_none")
              asm.jsr(asm.abs_l("rt_recordings_free"))
              asm.moveq(1, asm.d(0))
              asm.rts
              asm.label("rt_recordings_none")
              asm.moveq(0, asm.d(0))
              asm.rts

              asm.label("rt_recordings_release_music")
              asm.tst(:w, at.call(PLACE, HELD))
              asm.branch(:eq, "rt_recordings_release_music_done")
              asm.move(:w, at.call(PLACE, OWNER), asm.d(0))
              asm.branch(:eq, "rt_recordings_release_music_done") # the game's own
              asm.cmp(:w, asm.imm(EFFECT_OWNER), asm.d(0))
              asm.branch(:cc, "rt_recordings_release_music_done") # a sound effect's
              asm.jmp(asm.abs_l("rt_recordings_free"))
              asm.label("rt_recordings_release_music_done")
              asm.rts
            end

            # rt_recordings_stop(name, logged): the place freed if it plays recording +name+ (or anything, for
            # ALL) and it is the game's own, and [:stop_sample] logged (Reference::Mixer#stop).
            # rt_recordings_free: the place freed, and the Z80 told to go quiet.
            def emit_stop(asm, at)
              asm.label("rt_recordings_stop")
              asm.move(:w, asm.d(1), asm.pre(M68000::SP))
              asm.tst(:w, at.call(PLACE, OWNER))
              asm.branch(:ne, "rt_recordings_stop_log") # a song's note is the music's to stop
              asm.move(:w, at.call(PLACE, HELD), asm.d(1))
              asm.branch(:eq, "rt_recordings_stop_log")
              asm.subq(:w, 1, asm.d(1))
              asm.cmp(:w, asm.imm(ALL), asm.d(0))
              asm.branch(:eq, "rt_recordings_stop_it")
              asm.cmp(:w, asm.d(1), asm.d(0))
              asm.branch(:ne, "rt_recordings_stop_log")
              asm.label("rt_recordings_stop_it")
              asm.jsr(asm.abs_l("rt_recordings_free"))
              asm.label("rt_recordings_stop_log")
              asm.moveq(0, asm.d(0))
              asm.move(:w, asm.post(M68000::SP), asm.d(0))
              asm.jmp(asm.abs_l("rt_sound_log"))

              asm.label("rt_recordings_free")
              asm.clr(:w, at.call(PLACE, HELD))
              asm.movem_push(:l, :d0, :d1, :d2, :d3)
              emit_bus_taken(asm)
              asm.clr(:b, asm.abs_l(Z80_MEMORY + MAILBOX + PLAYS))
              asm.move(:w, asm.imm(PLAY_ENTRY), asm.d(3))
              asm.jsr(asm.abs_l("rt_z80_queued"))
              emit_bus_given_back(asm)
              asm.movem_pop(:l, :d0, :d1, :d2, :d3)
              asm.rts
            end

            # rt_recordings_frame: the place moved on by a frame (Reference::Mixer#mix_voice): the fraction, then
            # the whole samples and what the fraction carried; past the recording's end, back by its read-back
            # as many times as it takes, logging each time round; or, for one played once, the place freed.
            def emit_frame(asm, at)
              asm.label("rt_recordings_frame")
              asm.tst(:w, at.call(PLACE, HELD))
              asm.branch(:eq, "rt_recordings_frame_done")
              asm.move(:w, at.call(PLACE, PLACE_ADVANCE_FRACTION), asm.d(0))
              asm.add(:w, asm.d(0), at.call(PLACE, FRACTION))
              asm.move(:l, at.call(PLACE, POSITION), asm.d(0))
              asm.add(:l, at.call(PLACE, PLACE_ADVANCE), asm.d(0))
              asm.move(:w, at.call(PLACE, FRACTION), asm.d(1))
              asm.cmp(:w, at.call(PLACE, PLACE_ADVANCE_FRACTION), asm.d(1))
              asm.branch(:cc, "rt_recordings_frame_end") # the sum is below what was added: it carried
              asm.addq(:l, 1, asm.d(0))
              asm.label("rt_recordings_frame_end")
              asm.cmp(:l, at.call(PLACE, PLACE_LENGTH), asm.d(0))
              asm.branch(:cs, "rt_recordings_frame_keep")
              asm.tst(:l, at.call(PLACE, PLACE_BACK))
              asm.branch(:ne, "rt_recordings_frame_back")
              asm.clr(:w, at.call(PLACE, HELD)) # played once, and over
              asm.rts
              asm.label("rt_recordings_frame_back")
              asm.sub(:l, at.call(PLACE, PLACE_BACK), asm.d(0))
              asm.move(:w, at.call(PLACE, PLACE_LOGGED), asm.d(1))
              asm.cmp(:w, asm.imm(NOT_LOGGED), asm.d(1))
              asm.branch(:eq, "rt_recordings_frame_end") # a song's note: nothing logged as it comes round
              asm.move(:l, asm.d(0), asm.pre(M68000::SP))
              asm.move(:w, asm.d(1), asm.d(0))
              asm.jsr(asm.abs_l("rt_sound_log"))
              asm.move(:l, asm.post(M68000::SP), asm.d(0))
              asm.bra("rt_recordings_frame_end")
              asm.label("rt_recordings_frame_keep")
              asm.move(:l, asm.d(0), at.call(PLACE, POSITION))
              asm.label("rt_recordings_frame_done")
              asm.rts
            end

            # rt_recordings_send: what the row A4 points at plays, left in the Z80's mailbox, and a
            # PLAY_ENTRY queued. The window shows 32K of the cartridge, so a place in the cartridge is a
            # bank and where in the window: the bank is what is above the low 15 bits, and the window
            # starts at $8000. The version register is read with the Z80 stopped, which is how the
            # console's maker says a port at $A100xx must be read in a game whose Z80 reads the cartridge.
            def emit_mail(asm, _at)
              asm.label("rt_recordings_send")
              emit_bus_taken(asm)
              asm.lea(asm.abs_l(Z80_MEMORY + MAILBOX), asm.a(1))
              asm.move(:l, asm.disp(4, START), asm.d(0))
              asm.lea(asm.disp(1, AT), asm.a(2))
              asm.jsr(asm.abs_l("rt_recordings_place")) # AT, BANK
              asm.add(:l, asm.disp(4, LENGTH), asm.d(0))
              asm.jsr(asm.abs_l("rt_recordings_place")) # END_AT, END_BANK
              asm.sub(:l, asm.disp(4, BACK), asm.d(0))
              asm.jsr(asm.abs_l("rt_recordings_place")) # LOOP_AT, LOOP_BANK
              emit_step_mailed(asm, "rt_recordings_send_step")
              asm.tst(:l, asm.disp(4, BACK))
              asm.scc(:ne, asm.ind(2)) # LOOPS
              asm.move(:b, asm.imm(1), asm.disp(1, PLAYS))
              asm.move(:w, asm.imm(PLAY_ENTRY), asm.d(3))
              asm.jsr(asm.abs_l("rt_z80_queued"))
              emit_bus_given_back(asm)
              asm.rts

              # rt_recordings_place: the place in the cartridge D0 gives written at A2 on, kept in D0, as the
              # window's place and the bank, low bytes first.
              asm.label("rt_recordings_place")
              asm.move(:l, asm.d(0), asm.d(1))
              asm.and(:w, asm.imm(WINDOW - 1), asm.d(1))
              asm.or(:w, asm.imm(WINDOW), asm.d(1))
              asm.move(:b, asm.d(1), asm.post(2))
              asm.lsr(:w, 8, asm.d(1))
              asm.move(:b, asm.d(1), asm.post(2))
              asm.move(:l, asm.d(0), asm.d(1))
              asm.moveq(15, asm.d(2))
              asm.lsr(:l, asm.d(2), asm.d(1))
              asm.move(:b, asm.d(1), asm.post(2))
              asm.lsr(:w, 8, asm.d(1))
              asm.move(:b, asm.d(1), asm.post(2))
              asm.rts
            end

            # The row A4 points at's STEP into the mailbox's Z80_STEP, A2 pointing at it, low byte first and A2
            # moved past it: on a PAL console made PAL_STEP_EXTRA longer, and no more than $FFFF. +done+ names
            # the label it reaches once the step is known. Uses D1 and D2.
            def emit_step_mailed(asm, done)
              asm.move(:w, asm.disp(4, STEP), asm.d(1))
              asm.btst(PAL_CONSOLE_BIT, asm.abs_l(Console::GenesisHardware::VERSION_REGISTER))
              asm.branch(:eq, done)
              asm.move(:w, asm.d(1), asm.d(2))
              asm.mulu(asm.imm(PAL_STEP_EXTRA), asm.d(2))
              asm.add(:l, asm.imm(0x8000), asm.d(2))
              asm.swap(asm.d(2))
              asm.add(:w, asm.d(2), asm.d(1))
              asm.branch(:cc, done)
              asm.move(:w, asm.imm(0xFFFF), asm.d(1))
              asm.label(done)
              asm.move(:b, asm.d(1), asm.post(2))
              asm.lsr(:w, 8, asm.d(1))
              asm.move(:b, asm.d(1), asm.post(2))
            end

            # The speakers the row A4 points at plays from (SIDE) told to the FM chip's register $B6 of its second
            # part, the sixth voice's, which the DAC plays through: queued for the Z80 as any FM write is, and
            # dropped when it is what the register holds already (Sound#emit_fm_write_queued). Uses D0 to D3 and A1.
            # With +unless_kept+, a label, a SIDE of SIDE_KEPT writes nothing.
            def emit_side_queued(asm, unless_kept: nil)
              asm.move(:w, asm.imm(0x100 | (ChipWrites::SPEAKERS + 2)), asm.d(0))
              asm.move(:w, asm.disp(4, SIDE), asm.d(1))
              asm.branch(:eq, unless_kept) if unless_kept # SIDE_KEPT is nought
              asm.jsr(asm.abs_l("rt_fm_write"))
              asm.label(unless_kept) if unless_kept
            end

            # rt_recordings_glide(row, owner): the note +owner+'s part sounds, if it has the place, reads on at
            # the row's pitch (Reference::Mixer#glide_music_note): how far a frame takes it, and the Z80 told
            # its new step (GLIDE_ENTRY), which it takes from where it has got to, so nothing starts again; and
            # in a game with SIDES, the speakers the row names. A Genesis plays a recording at the one loudness,
            # so the glide's loudness reaches only the log, as the music volume's does. D0 = 1 when the part had
            # a note, nought when not.
            def emit_glide(asm, at, rows, sides: false)
              asm.label("rt_recordings_glide")
              asm.mulu(asm.imm(rows), asm.d(0))
              asm.lea(asm.abs_l("recording_plays"), asm.a(0))
              asm.lea(asm.idx(0, 0, 0), asm.a(4))
              asm.tst(:w, at.call(PLACE, HELD))
              asm.branch(:eq, "rt_recordings_none")
              asm.cmp(:w, at.call(PLACE, OWNER), asm.d(1))
              asm.branch(:ne, "rt_recordings_none")
              asm.move(:l, asm.disp(4, ADVANCE), at.call(PLACE, PLACE_ADVANCE))
              asm.move(:w, asm.disp(4, ADVANCE_FRACTION), at.call(PLACE, PLACE_ADVANCE_FRACTION))
              emit_side_queued(asm, unless_kept: "rt_recordings_glide_side_kept") if sides
              emit_bus_taken(asm)
              asm.lea(asm.abs_l(Z80_MEMORY + MAILBOX + Z80_STEP), asm.a(2))
              emit_step_mailed(asm, "rt_recordings_glide_step")
              asm.move(:w, asm.imm(GLIDE_ENTRY), asm.d(3))
              asm.jsr(asm.abs_l("rt_z80_queued"))
              emit_bus_given_back(asm)
              asm.moveq(1, asm.d(0))
              asm.rts
            end

            # rt_recordings_kept_for_pass: which recording the place holds copied into KEPT_BY_PASS for the
            # pass whose wait is ending, for a reader of the run to hold to the interpreter's mix at that
            # pass's frame boundary (Sound's rt_sound_frame).
            def emit_kept_for_pass(asm, memory, at)
              asm.label("rt_recordings_kept_for_pass")
              asm.move(:l, at.call(Frame::PASSES), asm.d(0))
              asm.and(:w, asm.imm(Frame::STEPS_KEPT - 1), asm.d(0))
              asm.add(:w, asm.d(0), asm.d(0))
              asm.lea(asm.abs_l(memory[KEPT_BY_PASS]), asm.a(0))
              asm.move(:w, at.call(PLACE, HELD), asm.idx(0, 0, 0, :w))
              asm.rts
            end

            # The Z80's program, assembled, the mailbox and the chips by the numbers above.
            #
            # ### A sample on each tick of a timer
            #
            # A sample sounds on a tick of the FM chip's first timer, not after a counted wait. The Z80 is
            # stopped many times a frame: for every block the video chip copies (Picture#emit_dma_started),
            # and for each write into its queue. A program that counts its own cycles from one sample to
            # the next loses the length of every stop, so the recording plays flat for as long as the
            # stops go on. The timer is in the FM chip and counts whether the Z80 runs or not.
            #
            # The samples a stop covered are passed over, not sounded late. The timer's flag says a tick
            # came, not how many. The second timer is set to come round with every 256th tick of the
            # first. The program counts the samples it sounds in a byte, and when the second timer's flag
            # shows, what the byte is short of 256 is the number of ticks a stop covered: the reader is
            # moved on by that many samples with nothing written to the DAC, which holds its last sample
            # meanwhile. A stop longer than the second timer's round loses a whole round.
            #
            # ### The recording read ahead
            #
            # The Z80 does not read each sample from the cartridge as it sounds it. It copies the recording
            # as it is into 256 bytes of its own memory (FIFO), a chunk of FIFO_CHUNK bytes at a time, while
            # it waits for the next tick; and a sample is read from there. This is how Sega's GEMS driver
            # plays a sample (its Z80.ASM: FILLDACFIFO keeps a FIFO of 256 bytes in two halves, XFER68K
            # copies into it in short bursts, and DACME sends the next byte on each tick of timer A). Its
            # use is that the Z80 can be asked to keep off the cartridge for a while and still play: the
            # 68000 does that while it reads the controllers (#emit_z80_kept_off_for_pad), which on a Team
            # Player takes several lines of the screen.
            #
            # Before each chunk the Z80 sets UNSAFE, then looks at BLOCK. If BLOCK is set, it clears UNSAFE
            # and copies nothing until BLOCK is clear again, sounding samples from FIFO meanwhile. Setting
            # UNSAFE before looking leaves no moment where the 68000 could set BLOCK and find UNSAFE clear
            # while a chunk is under way. UNSAFE is cleared after each chunk.
            #
            # The reader steps through FIFO by the play's step, a whole part and a fraction in 256ths, so a
            # recording plays at any pitch from the one copy. A copy that runs past the end of the window
            # onto the cartridge, or past the end of the recording, is taken back to that end, and the next
            # chunk starts in the next bank, or where the recording goes round to. A recording played once
            # is followed by silence: the copying goes on from FIFO_CHUNK bytes at the middle of the DAC's
            # range, which go round on themselves, until the next play.
            #
            # ### The FM chip is the Z80's
            #
            # The 68000's writes to the FM chip are entries of the queue, and the Z80 writes one between
            # two samples, after the tick's flag is cleared. The sample loop does not look at the queue on
            # each tick. There is a NOP where it would (:entry_looked_for), and the 68000 writes a call over
            # it as it puts an entry in the queue (ENTRY_CALL, the one-byte call to address 8, which is where
            # an entry is taken). The call puts the NOP back once the queue is empty, and leaves itself in
            # while another entry waits. A sample that writes an entry takes longer than a tick, and the
            # tick it runs over is one the second timer finds missing.
            #
            # ### Registers
            #
            # The first set: DE the FM chip's first port ($4000; $4001 for a value, by making E one), H the
            # page FIFO is on and L the next sample's place in it, C how far past that the reader is in
            # 256ths of a sample, and B the samples sounded since the second timer last came round. The step
            # is written into the two instructions that add it (:step_fraction, :step_whole). The second
            # set: HL where the next chunk is copied from, DE where in FIFO it goes, and BC the copy's count.
            #
            # ### What a sample costs the Z80
            #
            # A tick is four of the timer's, 576 cycles of the FM chip's clock: 269 of the Z80's. Counted by
            # hand from the instructions' cycles, a tick with FIFO full is seen in 21 cycles, and its flag
            # cleared, its sample sounded, the reader moved and how full FIFO is looked at in 171 more.
            # A chunk of FIFO_CHUNK bytes is 334 cycles, three looks for the tick among them, and 47 more
            # between two chunks; Genesis Plus GX adds three cycles to each read of the cartridge. So the
            # Z80 copies in a little over two bytes a sample when FIFO is low, so a play of DIRECT_STEP whole
            # samples a step or more is not copied: it is read straight from the cartridge, a sample a tick,
            # as the program did before it read ahead (#emit_direct_play). A tick that comes
            # while a chunk is copied is seen at the next look and sounds that much late, but not so late
            # that the next tick is lost.
            def driver(glides: false)
              Z80Program.new.tap do |z|
                z.bytes(0xF3) # DI
                z.bytes(0x31, 0xF0, 0x1F) # LD SP,$1FF0
                z.jump(0xC3, :init) # JP
                # The two one-byte calls' addresses, 8 and 16 (ENTRY_CALL and ENTRY_OWED).
                [[ENTRY_CALL_AT, :entry], [ENTRY_OWED_AT, :owed]].each do |at, target|
                  z.bytes(*Array.new(at - z.length, 0x00))
                  z.jump(0xC3, target) # JP
                end
                emit_entry_taken(z, glides: glides)
                emit_driver_idle(z)
                emit_new_play(z)
                emit_fifo_filled(z)
                emit_sample_sounded(z)
                emit_missed_passed_over(z)
                emit_fm_set(z)
                emit_bank_shown(z)
                emit_copy_past_end(z)
                emit_direct_play(z)
                emit_glide_entry(z) if glides
              end.assembled
            end

            # The labels of the mailbox's fields and the Z80's copy of them, in its memory.
            def mailbox_at(field) = MAILBOX + field
            def playing_at(field) = PLAYING + field

            # The queue's entry at L taken: QUEUE_READ moved past it for the 68000, and the call left in
            # the sample loop when another waits. +name+ names its one label.
            def emit_queue_moved_on(z, name)
              z.bytes(0x2C, 0x7D) # INC L ; LD A,L
              z.word(0x32, mailbox_at(QUEUE_READ)) # LD (queue read),A
              z.word(0x3A, mailbox_at(QUEUE_WRITTEN)) # LD A,(queue written)
              z.bytes(0xBD) # CP L
              z.jump(0xCA, name) # JP Z
              z.bytes(0x3E, ENTRY_CALL) # LD A,the call
              z.jump(0x32, :entry_looked_for) # LD (the sample loop's look),A
              z.jump(0x32, :direct_entry_looked_for) # LD (the direct loop's look),A
              z.label(name)
            end

            # :entry, which ENTRY_CALL calls: the queue's next entry, if there is one, made. An FM write is
            # written once the chip has taken the last value written to it, and the DAC's register named
            # again; a new play starts it, afresh. Every register is kept, and the flags. DE must be the
            # chip's first port.
            def emit_entry_taken(z, glides:)
              z.label(:entry)
              z.bytes(0xF5, 0xE5) # PUSH AF ; PUSH HL
              z.bytes(0xAF) # XOR A: NOP
              z.jump(0x32, :entry_looked_for) # LD (the sample loop's look),A
              z.jump(0x32, :direct_entry_looked_for) # LD (the direct loop's look),A
              z.word(0x2A, mailbox_at(QUEUE_READ)) # LD HL,(queue read): L the entry's place
              z.word(0x3A, mailbox_at(QUEUE_WRITTEN)) # LD A,(queue written)
              z.bytes(0xBD) # CP L
              z.jump(0xCA, :entry_done) # JP Z: none
              z.bytes(0x26, QUEUE >> 8) # LD H,the queue's page
              z.bytes(0x7E, 0xB7) # LD A,(HL) ; OR A
              z.jump(0xFA, glides ? :entry_kind : :entry_play) # JP M: a play
              z.label(:entry_busy)
              z.bytes(0x1A, 0x87) # LD A,(DE) ; ADD A,A
              z.jump(0xDA, :entry_busy) # JP C: the chip is still taking the last value
              z.bytes(0x5E) # LD E,(HL): the part's ports
              z.bytes(0x24, 0x7E, 0x12) # INC H ; LD A,(HL) ; LD (DE),A: the register named
              z.bytes(0x24, 0x7E, 0x1C, 0x12) # INC H ; LD A,(HL) ; INC E ; LD (DE),A: its value
              z.bytes(0x1E, 0x00, 0x3E, ChipWrites::DAC_SAMPLE, 0x12) # LD E,0 ; LD A,$2A ; LD (DE),A
              emit_queue_moved_on(z, :entry_written)
              z.label(:entry_done)
              z.bytes(0xE1, 0xF1, 0xC9) # POP HL ; POP AF ; RET
              z.label(:entry_play)
              emit_queue_moved_on(z, :entry_play_moved_on)
              z.bytes(0x31, 0xF0, 0x1F) # LD SP,$1FF0: whatever was under way is dropped
              z.jump(0xC3, :new_play) # JP
            end

            # :init, the timers' lengths set; then :idle, the DAC at the middle of its range (quiet), and
            # every entry taken as it comes until a play does.
            def emit_driver_idle(z)
              z.label(:init)
              [[0x24, TIMER_A >> 2], [0x25, TIMER_A & 3], [0x26, TIMER_B]].each do |register, value|
                z.word(0x21, (register << 8) | value) # LD HL,register and value
                z.jump(0xCD, :set_fm) # CALL
              end
              z.word(0x11, 0x4000) # LD DE,$4000
              z.label(:idle)
              z.bytes(0x3E, ChipWrites::DAC_SAMPLE, 0x32, 0x00, 0x40) # LD A,$2A ; LD ($4000),A
              z.bytes(0x3E, 0x80, 0x32, 0x01, 0x40) # LD A,$80 ; LD ($4001),A
              z.bytes(0xAF) # XOR A: off the cartridge, if a chunk was dropped or a play read it directly
              z.word(0x32, mailbox_at(UNSAFE)) # LD (unsafe),A
              z.bytes(0x3E, MODE_IDLE) # LD A,idle
              z.word(0x32, playing_at(PLAYING_MODE)) # LD (mode),A
              z.label(:wait)
              z.word(0x3A, mailbox_at(QUEUE_READ)) # LD A,(queue read)
              z.bytes(0x47) # LD B,A
              z.word(0x3A, mailbox_at(QUEUE_WRITTEN)) # LD A,(queue written)
              z.bytes(0xB8) # CP B
              z.jump(0xCA, :wait) # JP Z
              z.jump(0xCD, :entry) # CALL
              z.jump(0xC3, :wait) # JP
            end

            # :new_play, the play in the mailbox started: the timers stopped, its fields copied, the step
            # written in, the copying started at its start into FIFO from FIFO's start, and
            # FIFO_FIRST_CHUNKS copied (:first_chunk_copied counts them) before both timers start again
            # together, so the second comes round with the 256th sample of this play. Nought plays, quiet.
            def emit_new_play(z)
              z.label(:new_play)
              z.word(0x3A, mailbox_at(PLAYS)) # LD A,(plays)
              z.bytes(0xB7) # OR A
              z.jump(0xCA, :idle) # JP Z
              z.bytes(0x21) # LD HL,timers and stopped
              z.label(:stopped)
              z.bytes(TIMERS_STOPPED, TIMERS)
              z.jump(0xCD, :set_fm) # CALL
              z.word(0x21, mailbox_at(PLAYING_FIELDS.first)) # LD HL,the mailbox's fields
              z.word(0x11, PLAYING) # LD DE,the Z80's copy
              z.word(0x01, PLAYING_FIELDS.size) # LD BC,their length
              z.bytes(0xED, 0xB0) # LDIR
              # LOOPS made 1 for a recording that goes round inside the bank it ends on, which is nearly
              # all of them, and 2 for one that goes back to another bank. Showing a bank takes longer than
              # a tick, and a short loop comes round hundreds of times a second.
              z.word(0x3A, playing_at(PLAYING_LOOPS)) # LD A,(loops)
              z.bytes(0xB7) # OR A
              z.jump(0xCA, :loop_known) # JP Z
              z.word(0x2A, playing_at(PLAYING_LOOP_BANK)) # LD HL,(loop bank)
              z.bytes(0xED)
              z.word(0x5B, playing_at(PLAYING_END_BANK)) # LD DE,(end bank)
              z.bytes(0xB7, 0xED, 0x52) # OR A ; SBC HL,DE
              z.bytes(0x3E, 0x01) # LD A,1
              z.jump(0xCA, :loop_noted) # JP Z
              z.bytes(0x3C) # INC A
              z.label(:loop_noted)
              z.word(0x32, playing_at(PLAYING_LOOPS)) # LD (loops),A
              z.label(:loop_known)
              z.word(0x2A, playing_at(PLAYING_END_AT)) # LD HL,(end at)
              z.bytes(0xED)
              z.word(0x5B, playing_at(PLAYING_LOOP_AT)) # LD DE,(loop at)
              z.bytes(0xB7, 0xED, 0x52) # OR A ; SBC HL,DE
              z.word(0x22, playing_at(PLAYING_BACK)) # LD (back),HL
              emit_step_written(z)
              z.bytes(0xAF) # XOR A: nothing owed
              z.word(0x32, playing_at(PLAYING_OWED)) # LD (owed),A
              emit_owed_calls_written(z)
              z.word(0x3A, mailbox_at(Z80_STEP + 1)) # LD A,(step's whole samples)
              z.bytes(0xFE, DIRECT_STEP) # CP direct
              z.jump(0xD2, :direct_play) # JP NC
              z.bytes(0xAF) # XOR A: MODE_COPIED
              z.word(0x32, playing_at(PLAYING_MODE)) # LD (mode),A
              z.bytes(0xD9) # EXX
              z.word(0x2A, mailbox_at(BANK)) # LD HL,(bank)
              z.call_bank
              z.word(0x2A, mailbox_at(AT)) # LD HL,(at)
              z.word(0x11, FIFO) # LD DE,FIFO
              z.bytes(0xD9) # EXX
              z.word(0x11, 0x4000) # LD DE,$4000
              z.bytes(0x06, FIFO_FIRST_CHUNKS) # LD B,chunks
              z.jump(0x21, :first_chunk_copied) # LD HL,label
              z.jump(0x22, :chunk_copied_then) # LD (the chunk's last jump),HL
              z.jump(0xC3, :fill) # JP

              z.label(:first_chunk_copied)
              z.bytes(0x05) # DEC B
              z.jump(0xC2, :fill) # JP NZ
              z.jump(0x21, :fill_poll) # LD HL,label
              z.jump(0x22, :chunk_copied_then) # LD (the chunk's last jump),HL
              z.bytes(0x21) # LD HL,timers and counting
              z.label(:counting)
              z.bytes(TIMERS_COUNTING, TIMERS)
              z.jump(0xCD, :set_fm) # CALL
              z.word(0x21, FIFO) # LD HL,FIFO
              z.word(0x01, 0x0000) # LD BC,0: no samples sounded, and no fraction
              z.jump(0xC3, :fill_poll) # JP
            end

            # The mailbox's step written into the readers' adds, the copied play's and the direct one's.
            def emit_step_written(z)
              z.word(0x3A, mailbox_at(Z80_STEP)) # LD A,(step's fraction)
              z.jump(0x32, :step_fraction) # LD (the add),A
              z.jump(0x32, :direct_step_fraction) # LD (the add),A
              z.word(0x3A, mailbox_at(Z80_STEP + 1)) # LD A,(step's whole samples)
              z.jump(0x32, :step_whole) # LD (the add),A
              z.jump(0x32, :direct_step_whole) # LD (the add),A
            end

            # UNSAFE made UNSAFE_STOPPED, and BLOCK waited out, so the 68000 stops the Z80 for its next
            # read of the controllers and is not reading them now. The same order as a chunk's: the flag
            # first, then BLOCK. A is lost. +wait+ names its one label.
            def emit_stopped_for_pad(z, wait)
              z.bytes(0x3E, UNSAFE_STOPPED) # LD A,stopped
              z.word(0x32, mailbox_at(UNSAFE)) # LD (unsafe),A
              z.label(wait)
              z.word(0x3A, mailbox_at(BLOCK)) # LD A,(block)
              z.bytes(0xB7) # OR A
              z.jump(0xC2, wait) # JP NZ
              z.bytes(0x3E, MODE_DIRECT) # LD A,direct
              z.word(0x32, playing_at(PLAYING_MODE)) # LD (mode),A
            end

            # :direct_play, from :new_play: a play of DIRECT_STEP or more read straight from the cartridge,
            # from its start. :direct_loop, a tick of it: the sample read before the tick is awaited, kept
            # in the other A, and sent to the DAC once the tick's flag is cleared; then the reader moved on
            # (:direct_moved_on). The second timer passes over what a stop covered at once, as the program
            # did before it read ahead. In the first set: HL where in the window, C the fraction, B the
            # samples sounded since the second timer, DE the chip's first port.
            #
            # This is the old loop, with its cycles. A tick is seen in 21 and takes 235 more at most from
            # the sample's read, against 269.
            def emit_direct_play(z)
              z.label(:direct_play)
              emit_stopped_for_pad(z, :direct_play_waits)
              z.word(0x2A, mailbox_at(BANK)) # LD HL,(bank)
              z.call_bank
              z.bytes(0x21) # LD HL,timers and counting
              z.label(:direct_counting)
              z.bytes(TIMERS_COUNTING, TIMERS)
              z.jump(0xCD, :set_fm) # CALL
              z.word(0x2A, mailbox_at(AT)) # LD HL,(at)
              z.word(0x11, 0x4000) # LD DE,$4000
              z.word(0x01, 0x0000) # LD BC,0

              z.label(:direct_loop)
              z.bytes(0x7E, 0x08) # LD A,(HL) ; EX AF,AF'
              z.label(:direct_wait)
              z.bytes(0x1A, 0x0F) # LD A,(DE) ; RRCA
              z.jump(0xD2, :direct_wait) # JP NC
              z.bytes(0x0F) # RRCA: the second timer's flag
              z.jump(0xDA, :direct_second_timer) # JP C
              emit_timers_written(z, SAMPLE_TICK_SEEN, :direct_tick_seen)
              z.bytes(0x08, 0x1C, 0x12, 0x1D, 0x04) # EX AF,AF' ; INC E ; LD (DE),A ; DEC E ; INC B
              z.jump(0xCD, :direct_moved_on) # CALL
              z.label(:direct_entry_looked_for)
              z.bytes(ENTRY_NONE)
              z.jump(0xC3, :direct_loop) # JP

              z.label(:direct_second_timer)
              emit_timers_written(z, BOTH_TICKS_SEEN, :direct_both_ticks_seen)
              z.bytes(0x08, 0x1C, 0x12, 0x1D, 0x04) # EX AF,AF' ; INC E ; LD (DE),A ; DEC E ; INC B
              z.jump(0xCD, :direct_moved_on) # CALL
              z.bytes(0xAF, 0x90, 0x06, 0x00) # XOR A ; SUB B ; LD B,0
              z.jump(0xCA, :direct_loop) # JP Z
              z.jump(0xFA, :direct_loop) # JP M
              z.bytes(0x47) # LD B,A
              z.label(:direct_missed)
              z.jump(0xCD, :direct_moved_on) # CALL
              z.bytes(0x05) # DEC B
              z.jump(0xC2, :direct_missed) # JP NZ
              z.jump(0xC3, :direct_loop) # JP

              # :direct_moved_on: HL moved on by the step, into the next bank when it runs off the window,
              # and back by PLAYING_BACK as many times as it takes past the end, or to where the loop is
              # in another bank; a play played once ends there. A is lost.
              z.label(:direct_moved_on)
              z.bytes(0x79, 0xC6) # LD A,C ; ADD A,the step's fraction
              z.label(:direct_step_fraction)
              z.bytes(0x00)
              z.bytes(0x4F, 0x7D, 0xCE) # LD C,A ; LD A,L ; ADC A,the step's whole samples
              z.label(:direct_step_whole)
              z.bytes(0x00)
              z.bytes(0x6F) # LD L,A
              z.jump(0xD2, :direct_in_window) # JP NC
              z.bytes(0x24) # INC H
              z.jump(0xC2, :direct_in_window) # JP NZ
              z.bytes(0x26, WINDOW >> 8, 0xE5) # LD H,the window's start ; PUSH HL
              z.word(0x2A, playing_at(PLAYING_BANK_NOW)) # LD HL,(bank now)
              z.bytes(0x23) # INC HL
              z.call_bank
              z.bytes(0xE1) # POP HL
              z.label(:direct_in_window)
              z.bytes(0x7D, 0xD6) # LD A,L ; SUB end low
              z.label(:direct_end_low)
              z.bytes(0x00)
              z.bytes(0x7C, 0xDE) # LD A,H ; SBC A,end high
              z.label(:direct_end_high)
              z.bytes(0x00)
              z.bytes(0xF8) # RET M: before the end
              z.word(0x3A, playing_at(PLAYING_LOOPS)) # LD A,(loops)
              z.bytes(0x3D) # DEC A
              z.jump(0xFA, :direct_ended) # JP M: played once
              z.jump(0xC2, :direct_other_bank) # JP NZ
              z.bytes(0xD5, 0xED) # PUSH DE ; LD DE,(back)
              z.word(0x5B, playing_at(PLAYING_BACK))
              z.bytes(0xB7, 0xED, 0x52, 0xD1) # OR A ; SBC HL,DE ; POP DE
              z.jump(0xC3, :direct_in_window) # JP
              z.label(:direct_other_bank)
              z.word(0x2A, playing_at(PLAYING_LOOP_BANK)) # LD HL,(loop bank)
              z.call_bank
              z.word(0x2A, playing_at(PLAYING_LOOP_AT)) # LD HL,(loop at)
              z.bytes(0xC9) # RET
              z.label(:direct_ended)
              z.bytes(0x31, 0xF0, 0x1F) # LD SP,$1FF0
              z.jump(0xC3, :idle) # JP
            end

            # Fewer than FIFO_FULL bytes in FIFO not sounded yet: carry set. In the first set; A is lost.
            def emit_fill_looked_at(z)
              z.bytes(0xD9, 0x7B, 0xD9, 0x95) # EXX ; LD A,E ; EXX ; SUB L
              z.bytes(0xFE, FIFO_FULL) # CP full
            end

            # :fill_poll, between two chunks: the tick, if it has come, and the next chunk if FIFO is not
            # full. :fill, a chunk copied, with the 68000's leave (UNSAFE, then BLOCK), the tick looked for
            # twice on the way (#emit_chunk_tick_looked_for), and the copy taken back to the end it ran past
            # (:end_low and :end_high hold that end, written by :set_bank, and :copy_past_end handles it);
            # then on to :chunk_copied_then, which is :fill_poll but while a play's first chunks are copied.
            # :blocked, the copy put off, the ticks still sounded, until BLOCK is clear. :full, waiting for
            # the tick.
            def emit_fifo_filled(z)
              z.label(:fill_poll)
              z.bytes(0x1A, 0x0F) # LD A,(DE) ; RRCA: the first timer's flag
              z.jump(0xDA, :tick) # JP C
              z.bytes(0xD9, 0x7B, 0xD9, 0x95) # EXX ; LD A,E ; EXX ; SUB L
              z.jump(0xFA, :full) # JP M: FIFO_FULL or more
              z.label(:fill)
              z.bytes(0xD9) # EXX
              z.bytes(0x7C) # LD A,H: never nought, in the window or in the silence
              z.word(0x32, mailbox_at(UNSAFE)) # LD (unsafe),A
              z.word(0x3A, mailbox_at(BLOCK)) # LD A,(block)
              z.bytes(0xB7) # OR A
              z.jump(0xC2, :blocked) # JP NZ
              CHUNK_TICKS_LOOKED_FOR_AFTER.each_cons(2) do |from, to|
                (to - from).times { z.bytes(0xED, 0xA0) } # LDI
                emit_chunk_tick_looked_for(z) if to < FIFO_CHUNK
              end
              # HL less the end, which is nought short of the last bank: no higher than nought, or past
              # the end by less than a chunk.
              z.bytes(0x7D, 0xD6) # LD A,L ; SUB end low
              z.label(:end_low)
              z.bytes(0x00)
              z.bytes(0x7C, 0xDE) # LD A,H ; SBC A,end high
              z.label(:end_high)
              z.bytes(0x00)
              z.jump(0xF4, :copy_past_end) # CALL P
              z.bytes(0x16, FIFO >> 8) # LD D,FIFO's page: the chunk that ends it moves DE off it
              z.bytes(0xAF) # XOR A
              z.word(0x32, mailbox_at(UNSAFE)) # LD (unsafe),A
              z.bytes(0xD9) # EXX
              z.bytes(0xC3) # JP
              z.label(:chunk_copied_then)
              z.address(:fill_poll)

              z.label(:blocked)
              z.bytes(0xAF) # XOR A
              z.word(0x32, mailbox_at(UNSAFE)) # LD (unsafe),A
              z.bytes(0xD9) # EXX
              z.label(:blocked_wait)
              z.bytes(0x1A, 0x0F) # LD A,(DE) ; RRCA
              z.jump(0xDA, :tick) # JP C
              z.word(0x3A, mailbox_at(BLOCK)) # LD A,(block)
              z.bytes(0xB7) # OR A
              z.jump(0xC2, :blocked_wait) # JP NZ
              z.jump(0xC3, :fill) # JP

              # :chunk_tick, called in the second set with A the chip's status turned right once: the tick
              # sounded as :tick sounds it, the chip's ports named by their addresses, since DE is the copy's.
              z.label(:chunk_tick)
              z.bytes(0x0F) # RRCA: the second timer's flag
              z.jump(0xDA, :chunk_second_timer) # JP C
              z.bytes(0x3E, TIMERS, 0x32, 0x00, 0x40) # LD A,timers ; LD ($4000),A
              z.bytes(0x3E) # LD A,value
              z.label(:chunk_tick_seen)
              z.bytes(SAMPLE_TICK_SEEN)
              z.bytes(0x32, 0x01, 0x40) # LD ($4001),A
              z.bytes(0x3E, ChipWrites::DAC_SAMPLE, 0x32, 0x00, 0x40) # LD A,$2A ; LD ($4000),A
              z.bytes(0xD9) # EXX
              emit_sample_to_dac(z)
              emit_reader_moved(z)
              z.bytes(0xD9, 0xC9) # EXX ; RET
              z.label(:chunk_second_timer)
              z.bytes(0xD9) # EXX
              z.jump(0xCD, :second_timer) # CALL
              z.bytes(0xD9, 0xC9) # EXX ; RET

              z.label(:full)
              z.bytes(0x1A, 0x0F) # LD A,(DE) ; RRCA
              z.jump(0xD2, :full) # JP NC
            end

            # Where in a chunk the tick is looked for: after this many bytes of it. A tick that comes while
            # a chunk is copied must be seen soon enough that its flag is cleared before the next tick
            # comes, or that one is lost with it.
            CHUNK_TICKS_LOOKED_FOR_AFTER = [0, 0, 3, 6, FIFO_CHUNK].freeze

            # In the second set, partway through a chunk: the tick sounded (:chunk_tick) if it has come.
            def emit_chunk_tick_looked_for(z)
              z.word(0x3A, 0x4000) # LD A,($4000)
              z.bytes(0x0F) # RRCA
              z.jump(0xDC, :chunk_tick) # CALL C
            end

            # The timers' register named, +value+ written to it with the third voice's mode (the value's
            # label +patched+, TIMER_WRITES), and the DAC's named again. In the first set, E nought.
            def emit_timers_written(z, value, patched)
              z.bytes(0x3E, TIMERS, 0x12, 0x1C) # LD A,timers ; LD (DE),A ; INC E
              z.bytes(0x3E) # LD A,value
              z.label(patched)
              z.bytes(value)
              z.bytes(0x12, 0x1D) # LD (DE),A ; DEC E
              z.bytes(0x3E, ChipWrites::DAC_SAMPLE, 0x12) # LD A,$2A ; LD (DE),A
            end

            # The sample at the reader sent to the DAC, and counted. In the first set, E nought.
            def emit_sample_to_dac(z)
              z.bytes(0x7E, 0x1C, 0x12, 0x1D) # LD A,(HL) ; INC E ; LD (DE),A ; DEC E
              z.bytes(0x04) # INC B
            end

            # The reader moved on by the step, read from where :step_fraction and :step_whole hold it.
            def emit_reader_moved(z)
              z.jump(0x3A, :step_fraction) # LD A,(the step's fraction)
              z.bytes(0x81, 0x4F) # ADD A,C ; LD C,A
              z.jump(0x3A, :step_whole) # LD A,(the step's whole samples)
              z.bytes(0x8D, 0x6F) # ADC A,L ; LD L,A
            end

            # :tick, in the first set with A the chip's status turned right once: the tick sounded, then
            # the queue (:entry_looked_for), and a chunk; or, with FIFO full, a sample owed
            # (:owed_looked_for) and the wait for the next tick.
            #
            # The tick's flag is cleared first, then its sample sent to the DAC, as GEMS's DACME does: the
            # sooner the flag is cleared after the tick, the later the tick can be seen without the next
            # one lost. Then the reader is moved on by the step, written into the instructions that add
            # it. The second timer's flag, next to the first timer's, sends it to :second_timer first.
            def emit_sample_sounded(z)
              z.label(:tick)
              z.bytes(0x0F) # RRCA: the second timer's flag
              z.jump(0xDA, :tick_second_timer) # JP C
              emit_timers_written(z, SAMPLE_TICK_SEEN, :sample_tick_seen)
              emit_sample_to_dac(z)
              z.bytes(0x79, 0xC6) # LD A,C ; ADD A,the step's fraction
              z.label(:step_fraction)
              z.bytes(0x00)
              z.bytes(0x4F, 0x7D, 0xCE) # LD C,A ; LD A,L ; ADC A,the step's whole samples
              z.label(:step_whole)
              z.bytes(0x00)
              z.bytes(0x6F) # LD L,A
              z.label(:tick_sounded)
              emit_fill_looked_at(z)
              z.label(:entry_looked_for)
              z.bytes(ENTRY_NONE)
              z.jump(0xDA, :fill) # JP C
              z.label(:owed_looked_for)
              z.bytes(ENTRY_NONE)
              z.jump(0xC3, :full) # JP
              z.label(:tick_second_timer)
              z.jump(0xCD, :second_timer) # CALL
              z.jump(0xC3, :tick_sounded) # JP
            end

            # :second_timer, called in the first set: the second timer has come round. The tick is sounded
            # as any other; then what the count of samples is short of 256 is the ticks a stop covered,
            # and that many samples are owed (PLAYING_OWED). A tick that finds FIFO full, and so has the time
            # to spare before the next, moves the reader on once more until they are paid (:owed, which
            # ENTRY_OWED calls from :owed_looked_for), so the recording is back where the clock says a
            # sample at a time, with no stop long enough to lose a tick of its own. More than half of 256
            # short is not
            # believed: it is what a tick counted twice would look like, and passing over most of a round
            # for it would be heard.
            def emit_missed_passed_over(z)
              z.label(:second_timer)
              emit_timers_written(z, BOTH_TICKS_SEEN, :both_ticks_seen)
              emit_sample_to_dac(z)
              emit_reader_moved(z)
              z.bytes(0xAF, 0x90, 0x06, 0x00) # XOR A ; SUB B ; LD B,0
              z.bytes(0xC8) # RET Z
              z.bytes(0xF8) # RET M
              z.word(0x32, playing_at(PLAYING_OWED)) # LD (owed),A
              z.bytes(0x3E, ENTRY_OWED) # LD A,the call
              emit_owed_calls_written(z)
              z.bytes(0xC9) # RET

              # :owed, which ENTRY_OWED calls: the reader moved on once more, unless it is FIFO_KEPT_BEHIND
              # short of what is copied, which ends what is owed. Every register but the reader's is kept.
              z.label(:owed)
              z.bytes(0xF5) # PUSH AF
              z.bytes(0xD9, 0x7B, 0xD9, 0x95) # EXX ; LD A,E ; EXX ; SUB L
              z.bytes(0xFE, FIFO_KEPT_BEHIND) # CP kept behind
              z.jump(0xDA, :owed_paid) # JP C
              emit_reader_moved(z)
              z.word(0x3A, playing_at(PLAYING_OWED)) # LD A,(owed)
              z.bytes(0x3D) # DEC A
              z.word(0x32, playing_at(PLAYING_OWED)) # LD (owed),A
              z.jump(0xC2, :owed_kept) # JP NZ
              z.label(:owed_paid)
              z.bytes(0x3E, ENTRY_NONE) # LD A,NOP
              emit_owed_calls_written(z)
              z.label(:owed_kept)
              z.bytes(0xF1, 0xC9) # POP AF ; RET
            end

            # A written into :owed_looked_for.
            def emit_owed_calls_written(z) = z.jump(0x32, :owed_looked_for) # LD (owed looked for),A

            # :set_fm, FM register H set to L, and the DAC's named again. A is lost.
            def emit_fm_set(z)
              z.label(:set_fm)
              z.word(0x3A, 0x4000) # LD A,($4000)
              z.bytes(0x87) # ADD A,A
              z.jump(0xDA, :set_fm) # JP C: the chip is still taking the last write
              z.bytes(0x7C) # LD A,H
              z.word(0x32, 0x4000) # LD ($4000),A
              z.bytes(0x7D) # LD A,L
              z.word(0x32, 0x4001) # LD ($4001),A
              z.bytes(0x3E, ChipWrites::DAC_SAMPLE) # LD A,$2A
              z.word(0x32, 0x4000) # LD ($4000),A
              z.bytes(0xC9) # RET
            end

            # :set_bank, the bank in HL shown in the window and noted, and the end a chunk is held to
            # written into the chunk: the recording's end on its last bank, and nought, the window's end,
            # on any other. HL and A are lost. The window's bank register is one bit wide and takes nine
            # writes, the lowest bit first.
            def emit_bank_shown(z)
              z.label(:set_bank)
              z.word(0x22, playing_at(PLAYING_BANK_NOW)) # LD (bank now),HL
              z.bytes(0x7D) # LD A,L
              8.times { z.bytes(0x32, 0x00, 0x60, 0x0F) } # LD ($6000),A ; RRCA
              z.bytes(0x7C, 0x32, 0x00, 0x60) # LD A,H ; LD ($6000),A
              z.word(0x3A, playing_at(PLAYING_END_BANK)) # LD A,(end bank, low)
              z.bytes(0xBD) # CP L
              z.jump(0xC2, :not_last) # JP NZ
              z.word(0x3A, playing_at(PLAYING_END_BANK + 1)) # LD A,(end bank, high)
              z.bytes(0xBC) # CP H
              z.jump(0xC2, :not_last) # JP NZ
              z.word(0x2A, playing_at(PLAYING_END_AT)) # LD HL,(end at)
              z.jump(0xC3, :end_noted) # JP
              z.label(:not_last)
              z.word(0x21, 0x0000) # LD HL,0
              z.label(:end_noted)
              emit_end_written(z)
              z.bytes(0xC9) # RET
            end

            # HL written into the chunk and the direct reader as the end they are held to. A is lost.
            def emit_end_written(z)
              z.bytes(0x7D) # LD A,L
              z.jump(0x32, :end_low) # LD (end low),A
              z.jump(0x32, :direct_end_low) # LD (end low),A
              z.bytes(0x7C) # LD A,H
              z.jump(0x32, :end_high) # LD (end high),A
              z.jump(0x32, :direct_end_high) # LD (end high),A
            end

            # :copy_past_end, in the second set, called from a chunk that ran past its end: the bytes past
            # it taken back off FIFO, HL moved to where the copy goes on, and as many copied from there, so
            # the chunk is whole. Past the window's end, the next bank from the window's start; past the
            # recording's, where it goes round to, in its bank; and after one played once, the silence
            # (:silence), which goes round on itself. A copy that runs past its end again (a recording that
            # ends on a bank's edge, or goes round in less than a chunk) is moved on again. BC is lost.
            #
            # Each chunk starts a whole number of chunks into FIFO, so none runs off FIFO's page partway:
            # the copy moves DE on as one number, and a chunk that ran off the page would write into the
            # queue's.
            def emit_copy_past_end(z)
              z.label(:copy_past_end)
              z.bytes(0x16, FIFO >> 8) # LD D,FIFO's page
              emit_chunk_tick_looked_for(z)
              z.jump(0x3A, :end_low) # LD A,(end low)
              z.bytes(0x47, 0x7D, 0x90, 0x4F) # LD B,A ; LD A,L ; SUB B ; LD C,A: how far past
              z.bytes(0x7B, 0x91, 0x5F) # LD A,E ; SUB C ; LD E,A
              z.jump(0x3A, :end_high) # LD A,(end high)
              z.bytes(0xB7) # OR A
              z.jump(0xC2, :recording_ended) # JP NZ: the recording's end, not the window's
              z.word(0x2A, playing_at(PLAYING_BANK_NOW)) # LD HL,(bank now)
              z.bytes(0x23) # INC HL
              z.call_bank
              z.word(0x21, WINDOW) # LD HL,the window's start
              z.jump(0xC3, :copy_moved_on) # JP
              z.label(:recording_ended)
              z.word(0x3A, playing_at(PLAYING_LOOPS)) # LD A,(loops)
              z.bytes(0x3D) # DEC A
              z.jump(0xCA, :loop_in_bank) # JP Z
              z.jump(0xFA, :played_once) # JP M
              z.bytes(0x3D) # DEC A
              z.jump(0xC2, :silence_counted) # JP NZ: LOOPS_SILENCE
              z.word(0x2A, playing_at(PLAYING_LOOP_BANK)) # LD HL,(loop bank)
              z.call_bank
              z.label(:loop_in_bank)
              z.word(0x2A, playing_at(PLAYING_LOOP_AT)) # LD HL,(loop at)
              z.label(:copy_moved_on)
              emit_chunk_tick_looked_for(z)
              z.bytes(0x79, 0xB7) # LD A,C ; OR A
              z.jump(0xCA, :copy_whole) # JP Z
              z.bytes(0x06, 0x00) # LD B,0
              # Two bytes at a time, the tick looked for between.
              z.label(:copy_rest)
              z.bytes(0xED, 0xA0) # LDI
              z.jump(0xE2, :copy_rest_done) # JP PO: BC is nought
              z.bytes(0xED, 0xA0) # LDI
              z.jump(0xE2, :copy_rest_done) # JP PO
              emit_chunk_tick_looked_for(z)
              z.jump(0xC3, :copy_rest) # JP
              z.label(:copy_rest_done)
              z.bytes(0x16, FIFO >> 8) # LD D,FIFO's page
              z.label(:copy_whole)
              z.jump(0x3A, :end_low) # LD A,(end low)
              z.bytes(0x47, 0x7D, 0x90) # LD B,A ; LD A,L ; SUB B
              z.jump(0x3A, :end_high) # LD A,(end high)
              z.bytes(0x47, 0x7C, 0x98) # LD B,A ; LD A,H ; SBC A,B
              z.jump(0xF2, :copy_past_end) # JP P
              z.bytes(0xC9) # RET
              z.label(:played_once)
              z.jump(0x21, :silence_end) # LD HL,the silence's end
              emit_end_written(z)
              z.bytes(0x3E, LOOPS_SILENCE) # LD A,silence
              z.word(0x32, playing_at(PLAYING_LOOPS)) # LD (loops),A
              z.bytes(0x3E, SILENCE_CHUNKS) # LD A,chunks
              z.word(0x32, playing_at(PLAYING_SILENCE_LEFT)) # LD (silence left),A
              z.label(:silence_counted)
              z.jump(0x21, :silence) # LD HL,the silence
              z.word(0x3A, playing_at(PLAYING_SILENCE_LEFT)) # LD A,(silence left)
              z.bytes(0x3D) # DEC A
              z.word(0x32, playing_at(PLAYING_SILENCE_LEFT)) # LD (silence left),A
              z.jump(0xC2, :copy_moved_on) # JP NZ
              # The reader is past the recording's end: nothing more to sound.
              z.bytes(0x31, 0xF0, 0x1F) # LD SP,$1FF0: the chunk under way dropped
              z.bytes(0xD9) # EXX: the first set, whose DE is the chip's port
              z.jump(0xC3, :idle) # JP
              z.label(:silence)
              z.bytes(*Array.new(FIFO_CHUNK, 0x80))
              z.label(:silence_end)
            end

            # A glide, in a game whose notes glide: an entry of the queue that is GLIDE_ENTRY gives the play
            # the mailbox's step from here, where it has got to, and with nothing playing it changes nothing.
            # :entry sends an entry that is not an FM write here before :entry_play.
            # Must be written after everything else in the program: every other label then sits where it
            # does in a game with no glide, which builds the same bytes and whose labels Sound and
            # #emit_queued read.
            def emit_glide_entry(z)
              z.label(:entry_kind) # A the entry's first byte
              z.bytes(0xFE, GLIDE_ENTRY) # CP glide
              z.jump(0xC2, :entry_play) # JP NZ
              emit_queue_moved_on(z, :glide_moved_on)
              emit_step_written(z)
              # A copied play glided to DIRECT_STEP or more goes on read straight from the cartridge, from
              # where the reader is: the copy's place less what is read ahead of the reader, brought back
              # inside the loop when that is before where it goes round.
              z.word(0x3A, mailbox_at(Z80_STEP + 1)) # LD A,(step's whole samples)
              z.bytes(0xFE, DIRECT_STEP) # CP direct
              z.jump(0xDA, :entry_done) # JP C
              z.word(0x3A, playing_at(PLAYING_MODE)) # LD A,(mode)
              z.bytes(0xB7) # OR A: MODE_COPIED
              z.jump(0xC2, :entry_done) # JP NZ
              z.word(0x3A, playing_at(PLAYING_LOOPS)) # LD A,(loops)
              z.bytes(0xFE, LOOPS_SILENCE) # CP silence: the recording is copied to its end already
              z.jump(0xCA, :entry_done) # JP Z
              z.bytes(0xE1, 0xF1) # POP HL ; POP AF: the reader back
              emit_stopped_for_pad(z, :glide_waits)
              z.bytes(0xD9, 0x7B, 0xD9, 0x95) # EXX ; LD A,E ; EXX ; SUB L: read ahead of the reader
              z.bytes(0xD9, 0x4F, 0x06, 0x00) # EXX ; LD C,A ; LD B,0
              z.bytes(0xB7, 0xED, 0x42) # OR A ; SBC HL,BC
              z.word(0x3A, playing_at(PLAYING_LOOPS)) # LD A,(loops)
              z.bytes(0x3D) # DEC A
              z.jump(0xC2, :glide_placed) # JP NZ: no loop in this bank
              z.label(:glide_back)
              z.bytes(0xE5, 0xED) # PUSH HL ; LD DE,(loop at)
              z.word(0x5B, playing_at(PLAYING_LOOP_AT))
              z.bytes(0xB7, 0xED, 0x52, 0xE1) # OR A ; SBC HL,DE ; POP HL
              z.jump(0xD2, :glide_placed) # JP NC
              z.bytes(0xED)
              z.word(0x5B, playing_at(PLAYING_BACK)) # LD DE,(back)
              z.bytes(0x19) # ADD HL,DE
              z.jump(0xC3, :glide_back) # JP
              z.label(:glide_placed)
              z.bytes(0x7C, 0xB7) # LD A,H ; OR A
              z.jump(0xFA, :glide_in_window) # JP M
              z.bytes(0x26, WINDOW >> 8) # LD H,the window's start: the bank's start was passed back over
              z.label(:glide_in_window)
              z.bytes(0xE5, 0xD9, 0xE1) # PUSH HL ; EXX ; POP HL
              z.bytes(0x31, 0xF0, 0x1F) # LD SP,$1FF0
              z.jump(0xC3, :direct_loop) # JP
            end

            # A very small Z80 assembler, as much of one as the program above takes: bytes, an instruction
            # with a 16-bit number low byte first, and an instruction naming a label's address (a jump, a
            # call, or a load or store at a place in the program itself). Assembled, it is the program's
            # bytes (#code) and where each label is in them (#address_of), for the 68000 to write into.
            class Z80Program
              attr_reader :code

              def initialize
                @code = []
                @labels = {}
                @jumps = {}
              end

              def bytes(*values) = @code.concat(values)
              def word(opcode, value) = @code.push(opcode, value & 0xFF, value >> 8)
              def label(name) = @labels[name] = @code.length
              def address_of(name) = @labels.fetch(name)
              def length = @code.length

              def jump(opcode, target)
                @code.push(opcode)
                address(target)
              end

              # +target+'s address, two bytes, low first, with no instruction before it.
              def address(target)
                @jumps[@code.length] = target
                @code.push(0, 0)
              end

              def call_bank = jump(0xCD, :set_bank)

              # The jumps filled in. The program must end below what it reads ahead into, which is the
              # Z80's memory from FIFO on.
              def assembled
                @jumps.each do |at, target|
                  place = @labels.fetch(target)
                  @code[at] = place & 0xFF
                  @code[at + 1] = place >> 8
                end
                raise ArgumentError, "the Z80's program is #{length} bytes, past its read-ahead at #{FIFO}" if length > FIFO

                @code.freeze
                @labels.freeze
                freeze
              end
            end
          end
        end
      end
    end
  end
end
