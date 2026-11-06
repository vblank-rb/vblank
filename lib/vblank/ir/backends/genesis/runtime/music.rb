# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # THE MUSIC PLAYER. The game only names a tune (rt_music_play) or stops it (rt_music_stop), and the
          # player walks each part's notes (Genesis::Music) a frame at a time, sending each note's group of
          # commands to the sound chips as its frame comes.
          #
          # WHERE IT RUNS. Where a pass's wait ends (Sound's rt_sound_frame), once for every frame the pass
          # took, which is where the interpreter moves its music on too (Reference#advance_frame), after the
          # pass and by every frame it took. A game that keeps up hears each note on its own frame; one
          # that falls behind hears the frames it missed at once, as the interpreter logs them.
          #
          # What it does each frame is Reference::Player#advance's steps, in its order: catch up with the
          # tune the game names (a different one, or a stop, quiets the old and starts the new from its
          # first frame; one that played once and ended stays quiet), then each part's next note if its frame
          # has come, then the frame on, round to the tune's loop frame at its end.
          #
          # WHAT IS IN THE REGISTERS. A group sent to the chips uses most of them, so nothing is kept in a
          # register across one. Where the player has got to is in work RAM, the tune, the part and the
          # note as addresses in the song table, which A0 and A1 are loaded from as each is wanted.
          module Music
            NAMED = "rt music named" # The tune the game named last (Genesis::Music#number), nought for none
            PLAYING = "rt music playing" # The tune playing
            STOPS = "rt music stops" # How many times the game asked stop_music
            STOPS_SEEN = "rt music stops seen" # How many of those stops the player has acted on
            ENDED = "rt music ended" # A tune that played once and reached its end
            TUNE_HELD = "rt music tune held" # 1 while the game holds the tune, in a game that asks for it
            FRAME = "rt music frame" # How far into the tune, in frames
            AGAIN = "rt music again" # 1 once the tune has come round
            SONG = "rt music song" # Where the playing tune's record is, an address
            CURSORS = "rt music cursors" # Each part's next note
            PART = "rt music part" # The part being played
            PARTS_IN = "rt music parts in" # How many parts there are
            ENTRY = "rt music entry" # Where the part being played's entry is, an address
            NOTE = "rt music note" # Its note being played
            # THE MUSIC VOLUME, in a game that sets it (Genesis::Music#follows_level?): the level the notes
            # sounding were set at, with its FULL_LEVEL bit turned over so the nought memory starts at means
            # full; each part's note's volume as written, while its voice holds it (nought for a rest, or
            # none); and which parts' voices hold one, in the order they first took one since the tune
            # started (Reference::Player's @sounding, a Hash kept in the order its keys came).
            LEVEL_SET = "rt music level set"
            HELD = "rt music held"
            HELD_ORDER = "rt music held order"
            HELD_END = "rt music held end"
            HELD_IN = "rt music held in"
            HELD_WALK = "rt music held walk"
            CHANNEL_FOUND = "rt music channel found"
            LOUDNESS_LIST = "rt music loudness list" # Which of a part's lists of loudness groups a strike reads
            # EACH CONSOLE VOICE'S NOTE THAT CHANGES AS IT PLAYS, VOICE_BYTES a voice, in a game with one: a
            # wobble's record (Genesis::Music#wobble_record), nought for a voice holding still, the frames still
            # to wait, the frames its swing has left, and whether it is above the note's pitch.
            WOBBLES = "rt music wobbles"
            WOBBLE_RECORD = 0
            WOBBLE_WAIT = 2
            WOBBLE_LEFT = 4
            WOBBLE_RISING = 6
            # ...a square note's shapes' record and its note's frame, kept in 0..7 so nought is its first alone...
            SHAPES = "rt music shapes"
            SHAPE_RECORD = 0
            SHAPE_FRAME = 2
            # ...and a swell's record, its loudness and its count as the interpreter keeps them (IR::Tunes::Swell).
            SWELLS = "rt music swells"
            SWELL_RECORD = 0
            SWELL_VOLUME = 2
            SWELL_COUNTED = 4
            SWELL_RISING = 6
            VOICE_BYTES = 8
            VOICE_AT = "rt music voice at" # The voice being stepped, VOICE_BYTES a voice
            SWELL_CEILING = "rt music swell ceiling"
            SLIDE_CURSOR = "rt music slide cursor" # Where the sliding note's next frame is; nought when none slides

            PARTS = Genesis::Music::PARTS
            CONSOLE_PARTS = Genesis::Music::CONSOLE_PARTS

            module_function

            # +follows_level+ for a game that sets the music volume; +effects+ how many sound effects it has.
            def reserve(memory, follows_level: false, effects: 0, holds: false, wobbles: false, steps_shapes: false, swells: false,
                        slides: false, sides: false)
              memory.reserve(TUNE_HELD, 2) if holds
              memory.reserve(LOUDNESS_LIST, 2) if sides
              memory.reserve(SLIDE_CURSOR, 4) if slides
              memory.reserve(WOBBLES, CONSOLE_PARTS * VOICE_BYTES) if wobbles
              memory.reserve(SHAPES, CONSOLE_PARTS * VOICE_BYTES) if steps_shapes
              memory.reserve(SWELLS, CONSOLE_PARTS * VOICE_BYTES) if swells
              memory.reserve(SWELL_CEILING, 2) if swells
              memory.reserve(VOICE_AT, 2) if wobbles || steps_shapes || swells
              [NAMED, PLAYING, STOPS, STOPS_SEEN, ENDED, FRAME, AGAIN, PART, PARTS_IN].each { |name| memory.reserve(name, 2) }
              [SONG, ENTRY, NOTE].each { |name| memory.reserve(name, 4) }
              memory.reserve(CURSORS, PARTS * 2)
              Effects.reserve(memory, effects) if effects.positive?
              return unless follows_level

              [LEVEL_SET, HELD_END, HELD_WALK, CHANNEL_FOUND].each { |name| memory.reserve(name, 2) }
              [HELD, HELD_IN].each { |name| memory.reserve(name, PARTS * 2) }
              # ...and a word past the last part, which taking a part out of a full list reads as it moves the
              # rest down.
              memory.reserve(HELD_ORDER, (PARTS + 1) * 2)
            end

            # +level_at+ is where a game that sets its music volume keeps it (IR::Tunes::LEVEL), or nil;
            # +effects+ how many sound effects the game has; +recorded+ for a game with a part that plays a
            # recording.
            def emit(asm, memory, level_at: nil, effects: 0, recorded: false)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              sharing = effects.positive?
              emit_game_side(asm, at)
              emit_tune_hold(asm, at) if holds?(memory)
              emit_frames(asm, at, sharing, memory)
              emit_voice_changes(asm, at, memory)
              emit_switch(asm, at, memory, level_at, sharing, recorded)
              emit_song_frame(asm, at, memory, level_at, sharing, recorded)
              emit_level(asm, at, memory, level_at, recorded) if level_at
              Effects.emit(asm, memory, effects, level_at, recorded: recorded) if sharing
              emit_group(asm)
            end

            def holds?(memory) = memory.reserved?(TUNE_HELD)
            def wobbles?(memory) = memory.reserved?(WOBBLES)
            def steps_shapes?(memory) = memory.reserved?(SHAPES)
            def swells?(memory) = memory.reserved?(SWELLS)
            def slides?(memory) = memory.reserved?(SLIDE_CURSOR)
            def shares_voices?(memory) = memory.reserved?(Effects::HOLDERS)
            def sides?(memory) = memory.reserved?(LOUDNESS_LIST)

            # A0 = the song table, and A1 = the place in it D0's low word gives.
            def emit_table_place(asm, register = 1)
              asm.and(:l, asm.imm(0xFFFF), asm.d(0))
              asm.lea(asm.abs_l("music_data"), asm.a(0))
              asm.lea(asm.idx(0, 0, 0), asm.a(register))
            end

            # The group whose place is the word at +field+ from +pointer+ (an operand holding an address),
            # sent to the chips.
            def emit_group_at(asm, pointer, field)
              asm.movea(:l, pointer, asm.a(0))
              asm.move(:w, asm.disp(0, field), asm.d(0))
              asm.jsr(asm.abs_l("rt_sound_group"))
            end

            # The note at ENTRY and NOTE taken up by what changes as it plays, a tune's or an effect's.
            def emit_note_changes(asm, memory)
              asm.jsr(asm.abs_l("rt_music_note_wobble")) if wobbles?(memory)
              asm.jsr(asm.abs_l("rt_music_note_shapes")) if steps_shapes?(memory)
              asm.jsr(asm.abs_l("rt_music_note_swell")) if swells?(memory)
              asm.jsr(asm.abs_l("rt_music_note_slide")) if slides?(memory)
            end

            # The voice D4 names, VOICE_BYTES a voice, stopped wobbling, stepping and sliding, as an effect's
            # end stops it (Reference::Player#finish_effect). +channel+ is where its channel is.
            def emit_voice_stops_changing(asm, at, memory, channel)
              %i[wobbles shapes].each do |kind|
                name = kind == :wobbles ? WOBBLES : SHAPES
                next unless memory.reserved?(name)

                asm.lea(at.call(name), asm.a(1))
                asm.clr(:w, asm.idx(1, 0, 4, :w))
              end
              return unless slides?(memory)

              asm.cmp(:w, asm.imm(Genesis::Music::SLIDING_CHANNEL), channel)
              asm.branch(:ne, "rt_voice_stops_changing_done")
              asm.clr(:l, at.call(SLIDE_CURSOR))
              asm.label("rt_voice_stops_changing_done")
            end

            # A HELD TUNE'S NOTES HOLD STILL, and an effect's move on (Reference::Player#held_still?). With
            # no effects the whole walk stops at the top; with them each voice is asked. Inline, the voice in
            # D4: on to +next_voice+ when it holds still.
            def emit_skip_voice_held_still(asm, at, memory, next_voice, label)
              return unless holds?(memory) && shares_voices?(memory)

              asm.tst(:w, at.call(TUNE_HELD))
              asm.branch(:eq, label)
              asm.jsr(asm.abs_l("rt_sfx_effect_holds"))
              asm.branch(:eq, next_voice)
              asm.label(label)
            end

            # What a stopping tune's voices stop doing: all of it, but on a voice a sound effect holds, which
            # goes on as the effect's (Reference::Player#silence_song).
            def emit_tune_voices_stop_changing(asm, at, memory)
              blocks = [(WOBBLES if wobbles?(memory)), (SHAPES if steps_shapes?(memory)), (SWELLS if swells?(memory))].compact
              CONSOLE_PARTS.times do |voice|
                kept = "rt_music_quiet_changes_#{voice}"
                if shares_voices?(memory)
                  asm.move(:w, asm.imm(voice * 2), asm.d(4))
                  asm.jsr(asm.abs_l("rt_sfx_effect_holds"))
                  asm.branch(:ne, kept)
                end
                blocks.each { |name| asm.clr(:w, at.call(name, voice * VOICE_BYTES)) }
                asm.clr(:l, at.call(SLIDE_CURSOR)) if slides?(memory) && voice.zero?
                asm.label(kept)
              end
            end

            # rt_music_hold_tune, rt_music_release_tune: it stays where it is, or carries on.
            def emit_tune_hold(asm, at)
              asm.label("rt_music_hold_tune")
              asm.move(:w, asm.imm(1), at.call(TUNE_HELD))
              asm.rts
              asm.label("rt_music_release_tune")
              asm.clr(:w, at.call(TUNE_HELD))
              asm.rts
            end

            # rt_music_play(tune): play it from the next frame, unless it is playing already.
            # rt_music_play_now(tune): the same, and a tune that is starting plays its first frame here
            # (Reference::Player#start_song_here). rt_music_stop(): no tune.
            # rt_music_play_from_list(which, list): the song at place +which+ of song list +list+, from the
            # next frame; a place outside the list leaves the music as it is. ..._now the same, and here.
            def emit_game_side(asm, at)
              asm.label("rt_music_play")
              asm.move(:w, asm.d(0), at.call(NAMED))
              asm.rts

              asm.label("rt_music_play_now")
              asm.move(:w, asm.d(0), at.call(NAMED))
              asm.label("rt_music_start_here")
              asm.jsr(asm.abs_l("rt_music_switch"))
              asm.tst(:w, asm.d(0))
              asm.branch(:eq, "rt_music_start_here_done")
              asm.tst(:w, at.call(PLAYING))
              asm.branch(:eq, "rt_music_start_here_done")
              asm.jsr(asm.abs_l("rt_music_song_frame"))
              asm.label("rt_music_start_here_done")
              asm.rts

              asm.label("rt_music_stop")
              asm.clr(:w, at.call(NAMED))
              asm.addq(:w, 1, at.call(STOPS))
              asm.rts

              asm.label("rt_music_play_from_list")
              asm.jsr(asm.abs_l("rt_music_name_from_list"))
              asm.rts

              asm.label("rt_music_play_from_list_now")
              asm.jsr(asm.abs_l("rt_music_name_from_list"))
              asm.tst(:w, asm.d(0))
              asm.branch(:ne, "rt_music_start_here")
              asm.rts

              # rt_music_name_from_list: NAMED = the song at place D0 (32 bits) of list D1, and D0 = 1; or
              # D0 = nought, and nothing named, for a place outside the list. Compared as a number that
              # cannot be negative, below nought is past any list's end, so one test guards both.
              asm.label("rt_music_name_from_list")
              asm.lea(asm.abs_l("music_data"), asm.a(0))
              asm.moveq(0, asm.d(2))
              asm.move(:w, asm.disp(0, Genesis::Music::LISTS_AT), asm.d(2))
              asm.add(:w, asm.d(1), asm.d(1))
              asm.add(:l, asm.d(1), asm.d(2))
              asm.move(:w, asm.idx(0, 0, 2), asm.d(2))
              asm.lea(asm.idx(0, 0, 2), asm.a(1))
              asm.moveq(0, asm.d(3))
              asm.move(:w, asm.ind(1), asm.d(3))
              asm.cmp(:l, asm.d(3), asm.d(0))
              asm.branch(:cc, "rt_music_name_from_list_outside")
              asm.add(:l, asm.d(0), asm.d(0))
              asm.move(:w, asm.idx(1, 2, 0), at.call(NAMED))
              asm.moveq(1, asm.d(0))
              asm.rts
              asm.label("rt_music_name_from_list_outside")
              asm.moveq(0, asm.d(0))
              asm.rts
            end

            # rt_music_frame: one frame of the player: with sound effects, Reference::Player#advance's order:
            # the tune caught up with, the effects that outrank it, its parts, and the other effects.
            def emit_frames(asm, at, sharing, memory)
              asm.label("rt_music_frame")
              asm.jsr(asm.abs_l("rt_music_switch"))
              asm.jsr(asm.abs_l("rt_sfx_above")) if sharing
              asm.tst(:w, at.call(PLAYING))
              asm.branch(:eq, "rt_music_frame_played")
              asm.jsr(asm.abs_l("rt_music_song_frame"))
              asm.label("rt_music_frame_played")
              asm.jsr(asm.abs_l("rt_sfx_below")) if sharing
              asm.jsr(asm.abs_l("rt_music_swells")) if swells?(memory)
              asm.jsr(asm.abs_l("rt_music_slides")) if slides?(memory)
              asm.jsr(asm.abs_l("rt_music_wobbles")) if wobbles?(memory)
              asm.jsr(asm.abs_l("rt_music_shapes")) if steps_shapes?(memory)
              asm.rts
            end

            # What changes as a note plays: each kind the game's songs have.
            def emit_voice_changes(asm, at, memory)
              emit_wobbles(asm, at, memory) if wobbles?(memory)
              emit_shapes(asm, at, memory) if steps_shapes?(memory)
              emit_swells(asm, at, memory) if swells?(memory)
              emit_slides(asm, at) if slides?(memory)
            end

            # A1 = the state in block +name+ of the voice of the part at ENTRY, A0 = the note at NOTE.
            def emit_note_voice(asm, at, name)
              asm.movea(:l, at.call(ENTRY), asm.a(0))
              asm.move(:w, asm.disp(0, Genesis::Music::CHANNEL), asm.d(0))
              asm.subq(:w, 1, asm.d(0))
              asm.lsl(:w, 3, asm.d(0)) # VOICE_BYTES a voice
              asm.lea(at.call(name), asm.a(1))
              asm.lea(asm.idx(1, 0, 0, :w), asm.a(1))
              asm.movea(:l, at.call(NOTE), asm.a(0))
            end

            # A routine (+label+) that is handed a channel in D0 and clears +name+'s record for that voice:
            # the game's own sound took the voice (Reference::Player#game_sound_on).
            def emit_stop_voice_change(asm, at, label, name)
              asm.label(label)
              asm.subq(:w, 1, asm.d(0))
              asm.lsl(:w, 3, asm.d(0))
              asm.lea(at.call(name), asm.a(1))
              asm.clr(:w, asm.idx(1, 0, 0, :w))
              asm.rts
            end

            # A walk over the console's voices at VOICE_AT, the block's code for each with A1 at that voice's
            # state in block +name+ and D4 at the voice, given the label that goes on to the next.
            def emit_each_voice(asm, at, name, label)
              asm.clr(:w, at.call(VOICE_AT))
              asm.label("#{label}_voice")
              asm.move(:w, at.call(VOICE_AT), asm.d(4))
              asm.lea(at.call(name), asm.a(1))
              asm.lea(asm.idx(1, 0, 4, :w), asm.a(1))
              asm.lsr(:w, 2, asm.d(4)) # two bytes a voice, which the holders' table and the like read
              yield "#{label}_next"
              asm.label("#{label}_next")
              asm.add(:w, asm.imm(VOICE_BYTES), at.call(VOICE_AT))
              asm.cmp(:w, asm.imm(CONSOLE_PARTS * VOICE_BYTES), at.call(VOICE_AT))
              asm.branch(:ne, "#{label}_voice")
              asm.rts
            end

            # rt_music_wobbles: every wobbling voice moved on a frame, the voices in order, once everything
            # due on the frame has played (Reference::Player#step_wobbles), as IR::Tunes::Wobble#stepped counts
            # it. A held tune's notes hold still.
            def emit_wobbles(asm, at, memory)
              m = Genesis::Music
              asm.label("rt_music_wobbles")
              emit_held_tune_returns(asm, at, memory, "rt_music_wobbles_go")
              emit_each_voice(asm, at, WOBBLES, "rt_music_wobble") do |next_voice|
                asm.tst(:w, asm.disp(1, WOBBLE_RECORD))
                asm.branch(:eq, next_voice)
                emit_skip_voice_held_still(asm, at, memory, next_voice, "rt_music_wobble_moves")
                emit_reload_voice(asm, at, WOBBLES)
                asm.tst(:w, asm.disp(1, WOBBLE_WAIT))
                asm.branch(:eq, "rt_music_wobble_going")
                asm.subq(:w, 1, asm.disp(1, WOBBLE_WAIT))
                asm.bra(next_voice)
                asm.label("rt_music_wobble_going")
                asm.tst(:w, asm.disp(1, WOBBLE_LEFT))
                asm.branch(:ne, "rt_music_wobble_hold")
                asm.eor(:w, asm.imm(1), asm.disp(1, WOBBLE_RISING))
                asm.move(:w, asm.disp(1, WOBBLE_RECORD), asm.d(0))
                emit_table_place(asm, 2)
                asm.move(:w, asm.disp(2, m::WOBBLE_SPEED), asm.disp(1, WOBBLE_LEFT))
                asm.move(:w, asm.disp(2, m::WOBBLE_DOWN), asm.d(0))
                asm.tst(:w, asm.disp(1, WOBBLE_RISING))
                asm.branch(:eq, "rt_music_wobble_turn")
                asm.move(:w, asm.disp(2, m::WOBBLE_UP), asm.d(0))
                asm.label("rt_music_wobble_turn")
                asm.jsr(asm.abs_l("rt_sound_group"))
                emit_reload_voice(asm, at, WOBBLES)
                asm.label("rt_music_wobble_hold")
                asm.subq(:w, 1, asm.disp(1, WOBBLE_LEFT))
              end
              emit_stop_voice_change(asm, at, "rt_music_stop_wobble", WOBBLES)

              # rt_music_note_wobble: the voice of the part at ENTRY wobbling as the note at NOTE sets, or
              # holding still (Reference::Player#set_voice).
              asm.label("rt_music_note_wobble")
              emit_note_voice(asm, at, WOBBLES)
              # A note that slides does not wobble: the word is its slide's record.
              asm.moveq(0, asm.d(0))
              asm.move(:w, asm.disp(0, m::NOTE_VOLUME), asm.d(1))
              asm.and(:w, asm.imm(m::SLIDES), asm.d(1))
              asm.branch(:ne, "rt_music_note_wobble_says")
              asm.move(:w, asm.disp(0, m::NOTE_WOBBLE), asm.d(0))
              asm.label("rt_music_note_wobble_says")
              asm.move(:w, asm.d(0), asm.disp(1, WOBBLE_RECORD))
              asm.branch(:eq, "rt_music_note_wobble_done")
              emit_table_place(asm, 2)
              asm.move(:w, asm.disp(2, m::WOBBLE_WAITS), asm.disp(1, WOBBLE_WAIT))
              # A vibrato that carries takes the swing up where the voice's last wobble left it, which is
              # still here, however long ago it stopped (IR::Tunes::Wobble.starting).
              asm.tst(:w, asm.disp(2, m::WOBBLE_CARRIES))
              asm.branch(:ne, "rt_music_note_wobble_done")
              asm.clr(:w, asm.disp(1, WOBBLE_LEFT))
              asm.clr(:w, asm.disp(1, WOBBLE_RISING))
              asm.label("rt_music_note_wobble_done")
              asm.rts
            end

            # In a game with no effects, a held tune's voices all hold still, so its walk does not start.
            def emit_held_tune_returns(asm, at, memory, label)
              return unless holds?(memory) && !shares_voices?(memory)

              asm.tst(:w, at.call(TUNE_HELD))
              asm.branch(:eq, label)
              asm.rts
              asm.label(label)
            end

            # A1 = the state in block +name+ of the voice at VOICE_AT, again, after a call used it.
            def emit_reload_voice(asm, at, name)
              asm.move(:w, at.call(VOICE_AT), asm.d(0))
              asm.lea(at.call(name), asm.a(1))
              asm.lea(asm.idx(1, 0, 0, :w), asm.a(1))
            end

            # rt_music_shapes: every square note that steps its shapes given the shape of the frame it is on,
            # the voices in order, after the wobbles (Reference::Player#step_shapes). The record holds a group
            # for each of a note's four frames, nought where the shape stays. A shape writes nothing on a
            # PSG voice, which has the one, but the log says it.
            def emit_shapes(asm, at, memory)
              m = Genesis::Music
              asm.label("rt_music_shapes")
              emit_held_tune_returns(asm, at, memory, "rt_music_shapes_go")
              emit_each_voice(asm, at, SHAPES, "rt_music_shapes") do |next_voice|
                asm.tst(:w, asm.disp(1, SHAPE_RECORD))
                asm.branch(:eq, next_voice)
                emit_skip_voice_held_still(asm, at, memory, next_voice, "rt_music_shapes_step")
                emit_reload_voice(asm, at, SHAPES)
                asm.move(:w, asm.disp(1, SHAPE_FRAME), asm.d(1))
                asm.branch(:eq, "rt_music_shapes_on") # a note's first frame is its head's
                asm.and(:w, asm.imm(m::SHAPE_FRAMES_MASK), asm.d(1))
                asm.add(:w, asm.d(1), asm.d(1))
                asm.add(:w, asm.disp(1, SHAPE_RECORD), asm.d(1))
                asm.move(:w, asm.d(1), asm.d(0))
                emit_table_place(asm, 2)
                asm.move(:w, asm.ind(2), asm.d(0))
                asm.branch(:eq, "rt_music_shapes_on")
                asm.jsr(asm.abs_l("rt_sound_group"))
                emit_reload_voice(asm, at, SHAPES)
                asm.label("rt_music_shapes_on")
                asm.move(:w, asm.disp(1, SHAPE_FRAME), asm.d(0))
                asm.addq(:w, 1, asm.d(0))
                asm.cmp(:w, asm.imm(8), asm.d(0))
                asm.branch(:cs, "rt_music_shapes_kept")
                asm.moveq(4, asm.d(0))
                asm.label("rt_music_shapes_kept")
                asm.move(:w, asm.d(0), asm.disp(1, SHAPE_FRAME))
              end
              emit_stop_voice_change(asm, at, "rt_music_stop_shapes", SHAPES)

              # rt_music_note_shapes: the voice of the part at ENTRY stepping as the note at NOTE sets, or
              # holding its shape (Reference::Player#set_voice).
              asm.label("rt_music_note_shapes")
              emit_note_voice(asm, at, SHAPES)
              asm.move(:w, asm.disp(0, m::NOTE_SHAPES), asm.disp(1, SHAPE_RECORD))
              asm.clr(:w, asm.disp(1, SHAPE_FRAME))
              asm.rts
            end

            # rt_music_swells: every swelling note held under the music volume, the voices in order, before
            # the wobbles (Reference::Player#step_swells): struck where IR::Tunes::Swell#held_under returns, then
            # counted on a frame as Swell#stepped does. Runtime::Sound does the climbing; this only knows how
            # far it has got.
            def emit_swells(asm, at, _memory)
              m = Genesis::Music
              loudest = IR::Tunes::LOUDEST
              asm.label("rt_music_swells")
              asm.moveq(loudest, asm.d(0))
              asm.jsr(asm.abs_l("rt_music_scaled"))
              asm.move(:w, asm.d(0), at.call(SWELL_CEILING))
              emit_each_voice(asm, at, SWELLS, "rt_music_swell") do |next_voice|
                asm.tst(:w, asm.disp(1, SWELL_RECORD))
                asm.branch(:eq, next_voice)
                asm.tst(:w, asm.disp(1, SWELL_RISING))
                asm.branch(:eq, "rt_music_swell_kept")
                # Climbing: held once it reaches the ceiling, unless that is full, where it stops by itself.
                asm.move(:w, at.call(SWELL_CEILING), asm.d(0))
                asm.cmp(:w, asm.imm(loudest), asm.d(0))
                asm.branch(:cc, "rt_music_swell_count")
                asm.move(:w, asm.disp(1, SWELL_VOLUME), asm.d(1))
                asm.cmp(:w, asm.d(0), asm.d(1))
                asm.branch(:cs, "rt_music_swell_count")
                asm.bra("rt_music_swell_hold")
                # Held: struck lower if the ceiling came down, and let climb if it went up.
                asm.label("rt_music_swell_kept")
                asm.move(:w, asm.disp(1, SWELL_VOLUME), asm.d(1))
                asm.cmp(:w, at.call(SWELL_CEILING), asm.d(1))
                asm.branch(:eq, next_voice)
                asm.branch(:cc, "rt_music_swell_hold")
                asm.clr(:w, asm.disp(1, SWELL_COUNTED))
                asm.move(:w, asm.imm(1), asm.disp(1, SWELL_RISING))
                asm.move(:w, asm.imm(m::SWELL_ONWARDS), asm.d(0))
                asm.bra("rt_music_swell_strike")
                asm.label("rt_music_swell_hold")
                asm.move(:w, at.call(SWELL_CEILING), asm.disp(1, SWELL_VOLUME))
                asm.clr(:w, asm.disp(1, SWELL_COUNTED))
                asm.clr(:w, asm.disp(1, SWELL_RISING))
                asm.move(:w, asm.imm(m::SWELL_HOLDS), asm.d(0))
                asm.label("rt_music_swell_strike") # D0 = which list of the record's
                asm.add(:w, asm.disp(1, SWELL_RECORD), asm.d(0))
                asm.move(:w, asm.disp(1, SWELL_VOLUME), asm.d(1))
                asm.add(:w, asm.d(1), asm.d(1))
                asm.add(:w, asm.d(1), asm.d(0))
                emit_table_place(asm, 2)
                asm.move(:w, asm.ind(2), asm.d(0))
                asm.jsr(asm.abs_l("rt_sound_group"))
                emit_reload_voice(asm, at, SWELLS)
                asm.label("rt_music_swell_count")
                asm.tst(:w, asm.disp(1, SWELL_RISING))
                asm.branch(:eq, next_voice)
                asm.cmp(:w, asm.imm(loudest), asm.disp(1, SWELL_VOLUME))
                asm.branch(:cc, next_voice)
                asm.move(:w, asm.disp(1, SWELL_RECORD), asm.d(0))
                emit_table_place(asm, 2)
                asm.move(:w, asm.disp(2, m::SWELL_STEP), asm.d(2))
                asm.move(:w, asm.disp(1, SWELL_COUNTED), asm.d(0))
                asm.add(:w, asm.imm(IR::Tunes::COUNTED_A_FRAME), asm.d(0))
                asm.move(:w, asm.disp(1, SWELL_VOLUME), asm.d(1))
                asm.label("rt_music_swell_climb")
                asm.cmp(:w, asm.d(2), asm.d(0))
                asm.branch(:cs, "rt_music_swell_climbed")
                asm.sub(:w, asm.d(2), asm.d(0))
                asm.addq(:w, 1, asm.d(1))
                asm.cmp(:w, asm.imm(loudest), asm.d(1))
                asm.branch(:cs, "rt_music_swell_climb")
                asm.label("rt_music_swell_climbed")
                asm.move(:w, asm.d(0), asm.disp(1, SWELL_COUNTED))
                asm.move(:w, asm.d(1), asm.disp(1, SWELL_VOLUME))
              end
              emit_stop_voice_change(asm, at, "rt_music_stop_swell", SWELLS)

              # rt_music_note_swell: the voice of the part at ENTRY counting as the note at NOTE sets, from
              # its loudness at the level, or holding no swell (Reference::Player#hold_swell_under_level).
              asm.label("rt_music_note_swell")
              emit_note_voice(asm, at, SWELLS)
              asm.move(:w, asm.disp(0, m::NOTE_SWELL), asm.disp(1, SWELL_RECORD))
              asm.branch(:eq, "rt_music_note_swell_done")
              asm.move(:w, asm.disp(0, m::NOTE_VOLUME), asm.d(0))
              asm.btst(m::SLIDES.bit_length - 1, asm.d(0))
              asm.branch(:eq, "rt_music_note_swell_counts")
              # A note that slides is left to climb: striking it again would start its slide over.
              asm.clr(:w, asm.disp(1, SWELL_RECORD))
              asm.rts
              asm.label("rt_music_note_swell_counts")
              asm.and(:w, asm.imm(m::RINGS_ALONE - 1), asm.d(0))
              asm.move(:l, asm.a(1), asm.pre(M68000::SP))
              asm.jsr(asm.abs_l("rt_music_scaled"))
              asm.movea(:l, asm.post(M68000::SP), asm.a(1))
              asm.move(:w, asm.d(0), asm.disp(1, SWELL_VOLUME))
              asm.clr(:w, asm.disp(1, SWELL_COUNTED))
              asm.move(:w, asm.imm(1), asm.disp(1, SWELL_RISING))
              asm.label("rt_music_note_swell_done")
              asm.rts
            end

            # rt_music_slides: the sliding note's frame played from its record, every frame the player runs,
            # since on the Advance the voice moves by itself even under `hold_music`.
            # rt_music_note_slide: the record of the note at NOTE taken up, or nothing, when the part at ENTRY
            # plays on the one voice that slides.
            def emit_slides(asm, at)
              m = Genesis::Music
              asm.label("rt_music_slides")
              asm.tst(:l, at.call(SLIDE_CURSOR))
              asm.branch(:eq, "rt_music_slides_done")
              asm.movea(:l, at.call(SLIDE_CURSOR), asm.a(1))
              asm.move(:w, asm.post(1), asm.d(0))
              asm.move(:l, asm.a(1), at.call(SLIDE_CURSOR))
              asm.cmp(:w, asm.imm(m::SLIDE_END), asm.d(0))
              asm.branch(:eq, "rt_music_slides_over")
              asm.tst(:w, asm.d(0))
              asm.branch(:eq, "rt_music_slides_done")
              asm.jmp(asm.abs_l("rt_sound_group"))
              asm.label("rt_music_slides_over")
              asm.clr(:l, at.call(SLIDE_CURSOR))
              asm.label("rt_music_slides_done")
              asm.rts

              asm.label("rt_music_note_slide")
              asm.movea(:l, at.call(ENTRY), asm.a(0))
              asm.cmp(:w, asm.imm(m::SLIDING_CHANNEL), asm.disp(0, m::CHANNEL))
              asm.branch(:ne, "rt_music_note_slide_done")
              asm.movea(:l, at.call(NOTE), asm.a(1))
              asm.move(:w, asm.disp(1, m::NOTE_VOLUME), asm.d(0))
              asm.btst(m::SLIDES.bit_length - 1, asm.d(0))
              asm.branch(:ne, "rt_music_note_slides")
              asm.clr(:l, at.call(SLIDE_CURSOR))
              asm.rts
              asm.label("rt_music_note_slides")
              asm.move(:w, asm.disp(1, m::NOTE_WOBBLE), asm.d(0))
              emit_table_place(asm, 1)
              asm.move(:l, asm.a(1), at.call(SLIDE_CURSOR))
              asm.label("rt_music_note_slide_done")
              asm.rts
            end

            # rt_music_switch: caught up with the tune the game names (Reference::Player#switch_to_wanted_song).
            # D0 is 1 when that changed what is playing, nought when not.
            def emit_switch(asm, at, memory, level_at, sharing, recorded)
              m = Genesis::Music
              asm.label("rt_music_switch")
              asm.move(:w, at.call(ENDED), asm.d(0))
              asm.branch(:eq, "rt_music_switch_live")
              asm.cmp(:w, at.call(NAMED), asm.d(0))
              asm.branch(:ne, "rt_music_switch_forget")
              asm.move(:w, at.call(STOPS), asm.d(0))
              asm.cmp(:w, at.call(STOPS_SEEN), asm.d(0))
              asm.branch(:ne, "rt_music_switch_forget")
              # Still named, and no stop since: the tune that ended stays quiet.
              asm.tst(:w, at.call(PLAYING))
              asm.branch(:eq, "rt_music_switch_ended")
              asm.jsr(asm.abs_l("rt_music_quiet"))
              asm.label("rt_music_switch_ended")
              asm.clr(:w, at.call(PLAYING))
              asm.moveq(0, asm.d(0))
              asm.rts
              asm.label("rt_music_switch_forget")
              asm.clr(:w, at.call(ENDED))
              asm.label("rt_music_switch_live")
              asm.move(:w, at.call(NAMED), asm.d(0))
              asm.cmp(:w, at.call(PLAYING), asm.d(0))
              asm.branch(:ne, "rt_music_switch_change")
              asm.move(:w, at.call(STOPS), asm.d(0))
              asm.cmp(:w, at.call(STOPS_SEEN), asm.d(0))
              asm.branch(:ne, "rt_music_switch_change")
              asm.moveq(0, asm.d(0))
              asm.rts
              asm.label("rt_music_switch_change")
              asm.clr(:w, at.call(TUNE_HELD)) if holds?(memory)
              asm.move(:w, at.call(STOPS), at.call(STOPS_SEEN))
              asm.tst(:w, at.call(PLAYING))
              asm.branch(:eq, "rt_music_switch_quiet")
              asm.jsr(asm.abs_l("rt_music_quiet"))
              asm.label("rt_music_switch_quiet")
              asm.move(:w, at.call(NAMED), asm.d(0))
              asm.move(:w, asm.d(0), at.call(PLAYING))
              asm.branch(:eq, "rt_music_switch_changed")
              # The tune's word in the table of songs, whose place is at SONGS_AT.
              asm.subq(:w, 1, asm.d(0))
              asm.add(:w, asm.d(0), asm.d(0))
              asm.lea(asm.abs_l("music_data"), asm.a(0))
              asm.add(:w, asm.disp(0, m::SONGS_AT), asm.d(0))
              emit_table_place(asm, 1)
              asm.move(:w, asm.ind(1), asm.d(0))
              emit_table_place(asm, 1)
              asm.move(:l, asm.a(1), at.call(SONG))
              asm.clr(:w, at.call(FRAME))
              asm.clr(:w, at.call(AGAIN))
              asm.jsr(asm.abs_l("rt_music_from_the_top"))
              asm.label("rt_music_switch_changed")
              asm.moveq(1, asm.d(0))
              asm.rts

              asm.label("rt_music_from_the_top")
              PARTS.times { |part| asm.clr(:w, at.call(CURSORS, part * 2)) }
              asm.rts

              # THE PLAYING TUNE STOPS (Reference::Player#silence_song; SONG is still the tune's): the voices
              # its parts play on let go, but one a sound effect holds, which stays the effect's; every voice the
              # tune held free, no note held, and the tune's own stop logged (Music.stop_entry).
              asm.label("rt_music_quiet")
              asm.jsr(asm.abs_l("rt_recordings_release_music")) if recorded
              emit_tune_voices_stop_changing(asm, at, memory)
              if level_at
                PARTS.times do |part|
                  asm.clr(:w, at.call(HELD, part * 2))
                  asm.clr(:w, at.call(HELD_IN, part * 2))
                end
                asm.clr(:w, at.call(HELD_END))
              end
              asm.movea(:l, at.call(SONG), asm.a(0))
              asm.move(:w, asm.disp(0, m::VOICES), asm.d(0))
              Effects.emit_release_tune_voices(asm, at) if sharing
              asm.jsr(asm.abs_l("rt_sound_silence"))
              emit_group_at(asm, at.call(SONG), m::STOP_LOG)
              asm.rts
            end

            # rt_music_song_frame: each part's note whose frame has come, then the frame on
            # (Reference::Player#play_song_frame and #advance_song_frame).
            def emit_song_frame(asm, at, memory, level_at, sharing, recorded)
              m = Genesis::Music
              asm.label("rt_music_song_frame")
              asm.movea(:l, at.call(SONG), asm.a(0))
              asm.move(:w, asm.disp(0, m::PART_COUNT), at.call(PARTS_IN))
              asm.jsr(asm.abs_l("rt_music_relevel")) if level_at
              if holds?(memory) # a tune held stays on this frame, and no note of it starts
                asm.tst(:w, at.call(TUNE_HELD))
                asm.branch(:ne, "rt_music_song_frame_done")
              end
              asm.clr(:w, at.call(PART))
              asm.label("rt_music_part")
              asm.move(:w, at.call(PART), asm.d(0))
              asm.cmp(:w, at.call(PARTS_IN), asm.d(0))
              asm.branch(:cc, "rt_music_parts_done")
              asm.jsr(asm.abs_l("rt_music_entry"))
              asm.tst(:w, at.call(AGAIN))
              asm.branch(:eq, "rt_music_part_pass")
              asm.lea(asm.disp(0, m::AGAIN), asm.a(0))
              asm.label("rt_music_part_pass")
              asm.move(:w, asm.disp(0, m::NOTE_COUNT), asm.d(2))
              asm.move(:w, asm.disp(0, m::NOTES_AT), asm.d(3))
              asm.move(:w, at.call(PART), asm.d(1))
              asm.add(:w, asm.d(1), asm.d(1))
              asm.lea(at.call(CURSORS), asm.a(1))
              asm.move(:w, asm.idx(1, 0, 1, :w), asm.d(0))
              asm.cmp(:w, asm.d(2), asm.d(0))
              asm.branch(:cc, "rt_music_part_next")
              # The next note: its frame, and where its groups are.
              asm.mulu(asm.imm(m::NOTE_BYTES), asm.d(0))
              asm.and(:l, asm.imm(0xFFFF), asm.d(3))
              asm.add(:l, asm.d(3), asm.d(0))
              asm.lea(asm.abs_l("music_data"), asm.a(0))
              asm.lea(asm.idx(0, 0, 0), asm.a(1))
              asm.move(:w, asm.disp(1, m::NOTE_FRAME), asm.d(0))
              asm.cmp(:w, at.call(FRAME), asm.d(0))
              asm.branch(:ne, "rt_music_part_next")
              asm.move(:l, asm.a(1), at.call(NOTE))
              if recorded # a part that plays a recording: its note in Recordings' place
                asm.movea(:l, at.call(ENTRY), asm.a(0))
                asm.move(:w, asm.disp(0, m::CHANNEL), asm.d(0))
                asm.cmp(:w, asm.imm(m::RECORDED_CHANNEL), asm.d(0))
                asm.branch(:cs, "rt_music_part_console")
                asm.jsr(asm.abs_l("rt_music_recorded_note"))
                asm.bra("rt_music_part_passed")
                asm.label("rt_music_part_console")
              end
              if sharing
                # A voice a sound effect holds with a higher rank: the part carries on in time, silent here
                # (Reference::Player#play_song_frame).
                asm.movea(:l, at.call(SONG), asm.a(0))
                asm.move(:w, asm.disp(0, m::RANK), asm.d(0))
                Effects.emit_claim_call(asm, at)
                asm.branch(:eq, "rt_music_part_passed")
              end
              emit_group_at(asm, at.call(NOTE), m::NOTE_HEAD)
              emit_note_loudness(asm, at, memory) if level_at
              emit_group_at(asm, at.call(NOTE), m::NOTE_TAIL)
              emit_note_changes(asm, memory)
              asm.label("rt_music_part_passed")
              asm.move(:w, at.call(PART), asm.d(1))
              asm.add(:w, asm.d(1), asm.d(1))
              asm.lea(at.call(CURSORS), asm.a(1))
              asm.addq(:w, 1, asm.idx(1, 0, 1, :w))
              asm.label("rt_music_part_next")
              asm.addq(:w, 1, at.call(PART))
              asm.bra("rt_music_part")

              # rt_music_entry: ENTRY and A0 = where part PART's entry is.
              asm.label("rt_music_entry")
              asm.move(:w, at.call(PART), asm.d(0))
              asm.mulu(asm.imm(m::PART_BYTES), asm.d(0))
              asm.add(:l, at.call(SONG), asm.d(0))
              asm.add(:l, asm.imm(m::RECORD_BYTES), asm.d(0))
              asm.move(:l, asm.d(0), at.call(ENTRY))
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.rts

              emit_recorded_note(asm, at, memory, level_at) if recorded

              asm.label("rt_music_parts_done")
              asm.addq(:w, 1, at.call(FRAME))
              asm.movea(:l, at.call(SONG), asm.a(0))
              asm.move(:w, at.call(FRAME), asm.d(0))
              asm.cmp(:w, asm.disp(0, m::LENGTH), asm.d(0))
              asm.branch(:cs, "rt_music_song_frame_done")
              asm.tst(:w, asm.disp(0, m::PLAYS_ONCE))
              asm.branch(:eq, "rt_music_round")
              asm.move(:w, at.call(PLAYING), at.call(ENDED)) # a tune that plays once: ended
              asm.rts
              asm.label("rt_music_round")
              asm.move(:w, asm.disp(0, m::LOOP_FRAME), at.call(FRAME))
              asm.move(:w, asm.imm(1), at.call(AGAIN))
              asm.jsr(asm.abs_l("rt_music_from_the_top"))
              asm.label("rt_music_song_frame_done")
              asm.rts
            end

            # rt_music_recorded_note: the note at NOTE of a part that plays a recording, D0 its channel
            # (Genesis::Music::RECORDED_CHANNEL on): a note takes the place for the part (rt_recordings_note),
            # and logs itself if it found it; a rest gives the part's place back and logs itself whether the
            # part had it or not (Reference::Player#play_song_frame).
            def emit_recorded_note(asm, at, memory, level_at)
              m = Genesis::Music
              asm.label("rt_music_recorded_note")
              asm.sub(:w, asm.imm(m::RECORDED_CHANNEL - 1), asm.d(0)) # the part's own number in Recordings' place
              asm.move(:w, asm.d(0), asm.d(1))
              asm.movea(:l, at.call(NOTE), asm.a(0))
              asm.move(:w, asm.disp(0, m::NOTE_RECORDING), asm.d(2))
              asm.branch(:ne, "rt_music_recorded_note_plays")
              asm.move(:w, asm.d(1), asm.d(0))
              asm.jsr(asm.abs_l("rt_recordings_note_release"))
              asm.bra("rt_music_recorded_note_log")
              asm.label("rt_music_recorded_note_plays")
              asm.subq(:w, 1, asm.d(2))
              asm.move(:w, asm.d(2), asm.d(0))
              asm.movea(:l, at.call(SONG), asm.a(0))
              asm.move(:w, asm.disp(0, m::RANK), asm.d(2))
              asm.addq(:w, 1, asm.d(2)) # above the game's own sounds, at nought
              asm.jsr(asm.abs_l("rt_recordings_note"))
              asm.tst(:w, asm.d(0))
              asm.branch(:eq, "rt_music_recorded_note_done") # no place: not heard
              asm.label("rt_music_recorded_note_log")
              emit_group_at(asm, at.call(NOTE), m::NOTE_HEAD)
              emit_recorded_note_level(asm, at, memory) if level_at
              asm.label("rt_music_recorded_note_done")
              asm.rts
            end

            # The heard recorded note at NOTE under the music volume (Reference::Player#record_note_volume): the
            # part's record held for a new level to reach, nought for a rest, the part in HELD_ORDER, and its
            # loudness at the level logged. A Genesis plays a recording at the one loudness, so only the log
            # hears it.
            def emit_recorded_note_level(asm, at, _memory)
              m = Genesis::Music
              asm.movea(:l, at.call(NOTE), asm.a(0))
              asm.moveq(0, asm.d(3))
              asm.tst(:w, asm.disp(0, m::NOTE_RECORDING))
              asm.branch(:eq, "rt_music_recorded_level_rest")
              asm.move(:w, asm.disp(0, m::NOTE_WOBBLE), asm.d(3))
              asm.label("rt_music_recorded_level_rest")
              asm.move(:w, at.call(PART), asm.d(1))
              asm.add(:w, asm.d(1), asm.d(1))
              asm.lea(at.call(HELD), asm.a(1))
              asm.move(:w, asm.d(3), asm.idx(1, 0, 1, :w))
              emit_part_listed(asm, at, "rt_music_recorded_level_listed")
              asm.movea(:l, at.call(NOTE), asm.a(0))
              asm.move(:w, asm.disp(0, m::NOTE_WOBBLE), asm.d(0))
              asm.jsr(asm.abs_l("rt_music_level_entry"))
              asm.move(:w, asm.ind(1), asm.d(0))
              asm.jsr(asm.abs_l("rt_sound_group"))
            end

            # The part at PART (D1, two bytes a part) put at the end of HELD_ORDER, if it is not there.
            def emit_part_listed(asm, at, label)
              asm.lea(at.call(HELD_IN), asm.a(1))
              asm.tst(:w, asm.idx(1, 0, 1, :w))
              asm.branch(:ne, label)
              asm.move(:w, asm.imm(1), asm.idx(1, 0, 1, :w))
              asm.move(:w, at.call(HELD_END), asm.d(1))
              asm.lea(at.call(HELD_ORDER), asm.a(1))
              asm.move(:w, at.call(PART), asm.idx(1, 0, 1, :w))
              asm.addq(:w, 2, at.call(HELD_END))
              asm.label(label)
            end

            # A NOTE'S LOUDNESS, between its head and its tail (Genesis::Music#part_layout): its volume as
            # written held for a new level to reach, if its voice holds one, and its loudness at the level
            # written and logged.
            def emit_note_loudness(asm, at, memory)
              m = Genesis::Music
              asm.movea(:l, at.call(NOTE), asm.a(0))
              asm.move(:w, asm.disp(0, m::NOTE_VOLUME), asm.d(3))
              # A note that fades by itself is not held for a new level: one struck again would start its
              # fade over (IR::Tunes.changes_by_itself?), so the level reaches its next note.
              asm.move(:w, asm.d(3), asm.d(0))
              asm.btst(m::RINGS_ALONE.bit_length - 1, asm.d(0))
              asm.branch(:eq, "rt_music_note_may_hold")
              asm.movea(:l, at.call(ENTRY), asm.a(0))
              asm.move(:w, asm.disp(0, m::CHANNEL), asm.d(0))
              asm.jsr(asm.abs_l("rt_music_unhold"))
              asm.bra("rt_music_note_not_held")
              asm.label("rt_music_note_may_hold")
              asm.movea(:l, at.call(ENTRY), asm.a(0))
              asm.tst(:w, asm.disp(0, m::HOLDS))
              asm.branch(:eq, "rt_music_note_not_held")
              asm.move(:w, asm.d(3), asm.d(0))
              asm.and(:w, asm.imm(m::PLAIN_VOLUME | m::LEFT_ONLY | m::RIGHT_ONLY), asm.d(0))
              asm.move(:w, at.call(PART), asm.d(1))
              asm.add(:w, asm.d(1), asm.d(1))
              asm.lea(at.call(HELD), asm.a(1))
              asm.move(:w, asm.d(0), asm.idx(1, 0, 1, :w))
              emit_part_listed(asm, at, "rt_music_note_listed")
              asm.label("rt_music_note_not_held")
              asm.movea(:l, at.call(NOTE), asm.a(0))
              asm.move(:w, asm.disp(0, m::NOTE_VOLUME), asm.d(0))
              asm.and(:w, asm.imm(m::PLAIN_VOLUME | m::LEFT_ONLY | m::RIGHT_ONLY), asm.d(0))
              if swells?(memory)
                # A note that swells logs where it starts, and climbs by itself from there.
                asm.move(:w, asm.disp(0, m::NOTE_SWELL), asm.d(3))
                asm.branch(:eq, "rt_music_note_plain")
                asm.and(:w, asm.imm(m::PLAIN_VOLUME), asm.d(0))
                asm.jsr(asm.abs_l("rt_music_scaled"))
                asm.add(:w, asm.d(0), asm.d(0))
                asm.add(:w, asm.d(3), asm.d(0))
                asm.add(:w, asm.imm(m::SWELL_STARTS), asm.d(0))
                emit_table_place(asm, 2)
                asm.move(:w, asm.ind(2), asm.d(0))
                asm.jsr(asm.abs_l("rt_sound_group"))
                asm.bra("rt_music_note_loud")
                asm.label("rt_music_note_plain")
              end
              asm.jsr(asm.abs_l("rt_music_loudness"))
              asm.label("rt_music_note_loud") if swells?(memory)
            end

            # THE MUSIC VOLUME MOVED (Reference::Player#apply_music_volume): at the start of a frame of the
            # tune, before any note, every part whose voice holds a note writes and logs its loudness at the
            # new level, in the order the parts first took their voices (HELD_ORDER).
            #
            # rt_music_unhold: the playing tune's part on channel D0 taken out of HELD_ORDER, its note no longer
            # held, as a sound effect takes its voice (Reference::Player#play_effect_frame).
            #
            # rt_music_loudness: the part at ENTRY's loudness group for the volume in D0 at the level.
            # rt_music_scaled: D0 = the volume in D0 at the level (IR::Tunes.scaled_volume).
            # rt_music_level_entry: A1 = where the level's entry is in the record at place D0.
            def emit_level(asm, at, memory, level_at, recorded)
              m = Genesis::Music
              full = IR::Tunes::FULL_LEVEL
              asm.label("rt_music_relevel")
              asm.move(:w, asm.abs_l(level_at, 2), asm.d(0))
              asm.eor(:w, asm.imm(full), asm.d(0))
              asm.cmp(:w, at.call(LEVEL_SET), asm.d(0))
              asm.branch(:ne, "rt_music_relevel_moved")
              asm.rts
              asm.label("rt_music_relevel_moved")
              asm.move(:w, asm.d(0), at.call(LEVEL_SET))
              asm.clr(:w, at.call(HELD_WALK)) # where in HELD_ORDER, two bytes a part
              asm.label("rt_music_relevel_part")
              asm.move(:w, at.call(HELD_WALK), asm.d(1))
              asm.cmp(:w, at.call(HELD_END), asm.d(1))
              asm.branch(:cc, "rt_music_relevel_done")
              asm.lea(at.call(HELD_ORDER), asm.a(1))
              asm.move(:w, asm.idx(1, 0, 1, :w), at.call(PART))
              asm.move(:w, at.call(PART), asm.d(1))
              asm.add(:w, asm.d(1), asm.d(1))
              asm.lea(at.call(HELD), asm.a(1))
              asm.move(:w, asm.idx(1, 0, 1, :w), asm.d(3))
              asm.branch(:eq, "rt_music_relevel_next")
              asm.jsr(asm.abs_l("rt_music_entry"))
              if recorded
                asm.cmp(:w, asm.imm(m::RECORDED_CHANNEL), asm.disp(0, m::CHANNEL))
                asm.branch(:cs, "rt_music_relevel_console")
                asm.move(:w, asm.disp(0, m::CHANNEL), asm.d(1))
                asm.sub(:w, asm.imm(m::RECORDED_CHANNEL - 1), asm.d(1))
                asm.move(:w, asm.d(3), asm.pre(M68000::SP))
                asm.move(:w, asm.d(1), asm.d(0))
                asm.jsr(asm.abs_l("rt_recordings_sounding_for"))
                asm.move(:w, asm.post(M68000::SP), asm.d(3))
                asm.tst(:w, asm.d(0))
                asm.branch(:eq, "rt_music_relevel_next")
                asm.move(:w, asm.d(3), asm.d(0))
                asm.jsr(asm.abs_l("rt_music_level_entry"))
                asm.move(:w, asm.ind(1), asm.d(0))
                asm.jsr(asm.abs_l("rt_sound_group"))
                asm.bra("rt_music_relevel_next")
                asm.label("rt_music_relevel_console")
              end
              asm.move(:w, asm.d(3), asm.d(0))
              asm.jsr(asm.abs_l("rt_music_loudness"))
              asm.label("rt_music_relevel_next")
              asm.addq(:w, 2, at.call(HELD_WALK))
              asm.bra("rt_music_relevel_part")
              asm.label("rt_music_relevel_done")
              asm.rts

              asm.label("rt_music_level_entry")
              asm.move(:w, at.call(LEVEL_SET), asm.d(1))
              asm.eor(:w, asm.imm(full), asm.d(1))
              asm.add(:w, asm.d(1), asm.d(1))
              asm.add(:w, asm.d(1), asm.d(0))
              emit_table_place(asm, 1)
              asm.rts

              asm.label("rt_music_unhold")
              asm.tst(:w, at.call(PLAYING))
              asm.branch(:eq, "rt_music_unhold_done")
              asm.move(:w, asm.d(0), at.call(CHANNEL_FOUND))
              asm.movea(:l, at.call(SONG), asm.a(0))
              asm.move(:w, asm.disp(0, m::PART_COUNT), at.call(PARTS_IN))
              # An effect's own entry and part are its own: this finds the tune's on that channel.
              asm.move(:w, at.call(PART), asm.pre(M68000::SP))
              asm.move(:l, at.call(ENTRY), asm.pre(M68000::SP))
              asm.clr(:w, at.call(PART))
              asm.label("rt_music_unhold_find")
              asm.move(:w, at.call(PART), asm.d(0))
              asm.cmp(:w, at.call(PARTS_IN), asm.d(0))
              asm.branch(:cc, "rt_music_unhold_back")
              asm.jsr(asm.abs_l("rt_music_entry"))
              asm.move(:w, asm.disp(0, m::CHANNEL), asm.d(0))
              asm.cmp(:w, at.call(CHANNEL_FOUND), asm.d(0))
              asm.branch(:eq, "rt_music_unhold_found")
              asm.addq(:w, 1, at.call(PART))
              asm.bra("rt_music_unhold_find")
              asm.label("rt_music_unhold_found")
              asm.move(:w, at.call(PART), asm.d(0))
              asm.add(:w, asm.d(0), asm.d(0))
              asm.lea(at.call(HELD), asm.a(1))
              asm.clr(:w, asm.idx(1, 0, 0, :w))
              asm.lea(at.call(HELD_IN), asm.a(1))
              asm.tst(:w, asm.idx(1, 0, 0, :w))
              asm.branch(:eq, "rt_music_unhold_back")
              asm.clr(:w, asm.idx(1, 0, 0, :w))
              # Out of the list: every part after it moves down a place.
              asm.lea(at.call(HELD_ORDER), asm.a(1))
              asm.moveq(0, asm.d(1))
              asm.label("rt_music_unhold_seek")
              asm.move(:w, at.call(PART), asm.d(0))
              asm.cmp(:w, asm.idx(1, 0, 1, :w), asm.d(0))
              asm.branch(:eq, "rt_music_unhold_shift")
              asm.addq(:w, 2, asm.d(1))
              asm.bra("rt_music_unhold_seek")
              asm.label("rt_music_unhold_shift")
              asm.move(:w, asm.idx(1, 2, 1, :w), asm.idx(1, 0, 1, :w))
              asm.addq(:w, 2, asm.d(1))
              asm.cmp(:w, at.call(HELD_END), asm.d(1))
              asm.branch(:cs, "rt_music_unhold_shift")
              asm.subq(:w, 2, at.call(HELD_END))
              asm.label("rt_music_unhold_back")
              asm.move(:l, asm.post(M68000::SP), at.call(ENTRY))
              asm.move(:w, asm.post(M68000::SP), at.call(PART))
              asm.label("rt_music_unhold_done")
              asm.rts

              asm.label("rt_music_loudness")
              if sides?(memory)
                # The note's side in its upper bits is which of the part's lists: each is a word for each of
                # the sixteen volumes, 32 bytes.
                asm.move(:w, asm.d(0), asm.d(2))
                asm.lsr(:w, 5, asm.d(2))
                asm.and(:w, asm.imm(0x60), asm.d(2))
                asm.move(:w, asm.d(2), at.call(LOUDNESS_LIST))
              end
              asm.and(:w, asm.imm(m::PLAIN_VOLUME), asm.d(0))
              asm.jsr(asm.abs_l("rt_music_scaled"))
              asm.add(:w, asm.d(0), asm.d(0))
              asm.movea(:l, at.call(ENTRY), asm.a(0))
              asm.add(:w, asm.disp(0, m::LOUDNESS_GROUPS), asm.d(0))
              asm.add(:w, at.call(LOUDNESS_LIST), asm.d(0)) if sides?(memory)
              emit_table_place(asm, 1)
              asm.move(:w, asm.ind(1), asm.d(0))
              asm.jmp(asm.abs_l("rt_sound_group"))

              asm.label("rt_music_scaled")
              asm.move(:w, at.call(LEVEL_SET), asm.d(1))
              asm.eor(:w, asm.imm(full), asm.d(1))
              asm.mulu(asm.d(1), asm.d(0))
              asm.lsr(:w, IR::Tunes::LEVEL_SHIFT, asm.d(0))
              asm.rts
            end

            # rt_sound_group (D0 = where a group is in the table): each of its commands sent to the chips, or
            # its entry put in the sound log, until its end.
            def emit_group(asm)
              m = Genesis::Music
              asm.label("rt_sound_group")
              emit_table_place(asm, 2)
              asm.label("rt_sound_group_next")
              asm.move(:w, asm.post(2), asm.d(6))
              asm.branch(:eq, "rt_sound_group_done")
              asm.moveq(0, asm.d(0))
              asm.move(:w, asm.post(2), asm.d(0))
              asm.moveq(0, asm.d(1))
              asm.move(:w, asm.post(2), asm.d(1))
              asm.move(:l, asm.a(2), asm.pre(M68000::SP))
              Sound::ROUTINES.merge(m::GROUP_LOG => "rt_sound_log").each do |command, routine|
                skip = "rt_sound_group_not_#{command}"
                asm.cmp(:w, asm.imm(command), asm.d(6))
                asm.branch(:ne, skip)
                asm.jsr(asm.abs_l(routine))
                asm.bra("rt_sound_group_sent")
                asm.label(skip)
              end
              asm.label("rt_sound_group_sent")
              asm.movea(:l, asm.post(M68000::SP), asm.a(2))
              asm.bra("rt_sound_group_next")
              asm.label("rt_sound_group_done")
              asm.rts
            end
          end
        end
      end
    end
  end
end
