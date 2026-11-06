# frozen_string_literal: true

module VBlank
  module Playthroughs
    class Comparison
      # THE STRICT RULE FOR A FRAME SHOWN TORN, asked for with `forgiving_torn_frames_of:`.
      #
      # WHAT A TORN FRAME IS. A game that copies a change into the picture while the console is
      # drawing it shows that frame part old and part new: the top of the screen from after the
      # change and the bottom from before, say. The next frame shows the change whole. An
      # original game does this now and then, and a port that draws the change at the right
      # moment never shows the torn frame at all — so the two differ on that one frame though
      # the port is right.
      #
      # A TEAR CAN LAST MORE THAN A FRAME: a copy that takes longer than one frame shows two
      # pictures part way through the change, each unlike the frame before and the frame after,
      # before the picture settles (an original's billboard does this). So torn frames come in
      # runs, of one or more.
      #
      # WHY NOT `frames_in_a_row: 2`. That forgives any one frame, so a port that shows a change
      # a frame late passes as readily as the original's tearing. This forgives exactly one
      # thing. On every frame of a run where the torn side shows a picture unlike the frame before
      # it and unlike the frame after it, the other side must show the picture the run settles on:
      # that of the first frame after it that is not torn. Anything else is a difference as it
      # always was.
      #
      # WHAT IT COSTS is waiting: whether a frame is torn is not known until the frame after it
      # has been played, and what a run settles on not until it ends, so a frame is decided a
      # frame late, and the frames of a run once it ends, each with what was kept from it
      # (Observation). The picture of the torn side is kept on every frame, which the emulator
      # already holds, and the other side's only on a frame whose picture differs.
      #
      # +side+ is which cartridge is the one that tears, 0 for the first and 1 for the second,
      # and +likeness+ how alike the other side's picture and the settled one have to be.
      class TornFrames
        SIDES = %i[first second].freeze

        # A frame waiting to be decided: what was seen on it, whether the torn side's picture
        # was unlike the frame before, and the two sides' pictures on it.
        Waiting = Data.define(:observation, :unlike_before, :torn_side_picture, :other_side_picture)
        private_constant :Waiting

        # The rule for the side +given+ names, or nil for no rule.
        def self.for(given, likeness)
          refuse_unknown_side!(given)
          given && new(SIDES.index(given), likeness)
        end

        def self.refuse_unknown_side!(given)
          return if given.nil? || SIDES.include?(given)

          raise ArgumentError, "`forgiving_torn_frames_of:` was #{given.inspect}. It must be `:first` or `:second`. " \
                               "It names the cartridge whose torn frames are forgiven."
        end

        def initialize(side, likeness)
          @side = side
          @likeness = likeness
          @waiting = [] # the frame before this one, after the torn frames of a run not yet ended
          @before = nil
        end

        # HAND OVER THE FRAME JUST PLAYED and get back the frames now decided, oldest first: each
        # an Observation, with the picture taken out of what differed where that frame was torn
        # and forgiven. Empty while a run of torn frames goes on, and on the first frame, which
        # has none before it. +consoles+ is the two running cartridges, on the frame just played.
        #
        # The last frame waiting is torn when it is unlike the frame before it and the torn side
        # now shows something else again. When it is not, the run before it has ended, and the
        # torn side now shows what the run settled on: the last frame's picture, since the two
        # are alike (or it would be torn).
        def decide_waiting(observation, consoles)
          torn_side = consoles[@side]
          decided = []
          last = @waiting.last
          unless last.nil? || torn?(last, torn_side)
            decided = @waiting[0...-1].map { |torn| forgiven(torn, torn_side) } << last.observation
            @waiting = []
          end
          differs = observation.seen&.differed&.include?(PICTURE)
          @waiting << Waiting.new(observation: observation,
                                  unlike_before: differs && !@before.nil? && changed?(torn_side, @before, observation.kept.part),
                                  torn_side_picture: torn_side.picture, other_side_picture: (consoles[1 - @side].picture if differs))
          @before = torn_side.picture
          decided
        end

        # The frames still waiting when the tape runs out, which have no frame after them to say
        # how they settle: each is taken as it was seen.
        def waiting_observations = @waiting.map(&:observation)

        private

        # Whether +game+'s picture is unlike the one +kept+, in the part of the screen looked
        # at: a change only outside it is no change, so a frame that changed there and not
        # in the part is not torn in the part.
        def changed?(game, kept, part) = !game.difference_from(kept, looked_at: part.bytes).nil?

        def torn?(waiting, now) = waiting.unlike_before && changed?(now, waiting.torn_side_picture, waiting.observation.kept.part)

        # A torn frame of a run that has ended, forgiven where the other side showed the picture
        # the run settled on, which +settled+ (the torn side) shows now.
        def forgiven(waiting, settled)
          observation = waiting.observation
          return observation unless @likeness.alike?(settled, waiting.other_side_picture, observation.kept.part)

          observation.with(seen: observation.seen.with(differed: observation.seen.differed - [PICTURE]))
        end
      end
      private_constant :TornFrames
    end
  end
end
