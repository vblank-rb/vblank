# frozen_string_literal: true

module VBlank
  module Testing
    # ONE GAME HELD TO ANOTHER, FRAME BY FRAME, in a test: a port's cartridge held to the original it
    # is made from, the same presses on both from power-on. Matching the original is how a port is
    # accepted, and this is the one assertion for it, over Playthroughs::Comparison:
    #
    #   class TitleTest < Minitest::Test
    #     include VBlank::Testing::PlaysAlike
    #
    #     def test_the_title_comes_up_as_the_original_does
    #       assert_plays_alike ours, ORIGINAL.copy.path, to_the_title, ignoring_rectangles: [[0, 0, 160, 8]]
    #     end
    #   end
    #
    # +first+ and +second+ are cartridges (built ones, or files by their path: an original on any
    # console), and +playthrough+ a VBlank.playthrough: its script is played on the first, and the
    # presses it made are played on the second. The settings are Comparison's: `ignoring_rectangles:`
    # leaves parts of the screen out (a part not drawn yet, or a sprite layer the port draws another
    # way), `frames_in_a_row:` lets a difference that lasts fewer frames pass (an original that shows
    # a change torn for a frame while it copies it in), `share_may_differ:`, `readings:` (numbers read
    # off each and compared by name: a block for each side, handed the running cartridge, so the
    # original's is read by address, `game.mem16(0xD4B4)`, and ours by a variable's name, `:lives`),
    # `comparing:`, `lead_ins:`, `save:` or `saves:` (one save both start from, or one for each:
    # the original's in its own format and ours in ours), and `reports_in:` (a folder for the two
    # pictures and what differed).
    # `looking_at:` and `ignoring_rectangles:` take a list for each stretch of frames, or a block that
    # works the part out on each frame (a part that slides with the scenery); `pixels_apart:` looks at
    # every few pixels only; `layers:` compares the picture without its sprites or the sprites alone,
    # or each cartridge's own layers (`layers: [%i[bg0 bg1], %i[bg1 bg2]]`);
    # and `forgiving_torn_frames_of: :second` forgives the original a torn frame only where ours
    # already shows the frame it settles on. `by_passes:` lines the two up by the game's own passes
    # and not by frames, for an original that takes two frames over a pass now and then: each
    # cartridge's count of passes (`true` for the game loop's own on a cartridge built here, a
    # variable's name, a block, or one for each, as `readings:` takes them), with
    # `pass_count_wraps_at: 256` for a count kept in a byte. `skipping_still_frames_of: :second`
    # (or `:first`, or `:both`) skips that cartridge's frames whose picture is the one before's, a
    # room loading, so the two are in step again after a load that is longer on one.
    #
    # A failure says where the two first part: the frame and the moment before it, what differed,
    # every reading on both, how many pixels differ, the box they lie in, the first of them and its
    # colour on each, which video memories differ, and the report's folder when one was written.
    #
    # It plays both in the emulator, so the game's test group needs the emulator gems.
    module PlaysAlike
      def assert_plays_alike(first, second, playthrough, message = nil, **settings)
        drift = playthrough.compare(first, second, **settings).drift
        assert_nil drift, (drift && [message, PlaysAlike.drift_message(drift)].compact.join("\n"))
      end

      # The words of a failure: where the two parted, and how.
      def self.drift_message(drift)
        moment = drift.moment ? " The last moment named was #{drift.moment}." : ""
        ["The two cartridges stop playing alike #{where_words(drift)}.#{moment} What differed: #{differed_words(drift)}.",
         *readings_words(drift), *picture_words(drift.picture_difference), *video_words(drift),
         ("The report is in #{drift.report}." if drift.report)].compact.join("\n")
      end

      DIFFERED_WORDS = { Playthroughs::Comparison::PICTURE => "the picture",
                         Playthroughs::Comparison::FRAMES_APART => "how many frames each cartridge took" }.freeze

      # The frame, or for two lined up step by step the frame each showed it on, and the pass
      # where the steps are passes.
      def self.where_words(drift)
        return "on frame #{drift.frame}" unless drift.second_frame

        frames = "frame #{drift.frame} of the first cartridge and frame #{drift.second_frame} of the second"
        drift.pass ? "on pass #{drift.pass}, #{frames}" : "on #{frames}"
      end

      def self.differed_words(drift) = drift.differed.map { |what| DIFFERED_WORDS.fetch(what) { "the reading #{what}" } }.join(", ")

      def self.readings_words(drift)
        return [] if drift.readings.empty?

        ["The readings on that frame: #{drift.readings.map { |name, (one, other)| "#{name} is #{one.inspect} on the first and #{other.inspect} on the second" }.join('; ')}."]
      end

      def self.picture_words(difference)
        return [] unless difference

        x, y, width, height = difference.fetch(:box)
        first_color, second_color = difference.fetch(:colors).map { |color| format("0x%04X", color) }
        at_x, at_y = difference.fetch(:at)
        ["#{difference.fetch(:count)} pixels differ, all in the box from (#{x}, #{y}), #{width} wide and #{height} high. " \
         "The first is at (#{at_x}, #{at_y}): #{first_color} on the first cartridge and #{second_color} on the second."]
      end
      # Which of the console's video memories differed, each with its first difference.
      def self.video_words(drift)
        return [] if drift.video_differences.empty?

        ["These video memories differ: #{drift.video_differences.map(&:in_words).join('; ')}."]
      end
      private_class_method :where_words, :differed_words, :readings_words, :picture_words, :video_words
    end
  end
end
