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

          # A sprite's picture, cut into pieces: each piece where it sits in the picture, its first tile, its
          # palette, and how many tiles across (+columns+) and down (+rows+) it is, one to four each. +number+
          # is what the runtime knows it by.
          Piece = Data.define(:dx, :dy, :tile, :palette, :columns, :rows) do
            # The piece's size as the sprite table holds it, in the high byte of an entry's second word: the
            # columns less one in its bits 2 and 3, the rows less one in bits 0 and 1.
            def size_bits = ((columns - 1) << 2) | (rows - 1)
          end

          # The most tiles a sprite entry draws across, and down.
          PIECE_SQUARES = 4
          SpritePicture = Data.define(:name, :number, :width, :height, :pieces)

          # A grid of map cells, +columns+ by +rows+, as the console's video memory holds a cell: a word,
          # the tile and the palette.
          Grid = Data.define(:number, :columns, :rows, :words)

          # Raised for art the console cannot hold.
          class TooMuch < LoweringError; end

          # Raised when the pictures need more tiles than video memory holds at once: in a game whose
          # scenes each keep their own, the tiles of one scene with those every screen shows.
          class TooManyTiles < TooMuch; end

          # Raised when the lists of colours the sprites are drawn with need more palettes than there are: the
          # build keeps a palette for each list for good, which a build that lent them while a sprite wore
          # them would not.
          class TooManyLists < TooMuch; end

          attr_reader :grids, :sprite_pictures

          # The backdrop of a game that says none: black, as the interpreter's empty screen is.
          BACKDROP = 0

          # The palette a painted screen's picture is drawn from (Runtime::Paint), kept from the sprites
          # shown over it.
          PAINTED_PALETTE = 0

          # +backdrop+ is the colour the game shows wherever nothing is drawn (`screen ... backdrop:`),
          # a 15-bit colour, or nil for black.
          # +exact+ keeps two colours of the game's that the console shows as one in two places, for a game that
          # fades or tints: a fade moves the colours the game named, and two that are one to the console can be
          # two, a step apart, when they have moved.
          #
          # +beside_painting+ is for the sprites of a painted screen (`sprite ..., over_picture: true`). The
          # painted picture keeps the first palette and most of video RAM to itself (Runtime::Paint), so the
          # sprites have the other three palettes and the tiles between the picture's and the scroll table.
          #
          # EACH SCREEN'S TILES (+scene_tiles+). Video memory holds MOST_TILES tiles at once, and nothing
          # says they stay the same ones: the console's own games load a screen's art as the screen
          # starts. So in a game whose tiles together do not fit (Genesis#build), the tiles every screen
          # shows are numbered first, from 1, and go in at power-on and stay. Each scene then starts
          # from a copy of that list and adds its own after it (#with_tiles_of), so every scene's own
          # tiles are numbered from the same place, the first past the shared ones, and share one room
          # of video memory that the arriving scene fills (#scene_tile_data). What has to fit is one
          # scene's tiles with the shared ones, never two scenes'.
          def initialize(backdrop: nil, exact: false, beside_painting: false, scene_tiles: false)
            @exact = exact
            @beside_painting = beside_painting
            @scene_tiles = scene_tiles
            @scene_stores = {} # a scene => its copy of [@tiles, @tile_numbers, @tile_runs] (#with_tiles_of)
            @tiles_scene = nil # the scene whose copy is being added to, or nil
            @most_tiles = beside_painting ? Runtime::Paint.most_sprite_tiles : MOST_TILES
            @backdrop_color = (backdrop || BACKDROP) & 0x7FFF
            @backdrop = Console::GenesisHardware.color_word(@backdrop_color)
            @tiles = [blank_tile] # tile 0: nothing drawn, for an empty cell
            @tile_numbers = { blank_tile => 0 }
            @tile_runs = {} # the tiles of a sprite piece bigger than one, joined => the first's number (#tile_run_number)
            @palettes = Array.new(PALETTES) # each a list of up to fifteen colour words, or nil for one not used yet
            @held = {} # whose list => the palette it keeps to itself (#reserve_held_palette)
            if beside_painting
              @palettes[PAINTED_PALETTE] = []
              @held[:painted_screen] = PAINTED_PALETTE
            end
            @ordered = {} # a list of colours => the palette whose places are its (#ordered_palette)
            @originals = {} # what a place holds (a colour word, or the colour itself when exact) => the 15-bit colour it was first made from
            @sprite_pictures = {}
            @grids = []
          end

          # --- backgrounds ---

          # The cell +image+ (an Assets::Image of 8×8) makes in a map: its tile number and its palette.
          # +palette+ is a palette whose places are the tile's own list's (#reserve_held_palette), for a tile of a
          # background the game draws with other colours: the tile is then made of places, as a sprite's is.
          def background_cell(image, palette: nil)
            return placed_background_cell(image, palette) if palette

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
          # +palette+ is a palette whose places are the picture's own list's (#ordered_palette), which a
          # picture drawn in the colours of another list is drawn from place for place; without it the
          # picture is drawn from whatever palette holds its colours.
          #
          # A PIECE IS UP TO FOUR TILES ACROSS AND FOUR DOWN. One entry of the sprite table draws it from
          # tiles that follow one another in video memory, down its first column and then down the next,
          # so a big picture takes few of the table's 80 entries, and few of the 20 a row of the screen
          # shows (SpritePieces.cover). A blank square inside a piece is a blank tile of its own.
          def sprite_picture(name, image, palette: nil)
            @sprite_pictures[name] ||= begin
              drawn = (0...(image.width * image.height)).select { |at| image.drawn_at?(at) }
              line = palette || palette_for(drawn.map { |at| word_of(image.color_at(at)) }.uniq, "sprites")
              cover = SpritePieces.cover(image.width, image.height, most: PIECE_SQUARES) do |x, y|
                at = (y * image.width) + x
                if !image.drawn_at?(at) then 0
                elsif palette then image.place_at(at) || first_place(image, image.color_at(at))
                else @palettes[line].index(word_of(image.color_at(at))) + 1
                end
              end
              pieces = cover.map do |block|
                Piece.new(dx: block.across, dy: block.down, tile: tile_run_number(block.squares.map { |places| tile_bytes(places) }),
                          palette: line, columns: block.columns, rows: block.rows)
              end
              SpritePicture.new(name: name, number: @sprite_pictures.length, width: image.width, height: image.height,
                                pieces: pieces)
            end
          end

          # A PALETTE WHOSE PLACES ARE A LIST'S, in the list's order: a picture the game draws in the colours of
          # another list (a sprite's `draw_with`) is made of places in its own list and keeps them whichever
          # list it is drawn with, so each list it can be drawn with is a palette of its own with that list's
          # colours at those places, and the sprite is drawn from the one it is told. +colors+ (15-bit, see-through
          # left out) is the list. A palette that already begins with those colours serves, and one that has room
          # may be given more colours after them by pictures drawn in no list.
          def ordered_palette(colors)
            words = colors.map { |color| word_of(color) }
            @ordered.fetch(words) do
              if words.length > OWN_COLORS
                raise TooMuch, "A list of colours a sprite is drawn with holds #{words.length} colours, and a Genesis " \
                               "list shows #{OWN_COLORS} and see-through. To fix this, use #{OWN_COLORS} colours or fewer."
              end

              line = (0...PALETTES).find { |p| @palettes[p] && !@held.value?(p) && @palettes[p].first(words.length) == words } ||
                     (0...PALETTES).find { |p| @palettes[p].nil? } or
                raise TooManyLists, "The lists of colours the sprites are drawn with, and the pictures, need more lists " \
                                    "than a Genesis holds (#{PALETTES}, shared with every other picture).#{painted_palette_words} " \
                                    "To fix this, draw the sprites with fewer lists of colours."

              @palettes[line] ||= words
              @ordered[words] = line
            end
          end

          # A LIST OF COLOURS THE GAME CHANGES AS IT RUNS keeps a palette to itself, its colours in the order
          # of its places: changing it is writing other colours over that palette, so every pixel of a picture
          # drawn from it is the place it was drawn at, and nothing else's colours can share it. +key+ says
          # whose list it is, and +colors+ (15-bit, see-through left out) are the colours it starts with.
          def reserve_held_palette(key, colors)
            @held.fetch(key) do
              if colors.length > OWN_COLORS
                raise TooMuch, "A list of colours the game changes holds #{colors.length} colours, and a Genesis " \
                               "list shows #{OWN_COLORS} and see-through. To fix this, use #{OWN_COLORS} colours or fewer."
              end
              free = (0...PALETTES).find { |p| @palettes[p].nil? }
              unless free
                raise TooManyLists, "The lists of colours the game changes need more lists than a Genesis holds (#{PALETTES}, " \
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
          def color_memory
            colors = Array.new(PALETTES * PLACES, 0)
            colors[0] = @backdrop
            @palettes.each_with_index { |list, p| list&.each_with_index { |c, i| colors[(p * PLACES) + i + 1] = word_shown(c) } }
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

          # The tiles' pixels, tile 1 first (tile 0, the blank one, is in video RAM already): in a game of
          # +scene_tiles+, the ones every screen shows.
          def tile_data = @tiles.drop(1).join

          # How many tiles the art has, the blank one not counted.
          def tile_count = @tiles.length - 1

          # --- each screen's tiles ---

          # The block, with the tiles it makes kept in +scene+'s copy of the list, taken the first time
          # it is asked for. For nil, or in a game not built that way, in the list every screen shows.
          # Every tile every screen shows has to be made before the first copy is taken, or it would be
          # numbered where a scene's own tiles are (#scene_tile_data checks).
          def with_tiles_of(scene)
            return yield unless @scene_tiles && scene

            shared = [@tiles, @tile_numbers, @tile_runs]
            @tiles, @tile_numbers, @tile_runs = (@scene_stores[scene] ||= shared.map(&:dup))
            @tiles_scene = scene
            begin
              yield
            ensure
              @tiles_scene = nil
              @tiles, @tile_numbers, @tile_runs = shared
            end
          end

          # The number of the first tile of every scene's own: the first past the ones every screen shows.
          def first_scene_tile = @tiles.length

          # The pixels of +scene+'s own tiles, from #first_scene_tile on, which go into video memory as it
          # takes over; empty for a scene with none of its own.
          def scene_tile_data(scene)
            own, = @scene_stores[scene]
            return "".b unless own
            unless own.first(@tiles.length) == @tiles
              raise LoweringError, "a tile every screen shows was made after the scene #{scene.inspect} took its copy"
            end

            own.drop(@tiles.length).join
          end

          private

          def blank_tile = ("\0".b * TILE_BYTES)

          # A tile of a background drawn with other colours, made of the places its pixels were drawn at.
          def placed_background_cell(image, palette)
            places = Array.new(64) do |at|
              image.tile_see_through_at?(at) ? 0 : image.place_at(at) || first_place(image, image.color_at(at))
            end
            [tile_number(tile_bytes(places)), palette]
          end

          # The first place of the picture's own list that holds +color+, counting from place 1: place 0 is
          # see-through, however it is written in a list, as Assets::Recolor reads it.
          def first_place(image, color) = (1...image.colors.length).find { |place| (image.colors[place] & 0x7FFF) == color }

          # What a palette's place holds for a colour of the game's: its word of the console's, or the colour
          # itself when two that make one word are told apart. Kept with the colour it came from.
          def word_of(color)
            held = @exact ? color & 0x7FFF : Console::GenesisHardware.color_word(color)
            @originals[held] ||= color & 0x7FFF
            held
          end

          # The word of the colour memory a place's contents are.
          def word_shown(held) = @exact ? Console::GenesisHardware.color_word(held) : held

          def tile_number(bytes)
            @tile_numbers[bytes] ||= begin
              refuse_too_many_tiles!(@tiles.length)
              @tiles << bytes
              @tiles.length - 1
            end
          end

          # The first of the tiles +tiles+ (each one's bytes) in a row in video memory, for a sprite piece
          # drawn from them in that order: one tile is any tile alike, and a run is stored whole, once for
          # every piece of the same tiles. Each tile of a run serves a square of one tile alike after it.
          def tile_run_number(tiles)
            return tile_number(tiles.first) if tiles.length == 1

            @tile_runs[tiles.join] ||= begin
              first = @tiles.length
              refuse_too_many_tiles!(first + tiles.length - 1)
              tiles.each_with_index do |bytes, i|
                @tiles << bytes
                @tile_numbers[bytes] ||= first + i
              end
              first
            end
          end

          def refuse_too_many_tiles!(number)
            return if number <= @most_tiles

            if @beside_painting
              raise TooMuch, "The sprites over the painted screen use more different 8×8 squares of picture than a " \
                             "Genesis has room for (#{@most_tiles}). The painted screen uses most of the video memory. " \
                             "To fix this, use fewer or smaller sprite pictures."
            end
            if @tiles_scene
              raise TooManyTiles, "The scene :#{Modes.strip_scene_prefix(@tiles_scene)} and the pictures that every scene shows use more " \
                                  "different 8×8 squares of picture than a Genesis has room for (#{MOST_TILES}). To fix " \
                                  "this, use fewer different pictures in that scene."
            end
            raise TooManyTiles, "The pictures use more different 8×8 squares of picture than a Genesis has room for " \
                                "(#{MOST_TILES}). To fix this, use fewer different pictures."
          end

          # What a refusal says of the lists of colours the pictures have, beside a painted screen.
          def painted_palette_words
            @beside_painting ? " On a painted screen, the picture uses one of them, and the sprites have the other #{PALETTES - 1}." : ""
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
                             "#{OWN_COLORS} colours for the backgrounds and sprites together.#{painted_palette_words} " \
                             "To fix this, use fewer colours in the pictures."
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
