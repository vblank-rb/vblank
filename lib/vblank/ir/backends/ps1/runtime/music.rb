# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE MUSIC PLAYER, the Genesis's (Genesis::Runtime::Music and Effects) written again for the R3000.
          # The game only names a tune (rt_music_play) or stops it (rt_music_stop), and asks for a sound effect
          # (rt_sfx_play); the player walks each part's notes (PS1::Music, SongTable's table) a frame at a
          # time, handing each note's group of commands to the sound chip (rt_sound_group) as its frame comes.
          #
          # WHERE IT RUNS. Where a pass's wait ends (Sound's rt_sound_frame), once for every frame the pass
          # took, which is where the interpreter moves its music on too (Reference#advance_frame), after the
          # pass and by every frame it took.
          #
          # What it does each frame is Reference::Player#advance's steps, in its order: catch up with the
          # tune the game names (a different one, or a stop, quiets the old and starts the new from its first
          # frame; one that played once and ended stays quiet), the sound effects that outrank the tune, each
          # of the tune's parts' next note if its frame has come, the frame on (round to the tune's loop frame
          # at its end), and the other effects.
          #
          # WHO SOUNDS ON A VOICE. The tune and the effects share the four game voices, settled by rank
          # (SongTable, "who sounds on a voice"): a note takes a voice whose holder's rank is no higher than
          # its own, and holds it while it makes a sound (rt_sfx_claim).
          #
          # THE MUSIC VOLUME, in a game that sets it: every note's loudness is its group for its volume at the
          # level, and when the level moves, every part whose voice holds a note is struck again at the new one,
          # in the order the parts first took their voices (rt_music_relevel).
          #
          # WHAT IS IN THE REGISTERS. A group sent to the chip calls the sound routines, which change every
          # t register, so where the player has got to is in RAM, a word for each number: the tune, the part
          # and the note as addresses, and the rest as counts. Nothing is kept in a register across a call
          # but in s0 to s2, which a routine that uses them keeps on the stack.
          module Music
            NAMED = "rt music named" # The tune the game named last (PS1::Music#number), nought for none
            PLAYING = "rt music playing" # The tune playing
            STOPS = "rt music stops" # How many times the game asked stop_music
            STOPS_SEEN = "rt music stops seen" # How many of those stops the player has acted on
            ENDED = "rt music ended" # A tune that played once and reached its end
            TUNE_HELD = "rt music tune held" # 1 while the game holds the tune
            FRAME = "rt music frame" # How far into the tune, in frames
            AGAIN = "rt music again" # 1 once the tune has come round
            SONG = "rt music song" # Where the playing tune's record is, an address
            CURSORS = "rt music cursors" # Each part's next note, a word each
            PART = "rt music part" # The part being played
            PARTS_IN = "rt music parts in" # How many parts there are
            ENTRY = "rt music entry" # Where the part being played's entry is, an address
            NOTE = "rt music note" # Its note being played, an address
            # THE MUSIC VOLUME, in a game that sets it: the level the notes sounding were set at, with its
            # FULL_LEVEL bit turned over so the nought memory starts at means full; each part's note's volume
            # as written, while its voice holds it (nought for a rest, or none); and which parts' voices hold
            # one, in the order they first took one since the tune started (Reference::Player's @sounding, a
            # Hash kept in the order its keys came), as byte distances, a word a part.
            LEVEL_SET = "rt music level set"
            HELD = "rt music held"
            HELD_IN = "rt music held in"
            HELD_ORDER = "rt music held order"
            HELD_END = "rt music held end"
            HELD_WALK = "rt music held walk"
            CHANNEL_FOUND = "rt music channel found"

            # THE SOUND EFFECTS (Genesis::Runtime::Effects says each): which voice each holder holds, by
            # channel (1..4, a word each from channel 1), as the holder's rank's place; the channels in the
            # order each was first held; a claim on a voice; the tune's rank's place plus one as a frame
            # starts; the effect being played and its part and note; where in the effects' rank order a frame
            # is and where an effect's end is in HOLDER_ORDER; an effect asked for; and each effect's state.
            HOLDERS = "rt sfx holders"
            HOLDER_ORDER = "rt sfx holder order"
            HOLDER_END = "rt sfx holder end"
            HOLDER_SEEN = "rt sfx holder seen"
            CLAIM_CHANNEL = "rt sfx claim channel"
            CLAIM_RANK = "rt sfx claim rank"
            CLAIM_SOUNDS = "rt sfx claim sounds"
            TUNE_RANK = "rt sfx tune rank"
            EFFECT = "rt sfx effect"
            RECORD = "rt sfx record"
            STATE = "rt sfx state"
            SFX_PART = "rt sfx part"
            SFX_PARTS = "rt sfx parts"
            SFX_ENTRY = "rt sfx entry"
            SFX_NOTE = "rt sfx note"
            WALK = "rt sfx walk"
            RELEASE_WALK = "rt sfx release walk"
            RELEASE_RANK = "rt sfx release rank"
            RELEASE_CHANNEL = "rt sfx release channel"
            ASKED_EFFECT = "rt sfx asked effect"
            ASKED_GROUP = "rt sfx asked group"
            ASKED_PRIORITY = "rt sfx asked priority"
            OTHER = "rt sfx other"
            # Each effect's state, STATE_BYTES apart, a word each: asked for since the last frame; asked for,
            # as a frame plays it; to be cut off; sounding; how far into it; each part's next note.
            STATES = "rt sfx states"
            ASKED = 0
            ASKED_NOW = 4
            STOPPING = 8
            RUNNING = 12
            SFX_FRAME = 16
            SFX_CURSORS = 20
            STATE_BYTES = SFX_CURSORS + (PS1::Music::PARTS * 4)

            # EACH GAME VOICE'S NOTE THAT CHANGES AS IT PLAYS, VOICE_BYTES a voice, in a game with one: a
            # wobble's record (PS1::Music, SongTable#wobble_record), nought for a voice holding still, the frames
            # still to wait, the frames its swing has left, and whether it is above the note's pitch...
            WOBBLES = "rt music wobbles"
            WOBBLE_RECORD = 0
            WOBBLE_WAIT = 4
            WOBBLE_LEFT = 8
            WOBBLE_RISING = 12
            # ...a square note's shapes' record and its note's frame, kept in 0..7 so nought is its first alone...
            SHAPES = "rt music shapes"
            SHAPE_RECORD = 0
            SHAPE_FRAME = 4
            # ...and a swell's record, its loudness and its count as the interpreter keeps them (IR::Tunes::Swell).
            SWELLS = "rt music swells"
            SWELL_RECORD = 0
            SWELL_VOLUME = 4
            SWELL_COUNTED = 8
            SWELL_RISING = 12
            VOICE_BYTES = 16
            VOICE_AT = "rt music voice at" # The voice being stepped, VOICE_BYTES a voice
            SWELL_CEILING = "rt music swell ceiling"
            SLIDE_CURSOR = "rt music slide cursor" # Where the sliding note's next frame is, an address; nought when none slides

            CHANNELS = (1..4).freeze
            PARTS = PS1::Music::PARTS
            CONSOLE_PARTS = PS1::Music::CONSOLE_PARTS

            module_function

            # +follows_level+ for a game that sets the music volume; +effects+ how many sound effects it has;
            # +holds+ for one that holds its tune; and what its notes do as they play.
            def reserve(memory, follows_level: false, effects: 0, holds: false, wobbles: false, steps_shapes: false, swells: false,
                        slides: false)
              memory.reserve(TUNE_HELD, 4) if holds
              memory.reserve(SLIDE_CURSOR, 4) if slides
              memory.reserve(WOBBLES, CONSOLE_PARTS * VOICE_BYTES) if wobbles
              memory.reserve(SHAPES, CONSOLE_PARTS * VOICE_BYTES) if steps_shapes
              memory.reserve(SWELLS, CONSOLE_PARTS * VOICE_BYTES) if swells
              memory.reserve(SWELL_CEILING, 4) if swells
              memory.reserve(VOICE_AT, 4) if wobbles || steps_shapes || swells
              [NAMED, PLAYING, STOPS, STOPS_SEEN, ENDED, FRAME, AGAIN, PART, PARTS_IN, SONG, ENTRY, NOTE].each { |name| memory.reserve(name, 4) }
              memory.reserve(CURSORS, PARTS * 4)
              if effects.positive?
                [HOLDER_END, CLAIM_CHANNEL, CLAIM_RANK, CLAIM_SOUNDS, TUNE_RANK, EFFECT, RECORD, STATE, SFX_PART, SFX_PARTS, SFX_ENTRY,
                 SFX_NOTE, WALK, RELEASE_WALK, RELEASE_RANK, RELEASE_CHANNEL, ASKED_EFFECT, ASKED_GROUP, ASKED_PRIORITY,
                 OTHER].each { |name| memory.reserve(name, 4) }
                [HOLDERS, HOLDER_ORDER, HOLDER_SEEN].each { |name| memory.reserve(name, CHANNELS.size * 4) }
                memory.reserve(STATES, effects * STATE_BYTES)
              end
              return unless follows_level

              [LEVEL_SET, HELD_END, HELD_WALK, CHANNEL_FOUND].each { |name| memory.reserve(name, 4) }
              [HELD, HELD_IN].each { |name| memory.reserve(name, PARTS * 4) }
              # ...and a word past the last part, which taking a part out of a full list reads as it moves the
              # rest down.
              memory.reserve(HELD_ORDER, (PARTS + 1) * 4)
            end

            # +level_at+ is the address where a game that sets its music volume keeps it (IR::Tunes::LEVEL), or
            # nil; +effects+ how many sound effects the game has.
            def emit(asm, memory, level_at: nil, effects: 0)
              at = ->(name) { Runtime.at(memory, name) }
              sharing = effects.positive?
              holds = memory.reserved?(TUNE_HELD)
              emit_game_side(asm, at, holds)
              emit_frame(asm, at, sharing, memory)
              emit_voice_changes(asm, at, memory, holds, sharing)
              emit_switch(asm, at, holds, level_at, sharing, memory)
              emit_song_frame(asm, at, holds, level_at, sharing, memory)
              emit_level(asm, at, level_at, memory) if level_at
              emit_effects(asm, at, effects, level_at, memory) if sharing
              emit_group(asm)
            end

            # Whether the game plays recordings, so a recorded part's notes go to Runtime::Recordings' places.
            def recorded?(memory) = memory.reserved?(Recordings::PLACES_STATE)

            def wobbles?(memory) = memory.reserved?(WOBBLES)
            def steps_shapes?(memory) = memory.reserved?(SHAPES)
            def swells?(memory) = memory.reserved?(SWELLS)
            def slides?(memory) = memory.reserved?(SLIDE_CURSOR)

            # The note at ENTRY and NOTE taken up by what changes as it plays, a tune's or an effect's.
            def emit_note_changes(asm, memory)
              asm.jal("rt_music_note_wobble") if wobbles?(memory)
              asm.jal("rt_music_note_shapes") if steps_shapes?(memory)
              asm.jal("rt_music_note_swell") if swells?(memory)
              asm.jal("rt_music_note_slide") if slides?(memory)
            end

            # What changes as a note plays: each kind the game's songs have (Genesis::Runtime::Music says each,
            # in the same order).
            def emit_voice_changes(asm, at, memory, holds, sharing)
              emit_wobbles(asm, at, memory, holds, sharing) if wobbles?(memory)
              emit_shapes(asm, at, memory, holds, sharing) if steps_shapes?(memory)
              emit_swells(asm, at) if swells?(memory)
              emit_slides(asm, at) if slides?(memory)
            end

            # t1 = gp plus the voice of the part at ENTRY's place in a block, VOICE_BYTES a voice; t0 = NOTE.
            def emit_note_voice(asm, at)
              emit_field(asm, at, :t2, ENTRY, PS1::Music::CHANNEL)
              asm.addiu(:t2, :t2, -1)
              asm.sll(:t2, :t2, 4) # VOICE_BYTES a voice
              asm.addu(:t1, :t2, :gp)
              asm.lw(:t0, at.call(NOTE), :gp)
            end

            # A routine (+label+) handed a channel in a0 that clears block +name+'s record for that voice: the
            # game's own sound took the voice (Reference::Player#game_sound_on).
            def emit_stop_voice_change(asm, at, label, name)
              asm.label(label)
              asm.addiu(:t0, :a0, -1)
              asm.sll(:t0, :t0, 4)
              asm.addu(:t0, :t0, :gp)
              asm.jr(:ra) { asm.sw(:zero, at.call(name), :t0) }
            end

            # A walk over the game's voices at VOICE_AT, the block's code for each with t1 = gp plus the voice's
            # place in a block and t8 the place itself, given the label that goes on to the next.
            def emit_each_voice(asm, at, label)
              asm.sw(:zero, at.call(VOICE_AT), :gp)
              asm.label("#{label}_voice")
              emit_reload_voice(asm, at)
              yield "#{label}_next"
              asm.label("#{label}_next")
              emit_count_up(asm, at, VOICE_AT, VOICE_BYTES)
              asm.sltiu(:t1, :t0, CONSOLE_PARTS * VOICE_BYTES)
              asm.bne(:t1, :zero, "#{label}_voice")
            end

            def emit_reload_voice(asm, at)
              asm.lw(:t8, at.call(VOICE_AT), :gp)
              asm.addu(:t1, :t8, :gp)
            end

            # In a game with no effects, a held tune's voices all hold still, so its walk does not start
            # (on to +done+).
            def emit_held_tune_returns(asm, at, holds, sharing, done)
              return unless holds && !sharing

              asm.lw(:t0, at.call(TUNE_HELD), :gp)
              asm.bne(:t0, :zero, done)
            end

            # A HELD TUNE'S NOTES HOLD STILL, and an effect's move on (Reference::Player#held_still?). With effects
            # each voice is asked: on to +next_voice+ when it holds still.
            def emit_skip_voice_held_still(asm, at, holds, sharing, next_voice, label)
              return unless holds && sharing

              asm.lw(:t0, at.call(TUNE_HELD), :gp)
              asm.beq(:t0, :zero, label)
              asm.srl(:a0, :t8, 4)
              asm.jal("rt_sfx_effect_holds")
              asm.beq(:v0, :zero, next_voice)
              asm.label(label)
              emit_reload_voice(asm, at)
            end

            # rt_music_wobbles: every wobbling voice moved on a frame, the voices in order, once everything due
            # on the frame has played (Reference::Player#step_wobbles), as IR::Tunes::Wobble#stepped counts it.
            # rt_music_note_wobble: the voice of the part at ENTRY wobbling as the note at NOTE sets, or holding
            # still (Reference::Player#set_voice). A note that slides does not wobble: the word is its slide's
            # record. A vibrato that carries takes the swing up where the voice's last wobble left it.
            def emit_wobbles(asm, at, memory, holds, sharing)
              m = PS1::Music
              w = at.call(WOBBLES)
              asm.label("rt_music_wobbles")
              enter(asm)
              emit_held_tune_returns(asm, at, holds, sharing, "rt_music_wobbles_done")
              emit_each_voice(asm, at, "rt_music_wobble") do |next_voice|
                asm.lw(:t0, w + WOBBLE_RECORD, :t1)
                asm.beq(:t0, :zero, next_voice)
                emit_skip_voice_held_still(asm, at, holds, sharing, next_voice, "rt_music_wobble_moves")
                asm.lw(:t0, w + WOBBLE_WAIT, :t1)
                asm.beq(:t0, :zero, "rt_music_wobble_going")
                asm.addiu(:t0, :t0, -1)
                asm.b(next_voice) { asm.sw(:t0, w + WOBBLE_WAIT, :t1) }
                asm.label("rt_music_wobble_going")
                asm.lw(:t0, w + WOBBLE_LEFT, :t1)
                asm.bne(:t0, :zero, "rt_music_wobble_hold")
                asm.lw(:t0, w + WOBBLE_RISING, :t1)
                asm.xori(:t0, :t0, 1)
                asm.sw(:t0, w + WOBBLE_RISING, :t1)
                asm.lw(:t2, w + WOBBLE_RECORD, :t1)
                emit_table_place(asm, :t3, :t2)
                asm.lhu(:t4, m::WOBBLE_SPEED, :t3)
                asm.sw(:t4, w + WOBBLE_LEFT, :t1)
                asm.lhu(:a0, m::WOBBLE_DOWN, :t3)
                asm.beq(:t0, :zero, "rt_music_wobble_turn")
                asm.lhu(:a0, m::WOBBLE_UP, :t3)
                asm.label("rt_music_wobble_turn")
                asm.jal("rt_sound_group")
                emit_reload_voice(asm, at)
                asm.label("rt_music_wobble_hold")
                asm.lw(:t0, w + WOBBLE_LEFT, :t1)
                asm.addiu(:t0, :t0, -1)
                asm.sw(:t0, w + WOBBLE_LEFT, :t1)
              end
              asm.label("rt_music_wobbles_done")
              leave(asm)
              emit_stop_voice_change(asm, at, "rt_music_stop_wobble", WOBBLES)

              asm.label("rt_music_note_wobble")
              emit_note_voice(asm, at)
              asm.lhu(:t2, m::NOTE_VOLUME, :t0)
              asm.andi(:t2, :t2, m::SLIDES)
              asm.move(:t3, :zero)
              asm.bne(:t2, :zero, "rt_music_note_wobble_set")
              asm.lhu(:t3, m::NOTE_WOBBLE, :t0)
              asm.label("rt_music_note_wobble_set")
              asm.sw(:t3, w + WOBBLE_RECORD, :t1)
              asm.beq(:t3, :zero, "rt_music_note_wobble_done")
              emit_table_place(asm, :t4, :t3)
              asm.lhu(:t5, m::WOBBLE_WAITS, :t4)
              asm.sw(:t5, w + WOBBLE_WAIT, :t1)
              asm.lhu(:t5, m::WOBBLE_CARRIES, :t4)
              asm.bne(:t5, :zero, "rt_music_note_wobble_done")
              asm.sw(:zero, w + WOBBLE_LEFT, :t1)
              asm.sw(:zero, w + WOBBLE_RISING, :t1)
              asm.label("rt_music_note_wobble_done")
              asm.jr(:ra)
            end

            # rt_music_shapes: every square note that steps its shapes given the shape of the frame it is on, the
            # voices in order, after the wobbles (Reference::Player#step_shapes). The record holds a group for
            # each of a note's four frames, nought where the shape stays.
            # rt_music_note_shapes: the voice of the part at ENTRY stepping as the note at NOTE sets, or holding
            # its shape.
            def emit_shapes(asm, at, memory, holds, sharing)
              m = PS1::Music
              s = at.call(SHAPES)
              asm.label("rt_music_shapes")
              enter(asm)
              emit_held_tune_returns(asm, at, holds, sharing, "rt_music_shapes_done")
              emit_each_voice(asm, at, "rt_music_shapes") do |next_voice|
                asm.lw(:t0, s + SHAPE_RECORD, :t1)
                asm.beq(:t0, :zero, next_voice)
                emit_skip_voice_held_still(asm, at, holds, sharing, next_voice, "rt_music_shapes_step")
                asm.lw(:t2, s + SHAPE_FRAME, :t1)
                asm.beq(:t2, :zero, "rt_music_shapes_on") # a note's first frame is its head's
                asm.andi(:t2, :t2, m::SHAPE_FRAMES_MASK)
                asm.sll(:t2, :t2, 1)
                asm.lw(:t3, s + SHAPE_RECORD, :t1)
                asm.addu(:t2, :t2, :t3)
                emit_table_place(asm, :t4, :t2)
                asm.lhu(:a0, 0, :t4)
                asm.beq(:a0, :zero, "rt_music_shapes_on")
                asm.jal("rt_sound_group")
                emit_reload_voice(asm, at)
                asm.label("rt_music_shapes_on")
                asm.lw(:t0, s + SHAPE_FRAME, :t1)
                asm.addiu(:t0, :t0, 1)
                asm.sltiu(:t2, :t0, 8)
                asm.bne(:t2, :zero, "rt_music_shapes_kept")
                asm.li(:t0, 4)
                asm.label("rt_music_shapes_kept")
                asm.sw(:t0, s + SHAPE_FRAME, :t1)
              end
              asm.label("rt_music_shapes_done")
              leave(asm)
              emit_stop_voice_change(asm, at, "rt_music_stop_shapes", SHAPES)

              asm.label("rt_music_note_shapes")
              emit_note_voice(asm, at)
              asm.lhu(:t2, m::NOTE_SHAPES, :t0)
              asm.sw(:t2, s + SHAPE_RECORD, :t1)
              asm.jr(:ra) { asm.sw(:zero, s + SHAPE_FRAME, :t1) }
            end

            # rt_music_swells: every swelling note held under the music volume, the voices in order, before the
            # wobbles (Reference::Player#step_swells): struck where IR::Tunes::Swell#held_under returns, then
            # counted on a frame as Swell#stepped does. Runtime::Sound does the climbing; this only knows how far
            # it has got.
            # rt_music_note_swell: the voice of the part at ENTRY counting as the note at NOTE sets, from its
            # loudness at the level, or holding no swell (Reference::Player#hold_swell_under_level). A note that
            # slides is left to climb: striking it again would start its slide over.
            def emit_swells(asm, at)
              m = PS1::Music
              loudest = IR::Tunes::LOUDEST
              s = at.call(SWELLS)
              asm.label("rt_music_swells")
              enter(asm)
              asm.li(:a0, loudest)
              asm.jal("rt_music_scaled")
              asm.sw(:v0, at.call(SWELL_CEILING), :gp)
              emit_each_voice(asm, at, "rt_music_swell") do |next_voice|
                asm.lw(:t0, s + SWELL_RECORD, :t1)
                asm.beq(:t0, :zero, next_voice)
                asm.lw(:t0, s + SWELL_RISING, :t1)
                asm.beq(:t0, :zero, "rt_music_swell_kept")
                # Climbing: held once it reaches the ceiling, unless that is full, where it stops by itself.
                asm.lw(:t0, at.call(SWELL_CEILING), :gp)
                asm.sltiu(:t2, :t0, loudest)
                asm.beq(:t2, :zero, "rt_music_swell_count")
                asm.lw(:t2, s + SWELL_VOLUME, :t1)
                asm.sltu(:t3, :t2, :t0)
                asm.bne(:t3, :zero, "rt_music_swell_count")
                asm.b("rt_music_swell_hold")
                # Held: struck lower if the ceiling came down, and let climb if it went up.
                asm.label("rt_music_swell_kept")
                asm.lw(:t2, s + SWELL_VOLUME, :t1)
                asm.lw(:t0, at.call(SWELL_CEILING), :gp)
                asm.beq(:t2, :t0, next_voice)
                asm.sltu(:t3, :t2, :t0)
                asm.beq(:t3, :zero, "rt_music_swell_hold")
                asm.sw(:zero, s + SWELL_COUNTED, :t1)
                asm.li(:t3, 1)
                asm.sw(:t3, s + SWELL_RISING, :t1)
                asm.b("rt_music_swell_strike") { asm.li(:t4, m::SWELL_ONWARDS) }
                asm.label("rt_music_swell_hold")
                asm.lw(:t0, at.call(SWELL_CEILING), :gp)
                asm.sw(:t0, s + SWELL_VOLUME, :t1)
                asm.sw(:zero, s + SWELL_COUNTED, :t1)
                asm.sw(:zero, s + SWELL_RISING, :t1)
                asm.li(:t4, m::SWELL_HOLDS)
                asm.label("rt_music_swell_strike") # t4 = which list of the record's
                asm.lw(:t2, s + SWELL_RECORD, :t1)
                asm.addu(:t4, :t4, :t2)
                asm.lw(:t3, s + SWELL_VOLUME, :t1)
                asm.sll(:t3, :t3, 1)
                asm.addu(:t4, :t4, :t3)
                emit_table_place(asm, :t5, :t4)
                asm.lhu(:a0, 0, :t5)
                asm.jal("rt_sound_group")
                emit_reload_voice(asm, at)
                asm.label("rt_music_swell_count")
                asm.lw(:t0, s + SWELL_RISING, :t1)
                asm.beq(:t0, :zero, next_voice)
                asm.lw(:t2, s + SWELL_VOLUME, :t1)
                asm.sltiu(:t3, :t2, loudest)
                asm.beq(:t3, :zero, next_voice)
                asm.lw(:t3, s + SWELL_RECORD, :t1)
                emit_table_place(asm, :t4, :t3)
                asm.lhu(:t5, m::SWELL_STEP, :t4)
                asm.lw(:t0, s + SWELL_COUNTED, :t1)
                asm.addiu(:t0, :t0, IR::Tunes::COUNTED_A_FRAME)
                asm.label("rt_music_swell_climb")
                asm.sltu(:t3, :t0, :t5)
                asm.bne(:t3, :zero, "rt_music_swell_climbed")
                asm.subu(:t0, :t0, :t5)
                asm.addiu(:t2, :t2, 1)
                asm.sltiu(:t3, :t2, loudest)
                asm.bne(:t3, :zero, "rt_music_swell_climb")
                asm.label("rt_music_swell_climbed")
                asm.sw(:t0, s + SWELL_COUNTED, :t1)
                asm.sw(:t2, s + SWELL_VOLUME, :t1)
              end
              leave(asm)
              emit_stop_voice_change(asm, at, "rt_music_stop_swell", SWELLS)

              asm.label("rt_music_note_swell")
              enter(asm, %i[s0])
              emit_note_voice(asm, at)
              asm.move(:s0, :t1)
              asm.lhu(:t2, m::NOTE_SWELL, :t0)
              asm.sw(:t2, s + SWELL_RECORD, :s0)
              asm.beq(:t2, :zero, "rt_music_note_swell_done")
              asm.lhu(:t3, m::NOTE_VOLUME, :t0)
              asm.andi(:t4, :t3, m::SLIDES)
              asm.beq(:t4, :zero, "rt_music_note_swell_counts")
              asm.b("rt_music_note_swell_done") { asm.sw(:zero, s + SWELL_RECORD, :s0) }
              asm.label("rt_music_note_swell_counts")
              asm.andi(:a0, :t3, m::RINGS_ALONE - 1)
              asm.jal("rt_music_scaled")
              asm.sw(:v0, s + SWELL_VOLUME, :s0)
              asm.sw(:zero, s + SWELL_COUNTED, :s0)
              asm.li(:t0, 1)
              asm.sw(:t0, s + SWELL_RISING, :s0)
              asm.label("rt_music_note_swell_done")
              leave(asm, %i[s0])
            end

            # rt_music_slides: the sliding note's frame played from its record, every frame the player runs,
            # since on the Advance the voice moves by itself even under `hold_music`.
            # rt_music_note_slide: the record of the note at NOTE taken up, or nothing, when the part at ENTRY
            # plays on the one voice that slides.
            def emit_slides(asm, at)
              m = PS1::Music
              asm.label("rt_music_slides")
              asm.lw(:t0, at.call(SLIDE_CURSOR), :gp)
              asm.beq(:t0, :zero, "rt_music_slides_done")
              asm.lhu(:a0, 0, :t0)
              asm.addiu(:t0, :t0, 2)
              asm.sw(:t0, at.call(SLIDE_CURSOR), :gp)
              asm.li(:t1, m::SLIDE_END)
              asm.beq(:a0, :t1, "rt_music_slides_over")
              asm.beq(:a0, :zero, "rt_music_slides_done")
              asm.j("rt_sound_group")
              asm.label("rt_music_slides_over")
              asm.sw(:zero, at.call(SLIDE_CURSOR), :gp)
              asm.label("rt_music_slides_done")
              asm.jr(:ra)

              asm.label("rt_music_note_slide")
              emit_field(asm, at, :t1, ENTRY, m::CHANNEL)
              asm.li(:t2, m::SLIDING_CHANNEL)
              asm.bne(:t1, :t2, "rt_music_note_slide_done")
              asm.lw(:t0, at.call(NOTE), :gp)
              asm.lhu(:t1, m::NOTE_VOLUME, :t0)
              asm.andi(:t1, :t1, m::SLIDES)
              asm.bne(:t1, :zero, "rt_music_note_slides")
              asm.b("rt_music_note_slide_done") { asm.sw(:zero, at.call(SLIDE_CURSOR), :gp) }
              asm.label("rt_music_note_slides")
              asm.lhu(:t1, m::NOTE_WOBBLE, :t0)
              emit_table_place(asm, :t2, :t1)
              asm.sw(:t2, at.call(SLIDE_CURSOR), :gp)
              asm.label("rt_music_note_slide_done")
              asm.jr(:ra)
            end

            # The voice of channel +channel_name+ (a word) stopped wobbling, stepping and sliding, as an effect's
            # end stops it (Reference::Player#finish_effect).
            def emit_voice_stops_changing(asm, at, memory, channel_name, label)
              asm.lw(:t0, at.call(channel_name), :gp)
              [WOBBLES, SHAPES].each do |name|
                next unless memory.reserved?(name)

                asm.addiu(:t1, :t0, -1)
                asm.sll(:t1, :t1, 4)
                asm.addu(:t1, :t1, :gp)
                asm.sw(:zero, at.call(name), :t1)
              end
              return unless slides?(memory)

              asm.li(:t1, PS1::Music::SLIDING_CHANNEL)
              asm.bne(:t0, :t1, label)
              asm.sw(:zero, at.call(SLIDE_CURSOR), :gp)
              asm.label(label)
            end

            # What a stopping tune's voices stop doing: all of it, but on a voice a sound effect holds, which goes
            # on as the effect's (Reference::Player#silence_song).
            def emit_tune_voices_stop_changing(asm, at, memory, sharing)
              blocks = [WOBBLES, SHAPES, SWELLS].select { |name| memory.reserved?(name) }
              return if blocks.empty? && !slides?(memory)

              CONSOLE_PARTS.times do |voice|
                kept = "rt_music_quiet_changes_#{voice}"
                if sharing
                  asm.li(:a0, voice)
                  asm.jal("rt_sfx_effect_holds")
                  asm.bne(:v0, :zero, kept)
                end
                blocks.each { |name| asm.sw(:zero, at.call(name) + (voice * VOICE_BYTES), :gp) }
                asm.sw(:zero, at.call(SLIDE_CURSOR), :gp) if slides?(memory) && voice.zero?
                asm.label(kept)
              end
            end

            def enter(asm, saved = [])
              asm.addiu(:sp, :sp, -4 * (saved.size + 1))
              asm.sw(:ra, 0, :sp)
              saved.each_with_index { |register, i| asm.sw(register, 4 * (i + 1), :sp) }
            end

            def leave(asm, saved = [])
              asm.lw(:ra, 0, :sp)
              saved.each_with_index { |register, i| asm.lw(register, 4 * (i + 1), :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4 * (saved.size + 1)) }
            end

            # +into+ = the address of the song table's place +place+ (a register holding a halfword's worth).
            def emit_table_place(asm, into, place)
              asm.la(into, "music_data")
              asm.addu(into, into, place)
            end

            # The halfword at +field+ of the record whose address is the word +name+, into +into+.
            def emit_field(asm, at, into, name, field)
              asm.lw(into, at.call(name), :gp)
              asm.lhu(into, field, into)
            end

            # The group whose place is the halfword at +field+ of the record whose address is the word +name+,
            # sent to the chip.
            def emit_group_at(asm, at, name, field)
              emit_field(asm, at, :a0, name, field)
              asm.jal("rt_sound_group")
            end

            # The word +name+ moved on by +by+.
            def emit_count_up(asm, at, name, by = 1)
              asm.lw(:t0, at.call(name), :gp)
              asm.addiu(:t0, :t0, by)
              asm.sw(:t0, at.call(name), :gp)
            end

            # rt_music_play(a0 = tune): play it from the next frame, unless it is playing already.
            # rt_music_play_now(a0 = tune): the same, and a tune that is starting plays its first frame here
            # (Reference::Player#start_song_here). rt_music_stop(): no tune.
            # rt_music_play_from_list(a0 = which, a1 = list): the song at place +which+ of song list +list+,
            # from the next frame; a place outside the list leaves the music as it is. ..._now the same, and here.
            # rt_music_hold_tune, rt_music_release_tune: it stays where it is, or carries on.
            def emit_game_side(asm, at, holds)
              asm.label("rt_music_play")
              asm.jr(:ra) { asm.sw(:a0, at.call(NAMED), :gp) }

              asm.label("rt_music_play_now")
              asm.sw(:a0, at.call(NAMED), :gp)
              asm.label("rt_music_start_here")
              enter(asm)
              asm.jal("rt_music_switch")
              asm.beq(:v0, :zero, "rt_music_start_here_done")
              asm.lw(:t0, at.call(PLAYING), :gp)
              asm.beq(:t0, :zero, "rt_music_start_here_done")
              asm.jal("rt_music_song_frame")
              asm.label("rt_music_start_here_done")
              leave(asm)

              asm.label("rt_music_stop")
              asm.sw(:zero, at.call(NAMED), :gp)
              emit_count_up(asm, at, STOPS)
              asm.jr(:ra)

              asm.label("rt_music_play_from_list")
              asm.j("rt_music_name_from_list")

              asm.label("rt_music_play_from_list_now")
              enter(asm)
              asm.jal("rt_music_name_from_list")
              asm.beq(:v0, :zero, "rt_music_play_from_list_now_done")
              asm.jal("rt_music_start_here")
              asm.label("rt_music_play_from_list_now_done")
              leave(asm)

              # rt_music_name_from_list: NAMED = the song at place a0 of list a1, and v0 = 1; or v0 = nought,
              # and nothing named, for a place outside the list. Compared as a number that cannot be negative,
              # below nought is past any list's end, so one test guards both.
              asm.label("rt_music_name_from_list")
              emit_list_member(asm, PS1::Music::LISTS_AT, "rt_music_name_from_list_outside")
              asm.sw(:t3, at.call(NAMED), :gp)
              asm.jr(:ra) { asm.li(:v0, 1) }
              asm.label("rt_music_name_from_list_outside")
              asm.jr(:ra) { asm.move(:v0, :zero) }

              return unless holds

              asm.label("rt_music_hold_tune")
              asm.li(:t0, 1)
              asm.jr(:ra) { asm.sw(:t0, at.call(TUNE_HELD), :gp) }
              asm.label("rt_music_release_tune")
              asm.jr(:ra) { asm.sw(:zero, at.call(TUNE_HELD), :gp) }
            end

            # t3 = the number at place a0 of the list numbered a1 of the table whose list of lists is at the
            # header's +lists_at+; or on to +outside+ for a place past the list's end.
            def emit_list_member(asm, lists_at, outside)
              asm.la(:t0, "music_data")
              asm.lhu(:t1, lists_at, :t0)
              asm.sll(:t2, :a1, 1)
              asm.addu(:t1, :t1, :t2)
              asm.addu(:t1, :t0, :t1)
              asm.lhu(:t1, 0, :t1)
              asm.addu(:t1, :t0, :t1) # the list
              asm.lhu(:t2, 0, :t1) # how many it holds
              asm.sltu(:t3, :a0, :t2)
              asm.beq(:t3, :zero, outside)
              asm.sll(:t3, :a0, 1)
              asm.addu(:t3, :t1, :t3)
              asm.lhu(:t3, 2, :t3)
            end

            # rt_music_frame: one frame of the player: the tune caught up with, the effects that outrank it,
            # its parts, and the other effects (Reference::Player#advance).
            def emit_frame(asm, at, sharing, memory)
              asm.label("rt_music_frame")
              enter(asm)
              asm.jal("rt_music_switch")
              asm.jal("rt_sfx_above") if sharing
              asm.lw(:t0, at.call(PLAYING), :gp)
              asm.beq(:t0, :zero, "rt_music_frame_played")
              asm.jal("rt_music_song_frame")
              asm.label("rt_music_frame_played")
              asm.jal("rt_sfx_below") if sharing
              asm.jal("rt_music_swells") if swells?(memory)
              asm.jal("rt_music_slides") if slides?(memory)
              asm.jal("rt_music_wobbles") if wobbles?(memory)
              asm.jal("rt_music_shapes") if steps_shapes?(memory)
              leave(asm)
            end

            # rt_music_switch: caught up with the tune the game names (Reference::Player#switch_to_wanted_song).
            # v0 is 1 when that changed what is playing, nought when not.
            def emit_switch(asm, at, holds, level_at, sharing, memory)
              m = PS1::Music
              asm.label("rt_music_switch")
              enter(asm)
              asm.lw(:t0, at.call(ENDED), :gp)
              asm.beq(:t0, :zero, "rt_music_switch_live")
              asm.lw(:t1, at.call(NAMED), :gp)
              asm.bne(:t0, :t1, "rt_music_switch_forget")
              asm.lw(:t1, at.call(STOPS), :gp)
              asm.lw(:t2, at.call(STOPS_SEEN), :gp)
              asm.bne(:t1, :t2, "rt_music_switch_forget")
              # Still named, and no stop since: the tune that ended stays quiet.
              asm.lw(:t0, at.call(PLAYING), :gp)
              asm.beq(:t0, :zero, "rt_music_switch_ended")
              asm.jal("rt_music_quiet")
              asm.label("rt_music_switch_ended")
              asm.sw(:zero, at.call(PLAYING), :gp)
              asm.b("rt_music_switch_done") { asm.move(:v0, :zero) }
              asm.label("rt_music_switch_forget")
              asm.sw(:zero, at.call(ENDED), :gp)
              asm.label("rt_music_switch_live")
              asm.lw(:t0, at.call(NAMED), :gp)
              asm.lw(:t1, at.call(PLAYING), :gp)
              asm.bne(:t0, :t1, "rt_music_switch_change")
              asm.lw(:t1, at.call(STOPS), :gp)
              asm.lw(:t2, at.call(STOPS_SEEN), :gp)
              asm.bne(:t1, :t2, "rt_music_switch_change")
              asm.b("rt_music_switch_done") { asm.move(:v0, :zero) }
              asm.label("rt_music_switch_change")
              asm.sw(:zero, at.call(TUNE_HELD), :gp) if holds
              asm.lw(:t0, at.call(STOPS), :gp)
              asm.sw(:t0, at.call(STOPS_SEEN), :gp)
              asm.lw(:t0, at.call(PLAYING), :gp)
              asm.beq(:t0, :zero, "rt_music_switch_quiet")
              asm.jal("rt_music_quiet")
              asm.label("rt_music_switch_quiet")
              asm.lw(:t0, at.call(NAMED), :gp)
              asm.sw(:t0, at.call(PLAYING), :gp)
              asm.beq(:t0, :zero, "rt_music_switch_changed")
              # The tune's halfword in the table of songs, whose place is at SONGS_AT.
              asm.addiu(:t0, :t0, -1)
              asm.sll(:t0, :t0, 1)
              asm.la(:t1, "music_data")
              asm.lhu(:t2, m::SONGS_AT, :t1)
              asm.addu(:t2, :t2, :t0)
              asm.addu(:t2, :t1, :t2)
              asm.lhu(:t2, 0, :t2)
              asm.addu(:t2, :t1, :t2)
              asm.sw(:t2, at.call(SONG), :gp)
              asm.sw(:zero, at.call(FRAME), :gp)
              asm.sw(:zero, at.call(AGAIN), :gp)
              asm.jal("rt_music_from_the_top")
              asm.label("rt_music_switch_changed")
              asm.li(:v0, 1)
              asm.label("rt_music_switch_done")
              leave(asm)

              asm.label("rt_music_from_the_top")
              PARTS.times { |part| asm.sw(:zero, at.call(CURSORS) + (part * 4), :gp) }
              asm.jr(:ra)

              # THE PLAYING TUNE STOPS (Reference::Player#silence_song; SONG is still the tune's): the voices
              # its parts play on let go, but one a sound effect holds, which stays the effect's; every voice the
              # tune held free, no note held, and the tune's own stop logged (Music.stop_entry).
              asm.label("rt_music_quiet")
              enter(asm, %i[s0])
              asm.jal("rt_recordings_release_music") if recorded?(memory)
              if level_at
                PARTS.times do |part|
                  asm.sw(:zero, at.call(HELD) + (part * 4), :gp)
                  asm.sw(:zero, at.call(HELD_IN) + (part * 4), :gp)
                end
                asm.sw(:zero, at.call(HELD_END), :gp)
              end
              emit_field(asm, at, :s0, SONG, m::VOICES)
              emit_tune_voices_stop_changing(asm, at, memory, sharing)
              emit_release_tune_voices(asm, at) if sharing
              asm.move(:a0, :s0)
              asm.jal("rt_sound_silence")
              emit_group_at(asm, at, SONG, m::STOP_LOG)
              leave(asm, %i[s0])
            end

            # As the tune stops, inline: s0, the voices its parts play on, less those a sound effect holds; and
            # every voice the tune holds, or nobody does, free (Reference::Player#silence_song).
            def emit_release_tune_voices(asm, at)
              CHANNELS.each do |channel|
                kept = "rt_music_quiet_kept_#{channel}"
                done = "rt_music_quiet_done_#{channel}"
                asm.li(:a0, channel - 1)
                asm.jal("rt_sfx_effect_holds")
                asm.bne(:v0, :zero, kept)
                asm.b(done) { asm.sw(:zero, at.call(HOLDERS) + ((channel - 1) * 4), :gp) }
                asm.label(kept) # an effect's: not let go
                asm.andi(:s0, :s0, ~(1 << SPUWrites::CHANNEL_VOICES.fetch(channel)) & 0xFFFF)
                asm.label(done)
              end
            end

            # rt_music_song_frame: each part's note whose frame has come, then the frame on
            # (Reference::Player#play_song_frame and #advance_song_frame).
            def emit_song_frame(asm, at, holds, level_at, sharing, memory)
              m = PS1::Music
              asm.label("rt_music_song_frame")
              enter(asm)
              emit_field(asm, at, :t0, SONG, m::PART_COUNT)
              asm.sw(:t0, at.call(PARTS_IN), :gp)
              asm.jal("rt_music_relevel") if level_at
              if holds # a tune held stays on this frame, and no note of it starts
                asm.lw(:t0, at.call(TUNE_HELD), :gp)
                asm.bne(:t0, :zero, "rt_music_song_frame_done")
              end
              asm.sw(:zero, at.call(PART), :gp)
              asm.label("rt_music_part")
              asm.lw(:t0, at.call(PART), :gp)
              asm.lw(:t1, at.call(PARTS_IN), :gp)
              asm.sltu(:t2, :t0, :t1)
              asm.beq(:t2, :zero, "rt_music_parts_done")
              asm.jal("rt_music_entry")
              asm.lw(:t0, at.call(AGAIN), :gp)
              asm.beq(:t0, :zero, "rt_music_part_pass")
              asm.addiu(:v0, :v0, m::AGAIN)
              asm.label("rt_music_part_pass")
              asm.lhu(:t2, m::NOTE_COUNT, :v0)
              asm.lhu(:t4, m::NOTES_AT, :v0)
              asm.lw(:t0, at.call(PART), :gp)
              asm.sll(:t0, :t0, 2)
              asm.addu(:t0, :t0, :gp)
              asm.lw(:t5, at.call(CURSORS), :t0)
              asm.sltu(:t6, :t5, :t2)
              asm.beq(:t6, :zero, "rt_music_part_next")
              # The next note: its frame, and where its groups are.
              asm.sll(:t5, :t5, 4) # NOTE_BYTES a note
              asm.addu(:t5, :t5, :t4)
              emit_table_place(asm, :t6, :t5)
              asm.lhu(:t7, m::NOTE_FRAME, :t6)
              asm.lw(:t3, at.call(FRAME), :gp)
              asm.bne(:t7, :t3, "rt_music_part_next")
              asm.sw(:t6, at.call(NOTE), :gp)
              if recorded?(memory) # a part that plays a recording: its note in Recordings' places
                emit_field(asm, at, :t0, ENTRY, m::CHANNEL)
                asm.sltiu(:t1, :t0, m::RECORDED_CHANNEL)
                asm.bne(:t1, :zero, "rt_music_part_console")
                asm.jal("rt_music_recorded_note")
                asm.b("rt_music_part_passed")
                asm.label("rt_music_part_console")
              end
              if sharing
                # A voice a sound effect holds with a higher rank: the part carries on in time, silent here
                # (Reference::Player#play_song_frame).
                emit_field(asm, at, :a0, SONG, m::RANK)
                emit_claim_call(asm, at, ENTRY, NOTE)
                asm.beq(:v0, :zero, "rt_music_part_passed")
              end
              emit_group_at(asm, at, NOTE, m::NOTE_HEAD)
              asm.jal("rt_music_note_loudness") if level_at
              emit_group_at(asm, at, NOTE, m::NOTE_TAIL)
              emit_note_changes(asm, memory)
              asm.label("rt_music_part_passed")
              asm.lw(:t0, at.call(PART), :gp)
              asm.sll(:t0, :t0, 2)
              asm.addu(:t0, :t0, :gp)
              asm.lw(:t1, at.call(CURSORS), :t0)
              asm.addiu(:t1, :t1, 1)
              asm.sw(:t1, at.call(CURSORS), :t0)
              asm.label("rt_music_part_next")
              emit_count_up(asm, at, PART)
              asm.b("rt_music_part")

              asm.label("rt_music_parts_done")
              emit_count_up(asm, at, FRAME)
              asm.lw(:t1, at.call(SONG), :gp)
              asm.lhu(:t2, m::LENGTH, :t1)
              asm.sltu(:t3, :t0, :t2)
              asm.bne(:t3, :zero, "rt_music_song_frame_done")
              asm.lhu(:t2, m::PLAYS_ONCE, :t1)
              asm.beq(:t2, :zero, "rt_music_round")
              asm.lw(:t0, at.call(PLAYING), :gp) # a tune that plays once: ended
              asm.b("rt_music_song_frame_done") { asm.sw(:t0, at.call(ENDED), :gp) }
              asm.label("rt_music_round")
              asm.lhu(:t2, m::LOOP_FRAME, :t1)
              asm.sw(:t2, at.call(FRAME), :gp)
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(AGAIN), :gp)
              asm.jal("rt_music_from_the_top")
              asm.label("rt_music_song_frame_done")
              leave(asm)

              # rt_music_entry: ENTRY and v0 = where part PART's entry is.
              asm.label("rt_music_entry")
              asm.lw(:t0, at.call(PART), :gp)
              asm.sll(:t0, :t0, 4) # PART_BYTES a part
              asm.lw(:t1, at.call(SONG), :gp)
              asm.addu(:t0, :t0, :t1)
              asm.addiu(:v0, :t0, m::RECORD_BYTES)
              asm.jr(:ra) { asm.sw(:v0, at.call(ENTRY), :gp) }

              emit_recorded_note(asm, at, level_at) if recorded?(memory)
            end

            # rt_music_recorded_note: the note at NOTE of a song's part that plays a recording: a note takes a
            # place for the part (rt_recordings_note), and logs itself if it found one; a rest gives the part's
            # place back and logs itself whether the part had one or not (Reference::Player#play_song_frame).
            # The part's own number among the song's recorded parts, one up, is whose the place is.
            def emit_recorded_note(asm, at, level_at)
              m = PS1::Music
              asm.label("rt_music_recorded_note")
              enter(asm, %i[s0])
              emit_field(asm, at, :s0, ENTRY, m::CHANNEL)
              asm.addiu(:s0, :s0, -(m::RECORDED_CHANNEL - 1))
              emit_field(asm, at, :t2, NOTE, m::NOTE_RECORDING)
              asm.bne(:t2, :zero, "rt_music_recorded_note_plays")
              asm.move(:a0, :s0)
              asm.jal("rt_recordings_note_release")
              asm.b("rt_music_recorded_note_log")
              asm.label("rt_music_recorded_note_plays")
              asm.andi(:a0, :t2, ~m::GLIDES & 0xFFFF)
              asm.addiu(:a0, :a0, -1)
              asm.move(:a1, :s0)
              emit_field(asm, at, :a2, SONG, m::RANK)
              asm.addiu(:a2, :a2, 1) # above the game's own sounds, at nought
              emit_note_or_glide(asm, "rt_music_recorded_note")
              asm.beq(:v0, :zero, "rt_music_recorded_note_done") # no place: not heard
              asm.label("rt_music_recorded_note_log")
              emit_group_at(asm, at, NOTE, m::NOTE_HEAD)
              emit_recorded_note_level(asm, at) if level_at
              asm.label("rt_music_recorded_note_done")
              leave(asm, %i[s0])
            end

            # A recorded note that sounds, its row's word in t2 (SongTable::GLIDES set for one that glides): a
            # note that glides carries the part's sounding note on at its pitch (rt_recordings_glide), and any
            # other takes a place (rt_recordings_note). a0 to a2 are the row, the owner and the rank; v0 whether
            # it was heard. +label+ names the routine it is in.
            def emit_note_or_glide(asm, label)
              asm.andi(:t3, :t2, PS1::Music::GLIDES)
              asm.beq(:t3, :zero, "#{label}_strikes")
              asm.jal("rt_recordings_glide")
              asm.b("#{label}_struck")
              asm.label("#{label}_strikes")
              asm.jal("rt_recordings_note")
              asm.label("#{label}_struck")
            end

            # The recorded note at NOTE under the music volume (Reference::Player#record_note_volume): the part's
            # level record held for a new level to reach (nought for a rest), the part in HELD_ORDER, its
            # loudness at the level logged, and a note that sounds given that loudness.
            def emit_recorded_note_level(asm, at)
              m = PS1::Music
              emit_field(asm, at, :t3, NOTE, m::NOTE_RECORDING)
              asm.beq(:t3, :zero, "rt_music_recorded_level_held")
              emit_field(asm, at, :t3, NOTE, m::NOTE_WOBBLE)
              asm.label("rt_music_recorded_level_held")
              asm.lw(:t2, at.call(PART), :gp)
              asm.sll(:t2, :t2, 2)
              asm.addu(:t2, :t2, :gp)
              asm.sw(:t3, at.call(HELD), :t2)
              emit_part_listed(asm, at, "rt_music_recorded_level_listed")
              emit_field(asm, at, :a0, NOTE, m::NOTE_WOBBLE)
              emit_field(asm, at, :t3, NOTE, m::NOTE_RECORDING)
              asm.jal("rt_music_recorded_loudness")
            end

            # THE MUSIC VOLUME (Genesis::Runtime::Music#emit_level says each, in the same order).
            #
            # rt_music_note_loudness: the note at NOTE's loudness, between its head and its tail: its volume as
            # written held for a new level to reach, if its voice holds one, and its loudness at the level
            # written and logged. A note that fades by itself is not held: one struck again would start its
            # fade over (IR::Tunes.changes_by_itself?), so the level reaches its next note.
            #
            # rt_music_relevel: the level moved, so every part whose voice holds a note writes and logs its
            # loudness at the new one, in HELD_ORDER, at the start of a frame of the tune.
            #
            # rt_music_unhold(a0 = channel): the playing tune's part on that channel taken out of HELD_ORDER, its
            # note no longer held, as a sound effect takes its voice (Reference::Player#play_effect_frame).
            #
            # rt_music_loudness(a0 = volume): the part at ENTRY's loudness group for that volume at the level.
            # rt_music_scaled(a0 = volume): v0 = the volume at the level (IR::Tunes.scaled_volume).
            def emit_level(asm, at, level_at, memory)
              m = PS1::Music
              full = IR::Tunes::FULL_LEVEL
              plain = m::PLAIN_VOLUME
              sided = m::PLAIN_VOLUME | m::LEFT_ONLY | m::RIGHT_ONLY

              asm.label("rt_music_note_loudness")
              enter(asm)
              emit_field(asm, at, :t3, NOTE, m::NOTE_VOLUME)
              asm.andi(:t1, :t3, m::RINGS_ALONE)
              asm.beq(:t1, :zero, "rt_music_note_may_hold")
              emit_field(asm, at, :a0, ENTRY, m::CHANNEL)
              asm.jal("rt_music_unhold")
              asm.b("rt_music_note_not_held")
              asm.label("rt_music_note_may_hold")
              emit_field(asm, at, :t1, ENTRY, m::HOLDS)
              asm.beq(:t1, :zero, "rt_music_note_not_held")
              asm.andi(:t1, :t3, sided)
              asm.lw(:t2, at.call(PART), :gp)
              asm.sll(:t2, :t2, 2)
              asm.addu(:t2, :t2, :gp)
              asm.sw(:t1, at.call(HELD), :t2)
              emit_part_listed(asm, at, "rt_music_note_listed")
              asm.label("rt_music_note_not_held")
              emit_field(asm, at, :a0, NOTE, m::NOTE_VOLUME)
              asm.andi(:a0, :a0, sided)
              if swells?(memory)
                # A note that swells logs where it starts, and climbs by itself from there.
                emit_field(asm, at, :t3, NOTE, m::NOTE_SWELL)
                asm.beq(:t3, :zero, "rt_music_note_plain")
                asm.andi(:a0, :a0, plain)
                asm.jal("rt_music_scaled")
                asm.sll(:v0, :v0, 1)
                emit_field(asm, at, :t3, NOTE, m::NOTE_SWELL)
                asm.addu(:v0, :v0, :t3)
                asm.addiu(:v0, :v0, m::SWELL_STARTS)
                emit_table_place(asm, :t2, :v0)
                asm.lhu(:a0, 0, :t2)
                asm.jal("rt_sound_group")
                asm.b("rt_music_note_loud")
                asm.label("rt_music_note_plain")
              end
              asm.jal("rt_music_loudness")
              asm.label("rt_music_note_loud")
              leave(asm)

              if recorded?(memory)
                # rt_music_recorded_loudness(a0 = a recorded note's level record, t3 not nought when it took a
                # place): the group logging its loudness at the level, and the place it took (TAKEN) given that
                # loudness (SongTable#recorded_level_record: the logs, then the voices' volumes).
                asm.label("rt_music_recorded_loudness")
                enter(asm, %i[s0 s1])
                asm.lw(:t1, at.call(LEVEL_SET), :gp)
                asm.xori(:t1, :t1, full)
                asm.sll(:t1, :t1, 1)
                asm.addu(:t1, :t1, :a0)
                emit_table_place(asm, :s0, :t1)
                asm.move(:s1, :t3)
                asm.lhu(:a0, 0, :s0)
                asm.jal("rt_sound_group")
                asm.beq(:s1, :zero, "rt_music_recorded_loudness_done")
                asm.lhu(:a0, PS1::Music::LEVEL_VOLUMES, :s0)
                asm.jal("rt_recordings_loud")
                asm.label("rt_music_recorded_loudness_done")
                leave(asm, %i[s0 s1])
              end

              asm.label("rt_music_relevel")
              enter(asm, %i[s0])
              asm.li(:t1, level_at)
              asm.lw(:t0, 0, :t1)
              asm.xori(:t0, :t0, full)
              asm.lw(:t1, at.call(LEVEL_SET), :gp)
              asm.beq(:t0, :t1, "rt_music_relevel_done")
              asm.sw(:t0, at.call(LEVEL_SET), :gp)
              asm.sw(:zero, at.call(HELD_WALK), :gp) # where in HELD_ORDER, four bytes a part
              asm.label("rt_music_relevel_part")
              asm.lw(:t1, at.call(HELD_WALK), :gp)
              asm.lw(:t2, at.call(HELD_END), :gp)
              asm.sltu(:t3, :t1, :t2)
              asm.beq(:t3, :zero, "rt_music_relevel_done")
              asm.addu(:t1, :t1, :gp)
              asm.lw(:t0, at.call(HELD_ORDER), :t1)
              asm.sw(:t0, at.call(PART), :gp)
              asm.sll(:t0, :t0, 2)
              asm.addu(:t0, :t0, :gp)
              asm.lw(:s0, at.call(HELD), :t0)
              asm.beq(:s0, :zero, "rt_music_relevel_next")
              asm.jal("rt_music_entry")
              if recorded?(memory)
                # A recorded part's note is held only while its place still sounds it: struck at the new level
                # there, its loudness logged and its voice given it.
                asm.lhu(:t0, PS1::Music::CHANNEL, :v0)
                asm.sltiu(:t1, :t0, PS1::Music::RECORDED_CHANNEL)
                asm.bne(:t1, :zero, "rt_music_relevel_console")
                asm.addiu(:a0, :t0, -(PS1::Music::RECORDED_CHANNEL - 1))
                asm.jal("rt_recordings_sounding")
                asm.beq(:v0, :zero, "rt_music_relevel_next")
                asm.addiu(:v0, :v0, -1)
                asm.sw(:v0, at.call(Recordings::TAKEN), :gp)
                asm.move(:a0, :s0)
                asm.li(:t3, 1)
                asm.jal("rt_music_recorded_loudness")
                asm.b("rt_music_relevel_next")
                asm.label("rt_music_relevel_console")
              end
              asm.move(:a0, :s0)
              asm.jal("rt_music_loudness")
              asm.label("rt_music_relevel_next")
              emit_count_up(asm, at, HELD_WALK, 4)
              asm.b("rt_music_relevel_part")
              asm.label("rt_music_relevel_done")
              leave(asm, %i[s0])

              asm.label("rt_music_unhold")
              asm.lw(:t0, at.call(PLAYING), :gp)
              asm.bne(:t0, :zero, "rt_music_unhold_playing")
              asm.jr(:ra)
              asm.label("rt_music_unhold_playing")
              # An effect's own entry and part are its own: this finds the tune's on that channel.
              enter(asm, %i[s0 s1])
              asm.lw(:s0, at.call(PART), :gp)
              asm.lw(:s1, at.call(ENTRY), :gp)
              asm.sw(:a0, at.call(CHANNEL_FOUND), :gp)
              emit_field(asm, at, :t0, SONG, m::PART_COUNT)
              asm.sw(:t0, at.call(PARTS_IN), :gp)
              asm.sw(:zero, at.call(PART), :gp)
              asm.label("rt_music_unhold_find")
              asm.lw(:t0, at.call(PART), :gp)
              asm.lw(:t1, at.call(PARTS_IN), :gp)
              asm.sltu(:t2, :t0, :t1)
              asm.beq(:t2, :zero, "rt_music_unhold_back")
              asm.jal("rt_music_entry")
              asm.lhu(:t0, m::CHANNEL, :v0)
              asm.lw(:t1, at.call(CHANNEL_FOUND), :gp)
              asm.beq(:t0, :t1, "rt_music_unhold_found")
              emit_count_up(asm, at, PART)
              asm.b("rt_music_unhold_find")
              asm.label("rt_music_unhold_found")
              asm.lw(:t2, at.call(PART), :gp)
              asm.sll(:t0, :t2, 2)
              asm.addu(:t0, :t0, :gp)
              asm.sw(:zero, at.call(HELD), :t0)
              asm.lw(:t1, at.call(HELD_IN), :t0)
              asm.beq(:t1, :zero, "rt_music_unhold_back")
              asm.sw(:zero, at.call(HELD_IN), :t0)
              # Out of the list: every part after it moves down a place.
              asm.move(:t1, :zero)
              asm.label("rt_music_unhold_seek")
              asm.addu(:t3, :t1, :gp)
              asm.lw(:t4, at.call(HELD_ORDER), :t3)
              asm.beq(:t4, :t2, "rt_music_unhold_shift")
              asm.b("rt_music_unhold_seek") { asm.addiu(:t1, :t1, 4) }
              asm.label("rt_music_unhold_shift")
              asm.addu(:t3, :t1, :gp)
              asm.lw(:t4, at.call(HELD_ORDER) + 4, :t3)
              asm.sw(:t4, at.call(HELD_ORDER), :t3)
              asm.addiu(:t1, :t1, 4)
              asm.lw(:t5, at.call(HELD_END), :gp)
              asm.sltu(:t6, :t1, :t5)
              asm.bne(:t6, :zero, "rt_music_unhold_shift")
              emit_count_up(asm, at, HELD_END, -4)
              asm.label("rt_music_unhold_back")
              asm.sw(:s0, at.call(PART), :gp)
              asm.sw(:s1, at.call(ENTRY), :gp)
              leave(asm, %i[s0 s1])

              # A note's side in its upper bits is which of the part's lists of loudness groups: each list is a
              # halfword for each of the sixteen volumes, 32 bytes, and a part with no notes from one side has
              # the one list.
              asm.label("rt_music_loudness")
              enter(asm, %i[s0])
              asm.srl(:s0, :a0, 5)
              asm.andi(:s0, :s0, 0x60)
              asm.andi(:a0, :a0, plain)
              asm.jal("rt_music_scaled")
              asm.sll(:v0, :v0, 1)
              asm.addu(:v0, :v0, :s0)
              emit_field(asm, at, :t1, ENTRY, m::LOUDNESS_GROUPS)
              asm.addu(:t1, :t1, :v0)
              emit_table_place(asm, :t2, :t1)
              asm.lhu(:a0, 0, :t2)
              asm.jal("rt_sound_group")
              leave(asm, %i[s0])

              asm.label("rt_music_scaled")
              asm.lw(:t1, at.call(LEVEL_SET), :gp)
              asm.xori(:t1, :t1, full)
              asm.multu(:a0, :t1)
              asm.mflo(:v0)
              asm.jr(:ra) { asm.srl(:v0, :v0, IR::Tunes::LEVEL_SHIFT) }
            end

            # The part at PART put at the end of HELD_ORDER, if it is not there; t2 is gp plus its place.
            def emit_part_listed(asm, at, label)
              asm.lw(:t1, at.call(HELD_IN), :t2)
              asm.bne(:t1, :zero, label)
              asm.li(:t1, 1)
              asm.sw(:t1, at.call(HELD_IN), :t2)
              asm.lw(:t3, at.call(HELD_END), :gp)
              asm.addu(:t4, :t3, :gp)
              asm.lw(:t5, at.call(PART), :gp)
              asm.sw(:t5, at.call(HELD_ORDER), :t4)
              asm.addiu(:t3, :t3, 4)
              asm.sw(:t3, at.call(HELD_END), :gp)
              asm.label(label)
            end

            # A call of rt_sfx_claim, inline, by the rank's place in a0, for the part whose entry and note are at
            # the words +entry+ and +note+: v0 is 1 when the note takes the voice, nought when a holder of a
            # higher rank keeps it.
            def emit_claim_call(asm, at, entry, note)
              m = PS1::Music
              asm.sw(:a0, at.call(CLAIM_RANK), :gp)
              emit_field(asm, at, :t0, entry, m::CHANNEL)
              asm.sw(:t0, at.call(CLAIM_CHANNEL), :gp)
              emit_field(asm, at, :t0, note, m::NOTE_SOUNDS)
              asm.sw(:t0, at.call(CLAIM_SOUNDS), :gp)
              asm.jal("rt_sfx_claim")
            end

            # THE SOUND EFFECTS (Genesis::Runtime::Effects says each routine, in the same order).
            def emit_effects(asm, at, count, level_at, memory)
              emit_effect_holds(asm, at)
              emit_sfx_game_side(asm, at, count)
              emit_sfx_passes(asm, at, count)
              emit_sfx_frame(asm, at, level_at, memory)
              emit_sfx_finish(asm, at, memory)
              emit_claim(asm, at)
              emit_select(asm, at)
            end

            # rt_sfx_effect_holds(a0 = a channel less one): v0 not nought when a sound effect holds that voice,
            # rather than the tune or nobody.
            def emit_effect_holds(asm, at)
              asm.label("rt_sfx_effect_holds")
              asm.sll(:t0, :a0, 2)
              asm.addu(:t0, :t0, :gp)
              asm.lw(:t0, at.call(HOLDERS), :t0)
              asm.sll(:t0, :t0, 1)
              asm.la(:t1, "music_data")
              asm.lhu(:t2, PS1::Music::RANK_KINDS_AT, :t1)
              asm.addu(:t2, :t2, :t0)
              asm.addu(:t2, :t1, :t2)
              asm.lhu(:v0, 0, :t2)
              asm.jr(:ra)
            end

            # rt_sfx_play(a0 = which, a1 = list): the effect at place +which+ of effect list +list+ starts at the
            # next frame (Reference::Player#request_effect); rt_sfx_play_now, here (Reference::Player#start_effect_here).
            def emit_sfx_game_side(asm, at, count)
              m = PS1::Music
              asm.label("rt_sfx_play")
              asm.j("rt_sfx_request")

              asm.label("rt_sfx_play_now")
              enter(asm)
              asm.jal("rt_sfx_request")
              asm.beq(:v0, :zero, "rt_sfx_play_now_done")
              asm.lw(:a0, at.call(ASKED_EFFECT), :gp)
              asm.jal("rt_sfx_select")
              asm.sw(:zero, ASKED, :v1)
              # Every effect, in rank order: this one plays its first frame; one of a group waiting to be cut
              # off is cut off here.
              asm.sw(:zero, at.call(WALK), :gp)
              asm.label("rt_sfx_play_now_next")
              asm.jal("rt_sfx_select_ranked")
              asm.lw(:t0, at.call(ASKED_EFFECT), :gp)
              asm.bne(:v0, :t0, "rt_sfx_play_now_other")
              asm.lw(:t1, at.call(STATE), :gp)
              asm.li(:t0, 1)
              asm.sw(:t0, ASKED_NOW, :t1)
              asm.jal("rt_sfx_frame")
              asm.lw(:t1, at.call(STATE), :gp)
              asm.b("rt_sfx_play_now_walk") { asm.sw(:zero, ASKED_NOW, :t1) }
              asm.label("rt_sfx_play_now_other")
              asm.lw(:t1, at.call(STATE), :gp)
              asm.lw(:t0, STOPPING, :t1)
              asm.beq(:t0, :zero, "rt_sfx_play_now_walk")
              asm.sw(:zero, STOPPING, :t1)
              asm.jal("rt_sfx_finish")
              asm.label("rt_sfx_play_now_walk")
              emit_count_up(asm, at, WALK)
              asm.sltiu(:t1, :t0, count)
              asm.bne(:t1, :zero, "rt_sfx_play_now_next")
              asm.label("rt_sfx_play_now_done")
              leave(asm)

              # rt_sfx_request(a0 = which, a1 = list): the effect asked for, v0 = 1 and ASKED_EFFECT its number;
              # or v0 = nought, for a place outside the list or an effect its group's sounding one outranks.
              asm.label("rt_sfx_request")
              enter(asm)
              emit_list_member(asm, m::EFFECT_LISTS_AT, "rt_sfx_request_none")
              asm.sw(:t3, at.call(ASKED_EFFECT), :gp)
              asm.move(:a0, :t3)
              asm.jal("rt_sfx_select")
              asm.lhu(:t0, m::EFFECT_GROUP, :v0)
              asm.sw(:t0, at.call(ASKED_GROUP), :gp)
              asm.beq(:t0, :zero, "rt_sfx_request_ask")
              asm.lhu(:t0, m::EFFECT_PRIORITY, :v0)
              asm.sw(:t0, at.call(ASKED_PRIORITY), :gp)
              # The first of its group, in the order declared, asked for or sounding and not stopping.
              asm.sw(:zero, at.call(OTHER), :gp)
              asm.label("rt_sfx_request_find")
              asm.lw(:a0, at.call(OTHER), :gp)
              asm.sltiu(:t0, :a0, count)
              asm.beq(:t0, :zero, "rt_sfx_request_ask")
              asm.jal("rt_sfx_select")
              asm.lhu(:t0, m::EFFECT_GROUP, :v0)
              asm.lw(:t1, at.call(ASKED_GROUP), :gp)
              asm.bne(:t0, :t1, "rt_sfx_request_other")
              asm.lw(:t0, ASKED, :v1)
              asm.bne(:t0, :zero, "rt_sfx_request_current")
              asm.lw(:t0, RUNNING, :v1)
              asm.beq(:t0, :zero, "rt_sfx_request_other")
              asm.lw(:t0, STOPPING, :v1)
              asm.beq(:t0, :zero, "rt_sfx_request_current")
              asm.label("rt_sfx_request_other")
              emit_count_up(asm, at, OTHER)
              asm.b("rt_sfx_request_find")
              asm.label("rt_sfx_request_current")
              asm.lhu(:t0, m::EFFECT_PRIORITY, :v0)
              asm.lw(:t1, at.call(ASKED_PRIORITY), :gp)
              asm.sltu(:t2, :t1, :t0)
              asm.bne(:t2, :zero, "rt_sfx_request_none") # the one sounding outranks it
              asm.sw(:zero, ASKED, :v1)
              asm.li(:t0, 1)
              asm.sw(:t0, STOPPING, :v1)
              asm.label("rt_sfx_request_ask")
              asm.lw(:a0, at.call(ASKED_EFFECT), :gp)
              asm.jal("rt_sfx_select")
              asm.li(:t0, 1)
              asm.sw(:t0, ASKED, :v1)
              asm.b("rt_sfx_request_done") { asm.li(:v0, 1) }
              asm.label("rt_sfx_request_none")
              asm.move(:v0, :zero)
              asm.label("rt_sfx_request_done")
              leave(asm)
            end

            # rt_sfx_above and rt_sfx_below: a frame's effects that outrank the tune, played before its parts,
            # and the rest, after (Reference::Player#advance). rt_sfx_above takes up first what was asked for
            # since the last frame. rt_sfx_select_ranked: the effect at place WALK of the rank order, selected,
            # its number in v0.
            def emit_sfx_passes(asm, at, count)
              m = PS1::Music
              asm.label("rt_sfx_above")
              count.times do |effect|
                place = at.call(STATES) + (effect * STATE_BYTES)
                asm.lw(:t0, place + ASKED, :gp)
                asm.sw(:t0, place + ASKED_NOW, :gp)
                asm.sw(:zero, place + ASKED, :gp)
              end
              asm.sw(:zero, at.call(TUNE_RANK), :gp)
              asm.lw(:t0, at.call(PLAYING), :gp)
              asm.beq(:t0, :zero, "rt_sfx_above_tune")
              emit_field(asm, at, :t0, SONG, m::RANK)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, at.call(TUNE_RANK), :gp)
              asm.label("rt_sfx_above_tune")
              emit_pass(asm, at, count, "rt_sfx_above", above: true)

              asm.label("rt_sfx_below")
              emit_pass(asm, at, count, "rt_sfx_below", above: false)

              asm.label("rt_sfx_select_ranked")
              enter(asm)
              asm.la(:t0, "music_data")
              asm.lhu(:t1, m::BY_RANK_AT, :t0)
              asm.lw(:t2, at.call(WALK), :gp)
              asm.sll(:t2, :t2, 1)
              asm.addiu(:t2, :t2, 2) # past how many there are
              asm.addu(:t1, :t1, :t2)
              asm.addu(:t1, :t0, :t1)
              asm.lhu(:a0, 0, :t1)
              asm.jal("rt_sfx_select")
              asm.lw(:v0, at.call(EFFECT), :gp)
              leave(asm)
            end

            # One pass over the effects in rank order, playing those that outrank the tune (+above+), or those
            # that do not: an effect outranks it when its rank's place is at least TUNE_RANK.
            def emit_pass(asm, at, count, name, above:)
              enter(asm)
              asm.sw(:zero, at.call(WALK), :gp)
              asm.label("#{name}_next")
              asm.jal("rt_sfx_select_ranked")
              emit_field(asm, at, :t0, RECORD, PS1::Music::EFFECT_RANK)
              asm.lw(:t1, at.call(TUNE_RANK), :gp)
              asm.sltu(:t2, :t0, :t1)
              above ? asm.bne(:t2, :zero, "#{name}_walk") : asm.beq(:t2, :zero, "#{name}_walk")
              asm.jal("rt_sfx_frame")
              asm.label("#{name}_walk")
              emit_count_up(asm, at, WALK)
              asm.sltiu(:t1, :t0, count)
              asm.bne(:t1, :zero, "#{name}_next")
              leave(asm)
            end

            # rt_sfx_frame: one frame of the effect selected (Reference::Player#play_effect_frame). Cut off, it
            # stops first; asked for, it starts from its first note; at its end, it lets go of its voices;
            # sounding, each part plays its note whose frame has come, on the voice its rank lets it take.
            def emit_sfx_frame(asm, at, level_at, memory)
              m = PS1::Music
              asm.label("rt_sfx_frame")
              enter(asm)
              asm.lw(:t1, at.call(STATE), :gp)
              asm.lw(:t0, STOPPING, :t1)
              asm.beq(:t0, :zero, "rt_sfx_frame_not_cut")
              asm.sw(:zero, STOPPING, :t1)
              asm.jal("rt_sfx_finish")
              asm.label("rt_sfx_frame_not_cut")
              asm.lw(:t1, at.call(STATE), :gp)
              asm.lw(:t0, ASKED_NOW, :t1)
              asm.beq(:t0, :zero, "rt_sfx_frame_not_asked")
              asm.li(:t0, 1)
              asm.sw(:t0, RUNNING, :t1)
              asm.sw(:zero, SFX_FRAME, :t1)
              PARTS.times { |part| asm.sw(:zero, SFX_CURSORS + (part * 4), :t1) }
              emit_group_at(asm, at, RECORD, m::EFFECT_START_LOG)
              asm.b("rt_sfx_frame_sounding")
              asm.label("rt_sfx_frame_not_asked")
              asm.lw(:t0, RUNNING, :t1)
              asm.beq(:t0, :zero, "rt_sfx_frame_sounding")
              emit_field(asm, at, :t2, RECORD, m::EFFECT_LENGTH)
              asm.lw(:t0, SFX_FRAME, :t1)
              asm.sltu(:t3, :t0, :t2)
              asm.bne(:t3, :zero, "rt_sfx_frame_sounding")
              asm.jal("rt_sfx_finish")
              asm.label("rt_sfx_frame_sounding")
              asm.lw(:t1, at.call(STATE), :gp)
              asm.lw(:t0, RUNNING, :t1)
              asm.beq(:t0, :zero, "rt_sfx_frame_end")
              emit_field(asm, at, :t0, RECORD, m::EFFECT_PART_COUNT)
              asm.sw(:t0, at.call(SFX_PARTS), :gp)
              asm.sw(:zero, at.call(SFX_PART), :gp)
              asm.label("rt_sfx_frame_part")
              asm.lw(:t0, at.call(SFX_PART), :gp)
              asm.lw(:t1, at.call(SFX_PARTS), :gp)
              asm.sltu(:t2, :t0, :t1)
              asm.beq(:t2, :zero, "rt_sfx_frame_done")
              asm.jal("rt_sfx_entry")
              asm.lw(:t1, at.call(STATE), :gp)
              asm.lw(:t0, at.call(SFX_PART), :gp)
              asm.sll(:t0, :t0, 2)
              asm.addu(:t0, :t1, :t0) # the part's next note is SFX_CURSORS from here
              asm.lw(:t2, SFX_CURSORS, :t0)
              asm.lhu(:t3, m::NOTE_COUNT, :v0)
              asm.sltu(:t4, :t2, :t3)
              asm.beq(:t4, :zero, "rt_sfx_frame_next")
              asm.sll(:t2, :t2, 4) # NOTE_BYTES a note
              asm.lhu(:t3, m::NOTES_AT, :v0)
              asm.addu(:t2, :t2, :t3)
              emit_table_place(asm, :t3, :t2)
              asm.sw(:t3, at.call(SFX_NOTE), :gp)
              asm.lhu(:t4, m::NOTE_FRAME, :t3)
              asm.lw(:t5, SFX_FRAME, :t1)
              asm.bne(:t4, :t5, "rt_sfx_frame_next")
              asm.lw(:t5, SFX_CURSORS, :t0)
              asm.addiu(:t5, :t5, 1)
              asm.sw(:t5, SFX_CURSORS, :t0)
              if recorded?(memory) # a part that plays a recording: its note in Recordings' places
                emit_field(asm, at, :t0, SFX_ENTRY, m::CHANNEL)
                asm.sltiu(:t1, :t0, m::RECORDED_CHANNEL)
                asm.bne(:t1, :zero, "rt_sfx_frame_console")
                asm.jal("rt_sfx_recorded_note")
                asm.b("rt_sfx_frame_next")
                asm.label("rt_sfx_frame_console")
              end
              emit_field(asm, at, :a0, RECORD, m::EFFECT_RANK)
              emit_claim_call(asm, at, SFX_ENTRY, SFX_NOTE)
              asm.beq(:v0, :zero, "rt_sfx_frame_next")
              if level_at # the tune's note there is no longer held for a new level to reach
                asm.lw(:a0, at.call(CLAIM_CHANNEL), :gp)
                asm.jal("rt_music_unhold")
              end
              emit_group_at(asm, at, SFX_NOTE, m::NOTE_HEAD)
              emit_group_at(asm, at, SFX_NOTE, m::NOTE_TAIL)
              # An effect's note changes as it plays as a tune's does, by the same steps, which read the note
              # from the tune's places (Reference::Player#set_voice); the tune's own walk has finished or not
              # begun whenever an effect plays, so those places are free.
              asm.lw(:t0, at.call(SFX_ENTRY), :gp)
              asm.sw(:t0, at.call(ENTRY), :gp)
              asm.lw(:t0, at.call(SFX_NOTE), :gp)
              asm.sw(:t0, at.call(NOTE), :gp)
              emit_note_changes(asm, memory)
              asm.label("rt_sfx_frame_next")
              emit_count_up(asm, at, SFX_PART)
              asm.b("rt_sfx_frame_part")
              asm.label("rt_sfx_frame_done")
              asm.lw(:t1, at.call(STATE), :gp)
              asm.lw(:t0, SFX_FRAME, :t1)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, SFX_FRAME, :t1)
              asm.label("rt_sfx_frame_end")
              leave(asm)

              # rt_sfx_entry: SFX_ENTRY and v0 = where part SFX_PART of the effect selected is.
              asm.label("rt_sfx_entry")
              asm.lw(:t0, at.call(SFX_PART), :gp)
              asm.sll(:t0, :t0, 4) # PART_BYTES a part
              asm.lw(:t1, at.call(RECORD), :gp)
              asm.addu(:t0, :t0, :t1)
              asm.addiu(:v0, :t0, m::EFFECT_RECORD_BYTES)
              asm.jr(:ra) { asm.sw(:v0, at.call(SFX_ENTRY), :gp) }
            end

            # rt_sfx_finish: the effect selected over (Reference::Player#finish_effect): not sounding, and every
            # voice it still holds free and quiet, in the order the voices were first held, each through its
            # part's group for letting the voice go.
            def emit_sfx_finish(asm, at, memory)
              m = PS1::Music
              asm.label("rt_sfx_finish")
              enter(asm)
              asm.lw(:t1, at.call(STATE), :gp)
              asm.sw(:zero, RUNNING, :t1)
              emit_field(asm, at, :t0, RECORD, m::EFFECT_RANK)
              asm.sw(:t0, at.call(RELEASE_RANK), :gp)
              asm.sw(:zero, at.call(RELEASE_WALK), :gp)
              asm.label("rt_sfx_finish_next")
              asm.lw(:t1, at.call(RELEASE_WALK), :gp)
              asm.lw(:t2, at.call(HOLDER_END), :gp)
              asm.sltu(:t3, :t1, :t2)
              asm.beq(:t3, :zero, "rt_sfx_finish_done")
              asm.addu(:t1, :t1, :gp)
              asm.lw(:t0, at.call(HOLDER_ORDER), :t1)
              asm.sw(:t0, at.call(RELEASE_CHANNEL), :gp)
              asm.addiu(:t0, :t0, -1)
              asm.sll(:t0, :t0, 2)
              asm.addu(:t0, :t0, :gp)
              asm.lw(:t2, at.call(HOLDERS), :t0)
              asm.lw(:t3, at.call(RELEASE_RANK), :gp)
              asm.bne(:t2, :t3, "rt_sfx_finish_walk")
              asm.sw(:zero, at.call(HOLDERS), :t0)
              emit_voice_stops_changing(asm, at, memory, RELEASE_CHANNEL, "rt_sfx_finish_stops_changing")
              # Its part on that voice, whose group lets the voice go.
              emit_field(asm, at, :t0, RECORD, m::EFFECT_PART_COUNT)
              asm.sw(:t0, at.call(SFX_PARTS), :gp)
              asm.sw(:zero, at.call(SFX_PART), :gp)
              asm.label("rt_sfx_finish_find")
              asm.lw(:t0, at.call(SFX_PART), :gp)
              asm.lw(:t1, at.call(SFX_PARTS), :gp)
              asm.sltu(:t2, :t0, :t1)
              asm.beq(:t2, :zero, "rt_sfx_finish_walk")
              asm.jal("rt_sfx_entry")
              asm.lhu(:t0, m::CHANNEL, :v0)
              asm.lw(:t1, at.call(RELEASE_CHANNEL), :gp)
              asm.beq(:t0, :t1, "rt_sfx_finish_found")
              emit_count_up(asm, at, SFX_PART)
              asm.b("rt_sfx_finish_find")
              asm.label("rt_sfx_finish_found")
              emit_group_at(asm, at, SFX_ENTRY, m::EFFECT_RELEASE)
              asm.label("rt_sfx_finish_walk")
              emit_count_up(asm, at, RELEASE_WALK, 4)
              asm.b("rt_sfx_finish_next")
              asm.label("rt_sfx_finish_done")
              asm.jal("rt_sfx_release_recorded") if recorded?(memory)
              leave(asm)
              emit_sfx_recorded_parts(asm, at) if recorded?(memory)
            end

            # rt_sfx_recorded_note: the note at SFX_NOTE of the selected effect's part that plays a recording, in a
            # place the effect owns (Recordings::EFFECT_OWNER): a note takes a place at the effect's rank and logs
            # itself if it found one; a note that sounds nothing gives the part's place back, and logs itself
            # only if the part had it (Reference::Player#play_effect_frame).
            #
            # rt_sfx_release_recorded: each of the selected effect's parts that plays a recording gives back the
            # place it still sounds a note in, logging its end through its release group if it had one
            # (Reference::Player#finish_effect).
            #
            # rt_sfx_owner (a0 = a channel): v0 = the owner number of the selected effect's part on it: the
            # effect's number, one up, in the high byte, and the part's place among its recorded parts, one up.
            def emit_sfx_recorded_parts(asm, at)
              m = PS1::Music
              asm.label("rt_sfx_recorded_note")
              enter(asm, %i[s0])
              emit_field(asm, at, :a0, SFX_ENTRY, m::CHANNEL)
              asm.jal("rt_sfx_owner")
              asm.move(:s0, :v0)
              emit_field(asm, at, :t2, SFX_NOTE, m::NOTE_RECORDING)
              asm.bne(:t2, :zero, "rt_sfx_recorded_note_plays")
              asm.move(:a0, :s0)
              asm.jal("rt_recordings_note_release")
              asm.b("rt_sfx_recorded_note_heard")
              asm.label("rt_sfx_recorded_note_plays")
              asm.andi(:a0, :t2, ~m::GLIDES & 0xFFFF)
              asm.addiu(:a0, :a0, -1)
              asm.move(:a1, :s0)
              emit_field(asm, at, :a2, RECORD, m::EFFECT_RANK)
              asm.addiu(:a2, :a2, 1) # above the game's own sounds, at nought
              emit_note_or_glide(asm, "rt_sfx_recorded_note")
              asm.label("rt_sfx_recorded_note_heard")
              asm.beq(:v0, :zero, "rt_sfx_recorded_note_done")
              emit_group_at(asm, at, SFX_NOTE, m::NOTE_HEAD)
              asm.label("rt_sfx_recorded_note_done")
              leave(asm, %i[s0])

              asm.label("rt_sfx_release_recorded")
              enter(asm)
              emit_field(asm, at, :t0, RECORD, m::EFFECT_PART_COUNT)
              asm.sw(:t0, at.call(SFX_PARTS), :gp)
              asm.sw(:zero, at.call(SFX_PART), :gp)
              asm.label("rt_sfx_release_recorded_part")
              asm.lw(:t0, at.call(SFX_PART), :gp)
              asm.lw(:t1, at.call(SFX_PARTS), :gp)
              asm.sltu(:t2, :t0, :t1)
              asm.beq(:t2, :zero, "rt_sfx_release_recorded_done")
              asm.jal("rt_sfx_entry")
              asm.lhu(:a0, m::CHANNEL, :v0)
              asm.sltiu(:t1, :a0, m::RECORDED_CHANNEL)
              asm.bne(:t1, :zero, "rt_sfx_release_recorded_next") # a voice of the console's own, let go above
              asm.jal("rt_sfx_owner")
              asm.move(:a0, :v0)
              asm.jal("rt_recordings_note_release")
              asm.beq(:v0, :zero, "rt_sfx_release_recorded_next")
              emit_group_at(asm, at, SFX_ENTRY, m::EFFECT_RELEASE)
              asm.label("rt_sfx_release_recorded_next")
              emit_count_up(asm, at, SFX_PART)
              asm.b("rt_sfx_release_recorded_part")
              asm.label("rt_sfx_release_recorded_done")
              leave(asm)

              asm.label("rt_sfx_owner")
              asm.addiu(:t0, :a0, -(m::RECORDED_CHANNEL - 1))
              asm.lw(:v0, at.call(EFFECT), :gp)
              asm.addiu(:v0, :v0, 1)
              asm.sll(:v0, :v0, 8)
              asm.jr(:ra) { asm.or(:v0, :v0, :t0) }
            end

            # rt_sfx_claim: may a note of rank CLAIM_RANK sound on CLAIM_CHANNEL? Yes (v0 = 1) when nobody
            # holding it outranks it, and then it holds the voice while it sounds (CLAIM_SOUNDS), where a rest
            # lets it go; nought otherwise (Reference::Player#claim_channel).
            def emit_claim(asm, at)
              asm.label("rt_sfx_claim")
              asm.lw(:t1, at.call(CLAIM_CHANNEL), :gp)
              asm.addiu(:t1, :t1, -1)
              asm.sll(:t1, :t1, 2)
              asm.addu(:t1, :t1, :gp)
              asm.lw(:t0, at.call(HOLDERS), :t1)
              asm.lw(:t2, at.call(CLAIM_RANK), :gp)
              asm.sltu(:t3, :t2, :t0)
              asm.bne(:t3, :zero, "rt_sfx_claim_refused")
              asm.move(:t0, :zero) # a rest lets the voice go
              asm.lw(:t3, at.call(CLAIM_SOUNDS), :gp)
              asm.beq(:t3, :zero, "rt_sfx_claim_hold")
              asm.move(:t0, :t2)
              asm.label("rt_sfx_claim_hold")
              asm.sw(:t0, at.call(HOLDERS), :t1)
              asm.lw(:t3, at.call(HOLDER_SEEN), :t1)
              asm.bne(:t3, :zero, "rt_sfx_claim_known")
              asm.li(:t3, 1)
              asm.sw(:t3, at.call(HOLDER_SEEN), :t1)
              asm.lw(:t4, at.call(HOLDER_END), :gp)
              asm.addu(:t5, :t4, :gp)
              asm.lw(:t6, at.call(CLAIM_CHANNEL), :gp)
              asm.sw(:t6, at.call(HOLDER_ORDER), :t5)
              asm.addiu(:t4, :t4, 4)
              asm.sw(:t4, at.call(HOLDER_END), :gp)
              asm.label("rt_sfx_claim_known")
              asm.jr(:ra) { asm.li(:v0, 1) }
              asm.label("rt_sfx_claim_refused")
              asm.jr(:ra) { asm.move(:v0, :zero) }
            end

            # rt_sfx_select(a0 = an effect's number): that effect selected: EFFECT; RECORD and v0 where its
            # record is; STATE and v1 where its state is.
            def emit_select(asm, at)
              asm.label("rt_sfx_select")
              asm.sw(:a0, at.call(EFFECT), :gp)
              asm.li(:t0, STATE_BYTES)
              asm.multu(:a0, :t0)
              asm.mflo(:t0)
              asm.addu(:t0, :t0, :gp)
              asm.addiu(:v1, :t0, at.call(STATES))
              asm.sw(:v1, at.call(STATE), :gp)
              asm.sll(:t1, :a0, 1)
              asm.la(:t2, "music_data")
              asm.lhu(:t3, PS1::Music::EFFECTS_AT, :t2)
              asm.addu(:t3, :t3, :t1)
              asm.addu(:t3, :t2, :t3)
              asm.lhu(:t3, 0, :t3)
              asm.addu(:v0, :t2, :t3)
              asm.jr(:ra) { asm.sw(:v0, at.call(RECORD), :gp) }
            end

            # rt_sound_group(a0 = where a group is in the table): each of its commands sent to the chip, or its
            # entry put in the sound log, until its end. A command is three halfwords: what it is, and the
            # numbers handed to its routine in a0 and a1, the second read signed.
            def emit_group(asm)
              asm.label("rt_sound_group")
              enter(asm, %i[s0])
              emit_table_place(asm, :s0, :a0)
              asm.label("rt_sound_group_next")
              asm.lhu(:t1, 0, :s0)
              asm.beq(:t1, :zero, "rt_sound_group_done")
              asm.lhu(:a0, 2, :s0)
              asm.lh(:a1, 4, :s0)
              asm.addiu(:s0, :s0, 6)
              Sound::ROUTINES.merge(SongTable::GROUP_LOG => "rt_sound_log").each do |command, routine|
                skip = "rt_sound_group_not_#{command}"
                asm.li(:t2, command)
                asm.bne(:t1, :t2, skip)
                asm.jal(routine)
                asm.b("rt_sound_group_next")
                asm.label(skip)
              end
              asm.b("rt_sound_group_next")
              asm.label("rt_sound_group_done")
              leave(asm, %i[s0])
            end
          end
        end
      end
    end
  end
end
