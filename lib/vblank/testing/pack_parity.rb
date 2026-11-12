# frozen_string_literal: true

module VBlank
  module Testing
    # ONE GAME BUILT TWO WAYS HELD TO ONE ANSWER, in a test: a port built all-in-one, its data pack
    # read as the game is built, and the same port built with its pack left out
    # (`pack_at_start: true`), handed the pack as a file as it starts. A shell is the second build,
    # so a verb that works in the first and is wrong in the second shows a player a wrong picture
    # with no error. This is the one assertion for it:
    #
    #   class ShellBuildTest < Minitest::Test
    #     include VBlank::Testing
    #     include VBlank::Testing::PackParity
    #
    #     def test_the_title_built_with_its_pack_left_out_plays_as_all_in_one
    #       assert_pack_at_start_plays_alike all_in_one, left_out, pack_file, passes: 120, presses: { 40 => [:start] }
    #     end
    #   end
    #
    # Both programs are played by `game_player`, so on the interpreter's run it holds the
    # interpreter reading the file to the interpreter holding the data, and on the run of a build
    # for a computer (C, JavaScript, Ruby) that build reading the file to the same build holding
    # the data, each checked against the interpreter as every game is. +presses+ is the buttons
    # held on each frame that has any, by its number.
    #
    # WHAT IS COMPARED: the picture after every pass, the sound log, and every frame's slice of
    # mixed recordings. Variables are not enough, since a picture drawn from stand-in data leaves
    # every variable right.
    #
    # A BUILD THAT REFUSES IS THE OTHER RIGHT ANSWER, where a verb is not made for a pack left out
    # yet: an error in plain words whose fix is to build all-in-one. #pack_at_start_refusal gives
    # that error back, and lets any other raise through, so a test of a refusal cannot pass on a
    # fault.
    module PackParity
      # What every refusal of a build that leaves its pack out says, among its own words.
      FIX_WORDS = "all-in-one"

      # One run of one build: the picture after each pass (every pixel, row by row), the sound log,
      # each frame's mixed slice.
      Played = Data.define(:pictures, :sound_log, :mixed_sound) do
        # Whether the run showed anything but a black screen or made any sound. A game that does
        # neither is alike however it is built, and proves nothing.
        def shows_or_sounds?
          pictures.any? { |picture| picture.any? { |pixel| pixel != 0 } } || !sound_log.empty? ||
            mixed_sound.flatten.any? { |level| level != 0 }
        end
      end

      def assert_pack_at_start_plays_alike(whole, left_out, pack_file, passes:, presses: {}, message: nil)
        wanted = PackParity.played(game_player, whole, passes, presses)
        assert wanted.shows_or_sounds?,
               [message, "The all-in-one build shows a black screen and makes no sound in #{passes} passes, so there is nothing to compare."].compact.join("\n")
        handed = PackParity.played(game_player.hand_file(pack_file), left_out, passes, presses)
        difference = PackParity.difference(wanted, handed)
        assert_nil difference, [message, difference].compact.join("\n")
      end

      # The refusal the block raises, where it is the stated one: an ArgumentError (the builder's)
      # or a VBlank::BuildError (a lowering's) whose words name the fix, FIX_WORDS. Nil where the
      # block raises nothing. Any other error is raised on.
      def pack_at_start_refusal
        yield
        nil
      rescue ArgumentError, BuildError => e
        raise unless PackParity.stated_refusal?(e)

        e
      end

      def self.stated_refusal?(error)
        !error.is_a?(IR::Guardrails::ValidationError) && error.message.include?(FIX_WORDS)
      end

      # +program+ played on +player+ for +passes+, the buttons of +presses+ held on its frames.
      def self.played(player, program, passes, presses)
        pictures = []
        player.input_each_frame { |frame| presses.fetch(frame, []) } unless presses.empty?
        player.each_vblank { pictures << player.screen.to_a }
        player.run(program, frames: passes)
        Played.new(pictures: pictures, sound_log: player.audio.dup, mixed_sound: player.mixed_sound)
      end

      # How the build handed its pack (+handed+) differs from the all-in-one build (+wanted+), in
      # words that name the first pass they part on, or nil where they are alike.
      def self.difference(wanted, handed)
        picture_difference(wanted.pictures, handed.pictures) || mixed_sound_difference(wanted.mixed_sound, handed.mixed_sound) ||
          sound_log_difference(wanted.sound_log, handed.sound_log)
      end

      def self.picture_difference(wanted, handed)
        return "The all-in-one build showed #{wanted.length} passes and the build handed its pack #{handed.length}." if wanted.length != handed.length

        pass = wanted.each_index.find { |at| wanted[at] != handed[at] }
        return unless pass

        one = wanted[pass]
        other = handed[pass]
        differing = one.each_index.reject { |at| one[at] == other[at] }
        width = Console.described(Testing.console).screen_width
        first = differing.first
        format("The picture differs first on pass %<pass>d: %<count>d pixels, the first at (%<x>d, %<y>d), which is " \
               "0x%<one>04X all-in-one and 0x%<other>04X in the build handed its pack. The all-in-one picture has " \
               "%<one_colors>d colors and the other has %<other_colors>d.",
               pass: pass + 1, count: differing.length, x: first % width, y: first / width, one: one[first].to_i & 0xFFFF,
               other: other[first].to_i & 0xFFFF, one_colors: one.uniq.length, other_colors: other.uniq.length)
      end

      def self.mixed_sound_difference(wanted, handed)
        frame = (0...[wanted.length, handed.length].max).find { |at| wanted[at] != handed[at] }
        return unless frame

        "The mixed sound differs first on frame #{frame + 1}: #{wanted[frame].inspect} all-in-one and " \
          "#{handed[frame].inspect} in the build handed its pack."
      end

      def self.sound_log_difference(wanted, handed)
        entry = (0...[wanted.length, handed.length].max).find { |at| wanted[at] != handed[at] }
        return unless entry

        "The sound log differs first at entry #{entry + 1}: #{wanted[entry].inspect} all-in-one and " \
          "#{handed[entry].inspect} in the build handed its pack."
      end
      private_class_method :picture_difference, :mixed_sound_difference, :sound_log_difference
    end
  end
end
