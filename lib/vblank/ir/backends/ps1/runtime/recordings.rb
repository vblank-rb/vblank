# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE RECORDINGS: the game's own (`play_sample`, `stop_sample`), and the notes of songs' and sound
          # effects' parts that play one.
          #
          # The Advance's processor adds every recording a game plays into one stream, and the interpreter
          # does the same sums (Reference::Mixer). The PlayStation's sound chip needs none of that: each
          # recording plays on a voice of its own, read out of sound memory (SoundMemory), at a pitch and a
          # loudness of its own. So the interpreter's places are the chip's voices, one each: place 0 is
          # voice FIRST_VOICE, past the four game voices, and there are as many as the console sounds
          # recordings at once (Console::Description#recordings_at_once).
          #
          # THE COUNT IS THE INTERPRETER'S. What the game can tell of a recording — the log saying it came
          # round again, its place coming free at its end, how loud its shape has it — follows where it has
          # got to, so each place keeps that as the interpreter's mixer does (Reference::Mixer#mix_voice):
          # how far into the recording, in whole samples and 65536ths, moved on once a frame by the samples a
          # frame reads (Console::SampleClock.on_voices), read back by its hold at its end, or freed; and its
          # shape's level, stepped once a frame by Audio::Envelope#step (rt_recordings_shapes). The chip's own
          # voice plays the same samples at the same rate, its loudness set from the level each frame.
          #
          # Each play the game writes, and each recorded note of a song, is a row of the table
          # "recording_plays" (Lowering::Sound): where its recording starts in sound memory, the voice's
          # pitch and loudness, the recording's length, how far back it reads at its end (nought for one
          # played once), how far it moves a frame, the number of its entry in the sound log ([:sample,
          # name], or NOT_LOGGED for a song's note), which recording it is, and its shape packed in a word
          # (Audio::Envelope#packed; nought for none).
          #
          # A SONG'S RECORDED PART plays its notes in the same places (rt_recordings_note), taking one by the
          # interpreter's rule (Reference::Mixer#start_music_note): the part's own, while it still sounds a
          # note with no shape; the first free; the quietest note falling away; or the place of the
          # lowest-ranked sound ranked below the song — the game's own first, of those one that plays once
          # before one that loops, and the oldest. With none, the note is not played. A rest gives the part's
          # place back (rt_recordings_note_release), and so does the tune stopping
          # (rt_recordings_release_music); a note with a shape is not stopped there but falls away.
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
            ENVELOPE = 36
            ROW_BYTES = 40
            NOT_LOGGED = 0xFFFF

            # A place's state, PLACE_BYTES apart, a word each: which recording (its number plus one, nought
            # when the place is free), how far into it (whole samples and 65536ths), and the play's length,
            # read-back, how far a frame and log entry, copied from its row; whose it is (nought for the
            # game's own, a song's part's number for a song's — its place among the song's recorded parts,
            # one up — and for a sound effect's the same in the low byte under the effect's number, one up,
            # from EFFECT_OWNER); the rank it holds the place at (the song's or effect's rank's place one up,
            # nought for the game's own, which ranks below every one); its TICKET (LOOPS set for one of the
            # game's own that loops, and how many the game had started before it), which orders who gives way
            # first; its shape, its level (out of Audio::Envelope::FULL) and which part of the shape it is in;
            # and the loudness its voice has at full.
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
            RANK = 36
            TICKET = 40
            PLACE_ENVELOPE = 44
            LEVEL = 48
            PHASE = 52
            LOUD = 56
            PLACE_BYTES = 60
            LOOPS = 0x8000_0000
            EFFECT_OWNER = 0x100
            # Which part of its shape a note is in (Audio::Envelope), and DONE: fallen to nothing, its place
            # coming free on the frame after (Reference::Mixer::DONE).
            CLIMBING = 0
            HOLDING = 1
            FALLING = 2
            DONE = 3
            FULL = Audio::Envelope::FULL

            # ...and, for each of the last Frame::STEPS_KEPT passes, by the pass's number less its multiples of
            # STEPS_KEPT, each place's recording as its wait ended, a byte a place; and its level beside, in a
            # table of its own.
            KEPT_BY_PASS = "rt recordings kept by pass"
            LEVELS_BY_PASS = "rt recordings levels by pass"
            # WHAT COULD NOT BE PLAYED (Reference::Mixer#drops): how many plays and notes found every place
            # busy, and the most places songs and effects held at one of those moments.
            DROPS = "rt recordings drops"
            DROPS_MUSIC = "rt recordings drops music"
            TICKETS = "rt recordings tickets" # How many of its own sounds the game has started
            # The place a note last took, its offset, for the loudness the music volume gives it.
            TAKEN = "rt recordings taken"
            ALL = 0xFFFF # A stop that names no recording

            # WHERE A NOTE SITS BETWEEN THE SPEAKERS (Audio::Pan). Each voice of the sound chip has a volume
            # for the left speaker and one for the right, so a recorded note off the middle is heard there
            # exactly: each side's register is the voice's loudness times that side's share, out of
            # Audio::Pan::SHARE_FULL, to the nearest whole step.
            #
            # Kept in a game with a recorded note off the middle: a word a place, the left share in its low
            # byte and the right in the next, copied from the row's word of "recording_sides" (a word a
            # row, Audio::Pan.shares_word) as the place takes the row. A game with none writes the
            # loudness to both, as it always did.
            SIDES = "rt recordings sides"

            module_function

            def reserve(memory, sides: false)
              memory.reserve(SIDES, PLACES * 4) if sides
              [DROPS, DROPS_MUSIC, TICKETS, TAKEN].each { |name| memory.reserve(name, 4) }
              memory.reserve(PLACES_STATE, PLACES * PLACE_BYTES)
              memory.reserve(KEPT_BY_PASS, Frame::STEPS_KEPT * PLACES)
              memory.reserve(LEVELS_BY_PASS, Frame::STEPS_KEPT * PLACES)
            end

            def emit(asm, memory)
              at = ->(name) { Runtime.at(memory, name) }
              place = ->(field) { at.call(PLACES_STATE) + field }
              sides = memory.reserved?(SIDES)
              emit_play(asm, at, place)
              emit_take(asm, at, place, sides: sides)
              emit_note(asm, at, place)
              emit_glide(asm, at, place)
              emit_note_release(asm, at, place)
              emit_stop(asm, at, place)
              emit_frame(asm, at, place)
              emit_shapes(asm, at, place)
              emit_loudness(asm, at, place, sides: sides)
              emit_kept_for_pass(asm, at)
              emit_place_routines(asm, at, place)
            end

            # t9 = gp plus the place's offset, for a place at +offset+ (a register holding it): its fields
            # are then at(PLACES_STATE) + field from t9.
            def emit_place_at(asm, offset)
              asm.addu(:t9, offset, :gp)
            end

            # A walk over the places, s1 each one's offset, with t9 at it (#emit_place_at); the block's code for
            # each, given the label that goes on to the next.
            def each_place(asm, label)
              asm.move(:s1, :zero)
              asm.label("#{label}_place")
              emit_place_at(asm, :s1)
              yield "#{label}_next"
              asm.label("#{label}_next")
              asm.addiu(:s1, :s1, PLACE_BYTES)
              asm.sltiu(:t0, :s1, PLACES * PLACE_BYTES)
              asm.bne(:t0, :zero, "#{label}_place")
            end

            # s0 = the row numbered a0's address.
            def emit_row(asm)
              asm.li(:t0, ROW_BYTES)
              asm.multu(:a0, :t0)
              asm.mflo(:t0)
              asm.la(:s0, "recording_plays")
              asm.addu(:s0, :s0, :t0)
            end

            # rt_recordings_play(a0 = row): the play's entry logged, and the recording in the first free place
            # from its start (Reference::Mixer#start); with none free, the quietest note falling away; with
            # none of those, counted as dropped.
            def emit_play(asm, at, place)
              asm.label("rt_recordings_play")
              Music.enter(asm, %i[s0 s1])
              emit_row(asm)
              asm.lw(:a0, LOGGED, :s0)
              asm.jal("rt_sound_log")
              asm.jal("rt_recordings_free_place")
              asm.bne(:v0, :zero, "rt_recordings_play_found")
              asm.jal("rt_recordings_quietest")
              asm.bne(:v0, :zero, "rt_recordings_play_found")
              asm.jal("rt_recordings_drop")
              asm.b("rt_recordings_play_done")
              asm.label("rt_recordings_play_found")
              asm.addiu(:s1, :v0, -1)
              emit_place_at(asm, :s1)
              # The game's own, below every song, with the next ticket.
              asm.sw(:zero, place.call(OWNER), :t9)
              asm.sw(:zero, place.call(RANK), :t9)
              emit_count_up(asm, at, TICKETS)
              asm.lw(:t1, BACK, :s0)
              asm.beq(:t1, :zero, "rt_recordings_play_ticket")
              asm.lui(:t1, LOOPS >> 16)
              asm.or(:t0, :t0, :t1)
              asm.label("rt_recordings_play_ticket")
              asm.sw(:t0, place.call(TICKET), :t9)
              asm.jal("rt_recordings_take")
              asm.label("rt_recordings_play_done")
              Music.leave(asm, %i[s0 s1])
            end

            def emit_count_up(asm, at, name)
              asm.lw(:t0, at.call(name), :gp)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, at.call(name), :gp)
            end

            # rt_recordings_take (s0 = the row's address, s1 = the place's offset): the row's recording into
            # the place from its start, at full or at nothing to climb from by its shape
            # (Reference::Mixer#recording_fields); its voice told where the recording starts, its pitch and
            # loudness, and started at the frame boundary. TAKEN says which place.
            def emit_take(asm, at, place, sides: false)
              h = Console::PS1Hardware
              asm.label("rt_recordings_take")
              Music.enter(asm)
              emit_place_at(asm, :s1)
              asm.sw(:s1, at.call(TAKEN), :gp)
              asm.lw(:t0, NAME, :s0)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, place.call(HELD), :t9)
              asm.sw(:zero, place.call(POSITION), :t9)
              asm.sw(:zero, place.call(FRACTION), :t9)
              { LENGTH => PLACE_LENGTH, BACK => PLACE_BACK, ADVANCE => PLACE_ADVANCE, ADVANCE_FRACTION => PLACE_ADVANCE_FRACTION,
                LOGGED => PLACE_LOGGED, ENVELOPE => PLACE_ENVELOPE, VOLUME => LOUD }.each do |from, to|
                asm.lw(:t0, from, :s0)
                asm.sw(:t0, place.call(to), :t9)
              end
              emit_copy_row_sides(asm, at) if sides
              asm.sw(:zero, place.call(PHASE), :t9)
              asm.lw(:t0, ENVELOPE, :s0)
              asm.li(:t1, FULL)
              asm.bne(:t0, :zero, "rt_recordings_take_level")
              asm.sw(:t1, place.call(LEVEL), :t9)
              asm.b("rt_recordings_take_voice")
              asm.label("rt_recordings_take_level")
              asm.sw(:zero, place.call(LEVEL), :t9) # a shape climbs from nothing
              asm.label("rt_recordings_take_voice")
              emit_voice_number(asm, :a0)
              asm.sll(:t3, :a0, 4)
              { h::SPU_START => START, h::SPU_PITCH => PITCH }.each do |register, field|
                asm.addiu(:a0, :t3, register)
                asm.lw(:a1, field, :s0)
                asm.jal("rt_spu_write")
                emit_voice_number(asm, :t3)
                asm.sll(:t3, :t3, 4)
              end
              asm.jal("rt_recordings_volume")
              emit_voice_number(asm, :a0)
              asm.jal("rt_sound_key_on")
              Music.leave(asm)
            end

            # +into+ = the voice of the place at offset s1.
            def emit_voice_number(asm, into)
              asm.li(:t0, PLACE_BYTES)
              asm.divu(:s1, :t0)
              asm.mflo(into)
              asm.addiu(into, into, FIRST_VOICE)
            end

            # rt_recordings_note(a0 = row, a1 = owner, a2 = rank): a note of a song's or effect's recorded part,
            # the row's recording played in a place found by the interpreter's rule (the comment atop this
            # module). v0 = 1 when it found one, nought when the note is not played.
            def emit_note(asm, at, place)
              asm.label("rt_recordings_note")
              Music.enter(asm, %i[s0 s1 s2 s3])
              asm.move(:s2, :a1)
              asm.move(:s3, :a2)
              emit_row(asm)
              # The part's own place, still sounding its note — unless that note has a shape: then it is told
              # to fall away there, and this note takes another place.
              asm.move(:a0, :s2)
              asm.jal("rt_recordings_sounding")
              asm.beq(:v0, :zero, "rt_recordings_note_elsewhere")
              asm.addiu(:s1, :v0, -1)
              emit_place_at(asm, :s1)
              asm.lw(:t0, place.call(PLACE_ENVELOPE), :t9)
              asm.beq(:t0, :zero, "rt_recordings_note_found") # a plain note: taken over
              asm.li(:t0, FALLING)
              asm.sw(:t0, place.call(PHASE), :t9)
              asm.label("rt_recordings_note_elsewhere")
              asm.jal("rt_recordings_free_place")
              asm.bne(:v0, :zero, "rt_recordings_note_taking")
              asm.jal("rt_recordings_quietest")
              asm.bne(:v0, :zero, "rt_recordings_note_taking")
              asm.move(:a0, :s3)
              asm.jal("rt_recordings_lowest_below")
              asm.bne(:v0, :zero, "rt_recordings_note_taking")
              asm.jal("rt_recordings_drop")
              asm.b("rt_recordings_note_done") { asm.move(:v0, :zero) }
              asm.label("rt_recordings_note_taking")
              asm.addiu(:s1, :v0, -1)
              asm.label("rt_recordings_note_found")
              emit_place_at(asm, :s1)
              asm.sw(:s2, place.call(OWNER), :t9)
              asm.sw(:s3, place.call(RANK), :t9)
              asm.sw(:zero, place.call(TICKET), :t9)
              asm.jal("rt_recordings_take")
              asm.li(:v0, 1)
              asm.label("rt_recordings_note_done")
              Music.leave(asm, %i[s0 s1 s2 s3])
            end

            # rt_recordings_glide(a0 = row, a1 = owner): the note the owner's part sounds, if it has one, reads on
            # at the row's pitch (Reference::Mixer#glide_music_note): how far a frame takes it, and its voice's
            # pitch register, with no key on, so its shape goes on where it was. v0 = 1 when it had a note.
            def emit_glide(asm, at, place)
              h = Console::PS1Hardware
              asm.label("rt_recordings_glide")
              Music.enter(asm, %i[s0 s1])
              emit_row(asm)
              asm.move(:a0, :a1)
              asm.jal("rt_recordings_sounding")
              asm.beq(:v0, :zero, "rt_recordings_glide_done")
              asm.addiu(:s1, :v0, -1)
              asm.sw(:s1, at.call(TAKEN), :gp) # the place the music volume reaches
              emit_place_at(asm, :s1)
              { ADVANCE => PLACE_ADVANCE, ADVANCE_FRACTION => PLACE_ADVANCE_FRACTION }.each do |from, to|
                asm.lw(:t0, from, :s0)
                asm.sw(:t0, place.call(to), :t9)
              end
              emit_voice_number(asm, :a0)
              asm.sll(:a0, :a0, 4)
              asm.addiu(:a0, :a0, h::SPU_PITCH)
              asm.lw(:a1, PITCH, :s0)
              asm.jal("rt_spu_write")
              asm.li(:v0, 1)
              asm.label("rt_recordings_glide_done")
              Music.leave(asm, %i[s0 s1])
            end

            # rt_recordings_note_release(a0 = owner): the part's sounding note, if it has one, ended
            # (Reference::Mixer#release_music); v0 = 1 when it had one.
            # rt_recordings_release_music: every place a song's part holds and is not falling, ended so
            # (Reference::Mixer#release_all_music); a sound effect's are the effect's.
            # rt_recordings_end_note (s1 = a place's offset): a note with a shape falls away, one without stops,
            # its place free and its voice let go (Reference::Mixer#start_release!).
            def emit_note_release(asm, at, place)
              asm.label("rt_recordings_note_release")
              Music.enter(asm, %i[s1])
              asm.jal("rt_recordings_sounding")
              asm.beq(:v0, :zero, "rt_recordings_note_release_done")
              asm.addiu(:s1, :v0, -1)
              asm.jal("rt_recordings_end_note")
              asm.li(:v0, 1)
              asm.label("rt_recordings_note_release_done")
              Music.leave(asm, %i[s1])

              asm.label("rt_recordings_release_music")
              Music.enter(asm, %i[s1])
              each_place(asm, "rt_recordings_release_music") do |next_place|
                asm.lw(:t0, place.call(HELD), :t9)
                asm.beq(:t0, :zero, next_place)
                asm.lw(:t0, place.call(OWNER), :t9)
                asm.beq(:t0, :zero, next_place) # the game's own
                asm.sltiu(:t1, :t0, EFFECT_OWNER)
                asm.beq(:t1, :zero, next_place) # an effect's
                asm.lw(:t0, place.call(PHASE), :t9)
                asm.sltiu(:t1, :t0, FALLING)
                asm.beq(:t1, :zero, next_place) # falling already
                asm.jal("rt_recordings_end_note")
              end
              Music.leave(asm, %i[s1])

              asm.label("rt_recordings_end_note")
              emit_place_at(asm, :s1)
              asm.lw(:t0, place.call(PLACE_ENVELOPE), :t9)
              asm.beq(:t0, :zero, "rt_recordings_free")
              asm.li(:t0, FALLING)
              asm.jr(:ra) { asm.sw(:t0, place.call(PHASE), :t9) }

              # rt_recordings_free (s1 = a place's offset): the place free and its voice let go.
              asm.label("rt_recordings_free")
              emit_place_at(asm, :s1)
              asm.sw(:zero, place.call(HELD), :t9)
              emit_voice_number(asm, :a0)
              asm.j("rt_sound_key_off")
            end

            # rt_recordings_stop(a0 = a recording's number, or ALL; a1 = the log entry): every place of the
            # game's own holding that recording, or any, freed and its voice let go (Reference::Mixer#stop);
            # then the stop logged.
            def emit_stop(asm, _at, place)
              asm.label("rt_recordings_stop")
              Music.enter(asm, %i[s0 s1 s2])
              asm.move(:s0, :a0)
              asm.move(:s2, :a1)
              each_place(asm, "rt_recordings_stop") do |next_place|
                asm.lw(:t0, place.call(HELD), :t9)
                asm.beq(:t0, :zero, next_place)
                asm.lw(:t1, place.call(OWNER), :t9)
                asm.bne(:t1, :zero, next_place)
                asm.li(:t1, ALL)
                asm.beq(:s0, :t1, "rt_recordings_stop_it")
                asm.addiu(:t0, :t0, -1)
                asm.bne(:t0, :s0, next_place)
                asm.label("rt_recordings_stop_it")
                asm.jal("rt_recordings_free")
              end
              asm.move(:a0, :s2)
              asm.jal("rt_sound_log")
              Music.leave(asm, %i[s0 s1 s2])
            end

            # rt_recordings_frame: every place a frame on (Reference::Mixer#mix_voice): the fraction carried,
            # the whole samples added; past the end, a play once through is over and its place free, and one
            # that holds reads back by its hold as many times as it takes, the game's own logging each time
            # round.
            def emit_frame(asm, _at, place)
              asm.label("rt_recordings_frame")
              Music.enter(asm, %i[s1])
              each_place(asm, "rt_recordings_frame") do |next_place|
                asm.lw(:t0, place.call(HELD), :t9)
                asm.beq(:t0, :zero, next_place)
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
                asm.bne(:t2, :zero, next_place)
                asm.lw(:t2, place.call(PLACE_BACK), :t9)
                asm.bne(:t2, :zero, "rt_recordings_frame_round")
                asm.jal("rt_recordings_free") # once through: over
                asm.b(next_place)
                asm.label("rt_recordings_frame_round")
                asm.subu(:t0, :t0, :t2)
                asm.sw(:t0, place.call(POSITION), :t9)
                asm.lw(:t1, place.call(OWNER), :t9)
                asm.bne(:t1, :zero, "rt_recordings_frame_ends")
                asm.lw(:a0, place.call(PLACE_LOGGED), :t9)
                asm.jal("rt_sound_log")
                asm.b("rt_recordings_frame_ends")
              end
              Music.leave(asm, %i[s1])
            end

            # rt_recordings_shapes: one frame of every sounding note's shape (Reference::Mixer#step_envelopes,
            # Audio::Envelope#step): climbing by its attack to full, then down by its decay to its sustain level
            # and held there, or once ended falling by its release to nothing, where it is DONE, and its place
            # comes free on the frame after. Its voice's loudness follows its level.
            def emit_shapes(asm, _at, place)
              asm.label("rt_recordings_shapes")
              Music.enter(asm, %i[s1])
              each_place(asm, "rt_recordings_shapes") do |next_place|
                asm.lw(:t0, place.call(HELD), :t9)
                asm.beq(:t0, :zero, next_place)
                asm.lw(:t4, place.call(PLACE_ENVELOPE), :t9)
                asm.beq(:t4, :zero, next_place)
                asm.lw(:t1, place.call(PHASE), :t9)
                asm.li(:t2, DONE)
                asm.bne(:t1, :t2, "rt_recordings_shapes_step")
                asm.jal("rt_recordings_free")
                asm.b(next_place)
                asm.label("rt_recordings_shapes_step")
                asm.lw(:t0, place.call(LEVEL), :t9)
                asm.li(:t2, HOLDING)
                asm.beq(:t1, :t2, "rt_recordings_shapes_holding")
                asm.li(:t2, FALLING)
                asm.beq(:t1, :t2, "rt_recordings_shapes_falling")
                # Climbing: up by its attack, held at full and holding once it gets there.
                asm.andi(:t3, :t4, 0xFF)
                asm.addu(:t0, :t0, :t3)
                asm.sltiu(:t3, :t0, FULL)
                asm.bne(:t3, :zero, "rt_recordings_shapes_set")
                asm.li(:t0, FULL)
                asm.li(:t1, HOLDING)
                asm.b("rt_recordings_shapes_set")
                # Holding: down by its decay, no lower than its sustain level.
                asm.label("rt_recordings_shapes_holding")
                asm.srl(:t3, :t4, 16)
                asm.andi(:t3, :t3, 0xFF) # the sustain level
                asm.sltu(:t2, :t3, :t0)
                asm.beq(:t2, :zero, "rt_recordings_shapes_set") # at or under it: held
                asm.srl(:t2, :t4, 8)
                asm.andi(:t2, :t2, 0xFF)
                asm.multu(:t0, :t2)
                asm.mflo(:t0)
                asm.srl(:t0, :t0, Audio::Envelope::SCALE)
                asm.sltu(:t2, :t0, :t3)
                asm.beq(:t2, :zero, "rt_recordings_shapes_set")
                asm.b("rt_recordings_shapes_set") { asm.move(:t0, :t3) }
                # Falling: down by its release, DONE at nothing.
                asm.label("rt_recordings_shapes_falling")
                asm.srl(:t2, :t4, 24)
                asm.multu(:t0, :t2)
                asm.mflo(:t0)
                asm.srl(:t0, :t0, Audio::Envelope::SCALE)
                asm.bne(:t0, :zero, "rt_recordings_shapes_set")
                asm.li(:t1, DONE)
                asm.label("rt_recordings_shapes_set")
                asm.sw(:t0, place.call(LEVEL), :t9)
                asm.sw(:t1, place.call(PHASE), :t9)
                asm.jal("rt_recordings_volume")
              end
              Music.leave(asm, %i[s1])
            end

            # rt_recordings_volume (s1 = a place's offset): its voice's volume registers at its loudness, scaled
            # by its level the way the interpreter's mix scales a note's (Reference::Mixer#slide_gain: the
            # level's own top bit added back, so full is the whole loudness).
            # rt_recordings_loud(a0 = a voice's loudness at full): the place a note last took (TAKEN) sounding
            # at it, as the music volume sets (Reference::Player#song_loudness).
            def emit_loudness(asm, at, place, sides: false)
              h = Console::PS1Hardware
              asm.label("rt_recordings_loud")
              Music.enter(asm, %i[s1])
              asm.lw(:s1, at.call(TAKEN), :gp)
              emit_place_at(asm, :s1)
              asm.sw(:a0, place.call(LOUD), :t9)
              asm.jal("rt_recordings_volume")
              Music.leave(asm, %i[s1])

              asm.label("rt_recordings_volume")
              Music.enter(asm, %i[s2])
              emit_place_at(asm, :s1)
              asm.lw(:t0, place.call(LEVEL), :t9)
              asm.srl(:t1, :t0, 7)
              asm.addu(:t0, :t0, :t1)
              asm.lw(:t1, place.call(LOUD), :t9)
              asm.multu(:t0, :t1)
              asm.mflo(:s2)
              asm.srl(:s2, :s2, Audio::Envelope::SCALE)
              [h::SPU_VOLUME_LEFT, h::SPU_VOLUME_RIGHT].each_with_index do |register, side|
                emit_voice_number(asm, :t3)
                asm.sll(:t3, :t3, 4)
                asm.addiu(:a0, :t3, register)
                sides ? emit_side_loudness(asm, at, side) : asm.move(:a1, :s2)
                asm.jal("rt_spu_write")
              end
              Music.leave(asm, %i[s2])
            end

            # The row at s0's word of "recording_sides" into the place at offset s1's word of SIDES.
            def emit_copy_row_sides(asm, at)
              asm.la(:t0, "recording_plays")
              asm.subu(:t0, :s0, :t0)
              asm.li(:t1, ROW_BYTES)
              asm.divu(:t0, :t1)
              asm.mflo(:t0)
              asm.sll(:t0, :t0, 2)
              asm.la(:t1, "recording_sides")
              asm.addu(:t0, :t0, :t1)
              asm.lw(:t0, 0, :t0)
              emit_place_sides_at(asm, :t1)
              asm.sw(:t0, at.call(SIDES), :t1)
            end

            # +into+ = gp plus the place at offset s1's word of SIDES, less where SIDES is.
            def emit_place_sides_at(asm, into)
              asm.li(into, PLACE_BYTES)
              asm.divu(:s1, into)
              asm.mflo(into)
              asm.sll(into, into, 2)
              asm.addu(into, into, :gp)
            end

            # a1 = the loudness in s2 as side +side+ (0 the left, 1 the right) of the place at offset s1
            # hears it (SIDES), to the nearest whole step. Leaves a0 as it is.
            def emit_side_loudness(asm, at, side)
              emit_place_sides_at(asm, :t1)
              asm.lw(:t0, at.call(SIDES), :t1)
              asm.srl(:t0, :t0, 8) if side == 1
              asm.andi(:t0, :t0, 0xFF)
              asm.multu(:s2, :t0)
              asm.mflo(:a1)
              asm.addiu(:a1, :a1, Audio::Pan::SHARE_ROUNDING)
              asm.srl(:a1, :a1, Audio::Pan::SHARE_SHIFT)
            end

            # rt_recordings_kept_for_pass: which recording each place holds (the low byte of its HELD) and its
            # level copied for the pass whose wait is ending, for a reader of the run to hold to the
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
                asm.lw(:t1, at.call(PLACES_STATE) + (place * PLACE_BYTES) + LEVEL, :gp)
                asm.sb(:t1, at.call(LEVELS_BY_PASS) + place, :t0)
              end
              asm.jr(:ra)
            end

            # THE PLACES A NOTE CAN BE GIVEN, each answering v0 = the place's offset one up, nought for none:
            #
            # rt_recordings_free_place: the first free.
            # rt_recordings_quietest: the quietest note of a song or an effect falling away, the first of two
            # as quiet (Reference::Mixer#quietest_releasing_slot).
            # rt_recordings_lowest_below(a0 = rank): the lowest-ranked sound ranked below it, the game's own
            # first, by rank and then ticket, the first of two alike (Reference::Mixer#lowest_ranked_slot_below).
            # rt_recordings_sounding(a0 = owner): the place the owner's part sounds its note in now, not one of
            # its notes falling away (Reference::Mixer#sounding_slot).
            #
            # rt_recordings_drop: a play or a note that found every place busy, counted, with the most of them
            # songs and effects held at such a moment (Reference::Mixer#record_drop).
            def emit_place_routines(asm, at, place)
              asm.label("rt_recordings_free_place")
              Music.enter(asm, %i[s1])
              asm.move(:v0, :zero)
              each_place(asm, "rt_recordings_free_place") do |next_place|
                asm.lw(:t0, place.call(HELD), :t9)
                asm.bne(:t0, :zero, next_place)
                asm.b("rt_recordings_free_place_done") { asm.addiu(:v0, :s1, 1) }
              end
              asm.label("rt_recordings_free_place_done")
              Music.leave(asm, %i[s1])

              asm.label("rt_recordings_quietest")
              Music.enter(asm, %i[s1])
              asm.move(:v0, :zero)
              asm.li(:t5, FULL + 1) # the quietest level yet
              each_place(asm, "rt_recordings_quietest") do |next_place|
                emit_skip_unless_releasing(asm, place, next_place)
                asm.lw(:t0, place.call(LEVEL), :t9)
                asm.sltu(:t1, :t0, :t5)
                asm.beq(:t1, :zero, next_place)
                asm.move(:t5, :t0)
                asm.addiu(:v0, :s1, 1)
              end
              Music.leave(asm, %i[s1])

              asm.label("rt_recordings_lowest_below")
              Music.enter(asm, %i[s1])
              asm.move(:v0, :zero)
              each_place(asm, "rt_recordings_lowest_below") do |next_place|
                asm.lw(:t0, place.call(HELD), :t9)
                asm.beq(:t0, :zero, next_place)
                asm.lw(:t0, place.call(RANK), :t9)
                asm.sltu(:t1, :t0, :a0)
                asm.beq(:t1, :zero, next_place) # not below the note
                asm.lw(:t2, place.call(TICKET), :t9)
                asm.beq(:v0, :zero, "rt_recordings_lowest_below_best")
                asm.sltu(:t1, :t0, :t6)
                asm.bne(:t1, :zero, "rt_recordings_lowest_below_best") # ranked lower than the best yet
                asm.bne(:t0, :t6, next_place)
                asm.sltu(:t1, :t2, :t7)
                asm.beq(:t1, :zero, next_place) # no older, or the same: the first stays
                asm.label("rt_recordings_lowest_below_best")
                asm.move(:t6, :t0)
                asm.move(:t7, :t2)
                asm.addiu(:v0, :s1, 1)
              end
              Music.leave(asm, %i[s1])

              asm.label("rt_recordings_sounding")
              Music.enter(asm, %i[s1])
              asm.move(:v0, :zero)
              each_place(asm, "rt_recordings_sounding") do |next_place|
                asm.lw(:t0, place.call(HELD), :t9)
                asm.beq(:t0, :zero, next_place)
                asm.lw(:t0, place.call(OWNER), :t9)
                asm.bne(:t0, :a0, next_place)
                asm.lw(:t0, place.call(PHASE), :t9)
                asm.sltiu(:t1, :t0, FALLING)
                asm.beq(:t1, :zero, next_place)
                asm.b("rt_recordings_sounding_done") { asm.addiu(:v0, :s1, 1) }
              end
              asm.label("rt_recordings_sounding_done")
              Music.leave(asm, %i[s1])

              asm.label("rt_recordings_drop")
              Music.enter(asm, %i[s1])
              emit_count_up(asm, at, DROPS)
              asm.move(:t5, :zero) # the places songs and effects hold
              each_place(asm, "rt_recordings_drop") do |next_place|
                asm.lw(:t0, place.call(HELD), :t9)
                asm.beq(:t0, :zero, next_place)
                asm.lw(:t0, place.call(OWNER), :t9)
                asm.beq(:t0, :zero, next_place)
                asm.addiu(:t5, :t5, 1)
              end
              asm.lw(:t0, at.call(DROPS_MUSIC), :gp)
              asm.sltu(:t1, :t0, :t5)
              asm.beq(:t1, :zero, "rt_recordings_drop_done")
              asm.sw(:t5, at.call(DROPS_MUSIC), :gp)
              asm.label("rt_recordings_drop_done")
              Music.leave(asm, %i[s1])
            end

            # On to +next_place+ unless the place at t9 is a note of a song or an effect falling away, or just
            # fallen (Reference::Mixer#releasing?).
            def emit_skip_unless_releasing(asm, place, next_place)
              asm.lw(:t0, place.call(HELD), :t9)
              asm.beq(:t0, :zero, next_place)
              asm.lw(:t0, place.call(OWNER), :t9)
              asm.beq(:t0, :zero, next_place)
              asm.lw(:t0, place.call(PHASE), :t9)
              asm.sltiu(:t1, :t0, FALLING)
              asm.bne(:t1, :zero, next_place)
            end
          end
        end
      end
    end
  end
end
