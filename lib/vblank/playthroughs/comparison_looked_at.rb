# frozen_string_literal: true

module VBlank
  module Playthroughs
    class Comparison
      # WHICH PIXELS OF THE SCREEN A COMPARISON LOOKS AT, frame by frame.
      #
      # With nothing said it is every pixel. Three settings narrow it, and they go together:
      #
      #   looking_at:           the parts to look within; everything outside them is left out
      #   ignoring_rectangles:  the parts to leave out, inside whatever is looked within
      #   pixels_apart:         only every few pixels across and down, 1 for every pixel
      #
      # WHY A PORT NEEDS MORE THAN FIXED RECTANGLES. A rebuilt game matches its original one
      # part at a time: the room before the status bar, the status bar before the menus. What
      # is ready changes with the stretch of the game, so a part can be said for a stretch of
      # frames. And a part that belongs to the scenery moves when the view scrolls, so a part
      # can be worked out on every frame from the two running cartridges, by a block.
      #
      # EACH OF THE FIRST TWO TAKES ONE OF THREE THINGS:
      #
      #   [[x, y, width, height], ...]                 the same rectangles on every frame
      #   { 1..120 => [...], :door.. => [...] }        rectangles for each stretch of frames, a
      #                                                range of frame numbers or of moments as in
      #                                                `ignoring_frames:`; a frame that no stretch
      #                                                covers is looked at whole
      #   ->(first, second) { [[x, y, w, h], ...] }    a block, handed the two running cartridges
      #                                                (and the frame's number, if it takes three)
      #                                                and asked on every frame that is looked at,
      #                                                in order, so it can remember the frame before
      #
      # A rectangle given in a list or for a stretch has to lie on the screen, since a part off
      # it is a slip. One a block answers is cut to the screen, since a part that moves with
      # the scenery slides off the edge.
      #
      # A DECIDED FRAME IS A Part: a byte for each pixel, a row at a time, 1 where the pixel is
      # looked at and 0 where it is not — the form the emulator counts a difference in — and
      # how many pixels are looked at, which is what a share of the picture is a share of.
      # Parts are cached by the rectangles that made them, so a part that does not change is
      # worked out once.
      class LookedAt
        SETTINGS = %i[looking_at ignoring_rectangles pixels_apart].freeze

        # One frame's decision: +bytes+ a byte for each pixel, +count+ how many are looked at.
        Part = Data.define(:bytes, :count)

        # A part of the screen, by its top left corner and its size.
        Rectangle = Data.define(:x, :y, :width, :height) do
          def columns = x...(x + width)
          def rows = y...(y + height)
          def on_screen?(screen_width, screen_height) = x >= 0 && y >= 0 && columns.end <= screen_width && rows.end <= screen_height
          def in_words = "#{width} by #{height} pixels from column #{x}, row #{y}"

          # The part of it that is on a screen of that size, or nil for none.
          def cut_to(screen_width, screen_height)
            left = x.clamp(0, screen_width)
            top = y.clamp(0, screen_height)
            right = columns.end.clamp(0, screen_width)
            bottom = rows.end.clamp(0, screen_height)
            Rectangle.new(left, top, right - left, bottom - top) if right > left && bottom > top
          end
        end

        LOOKED_AT = "\x01".b.freeze
        LEFT_OUT = "\x00".b.freeze
        private_constant :LOOKED_AT, :LEFT_OUT

        # The most parts cached at once: a block that moves its part every frame would otherwise
        # cache one for every frame played.
        MOST_CACHED_PARTS = 64
        private_constant :MOST_CACHED_PARTS

        # +moments+ is the names of the moments the playthrough declares, so a stretch that
        # names one it does not have is refused here. +screen_size+ is [width, height], or nil
        # while it is not known: a rectangle is checked against the screen once it is.
        def initialize(looking_at: nil, ignoring_rectangles: [], pixels_apart: 1, moments: [], screen_size: nil)
          refuse_invalid_spacing!(pixels_apart)
          @given = { looking_at: looking_at, ignoring_rectangles: ignoring_rectangles, pixels_apart: pixels_apart }
          @moments = moments
          @within = looking_at.nil? ? nil : Choice.new(:looking_at, looking_at, moments)
          @outside = Choice.new(:ignoring_rectangles, ignoring_rectangles, moments)
          @pixels_apart = pixels_apart
          @width, @height = screen_size
          choices.each { |choice| choice.refuse_off_screen!(@width, @height) } if screen_size
          @part_cache = {}
        end

        # The same settings, for a screen of +screen_size+ ([width, height]).
        def sized_for(screen_size)
          screen_size == [@width, @height] ? self : LookedAt.new(**@given, moments: @moments, screen_size: screen_size)
        end

        def screen_size = [@width, @height]

        # How many pixels the screen has.
        def pixels = @width * @height

        # Whether the part looked at can be different on different frames: a stretch or a
        # block. Only a comparison frame by frame has frames to say it of.
        def changes_with_frame? = choices.any?(&:changes_with_frame?)

        # Whether every pixel is looked at on every frame.
        def whole_screen? = !changes_with_frame? && fixed_part.count == pixels

        # The part looked at on every frame, for a part that does not change with the frame.
        def fixed_part = part_of(@within&.rectangles, @outside.rectangles || [])

        # THE PART LOOKED AT ON EACH FRAME OF +tape+: what a comparison asks on every frame,
        # with the stretches written in moments turned into the frames those name on it.
        def on_tape(tape) = OnTape.new(self, choices.to_h { |choice| [choice, choice.frame_ranges_on(tape)] })

        # The part looked at on +frame+, with +first+ and +second+ the two running cartridges.
        # +ranges+ is each choice's stretches as frames (#on_tape).
        def part_on(frame, first, second, ranges)
          within = @within&.rectangles_on(frame, first, second, ranges[@within], screen_size)
          outside = @outside.rectangles_on(frame, first, second, ranges[@outside], screen_size) || []
          part_of(within, outside)
        end

        # WHAT WAS LOOKED AT, AS SENTENCES, for a report a person reads: nothing when it was
        # every pixel.
        def sentences
          [*@within&.sentences("Only these parts of the screen were looked at", "chose the parts of the screen that were looked at"),
           *@outside.sentences("These parts of the screen were not looked at", "chose parts of the screen that were not looked at"),
           *(["Only every #{ordinal(@pixels_apart)} pixel across and down was looked at."] if @pixels_apart > 1)]
        end

        # THE PART ON EACH FRAME OF ONE TAPE. See LookedAt#on_tape.
        OnTape = Data.define(:looked_at, :ranges) do
          def part_on(frame, first, second) = looked_at.part_on(frame, first, second, ranges)
        end

        private

        def choices = [@within, @outside].compact

        def ordinal(number)
          return "#{number}th" if (11..13).cover?(number % 100)

          "#{number}#{{ 1 => 'st', 2 => 'nd', 3 => 'rd' }.fetch(number % 10, 'th')}"
        end

        # The part looked within +within+ (nil for the whole screen), less +outside+, on the
        # pixels the spacing keeps.
        def part_of(within, outside)
          @part_cache.clear if @part_cache.size >= MOST_CACHED_PARTS
          @part_cache[[within, outside]] ||= begin
            grid = spaced_pixels
            bytes = within ? LEFT_OUT * pixels : grid.dup
            within&.each do |rectangle|
              rectangle.rows.each { |row| bytes[(row * @width) + rectangle.x, rectangle.width] = grid[(row * @width) + rectangle.x, rectangle.width] }
            end
            outside.each do |rectangle|
              rectangle.rows.each { |row| bytes[(row * @width) + rectangle.x, rectangle.width] = LEFT_OUT * rectangle.width }
            end
            Part.new(bytes: bytes.freeze, count: bytes.count(LOOKED_AT))
          end
        end

        # Every pixel the spacing keeps: every pixel, or with +pixels_apart+ of 2 every other
        # one across on every other row, counted from the top left corner.
        def spaced_pixels
          @spaced_pixels ||= if @pixels_apart == 1
                               (LOOKED_AT * pixels).freeze
                             else
                               row = Array.new(@width) { |x| (x % @pixels_apart).zero? ? LOOKED_AT : LEFT_OUT }.join
                               Array.new(@height) { |y| (y % @pixels_apart).zero? ? row : LEFT_OUT * @width }.join.freeze
                             end
        end

        def refuse_invalid_spacing!(given)
          return if given.is_a?(Integer) && given >= 1

          raise ArgumentError, "`pixels_apart:` was #{given.inspect}. It must be a whole number, 1 or more. With 2, the " \
                               "comparison looks at every other pixel across and down. With 1, it looks at every pixel."
        end

        # ONE OF THE TWO SETTINGS OF RECTANGLES, as it was written: a list, a list for each
        # stretch of frames, or a block. See LookedAt.
        class Choice
          # One stretch's rectangles: the range as it was written, the same as frames to be
          # read on a tape (IgnoredFrames), and the rectangles.
          Stretch = Data.define(:written, :frames, :rectangles)

          def initialize(setting, given, moments)
            @setting = setting
            if given.respond_to?(:call)
              @block = given
            elsif given.is_a?(Hash) && given.any?
              @stretches = given.map do |stretch, list|
                refuse_malformed_stretch!(stretch)
                Stretch.new(written: stretch, frames: IgnoredFrames.new([stretch], moments, setting: setting),
                            rectangles: rectangles_from(list))
              end
            else
              @list = rectangles_from(given)
            end
          end

          # The rectangles on every frame, for a list; nil for a stretch or a block.
          def rectangles = @list

          def changes_with_frame? = @list.nil?

          # Each stretch's frames on +tape+, beside its rectangles.
          def frame_ranges_on(tape)
            return [] unless @stretches

            @stretches.flat_map { |stretch| stretch.frames.frame_ranges_on(tape).map { |frames| [frames, stretch.rectangles] } }
          end

          # The rectangles on +frame+, or nil for a frame no stretch covers.
          def rectangles_on(frame, first, second, ranges, screen_size)
            return @list if @list
            return answered_by_block(first, second, frame, screen_size) if @block

            covering = ranges.select { |frames, _list| frames.cover?(frame) }
            covering.flat_map(&:last) unless covering.empty?
          end

          def refuse_off_screen!(width, height)
            [*@list, *@stretches&.flat_map(&:rectangles)].each do |rectangle|
              next if rectangle.on_screen?(width, height)

              raise ArgumentError, "`#{@setting}:` holds #{rectangle.to_h.values.inspect}. A part of that rectangle is " \
                                   "off the screen. The screen is #{width} pixels wide and #{height} pixels high. " \
                                   "Give a rectangle that is on the screen."
            end
          end

          # +fixed+ starts the sentence of a list; +chosen+ says what a block did.
          def sentences(fixed, chosen)
            return ["A block #{chosen} on each frame."] if @block
            return @list.empty? ? [] : ["#{fixed}: #{in_words(@list)}."] if @list

            @stretches.map { |stretch| "On the frames #{stretch.written.inspect}: #{fixed.downcase}: #{in_words(stretch.rectangles)}." }
          end

          private

          def in_words(list) = list.empty? ? "none" : list.map(&:in_words).join("; ")

          # A block that takes three is handed the frame's number too, counted from 1, for a part
          # that belongs to some frames only and moves on them.
          def answered_by_block(first, second, frame, screen_size)
            answer = @block.arity == 2 ? @block.call(first, second) : @block.call(first, second, frame)
            unless answer.is_a?(Array) && answer.all? { |written| written.is_a?(Array) && written.size == 4 && written.all?(Integer) }
              raise ArgumentError, "The block given to `#{@setting}:` answered #{answer.inspect}. It must answer a list of " \
                                   "rectangles, each four whole numbers: [x, y, width, height]."
            end
            answer.filter_map { |written| Rectangle.new(*written).cut_to(*screen_size) }
          end

          # The whole of what was given is quoted back, because the commonest slip is one
          # rectangle written with no list around it.
          def rectangles_from(given)
            unless given.is_a?(Array) && given.all? { |written| well_formed_rectangle?(written) }
              raise ArgumentError, "`#{@setting}:` was #{given.inspect}. It must be a list of rectangles, a list for each " \
                                   "stretch of frames, or a block. Each rectangle is four whole numbers: [x, y, width, height]. " \
                                   "The width and the height must be 1 or more. One rectangle is written like " \
                                   "`#{@setting}: [[0, 128, 240, 32]]`."
            end
            given.map { |written| Rectangle.new(*written) }
          end

          def well_formed_rectangle?(written)
            written.is_a?(Array) && written.size == 4 && written.all?(Integer) && written.last(2).all?(&:positive?)
          end

          def refuse_malformed_stretch!(stretch)
            return if stretch.is_a?(Range)

            raise ArgumentError, "`#{@setting}:` holds #{stretch.inspect} before its rectangles. Before the rectangles " \
                                 "of a stretch comes a range of frame numbers or of moments, like " \
                                 "`#{@setting}: { 1..120 => [[0, 128, 240, 32]] }`."
          end
        end
        private_constant :Choice
      end
    end
  end
end
