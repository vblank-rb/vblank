# frozen_string_literal: true

module VBlank
  module DSL
    # Recorded sounds
    #
    # A recorded sound is a clip of real sound played back as it was recorded, not a tone made up
    # by one of the console's tone voices. `sample` hands one back, and the game plays and stops it.
    #
    # ```ruby
    # boom = sample :boom, pcm: [0, 80, 120, 80, 0, -80, -120, -80], rate: 8000
    # boom.play if pressed(:a)
    # ```
    #
    # VBlank feeds the console's sound hardware for you, so playing a recording is only
    # `boom.play`. See Builder#sample.
    #--
    # On the Advance a recording plays through the direct-sound FIFO, fed by DMA and clocked by a
    # timer (GBATEK, "GBA Sound Channel A and B - DMA Sound").
    #++
    class Sample
      # Built by Builder#sample, which embeds the sound data.
      def initialize(builder, name)
        @builder = builder
        @name = name
      end

      # The recording's name, as given to `sample`.
      attr_reader :name

      # How loud a voice sits in the mix — from full down to silent. These are the levels
      # `play(volume:)` accepts (the same words the other sound verbs use).
      VOLUME_LEVELS = %i[full three_quarter half quarter mute].freeze

      # Check a note name (a pitch to play at, or a sample's recorded note) is one the framework
      # knows, with a friendly error naming the range. Shared by `sample note:` and `play pitch:`.
      def self.validate_note!(note, label) # :nodoc:
        return if VBlank::Audio::Music::NOTE_FREQUENCIES.key?(note)

        known = VBlank::Audio::Music::NOTE_FREQUENCIES.keys
        raise ArgumentError,
              "#{label} #{note.inspect} isn't a note — use one like :C4 or :Fs4 (range #{known.first}..#{known.last})"
      end

      # Plays the recording from its start, and returns the recording so calls chain.
      #
      # By default it plays once, at full volume. Played at another pitch, it is read faster or
      # slower, so one recorded note covers a whole keyboard; the shift is from the note given to
      # `sample note:`.
      #
      # ```ruby
      # music.play(loop: true, volume: :half)  # a quiet track that keeps going
      # piano.play(pitch: :E4)                 # the recorded note, moved to E4
      # boom.play                              # once, at full volume
      # ```
      #
      # * `loop:` - true to start again from the start each time it ends, until #stop.
      # * `volume:` - how loud it plays: `:full`, `:three_quarter`, `:half`, `:quarter` or `:mute`.
      # * `pitch:` - the note to play it at, such as `:C4` or `:Fs4`.
      def play(loop: false, volume: :full, pitch: nil)
        unless VOLUME_LEVELS.include?(volume)
          raise ArgumentError,
                "play volume #{volume.inspect} isn't a level — use one of #{VOLUME_LEVELS.join(', ')}"
        end
        Sample.validate_note!(pitch, "play pitch:") if pitch

        @builder.record_statement(IR::Build.play_sample(@name, loop: loop, volume: volume, pitch: pitch))
        self
      end

      # Stops the recording, cutting off every play of it still sounding, and returns the
      # recording.
      #
      # ```ruby
      # music.stop if pressed(:start)
      # ```
      def stop
        @builder.record_statement(IR::Build.stop_sample(@name))
        self
      end
    end
  end
end
