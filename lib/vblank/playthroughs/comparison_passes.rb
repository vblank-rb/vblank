# frozen_string_literal: true

module VBlank
  module Playthroughs
    class Comparison
      # TWO CARTRIDGES LINED UP BY THE GAME'S OWN PASSES, asked for with `by_passes:`.
      #
      # WHAT A PASS IS. A game runs one loop over and over: read the buttons, move everything,
      # draw. One run of it is a pass. Most passes take one frame, but a pass with a lot to do
      # takes two or three, and then the screen shows the same pass for that many frames. An
      # original game does this now and then; a port of it may do it on other passes, or never.
      # Frame by frame such a pair is out of step from the first slow pass, and nothing after it
      # is like with like. `frames_in_a_row:` only forgives a difference for a few frames, which
      # is not the same thing.
      #
      # SO EACH CARTRIDGE SAYS ITS OWN COUNT OF PASSES, read after every frame, the way a reading
      # is read (see Readings): a variable's name, a block handed the running cartridge, or one
      # of those for each. `true` is the game loop's own count, which a cartridge built here keeps
      # (Diagnostics::Verifier#passes). An original keeps a counter somewhere in its memory, and a
      # block reads it by its address. A counter kept in a byte comes back round to nought, and
      # `pass_count_wraps_at: 256` counts it on past that, on both cartridges.
      #
      # HOW THE TWO ARE PLAYED. The first cartridge plays the tape frame by frame, as it always
      # does. A frame on which its count shows a pass it has not shown before is that pass's
      # first frame; the other frames of a slow pass are not looked at. The second cartridge is
      # then played on until its own count shows that pass too, and the two are compared there,
      # each on the first frame it showed it. The second is held, on each frame it plays, the
      # buttons the first held on the frame it showed that pass, so a press lands on the same
      # pass on both, wherever it lands in frames. A game reads its buttons once a pass, so what
      # the first is held on the later frames of a slow pass it never reads, and the second is
      # not given it either: a press of one frame that falls there reaches neither game.
      #
      # A count that comes back round is told from one the game sets back (a new game) only by
      # `pass_count_wraps_at:`: with it, any fall is a lap; without it, a fall is an error.
      # Two counts that never show the same pass compare nothing, and that is an error too.
      #
      # A pass that one of them does not show — its count goes past it in one frame — is passed
      # over, and is not looked at, the way a frame `ignoring_frames:` leaves out is not.
      # `frames_in_a_row:` counts the passes the first shows, and frame numbers in the other
      # settings (`ignoring_frames:`, a part of the screen for a stretch of frames) are the first
      # cartridge's frames.
      #
      # +way+ is the count as `by_passes:` was written, and +wraps_at+ is `pass_count_wraps_at:`,
      # or nil for a count that never comes round.
      class Passes
        # The name the count is read under, as a reading. A comparison's own readings can never
        # have it, since none can be called this.
        COUNT = :pass

        # What a reading of the game loop's own count calls on the running cartridge.
        GameLoopCount = Data.define do
          def call(game) = game.passes
        end
        private_constant :GameLoopCount

        SIDES = %w[first second].freeze
        private_constant :SIDES

        # The count of +by_passes+, or nil for a comparison frame by frame.
        def self.from(by_passes, wraps_at)
          if by_passes.nil?
            return nil if wraps_at.nil?

            raise ArgumentError, "`pass_count_wraps_at:` was given, and `by_passes:` was not. `pass_count_wraps_at:` says " \
                                 "where a count of passes comes back round to nought. Give `by_passes:` too, or remove " \
                                 "`pass_count_wraps_at:`."
          end

          new(by_passes, wraps_at)
        end

        def initialize(way, wraps_at)
          refuse_malformed_way!(way)
          refuse_unusable_wrap!(wraps_at)
          ways = way.is_a?(Array) ? way : [way, way]
          @game_loop_sides = ways.each_index.select { |side| ways[side] == true }
          @reading = Readings.new(COUNT => ways.map { |one| one == true ? GameLoopCount.new : one })
          @wraps_at = wraps_at
        end

        # Whether the cartridge on +side+ (0 or 1) is read by the game loop's own count, which
        # the reader of an Advance cartridge has to be told to keep before it is switched on.
        def game_loop_count?(side) = @game_loop_sides.include?(side)

        # The count is looked at on the two cartridges before a frame is played: a variable they
        # do not have, and the game loop's count on a cartridge that was not built here.
        def refuse_unreadable_on!(cartridges)
          @reading.refuse_unreadable_on!(cartridges)
          @game_loop_sides.each do |side|
            next if cartridges[side].built

            raise ArgumentError, "`by_passes:` reads the game loop's own count from the #{SIDES[side]} cartridge. That " \
                                 "cartridge was not built here, so it does not keep that count. Give that cartridge a " \
                                 "block that reads its own counter by its address: `->(game) { game.mem8(address) }`."
          end
        end

        # The two running cartridges, lined up.
        def lined_up_on(first, second) = LinedUp.new(Count.new(@reading, 0, @wraps_at, first), Count.new(@reading, 1, @wraps_at, second))

        # ONE CARTRIDGE'S COUNT OF PASSES AS IT PLAYS, counted on past each wrap so that a later
        # pass is always a bigger number. +side+ is 0 for the first cartridge and 1 for the second.
        class Count
          def initialize(reading, side, wraps_at, game)
            @reading = reading
            @side = side
            @wraps_at = wraps_at
            @game = game
            @last = nil
            @laps = 0
          end

          # The pass the cartridge shows now, read off it and counted on past a wrap since the
          # last reading. It is read after every frame the cartridge plays, so no wrap is missed.
          def read_pass!
            raw = @reading.values_from(@game, @side).fetch(COUNT)
            refuse_count_not_whole!(raw)
            raw %= @wraps_at if @wraps_at
            if @last && raw < @last
              refuse_fallen_count!(raw)
              @laps += @wraps_at
            end
            @last = raw
            raw + @laps
          end

          # Play the cartridge one frame, holding +keys+, and read the pass it shows after it.
          def step_and_read_pass!(keys)
            @game.step(1, keys: keys)
            read_pass!
          end

          private

          def which = SIDES[@side]

          def refuse_count_not_whole!(raw)
            return if raw.is_a?(Integer)

            raise ReadingFailed, "`by_passes:` read #{raw.inspect} from the #{which} cartridge as its count of passes. A " \
                                 "count of passes must be a whole number."
          end

          def refuse_fallen_count!(raw)
            return if @wraps_at

            raise PassCountFell, "The #{which} cartridge's count of passes went back from #{@last} to #{raw}. A count of " \
                                 "passes must go up. If the count comes back round to nought, give the number it comes " \
                                 "round at, like `pass_count_wraps_at: 256` for a count kept in a byte."
          end
        end
        private_constant :Count

        # THE TWO CARTRIDGES PLAYED PASS BY PASS: the first frame by frame, the second as far as
        # each pass the first shows.
        class LinedUp
          # How many frames each has played.
          attr_reader :second_frames

          def initialize(first, second)
            @first = first
            @second = second
            @shown = nil
            @second_frames = 0
            @both_shown = 0
          end

          # The pass the first cartridge shows for the first time on the frame it has just
          # played, or nil when it shows one it has shown before.
          def read_pass_begun_on_first!
            pass = @first.read_pass!
            return nil if @shown && pass <= @shown

            @shown = pass
          end

          # Play the second cartridge on, holding +keys+, until its count shows +pass+ or a later
          # one, and answer whether it shows that very pass, which is then compared. It plays at
          # least one frame the first time, since nothing is shown before a frame is played.
          def play_second_to_pass!(pass, keys)
            count = @second_frames.zero? ? nil : @second.read_pass!
            still = 0
            until count && count >= pass
              moved = @second.step_and_read_pass!(keys)
              @second_frames += 1
              still = moved == count ? still + 1 : 0
              count = moved
              refuse_stopped_count!(pass, count) if still >= PassSteppedGame::MOST_FRAMES_STILL
            end
            (count == pass).tap { |shown| @both_shown += 1 if shown }
          end

          # The playing has ended. A comparison in which the second never showed a pass the first
          # did compared nothing, and would pass whatever the two did: two counts that do not
          # count the same passes, most likely.
          def refuse_nothing_compared!
            return if @both_shown.positive? || @shown.nil?

            raise PassNotReached, "The second cartridge showed none of the passes the first cartridge showed, so no pass " \
                                  "was compared. The first cartridge's last pass was #{@shown}, and the second cartridge's " \
                                  "count was #{@second.read_pass!}. Make the two counts count the same passes, from the " \
                                  "same number."
          end

          private

          def refuse_stopped_count!(pass, count)
            raise PassNotReached, "The second cartridge's count of passes stopped at #{count}, and the first cartridge " \
                                  "showed pass #{pass}. The count did not move in #{PassSteppedGame::MOST_FRAMES_STILL} " \
                                  "frames, so the comparison stopped. The second game ended there, or its count does not " \
                                  "move on that stretch. Make the tape end sooner, or count something that goes on moving there."
          end
        end
        private_constant :LinedUp

        private

        def refuse_malformed_way!(way)
          return if way_to_count?(way) || (way.is_a?(Array) && way.size == 2 && way.all? { |one| way_to_count?(one) })

          raise ArgumentError, "`by_passes:` was #{way.inspect}. That is not a way to count passes. It can be `true`, for " \
                               "the game loop's own count on a cartridge built here. It can be the name of a variable, or a " \
                               "block that is given the running cartridge. It can be a list of two of those, one for each " \
                               "cartridge. Write it like `by_passes: [:passes, ->(game) { game.mem8(0xFF9B) }]`."
        end

        def way_to_count?(way) = way == true || way.is_a?(Symbol) || way.respond_to?(:call)

        def refuse_unusable_wrap!(wraps_at)
          return if wraps_at.nil? || (wraps_at.is_a?(Integer) && wraps_at > 1)

          raise ArgumentError, "`pass_count_wraps_at:` was #{wraps_at.inspect}. It must be a whole number above 1. It is " \
                               "the number a count of passes comes back round to nought at, like 256 for a count kept in a byte."
        end
      end
      private_constant :Passes

      # A COUNT OF PASSES THAT WENT DOWN, on a cartridge `by_passes:` lines up, where nothing said
      # it comes back round. The message says which cartridge and how to say where it wraps.
      class PassCountFell < StandardError; end

      # THE SECOND CARTRIDGE NEVER SHOWED A PASS THE FIRST DID: its count stood still for a minute
      # of frames short of it, or it showed none of the first's passes at all. The message says
      # which pass and where the count was.
      class PassNotReached < StandardError; end
    end
  end
end
