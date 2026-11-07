# frozen_string_literal: true

module VBlank
  module Graphics
    # A FONT WHOSE CHARACTERS ARE THE GAME'S OWN PICTURES: a score in a game's own numerals, a
    # word in letters lifted off a cartridge. Each character is a picture the game declared with
    # `image` — in as many colours as the picture has — rather than a one-colour glyph, so the
    # font holds only names and sizes, and drawing a character is drawing that picture.
    #
    # It lays text out the way {Font} does, so `text_width`, `:center` and a number's field come
    # out the same way for either kind: the pen advances by each picture's own width and a gap,
    # and a number keeps a column as wide as the widest picture. Every picture is one height, so a
    # line is one height.
    class PictureFont
      attr_reader :height, :spacing

      # @param pictures [Hash{String=>Symbol}] each character, and the picture it is drawn as
      # @param sizes [Hash{String=>Array(Integer, Integer)}] each character's picture, width and height
      # @param spacing [Integer] blank pixels between characters
      def initialize(pictures:, sizes:, spacing:)
        @pictures = pictures
        @widths = sizes.transform_values(&:first)
        @height = sizes.values.map(&:last).max || 0
        @spacing = spacing
        @max_width = @widths.values.max || 0
      end

      # The picture a character is drawn as, or nil where the font has none.
      def picture(char) = @pictures[char]

      # The characters the font holds.
      def characters = @pictures.keys

      # This character's picture's width, or nil if the font lacks it.
      def glyph_width(char) = @widths[char]

      # The widest picture in the font.
      def width = @max_width

      # The widest a single character can advance: the widest picture plus its gap. A number
      # keeps a column this wide for each digit, so a digit that changes never moves the others.
      def cell_w = @max_width + @spacing

      # The characters of +text+ this font has no picture for, each once.
      def missing_characters(text) = text.each_char.reject { |ch| @pictures.key?(ch) }.uniq

      # Yield each character of +text+ with the column it starts at, as {Font#each_glyph_x} does.
      def each_glyph_x(text)
        pen = 0
        text.each_char do |ch|
          yield ch, pen
          pen += (glyph_width(ch) || @max_width) + @spacing
        end
      end

      # How wide +text+ comes out in pixels: each picture's own width, a gap between them.
      def text_width(text)
        return 0 if text.empty?

        text.each_char.sum { |ch| (glyph_width(ch) || @max_width) + @spacing } - @spacing
      end
    end
  end
end
