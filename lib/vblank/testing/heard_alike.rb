# frozen_string_literal: true

module VBlank
  module Testing
    # ONE GAME'S HEARD SOUND HELD TO ANOTHER'S, in a test: a port's cartridge beside the original it
    # is made from, the same presses on both in the same emulator. It is the one assertion for what
    # comes out of the speakers, over Playthroughs::HeardComparison, as PlaysAlike is for the picture:
    #
    #   class TitleTuneTest < Minitest::Test
    #     include VBlank::Testing::HeardAlike
    #
    #     def test_the_title_tune_is_heard_as_the_originals_is
    #       assert_heard_alike ours, ORIGINAL.copy.path, to_the_end_of_the_tune,
    #                          heard_above: 0,                # the emulator's silence is exactly nought
    #                          first_heard_frames_apart: 0,   # the first note starts on the original's frame
    #                          level_share_apart: 0.1,        # a tenth: the two mix a chord in another order
    #                          ending_frames_apart: 6         # the last chord's fall is rounded another way
    #     end
    #   end
    #
    # +first+ and +second+ are cartridges (built ones, or files by their path: an original on any
    # console whose emulator hands its sound over), and +presses+ a tape or a VBlank.playthrough,
    # whose script is played on the first and the presses it made on the second. Every setting is
    # the game's to give, with its reason beside it, and none has a value this assumes:
    #
    #   heard_above:               the loudest sample a frame may have and still count as silent
    #   first_heard_frames_apart:  how many frames apart the two may first be heard
    #   level_share_apart:         how far apart their levels may be, as a share of the louder one's
    #   ending_frames_apart:       how many frames apart they may be last heard, and their last
    #                              sounds may take to fall silent
    #   lead_ins:                  a playthrough for each to play first, not counted (optional)
    #
    # A failure says which of those was out, what each cartridge measured, the first frame the two
    # differ on and the loudest sample each put out on it.
    #
    # It plays both in the emulator, so the game's test group needs the emulator gems.
    module HeardAlike
      def assert_heard_alike(first, second, presses, message = nil, **settings)
        compared = Playthroughs::HeardComparison.play(presses, first, second, **settings)
        assert compared.alike?, (compared.alike? ? nil : [message, HeardAlike.difference_message(compared)].compact.join("\n"))
      end

      # The words of a failure: which measure was out, what each side measured, and the frame.
      def self.difference_message(compared)
        difference = compared.difference
        [measure_words(difference, compared), frame_words(difference)].compact.join(" ")
      end

      def self.measure_words(difference, compared)
        one, other = difference.measured
        case difference.what
        when :never_heard then never_heard_words(compared)
        when :first_heard
          "The two cartridges are first heard on different frames: frame #{one} on the first and frame #{other} on the second."
        when :level
          "The two cartridges are heard at different levels: #{one.round} on the first and #{other.round} on the " \
          "second, the loudest sample a frame averaged over the frames each is heard."
        when :last_heard
          "The two cartridges are last heard on different frames: frame #{one} on the first and frame #{other} on the second."
        when :fall
          "The last sound takes a different time to fall silent: #{one} frames on the first cartridge and #{other} on the second."
        end
      end

      def self.never_heard_words(compared)
        sides = { "first" => compared.first, "second" => compared.second }
        silent, heard = sides.partition { |_, side| !side.heard? }
        limit = "above #{compared.first.heard_above} in #{compared.first.frames} frames"
        return "Neither cartridge is heard #{limit}, so there is nothing to compare." if heard.empty?

        "The #{silent.first.first} cartridge is never heard #{limit}. The #{heard.first.first} is first heard on " \
          "frame #{heard.first.last.first_heard}."
      end

      def self.frame_words(difference)
        return unless difference.frame

        "They first differ on frame #{difference.frame}: the loudest sample is #{difference.loudest[0]} on the first " \
          "and #{difference.loudest[1]} on the second."
      end
      private_class_method :measure_words, :never_heard_words, :frame_words
    end
  end
end
