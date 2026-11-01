# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # WHAT A PAINTED SCREEN'S GAME PAINTS WITH, worked out while the game is built: its colours,
        # and its pictures and text in the form Runtime::Paint copies them onto the screen.
        #
        # THE COLOURS. A painted screen is tiles whose pixels are four bits each (Runtime::Paint), so
        # every pixel is one of sixteen colours from one list of the console's colour memory. Every
        # colour the game can paint is known before it runs — each drawing names its colours — so the
        # list is made here, and the game paints a colour's place in it. Place 0 is black: a pixel of
        # place 0 is see-through on the console and shows the colour behind every plane, which is black
        # too, the colour the screen starts in. A Genesis keeps three bits of each colour channel, so two
        # colours of the game that differ only below those are one colour here, and share a place.
        #
        # A PICTURE is kept as a byte for each of its pixels, row by row: the place of the pixel's
        # colour, or Runtime::Paint::NOT_DRAWN for one the picture leaves see-through.
        class PaintedArt
          COLORS = 16
          BLACK = 0

          # Raised when the game paints more colours than a list of the console's colour memory holds.
          class TooMuch < LoweringError; end

          # One picture as Runtime::Paint reads it: its number, its size, and its pixels.
          Picture = Data.define(:number, :width, :height, :pixels)

          attr_reader :pictures

          def initialize
            @colors = [BLACK]
            @originals = { BLACK => 0 }
            @pictures = []
            @numbered = {}
          end

          # The place of +color+ (15-bit) in the colour list, added there the first time.
          def place_of(color)
            word = Console::GenesisHardware.color_word(color)
            @originals[word] ||= color & 0x7FFF
            at = @colors.index(word)
            return at if at

            if @colors.length >= COLORS
              raise TooMuch, "This game paints more than #{COLORS - 1} colours besides black. A Genesis shows " \
                             "#{COLORS - 1} colours and black on a painted screen. To fix this, use fewer colours."
            end
            @colors << word
            @colors.length - 1
          end

          # The picture +key+ names, made once from a block that gives the picture's width, height and
          # the colour of each drawn pixel ({[x, y] => color}).
          def picture(key)
            @numbered[key] ||= begin
              width, height, drawn = yield
              made = make_picture(@pictures.length, width, height, drawn)
              @pictures << made
              made
            end
          end

          # The colour list as the console's colour memory takes it: sixteen words, in its layout.
          def colors_as_words = @colors.dup.fill(BLACK, @colors.length...COLORS)

          # The colour list as the game's own colours, 15-bit, for the runtime to fade and tint (Runtime::Tint).
          def colors_as_15bit = @colors.map { |word| @originals.fetch(word) }.fill(BLACK, @colors.length...COLORS)

          # How many places of the list the game paints in, from place 0.
          def colors_painted = @colors.length

          private

          def make_picture(number, width, height, drawn)
            pixels = Array.new(width * height) do |at|
              color = drawn[[at % width, at / width]]
              color.nil? ? Runtime::Paint::NOT_DRAWN : place_of(color)
            end
            Picture.new(number: number, width: width, height: height, pixels: pixels)
          end
        end
      end
    end
  end
end
