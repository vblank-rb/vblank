# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE MUSIC PLAYER. The game only names a tune (rt_music_play) or stops it (rt_music_stop),
          # and the player walks each part's notes (SNES::Music) a frame at a time, handing each note's
          # group of commands to the sound unit as its frame comes.
          #
          # WHERE IT RUNS. The Advance and the Color play their music from the screen's interrupt.
          # Here that interrupt would come between any two of the game's own writes to the sound
          # unit, and the mailboxes take one command at a time: a note sent from the interrupt in
          # the middle of a beep's write would spoil both. So the player runs where a pass's wait
          # ends (Sound's rt_sound_frame), once for every frame the pass took — which is also where
          # the interpreter moves its music on (Reference#advance_frame), after the pass and by every
          # frame it took. A game that keeps up hears each note on its own frame; one that falls
          # behind hears the frames it missed at once, as the interpreter logs them.
          #
          # What it does each frame is Reference::Player#advance's steps, in its order: catch up
          # with the tune the game names (a different one, or a stop, quiets the old and starts the
          # new from its first frame; one that played once and ended stays quiet), then each part's
          # next note if its frame has come, then the frame on, round to the tune's loop frame at its
          # end.
          module Music
            NAMED = "rt music named" # the tune the game named last (SNES::Music#number), nought for none
            PLAYING = "rt music playing" # ...and the tune playing
            STOPS = "rt music stops" # how many times the game said stop_music...
            STOPS_SEEN = "rt music stops seen" # ...and how many of those the player has acted on
            ENDED = "rt music ended" # a tune that played once and reached its end
            TUNE_HELD = "rt music tune held" # 1 while the game holds the tune, in a game that says so
            FRAME = "rt music frame" # how far into the tune, in frames
            AGAIN = "rt music again" # 1 once the tune has come round
            SONG = "rt music song" # where the playing tune's record is in the table
            CURSORS = "rt music cursors" # each part's next note
            NEXT_NOTE_FRAME = "rt music next note frame" # the frame the next of those is due
            NO_NOTE_DUE = 0xFFFF # ...when no part has a note left this time round
            PART = "rt music part" # the part being played...
            PARTS_IN = "rt music parts in" # ...of how many
            COUNT = "rt music count" # how many notes the part has this time round...
            LIST = "rt music list" # ...and where they are
            ENTRY = "rt music entry" # where the part being played's entry is in the table
            NOTE = "rt music note" # ...and its note being played
            # THE MUSIC VOLUME, in a game that sets it (SNES::Music#follows_level?): the level the
            # notes sounding were set at, kept with its FULL_LEVEL bit turned over so the nought
            # memory starts at says full; each part's note's volume as written, while its voice holds
            # it (nought for a rest, or none); a note's loudness at the level, worked out; the level
            # itself while a loudness is worked out; and where the part's loudness groups are while
            # one is found.
            LEVEL_SET = "rt music level set"
            HELD = "rt music held"
            LOUDNESS = "rt music loudness"
            LEVEL_NOW = "rt music level now"
            LOUDNESS_TABLE = "rt music loudness table"
            # THE PARTS WHOSE VOICES HOLD A NOTE, in the order they first took one since the tune
            # started (Reference::Player's @sounding, a Hash kept in the order its keys came): each
            # part's number, two bytes apart, and where the list ends, and whether each part is in it.
            # A sound effect taking a part's voice takes the part out, and the part's next note puts
            # it back at the end, so the order is the parts' only until an effect plays.
            HELD_ORDER = "rt music held order"
            HELD_END = "rt music held end"
            HELD_IN = "rt music held in"
            HELD_WALK = "rt music held walk"
            CHANNEL_FOUND = "rt music channel found"
            # A NOTE THAT WOBBLES ITS PITCH (SNES::Music#wobble_record), in a game with one. The sound
            # chip has no wobble, so the player does it a frame at a time, as the interpreter counts
            # it (IR::Tunes::Wobble): each console voice's record, nought for a voice holding still;
            # the frames still to wait; the frames its swing has left; and whether it is above the
            # note's pitch. WOBBLE_AT is the voice being stepped.
            WOBBLE_RECORD = "rt music wobble record"
            WOBBLE_WAIT = "rt music wobble wait"
            WOBBLE_LEFT = "rt music wobble left"
            WOBBLE_RISING = "rt music wobble rising"
            WOBBLE_AT = "rt music wobble at"
            # A SQUARE NOTE THAT STEPS ITS SHAPES (SNES::Music#shape_record), in a game with one: each
            # console voice's record, nought for a voice holding its shape, and its note's frame, kept
            # in 0..7 so nought is the note's first frame alone.
            SHAPE_RECORD = "rt music shape record"
            SHAPE_FRAME = "rt music shape frame"
            # A NOTE THAT SWELLS UNDER THE MUSIC VOLUME (SNES::Music#swell_record), in a game with one:
            # each console voice's record, nought for no such note, and its count as the
            # interpreter keeps it (IR::Tunes::Swell). SWELL_AT is the voice being stepped, and the
            # rest are what stepping it works with.
            SWELL_RECORD = "rt music swell record"
            SWELL_VOLUME = "rt music swell volume"
            SWELL_COUNTED = "rt music swell counted"
            SWELL_RISING = "rt music swell rising"
            SWELL_AT = "rt music swell at"
            SWELL_CEILING = "rt music swell ceiling"
            SWELL_NEEDS = "rt music swell needs"
            SWELL_GROUPS = "rt music swell groups"
            # A NOTE THAT SLIDES (SNES::Music#slide_record), in a game with one: where in its record
            # the next frame is, nought when no note slides. Only one voice slides, so one word.
            SLIDE_CURSOR = "rt music slide cursor"
            # Which of a part's lists of loudness groups a strike reads, in a game with a note from one
            # speaker and a music volume (SNES::Music#loudness_group).
            LOUDNESS_LIST = "rt music loudness list"

            module_function

            # +follows_level+ for a game that sets the music volume (SNES::Music.follows_level?);
            # +effects+ how many sound effects the game has (Effects).
            def reserve(memory, follows_level: false, effects: 0, holds: false, wobbles: false, steps_shapes: false, swells: false,
                        slides: false, sides: false)
              memory.reserve(TUNE_HELD, 2) if holds
              memory.reserve(LOUDNESS_LIST, 2) if sides
              memory.reserve(SLIDE_CURSOR, 2) if slides
              if swells
                [SWELL_RECORD, SWELL_VOLUME, SWELL_COUNTED, SWELL_RISING].each { |name| memory.reserve(name, SNES::Music::CONSOLE_PARTS * 2) }
                [SWELL_AT, SWELL_CEILING, SWELL_NEEDS, SWELL_GROUPS].each { |name| memory.reserve(name, 2) }
              end
              if steps_shapes
                [SHAPE_RECORD, SHAPE_FRAME].each { |name| memory.reserve(name, SNES::Music::CONSOLE_PARTS * 2) }
                memory.reserve(WOBBLE_AT, 2) unless wobbles
              end
              if wobbles
                [WOBBLE_RECORD, WOBBLE_WAIT, WOBBLE_LEFT, WOBBLE_RISING].each { |name| memory.reserve(name, SNES::Music::CONSOLE_PARTS * 2) }
                memory.reserve(WOBBLE_AT, 2)
              end
              [NAMED, PLAYING, STOPS, STOPS_SEEN, ENDED, FRAME, NEXT_NOTE_FRAME, AGAIN, SONG, PART, PARTS_IN, COUNT, LIST,
               ENTRY, NOTE].each { |name| memory.reserve(name, 2) }
              memory.reserve(CURSORS, SNES::Music::PARTS * 2)
              Effects.reserve(memory, effects) if effects.positive?
              return unless follows_level

              [LEVEL_SET, LOUDNESS, LEVEL_NOW, LOUDNESS_TABLE, HELD_END, HELD_WALK, CHANNEL_FOUND].each { |name| memory.reserve(name, 2) }
              [HELD, HELD_IN].each { |name| memory.reserve(name, SNES::Music::PARTS * 2) }
              # ...and a word past the last part, which taking a part out of a full list reads as it
              # moves the rest down (rt_music_unhold).
              memory.reserve(HELD_ORDER, (SNES::Music::PARTS + 1) * 2)
            end

            # +level_at+ is where a game that sets its music volume keeps it (IR::Tunes::LEVEL), or nil;
            # +effects+ how many sound effects the game has.
            def emit(asm, memory, level_at: nil, effects: 0, recorded: false)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              sharing = effects.positive?
              emit_game_side(asm, at)
              emit_tune_hold(asm, at) if holds?(memory)
              emit_frames(asm, at, sharing, memory)
              emit_wobbles(asm, at, memory) if wobbles?(memory)
              emit_shapes(asm, at, memory) if steps_shapes?(memory)
              emit_swells(asm, at, memory) if swells?(memory)
              emit_slides(asm, at) if slides?(memory)
              emit_switch(asm, at, memory, level_at, sharing, recorded)
              emit_song_frame(asm, at, memory, level_at, sharing, recorded)
              emit_level(asm, at, memory, level_at, recorded) if level_at
              Effects.emit(asm, memory, effects, level_at, recorded: recorded) if sharing
              emit_group(asm)
            end

            # Whether the game holds its music (TUNE_HELD).
            def holds?(memory) = memory.reserved?(TUNE_HELD)

            # Whether the game has a note that wobbles (WOBBLE_RECORD).
            def wobbles?(memory) = memory.reserved?(WOBBLE_RECORD)

            # Whether the game has a note that steps its shapes (SHAPE_RECORD).
            def steps_shapes?(memory) = memory.reserved?(SHAPE_RECORD)

            # Whether the game has a note that swells under the music volume (SWELL_RECORD).
            def swells?(memory) = memory.reserved?(SWELL_RECORD)

            # Whether the game has a note that slides (SLIDE_CURSOR).
            def slides?(memory) = memory.reserved?(SLIDE_CURSOR)

            # Whether the game has sound effects, which share the voices (Effects).
            def shares_voices?(memory) = memory.reserved?(Effects::HOLDERS)

            # Whether a note from one speaker stays there as the music volume moves (LOUDNESS_LIST).
            def sides?(memory) = memory.reserved?(LOUDNESS_LIST)

            # The note at ENTRY and NOTE taken up by what changes as it plays, a tune's or an effect's.
            def emit_note_changes(asm, memory)
              asm.jsr(asm.abs("rt_music_note_wobble")) if wobbles?(memory)
              asm.jsr(asm.abs("rt_music_note_shapes")) if steps_shapes?(memory)
              asm.jsr(asm.abs("rt_music_note_swell")) if swells?(memory)
              asm.jsr(asm.abs("rt_music_note_slide")) if slides?(memory)
            end

            # The voice Y says stopped wobbling, stepping and sliding, A left nought, as an effect's
            # end stops it (Reference::Player#finish_effect). +channel+ is where its channel is.
            def emit_voice_stops_changing(asm, memory, channel)
              asm.lda(0)
              asm.sta(asm.abs_y(memory[WOBBLE_RECORD])) if wobbles?(memory)
              asm.sta(asm.abs_y(memory[SHAPE_RECORD])) if steps_shapes?(memory)
              return unless slides?(memory)

              asm.lda(channel)
              asm.cmp(SNES::Music::SLIDING_CHANNEL)
              asm.bne("rt_voice_stops_changing_done")
              asm.stz(asm.abs(memory[SLIDE_CURSOR]))
              asm.label("rt_voice_stops_changing_done")
            end

            # A HELD TUNE'S NOTES HOLD STILL, and an effect's move on (Reference::Player#held_still?).
            # With no effects the whole walk stops at the top; with them each voice is asked. Inline,
            # Y the voice: on to +next+ when it holds still. A wide branch, since Y's walk can be long.
            def emit_skip_voice_held_still(asm, at, memory, next_voice, label)
              return unless holds?(memory) && shares_voices?(memory)

              asm.lda(at.call(TUNE_HELD))
              asm.beq(label)
              asm.jsr(asm.abs("rt_sfx_effect_holds"))
              asm.branch_long(:beq, next_voice)
              asm.ldy(at.call(WOBBLE_AT))
              asm.label(label)
            end

            # A stopping tune's voices stop changing, but one a sound effect holds, which goes on as
            # the effect's (Reference::Player#silence_song).
            def emit_tune_voices_stop_changing(asm, at, memory)
              records = [(WOBBLE_RECORD if wobbles?(memory)), (SHAPE_RECORD if steps_shapes?(memory)),
                         (SWELL_RECORD if swells?(memory))].compact
              unless shares_voices?(memory)
                SNES::Music::CONSOLE_PARTS.times { |voice| records.each { |name| asm.stz(asm.abs(memory[name], voice * 2)) } }
                asm.stz(at.call(SLIDE_CURSOR)) if slides?(memory)
                return
              end

              SNES::Music::CONSOLE_PARTS.times do |voice|
                kept = "rt_music_quiet_changes_#{voice}"
                asm.ldy(voice * 2)
                asm.jsr(asm.abs("rt_sfx_effect_holds"))
                asm.bne(kept)
                records.each { |name| asm.stz(asm.abs(memory[name], voice * 2)) }
                asm.stz(at.call(SLIDE_CURSOR)) if slides?(memory) && voice.zero?
                asm.label(kept)
              end
            end

            # rt_music_slides: the sliding note's frame played from its record, every frame the
            # player runs, since on the Advance the voice moves by itself even under `hold_music`.
            # rt_music_note_slide: the record of the note at NOTE taken up, or nothing, when the
            # part at ENTRY plays on the one voice that slides.
            def emit_slides(asm, at)
              m = SNES::Music
              asm.label("rt_music_slides")
              asm.ldx(at.call(SLIDE_CURSOR))
              asm.beq("rt_music_slides_done")
              asm.lda(asm.long_x("music_data"))
              asm.inx
              asm.inx
              asm.stx(at.call(SLIDE_CURSOR))
              asm.cmp(m::SLIDE_END)
              asm.beq("rt_music_slides_over")
              asm.tax
              asm.beq("rt_music_slides_done")
              asm.jmp(asm.abs("rt_sound_group"))
              asm.label("rt_music_slides_over")
              asm.stz(at.call(SLIDE_CURSOR))
              asm.label("rt_music_slides_done")
              asm.rts

              asm.label("rt_music_note_slide")
              asm.ldx(at.call(ENTRY))
              asm.lda(asm.long_x("music_data", m::CHANNEL))
              asm.cmp(m::SLIDING_CHANNEL)
              asm.bne("rt_music_note_slide_done")
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_VOLUME))
              asm.bit(m::SLIDES)
              asm.bne("rt_music_note_slides")
              asm.stz(at.call(SLIDE_CURSOR))
              asm.rts
              asm.label("rt_music_note_slides")
              asm.lda(asm.long_x("music_data", m::NOTE_WOBBLE))
              asm.sta(at.call(SLIDE_CURSOR))
              asm.label("rt_music_note_slide_done")
              asm.rts
            end

            # rt_music_swells: every swelling note held under the music volume, the voices in order,
            # before the wobbles (Reference::Player#step_swells): struck where IR::Tunes::Swell#held_under
            # says, then counted on a frame as Swell#stepped does. The sound chip does the climbing; this
            # only knows how far it has got.
            def emit_swells(asm, at, memory)
              m = SNES::Music
              loudest = IR::Tunes::LOUDEST
              volume = asm.abs_y(memory[SWELL_VOLUME])
              counted = asm.abs_y(memory[SWELL_COUNTED])
              rising = asm.abs_y(memory[SWELL_RISING])
              record = asm.abs_y(memory[SWELL_RECORD])
              asm.label("rt_music_swells")
              asm.lda(loudest)
              asm.jsr(asm.abs("rt_music_scaled"))
              asm.sta(at.call(SWELL_CEILING))
              asm.stz(at.call(SWELL_AT))
              asm.label("rt_music_swell_voice")
              asm.ldy(at.call(SWELL_AT))
              asm.lda(record)
              asm.branch_long(:beq, "rt_music_swell_next")
              asm.lda(rising)
              asm.beq("rt_music_swell_kept")
              # Climbing: held once it reaches the ceiling, unless that is full, where the voice stops by itself.
              asm.lda(at.call(SWELL_CEILING))
              asm.cmp(loudest)
              asm.bcs("rt_music_swell_count")
              asm.lda(volume)
              asm.cmp(at.call(SWELL_CEILING))
              asm.bcc("rt_music_swell_count")
              asm.bra("rt_music_swell_hold")
              # Held: struck lower if the ceiling came down, and let climb if it went up.
              asm.label("rt_music_swell_kept")
              asm.lda(volume)
              asm.cmp(at.call(SWELL_CEILING))
              asm.branch_long(:beq, "rt_music_swell_next")
              asm.bcs("rt_music_swell_hold")
              asm.lda(0)
              asm.sta(counted)
              asm.lda(1)
              asm.sta(rising)
              asm.lda(m::SWELL_ONWARDS)
              asm.bra("rt_music_swell_strike")
              asm.label("rt_music_swell_hold")
              asm.lda(at.call(SWELL_CEILING))
              asm.sta(volume)
              asm.lda(0)
              asm.sta(counted)
              asm.sta(rising)
              asm.lda(m::SWELL_HOLDS)
              asm.label("rt_music_swell_strike") # A = which list of the record's
              asm.clc
              asm.adc(record)
              asm.sta(at.call(SWELL_GROUPS))
              asm.lda(volume)
              asm.asl
              asm.clc
              asm.adc(at.call(SWELL_GROUPS))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.ldy(at.call(SWELL_AT))
              asm.label("rt_music_swell_count")
              asm.lda(rising)
              asm.beq("rt_music_swell_next")
              asm.lda(volume)
              asm.cmp(loudest)
              asm.bcs("rt_music_swell_next")
              asm.lda(record)
              asm.tax
              asm.lda(asm.long_x("music_data", m::SWELL_STEP))
              asm.sta(at.call(SWELL_NEEDS))
              asm.lda(counted)
              asm.clc
              asm.adc(IR::Tunes::COUNTED_A_FRAME)
              asm.sta(counted)
              asm.label("rt_music_swell_climb")
              asm.lda(counted)
              asm.cmp(at.call(SWELL_NEEDS))
              asm.bcc("rt_music_swell_next")
              asm.sec
              asm.sbc(at.call(SWELL_NEEDS))
              asm.sta(counted)
              asm.lda(volume)
              asm.inc
              asm.sta(volume)
              asm.cmp(loudest)
              asm.bcc("rt_music_swell_climb")
              asm.label("rt_music_swell_next")
              asm.inc(at.call(SWELL_AT))
              asm.inc(at.call(SWELL_AT))
              asm.lda(at.call(SWELL_AT))
              asm.cmp(SNES::Music::CONSOLE_PARTS * 2)
              asm.branch_long(:bne, "rt_music_swell_voice")
              asm.rts

              # rt_music_stop_swell(channel): the game's own sound took the voice
              # (Reference::Player#game_sound_on).
              asm.label("rt_music_stop_swell")
              asm.lda(asm.direct(Sound::R0))
              asm.dec
              asm.asl
              asm.tay
              asm.lda(0)
              asm.sta(record)
              asm.rtl

              # rt_music_note_swell: the voice of the part at ENTRY counting as the note at NOTE says,
              # from its loudness at the level, or holding no swell (Reference::Player#hold_swell_under_level).
              asm.label("rt_music_note_swell")
              asm.ldx(at.call(ENTRY))
              asm.lda(asm.long_x("music_data", m::CHANNEL))
              asm.dec
              asm.asl
              asm.tay
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_SWELL))
              asm.sta(record)
              asm.beq("rt_music_note_swell_done")
              asm.lda(asm.long_x("music_data", m::NOTE_VOLUME))
              asm.bit(m::SLIDES)
              asm.beq("rt_music_note_swell_counts")
              # A note that slides is left to climb: striking it again would start its slide over.
              asm.lda(0)
              asm.sta(record)
              asm.rts
              asm.label("rt_music_note_swell_counts")
              asm.and_a(m::RINGS_ALONE - 1)
              asm.jsr(asm.abs("rt_music_scaled"))
              asm.sta(volume)
              asm.lda(0)
              asm.sta(counted)
              asm.lda(1)
              asm.sta(rising)
              asm.label("rt_music_note_swell_done")
              asm.rts
            end

            # rt_music_shapes: every square note that steps its shapes given the shape of the frame it
            # is on, the voices in order, after the wobbles (Reference::Player#step_shapes). The
            # record holds a group for each of a note's four frames, nought where the shape stays.
            def emit_shapes(asm, at, memory)
              m = SNES::Music
              asm.label("rt_music_shapes")
              if holds?(memory) && !shares_voices?(memory)
                asm.lda(at.call(TUNE_HELD))
                asm.beq("rt_music_shapes_go")
                asm.rts
                asm.label("rt_music_shapes_go")
              end
              asm.stz(at.call(WOBBLE_AT))
              asm.label("rt_music_shapes_voice")
              asm.ldy(at.call(WOBBLE_AT))
              asm.lda(asm.abs_y(memory[SHAPE_RECORD]))
              asm.branch_long(:beq, "rt_music_shapes_next")
              emit_skip_voice_held_still(asm, at, memory, "rt_music_shapes_next", "rt_music_shapes_step")
              asm.lda(asm.abs_y(memory[SHAPE_FRAME]))
              asm.beq("rt_music_shapes_on") # a note's first frame is its head's
              asm.and_a(3)
              asm.asl
              asm.clc
              asm.adc(asm.abs_y(memory[SHAPE_RECORD]))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.beq("rt_music_shapes_on")
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.ldy(at.call(WOBBLE_AT))
              asm.label("rt_music_shapes_on")
              asm.lda(asm.abs_y(memory[SHAPE_FRAME]))
              asm.inc
              asm.cmp(8)
              asm.bcc("rt_music_shapes_kept")
              asm.lda(4)
              asm.label("rt_music_shapes_kept")
              asm.sta(asm.abs_y(memory[SHAPE_FRAME]))
              asm.label("rt_music_shapes_next")
              asm.inc(at.call(WOBBLE_AT))
              asm.inc(at.call(WOBBLE_AT))
              asm.lda(at.call(WOBBLE_AT))
              asm.cmp(m::CONSOLE_PARTS * 2)
              asm.bne("rt_music_shapes_voice")
              asm.rts

              # rt_music_stop_shapes(channel): the game's own sound took the voice
              # (Reference::Player#game_sound_on).
              asm.label("rt_music_stop_shapes")
              asm.lda(asm.direct(Sound::R0))
              asm.dec
              asm.asl
              asm.tay
              asm.lda(0)
              asm.sta(asm.abs_y(memory[SHAPE_RECORD]))
              asm.rtl

              # rt_music_note_shapes: the voice of the part at ENTRY stepping as the note at NOTE
              # says, or holding its shape (Reference::Player#set_voice).
              asm.label("rt_music_note_shapes")
              asm.ldx(at.call(ENTRY))
              asm.lda(asm.long_x("music_data", m::CHANNEL))
              asm.dec
              asm.asl
              asm.tay
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_SHAPES))
              asm.sta(asm.abs_y(memory[SHAPE_RECORD]))
              asm.lda(0)
              asm.sta(asm.abs_y(memory[SHAPE_FRAME]))
              asm.rts
            end

            # rt_music_wobbles: every wobbling voice moved on a frame, the voices in order, once
            # everything due on the frame has played (Reference::Player#step_wobbles), as
            # IR::Tunes::Wobble#stepped counts it. A held tune's notes hold still.
            def emit_wobbles(asm, at, memory)
              m = SNES::Music
              asm.label("rt_music_wobbles")
              if holds?(memory) && !shares_voices?(memory)
                asm.lda(at.call(TUNE_HELD))
                asm.beq("rt_music_wobbles_go")
                asm.rts
                asm.label("rt_music_wobbles_go")
              end
              asm.stz(at.call(WOBBLE_AT))
              asm.label("rt_music_wobble_voice")
              asm.ldy(at.call(WOBBLE_AT))
              asm.lda(asm.abs_y(memory[WOBBLE_RECORD]))
              asm.branch_long(:beq, "rt_music_wobble_next")
              emit_skip_voice_held_still(asm, at, memory, "rt_music_wobble_next", "rt_music_wobble_moves")
              asm.lda(asm.abs_y(memory[WOBBLE_WAIT]))
              asm.beq("rt_music_wobble_going")
              asm.dec
              asm.sta(asm.abs_y(memory[WOBBLE_WAIT]))
              asm.bra("rt_music_wobble_next")
              asm.label("rt_music_wobble_going")
              asm.lda(asm.abs_y(memory[WOBBLE_LEFT]))
              asm.bne("rt_music_wobble_hold")
              asm.lda(asm.abs_y(memory[WOBBLE_RISING]))
              asm.eor(1)
              asm.sta(asm.abs_y(memory[WOBBLE_RISING]))
              asm.lda(asm.abs_y(memory[WOBBLE_RECORD]))
              asm.tax
              asm.lda(asm.long_x("music_data", m::WOBBLE_SPEED))
              asm.sta(asm.abs_y(memory[WOBBLE_LEFT]))
              asm.lda(asm.abs_y(memory[WOBBLE_RISING]))
              asm.beq("rt_music_wobble_down")
              asm.lda(asm.long_x("music_data", m::WOBBLE_UP))
              asm.bra("rt_music_wobble_turn")
              asm.label("rt_music_wobble_down")
              asm.lda(asm.long_x("music_data", m::WOBBLE_DOWN))
              asm.label("rt_music_wobble_turn")
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.ldy(at.call(WOBBLE_AT))
              asm.label("rt_music_wobble_hold")
              asm.lda(asm.abs_y(memory[WOBBLE_LEFT]))
              asm.dec
              asm.sta(asm.abs_y(memory[WOBBLE_LEFT]))
              asm.label("rt_music_wobble_next")
              asm.inc(at.call(WOBBLE_AT))
              asm.inc(at.call(WOBBLE_AT))
              asm.lda(at.call(WOBBLE_AT))
              asm.cmp(m::CONSOLE_PARTS * 2)
              asm.bne("rt_music_wobble_voice")
              asm.rts

              # rt_music_stop_wobble(channel): the game's own sound took the voice, so no note of a
              # song's wobbles on it (Reference::Player#game_sound_on).
              asm.label("rt_music_stop_wobble")
              asm.lda(asm.direct(Sound::R0))
              asm.dec
              asm.asl
              asm.tay
              asm.lda(0)
              asm.sta(asm.abs_y(memory[WOBBLE_RECORD]))
              asm.rtl

              # rt_music_note_wobble: the voice of the part at ENTRY wobbling as the note at NOTE
              # says, or holding still (Reference::Player#set_voice).
              asm.label("rt_music_note_wobble")
              asm.ldx(at.call(ENTRY))
              asm.lda(asm.long_x("music_data", m::CHANNEL))
              asm.dec
              asm.asl
              asm.tay
              asm.ldx(at.call(NOTE))
              if slides?(memory)
                # A note that slides does not wobble: the word is its slide's record.
                asm.lda(asm.long_x("music_data", m::NOTE_VOLUME))
                asm.bit(m::SLIDES)
                asm.beq("rt_music_note_wobble_says")
                asm.lda(0)
                asm.sta(asm.abs_y(memory[WOBBLE_RECORD]))
                asm.rts
                asm.label("rt_music_note_wobble_says")
              end
              asm.lda(asm.long_x("music_data", m::NOTE_WOBBLE))
              asm.sta(asm.abs_y(memory[WOBBLE_RECORD]))
              asm.beq("rt_music_note_wobble_done")
              asm.tax
              asm.lda(asm.long_x("music_data", m::WOBBLE_WAITS))
              asm.sta(asm.abs_y(memory[WOBBLE_WAIT]))
              # A vibrato that carries takes the swing up where the voice's last wobble left it, which
              # is still here, however long ago it stopped (IR::Tunes::Wobble.starting).
              asm.lda(asm.long_x("music_data", m::WOBBLE_CARRIES))
              asm.bne("rt_music_note_wobble_done")
              asm.lda(0)
              asm.sta(asm.abs_y(memory[WOBBLE_LEFT]))
              asm.sta(asm.abs_y(memory[WOBBLE_RISING]))
              asm.label("rt_music_note_wobble_done")
              asm.rts
            end

            # rt_music_hold_tune, rt_music_release_tune: it stays where it is, or carries on
            # (Reference::Player#hold).
            def emit_tune_hold(asm, at)
              asm.label("rt_music_hold_tune")
              asm.lda(1)
              asm.sta(at.call(TUNE_HELD))
              asm.rtl
              asm.label("rt_music_release_tune")
              asm.stz(at.call(TUNE_HELD))
              asm.rtl
            end

            # rt_music_play(tune): play it from the next frame, unless it is playing already.
            # rt_music_play_now(tune): the same, and a tune that is starting plays its first frame
            # here (Reference::Player#start_song_here). rt_music_stop(): no tune.
            def emit_game_side(asm, at)
              asm.label("rt_music_play")
              asm.lda(asm.direct(Sound::R0))
              asm.sta(at.call(NAMED))
              asm.rtl

              asm.label("rt_music_play_now")
              asm.lda(asm.direct(Sound::R0))
              asm.sta(at.call(NAMED))
              # The tune named, caught up with here: one that starts plays its first frame.
              asm.label("rt_music_start_here")
              asm.jsr(asm.abs("rt_music_switch"))
              asm.beq("rt_music_start_here_done")
              asm.lda(at.call(PLAYING))
              asm.beq("rt_music_start_here_done")
              asm.jsr(asm.abs("rt_music_song_frame"))
              asm.label("rt_music_start_here_done")
              asm.rtl

              asm.label("rt_music_stop")
              asm.stz(at.call(NAMED))
              asm.inc(at.call(STOPS))
              asm.rtl

              # rt_music_play_from_list(which, list): the song at place +which+ of song list +list+
              # (SNES::Music#list_number), from the next frame; a place outside the list leaves the
              # music as it is (Reference::Player#request_song_at). rt_music_play_from_list_now: the
              # same, and a song it names that is starting plays its first frame here.
              asm.label("rt_music_play_from_list")
              asm.jsr(asm.abs("rt_music_name_from_list"))
              asm.rtl

              asm.label("rt_music_play_from_list_now")
              asm.jsr(asm.abs("rt_music_name_from_list"))
              asm.bne("rt_music_start_here")
              asm.rtl

              # rt_music_name_from_list: NAMED = the song at place R0 (32 bits) of list R1, and A = 1;
              # or A = nought, and nothing named, for a place outside the list.
              asm.label("rt_music_name_from_list")
              asm.lda(asm.direct(Sound::R0 + 2))
              asm.bne("rt_music_name_from_list_outside") # below nought, or far past any list's end
              asm.lda(asm.direct(Sound::R1))
              asm.asl
              asm.clc
              asm.adc(asm.long("music_data", SNES::Music::LISTS_AT))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.sta(at.call(LIST))
              asm.tax
              asm.lda(asm.direct(Sound::R0))
              asm.cmp(asm.long_x("music_data")) # how many songs the list holds
              asm.bcs("rt_music_name_from_list_outside")
              asm.asl
              asm.clc
              asm.adc(at.call(LIST))
              asm.tax
              asm.lda(asm.long_x("music_data", 2))
              asm.sta(at.call(NAMED))
              asm.lda(1)
              asm.rts
              asm.label("rt_music_name_from_list_outside")
              asm.lda(0)
              asm.rts
            end

            # rt_music_frame: one frame of the player (Sound's rt_sound_frame plays one for each frame
            # the pass just ended took) — with sound effects, Reference::Player#advance's order: the
            # tune caught up with, the effects that outrank it, its parts, and the other effects
            # (Effects).
            def emit_frames(asm, at, sharing, memory)
              asm.label("rt_music_frame")
              asm.jsr(asm.abs("rt_music_switch"))
              asm.jsr(asm.abs("rt_sfx_above")) if sharing
              asm.lda(at.call(PLAYING))
              asm.beq("rt_music_frame_played")
              asm.jsr(asm.abs("rt_music_song_frame"))
              asm.label("rt_music_frame_played")
              asm.jsr(asm.abs("rt_sfx_below")) if sharing
              asm.jsr(asm.abs("rt_music_swells")) if swells?(memory)
              asm.jsr(asm.abs("rt_music_slides")) if slides?(memory)
              asm.jsr(asm.abs("rt_music_wobbles")) if wobbles?(memory)
              asm.jsr(asm.abs("rt_music_shapes")) if steps_shapes?(memory)
              asm.rts
            end

            # rt_music_switch: caught up with the tune the game names (Reference::Player#switch_to_wanted_song).
            # A is 1 when that changed what is playing, nought when not.
            def emit_switch(asm, at, memory, level_at, sharing, recorded)
              asm.label("rt_music_switch")
              asm.lda(at.call(ENDED))
              asm.beq("rt_music_switch_live")
              asm.cmp(at.call(NAMED))
              asm.bne("rt_music_switch_forget")
              asm.lda(at.call(STOPS))
              asm.cmp(at.call(STOPS_SEEN))
              asm.bne("rt_music_switch_forget")
              # Still named, and no stop since: the tune that ended stays quiet.
              asm.lda(at.call(PLAYING))
              asm.beq("rt_music_switch_ended")
              asm.jsr(asm.abs("rt_music_quiet"))
              asm.label("rt_music_switch_ended")
              asm.stz(at.call(PLAYING))
              asm.lda(0)
              asm.rts
              asm.label("rt_music_switch_forget")
              asm.stz(at.call(ENDED))
              asm.label("rt_music_switch_live")
              asm.lda(at.call(NAMED))
              asm.cmp(at.call(PLAYING))
              asm.bne("rt_music_switch_change")
              asm.lda(at.call(STOPS))
              asm.cmp(at.call(STOPS_SEEN))
              asm.bne("rt_music_switch_change")
              asm.lda(0)
              asm.rts
              asm.label("rt_music_switch_change")
              asm.stz(at.call(TUNE_HELD)) if holds?(memory)
              asm.lda(at.call(STOPS))
              asm.sta(at.call(STOPS_SEEN))
              asm.lda(at.call(PLAYING))
              asm.beq("rt_music_switch_quiet")
              asm.jsr(asm.abs("rt_music_quiet"))
              asm.label("rt_music_switch_quiet")
              asm.lda(at.call(NAMED))
              asm.sta(at.call(PLAYING))
              asm.beq("rt_music_switch_changed")
              asm.dec # the tune's word in the table of songs, whose place is at SONGS_AT
              asm.asl
              asm.clc
              asm.adc(asm.long("music_data", SNES::Music::SONGS_AT))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.sta(at.call(SONG))
              asm.stz(at.call(FRAME))
              asm.stz(at.call(AGAIN))
              asm.jsr(asm.abs("rt_music_from_the_top"))
              asm.label("rt_music_switch_changed")
              asm.lda(1)
              asm.rts

              asm.label("rt_music_from_the_top")
              SNES::Music::PARTS.times { |p| asm.stz(at.call(CURSORS, p * 2)) }
              asm.lda(at.call(FRAME)) # a walk now, to find where each part's notes begin
              asm.sta(at.call(NEXT_NOTE_FRAME))
              asm.rts

              # THE PLAYING TUNE STOPS (Reference::Player#silence_song; SONG is still the tune's): the
              # voices its parts play on let go — but one a sound effect holds, which stays the
              # effect's — every voice the tune held free, no note held, and the tune's own stop
              # logged (Music.stop_entry).
              asm.label("rt_music_quiet")
              asm.jsl(asm.long("rt_recordings_release_music")) if recorded # the places its parts hold
              emit_tune_voices_stop_changing(asm, at, memory)
              if level_at
                SNES::Music::PARTS.times do |p|
                  asm.stz(asm.abs(memory[HELD], p * 2))
                  asm.stz(asm.abs(memory[HELD_IN], p * 2))
                end
                asm.stz(at.call(HELD_END))
              end
              asm.ldx(at.call(SONG))
              asm.lda(asm.long_x("music_data", SNES::Music::VOICES))
              asm.sta(asm.direct(Sound::R0))
              Effects.emit_release_tune_voices(asm, memory) if sharing
              asm.lda(asm.direct(Sound::R0))
              asm.sta(asm.direct(Sound::R1))
              asm.lda(Sound::SET_KEY_OFF_BITS)
              asm.jsl(asm.long("rt_sound_command"))
              asm.ldx(at.call(SONG))
              asm.lda(asm.long_x("music_data", SNES::Music::STOP_LOG))
              asm.tax
              asm.jmp(asm.abs("rt_sound_group"))
            end

            # rt_music_recorded_note: the note at NOTE of a part that plays a recording, A its channel
            # (SNES::Music::RECORDED_CHANNEL on): a note takes a place for the part (rt_recordings_note),
            # and logs itself if it found one; a rest gives the part's place back and logs itself
            # whether the part had one or not (Reference::Player#play_song_frame).
            def emit_recorded_note(asm, at, memory, level_at)
              m = SNES::Music
              asm.label("rt_music_recorded_note")
              asm.sec
              asm.sbc(m::RECORDED_CHANNEL - 1) # the part's own number in Recordings' places
              asm.sta(asm.direct(Sound::R1))
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_RECORDING))
              asm.bne("rt_music_recorded_note_plays")
              asm.lda(asm.direct(Sound::R1))
              asm.sta(asm.direct(Sound::R0))
              asm.jsl(asm.long("rt_recordings_note_release"))
              asm.bra("rt_music_recorded_note_log")
              asm.label("rt_music_recorded_note_plays")
              asm.dec
              asm.sta(asm.direct(Sound::R0))
              asm.ldx(at.call(SONG))
              asm.lda(asm.long_x("music_data", m::RANK))
              asm.inc # above the game's own sounds, at nought
              asm.sta(asm.direct(Sound::R2))
              asm.jsl(asm.long("rt_recordings_note"))
              asm.cmp(0)
              asm.beq("rt_music_recorded_note_done") # no place: not heard
              asm.label("rt_music_recorded_note_log")
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_HEAD))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              emit_recorded_note_level(asm, at, memory) if level_at
              asm.label("rt_music_recorded_note_done")
              asm.rts
            end

            # The heard recorded note at NOTE under the music volume (Reference::Player#record_note_volume):
            # the part's record held for a new level to reach, nought for a rest, the part in HELD_ORDER,
            # and its loudness at the level given to its place and logged.
            def emit_recorded_note_level(asm, at, memory)
              m = SNES::Music
              asm.lda(at.call(PART))
              asm.asl
              asm.tay
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_WOBBLE))
              asm.sta(at.call(LOUDNESS_TABLE))
              asm.lda(asm.long_x("music_data", m::NOTE_RECORDING))
              asm.beq("rt_music_recorded_level_rest")
              asm.lda(at.call(LOUDNESS_TABLE))
              asm.label("rt_music_recorded_level_rest")
              asm.sta(asm.abs_y(memory[HELD]))
              asm.lda(asm.abs_y(memory[HELD_IN]))
              asm.bne("rt_music_recorded_level_listed")
              asm.lda(1)
              asm.sta(asm.abs_y(memory[HELD_IN]))
              asm.ldx(at.call(HELD_END))
              asm.lda(at.call(PART))
              asm.sta(asm.abs_x(memory[HELD_ORDER]))
              asm.inx
              asm.inx
              asm.stx(at.call(HELD_END))
              asm.label("rt_music_recorded_level_listed")
              emit_level_entry(asm, at)
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_RECORDING))
              asm.beq("rt_music_recorded_level_log")
              asm.ldx(at.call(LOUDNESS))
              asm.lda(asm.long_x("music_data", m::LEVEL_VOLUMES))
              asm.sta(asm.direct(Sound::R0))
              asm.jsl(asm.long("rt_recordings_loud"))
              asm.label("rt_music_recorded_level_log")
              asm.ldx(at.call(LOUDNESS))
              asm.lda(asm.long_x("music_data"))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
            end

            # LOUDNESS = where the level's entry is in the record at LOUDNESS_TABLE.
            def emit_level_entry(asm, at)
              asm.lda(at.call(LEVEL_SET))
              asm.eor(IR::Tunes::FULL_LEVEL)
              asm.asl
              asm.clc
              asm.adc(at.call(LOUDNESS_TABLE))
              asm.sta(at.call(LOUDNESS))
            end

            # rt_music_song_frame: each part's note whose frame has come, then the frame on
            # (Reference::Player#play_song_frame and #advance_song_frame).
            def emit_song_frame(asm, at, memory, level_at, sharing, recorded)
              m = SNES::Music
              asm.label("rt_music_song_frame")
              asm.ldx(at.call(SONG))
              asm.lda(asm.long_x("music_data", m::PART_COUNT))
              asm.sta(at.call(PARTS_IN))
              asm.jsr(asm.abs("rt_music_relevel")) if level_at
              if holds?(memory) # a tune held stays on this frame, and no note of it starts
                asm.lda(at.call(TUNE_HELD))
                asm.branch_long(:bne, "rt_music_song_frame_done")
              end
              # Most frames start no note, so the parts are walked only on the frame the next is due.
              asm.lda(at.call(FRAME))
              asm.cmp(at.call(NEXT_NOTE_FRAME))
              asm.branch_long(:bne, "rt_music_parts_done")
              asm.lda(NO_NOTE_DUE)
              asm.sta(at.call(NEXT_NOTE_FRAME))
              asm.stz(at.call(PART))
              asm.label("rt_music_part")
              asm.lda(at.call(PART))
              asm.cmp(at.call(PARTS_IN))
              asm.branch_long(:bcs, "rt_music_parts_done")
              asm.jsr(asm.abs("rt_music_entry"))
              asm.lda(at.call(AGAIN))
              asm.beq("rt_music_part_pass")
              m::AGAIN.times { asm.inx }
              asm.label("rt_music_part_pass")
              asm.lda(asm.long_x("music_data", m::NOTE_COUNT))
              asm.sta(at.call(COUNT))
              asm.lda(asm.long_x("music_data", m::NOTES_AT))
              asm.sta(at.call(LIST))
              asm.lda(at.call(PART))
              asm.asl
              asm.tay
              asm.lda(asm.abs_y(memory[CURSORS]))
              asm.cmp(at.call(COUNT))
              asm.branch_long(:bcs, "rt_music_part_next")
              emit_times(asm, m::NOTE_BYTES) # the next note: its frame, and where its group is
              asm.clc
              asm.adc(at.call(LIST))
              asm.tax
              asm.lda(asm.long_x("music_data", m::NOTE_FRAME))
              asm.cmp(at.call(FRAME))
              asm.beq("rt_music_part_note_due")
              emit_next_note_frame_kept(asm, at)
              asm.brl("rt_music_part_next")
              asm.label("rt_music_part_note_due")
              asm.stx(at.call(NOTE))
              if recorded # a part that plays a recording: its note in Recordings' places
                asm.ldx(at.call(ENTRY))
                asm.lda(asm.long_x("music_data", m::CHANNEL))
                asm.cmp(m::RECORDED_CHANNEL)
                asm.bcc("rt_music_part_console")
                asm.jsr(asm.abs("rt_music_recorded_note"))
                asm.brl("rt_music_part_passed")
                asm.label("rt_music_part_console")
              end
              if sharing
                # A voice a sound effect holds with a higher rank: the part carries on in time,
                # silent here (Reference::Player#play_song_frame).
                asm.ldx(at.call(SONG))
                asm.lda(asm.long_x("music_data", m::RANK))
                Effects.emit_claim_call(asm, memory)
                asm.branch_long(:beq, "rt_music_part_passed")
              end
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_HEAD))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              emit_note_loudness(asm, at, memory) if level_at
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_TAIL))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              emit_note_changes(asm, memory)
              asm.label("rt_music_part_passed")
              asm.lda(at.call(PART))
              asm.asl
              asm.tax
              asm.inc(asm.abs_x(memory[CURSORS]))
              asm.lda(asm.abs_x(memory[CURSORS])) # the part's note after this one: its frame, if it has one
              asm.cmp(at.call(COUNT))
              asm.bcs("rt_music_part_next")
              emit_times(asm, m::NOTE_BYTES)
              asm.clc
              asm.adc(at.call(LIST))
              asm.tax
              asm.lda(asm.long_x("music_data", m::NOTE_FRAME))
              asm.cmp(at.call(FRAME))
              asm.beq("rt_music_part_next") # one note a part a frame, as Reference::Player#play_song_frame
              emit_next_note_frame_kept(asm, at)
              asm.label("rt_music_part_next")
              asm.inc(at.call(PART))
              asm.brl("rt_music_part")

              # rt_music_entry: ENTRY and X = where part PART's entry is.
              asm.label("rt_music_entry")
              asm.lda(at.call(PART))
              emit_times(asm, m::PART_BYTES)
              asm.clc
              asm.adc(at.call(SONG))
              asm.clc
              asm.adc(m::RECORD_BYTES)
              asm.sta(at.call(ENTRY))
              asm.tax
              asm.rts

              emit_recorded_note(asm, at, memory, level_at) if recorded

              asm.label("rt_music_parts_done")
              asm.inc(at.call(FRAME))
              asm.ldx(at.call(SONG))
              asm.lda(at.call(FRAME))
              asm.cmp(asm.long_x("music_data", m::LENGTH))
              asm.bcc("rt_music_song_frame_done")
              asm.lda(asm.long_x("music_data", m::PLAYS_ONCE))
              asm.beq("rt_music_round")
              asm.lda(at.call(PLAYING)) # a tune that plays once: ended
              asm.sta(at.call(ENDED))
              asm.rts
              asm.label("rt_music_round")
              asm.lda(asm.long_x("music_data", m::LOOP_FRAME))
              asm.sta(at.call(FRAME))
              asm.lda(1)
              asm.sta(at.call(AGAIN))
              asm.jsr(asm.abs("rt_music_from_the_top"))
              asm.label("rt_music_song_frame_done")
              asm.rts
            end

            # With a note's frame in A and the carry from comparing it with FRAME: kept in
            # NEXT_NOTE_FRAME if it is ahead of FRAME and sooner than the one kept.
            def emit_next_note_frame_kept(asm, at)
              kept = asm.here
              asm.bcc("rt_music_next_note_kept_#{kept}")
              asm.cmp(at.call(NEXT_NOTE_FRAME))
              asm.bcs("rt_music_next_note_kept_#{kept}")
              asm.sta(at.call(NEXT_NOTE_FRAME))
              asm.label("rt_music_next_note_kept_#{kept}")
            end

            # A NOTE'S LOUDNESS, between its head and its tail (SNES::Music#part_layout): its volume as
            # written held for a new level to reach, if its voice holds one, and its loudness at the
            # level written and logged.
            def emit_note_loudness(asm, at, memory)
              m = SNES::Music
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_VOLUME))
              asm.and_a(m::PLAIN_VOLUME | m::LEFT_ONLY | m::RIGHT_ONLY)
              asm.pha
              # A note that fades by itself is not held for a new level: one struck again would
              # start its fade over (IR::Tunes.changes_by_itself?), so the level reaches its next note.
              asm.lda(asm.long_x("music_data", m::NOTE_VOLUME))
              asm.bit(m::RINGS_ALONE)
              asm.beq("rt_music_note_may_hold")
              asm.ldx(at.call(ENTRY))
              asm.lda(asm.long_x("music_data", m::CHANNEL))
              asm.jsr(asm.abs("rt_music_unhold"))
              asm.bra("rt_music_note_not_held")
              asm.label("rt_music_note_may_hold")
              asm.ldx(at.call(ENTRY))
              asm.lda(asm.long_x("music_data", m::HOLDS))
              asm.beq("rt_music_note_not_held")
              asm.lda(at.call(PART))
              asm.asl
              asm.tay
              asm.lda(asm.stack(1))
              asm.sta(asm.abs_y(memory[HELD]))
              asm.lda(asm.abs_y(memory[HELD_IN]))
              asm.bne("rt_music_note_not_held") # in the list already, where it first came
              asm.lda(1)
              asm.sta(asm.abs_y(memory[HELD_IN]))
              asm.ldx(at.call(HELD_END))
              asm.lda(at.call(PART))
              asm.sta(asm.abs_x(memory[HELD_ORDER]))
              asm.inx
              asm.inx
              asm.stx(at.call(HELD_END))
              asm.label("rt_music_note_not_held")
              asm.pla
              if swells?(memory)
                # A note that swells logs its loudness and writes nothing: it stays at full volume, climbing.
                asm.sta(at.call(LOUDNESS))
                asm.ldx(at.call(NOTE))
                asm.lda(asm.long_x("music_data", m::NOTE_SWELL))
                asm.beq("rt_music_note_plain")
                asm.sta(at.call(SWELL_GROUPS))
                asm.lda(at.call(LOUDNESS))
                asm.and_a(m::PLAIN_VOLUME)
                asm.jsr(asm.abs("rt_music_scaled"))
                asm.asl
                asm.clc
                asm.adc(at.call(SWELL_GROUPS))
                asm.clc
                asm.adc(m::SWELL_STARTS)
                asm.tax
                asm.lda(asm.long_x("music_data"))
                asm.tax
                asm.jsr(asm.abs("rt_sound_group"))
                asm.bra("rt_music_note_loud")
                asm.label("rt_music_note_plain")
                asm.lda(at.call(LOUDNESS))
              end
              asm.jsr(asm.abs("rt_music_loudness"))
              asm.label("rt_music_note_loud") if swells?(memory)
            end

            # THE MUSIC VOLUME MOVED (Reference::Player#apply_music_volume): at the start of a frame
            # of the tune, before any note, every part whose voice holds a note writes and logs its
            # loudness at the new level, in the order the parts first took their voices (HELD_ORDER) —
            # the order of the parts, since every part's first time round starts with an event at
            # frame 0 (IR::Tunes.loop_passes), until a sound effect takes one.
            #
            # rt_music_unhold: the playing tune's part on channel A taken out of HELD_ORDER, its note
            # no longer held, as a sound effect takes its voice (Reference::Player#play_effect_frame).
            #
            # rt_music_loudness: the part at ENTRY's loudness group for the volume in A at the level.
            # rt_music_scaled: A = the volume in A at the level (IR::Tunes.scaled_volume), the level
            # times the volume by adding, and a shift.
            # A part that plays a recording, its record on the stack and its entry in X: its sounding
            # note's place given the new loudness, and logged only if it has one
            # (Reference::Mixer#rescale_music). On to the next part.
            def emit_relevel_recorded_part(asm, at)
              m = SNES::Music
              asm.lda(asm.long_x("music_data", m::CHANNEL))
              asm.cmp(m::RECORDED_CHANNEL)
              asm.bcc("rt_music_relevel_console")
              asm.sec
              asm.sbc(m::RECORDED_CHANNEL - 1)
              asm.sta(asm.direct(Sound::R0))
              asm.pla
              asm.sta(at.call(LOUDNESS_TABLE))
              emit_level_entry(asm, at)
              asm.tax
              asm.lda(asm.long_x("music_data", m::LEVEL_VOLUMES))
              asm.sta(asm.direct(Sound::R1))
              asm.jsl(asm.long("rt_recordings_rescale"))
              asm.cmp(0)
              asm.branch_long(:beq, "rt_music_relevel_next")
              asm.ldx(at.call(LOUDNESS))
              asm.lda(asm.long_x("music_data"))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.brl("rt_music_relevel_next")
              asm.label("rt_music_relevel_console")
            end

            def emit_level(asm, at, memory, level_at, recorded)
              m = SNES::Music
              full = IR::Tunes::FULL_LEVEL
              asm.label("rt_music_relevel")
              asm.lda(asm.abs(level_at))
              asm.eor(full)
              asm.cmp(at.call(LEVEL_SET))
              asm.bne("rt_music_relevel_moved")
              asm.rts
              asm.label("rt_music_relevel_moved")
              asm.sta(at.call(LEVEL_SET))
              asm.stz(at.call(HELD_WALK)) # where in HELD_ORDER, two bytes a part
              asm.label("rt_music_relevel_part")
              asm.lda(at.call(HELD_WALK))
              asm.cmp(at.call(HELD_END))
              asm.bcs("rt_music_relevel_done")
              asm.tax
              asm.lda(asm.abs_x(memory[HELD_ORDER]))
              asm.sta(at.call(PART))
              asm.asl
              asm.tay
              asm.lda(asm.abs_y(memory[HELD]))
              asm.branch_long(:beq, "rt_music_relevel_next")
              asm.pha
              asm.jsr(asm.abs("rt_music_entry"))
              emit_relevel_recorded_part(asm, at) if recorded
              asm.pla
              asm.jsr(asm.abs("rt_music_loudness"))
              asm.label("rt_music_relevel_next")
              asm.inc(at.call(HELD_WALK))
              asm.inc(at.call(HELD_WALK))
              asm.bra("rt_music_relevel_part")
              asm.label("rt_music_relevel_done")
              asm.rts

              asm.label("rt_music_unhold")
              asm.sta(at.call(CHANNEL_FOUND))
              asm.lda(at.call(PLAYING))
              asm.beq("rt_music_unhold_done")
              asm.ldx(at.call(SONG))
              asm.lda(asm.long_x("music_data", m::PART_COUNT))
              asm.sta(at.call(PARTS_IN))
              asm.stz(at.call(PART))
              asm.label("rt_music_unhold_find")
              asm.lda(at.call(PART))
              asm.cmp(at.call(PARTS_IN))
              asm.bcs("rt_music_unhold_done")
              asm.jsr(asm.abs("rt_music_entry"))
              asm.lda(asm.long_x("music_data", m::CHANNEL))
              asm.cmp(at.call(CHANNEL_FOUND))
              asm.beq("rt_music_unhold_found")
              asm.inc(at.call(PART))
              asm.bra("rt_music_unhold_find")
              asm.label("rt_music_unhold_found")
              asm.lda(at.call(PART))
              asm.asl
              asm.tay
              asm.lda(0)
              asm.sta(asm.abs_y(memory[HELD]))
              asm.lda(asm.abs_y(memory[HELD_IN]))
              asm.beq("rt_music_unhold_done")
              asm.lda(0)
              asm.sta(asm.abs_y(memory[HELD_IN]))
              # Out of the list: every part after it moves down a place.
              asm.ldx(0)
              asm.label("rt_music_unhold_seek")
              asm.lda(asm.abs_x(memory[HELD_ORDER]))
              asm.cmp(at.call(PART))
              asm.beq("rt_music_unhold_shift")
              asm.inx
              asm.inx
              asm.bra("rt_music_unhold_seek")
              asm.label("rt_music_unhold_shift")
              asm.lda(asm.abs_x(memory[HELD_ORDER], 2))
              asm.sta(asm.abs_x(memory[HELD_ORDER]))
              asm.inx
              asm.inx
              asm.cpx(at.call(HELD_END))
              asm.bcc("rt_music_unhold_shift")
              asm.dec(at.call(HELD_END))
              asm.dec(at.call(HELD_END))
              asm.label("rt_music_unhold_done")
              asm.rts

              asm.label("rt_music_loudness")
              if sides?(memory)
                # The note's side in its upper bits is which of the part's lists: each is a word for
                # each of the sixteen volumes, 32 bytes.
                asm.sta(at.call(LOUDNESS))
                5.times { asm.lsr }
                asm.and_a(0x60)
                asm.sta(at.call(LOUDNESS_LIST))
                asm.lda(at.call(LOUDNESS))
                asm.and_a(m::PLAIN_VOLUME)
              end
              asm.jsr(asm.abs("rt_music_scaled"))
              asm.sta(at.call(LOUDNESS))
              asm.ldx(at.call(ENTRY))
              asm.lda(asm.long_x("music_data", m::LOUDNESS_GROUPS))
              asm.sta(at.call(LOUDNESS_TABLE))
              asm.lda(at.call(LOUDNESS))
              asm.asl
              asm.clc
              asm.adc(at.call(LOUDNESS_TABLE))
              if sides?(memory)
                asm.clc
                asm.adc(at.call(LOUDNESS_LIST))
              end
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.tax
              asm.jmp(asm.abs("rt_sound_group"))

              asm.label("rt_music_scaled")
              asm.tax
              asm.lda(at.call(LEVEL_SET))
              asm.eor(full)
              asm.sta(at.call(LEVEL_NOW))
              asm.lda(0)
              asm.cpx(0)
              asm.beq("rt_music_scaled_summed")
              asm.label("rt_music_scaled_add")
              asm.clc
              asm.adc(at.call(LEVEL_NOW))
              asm.dex
              asm.bne("rt_music_scaled_add")
              asm.label("rt_music_scaled_summed")
              IR::Tunes::LEVEL_SHIFT.times { asm.lsr }
              asm.rts
            end

            # rt_sound_group (X = where a group is in the table): each of its commands sent to the sound
            # unit, or its entry put in the sound log, until its end.
            def emit_group(asm)
              m = SNES::Music
              asm.label("rt_sound_group")
              asm.lda(asm.long_x("music_data"))
              asm.beq("rt_sound_group_done")
              asm.cmp(m::GROUP_LOG)
              asm.beq("rt_sound_group_log")
              asm.pha
              asm.lda(asm.long_x("music_data", m::COMMAND_FIRST))
              asm.sta(asm.direct(Sound::R0))
              asm.lda(asm.long_x("music_data", m::COMMAND_SECOND))
              asm.sta(asm.direct(Sound::R1))
              asm.pla
              asm.phx
              asm.jsl(asm.long("rt_sound_command"))
              asm.plx
              asm.bra("rt_sound_group_next")
              asm.label("rt_sound_group_log")
              asm.lda(asm.long_x("music_data", m::COMMAND_FIRST))
              asm.sta(asm.direct(Sound::R0))
              asm.phx
              asm.jsl(asm.long("rt_sound_log"))
              asm.plx
              asm.label("rt_sound_group_next")
              asm.txa
              asm.clc
              asm.adc(m::COMMAND_BYTES)
              asm.tax
              asm.bra("rt_sound_group")
              asm.label("rt_sound_group_done")
              asm.rts
            end

            # A times +count+, a power of two, by shifting.
            def emit_times(asm, count)
              raise ArgumentError, "#{count} is not a power of two" unless count.positive? && (count & (count - 1)).zero?

              (count.bit_length - 1).times { asm.asl }
            end
          end
        end
      end
    end
  end
end
