# frozen_string_literal: true

module VBlank
  module DSL
    # A list of sound effects
    #
    # The game's sound effects, played by name or by number. `sound_effects` hands one back.
    #
    # ```ruby
    # sfx = sound_effects :sfx, { hit: hit, spark: SPARK }
    # sfx.play :hit
    # sfx.play which        # whichever effect a number the game keeps names
    # ```
    #
    # Each effect plays once, over the song that is playing, from the frame after it is asked
    # for. Asked for again while it still sounds, it starts again from its first note. A number
    # the game works out that names no effect plays nothing.
    class SoundEffectList
      include ScoreList

      # Plays a sound effect of the list, and returns the list so calls chain.
      #
      # ```ruby
      # sfx.play :spark, this_frame: true
      # ```
      #
      # * `which` - the effect: a name the list was given, a number counting from 0, or a number
      #   the game works out as it runs.
      # * `this_frame:` - true to start the effect here, its first frame played where it is asked
      #   for, rather than on the next frame.
      def play(which, this_frame: false)
        @builder.play_sound_effect(@name, entry_number(which), this_frame: this_frame)
        self
      end

      private

      def entry_noun = "sound effect"
    end
  end
end
