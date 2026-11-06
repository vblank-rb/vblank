# frozen_string_literal: true

module VBlank
  module Playthroughs
    class Comparison
      # HOW ALIKE TWO PICTURES HAVE TO BE to count as the same. With nothing set, every pixel
      # has to be the same colour: the strict comparison.
      #
      # That is the right question of a framework change, and the wrong one of a game being
      # rebuilt to match another, where one stray pixel several minutes in would otherwise
      # hide everything after it.
      #
      # +share_may_differ+ is the share of the pixels that ARE looked at that may be a
      # different colour, from 0 to 1, before a frame counts as differing. +frames_in_a_row+ is
      # how many frames running have to differ before it is drift, so that one frame of flicker
      # is not. Which pixels are looked at is the LookedAt's to decide, a frame at a time, and each
      # question here is asked of one frame's Part.
      class Likeness
        SETTINGS = %i[share_may_differ frames_in_a_row].freeze

        # The Advance's screen, [width, height]: the size settings are checked against before the
        # cartridges are known, when none is given.
        ADVANCE_SCREEN = Ractor.make_shareable([Console::Hardware::SCREEN_WIDTH, Console::Hardware::SCREEN_HEIGHT])

        # +looked_at+ is the LookedAt, which knows the screen's size.
        def initialize(looked_at:, share_may_differ: 0, frames_in_a_row: 1)
          refuse_share_outside_range!(share_may_differ)
          refuse_invalid_run_length!(frames_in_a_row)
          @settings = { share_may_differ: share_may_differ, frames_in_a_row: frames_in_a_row }
          @share_may_differ = share_may_differ
          @frames_in_a_row = frames_in_a_row
          @looked_at = looked_at
        end

        attr_reader :looked_at

        # The same settings, for a screen of +screen_size+ ([width, height]). A rectangle off that
        # screen is refused then.
        def sized_for(screen_size) = Likeness.new(**@settings, looked_at: @looked_at.sized_for(screen_size))

        # The screen's size this is for, [width, height].
        def screen_size = @looked_at.screen_size

        # Whether the two running cartridges are showing pictures alike enough, of +part+.
        # +second+ can also be a picture kept from earlier (Verifier#picture).
        #
        # Two pictures that are the same are known to be in one comparison, and two that are
        # not are known to differ in the same one when nothing may: only a comparison that
        # was told some of the screen may differ, or need not be looked at, has to go and
        # count what is out. The emulator does the counting, in one pass over the two
        # pictures, so that costs little more than the frame did.
        def alike?(first, second, part)
          return true if first.same_picture_as?(second)
          return false if strict?(part)

          share_differing(first, second, part) <= @share_may_differ
        end

        # The same question of two screens that were kept, each a screenful of colours: the
        # two cartridges are not running side by side, so there is nothing to ask but the
        # pictures themselves.
        def pictures_alike?(first, second, part)
          return true if first == second || part.count.zero?

          differing_places(first, second, part).size.fdiv(part.count) <= @share_may_differ
        end

        # How the two running cartridges' pictures differ, of the places that are looked at
        # (Verifier#difference_from), or nil when they do not.
        def difference(first, second, part)
          first.difference_from(second, looked_at: part.count == @looked_at.pixels ? nil : part.bytes)
        end

        # Whether +frames+ differing frames, one after another, are drift.
        def drift_after?(frames) = frames >= @frames_in_a_row

        # Where two pictures differ, of the places that are looked at. This is for two
        # screens that were kept, each a screenful of colours a row at a time, and what
        # comes back is where in that list the two hold different colours. (Two consoles
        # still running are asked through `alike?`, which does not copy their screens out.)
        def differing_places(first, second, part)
          (0...first.size).select { |at| part.bytes.getbyte(at) != 0 && first[at] != second[at] }
        end

        # HOW ALIKE THE PICTURES HAD TO BE, AS SENTENCES, for a report a person reads.
        # +point+ is what the two were compared at, `A frame` or `A moment`.
        def picture_sentences(point)
          looked_at = @looked_at.whole_screen? ? "pixels" : "pixels that were looked at"
          words = if @share_may_differ.zero?
                    ["#{point} differed when one of the #{looked_at} was a different colour."]
                  else
                    ["#{point} differed when more than #{percent_allowed} percent of the #{looked_at} were a different colour."]
                  end
          words + @looked_at.sentences
        end

        # How many differing frames in a row it took, as a sentence, where that was more
        # than one. It is its own sentence because it holds whatever is compared, a reading
        # as much as the picture.
        def run_length_sentences
          @frames_in_a_row > 1 ? ["#{@frames_in_a_row} frames in a row had to differ before it was drift."] : []
        end

        private

        def strict?(part) = @share_may_differ.zero? && part.count == @looked_at.pixels

        # The share as a percentage a person reads: `1`, `0.5`, and for one pixel of the
        # screen `0.0026041667`. It is written out in full and never with an exponent,
        # which is how a very small number is otherwise printed.
        def percent_allowed = format("%.10f", @share_may_differ * 100.0).sub(/\.?0+\z/, "")

        # The share of the pixels looked at that are a different colour in the two pictures.
        # It is the shares that are compared and never a count worked back out of one: a
        # share written as a decimal, multiplied back up by the pixels, can come out a hair
        # under the count it was worked out from.
        def share_differing(first, second, part)
          return 0 if part.count.zero?

          difference = first.difference_from(second, looked_at: part.bytes)
          (difference ? difference[:count] : 0).fdiv(part.count)
        end

        # A share is a plain number from 0 to 1. The comparisons are written out because the
        # things that are not one — a number that is not a number, a complex one — answer
        # neither, where asking whether they lie between 0 and 1 would stop with an error
        # of Ruby's own.
        def refuse_share_outside_range!(share)
          return if share.is_a?(Numeric) && share.real? && share >= 0 && share <= 1

          raise ArgumentError, "`share_may_differ:` was #{share.inspect}. It must be a number from 0 to 1. " \
                               "It is the share of the pixels that can differ: 0.01 is one pixel in a hundred."
        end

        def refuse_invalid_run_length!(frames)
          return if frames.is_a?(Integer) && frames >= 1

          raise ArgumentError, "`frames_in_a_row:` was #{frames.inspect}. It must be a whole number, 1 or more. " \
                               "It is how many frames in a row must differ before the comparison calls it drift."
        end
      end
    end
  end
end
