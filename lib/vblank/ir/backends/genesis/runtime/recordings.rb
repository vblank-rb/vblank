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
          # (MAILBOX) and adds one to the first byte, which the Z80 looks at between samples. The same FM
          # chip takes the 68000's own writes, so each of those asks for the bus too, and puts the chip's
          # address back at the DAC's before it lets go (Sound's rt_fm_write).
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

            # THE Z80'S SIDE. Everything it reads is in its own memory, at MAILBOX on.
            MAILBOX = 0x1F00
            NEW_PLAY = 0 # A byte the 68000 adds one to
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

            Z80_MEMORY = 0xA00000
            WINDOW = 0x8000 # Where the window starts in the Z80's memory, and how much it shows

            # The program's cycles between one sample and the next, and how many times the wait in it goes
            # round to make that come to Console::GENESIS's recording_voice_hz, with every sample taking
            # the time of one in the recording's last 256 bytes (the program's :not_near_end).
            WAIT_ROUNDS = 6

            module_function

            def reserve(memory)
              memory.reserve(PLACE, PLACE_BYTES)
              memory.reserve(KEPT_BY_PASS, Frame::STEPS_KEPT * 2)
              [DROPS, DROPS_MUSIC, OWNER_ASKING].each { |name| memory.reserve(name, 2) }
            end

            # A play's row, for "recording_plays": +start+ a label.
            def emit_row(asm, start:, length:, back:, advance:, logged:, name:, step:)
              asm.data_longs(start)
              asm.data_longs(length, back, advance >> 16)
              asm.data_words(advance & 0xFFFF, logged, name, step)
            end

            def emit(asm, memory)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              emit_start(asm)
              emit_play(asm, at)
              emit_note(asm, at)
              emit_stop(asm, at)
              emit_frame(asm, at)
              emit_mail(asm, at)
              emit_kept_for_pass(asm, memory, at)
            end

            # The Z80's bus asked for and waited for, and given back. D0, D1 and A0 are left alone.
            def emit_bus_taken(asm)
              h = Console::GenesisHardware
              asm.move(:w, asm.imm(h::Z80_REQUEST), asm.abs_l(h::Z80_BUS_REQUEST))
              label = "rt_bus_wait_#{asm.here}"
              asm.label(label)
              asm.btst(0, asm.abs_l(h::Z80_BUS_REQUEST))
              asm.branch(:ne, label)
            end

            # The FM chip's address put back at the DAC's for the Z80's next write (the 68000's writes moved
            # it), and the Z80 let go.
            def emit_bus_given_back(asm)
              h = Console::GenesisHardware
              asm.jsr(asm.abs_l("rt_fm_wait"))
              asm.move(:b, asm.imm(ChipWrites::DAC_SAMPLE), asm.abs_l(h::FM))
              asm.clr(:w, asm.abs_l(h::Z80_BUS_REQUEST))
            end

            # rt_recordings_start, as the game starts: the Z80's program copied into its memory and started,
            # the bus held all the while (Runtime::Boot has held it since power-on).
            def emit_start(asm)
              h = Console::GenesisHardware
              asm.label("rt_recordings_start")
              asm.lea(asm.abs_l("rt_z80_program"), asm.a(0))
              asm.lea(asm.abs_l(Z80_MEMORY), asm.a(1))
              asm.move(:w, asm.imm(driver.length - 1), asm.d(0))
              asm.label("rt_recordings_start_next")
              asm.move(:b, asm.post(0), asm.post(1))
              asm.dbra(asm.d(0), "rt_recordings_start_next")
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
              asm.data_bytes(driver)
              asm.data_bytes(0) if driver.length.odd?
            end

            # rt_recordings_play(row): the play's entry logged, and the recording in the place from its start
            # (Reference::Mixer#start) if it is free. With it busy, the play is dropped, as the mixer drops it.
            def emit_play(asm, at)
              asm.label("rt_recordings_play")
              asm.mulu(asm.imm(ROW_BYTES), asm.d(0))
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
            def emit_note(asm, at)
              asm.label("rt_recordings_note")
              asm.mulu(asm.imm(ROW_BYTES), asm.d(0))
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
              emit_bus_taken(asm)
              asm.lea(asm.abs_l(Z80_MEMORY + MAILBOX), asm.a(1))
              asm.clr(:b, asm.disp(1, PLAYS))
              asm.addq(:b, 1, asm.disp(1, NEW_PLAY))
              asm.clr(:w, asm.abs_l(Console::GenesisHardware::Z80_BUS_REQUEST))
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

            # rt_recordings_send: what the row A4 points at plays, left in the Z80's mailbox. The window shows
            # 32K of the cartridge, so a place in the cartridge is a bank and where in the window: the bank
            # is what is above the low 15 bits, and the window starts at $8000.
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
              asm.move(:b, asm.disp(4, STEP + 1), asm.post(2)) # Z80_STEP, low byte first
              asm.move(:b, asm.disp(4, STEP), asm.post(2))
              asm.tst(:l, asm.disp(4, BACK))
              asm.scc(:ne, asm.ind(2)) # LOOPS
              asm.move(:b, asm.imm(1), asm.disp(1, PLAYS))
              asm.addq(:b, 1, asm.disp(1, NEW_PLAY))
              asm.clr(:w, asm.abs_l(Console::GenesisHardware::Z80_BUS_REQUEST))
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

            # THE Z80'S PROGRAM, as its bytes, the mailbox and the chips by the numbers above. Its registers: B
            # the play it last saw, HL where it reads in the window, DE its step, C the fraction of a sample.
            #
            #   start: reset, and the first play awaited with the DAC at the middle of its range (quiet)
            #   loop:  one sample to the DAC, HL moved on by DE, a new bank when it runs off the window, the end
            #          of the recording looked for while on its last bank, a wait, and the mailbox looked at
            def driver
              Z80Program.new.tap do |z|
                mail = ->(field) { MAILBOX + field }
                z.bytes(0xF3) # DI
                z.bytes(0x31, 0xF0, 0x1F) # LD SP,$1FF0
                z.bytes(0x06, 0x00) # LD B,0
                z.label(:idle)
                z.bytes(0x3E, ChipWrites::DAC_SAMPLE, 0x32, 0x00, 0x40) # LD A,$2A ; LD ($4000),A
                z.bytes(0x3E, 0x80, 0x32, 0x01, 0x40) # LD A,$80 ; LD ($4001),A
                z.label(:wait)
                z.word(0x3A, mail.call(NEW_PLAY)) # LD A,(new play)
                z.bytes(0xB8) # CP B
                z.jump(0xCA, :wait) # JP Z
                z.label(:new_play)
                z.word(0x3A, mail.call(NEW_PLAY)) # LD A,(new play)
                z.bytes(0x47) # LD B,A
                z.word(0x3A, mail.call(PLAYS)) # LD A,(plays)
                z.bytes(0xB7) # OR A
                z.jump(0xCA, :idle) # JP Z
                z.word(0x2A, mail.call(BANK)) # LD HL,(bank)
                z.call_bank
                z.word(0x2A, mail.call(AT)) # LD HL,(at)
                z.bytes(0xED)
                z.word(0x5B, mail.call(Z80_STEP)) # LD DE,(step)
                z.bytes(0x0E, 0x00) # LD C,0
                z.label(:loop)
                z.bytes(0x3E, ChipWrites::DAC_SAMPLE, 0x32, 0x00, 0x40) # LD A,$2A ; LD ($4000),A
                z.bytes(0x7E, 0x32, 0x01, 0x40) # LD A,(HL) ; LD ($4001),A
                z.bytes(0x79, 0x83, 0x4F) # LD A,C ; ADD A,E ; LD C,A
                z.bytes(0x7D, 0x8A, 0x6F) # LD A,L ; ADC A,D ; LD L,A
                z.jump(0xD2, :same_window) # JP NC
                z.bytes(0x24) # INC H
                z.jump(0xC2, :same_window) # JP NZ
                z.bytes(0x26, 0x80) # LD H,$80
                z.bytes(0xE5) # PUSH HL
                z.word(0x2A, mail.call(BANK_NOW)) # LD HL,(bank now)
                z.bytes(0x23) # INC HL
                z.call_bank
                z.bytes(0xE1) # POP HL
                z.label(:same_window)
                z.word(0x3A, mail.call(END_HIGH_NOW)) # LD A,(end's high byte, on the last bank)
                z.bytes(0xBC) # CP H
                z.jump(0xC2, :not_near_end) # JP NZ
                z.word(0x3A, mail.call(END_AT)) # LD A,(end's low byte)
                z.bytes(0xBD) # CP L
                z.jump(0xCA, :ended) # JP Z
                z.jump(0xD2, :timing) # JP NC: the end is still above L
                z.label(:ended)
                z.word(0x3A, mail.call(LOOPS)) # LD A,(loops)
                z.bytes(0xB7) # OR A
                z.jump(0xCA, :idle) # JP Z
                z.word(0x2A, mail.call(LOOP_BANK)) # LD HL,(loop bank)
                z.call_bank
                z.word(0x2A, mail.call(LOOP_AT)) # LD HL,(loop at)
                z.label(:timing)
                z.bytes(0x3E, WAIT_ROUNDS) # LD A,rounds
                z.label(:rounds)
                z.bytes(0x3D) # DEC A
                z.jump(0xC2, :rounds) # JP NZ
                z.word(0x3A, mail.call(NEW_PLAY)) # LD A,(new play)
                z.bytes(0xB8) # CP B
                z.jump(0xC2, :new_play) # JP NZ
                z.jump(0xC3, :loop) # JP

                # EVERY SAMPLE TAKES THE SAME TIME, wherever it lies. A sample in the recording's last
                # 256 bytes is tested against the end's low byte as well, four instructions more; one
                # anywhere else comes here and spends the same 37 cycles doing nothing (a read and
                # two loads of A, which the wait loads again, and the jump back). Without it a
                # recording played faster than it was recorded up to its last 256 bytes and slower
                # inside them, so a short one and a long one were heard at different pitches.
                z.label(:not_near_end)
                z.word(0x3A, mail.call(END_AT)) # LD A,(end's low byte)
                z.bytes(0x3E, 0x00, 0x3E, 0x00) # LD A,0 ; LD A,0
                z.jump(0xC3, :timing) # JP

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
                z.bytes(0xC9) # RET
              end.assembled
            end

            # A very small Z80 assembler, as much of one as the program above takes: bytes, an instruction
            # with a 16-bit number low byte first, and a jump to a label.
            class Z80Program
              def initialize
                @code = []
                @labels = {}
                @jumps = {}
              end

              def bytes(*values) = @code.concat(values)
              def word(opcode, value) = @code.push(opcode, value & 0xFF, value >> 8)
              def label(name) = @labels[name] = @code.length

              def jump(opcode, target)
                @jumps[@code.length + 1] = target
                @code.push(opcode, 0, 0)
              end

              def call_bank = jump(0xCD, :set_bank)

              def assembled
                @jumps.each do |at, target|
                  place = @labels.fetch(target)
                  @code[at] = place & 0xFF
                  @code[at + 1] = place >> 8
                end
                @code.freeze
              end
            end
          end
        end
      end
    end
  end
end
