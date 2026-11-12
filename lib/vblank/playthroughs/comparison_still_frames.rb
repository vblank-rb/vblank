# frozen_string_literal: true

module VBlank
  module Playthroughs
    class Comparison
      # EACH CARTRIDGE'S OWN STILL FRAMES SKIPPED, asked for with `skipping_still_frames_of:`.
      #
      # WHAT A STILL FRAME IS. A frame whose picture is the same as the frame before it. A game
      # shows a run of them while it loads a room, holds a fade, or waits: the picture stands
      # while the console works. An original takes as long as each room takes; a port takes
      # another length, or none. Frame by frame the two are out of step after the first load,
      # and `ignoring_frames:` cannot help: it leaves out the same frame numbers on both, and
      # the stretch is a different length on each.
      #
      # SO A SIDE'S STILL FRAMES ARE SKIPPED, the first cartridge's, the second's or both: the
      # frames whose picture changed are counted on that side, and the two are lined up by that
      # count (see LinedUp), each compared on the frame it showed its next change. A side whose
      # still frames are not skipped counts every frame. The picture is the one compared, in the
      # part of the screen looked at on every frame, so with `layers:` a still frame is one whose
      # sprites (or backgrounds) stood still, and a clock left out with `ignoring_rectangles:`
      # does not make a frame move.
      #
      # ONE SIDE OR BOTH. Skipping one side's still frames is for a side that alone holds still:
      # an original's room load the port does not have. Where both hold still together (a hero
      # standing in a still room, a pause), the side that is not skipped counts those frames and
      # the skipped side does not, so the two part; skip both.
      #
      # Frame 1 is never still, having no frame before it.
      #
      # +side+ is `:first`, `:second` or `:both`.
      class StillFrames
        SIDES = Ractor.make_shareable({ first: [0], second: [1], both: [0, 1] })

        # The rule for +given+, or nil for none.
        def self.from(given)
          return nil if given.nil?
          return new(SIDES.fetch(given)) if SIDES.key?(given)

          raise ArgumentError, "`skipping_still_frames_of:` was #{given.inspect}. It must be `:first`, `:second` or " \
                               "`:both`. It names the cartridges whose still frames are skipped: frames whose picture " \
                               "is the same as the frame before."
        end

        def initialize(sides)
          @sides = sides
        end

        # Nothing about the count can be wrong before the cartridges are played.
        def refuse_unreadable_on!(_cartridges) = nil
        def game_loop_count?(_side) = false

        # The two running cartridges, lined up.
        # A frame is still when nothing changed in +part+, the part of the screen looked at on
        # every frame, so a clock or an animated tile left out of the comparison does not keep
        # every frame moving.
        def lined_up_on(first, second, part)
          LinedUp.new(Count.new(first, part, skipping: @sides.include?(0)), Count.new(second, part, skipping: @sides.include?(1)),
                      passes: false)
        end

        # The setting's name, for an error about settings it cannot be used with.
        def setting_name = "`skipping_still_frames_of:`"

        # ONE CARTRIDGE'S COUNT OF ITS FRAMES, with its still frames left out of it when
        # +skipping+, as it plays.
        class Count
          def current_step = @current

          def initialize(game, part, skipping:)
            @game = game
            @looked_at = part.bytes
            @skipping = skipping
            @before = nil
            @current = nil
          end

          def counted_words = "changing frames"

          # The count after the frame just played: one more, unless its picture is the same as
          # the frame before's and this side's still frames are skipped. Read once a frame.
          def read_after_frame!
            picture = @game.picture
            still = @skipping && @before && @game.difference_from(@before, looked_at: @looked_at).nil?
            @before = picture
            @current = (@current || 0) + (still ? 0 : 1)
          end

          def step_and_read!(keys)
            @game.step(1, keys: keys)
            read_after_frame!
          end

          # (+past:+ is never set here: a frame whose picture changed is not compared at its end.)
          def refuse_stood_still!(_wanted, **)
            raise PictureStoodStill, "The second cartridge's picture stayed the same for #{LinedUp::MOST_FRAMES_STILL} " \
                                     "frames, after the first cartridge's picture changed. The comparison skips the second " \
                                     "cartridge's still frames, so it waited for a change, and none came. Make the tape end " \
                                     "sooner, or remove the second cartridge from `skipping_still_frames_of:`."
          end
        end
        private_constant :Count
      end
      private_constant :StillFrames

      # THE SECOND CARTRIDGE'S PICTURE STOOD STILL FOR A MINUTE OF FRAMES, where its still frames
      # are skipped and the first cartridge's picture had changed. The message says how to go on.
      class PictureStoodStill < StandardError; end
    end
  end
end
