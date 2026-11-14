# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # A GAME'S RECORDINGS (`play_sample`, `stop_sample`, a song's recorded part).
          #
          # THE FM CHIP'S SIXTH VOICE CAN BE A SPEAKER HELD BY HAND: with its DAC on, the chip plays whatever
          # byte it was last told in register $2A, so a recording is a byte written thirteen thousand times a
          # second. That is far too often for the 68000, with a game to run, so it is the sound processor's
          # one job: the Z80 is sent a little program at power-on (#driver), which reads the recording from
          # the cartridge through its window onto the 68000's memory and writes one byte after another, and
          # the game goes on. A Genesis sounds one recording at a time.
          #
          # HOW THE TWO TALK. The 68000 can write into the Z80's memory only after asking for its bus, which
          # stops the Z80 for that moment. It leaves what to play in the mailbox at the top of that memory
          # (MAILBOX), and puts an entry in the queue beside it (QUEUE) saying so, which the Z80 looks at
          # between samples. THE FM CHIP IS THE Z80'S ALONE in a game that plays recordings: the 68000's
          # writes to it are entries in the same queue (Sound's rt_fm_write), and the Z80 makes one a
          # sample, between the DAC's writes. The console's own sound drivers do the same, so the 68000
          # never stops the Z80 for longer than it takes to write a few bytes into its memory.
          #
          # THE COUNT IS THE INTERPRETER'S. What the game can tell of a recording (the log saying it came
          # round again, the place coming free at its end) follows where it has got to, so the 68000 keeps
          # that as the interpreter's mixer does, in whole samples and 65536ths, moved on once a frame by
          # the samples a frame reads (Console::SampleClock.on_voices).
          #
          # A SONG'S RECORDED PART plays its notes in the same place, by the interpreter's rule
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
            # WHAT COULD NOT BE PLAYED (Reference::Mixer#drops): how many plays and notes found the place
            # busy, and whether a song's held it at one of those moments.
            DROPS = "rt recordings drops"
            DROPS_MUSIC = "rt recordings drops music"
            OWNER_ASKING = "rt recordings owner asking"

            ALL = 0xFFFF

            # THE Z80'S SIDE. Everything it reads is in its own memory, at QUEUE and MAILBOX on.
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
            BANK_NOW = 17
            END_HIGH_NOW = 19 # END_AT's high byte, while the window is on the last bank; nought otherwise

            QUEUE_READ = 20 # How far the Z80 has read the queue, the same way

            # THE QUEUE: what the Z80 is asked to do, in order, an entry at each of 256 places that go
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

            # THE Z80'S CLOCK FOR A SAMPLE IS THE FM CHIP'S FIRST TIMER (#driver). A timer of that chip
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
            # THE SAME REGISTER HOLDS THE THIRD FM VOICE'S MODE in its top two bits, so every write the
            # Z80 makes to it carries the mode the game last gave: the 68000 writes the mode into each
            # of the Z80's writes (TIMER_WRITES, the labels of their values in #driver) as it asks for it.
            MODE_BITS = 0xC0
            TIMER_WRITES = { stopped: TIMERS_STOPPED, counting: TIMERS_COUNTING,
                             sample_tick_seen: SAMPLE_TICK_SEEN, both_ticks_seen: BOTH_TICKS_SEEN }.freeze

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
              emit_bus_for_pad(asm)
            end

            # STOPPING THE Z80. The 68000 stops it for three things: a copy by the video chip, a write into
            # the Z80's memory, and a read of the controller's port, which the console's maker says must
            # not come just before a Z80 read of the cartridge (S3 in docs/genesis/dma-and-the-sound-processor.md).
            # The controller is read in the blank's interrupt, so the interrupt asks for the bus too
            # (rt_z80_bus_for_pad), and the same bulletins say a request made in an interrupt breaks one
            # the main program has made (S4). So the main program holds interrupts off from asking for the
            # bus until it lets go: the interrupt never comes inside one of its stops, and a stop of the
            # interrupt's own is over before the main program runs again.
            #
            # A STOP FOR EACH, NOT ONE FOR THE WHOLE BLANK. Sonic 3 & Knuckles stops its Z80 once in the
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

            # rt_z80_bus_for_pad: in the blank's interrupt, the controller read (Frame's rt_pad_read) with the
            # Z80 stopped.
            def emit_bus_for_pad(asm)
              asm.label("rt_z80_bus_for_pad")
              emit_bus_requested(asm)
              asm.jsr(asm.abs_l("rt_pad_read"))
              emit_bus_released(asm)
              asm.rts
            end

            # rt_z80_queued(register, value, part in D3): an entry put in the Z80's queue, the bus held.
            # D2 and A1 are used. A FULL QUEUE is let go of for a little while, the Z80 taking entries
            # meanwhile, until there is a place.
            def emit_queued(asm)
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
              [QUEUE_WRITTEN, QUEUE_READ, PLAYS].each { |field| asm.clr(:b, asm.abs_l(Z80_MEMORY + MAILBOX + field)) }
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
              emit_queued(asm)
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
            def emit_side_queued(asm)
              asm.move(:w, asm.imm(0x100 | (ChipWrites::SPEAKERS + 2)), asm.d(0))
              asm.move(:w, asm.disp(4, SIDE), asm.d(1))
              asm.jsr(asm.abs_l("rt_fm_write"))
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
              emit_side_queued(asm) if sides
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

            # THE Z80'S PROGRAM, assembled, the mailbox and the chips by the numbers above. Its registers: HL
            # where it reads in the window, DE its step, C the fraction of a sample, and B the samples a
            # stop covered while it passes over them; and in its second set, HL and DE the FM chip's
            # first two ports, B the samples sounded since the second timer last came round, and C how far
            # it has read the queue.
            #
            #   start: the timers' lengths set, and the queue awaited with the DAC at the middle of its
            #          range (quiet), each FM write made as it comes, until a play does
            #   loop:  the next sample read, the first timer's tick awaited, the sample to the DAC, HL moved
            #          on by DE, a new bank when it runs off the window, the end of the recording looked
            #          for while on its last bank, the tick's flag cleared, and the queue looked at: one
            #          entry taken, if there is one
            #
            # A SAMPLE SOUNDS ON A TICK OF THE FM CHIP'S FIRST TIMER, NOT AFTER A COUNTED WAIT. The Z80 is
            # stopped many times a frame: for every block the video chip copies (Picture#emit_dma_started),
            # and for the queue. A program that counts its own cycles from one sample to the next loses
            # the length of every stop, so the recording plays flat for as long as the stops go on. The
            # timer is in the FM chip and counts whether the Z80 runs or not, so the gap between two
            # samples no longer depends on how long the work between them took.
            #
            # THE SAMPLES A STOP COVERED ARE PASSED OVER, NOT SOUNDED LATE. The timer's flag says a tick
            # came, not how many, so ticks that came while the Z80 was stopped would be lost with it.
            # The second timer is set to come round with every 256th tick of the first. The program
            # counts the samples it sounds in a byte, and when the second timer's flag shows, what the
            # byte is short of 256 is the number of ticks a stop covered: HL is moved on by that many
            # samples with nothing written to the DAC, which holds its last sample meanwhile. So the
            # recording is back where the clock says within 256 samples of any stop, a little over a
            # frame. A stop longer than the second timer's round loses a whole round.
            #
            # THE FM CHIP IS WRITTEN HERE ALONE, so the register named is always one the program named
            # itself, and it names the DAC's again after every other. A song's note is some thirty
            # registers. The 68000 used to write them itself, stopping the Z80 for each and for the
            # chip's waits round it, which held the DAC still for long enough to lose whole waves of a
            # recording; now each is three bytes of the queue, and the Z80 writes one between two
            # samples. A sample that writes one takes longer than a tick, and the tick it runs over is
            # one of those the second timer finds missing: the recording is held one sample longer and
            # then passes over one, which cannot be heard. The chip's busy flag is looked at before each
            # entry is written, since the Z80 writes them back to back while no recording plays.
            def driver(glides: false)
              Z80Program.new.tap do |z|
                mail = ->(field) { MAILBOX + field }
                # The timers' register named, +value+ written to it with the third voice's mode (the
                # value's label +patched+, TIMER_WRITES), and the DAC's named again. In the second set.
                emit_timers_written = lambda do |value, patched|
                  z.bytes(0x3E, TIMERS, 0x77) # LD A,timers ; LD (HL),A
                  z.bytes(0x3E) # LD A,value
                  z.label(patched)
                  z.bytes(value)
                  z.bytes(0x12) # LD (DE),A
                  z.bytes(0x3E, ChipWrites::DAC_SAMPLE, 0x77) # LD A,$2A ; LD (HL),A
                end
                # The queue's next entry looked at, in the second set, with DE pointing at its first
                # byte: to +play+ for a new play, and on for an FM write, its part in A.
                emit_entry_looked_at = lambda do |play|
                  z.bytes(0x16, QUEUE >> 8, 0x59) # LD D,the queue's page ; LD E,C
                  z.bytes(0x1A, 0xB7) # LD A,(DE) ; OR A
                  z.jump(0xFA, play) # JP M
                end
                # The entry taken: C moved on and noted for the 68000, DE the chip's port again.
                emit_entry_taken = lambda do
                  z.bytes(0x0C, 0x79) # INC C ; LD A,C
                  z.word(0x32, mail.call(QUEUE_READ)) # LD (queue read),A
                  z.word(0x11, 0x4001) # LD DE,$4001
                end
                # The entry's register set to its value on its part of the chip, once the chip has taken
                # the last value written to it, and the DAC's register named again.
                emit_entry_written = lambda do |busy|
                  z.label(busy)
                  z.bytes(0xCB, 0x7E) # BIT 7,(HL): the chip busy
                  z.jump(0xC2, busy) # JP NZ
                  z.bytes(0x6F) # LD L,A: the part's ports
                  z.bytes(0x14, 0x1A, 0x77) # INC D ; LD A,(DE) ; LD (HL),A: the register named
                  z.bytes(0x14, 0x1A, 0x2C, 0x77) # INC D ; LD A,(DE) ; INC L ; LD (HL),A: its value
                  emit_entry_taken.call
                  z.bytes(0x2E, 0x00, 0x3E, ChipWrites::DAC_SAMPLE, 0x77) # LD L,0 ; LD A,$2A ; LD (HL),A
                end
                # HL moved on a sample: by DE, into a new bank when it runs off the window, and back to
                # where the recording goes round, or to :idle, at its end. Then on to +done+.
                #
                # +patched+ for the one every sample runs, which has to fit between two ticks with
                # the rest of the loop: the end it looks for is written into its two compares
                # (:set_bank and :new_play write them), which is two reads of the mailbox fewer.
                emit_sample_passed = lambda do |name, done, patched: false|
                  same_window = DerivedNames.sub_label(name, :same_window)
                  ended = DerivedNames.sub_label(name, :ended)
                  same_bank = DerivedNames.sub_label(name, :same_bank)
                  z.bytes(0x79, 0x83, 0x4F) # LD A,C ; ADD A,E ; LD C,A
                  z.bytes(0x7D, 0x8A, 0x6F) # LD A,L ; ADC A,D ; LD L,A
                  z.jump(0xD2, same_window) # JP NC
                  z.bytes(0x24) # INC H
                  z.jump(0xC2, same_window) # JP NZ
                  z.bytes(0x26, 0x80) # LD H,$80
                  z.bytes(0xE5) # PUSH HL
                  z.word(0x2A, mail.call(BANK_NOW)) # LD HL,(bank now)
                  z.bytes(0x23) # INC HL
                  z.call_bank
                  z.bytes(0xE1) # POP HL
                  z.label(same_window)
                  if patched
                    z.bytes(0x7C, 0xFE) # LD A,H ; CP the end's high byte, on the last bank
                    z.label(:end_high_patched)
                    z.bytes(0x00)
                    z.jump(0xC2, done) # JP NZ
                    z.bytes(0x7D, 0xFE) # LD A,L ; CP the end's low byte
                    z.label(:end_low_patched)
                    z.bytes(0x00)
                    z.jump(0xDA, done) # JP C: L is still below the end
                  else
                    z.word(0x3A, mail.call(END_HIGH_NOW)) # LD A,(end's high byte, on the last bank)
                    z.bytes(0xBC) # CP H
                    z.jump(0xC2, done) # JP NZ
                    z.word(0x3A, mail.call(END_AT)) # LD A,(end's low byte)
                    z.bytes(0xBD) # CP L
                    z.jump(0xCA, ended) # JP Z
                    z.jump(0xD2, done) # JP NC: the end is still above L
                  end
                  z.label(ended)
                  z.word(0x3A, mail.call(LOOPS)) # LD A,(loops)
                  z.bytes(0x3D) # DEC A
                  z.jump(0xCA, same_bank) # JP Z
                  z.jump(0xFA, :idle) # JP M: played once
                  z.word(0x2A, mail.call(LOOP_BANK)) # LD HL,(loop bank)
                  z.call_bank
                  z.label(same_bank)
                  z.word(0x2A, mail.call(LOOP_AT)) # LD HL,(loop at)
                  z.jump(0xC3, done) # JP
                end

                z.bytes(0xF3) # DI
                z.bytes(0x31, 0xF0, 0x1F) # LD SP,$1FF0
                [[0x24, TIMER_A >> 2], [0x25, TIMER_A & 3], [0x26, TIMER_B]].each do |register, value|
                  z.word(0x21, (register << 8) | value) # LD HL,register and value
                  z.jump(0xCD, :set_fm) # CALL
                end
                z.bytes(0xD9) # EXX
                z.bytes(0x21, 0x00, 0x40, 0x11, 0x01, 0x40) # LD HL,$4000 ; LD DE,$4001
                z.bytes(0x0E, 0x00) # LD C,0: the queue read from its start
                z.bytes(0xD9) # EXX
                z.label(:idle)
                z.bytes(0x3E, ChipWrites::DAC_SAMPLE, 0x32, 0x00, 0x40) # LD A,$2A ; LD ($4000),A
                z.bytes(0x3E, 0x80, 0x32, 0x01, 0x40) # LD A,$80 ; LD ($4001),A
                z.bytes(0xD9) # EXX
                # Nothing playing: every entry is taken as it comes.
                z.label(:wait)
                z.word(0x3A, mail.call(QUEUE_WRITTEN)) # LD A,(queue written)
                z.bytes(0xB9) # CP C
                z.jump(0xCA, :wait) # JP Z
                emit_entry_looked_at.call(glides ? :wait_entry : :wait_play)
                emit_entry_written.call(:wait_busy)
                z.jump(0xC3, :wait) # JP
                z.label(:wait_play)
                emit_entry_taken.call
                z.bytes(0xD9) # EXX

                z.label(:new_play)
                z.word(0x3A, mail.call(PLAYS)) # LD A,(plays)
                z.bytes(0xB7) # OR A
                z.jump(0xCA, :idle) # JP Z
                # Both timers stopped and started again together, so the second comes round with the
                # 256th sample of this play, and the count of them from nought.
                z.bytes(0x21) # LD HL,timers and stopped
                z.label(:stopped)
                z.bytes(TIMERS_STOPPED, TIMERS)
                z.jump(0xCD, :set_fm) # CALL
                z.bytes(0x21) # LD HL,timers and counting
                z.label(:counting)
                z.bytes(TIMERS_COUNTING, TIMERS)
                z.jump(0xCD, :set_fm) # CALL
                # LOOPS made 1 for a recording that goes round inside the bank it ends on, which is
                # nearly all of them, and 2 for one that goes back to another bank. Showing a bank
                # takes longer than a tick, and a short loop comes round hundreds of times a second.
                z.word(0x3A, mail.call(LOOPS)) # LD A,(loops)
                z.bytes(0xB7) # OR A
                z.jump(0xCA, :loop_known) # JP Z
                z.word(0x2A, mail.call(LOOP_BANK)) # LD HL,(loop bank)
                z.bytes(0xED)
                z.word(0x5B, mail.call(END_BANK)) # LD DE,(end bank)
                z.bytes(0xB7, 0xED, 0x52) # OR A ; SBC HL,DE
                z.bytes(0x3E, 0x01) # LD A,1
                z.jump(0xCA, :loop_noted) # JP Z
                z.bytes(0x3C) # INC A
                z.label(:loop_noted)
                z.word(0x32, mail.call(LOOPS)) # LD (loops),A
                z.label(:loop_known)
                z.word(0x3A, mail.call(END_AT)) # LD A,(end's low byte)
                z.jump(0x32, :end_low_patched) # LD (the compare),A
                z.word(0x2A, mail.call(BANK)) # LD HL,(bank)
                z.call_bank
                z.word(0x2A, mail.call(AT)) # LD HL,(at)
                z.bytes(0xED)
                z.word(0x5B, mail.call(Z80_STEP)) # LD DE,(step)
                z.bytes(0x0E, 0x00) # LD C,0
                z.bytes(0xD9, 0x06, 0x00, 0xD9) # EXX ; LD B,0 ; EXX

                # The sample is read before its tick is awaited, so it reaches the DAC as soon as the
                # tick is seen: the read is the one thing here that can be made to wait.
                z.label(:loop)
                z.bytes(0x7E) # LD A,(HL)
                z.bytes(0xD9) # EXX
                z.label(:tick)
                z.bytes(0xCB, 0x46) # BIT 0,(HL): the first timer's flag
                z.jump(0xCA, :tick) # JP Z
                z.bytes(0x12) # LD (DE),A: the sample to the DAC, whose register is the one named
                z.bytes(0x04) # INC B
                z.bytes(0xD9) # EXX
                emit_sample_passed.call(:sounded, :sounded_passed, patched: true)
                # THE TICK'S FLAG IS CLEARED AFTER HL HAS MOVED ON, NOT BEFORE. The chip takes a while
                # over each value written to it, a third of a sample's time. Moving HL on first puts
                # more than that while between the DAC's write and this one, and the rest of the
                # loop and the wait for the tick put as much between this one and the DAC's next.
                z.label(:sounded_passed)
                z.bytes(0xD9) # EXX
                z.bytes(0x7E, 0xE6, 0x02) # LD A,(HL) ; AND 2: the second timer's flag
                z.jump(0xC2, :second_timer) # JP NZ
                emit_timers_written.call(SAMPLE_TICK_SEEN, :sample_tick_seen)
                z.label(:mail)
                z.word(0x3A, mail.call(QUEUE_WRITTEN)) # LD A,(queue written)
                z.bytes(0xB9, 0xD9) # CP C ; EXX, which leaves the flags as they are
                z.jump(0xCA, :loop) # JP Z
                z.bytes(0xD9) # EXX
                emit_entry_looked_at.call(glides ? :loop_entry : :loop_play)
                emit_entry_written.call(:loop_busy)
                z.bytes(0xD9) # EXX
                z.jump(0xC3, :loop) # JP
                z.label(:loop_play)
                emit_entry_taken.call
                z.bytes(0xD9) # EXX
                z.jump(0xC3, :new_play) # JP

                # The second timer has come round: what the count of samples is short of 256 is the
                # ticks a stop covered, and that many samples are passed over. More than half of 256
                # short is not believed: it is what a tick counted twice would look like, and passing
                # over most of a round for it would be heard.
                z.label(:second_timer)
                emit_timers_written.call(BOTH_TICKS_SEEN, :both_ticks_seen)
                z.bytes(0xAF, 0x90) # XOR A ; SUB B
                z.bytes(0x06, 0x00) # LD B,0
                z.jump(0xCA, :mail) # JP Z
                z.jump(0xFA, :mail) # JP M
                z.bytes(0xD9, 0x47) # EXX ; LD B,A
                z.label(:missed)
                emit_sample_passed.call(:missed, :missed_passed)
                z.label(:missed_passed)
                z.bytes(0x05) # DEC B
                z.jump(0xC2, :missed) # JP NZ
                z.bytes(0xD9) # EXX
                z.jump(0xC3, :mail) # JP

                # FM register H set to L, and the DAC's named again. A is lost.
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

                # The bank in HL shown in the window and noted, END_HIGH_NOW set for it. HL is lost. The
                # window's bank register is one bit wide and takes nine writes, the lowest bit first.
                z.label(:set_bank)
                z.word(0x22, mail.call(BANK_NOW)) # LD (bank now),HL
                z.bytes(0x7D) # LD A,L
                8.times { z.bytes(0x32, 0x00, 0x60, 0x0F) } # LD ($6000),A ; RRCA
                z.bytes(0x7C, 0x32, 0x00, 0x60) # LD A,H ; LD ($6000),A
                z.word(0x3A, mail.call(END_BANK)) # LD A,(end bank, low)
                z.bytes(0xBD) # CP L
                z.jump(0xC2, :not_last) # JP NZ
                z.word(0x3A, mail.call(END_BANK + 1)) # LD A,(end bank, high)
                z.bytes(0xBC) # CP H
                z.jump(0xC2, :not_last) # JP NZ
                z.word(0x3A, mail.call(END_AT + 1)) # LD A,(end's high byte)
                z.jump(0xC3, :noted) # JP
                z.label(:not_last)
                z.bytes(0xAF) # XOR A
                z.label(:noted)
                z.word(0x32, mail.call(END_HIGH_NOW)) # LD (end high now),A
                z.jump(0x32, :end_high_patched) # LD (the compare),A
                z.bytes(0xC9) # RET
                emit_glide_entries(z, mail, emit_entry_taken) if glides
              end.assembled
            end

            # A GLIDE, in a game whose notes glide: an entry of the queue that is GLIDE_ENTRY gives the play
            # the mailbox's step from here, where it has got to, and is taken at once with nothing playing.
            # The two places that send an entry onward to a new play send it here first (#driver's
            # :wait_play and :loop_play, reached by the jumps to :wait_entry and :loop_entry instead).
            # Must be written after everything else in the program: every other label then sits where it
            # does in a game with no glide, which builds the same bytes and whose labels Sound reads.
            def emit_glide_entries(z, mail, emit_entry_taken)
              z.label(:loop_entry) # in the second set, A the entry's first byte
              z.bytes(0xFE, GLIDE_ENTRY) # CP glide
              z.jump(0xC2, :loop_play) # JP NZ
              emit_entry_taken.call
              z.bytes(0xD9) # EXX
              z.bytes(0xED)
              z.word(0x5B, mail.call(Z80_STEP)) # LD DE,(step)
              z.jump(0xC3, :loop) # JP
              z.label(:wait_entry) # nothing playing: the glide has nothing to move
              z.bytes(0xFE, GLIDE_ENTRY) # CP glide
              z.jump(0xC2, :wait_play) # JP NZ
              emit_entry_taken.call
              z.jump(0xC3, :wait) # JP
            end

            # A very small Z80 assembler, as much of one as the program above takes: bytes, an instruction
            # with a 16-bit number low byte first, and a jump to a label. Assembled, it is the program's
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
                @jumps[@code.length + 1] = target
                @code.push(opcode, 0, 0)
              end

              def call_bank = jump(0xCD, :set_bank)

              # The jumps filled in. The program must end below the queue, which is the Z80's memory
              # from QUEUE on.
              def assembled
                @jumps.each do |at, target|
                  place = @labels.fetch(target)
                  @code[at] = place & 0xFF
                  @code[at + 1] = place >> 8
                end
                raise ArgumentError, "the Z80's program is #{length} bytes, past its queue at #{QUEUE}" if length > QUEUE

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
