# frozen_string_literal: true

module VBlank
  module IR
    # WHAT A DECLARED ASSET IS, read off the node that declares it.
    #
    # A program declares images and recorded sounds, and every backend has to know the same
    # things about them: how big a picture is, which of its colors means "see through",
    # how fast a recording plays. Each backend used to write that down for itself, which is
    # two descriptions of one thing in the two places whose whole contract is that they
    # agree — and nothing but a test to notice when they drifted.
    #
    # These are built from the declaring node by one function, so there is one description
    # and the backends read it. What a backend then DOES with an asset is its own business
    # and stays there: where the GBA packed a table into the cartridge, or which hardware
    # layer a background got, means nothing to an interpreter and is not here.
    module Assets
      # A picture: its size, which color index is see-through (nil if none is), the
      # pixels themselves, and — where the art came from somewhere that already decided
      # them — its own table of colors in its own order (nil where it did not).
      #
      # +places+ is the same picture read the other way round: where the art was given as
      # numbers into that table, one byte a pixel saying which place it came from (nil
      # where the art was given as colors). The two are the same picture until the table
      # holds one color at two places, which a palette taken off a real cartridge usually
      # does — then a pixel's color no longer shows which place drew it, and anything that
      # reads a pixel as a NUMBER has to ask here instead.
      #
      # +colors_name+ is the name of the list of colours it was drawn from, where the game named one
      # (`image ..., colors: :sea`), and nil where it gave the colours themselves. Two lists named
      # apart are two lists even when they hold the same colours — a screen brought in from white
      # starts with every list white — so a background told to draw each of its lists with
      # another tells them apart by #list_drawn_from, the name and the colours together.
      #
      # +pieces+ is, for a picture the game made of pieces (`image ..., pieces:`), each piece
      # front-most first as [dx, dy, its places]: where its top left is in the picture, and its
      # pixels as places in the picture's list, row by row, 64 of them for a piece of 8x8 and 256
      # for one of 16x16. The picture's own pixels are those pieces laid over each other, so a
      # console that draws sprites from pieces can draw it from the same ones; nil for any other
      # picture. A console with no piece of 16x16 reads #small_pieces.
      #
      # +piece_groups+ is, where those pieces were cut from bigger ones, how many of them each bigger
      # piece became, in their order: [4, 1] is a piece cut into the first four and a piece that is
      # the fifth alone. Art taken from a console's own sprite frames comes as pieces of up to 32x32,
      # and a picture's pieces are 8x8 or 16x16, so a bigger one is cut. A console whose sprite
      # table draws a piece that big puts the group back together and draws it as one; nil where
      # every piece is its own.
      #
      # The side of a piece of a picture made of pieces (Image#pieces), and of the larger kind.
      PIECE_SIZE = 8
      BIG_PIECE_SIZE = 16

      # What marks a pixel see-through where a picture has no marker yet (the sixteenth bit alone).
      SEE_THROUGH_MARKER = 0x8000

      # A PICTURE GIVEN AS PLACES INTO A LIST OF COLOURS (`image colors:, places:`), as its pixels: a
      # place's colour (colour 0 for a place past them), or SEE_THROUGH_MARKER at place +see_through+
      # (0, as a picture of up to sixteen colours has it; nil for none). Gives back the pixels, two bytes each, and
      # the marker when a pixel is see-through, nil when none is. The build makes a picture so from
      # the numbers a game holds, and the interpreter from a file it is handed (IR::StartFile), so a
      # picture is the same pixels whichever way its numbers came.
      def self.placed_pixels(places, colors, see_through: 0)
        pixels = places.map { |place| place == see_through ? SEE_THROUGH_MARKER : colors.fetch(place, 0) }
        [pixels.pack("v*"), places.include?(see_through) ? SEE_THROUGH_MARKER : nil]
      end

      # Places kept two to a byte, the left one in the low half, as sixteen-colour tiles keep them:
      # every place of +bytes+, in order.
      def self.places_packed_in(bytes) = bytes.unpack("C*").flat_map { |both| [both & 0x0F, both >> 4] }

      # Colours kept two bytes each, low byte first, five bits a channel: each one's fifteen bits (the
      # sixteenth is not a colour, Graphics::Color.resolve).
      def self.colors_packed_in(bytes) = bytes.unpack("v*").map { |color| color & 0x7FFF }

      # The places of tiles kept one after another, each 64 places row by row, for a picture
      # +across+ tiles wide: the places of the picture's pixels row by row. A picture one tile wide
      # keeps its places in the order the tiles hold them already.
      def self.picture_places_of_tiles(places, across:)
        return places if across == 1

        width = across * 8
        Array.new(places.length) do |at|
          row, column = at.divmod(width)
          places.fetch(((((row / 8) * across) + (column / 8)) * 64) + ((row % 8) * 8) + (column % 8))
        end
      end

      Image = Data.define(:width, :height, :transparent, :pixels, :colors, :places, :colors_name, :pieces,
                         :places_from_pack, :piece_groups) do
        def initialize(width:, height:, transparent:, pixels:, colors:, places:, colors_name: nil, pieces: nil,
                       places_from_pack: false, piece_groups: nil) = super

        def self.of(node)
          new(width: node.width, height: node.height, transparent: node.transparent,
              pixels: node.pixels, colors: node.colors, places: node.places, colors_name: node.colors_name,
              pieces: (node.pieces if node.respond_to?(:pieces)),
              piece_groups: (node.piece_groups if node.respond_to?(:piece_groups)),
              places_from_pack: node.respond_to?(:places_from_pack) && node.places_from_pack == true)
        end

        # The list this picture was drawn from, as a background's recolouring keeps them apart.
        def list_drawn_from = [colors_name, colors]

        # Whether the places are a data pack slot's tiles, in the layout of the console the original is
        # for, so a lowering that keeps places as they are keeps these.
        def places_from_pack? = places_from_pack

        # Which place in the picture's own list this pixel was drawn at, or nil for a
        # picture whose art was given as colors and never recorded one.
        def place_at(index) = places&.getbyte(index)

        # ONE PIXEL, COUNTING ACROSS THE ROWS: pixel 0 is the top left, and the next is the
        # one to its right. Two bytes each, the low one first.
        #
        # TWO READINGS, AND THE DIFFERENCE MATTERS. +raw_at+ is the number the program wrote,
        # which is fifteen bits of color and a sixteenth bit that marks a pixel see-through —
        # so it is the one to compare against +transparent+, and #drawn_at? is that comparison.
        # +color_at+ drops that bit, and is the color the console shows. Reading the wrong one
        # is quiet: a see-through pixel would read as a real color nothing else uses, and turn
        # up as one more color in a picture's table.
        def raw_at(index) = pixels.getbyte(index * 2) | (pixels.getbyte((index * 2) + 1) << 8)

        def color_at(index) = raw_at(index) & 0x7FFF

        # Does this pixel draw anything? A picture with no see-through color draws every one.
        def drawn_at?(index) = transparent.nil? || raw_at(index) != transparent

        # Does the layer behind show through this pixel when the picture is a background
        # tile? A tile has no marker of its own for "nothing here", so it is the backdrop
        # color, black, that marks it — except in art that came with its place numbers,
        # where place 0 marks it and black at any other place is a color like the rest. Every
        # backend asks this one question, so a black pixel is solid or see-through on each.
        def tile_see_through_at?(index)
          place = place_at(index)
          place.nil? ? color_at(index).zero? : place.zero?
        end

        # The same picture with every pixel #tile_see_through_at? carrying the see-through marker, for
        # a console that stamps a tile as it stamps any picture, which skips only what is marked.
        def with_tile_see_through_marked
          count = width * height
          return self if (0...count).none? { |at| drawn_at?(at) && tile_see_through_at?(at) }

          marker = transparent || SEE_THROUGH_MARKER
          marked = (0...count).map { |at| tile_see_through_at?(at) ? marker : raw_at(at) }
          with(pixels: marked.pack("v*"), transparent: marker)
        end

        # EVERY COLOR THIS PICTURE ACTUALLY DRAWS, its see-through pixels left out. What a
        # picture was given and what it uses are different lists: a table can name colors no
        # pixel is painted in, which is how one picture ships a whole game's palette.
        #
        # Each colour once, in the order the pixels first draw it, row by row from the top
        # left — the order a table of colours built from the picture lists them in. Two values
        # that differ only in the see-through bit are one colour here.
        def colors_drawn
          Remembered.fetch(:colors_drawn, self) do
            pixels.unpack("v*").reject { |value| value == transparent }.map { |value| value & 0x7FFF }.uniq
          end
        end

        # THE SAME PICTURE THE OTHER WAY ROUND — every row read right to left.
        #
        # "Left is the right one, backwards" is close to universal in 2D games, and this
        # is the one place a picture is turned round. A program that DECLARES a pose is a
        # mirror and a build that NOTICES one already is therefore compare the same bytes,
        # which is what lets the second recognize the first.
        def mirrored
          turned = (0...height).each_with_object(+"".b) do |row, bytes|
            bytes << pixels.byteslice(row * width * 2, width * 2).unpack("v*").reverse.pack("v*")
          end
          with(pixels: turned, places: places && mirrored_places,
               pieces: pieces&.map { |dx, dy, own| [width - dx - Image.side(own), dy, Image.rows(own).map(&:reverse).join.b] })
        end

        # THE SAME PICTURE TURNED TOP TO BOTTOM — its rows in the other order. The other
        # mirror, and the one place a picture is turned that way, for the same reason as above.
        def upside_down
          rows = (0...height).map { |row| pixels.byteslice(row * width * 2, width * 2) }
          upended = places && (0...height).map { |row| places.byteslice(row * width, width) }.reverse.join.b
          with(pixels: rows.reverse.join.b, places: upended,
               pieces: pieces&.map { |dx, dy, own| [dx, height - dy - Image.side(own), Image.rows(own).reverse.join.b] })
        end

        # The picture turned +way+, as a game names a turn: :mirrored or :upside_down.
        def turned(way)
          case way
          when :mirrored then mirrored
          when :upside_down then upside_down
          else raise ArgumentError, "#{way.inspect} is not a way to turn a picture"
          end
        end

        # The picture's pieces, every one 8x8: a piece of 16x16 is the four of it, in its place in
        # the order, less any of the four that draws nothing.
        def small_pieces
          pieces&.flat_map do |dx, dy, own|
            next [[dx, dy, own]] if Image.side(own) == PIECE_SIZE

            Image.quarters(own).filter_map do |across, down, quarter|
              [dx + across, dy + down, quarter] if quarter.bytes.any?(&:positive?)
            end
          end
        end

        # How many pixels a side a piece's places are.
        def self.side(own) = own.bytesize > PIECE_SIZE * PIECE_SIZE ? BIG_PIECE_SIZE : PIECE_SIZE

        # A piece's places, a row at a time.
        def self.rows(own)
          across = side(own)
          (0...across).map { |row| own.byteslice(row * across, across) }
        end

        # A piece of 16x16 as its four quarters, each [across, down, its 64 places]: left top, right
        # top, left bottom, right bottom.
        def self.quarters(own)
          rows = rows(own)
          [0, PIECE_SIZE].product([0, PIECE_SIZE]).map do |down, across|
            [across, down, rows[down, PIECE_SIZE].map { |row| row.byteslice(across, PIECE_SIZE) }.join.b]
          end
        end

        private

        def mirrored_places
          (0...height).each_with_object(+"".b) do |row, bytes|
            bytes << places.byteslice(row * width, width).reverse
          end
        end
      end

      # WHAT COLOR A PIXEL IS DRAWN IN while its picture is drawn with another list of colors:
      # each place of the picture's own list shows the color at the same place of that list.
      # A picture whose art was given as places is read by place, which is what a machine that
      # keeps a number per pixel does with it; one given as colors has only its colors to go
      # on. One of the two halves is filled in and the other is not, since a picture is one
      # kind or the other.
      #
      # It is the picture's business rather than any one backend's, so a backend that swaps
      # colors as it draws and one that makes its recolored pictures ahead of time ask the
      # same rule.
      Recolor = Data.define(:places, :by_place, :by_color) do
        # +picture+ (an Image) drawn with the list +swapped+.
        def self.of(picture, swapped)
          new(places: picture.places, by_place: swapped,
              by_color: picture.places ? nil : color_swaps(picture.colors, swapped))
        end

        # A picture given as COLORS has no places recorded, so its swap is read the only way
        # left: color to color, and a color its list holds twice is read at the first of
        # them. The build refuses that where the two places differ in the list being drawn
        # with, so this is only ever reached where both places agree.
        def self.color_swaps(own, swapped)
          (1...own.length).each_with_object({}) { |place, swaps| swaps[own[place]] ||= swapped[place] }
        end

        # The color pixel +index+ is drawn in, +color+ being the one the picture stores there.
        def color_for(index, color)
          return by_place[places.getbyte(index)] || color if places

          by_color.fetch(color, color)
        end
      end

      # A recorded sound: how many samples a second it was recorded at, how many there are,
      # and the note it was played at when recorded (which is what playing it at another
      # pitch is measured from).
      # +holds_from+ is where a held note reads back to at the end of the recording, as a sample
      # number, or nil for one that runs out. It is kept as HOW FAR BACK that is rather than
      # where it starts, because that is what a voice needs: the mixer moves its read pointer
      # back by this when it reaches the end, which is one subtraction and no arithmetic about
      # where the recording began.
      Sample = Data.define(:rate, :length, :note, :envelope, :holds_from) do
        def self.of(node)
          new(rate: node.rate, length: node.bytes.bytesize, note: node.note,
              envelope: node.envelope, holds_from: node.holds_from)
        end

        # How far a held note goes back at the end of the recording, or 0 for one that stops
        # there. A recording that holds from its very start goes back by the whole of it.
        def loop_length = holds_from ? length - holds_from : 0
      end
    end
  end
end
