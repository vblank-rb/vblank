# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE GAME'S OWN RECORDINGS (`play_sample`, `stop_sample`).
          #
          # The Advance's processor adds every recording a game plays into one stream, and the interpreter
          # does the same sums (Reference::Mixer). The PlayStation's sound chip needs none of that: each
          # recording plays on a voice of its own, read out of sound memory (SoundMemory), at a pitch and a
          # loudness of its own. So the interpreter's places are the chip's voices, one each: place 0 is
          # voice FIRST_VOICE, past the four game voices, and there are as many as the console sounds
          # recordings at once (Console::Description#recordings_at_once).
          #
          # THE COUNT IS THE INTERPRETER'S. What the game can tell of a recording — the log saying it came
          # round again, its place coming free at its end — follows where it has got to, so each place
          # keeps that as the interpreter's mixer does (Reference::Mixer#mix_voice): how far into the
          # recording, in whole samples and 65536ths, moved on once a frame by the samples a frame reads
          # (Console::SampleClock.on_voices), read back by its hold at its end, or freed. The chip's own
          # voice plays the same samples at the same rate, so it ends where the count does.
          #
          # Each play the game writes is a row of the table "recording_plays" (Lowering::Sound): where its
          # recording starts in sound memory, the voice's pitch and volume, the recording's length, how far
          # back it reads at its end (nought for one played once), how far it moves a frame, the number of
          # its entry in the sound log ([:sample, name]) and which recording it is.
          module Recordings
            PLACES = Console::PLAYSTATION.recordings_at_once
            FIRST_VOICE = SPUWrites::VOICES

            # A play's row in the table, a word each.
            START = 0
            PITCH = 4
            VOLUME = 8
            LENGTH = 12
            BACK = 16
            ADVANCE = 20
            ADVANCE_FRACTION = 24
            LOGGED = 28
            NAME = 32
            ROW_BYTES = 36

            # A place's state, PLACE_BYTES apart, a word each: which recording (its number plus one, nought
            # when the place is free), how far into it (whole samples and 65536ths), and the play's length,
            # read-back, how far a frame and log entry, copied from its row; whose it is (nought for the
            # game's own) and its TICKET: LOOPS set for one that loops, and how many the game had started
            # before it, which orders who gives way first.
            PLACES_STATE = "rt recordings places"
            HELD = 0
            POSITION = 4
            FRACTION = 8
            PLACE_LENGTH = 12
            PLACE_BACK = 16
            PLACE_ADVANCE = 20
            PLACE_ADVANCE_FRACTION = 24
            PLACE_LOGGED = 28
            OWNER = 32
            TICKET = 36
            PLACE_BYTES = 40
            LOOPS = 0x8000_0000

            # ...and, for each of the last Frame::STEPS_KEPT passes, by the pass's number less its multiples of
            # STEPS_KEPT, each place's recording as its wait ended: a byte a place.
            KEPT_BY_PASS = "rt recordings kept by pass"
            # WHAT COULD NOT BE PLAYED (Reference::Mixer#drops): how many plays found every place busy, and
            # the most places songs held at one of those moments.
            DROPS = "rt recordings drops"
            DROPS_MUSIC = "rt recordings drops music"
            TICKETS = "rt recordings tickets" # How many of its own sounds the game has started
            ALL = 0xFFFF # A stop that names no recording

            module_function

            # The voice of place +place+.
            def voice_of(place) = FIRST_VOICE + place

            def reserve(memory)
              [DROPS, DROPS_MUSIC, TICKETS].each { |name| memory.reserve(name, 4) }
              memory.reserve(PLACES_STATE, PLACES * PLACE_BYTES)
              memory.reserve(KEPT_BY_PASS, Frame::STEPS_KEPT * PLACES)
            end

            def emit(asm, memory)
              at = ->(name) { Runtime.at(memory, name) }
              emit_play(asm, at)
              emit_stop(asm, at)
              emit_frame(asm, at)
              emit_kept_for_pass(asm, at)
            end

            # t9 = gp plus the place's offset, for a place at +offset+ (a register holding it): its fields
            # are then at(PLACES_STATE) + field from t9.
            def emit_place_at(asm, offset)
              asm.addu(:t9, offset, :gp)
            end

            # rt_recordings_play(a0 = row): the play's entry logged, and the recording in the first free
            # place from its start (Reference::Mixer#start); with none free, counted as dropped. Its voice
            # told where the recording starts, its pitch and loudness, and started at the frame boundary.
            def emit_play(asm, at)
              place = ->(field) { at.call(PLACES_STATE) + field }
              asm.label("rt_recordings_play")
              Music.enter(asm, %i[s0 s1])
              asm.li(:t0, ROW_BYTES)
              asm.multu(:a0, :t0)
              asm.mflo(:t0)
              asm.la(:s0, "recording_plays")
              asm.addu(:s0, :s0, :t0)
              asm.lw(:a0, LOGGED, :s0)
              asm.jal("rt_sound_log")
              asm.move(:s1, :zero) # the place's offset
              asm.label("rt_recordings_play_find")
              emit_place_at(asm, :s1)
              asm.lw(:t0, place.call(HELD), :t9)
              asm.beq(:t0, :zero, "rt_recordings_play_found")
              asm.addiu(:s1, :s1, PLACE_BYTES)
              asm.sltiu(:t0, :s1, PLACES * PLACE_BYTES)
              asm.bne(:t0, :zero, "rt_recordings_play_find")
              emit_drop(asm, at, place)
              asm.b("rt_recordings_play_done")
              asm.label("rt_recordings_play_found")
              # The game's own, below every song, with the next ticket.
              asm.sw(:zero, place.call(OWNER), :t9)
              asm.lw(:t0, at.call(TICKETS), :gp)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, at.call(TICKETS), :gp)
              asm.lw(:t1, BACK, :s0)
              asm.beq(:t1, :zero, "rt_recordings_play_ticket")
              asm.lui(:t1, LOOPS >> 16)
              asm.or(:t0, :t0, :t1)
              asm.label("rt_recordings_play_ticket")
              asm.sw(:t0, place.call(TICKET), :t9)
              asm.lw(:t0, NAME, :s0)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, place.call(HELD), :t9)
              asm.sw(:zero, place.call(POSITION), :t9)
              asm.sw(:zero, place.call(FRACTION), :t9)
              { LENGTH => PLACE_LENGTH, BACK => PLACE_BACK, ADVANCE => PLACE_ADVANCE, ADVANCE_FRACTION => PLACE_ADVANCE_FRACTION,
                LOGGED => PLACE_LOGGED }.each do |from, to|
                asm.lw(:t0, from, :s0)
                asm.sw(:t0, place.call(to), :t9)
              end
              emit_voice_start(asm)
              asm.label("rt_recordings_play_done")
              Music.leave(asm, %i[s0 s1])
            end

            # The voice of the place at offset s1 told about the row at s0: where its recording starts, its
            # pitch, its loudness on both speakers, and started at the frame boundary.
            def emit_voice_start(asm)
              h = Console::PS1Hardware
              asm.li(:t0, PLACE_BYTES)
              asm.divu(:s1, :t0)
              asm.mflo(:t2)
              asm.addiu(:t2, :t2, FIRST_VOICE) # the voice
              asm.sll(:t3, :t2, 4)
              { h::SPU_START => START, h::SPU_PITCH => PITCH, h::SPU_VOLUME_LEFT => VOLUME, h::SPU_VOLUME_RIGHT => VOLUME }.each do |register, field|
                asm.addiu(:a0, :t3, register)
                asm.lw(:a1, field, :s0)
                asm.jal("rt_spu_write")
              end
              asm.li(:t0, PLACE_BYTES)
              asm.divu(:s1, :t0)
              asm.mflo(:a0)
              asm.addiu(:a0, :a0, FIRST_VOICE)
              asm.jal("rt_sound_key_on")
            end

            # A play that found every place busy: counted, with the most places songs held at such a moment
            # (Reference::Mixer#record_drop). Places of songs are not made yet, so that is nought.
            def emit_drop(asm, at, _place)
              asm.lw(:t0, at.call(DROPS), :gp)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, at.call(DROPS), :gp)
            end

            # rt_recordings_stop(a0 = a recording's number, or ALL; a1 = the log entry): every place of the
            # game's own holding that recording, or any, freed and its voice let go
            # (Reference::Mixer#stop); then the stop logged.
            def emit_stop(asm, at)
              place = ->(field) { at.call(PLACES_STATE) + field }
              asm.label("rt_recordings_stop")
              Music.enter(asm, %i[s0 s1 s2])
              asm.move(:s0, :a0)
              asm.move(:s2, :a1)
              asm.move(:s1, :zero)
              asm.label("rt_recordings_stop_place")
              emit_place_at(asm, :s1)
              asm.lw(:t0, place.call(HELD), :t9)
              asm.beq(:t0, :zero, "rt_recordings_stop_next")
              asm.lw(:t1, place.call(OWNER), :t9)
              asm.bne(:t1, :zero, "rt_recordings_stop_next")
              asm.li(:t1, ALL)
              asm.beq(:s0, :t1, "rt_recordings_stop_it")
              asm.addiu(:t0, :t0, -1)
              asm.bne(:t0, :s0, "rt_recordings_stop_next")
              asm.label("rt_recordings_stop_it")
              asm.sw(:zero, place.call(HELD), :t9)
              asm.li(:t0, PLACE_BYTES)
              asm.divu(:s1, :t0)
              asm.mflo(:a0)
              asm.addiu(:a0, :a0, FIRST_VOICE)
              asm.jal("rt_sound_key_off")
              asm.label("rt_recordings_stop_next")
              asm.addiu(:s1, :s1, PLACE_BYTES)
              asm.sltiu(:t0, :s1, PLACES * PLACE_BYTES)
              asm.bne(:t0, :zero, "rt_recordings_stop_place")
              asm.move(:a0, :s2)
              asm.jal("rt_sound_log")
              Music.leave(asm, %i[s0 s1 s2])
            end

            # rt_recordings_frame: every place a frame on (Reference::Mixer#mix_voice): the fraction carried,
            # the whole samples added; past the end, a play once through is over and its place free, and one
            # that holds reads back by its hold as many times as it takes, the game's own logging each time
            # round.
            def emit_frame(asm, at)
              place = ->(field) { at.call(PLACES_STATE) + field }
              asm.label("rt_recordings_frame")
              Music.enter(asm, %i[s0 s1])
              asm.move(:s1, :zero)
              asm.label("rt_recordings_frame_place")
              emit_place_at(asm, :s1)
              asm.lw(:t0, place.call(HELD), :t9)
              asm.beq(:t0, :zero, "rt_recordings_frame_next")
              asm.lw(:t0, place.call(FRACTION), :t9)
              asm.lw(:t1, place.call(PLACE_ADVANCE_FRACTION), :t9)
              asm.addu(:t0, :t0, :t1)
              asm.srl(:t2, :t0, 16) # the carry
              asm.andi(:t0, :t0, 0xFFFF)
              asm.sw(:t0, place.call(FRACTION), :t9)
              asm.lw(:t0, place.call(POSITION), :t9)
              asm.lw(:t1, place.call(PLACE_ADVANCE), :t9)
              asm.addu(:t0, :t0, :t1)
              asm.addu(:t0, :t0, :t2)
              asm.sw(:t0, place.call(POSITION), :t9)
              asm.label("rt_recordings_frame_ends")
              emit_place_at(asm, :s1)
              asm.lw(:t0, place.call(POSITION), :t9)
              asm.lw(:t1, place.call(PLACE_LENGTH), :t9)
              asm.sltu(:t2, :t0, :t1)
              asm.bne(:t2, :zero, "rt_recordings_frame_next")
              asm.lw(:t2, place.call(PLACE_BACK), :t9)
              asm.bne(:t2, :zero, "rt_recordings_frame_round")
              asm.b("rt_recordings_frame_next") { asm.sw(:zero, place.call(HELD), :t9) } # once through: over
              asm.label("rt_recordings_frame_round")
              asm.subu(:t0, :t0, :t2)
              asm.sw(:t0, place.call(POSITION), :t9)
              asm.lw(:t1, place.call(OWNER), :t9)
              asm.bne(:t1, :zero, "rt_recordings_frame_ends")
              asm.lw(:a0, place.call(PLACE_LOGGED), :t9)
              asm.jal("rt_sound_log")
              asm.b("rt_recordings_frame_ends")
              asm.label("rt_recordings_frame_next")
              asm.addiu(:s1, :s1, PLACE_BYTES)
              asm.sltiu(:t0, :s1, PLACES * PLACE_BYTES)
              asm.bne(:t0, :zero, "rt_recordings_frame_place")
              Music.leave(asm, %i[s0 s1])
            end

            # rt_recordings_kept_for_pass: which recording each place holds (the low byte of its HELD) copied
            # into KEPT_BY_PASS for the pass whose wait is ending, for a reader of the run to hold to the
            # interpreter's mix at that pass's frame boundary (Sound's rt_sound_frame).
            def emit_kept_for_pass(asm, at)
              asm.label("rt_recordings_kept_for_pass")
              asm.lw(:t0, at.call(Frame::PASSES), :gp)
              asm.andi(:t0, :t0, Frame::STEPS_KEPT - 1)
              asm.li(:t1, PLACES)
              asm.multu(:t0, :t1)
              asm.mflo(:t0)
              asm.addu(:t0, :t0, :gp)
              PLACES.times do |place|
                asm.lw(:t1, at.call(PLACES_STATE) + (place * PLACE_BYTES) + HELD, :gp)
                asm.sb(:t1, at.call(KEPT_BY_PASS) + place, :t0)
              end
              asm.jr(:ra)
            end
          end
        end
      end
    end
  end
end
