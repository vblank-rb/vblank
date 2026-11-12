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
        # draws it and whichever way round, since a cell and a sprite's piece each say whether
        # their tile is mirrored or upside down (TileStore). What cannot fit — more colours than
        # the palettes hold, more tiles than video memory has room for — is refused here with
        # plain words.
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
          # palette, and how many tiles across (+columns+) and down (+rows+) it is, one to four each. +tile+
          # is the tile's number with the bits that turn the piece (TileStore). +number+ is what the runtime
          # knows a picture by.
          Piece = Data.define(:dx, :dy, :tile, :palette, :columns, :rows) do
            # The piece's size as the sprite table holds it, in the high byte of an entry's second word: the
            # columns less one in its bits 2 and 3, the rows less one in bits 0 and 1.
            def size_bits = ((columns - 1) << 2) | (rows - 1)
          end

          # The most tiles a sprite entry draws across, and down.
          PIECE_SQUARES = 4
          SpritePicture = Data.define(:name, :number, :width, :height, :pieces)

          # A piece of a sprite's picture before its tiles have numbers: where it sits, how many tiles
          # each way, its tiles' bytes down each column and then across, and its palette.
          Block = Data.define(:dx, :dy, :columns, :rows, :tiles, :palette)

          # A sprite's picture as its blocks, in the order the sprite table takes them (the one in front
          # last). +pieced+ says the blocks are the pieces the picture was made of.
          Cut = Data.define(:name, :width, :height, :blocks, :pieced)

          # A grid of map cells, +columns+ by +rows+, as the console's video memory holds a cell: a word,
          # the tile and the palette.
          Grid = Data.define(:number, :columns, :rows, :words)

          # Raised for art the console cannot hold.
          class TooMuch < LoweringError; end

          # Raised when the pictures need more tiles than video memory holds at once: in a game whose
          # scenes each keep their own, the tiles of one scene with those every screen shows.
          class TooManyTiles < TooMuch; end

          # Raised when the pictures need more palettes than there are: in a game whose scenes each keep
          # their own colours (+scene_colors+), the palettes of one scene with those every screen keeps.
          class TooManyColors < TooMuch; end

          # Raised when the lists of colours the sprites are drawn with need more palettes than there are: the
          # build keeps a palette for each list for good, which a build that lent them while a sprite wore
          # them would not. +scene+ is the scene whose own lists did not fit beside those every screen keeps,
          # or nil for the game's.
          class TooManyLists < TooManyColors
            attr_reader :scene

            def initialize(message = nil, scene: nil)
              super(message)
              @scene = scene
            end
          end

          # What a scene writes over a palette as it takes over (#scene_palette_writes): the palette's
          # number, how many of its places hold a colour, and those colours, 15-bit, filled out to fifteen.
          PaletteWrite = Data.define(:palette, :used, :colors)

          # A scene's copy of the palettes (#with_colors_of): the four, and which palette each list in its own
          # order is (#ordered_palette).
          PaletteSet = Data.define(:palettes, :ordered)

          attr_reader :grids, :sprite_pictures

          # How many tiles video memory has room for, the blank one not counted.
          attr_reader :most_tiles

          # How many tiles the pictures every screen shows put in video memory, the blank one not counted.
          def shared_tile_count = @shared_tiles.length - 1

          # For each scene that keeps tiles of its own (+scene_tiles+), how many are in video memory
          # while it is up: its own and the ones every screen shows.
          def tile_count_by_scene = @scene_stores.transform_values { |tiles| tiles.length - 1 }

          # The backdrop of a game that names none: black, as the interpreter's empty screen is.
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
          #
          # EACH SCREEN'S COLOURS (+scene_colors+) go the same way, for a game whose pictures together
          # need more than the four palettes (Genesis#build): the console's own games write a screen's
          # palettes as the screen comes up. The palettes every screen keeps are allotted first: a list
          # the game changes, whose palette is written over whichever scene is up, and the colours of
          # the pictures every screen shows. Each scene then starts from a copy of them and allots its
          # own pictures' colours in what is left, even adding to a palette of theirs that has room
          # (#with_colors_of), and as it takes over it writes each palette its copy holds differently
          # (#scene_palette_writes). What has to fit is one scene's colours with the shared ones.
          def initialize(backdrop: nil, exact: false, beside_painting: false, scene_tiles: false, scene_colors: false)
            @exact = exact
            @beside_painting = beside_painting
            @scene_tiles = scene_tiles
            @scene_colors = scene_colors
            @scene_stores = {} # a scene => its copy of the tiles every screen shows, with its own after them (#with_tiles_of)
            @most_tiles = beside_painting ? Runtime::Paint.most_sprite_tiles : MOST_TILES
            @backdrop_color = (backdrop || BACKDROP) & 0x7FFF
            @backdrop = Console::GenesisHardware.color_word(@backdrop_color)
            @shared_tiles = TileStore.new # the tiles every screen shows
            @tiles = @shared_tiles # the store being added to: those, or a scene's copy
            @cuts = {} # a sprite picture's name => its Cut (#cut_sprite_picture)
            @palettes = Array.new(PALETTES) # each a list of up to fifteen colour words, or nil for one not used yet
            @held = {} # whose list => the palette it keeps to itself (#reserve_held_palette)
            if beside_painting
              @palettes[PAINTED_PALETTE] = []
              @held[:painted_screen] = PAINTED_PALETTE
            end
            @ordered = {} # a list of colours => the palette whose places are its (#ordered_palette)
            @shared_palettes = @palettes # the palettes every screen keeps; @palettes is those, or a scene's copy
            @shared_ordered = @ordered
            @scene_palette_sets = {} # a scene => its copies of @palettes and @ordered (#with_colors_of)
            @colors_scene = nil # the scene whose copy is being added to, for a refusal's words
            @originals = {} # what a place holds (a colour word, or the colour itself when exact) => the 15-bit colour it was first made from
            @sprite_pictures = {}
            @grids = []
            @run_tiles = {} # [a store's object_id, a painted tile's name] => its number there (#run_cell)
          end

          # --- backgrounds ---

          # The cell +image+ (an Assets::Image of 8×8) makes in a map: its tile and its palette. The tile is
          # its number with the bits that turn it (TileStore), so a tile shown mirrored or upside down, or
          # one a sprite's piece draws too, is the one tile in video memory.
          # +palette+ is a palette whose places are the tile's own list's (#reserve_held_palette), for a tile of a
          # background the game draws with other colours: the tile is then made of places, as a sprite's is.
          # +of+ is the background's name, for a build with too many tiles to say what took them.
          def background_cell(image, of:, palette: nil)
            taker = "background :#{of}"
            return placed_background_cell(image, palette, taker) if palette

            drawn = (0...64).reject { |at| image.tile_see_through_at?(at) }
            colors = drawn.map { |at| word_of(image.color_at(at)) }.uniq
            palette = palette_for(colors, "backgrounds")
            places = Array.new(64) do |at|
              image.tile_see_through_at?(at) ? 0 : @palettes[palette].index(word_of(image.color_at(at))) + 1
            end
            [@tiles.word_of(TileBytes.of(places), taker), palette]
          end

          # THE CELL OF A TILE THE GAME PAINTS (Lowering::TileRuns), +name+, from the list +colors+ (see-through
          # first): a tile of its own in the store being added to, blank until the game's first copy, and
          # the palette whose places are the list's, so the places the game paints are the palette's. One
          # tile for each store that shows it: the tiles every screen shows, or a scene's own.
          # +palette+ is one a background drawn with other colours writes over (#reserve_held_palette).
          def run_cell(name, colors, palette: nil)
            number = (@run_tiles[[@tiles.object_id, name]] ||= @tiles.own_tile("painted tiles :#{name}"))
            [number, palette || ordered_palette(colors.drop(1).map { |color| color & 0x7FFF })]
          end

          # Every number the painted tile +name+ has in video memory: one for each store that shows it.
          def run_tile_numbers(name) = @run_tiles.filter_map { |(_, tile), number| number if tile == name }

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
          #
          # A PICTURE MADE OF A CONSOLE'S OWN PIECES (Assets::Image#piece_groups, a pose read from an
          # original's frames) is drawn as those pieces, each an entry of the table wherever it sits in the
          # picture, and not covered again on the picture's grid of 8. A frame's piece names a run of the
          # original's tiles, so cut this way each of its tiles is one of the original's, whole: the tile
          # another pose's piece or a background's cell shows, stored once (TileStore). Cut on the picture's
          # grid, a piece that sits off it is cut across the middle of every tile and shares none.
          #
          # The picture is cut here and given its tiles' numbers later (#sprite_picture), so the pictures of
          # one screen can have their longest runs of tiles stored first (#store_piece_runs_longest_first).
          def cut_sprite_picture(name, image, palette: nil)
            @cuts[name] ||= begin
              line = palette || palette_for(sprite_color_words(image), "sprites")
              blocks = image.piece_groups ? piece_blocks(image, line, palette) : cover_blocks(image, line, palette)
              Cut.new(name: name, width: image.width, height: image.height, blocks: blocks, pieced: !image.piece_groups.nil?)
            end
          end

          # THE RUNS OF TILES THE PIECES OF +names+ NAME (pictures cut already, of a console's own pieces),
          # stored the longest first. A short piece's tiles are often part of a long one's, as an original
          # draws a small piece from the middle of the tiles a big one uses; stored after the long run the
          # short one is found inside it, and stored before it the long run would hold those tiles again.
          def store_piece_runs_longest_first(names)
            runs = names.flat_map do |name|
              cut = @cuts.fetch(name)
              cut.pieced ? cut.blocks.select { |block| block.tiles.length > 1 }.map { |block| [name, block] } : []
            end
            runs.sort_by.with_index { |(_, block), at| [-block.tiles.length, at] }.each do |name, block|
              @tiles.word_of_run(block.tiles, block.columns, block.rows, sprite_taker(name))
            end
          end

          # The sprite picture +name+, cut already (#cut_sprite_picture), with each piece's tiles in the
          # store being added to (#with_tiles_of).
          def sprite_picture(name)
            @sprite_pictures[name] ||= begin
              cut = @cuts.fetch(name)
              pieces = cut.blocks.map do |block|
                Piece.new(dx: block.dx, dy: block.dy, palette: block.palette, columns: block.columns, rows: block.rows,
                          tile: @tiles.word_of_run(block.tiles, block.columns, block.rows, sprite_taker(name)))
              end
              SpritePicture.new(name: name, number: @sprite_pictures.length, width: cut.width, height: cut.height, pieces: pieces)
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
                     (0...PALETTES).find { |p| @palettes[p].nil? }
              unless line
                raise TooManyLists.new(scene_lists_full_message, scene: @colors_scene) if @colors_scene

                raise TooManyLists, "The lists of colours the sprites are drawn with, and the pictures, need more lists " \
                                    "than a Genesis holds (#{PALETTES}, shared with every other picture).#{painted_palette_words} " \
                                    "To fix this, draw the sprites with fewer lists of colours."
              end

              @palettes[line] ||= words
              @ordered[words] = line
            end
          end

          # A LIST OF COLOURS THE GAME CHANGES AS IT RUNS keeps a palette to itself, its colours in the order
          # of its places: changing it is writing other colours over that palette, so every pixel of a picture
          # drawn from it is the place it was drawn at, and nothing else's colours can share it. +key+ names
          # whose list it is, and +colors+ (15-bit, see-through left out) are the colours it starts with.
          #
          # In a game of +scene_colors+ the list's palette is one every screen keeps, since the game can change
          # the list whichever scene is up: so every list is given its palette before any scene takes its copy.
          def reserve_held_palette(key, colors)
            @held.fetch(key) do
              unless @scene_palette_sets.empty?
                raise LoweringError, "the list #{key.inspect} was given a palette after a scene took its copy of the palettes"
              end
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
          # turn. Colour 0 is the backdrop. In a game of +scene_colors+, the palettes every screen keeps,
          # which each scene writes its own over as it takes over.
          def color_memory
            colors = Array.new(PALETTES * PLACES, 0)
            colors[0] = @backdrop
            @shared_palettes.each_with_index { |list, p| list&.each_with_index { |c, i| colors[(p * PLACES) + i + 1] = word_shown(c) } }
            colors
          end

          # The colours of the game's that the colour memory's places were made from, 15-bit, a word each
          # in the colour memory's order (Runtime::Tint): the backdrop, then each palette's places. Two
          # colours of the game that make one word of the console's are the first one, which a fade can
          # tell apart from the other where the interpreter would.
          def colors15
            colors = Array.new(PALETTES * PLACES, 0)
            colors[0] = @backdrop_color
            @shared_palettes.each_with_index { |list, p| list&.each_with_index { |word, i| colors[(p * PLACES) + i + 1] = original_of(word) } }
            colors
          end

          # How many places of each palette hold a colour, for the runtime to write again when they change.
          def colors_used = @shared_palettes.map { |list| list ? list.length : 0 }

          # --- each screen's colours ---

          # The block, with the colours it allots kept in +scene+'s copy of the palettes, taken the first
          # time it is asked for. For nil, or in a game not built that way, in the palettes every screen
          # keeps. Every palette every screen keeps has to be allotted before the first copy is taken
          # (#scene_palette_writes checks).
          def with_colors_of(scene)
            return yield unless @scene_colors && scene

            set = @scene_palette_sets[scene] ||= PaletteSet.new(palettes: @shared_palettes.map { |list| list&.dup },
                                                                ordered: @shared_ordered.dup)
            @palettes = set.palettes
            @ordered = set.ordered
            @colors_scene = scene
            begin
              yield
            ensure
              @palettes = @shared_palettes
              @ordered = @shared_ordered
              @colors_scene = nil
            end
          end

          # The palettes +scene+ writes as it takes over: each its copy holds differently from the palettes
          # every screen keeps. Empty for a scene with no colours of its own. A palette the scene does not
          # write may hold what the last scene wrote, past the places every screen keeps, where none of
          # this scene's pictures draw.
          def scene_palette_writes(scene)
            palettes = @scene_palette_sets[scene]&.palettes
            return [] unless palettes

            (0...PALETTES).filter_map do |p|
              shared = @shared_palettes[p]
              if shared && palettes[p]&.first(shared.length) != shared
                raise LoweringError, "a palette every screen keeps was given colours after the scene #{scene.inspect} took its copy"
              end
              next if palettes[p].nil? || palettes[p] == shared

              PaletteWrite.new(palette: p, used: palettes[p].length,
                               colors: palette_colors(palettes[p].map { |word| original_of(word) }))
            end
          end

          # The tiles' pixels, tile 1 first (tile 0, the blank one, is in video RAM already): in a game of
          # +scene_tiles+, the ones every screen shows.
          def tile_data = @shared_tiles.tiles.drop(1).join

          # How many tiles the art has, the blank one not counted.
          def tile_count = @shared_tiles.length - 1

          # THE BUILD IS REFUSED WHERE ITS TILES DO NOT FIT, once every picture is made: the tiles every
          # screen shows, and in a game whose scenes each keep their own, each scene's with them. Asked
          # at the end and not as each tile is stored, so the refusal can say how many tiles are wanted
          # and which pictures took the most.
          def refuse_too_many_tiles!
            scene, store = [[nil, @shared_tiles], *@scene_stores.to_a].find { |_, tiles| tiles.length - 1 > @most_tiles }
            return unless store

            wanted = store.length - 1
            biggest = store.takers.sort_by { |taker, count| [-count, taker] }.first(BIGGEST_TAKERS_NAMED)
                           .map { |taker, count| "#{taker} (#{count})" }.join(", ")
            counted = "A Genesis has room for #{@most_tiles}. The pictures that use the most are: #{biggest}. The build " \
                      "counts a square that two pictures show for the first picture."
            if @beside_painting
              raise TooMuch, "The sprites over the painted screen need #{wanted} different 8×8 squares of picture. " \
                             "#{counted} The painted screen uses most of the video memory. To fix this, use fewer or " \
                             "smaller sprite pictures."
            end
            if scene
              raise TooManyTiles, "The scene :#{Modes.strip_scene_prefix(scene)} and the pictures that every scene shows need " \
                                  "#{wanted} different 8×8 squares of picture. #{counted} To fix this, use fewer different " \
                                  "pictures in that scene."
            end
            raise TooManyTiles, "The pictures need #{wanted} different 8×8 squares of picture. #{counted} To fix this, " \
                                "use fewer different pictures."
          end

          # How many of the pictures that took the most tiles a refusal names.
          BIGGEST_TAKERS_NAMED = 5

          # --- each screen's tiles ---

          # The block, with the tiles it makes kept in +scene+'s copy of the list, taken the first time
          # it is asked for. For nil, or in a game not built that way, in the list every screen shows.
          # Every tile every screen shows has to be made before the first copy is taken, or it would be
          # numbered where a scene's own tiles are (#scene_tile_data checks).
          def with_tiles_of(scene)
            return yield unless @scene_tiles && scene

            @tiles = (@scene_stores[scene] ||= @shared_tiles.dup)
            begin
              yield
            ensure
              @tiles = @shared_tiles
            end
          end

          # The number of the first tile of every scene's own: the first past the ones every screen shows.
          def first_scene_tile = @shared_tiles.length

          # The pixels of +scene+'s own tiles, from #first_scene_tile on, which go into video memory as it
          # takes over; empty for a scene with none of its own.
          def scene_tile_data(scene)
            own = @scene_stores[scene]
            return "".b unless own
            unless own.tiles.first(@shared_tiles.length) == @shared_tiles.tiles
              raise LoweringError, "a tile every screen shows was made after the scene #{scene.inspect} took its copy"
            end

            own.tiles.drop(@shared_tiles.length).join
          end

          private

          # A tile of a background drawn with other colours, made of the places its pixels were drawn at.
          def placed_background_cell(image, palette, taker)
            places = Array.new(64) do |at|
              image.tile_see_through_at?(at) ? 0 : image.place_at(at) || first_place(image, image.color_at(at))
            end
            [@tiles.word_of(TileBytes.of(places), taker), palette]
          end

          def sprite_taker(name) = "sprite picture :#{name}"

          # The colours +image+'s pixels are drawn in, as places of a palette hold them: for a picture of a
          # console's own pieces every piece's, the ones another piece hides too, since each piece keeps
          # tiles of its own.
          def sprite_color_words(image)
            unless image.piece_groups
              drawn = (0...(image.width * image.height)).select { |at| image.drawn_at?(at) }
              return drawn.map { |at| word_of(image.color_at(at)) }.uniq
            end

            places = image.pieces.flat_map { |_, _, own| own.bytes }.uniq - [0]
            places.map { |place| word_of(image.colors.fetch(place)) }.uniq
          end

          # +image+ covered on its own grid of 8 by blocks of up to four tiles each way (SpritePieces.cover).
          def cover_blocks(image, line, palette)
            cover = SpritePieces.cover(image.width, image.height, most: PIECE_SQUARES) do |x, y|
              at = (y * image.width) + x
              if !image.drawn_at?(at) then 0
              elsif palette then image.place_at(at) || first_place(image, image.color_at(at))
              else @palettes[line].index(word_of(image.color_at(at))) + 1
              end
            end
            cover.map do |block|
              Block.new(dx: block.across, dy: block.down, columns: block.columns, rows: block.rows, palette: line,
                        tiles: block.squares.map { |places| TileBytes.of(places) })
            end
          end

          # +image+ as the pieces it was made of, each group of them (Assets::Image#piece_groups) one block
          # where it makes a whole rectangle of up to four tiles each way, and a block for each piece of the
          # group where it does not. A block that draws nothing is left out. The picture's pieces are in
          # front first; the sprite table is written from its last row to its first, so the blocks are in
          # the other order.
          def piece_blocks(image, line, palette)
            at = 0
            blocks = image.piece_groups.flat_map do |count|
              group = image.pieces[at, count]
              at += count
              whole = rectangle_of_squares(group.flat_map { |piece| squares_of_piece(piece) })
              whole ? [whole] : group.map { |piece| rectangle_of_squares(squares_of_piece(piece)) }
            end
            blocks.reject { |_, _, _, _, squares| squares.all? { |own| own.bytes.all?(&:zero?) } }.reverse.map do |dx, dy, columns, rows, squares|
              tiles = squares.map do |own|
                TileBytes.of(own.bytes.map { |place| palette_place(image, place, line, palette) })
              end
              Block.new(dx: dx, dy: dy, columns: columns, rows: rows, tiles: tiles, palette: line)
            end
          end

          # What a pixel drawn at +place+ of +image+'s own list is in a tile: the place itself where the
          # palette's places are the list's, and else where the palette holds the place's colour.
          def palette_place(image, place, line, palette)
            return place if place.zero? || palette

            @palettes[line].index(word_of(image.colors.fetch(place))) + 1
          end

          # A piece of a picture ([dx, dy, places]) as its squares of 8×8, each [left, top, its 64 places].
          def squares_of_piece(piece)
            dx, dy, own = piece
            return [[dx, dy, own]] if Assets::Image.side(own) == Assets::PIECE_SIZE

            Assets::Image.quarters(own).map { |across, down, quarter| [dx + across, dy + down, quarter] }
          end

          # +squares+ as one rectangle, [left, top, columns, rows, its squares' places down each column and
          # then across], or nil where they are not every square of a rectangle of up to PIECE_SQUARES each way.
          def rectangle_of_squares(squares)
            side = Assets::PIECE_SIZE
            left = squares.map { |x, _, _| x }.min
            top = squares.map { |_, y, _| y }.min
            return nil unless squares.all? { |x, y, _| ((x - left) % side).zero? && ((y - top) % side).zero? }

            placed = squares.to_h { |x, y, own| [[(x - left) / side, (y - top) / side], own] }
            columns = placed.keys.map(&:first).max + 1
            rows = placed.keys.map(&:last).max + 1
            return nil if columns > PIECE_SQUARES || rows > PIECE_SQUARES || placed.length != squares.length || columns * rows != squares.length

            [left, top, columns, rows, (0...columns).flat_map { |column| (0...rows).map { |row| placed.fetch([column, row]) } }]
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

          # The 15-bit colour of the game's a place's contents were first made from.
          def original_of(held) = @originals.fetch(held, 0)

          # The refusal for a scene whose own pictures need more palettes than the ones every screen keeps
          # leave it.
          def scene_palettes_full_message
            scene = Modes.strip_scene_prefix(@colors_scene)
            kept = @shared_palettes.count(&:itself)
            "The pictures of the scene :#{scene} use more colours than a Genesis can show. A Genesis holds " \
              "#{PALETTES} sets of #{OWN_COLORS} colours for the backgrounds and sprites together. The pictures " \
              "and lists of colours that every scene shows use #{kept} of the sets, and the scene :#{scene} gets " \
              "the other #{PALETTES - kept}. To fix this, use fewer colours in the pictures of the scene :#{scene}."
          end

          # The same for the lists of colours a scene's own pictures are drawn with: what happened, for the
          # lowering to add why and what to do (Lowering::Picture#too_many_lists_message).
          def scene_lists_full_message
            scene = Modes.strip_scene_prefix(@colors_scene)
            kept = @shared_palettes.count(&:itself)
            "The scene :#{scene} draws its pictures with more lists of colours than a Genesis has for that scene. " \
              "A Genesis holds #{PALETTES} sets of #{OWN_COLORS} colours. The pictures and lists of colours that every " \
              "scene shows use #{kept} of the sets, and the scene :#{scene} gets the other #{PALETTES - kept}."
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
              raise TooManyColors, scene_palettes_full_message if @colors_scene

              raise TooManyColors, "The pictures use more colours than a Genesis can show. It holds #{PALETTES} sets of " \
                                   "#{OWN_COLORS} colours for the backgrounds and sprites together.#{painted_palette_words} " \
                                   "To fix this, use fewer colours in the pictures."
            end

            @palettes[unused] = colors.dup
            unused
          end
        end
      end
    end
  end
end
