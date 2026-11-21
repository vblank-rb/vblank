# frozen_string_literal: true

module VBlank
  class Builder
    # Music
    #
    # `song` writes a tune with notes and rests, `play_song` names the one that is playing, and
    # `stop_music` silences it. Music plays on its own, a frame at a time, so a game that is too
    # busy for one frame still hears it at the right speed. Sound effects play over it.
    #
    # ```ruby
    # enable_sound
    # song :gameplay do
    #   tempo 140
    #   note :C4, :eighth
    #   note :E4, :eighth
    #   note :G4, :quarter
    #   rest :quarter
    # end
    # play_song :gameplay
    # ```
    #
    # A game whose music already exists as numbers, such as tunes decoded from another cartridge,
    # hands it over with `songs` and plays it by number instead.
    #--
    # Songs play on channel 1 (with sweep) so they don't clash with beep/SFX on channel 2; they
    # share the @sound_enabled flag with Sound. A concern of Builder, mixed in so
    # song/play_song/stop_music are flat DSL verbs. This is Builder::Music (the verbs), distinct
    # from VBlank::Audio::Music (the note/tempo notation the `song` block is written in).
    #++
    module Music
      # Writes a tune with notes and rests, and gives it a name to play by.
      #
      # The block says the tune: `tempo`, then `note` with a pitch and a length, and `rest` with
      # a length. Songs are collected as the game is built and played by `play_song`.
      #
      # ```ruby
      # song :gameplay do
      #   tempo 140
      #   note :C4, :eighth
      #   note :E4, :eighth
      #   note :G4, :quarter
      #   rest :quarter
      # end
      # ```
      #
      # * `name` - the song's name, as a symbol. A name used twice is an error.
      def song(name, &block)
        raise ArgumentError, "The song :#{name} is already defined. Use a different name." if @songs.key?(name)

        # Fully qualified: VBlank::Audio::Music is the note/tempo DSL the block is written
        # in — a bare `Music` here would mean this Builder::Music concern instead.
        ctx = VBlank::Audio::Music::SongContext.new
        ctx.instance_eval(&block)
        @songs[name] = ctx

        # In the IR a song carries its already-resolved score — one or more parts
        # (each a list of frame/frequency pairs, with its own tone and volume), the
        # song's length, and where it loops from — so every backend replays the same tune.
        record(Build.song(name, voices: ctx.voices, total_frames: ctx.total_frames, loop_frame: ctx.loop_frame))
      end

      # Names the song that is playing now.
      #
      # It plays from its start, loops, and keeps the tempo it was written at whatever the game is
      # doing. Naming the song that is already playing changes nothing, so this can be written
      # once or every frame, from a branch or a scene. Naming a different song starts that one
      # from its beginning, and `stop_music` silences it.
      #
      # A song named here starts on the next frame. A game rebuilt to match a cartridge whose
      # sound runs after its game logic writes `this_frame: true` to start it right here.
      #
      # ```ruby
      # play_song :gameplay
      # ```
      #
      # * `name` - the song's name, from `song`.
      # * `this_frame:` - `true` to start it here, and play its second frame on the next frame,
      #   instead of starting on the next frame.
      #--
      # The player runs as the screen finishes a picture, which is before the game's pass, so it
      # hears the name a frame on. With `this_frame: true` the song is taken up and its first
      # frame played right here.
      #++
      def play_song(name, this_frame: false)
        raise ArgumentError, "Sound is off. Call enable_sound before play_song." unless @sound_enabled
        unless @songs.key?(name)
          raise ArgumentError, "The song :#{name} is not defined. Define it with `song :#{name} do ... end`."
        end

        refuse_unknown_this_frame!(this_frame)
        record(Build.play_song(name, this_frame: this_frame))
      end

      # Silences the music: no song is playing after this.
      #
      # Like `play_song`, it can be called every frame. The song goes quiet once, and calling it
      # again while nothing plays does nothing. Called in the same frame as naming a song, it
      # starts that song over from its first note, so `stop_music; play_song :title` restarts a
      # tune.
      #
      # ```ruby
      # if lives == 0
      #   stop_music
      #   beep 220
      # end
      # ```
      def stop_music
        record(Build.stop_music)
      end

      # Holds the music where it is, for example while the next screen loads.
      #
      # The notes sounding ring on as they are, and nothing new starts, from the next frame.
      # `release_music` carries on from the note it stopped before, and naming another song or
      # calling `stop_music` lets it go too. Naming the song held changes nothing, so a game that
      # calls `play_song` every frame can hold its music like any other. Sound effects play on, and
      # the music volume still reaches the notes held. Holding when no song plays does nothing.
      #
      # ```ruby
      # if pressed(:start)
      #   hold_music             # the menu opens, and the tune waits
      # end
      # if pressed(:b)
      #   release_music          # back to the game, from the note it stopped before
      # end
      # ```
      def hold_music
        record(Build.hold_music(true))
      end

      # Carries on with the music that `hold_music` held, from the next frame.
      #
      # Called when the music is not held, it does nothing.
      def release_music
        record(Build.hold_music(false))
      end

      # Sets how loud the music plays, or reads how loud it is now.
      #
      # The volume goes from 0 (silent) to 100 (as written). It reaches the song playing now,
      # notes already sounding included, from the next frame, and every song after it, until it is
      # set again. Sound effects are not the music, and keep their own volume. `fade_music_out`
      # walks the volume down to silence over time.
      #
      # With no number it reads how loud the music is now, from 0 to 100. That is how a game waits
      # for a fade to finish before it switches songs, so that the switch is never heard.
      #
      # ```ruby
      # music_volume 50          # half as loud
      # music_volume slider      # whatever a settings screen holds
      #
      # if music_volume == 0
      #   track = next_track
      #   fade_music_in
      # end
      # ```
      #
      # * `amount` - from 0 to 100. A number outside that is held at the nearer end. Leave it out
      #   to read the volume instead.
      def music_volume(amount = nil)
        @music_level ||= var(IR::Tunes::LEVEL, IR::Tunes::FULL_LEVEL)
        full = IR::Tunes::FULL_LEVEL
        return @music_level * IR::Tunes::FULL_PERCENT / full if amount.nil?

        if amount.is_a?(Integer)
          @music_level = amount.clamp(0, 100) * full / 100
        else
          # Worked out, held in range, and only then stored: the player reads the level from the
          # screen's interrupt, which can land between any two statements, and a level stored
          # before it was held in range would sound for a frame at whatever came out.
          wanted = value_handle_for(:__music_level_wanted)
          wanted.store! amount * full / 100
          wanted.clamp! 0, full
          @music_level.store! wanted # one variable taking the other's number, where `=` would move the name
        end
        nil
      end

      # Hands over music as data, and returns a list to play it from by number.
      #
      # Use it for a game whose music already exists as numbers, such as tunes decoded from
      # another cartridge or read from a file, instead of written as `song` blocks. Each tune is a
      # `VBlank::Audio::Score`. A hash names them instead of numbering them.
      #
      # ```ruby
      # music = songs :music, [title_theme, file_select, forest]
      # music.play 2            # the forest
      # music.play track        # or whichever one a number the game holds names
      #
      # music = songs :music, { title: title, forest: FOREST }
      # music.play :forest
      # ```
      #
      # * `name` - the list's name, as a symbol.
      # * `scores` - the tunes, as a list or a hash.
      def songs(name, scores)
        turn_sound_on
        scores = scores_with_pack_notes(scores, "songs :#{name}")
        keys, members = record_scores(name: name, scores: scores, verb: :songs, entry: "Song") do |key, score|
          refuse_song_keeping_voices!(name, key, score)
          next unless score.group

          raise ArgumentError, "Song #{key.inspect} of :#{name} has `group:`. A group says which sound effects " \
                               "play one at a time. Songs already play one at a time. Remove `group:` " \
                               "from this Score."
        end
        record(Build.song_list(name, members))
        VBlank::DSL::SongList.new(self, name, keys)
      end

      private def refuse_song_keeping_voices!(name, key, score)
        return unless score.keeps_voices

        raise ArgumentError, "Song #{key.inspect} of :#{name} has `keeps_voices:`. It says a sound effect holds " \
                             "its voices until it ends. Remove `keeps_voices:` from this Score."
      end

      # Hands over sound effects as data, and returns a list to play them from.
      #
      # An effect is a short run of notes, the way a tune is, such as a sword hit, a door or a
      # chest. Each is played once over the song that is playing. Asked for again while it is
      # still sounding, one starts again from its first note. When an effect and the song, or two
      # effects, want the same voice at once, the one with the higher `priority:` sounds on it.
      # Each effect is a `VBlank::Audio::Score`.
      #
      # ```ruby
      # sfx = sound_effects :sfx, { hit: hit, spark: SPARK }
      # sfx.play :hit
      # sfx.play which          # or whichever one a number the game holds names
      # ```
      #
      # * `name` - the list's name, as a symbol.
      # * `scores` - the effects, as a list or a hash.
      def sound_effects(name, scores)
        turn_sound_on
        scores = scores_with_pack_notes(scores, "sound_effects :#{name}")
        keys, members = record_scores(name: name, scores: scores, verb: :sound_effects,
                                      entry: "Sound effect") do |key, score|
          refuse_looping_sound_effect!(effect: "Sound effect #{key.inspect} of :#{name}", score: score)
        end
        record(Build.sound_effect_list(name, members))
        VBlank::DSL::SoundEffectList.new(self, name, keys)
      end

      # The hook behind SoundEffectList#play: record that effect number +which+ of the list starts
      # now — a number already checked against the list when it was written, or a Value.
      # Hook behind SoundEffectList#play, documented on `sound_effects`.
      def play_sound_effect(name, which, this_frame: false)  # :nodoc:
        refuse_unknown_this_frame!(this_frame)
        record(Build.play_sound_effect(name, which: DSL::Value.node_for(which), this_frame: this_frame))
      end

      # The hook behind SongList#play: record that the tune playing now is number +which+ of
      # the list — a number already checked against the list when it was written, or a Value.
      # Hook behind SongList#play, documented on `songs`; a game writes `music.play track`.
      def play_from_list(name, which, this_frame: false)  # :nodoc:
        refuse_unknown_this_frame!(this_frame)
        record(Build.play_from_list(name, which: DSL::Value.node_for(which), this_frame: this_frame))
      end

      private

      def refuse_unknown_this_frame!(this_frame)
        return if [true, false].include?(this_frame)

        raise ArgumentError, "`this_frame:` is #{this_frame.inspect}. It must be true or false."
      end

      # A list of Scores handed to `songs` or `sound_effects` (+verb+), each one recorded as a song
      # node named for its place in the list. +entry+ is what one of them is called, for the
      # errors, and the block, when given, is handed each Score to refuse before it is recorded.
      # Returns the keys the list was given, and the names of the songs recorded.
      def record_scores(name:, scores:, verb:, entry:)
        if @songs.key?(name) || @song_lists.key?(name)
          raise ArgumentError, "There is already a song named :#{name}. Use a different name."
        end

        entries = score_entries(name: name, scores: scores, verb: verb)
        members = entries.map do |key, score|
          unless score.is_a?(VBlank::Audio::Score)
            raise ArgumentError, "#{entry} #{key.inspect} of :#{name} is #{score.inspect}, which is not a " \
                                 "VBlank::Audio::Score. Give `#{verb}` a list of Scores, or a Hash of them by name."
          end

          yield key, score if block_given?
          record_score(member: :"#{name}.#{key}", score: score)
        end
        @song_lists[name] = members
        [entries.map(&:first), members]
      end

      def record_score(member:, score:)
        @songs[member] = score
        # A part that reads its notes from the data pack as the game starts keeps its handle until here (PackScores).
        reads_at_start = score.parts.any? { |part| part.notes.is_a?(DSL::PackNotes) }
        record(Build.song(member, **(reads_at_start ? song_reading_notes_at_start(score) : score.to_song)))
        member
      end

      # Refuse a Score a sound effect cannot play. An effect plays every voice a song does, sharing
      # each with the song by priority, but it plays once, so it has no loop. How many parts it may
      # have on each is checked with a song's, on the finished program
      # (Guardrails::Checks::SongTooManyParts).
      def refuse_looping_sound_effect!(effect:, score:)
        return unless score.loop_from

        raise ArgumentError, "#{effect} has `loop_from:`. A sound effect plays one time, and does not " \
                             "loop. Remove `loop_from:` from this Score."
      end

      def score_entries(name:, scores:, verb:)
        entries =
          case scores
          when Hash then scores.to_a
          when Array then scores.each_with_index.map { |score, number| [number, score] }
          else
            raise ArgumentError, "#{verb} :#{name} takes a list of Scores, or a Hash of them by name. " \
                                 "You gave #{scores.class}."
          end
        raise ArgumentError, "#{verb} :#{name} needs at least one Score." if entries.empty?

        entries
      end
    end
  end
end
