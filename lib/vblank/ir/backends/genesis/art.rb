# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # A GAME'S PICTURES, MADE INTO WHAT A GENESIS DRAWS FROM, while the program is built.
        #
        # The Genesis draws everything from TILES: 8×8 pictures in which each pixel is a number, here
        # four bits — one of sixteen places in a list of colours (a PALETTE). A tile is 32 bytes: a row of
        # eight pixels is four bytes, two pixels to a byte, the left one in the top four bits. A
        # background is a grid of cells (a MAP), each naming a tile and one of four palettes for it; a
        # sprite is a tile placed anywhere, drawn from one of the same four palettes. Place 0 of every
        # palette is see-through, and where nothing is drawn the screen shows colour 0 of the first
        # palette, the BACKDROP, black as the interpreter's empty screen is.
        #
        # So a picture the game declared is cut into 8×8 pieces, each piece's pixels written as places
        # in a palette of fifteen colours, and the palettes the game's pictures need gathered into the
        # colour memory (CRAM): 64 colours, four lists of sixteen, the backgrounds' and the sprites'
        # together. Backgrounds and sprites share their tiles too: a tile is stored once whoever
        # draws it. What cannot fit — more colours than the palettes hold, more tiles than video
        # memory has room for — is refused here with plain words.
        #
        # A colour here is a word of the console's own nine bits (Console::GenesisHardware.color_word),
        # so two colours of the game that differ only in the bits a Genesis does not keep are one.
        class Art
          # A palette's places, and how many hold a colour of the picture's own: place 0 is see-through.
          PLACES = 16
          OWN_COLORS = PLACES - 1
          PALETTES = 4

          # How many tiles there is room for in video RAM (see Runtime::Picture for the layout): tile 0
          # is kept blank, for an empty cell.
          MOST_TILES = 1471

          TILE_BYTES = 32

          # A cell of a map: the tile in the low eleven bits, the palette in the two bits at 13.
          PALETTE_SHIFT = 13

          # A sprite's picture, cut into pieces: each piece where it sits in the picture, its tile and its
          # palette. +number+ is what the runtime knows it by.
          Piece = Data.define(:dx, :dy, :tile, :palette)
          SpritePicture = Data.define(:name, :number, :width, :height, :pieces)

          # A grid of map cells, +columns+ by +rows+, as the console's video memory holds a cell: a word,
          # the tile and the palette.
          Grid = Data.define(:number, :columns, :rows, :words)

          # Raised for art the console cannot hold.
          class TooMuch < LoweringError; end

          attr_reader :grids, :sprite_pictures

          # The backdrop of a game that says none: black, as the interpreter's empty screen is.
          BACKDROP = 0

          # +backdrop+ is the colour the game shows wherever nothing is drawn (`screen ... backdrop:`),
          # a 15-bit colour, or nil for black.
          def initialize(backdrop: nil)
            @backdrop_color = (backdrop || BACKDROP) & 0x7FFF
            @backdrop = Console::GenesisHardware.color_word(@backdrop_color)
            @tiles = [blank_tile] # tile 0: nothing drawn, for an empty cell
            @tile_numbers = { blank_tile => 0 }
            @palettes = Array.new(PALETTES) # each a list of up to fifteen colour words, or nil for one not used yet
            @held = {} # whose list => the palette it keeps to itself (#held_sprite_palette)
            @originals = {} # a colour word => the 15-bit colour of the game's it was first made from
            @sprite_pictures = {}
            @grids = []
          end

          # --- backgrounds ---

          # The cell +image+ (an Assets::Image of 8×8) makes in a map: its tile number and its palette.
          def background_cell(image)
            drawn = (0...64).reject { |at| image.tile_see_through_at?(at) }
            colors = drawn.map { |at| word_of(image.color_at(at)) }.uniq
            palette = palette_for(colors, "backgrounds")
            places = Array.new(64) do |at|
              image.tile_see_through_at?(at) ? 0 : @palettes[palette].index(word_of(image.color_at(at))) + 1
            end
            [tile_number(tile_bytes(places)), palette]
          end

          # The map +cells+ ([tile, palette] or nil, by row and column) made into a grid of +columns+ ×
          # +rows+ cells, and its number.
          def grid(cells, columns, rows)
            words = Array.new(rows) do |row|
              Array.new(columns) do |column|
                cell = cells.dig(row, column)
                cell ? cell[0] | (cell[1] << PALETTE_SHIFT) : 0
              end
            end.flatten
            @grids << Grid.new(number: @grids.length, columns: columns, rows: rows, words: words)
            @grids.last
          end

          # --- sprites ---

          # The sprite picture +name+ (an Assets::Image), cut into pieces. A picture whose width or
          # height is not a multiple of 8 has its last pieces' extra pixels left undrawn.
          # +held+ is the palette of a list the game changes (#held_sprite_palette), which the picture is drawn
          # from place for place.
          def sprite_picture(name, image, held: nil)
            @sprite_pictures[name] ||= begin
              drawn = (0...(image.width * image.height)).select { |at| image.drawn_at?(at) }
              palette = held || palette_for(drawn.map { |at| word_of(image.color_at(at)) }.uniq, "sprites")
              cut = SpritePieces.cut(image.width, image.height) do |x, y|
                at = (y * image.width) + x
                if !image.drawn_at?(at) then 0
                elsif held then image.place_at(at) || image.colors.index(image.color_at(at))
                else @palettes[palette].index(word_of(image.color_at(at))) + 1
                end
              end
              pieces = cut.map do |across, down, places|
                Piece.new(dx: across, dy: down, tile: tile_number(tile_bytes(places)), palette: palette)
              end
              SpritePicture.new(name: name, number: @sprite_pictures.length, width: image.width, height: image.height,
                                pieces: pieces)
            end
          end

          # A LIST OF COLOURS THE GAME CHANGES AS IT RUNS keeps a palette to itself, its colours in the order
          # of its places: changing it is writing other colours over that palette, so every pixel of a picture
          # drawn from it is the place it was drawn at, and nothing else's colours can share it. +key+ says
          # whose list it is, and +colors+ (15-bit, see-through left out) are the colours it starts with.
          def held_sprite_palette(key, colors)
            @held.fetch(key) do
              if colors.length > OWN_COLORS
                raise TooMuch, "A list of colours the game changes holds #{colors.length} colours, and a Genesis " \
                               "palette shows #{OWN_COLORS} and see-through. To fix this, use #{OWN_COLORS} colours or fewer."
              end
              free = (0...PALETTES).find { |p| @palettes[p].nil? }
              unless free
                raise TooMuch, "The lists of colours the game changes need more palettes than a Genesis has (#{PALETTES}, " \
                               "shared with every other picture). To fix this, change fewer lists, or draw fewer " \
                               "pictures in other colours."
              end

              @palettes[free] = colors.map { |color| word_of(color) }
              @held[key] = free
            end
          end

          # The palette kept under +key+, or nil for a list nothing is drawn with.
          def held_palette_of(key) = @held[key]

          # +colors+ (15-bit) as the words a palette's places hold, filled out to fifteen.
          def palette_colors(colors) = colors.map { |color| color & 0x7FFF }.fill(0, colors.length...OWN_COLORS)

          # --- the colour memory ---

          # All 64 colours, as the console's colour memory holds them: a word each, the four palettes in
          # turn. Colour 0 is the backdrop.
          def cgram
            colors = Array.new(PALETTES * PLACES, 0)
            colors[0] = @backdrop
            @palettes.each_with_index { |list, p| list&.each_with_index { |c, i| colors[(p * PLACES) + i + 1] = c } }
            colors
          end

          # The colours of the game's that the colour memory's places were made from, 15-bit, a word each
          # in the colour memory's order (Runtime::Tint): the backdrop, then each palette's places. Two
          # colours of the game that make one word of the console's are the first one, which a fade can
          # tell apart from the other where the interpreter would.
          def colors15
            colors = Array.new(PALETTES * PLACES, 0)
            colors[0] = @backdrop_color
            @palettes.each_with_index do |list, p|
              list&.each_with_index { |word, i| colors[(p * PLACES) + i + 1] = @originals.fetch(word, 0) }
            end
            colors
          end

          # How many places of each palette hold a colour, for the runtime to write again when they change.
          def colors_used = @palettes.map { |list| list ? list.length : 0 }

          # The tiles' pixels, tile 1 first (tile 0, the blank one, is in video RAM already).
          def tile_data = @tiles.drop(1).join

          # How many tiles the art has, the blank one not counted.
          def tile_count = @tiles.length - 1

          private

          def blank_tile = ("\0".b * TILE_BYTES)

          # The word of the console's a colour of the game's is, kept with the colour it came from.
          def word_of(color)
            word = Console::GenesisHardware.color_word(color)
            @originals[word] ||= color & 0x7FFF
            word
          end

          def tile_number(bytes)
            @tile_numbers[bytes] ||= begin
              number = @tiles.length
              if number > MOST_TILES
                raise TooMuch, "The pictures use more different 8×8 squares of picture than a Genesis has room for " \
                               "(#{MOST_TILES}). To fix this, use fewer different pictures."
              end

              @tiles << bytes
              number
            end
          end

          # The palette that holds every one of +colors+, adding them to one with room where none does,
          # or starting another. +what+ names whose picture it is.
          def palette_for(colors, what)
            if colors.length > OWN_COLORS
              raise TooMuch, "A picture of the #{what} uses #{colors.length} colours, and on a tiled screen a " \
                             "Genesis tile shows #{OWN_COLORS} and see-through. To fix this, draw it in #{OWN_COLORS} " \
                             "colours or fewer."
            end

            used = (0...PALETTES).select { |p| @palettes[p] && !@held.value?(p) }
            found = used.find { |p| (colors - @palettes[p]).empty? }
            return found if found

            roomy = used.select { |p| (@palettes[p] | colors).length <= OWN_COLORS }.max_by { |p| (@palettes[p] & colors).length }
            if roomy
              @palettes[roomy] |= colors
              return roomy
            end
            unused = (0...PALETTES).find { |p| @palettes[p].nil? }
            unless unused
              raise TooMuch, "The pictures use more colours than a Genesis can show. It holds #{PALETTES} sets of " \
                             "#{OWN_COLORS} colours for the backgrounds and sprites together. To fix this, use fewer " \
                             "colours in the pictures."
            end

            @palettes[unused] = colors.dup
            unused
          end

          # The 32 bytes of a tile whose 64 pixels are +places+ (0 to 15), row by row: each row's four
          # bytes, the left pixel of a byte in its top four bits.
          def tile_bytes(places)
            places.each_slice(2).map { |left, right| (left << 4) | right }.pack("C*")
          end
        end
      end
    end
  end
end
