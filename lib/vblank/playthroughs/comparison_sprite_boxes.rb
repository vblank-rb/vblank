# frozen_string_literal: true

module VBlank
  module Playthroughs
    class Comparison
      # EVERY SPRITE'S BOX, LEFT OUT OF THE PICTURE COMPARED (`ignoring_sprites: true`): on each frame
      # looked at, the box of every entry of the console's own sprite table on either cartridge, on
      # that frame and on the frame before it.
      #
      # WHAT IT IS FOR. A port's scenery is ready before its characters are, and the original shows
      # its characters on top of the scenery anyway. `layers: :backgrounds` draws both pictures with
      # the sprites switched off, and so holds the port to the scenery under every character too; and
      # not every console's emulator can switch a layer off (Genesis Plus GX draws them together).
      # This leaves the pixels under the sprites out of both pictures instead.
      #
      # WHY THE FRAME BEFORE TOO. A console draws a frame from a sprite table the game wrote a frame
      # or so earlier, so the table read after a frame and the sprites in its picture can be a frame
      # apart. Both are left out. Where the two cartridges are lined up step by step, the frame
      # before is each cartridge's own: the frame it played before the one it showed the step on.
      #
      # THE TABLE IS READ RAW (Verifier#sprite_boxes), as the console holds it, so a cartridge with no
      # build record, the original, is read the same as ours. A Super Nintendo cartridge's sprites
      # come in two sizes the game sets in a register the emulator does not hand over, so for one the
      # setting is the two sizes, small then large: `ignoring_sprites: [[8, 8], [16, 16]]`.
      class SpriteBoxes
        # The setting as given: nil for none, or the boxes to leave out.
        def self.from(given)
          return nil if given.nil? || given == false
          return new(nil) if given == true
          return new(given) if two_sizes?(given)

          raise ArgumentError, "`ignoring_sprites:` was #{given.inspect}. It must be true or false. For a Super Nintendo " \
                               "cartridge it can be the two sizes of its sprites, small then large, like " \
                               "`ignoring_sprites: [[8, 8], [16, 16]]`."
        end

        def self.two_sizes?(given)
          given.is_a?(Array) && given.size == 2 &&
            given.all? { |size| size.is_a?(Array) && size.size == 2 && size.all? { |side| side.is_a?(Integer) && side.positive? } }
        end
        private_class_method :two_sizes?

        # +sizes+ is the two sizes of a Super Nintendo cartridge's sprites, or nil where none were given.
        def initialize(sizes)
          @sizes = sizes
        end

        # A cartridge whose sprite sizes the game sets is refused where no sizes were given, before a
        # frame is played.
        def refuse_unreadable_on!(cartridges)
          return if @sizes

          %w[first second].zip(cartridges).each do |which, cartridge|
            kit = Console.for(cartridge.console)
            next unless kit.sprite_sizes_set_by_game?

            raise ArgumentError, "`ignoring_sprites:` was true, and the #{which} cartridge is for a #{kit.title}. Its game " \
                                 "sets the two sizes of its sprites, and the comparison cannot read them. Give the two " \
                                 "sizes, small then large, like `ignoring_sprites: [[8, 8], [16, 16]]`."
          end
        end

        # The boxes of +consoles+, the two running cartridges, read from now on (Watch). +cartridges+
        # are theirs, and +screen_size+ the screen the boxes are cut to.
        def start_watch(consoles, cartridges, screen_size)
          options = cartridges.map { |cartridge| Console.for(cartridge.console).sprite_sizes_set_by_game? ? { sizes: @sizes } : {} }
          Watch.new(consoles, options, screen_size)
        end

        # What a report says of it.
        def sentences
          ["The box of every sprite in either cartridge's sprite table, on each frame and on the frame before it, " \
           "was not looked at."]
        end

        # THE BOXES OF TWO RUNNING CARTRIDGES, read after each frame either one plays. Each is read as
        # it stands when the watch begins, so the first frame played has a frame before it, the
        # lead-in's last.
        class Watch
          def initialize(consoles, options, screen_size)
            @consoles = consoles
            @options = options
            @screen_size = screen_size
            @before = [[], []]
            @now = [0, 1].map { |side| boxes_of(side) }
          end

          # The table of the cartridge on +side+ (0 for the first, 1 for the second) read again,
          # after a frame it played.
          def read_after_frame!(side)
            @before[side] = @now[side]
            @now[side] = boxes_of(side)
          end

          # Every box to leave out now, cut to the screen (LookedAt::Rectangle).
          def rectangles = (@before.flatten + @now.flatten).uniq

          private

          def boxes_of(side)
            @consoles[side].sprite_boxes(**@options[side]).filter_map do |box|
              LookedAt::Rectangle.new(box.x, box.y, box.width, box.height).cut_to(*@screen_size)
            end
          end
        end
      end
      private_constant :SpriteBoxes
    end
  end
end
