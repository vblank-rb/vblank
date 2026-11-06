# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A GAME'S PICTURES, MADE INTO WHAT A SUPER NINTENDO DRAWS FROM, while the program is built.
        #
        # The Super Nintendo draws everything from TILES: 8×8 pictures in which each pixel is a
        # number, here four bits — one of sixteen places in a list of colours (a PALETTE). A tile
        # is kept as four BITPLANES: for each row, a byte holding bit 0 of each of its eight
        # pixels, then a byte holding bit 1, and after all eight rows the same again for bits 2 and
        # 3 — 32 bytes a tile. A background is a grid of cells (a MAP), each naming a tile and one of
        # eight palettes for it; a sprite is a tile placed anywhere, drawn from one of eight palettes
        # of its own. Place 0 of every palette is see-through, and where nothing is drawn the screen
        # shows colour 0 of the first palette, the BACKDROP, black as the interpreter's empty
        # screen is.
        #
        # So a picture the game declared is cut into 8×8 pieces, each piece's pixels written as
        # places in a palette of fifteen colours, and the palettes the game's pictures need gathered
        # into the console's colour memory (CGRAM): 128 colours for the backgrounds, then 128 for
        # the sprites. What cannot fit — more colours than the palettes hold, more tiles than video
        # memory has room for — is refused here with plain words.
        class Art
          # A palette's places, and how many hold a colour of the picture's own: place 0 is
          # see-through.
          PLACES = Console::SUPER_NINTENDO.list_colors
          OWN_COLORS = PLACES - 1
          PALETTES = 8

          # How many tiles there is room for in video memory (see Runtime::Picture for the layout):
          # 1024 for the backgrounds and 512 for the sprites.
          MOST_BACKGROUND_TILES = 1024
          MOST_SPRITE_TILES = 512

          # In a game with a status bar on the third layer the last 64 of the 1024 places hold
          # that layer's map instead (Runtime::Picture::THIRD_LAYER_MAP).
          THIRD_LAYER_TILE_PLACES = 960

          TILE_BYTES = 32

          # THE THIRD LAYER'S TILES are four-colour: two bit planes, so each pixel is one of four
          # places (place 0 see-through) and a tile is 16 bytes, the first half of a sixteen-colour
          # tile's 32 (#tile_bytes). The console reads them from video memory address 0, as the
          # other two layers do, counting 16 bytes a tile where those count 32; so one place of the
          # backgrounds' list holds two of them, numbered twice its own number and one more.
          # Their number is ten bits of a cell, so those places are among the first 512.
          BAR_TILE_BYTES = 16
          BAR_TILE_SLOTS = 512

          # And their colours are eight lists of three (and see-through), in the first 32 colours
          # of the colour memory: list n is colours 4n+1 to 4n+3. Those are where the backgrounds'
          # lists 0 and 1 are, so each four of the bar's lists take one of the backgrounds' eight
          # away from them (#reserve_bar_palettes).
          BAR_PALETTES = 8
          BAR_OWN_COLORS = 3
          BAR_PALETTES_A_LIST = PLACES / (BAR_OWN_COLORS + 1)

          # A tile number and attributes as a cell of a map holds them: the tile in the low ten
          # bits, the palette in the next three.
          PALETTE_SHIFT = 10

          # A cell's priority bit: with it, BG1's cells are drawn in front of a sprite of priority
          # 2, which is in front of BG2's (Mode 1's order, front first: sprites of priority 3, BG1
          # high, BG2 high, sprites of 2, BG1 low, BG2 low, sprites of 1).
          CELL_IN_FRONT = 0x2000

          # A sprite's picture, cut into pieces: each piece where it sits in the picture, its tile
          # and its palette. A +big+ piece is a whole square of 16×16, which the console draws from
          # four tiles as one row of its table of 128. +number+ is what the runtime knows it by.
          Piece = Data.define(:dx, :dy, :tile, :palette, :big) do
            def initialize(dx:, dy:, tile:, palette:, big: false) = super
          end
          SpritePicture = Data.define(:name, :number, :width, :height, :pieces)

          # THE TABLE OF SPRITES HAS 128 ROWS, and a character is often bigger than one 8×8 tile, so
          # a screen of big sprites cut into 8×8 pieces runs out of rows the console's own games do
          # not. The console can be told a row is the larger of its two sprite sizes, 16×16 here.
          # It then draws four tiles from one row: the one the row names, the one beside it, and the
          # two under those. Under means sixteen on, since the console keeps its sprite tiles in
          # rows of sixteen, and within one page of 256: the row after the last of a page is that
          # page's first, not the next page's. So a square's four tiles have to be laid out in that
          # shape, which is why this class places tiles rather than only listing them.
          SQUARE = 16
          TILES_ACROSS = 16
          TILE_ROWS_IN_PAGE = 16

          # A square with one piece drawn saves no row and costs four tiles.
          SQUARE_LEAST_PIECES = 2

          # A grid of map cells, as the console's video memory holds it: +columns+ and +rows+ of
          # 32 or 64, and the bytes, two a cell, laid out in screens of 32×32 cells — the left top
          # screen, then the right one, then the two below — as the console reads a map wider or
          # taller than one screen.
          Grid = Data.define(:number, :columns, :rows, :bytes) do
            # The size bits of a background's map register (BGnSC): one screen, two across, two
            # down or four.
            def size_bits = (columns == 64 ? 1 : 0) | (rows == 64 ? 2 : 0)
          end

          # Raised for art the console cannot hold.
          class TooMuch < LoweringError; end

          # The game's backgrounds need more sets of colours than one list of eight can hold, which
          # is not yet the end of it: built again, each scene brings its own in (+screen_colors+).
          class TooManyBackgroundColors < TooMuch; end

          # The same for the sprites' (+sprite_colors+).
          class TooManySpriteColors < TooMuch; end

          # The same for the sprites' tiles (+scene_tiles+).
          class TooManySpriteTiles < TooMuch; end

          # One screen's sprites do not fit video memory cut into squares of 16×16, in a game whose
          # screens each keep their own. That screen alone is cut small, and the others keep their
          # squares: a title's words in squares take half the rows of the sprite table they take
          # cut small, and it has only 128.
          class ScreenSpritesFull < TooMuch
            attr_reader :scene

            def initialize(message, scene:)
              super(message)
              @scene = scene
            end
          end

          # The same for the backgrounds' tiles (+background_tiles+).
          class TooManyBackgroundTiles < TooMuch; end

          # A status bar on the third layer whose art does not fit four-colour tiles. Nothing a
          # second build tries can help, so it is not one of TooMuch.
          class BarArtTooColorful < LoweringError; end

          attr_reader :background_tiles, :sprite_tiles, :grids, :sprite_pictures

          # WHAT A BACKGROUND TILE'S PIXELS COME TO, worked out once a build. A map names the same
          # tile in many cells, and a build is tried several times over (SNES#build), and each time
          # a cell is made its picture was read pixel by pixel again: which colours it draws, and the
          # 32 bytes of each 8×8 quarter. Those depend on the picture alone, and on where its
          # colours sit in the palette it is drawn from, so they are kept here by exactly that.
          #
          # Which palette a cell takes, and which tile number, are NOT kept: those are the Art's
          # choices, made against the palettes and tiles placed so far, and a cell made twice can
          # take an earlier palette the second time (one that has since gained its colours). So
          # every call still makes those choices as it always did, and only reading the pixels is
          # saved.
          #
          # It is one object for the whole build, handed to each try's Art, and shared as it is by
          # the copies a measurement makes (Lowering#bytes_of): what it holds is true of the
          # pictures whatever a try or a measurement places.
          class TileMemo
            def initialize
              @colors = {}
              @tiles = {}
              @joined = {}.compare_by_identity
            end

            # The colours the first +count+ pixels of +image+ draw, each once, in the order the
            # pixels first draw them.
            def colors_drawn(image, count)
              @colors[[image, count]] ||= (0...count).reject { |at| image.tile_see_through_at?(at) }
                                                     .map { |at| image.color_at(at) }.uniq.freeze
            end

            # The bytes the block makes of +image+'s first +count+ pixels, kept by +places+: where
            # each of its colours is in the palette it is drawn from (#places_of), or :held for a
            # picture drawn from a list place for place.
            def tiles(image, count, places) = @tiles[[image, count, places]] ||= Ractor.make_shareable(yield)

            # A big tile's quarters as one string, the key Art finds its tile number by.
            def joined(quarters) = @joined[quarters] ||= quarters.join.freeze

            # Where each of +colors+ is in +palette+.
            def self.places_of(colors, palette) = colors.map { |color| palette.index(color) }
          end

          # The backdrop of a game that names none: black, as the interpreter's empty screen is.
          BACKDROP = 0

          # +backdrop+ is the colour the game shows wherever nothing is drawn (`screen ... backdrop:`),
          # a 15-bit colour, or nil for black. +sprite_squares+ draws a sprite's squares of 16×16 as
          # one row each. A square keeps its four tiles together, so it shares them less often than
          # 8×8 pieces do, and a game that only just fits is built without (SNES#build).
          #
          # EACH SCREEN'S COLOURS (+screen_colors+). The console draws a background from eight sets
          # of colours at once, and nothing says they cannot change between two screens, so a game's
          # own screens load theirs as they load their maps: dozens across a game, and never more
          # than eight up. A game that does not fit the eight is built that way (SNES#build). What
          # every screen shows takes its sets first (#background_palettes). Then each scene starts
          # from a copy of them and adds its own, so it can hand out all that are left and even
          # add to one of theirs, and what it brings in as it takes over is whatever differs from
          # those (#scene_colors). The sprites' eight sets go the same way (+sprite_colors+), the
          # pictures only one scene's sprites show drawn from that scene's (#sprite_palettes), so a
          # list of one screen pushes out no list of another screen, which never share a frame.
          #
          # EACH SCREEN'S SPRITE TILES (+scene_tiles+). Video memory holds 512 sprite tiles at once, and
          # nothing says they stay the same ones. Those of what every screen keeps go in at power-on
          # and stay. Each scene starts from a copy of that list and adds its own in the places left
          # (#with_sprite_tiles_of), and those come in as it takes over (#scene_sprite_tiles). The
          # backgrounds' 1024 tiles go the same way (+background_tiles+, #with_background_tiles_of).
          #
          # A STATUS BAR ON THE THIRD LAYER (+third_layer+, #bar_cell) takes the last 64 tile places
          # for its map (Runtime::Picture::THIRD_LAYER_MAP), so the backgrounds keep 960.
          def initialize(backdrop: nil, sprite_squares: true, screen_colors: false, sprite_colors: false, scene_tiles: false,
                         background_tiles: false, small_sprite_scenes: [], third_layer: false, tile_memo: TileMemo.new)
            @tile_memo = tile_memo
            @most_background_tiles = third_layer ? THIRD_LAYER_TILE_PLACES : MOST_BACKGROUND_TILES
            @bar_palettes = []
            @bar_tile_numbers = { blank_bar_tile => 0 }
            @bar_open_slots = {}.compare_by_identity
            @sprite_squares = sprite_squares
            @small_sprite_scenes = small_sprite_scenes
            @scene_of_sprite_tiles = nil
            @screen_colors = screen_colors
            @sprite_colors = sprite_colors
            @scene_tiles = scene_tiles
            @scene_background_tiles = background_tiles
            @scene_sprite_stores = {}
            @scene_background_stores = {}
            @scene_palettes = {}
            @scene_sprite_palettes = {}
            @scene_sprite_held = {}
            @sprite_square_numbers = {}
            @square_tile_numbers = {}
            @backdrop = (backdrop || BACKDROP) & 0x7FFF
            @background_tiles = [blank_tile] # tile 0: nothing drawn, for an empty cell
            @background_tile_numbers = { blank_tile => 0 }
            @background_palettes = [[]] # each a list of up to fifteen colours
            @sprite_tiles = []
            @sprite_tile_numbers = {}
            @sprite_palettes = [] # each a list of up to fifteen colours, or nil for one not used yet
            @sprite_palettes_for = { false => (0...PALETTES), true => (0...PALETTES) }
            @unmixed_scenes = []
            @held_palettes = {} # whose list => its palette (#held_palette)
            @held = { backgrounds: [], sprites: [] }
            @scene_held = {} # a scene -> the same, for its own copy of the background palettes
            @sprite_pictures = {}
            @grids = []
          end

          # --- backgrounds ---

          # A cell with nothing in it names tile 0, and on a layer of 16×16 tiles the console draws that
          # as tile 0 and the three that make up a big tile with it. In a game of 8×8 tiles too, one
          # could land there and show in every empty cell, so those three stay blank.
          def reserve_blank_big_tile
            BIG_TILE_PLACES.drop(1).each { |place| @background_tiles[place] = blank_tile }
          end

          # The cell +image+ (an Assets::Image of 8×8) makes in a map: its tile number and its
          # palette, as two numbers.
          # +held+ is the palette of a list the game changes (#held_background_palette), whose
          # tiles are drawn from it place for place. +scene+ is the scene whose own background this
          # is, in a game of +screen_colors+, and nil for what every screen shows; +tile_scene+ the
          # same for its tiles, in a game of +background_tiles+.
          def background_cell(image, held: nil, scene: nil, tile_scene: nil)
            palettes = background_palettes(scene)
            colors = @tile_memo.colors_drawn(image, 64)
            palette = held || palette_for(palettes, colors, backgrounds_in_message(scene))
            bytes = @tile_memo.tiles(image, 64, held ? :held : TileMemo.places_of(colors, palettes[palette])) do
              tile_bytes(Array.new(64) do |at|
                if image.tile_see_through_at?(at) then 0
                elsif held then place_in_list(image, at)
                else palettes[palette].index(image.color_at(at)) + 1
                end
              end)
            end
            number = with_background_tiles_of(tile_scene) do
              @background_tile_numbers[bytes] ||= begin
                at = @background_tiles.index(nil) || @background_tiles.length
                refuse_too_many!(at, @most_background_tiles, "backgrounds", background_tiles_error)
                @background_tiles[at] = bytes
                at
              end
            end
            [number, palette]
          end

          # THE CELL A 16×16 TILE MAKES, on a background the console draws from tiles of that size. The
          # console still keeps 8×8 tiles, and draws a big one as four: the one a cell names, the one
          # after it, and the two sixteen on (the row below, in video memory's rows of sixteen tiles).
          # So the four quarters of +image+ (an Assets::Image of 16×16) go in four places that
          # pattern takes, the first of them at an even place in an even row, and the whole tile is
          # drawn from one palette. Its tile number (the top left quarter's) and the palette.
          def background_big_cell(image, held: nil, scene: nil, tile_scene: nil)
            palettes = background_palettes(scene)
            colors = @tile_memo.colors_drawn(image, 256)
            palette = held || palette_for(palettes, colors, backgrounds_in_message(scene))
            quarters = @tile_memo.tiles(image, 256, held ? :held : TileMemo.places_of(colors, palettes[palette])) do
              (0...4).map do |quarter|
                tile_bytes(Array.new(64) do |at|
                  pixel = ((((quarter / 2) * 8) + (at / 8)) * 16) + ((quarter % 2) * 8) + (at % 8)
                  if image.tile_see_through_at?(pixel) then 0
                  elsif held then place_in_list(image, pixel)
                  else palettes[palette].index(image.color_at(pixel)) + 1
                  end
                end)
              end
            end
            number = with_background_tiles_of(tile_scene) do
              @background_tile_numbers[@tile_memo.joined(quarters)] ||= begin
                at = free_big_place
                refuse_too_many!(at + BIG_TILE_PLACES.last, @most_background_tiles, "backgrounds", background_tiles_error)
                BIG_TILE_PLACES.zip(quarters) { |offset, bytes| @background_tiles[at + offset] = bytes }
                at
              end
            end
            [number, palette]
          end

          # THE CELL +image+ (8×8) MAKES ON THE THIRD LAYER, for the status bar +bar+ (a name, for the
          # words of a refusal): its four-colour tile's number and its list, of the bar's eight. A
          # tile of more than three colours, or more colours than the eight lists hold, is refused
          # naming the bar and the tile (+tile+).
          def bar_cell(image, bar:, tile:)
            drawn = (0...64).reject { |at| image.tile_see_through_at?(at) }
            colors = drawn.map { |at| image.color_at(at) }.uniq
            if colors.length > BAR_OWN_COLORS
              raise BarArtTooColorful, "The status bar :#{bar} shows the tile :#{tile} in #{colors.length} colours. " \
                                       "On a Super Nintendo, a status bar beside two backgrounds uses tiles of four " \
                                       "colours. A tile shows #{BAR_OWN_COLORS} colours and see-through. To fix this, " \
                                       "draw the tile :#{tile} in #{BAR_OWN_COLORS} colours or fewer."
            end

            palette = bar_palette_for(colors, bar)
            places = Array.new(64) do |at|
              image.tile_see_through_at?(at) ? 0 : @bar_palettes[palette].index(image.color_at(at)) + 1
            end
            [bar_tile_number(tile_bytes(places).byteslice(0, BAR_TILE_BYTES)), palette]
          end

          # THE BACKGROUNDS' LISTS THE BAR'S COLOURS ARE IN, kept from the other backgrounds: one for
          # each four lists of the bar's. Called once the bar's cells are made and before any other
          # background's, so those are the first lists and nothing else is in them yet.
          def reserve_bar_palettes
            ((@bar_palettes.length + BAR_PALETTES_A_LIST - 1) / BAR_PALETTES_A_LIST).times do |palette|
              @background_palettes[palette] = Array.new(OWN_COLORS, BAR_LIST_HOLDER)
              @held[:backgrounds] << palette
            end
          end

          # What a background list given to the bar holds until the colour memory is written: no
          # colour a picture can have, so no picture's colours are found in it.
          BAR_LIST_HOLDER = -1

          # A LIST THE GAME CHANGES AS IT RUNS has a palette to itself, its colours in the order of its
          # places: changing it is writing another list over that palette, so every pixel has to
          # be the place it was drawn at, and nothing else's colours can share it. +key+ says whose
          # it is, a background's name and a list or a sprites' list. Its colours are the first ones
          # it holds; the rest go in as the game runs (Runtime::Tint's rt_colors_hold).
          def held_background_palette(key, colors, scene: nil)
            held_palette(background_palettes(scene), key, colors, backgrounds_in_message(scene), 0...PALETTES)
          end

          # The sets of colours +scene+'s own backgrounds are drawn from: in a game of +screen_colors+
          # a copy of what every screen shows, taken the first time it is asked for, by when those
          # are all made (Lowering::Picture#make_shared_background_colors). Otherwise the game's.
          def background_palettes(scene)
            return @background_palettes unless scene

            @scene_held[scene] ||= @held[:backgrounds].dup
            @scene_palettes[scene] ||= @background_palettes.map { |list| list&.dup }
          end

          # What +scene+ brings in as it takes over, as [where in the colour memory, its colours] for
          # each set: those that are not as every screen left them. Never none, since the routine
          # that copies them counts down from how many (Runtime::Tint's rt_colors_hold).
          def scene_colors(scene)
            palettes = background_palettes(scene)
            changed = palettes.each_index.select { |palette| palettes[palette] && palettes[palette] != @background_palettes[palette] }
            sprites = scene_sprite_colors(scene)
            changed = [(0...PALETTES).find { |palette| !@scene_held[scene].include?(palette) } || 0] if changed.empty? && sprites.empty?
            changed.map { |palette| [background_palette_at(palette), palettes[palette] || []] } + sprites
          end

          # The sets of colours +scene+'s own sprites are drawn from: in a game of +sprite_colors+ a
          # copy of what every screen keeps, taken the first time it is asked for, by when those are
          # all made (Lowering::Picture#reserve_shared_sprite_colors). Otherwise the game's.
          def sprite_palettes(scene)
            return @sprite_palettes unless scene

            @scene_sprite_held[scene] ||= @held[:sprites].dup
            @scene_sprite_palettes[scene] ||= @sprite_palettes.map { |list| list&.dup }
          end

          def held_sprite_palette(key, colors, mixed: false, scene: nil)
            allocate_sprite_palette(mixed, scene) { |within| held_palette(sprite_palettes(scene), key, colors, "sprites", within) }
          end

          # The colours and tiles of +image+, a picture of what every screen keeps, placed before any
          # scene takes its copies, whichever order pictures are made in. Making the picture itself
          # later finds both where they were put.
          def reserve_shared_sprite_picture(image, mixed: false, held: nil)
            sprite_picture(:reserved, image, mixed: mixed, held: held)
            @sprite_pictures.delete(:reserved)
          end

          # What +scene+ brings into video memory as it takes over, as [the first tile, its tiles'
          # bytes], or nil for a scene with none of its own.
          def scene_sprite_tiles(scene) = tiles_past_shared(@scene_sprite_stores.dig(scene, 0), @sprite_tiles)

          # The same for its background tiles.
          def scene_background_tiles(scene) = tiles_past_shared(@scene_background_stores.dig(scene, 0), @background_tiles)

          # The palette kept under +key+, or nil for a list nothing is drawn with.
          def held_palette_of(key) = @held_palettes[key]

          # Where a palette starts in the 512 bytes of the colour memory: the backgrounds' from
          # colour 1 of each, the sprites' after them.
          def background_palette_at(palette) = ((palette * PLACES) + 1) * 2
          def sprite_palette_at(palette) = ((128 + (palette * PLACES)) + 1) * 2

          def held_palette(palettes, key, colors, what, within)
            @held_palettes.fetch(key) do
              held = held_in(palettes)
              free = within.find { |p| palettes[p].nil? || (palettes[p].empty? && !held.include?(p)) }
              unless free
                raise too_much_error_for(palettes), "The #{what} hold more lists of colours the game changes than a Super " \
                                              "Nintendo can show. It holds #{PALETTES} sets of #{OWN_COLORS} colours. " \
                                              "To fix this, change fewer lists."
              end

              palettes[free] = colors.dup
              held << free
              @held_palettes[key] = free
            end
          end

          # Which place of its list pixel +at+ of +image+ was drawn at.
          # Place 0 is see-through and holds no colour to find, whatever is written there.
          def place_in_list(image, at)
            image.place_at(at) || (1...image.colors.length).find { |place| image.colors[place] == image.color_at(at) }
          end

          # Where a big tile's quarters go, from the place its cell names.
          BIG_TILE_PLACES = [0, 1, 16, 17].freeze

          # The first place a big tile fits: even, in an even row of sixteen, with all four places free.
          def free_big_place
            at = 0
            at += 2 until (at % 32) < 16 && BIG_TILE_PLACES.all? { |offset| @background_tiles[at + offset].nil? }
            at
          end

          # The map +cells+ ([tile, palette] or nil, by row and column) made into the console's grid
          # of +columns+ × +rows+ cells, and its number; +in_front+ gives every cell drawn the
          # priority bit (CELL_IN_FRONT).
          def grid(cells, columns, rows, in_front: false)
            bytes = +"".b
            (rows / 32).times do |screen_row|
              (columns / 32).times do |screen_column|
                32.times do |row|
                  32.times do |column|
                    cell = cells.dig((screen_row * 32) + row, (screen_column * 32) + column)
                    word = cell ? cell[0] | (cell[1] << PALETTE_SHIFT) | (in_front ? CELL_IN_FRONT : 0) : 0
                    bytes << [word].pack("v")
                  end
                end
              end
            end
            @grids << Grid.new(number: @grids.length, columns: columns, rows: rows, bytes: bytes)
            @grids.last
          end

          # --- sprites ---

          # The palettes a see-through sprite is drawn from: the console's colour math reaches a
          # sprite drawn from the last four alone, so in a game with see-through sprites those are
          # theirs and the first four the others' (#split_sprite_palettes!).
          MIXED_SPRITE_PALETTES = (4...PALETTES)

          # Keeps the last four sprite palettes for see-through sprites, before any sprite is made.
          #
          # A see-through layer that only some scenes show leaves the colour math off while any other
          # scene is up (Lowering::Picture#emit_see_through_for_scene), and then the last four sets
          # blend nothing. +unmixed_scenes+ names those scenes: in a game where each scene brings its
          # own sprite colours in (+sprite_colors+), a picture of one of them that fills the first
          # four goes on into the last four, as a console game's stage does with all eight.
          def split_sprite_palettes!(unmixed_scenes: [])
            @sprite_palettes_for = { false => (0...MIXED_SPRITE_PALETTES.begin), true => MIXED_SPRITE_PALETTES }
            @unmixed_scenes = unmixed_scenes
          end

          # The sprite picture +name+ (an Assets::Image), cut into pieces. A picture whose width or
          # height is not a multiple of 8 has its last pieces' extra pixels left undrawn.
          # +mixed+ draws it from a see-through sprite's palettes (#split_sprite_palettes!).
          # +held+ is the palette of a list the game changes (#held_sprite_palette), whose pictures
          # are drawn from it place for place. +scene+ is the one scene whose sprites show it, in a game
          # of +sprite_colors+, and nil for what every screen keeps; +tile_scene+ the same for its
          # tiles, in a game of +scene_tiles+. +number+ is its place in the table of pictures, where
          # it is not made in that order.
          def sprite_picture(name, image, mixed: false, held: nil, scene: nil, tile_scene: nil, number: @sprite_pictures.length)
            @sprite_pictures[name] ||= with_sprite_tiles_of(tile_scene) do
              next pieced_sprite_picture(name, image, mixed, held, scene, number) if image.pieces

              palettes = sprite_palettes(scene)
              palette = held || allocate_sprite_palette(mixed, scene) do |within|
                palette_for(palettes, sprite_image_colors(image), "sprites", within)
              end
              cut =SpritePieces.cut(image.width, image.height) do |x, y|
                i = (y * image.width) + x
                if !image.drawn_at?(i) then 0
                elsif held then place_in_list(image, i)
                else palettes[palette].index(image.color_at(i)) + 1
                end
              end
              squares = cut.to_h { |across, down, places| [[across, down], places] }
              pieces = squares_here? ? square_pieces(squares, image, palette) : []
              pieces += squares.map do |(across, down), places|
                Piece.new(dx: across, dy: down, tile: sprite_tile_number(tile_bytes(places)), palette: palette)
              end
              SpritePicture.new(name: name, number: number, width: image.width, height: image.height, pieces: pieces)
            end
          end

          # Whether any picture has a square of 16×16, which the runtime then reads off each piece.
          def sprite_squares? = @sprite_pictures.each_value.any? { |picture| picture.pieces.any?(&:big) }

          # --- tiles a game paints from a list (a run: Builder::TileRuns) ---
          #
          # Their pixels are not known while the game is built, so each run has tiles of its own,
          # blank until the game copies its list into them, never merged with another tile, and a
          # palette whose places are its colours in the order the game listed them: each four
          # bits of the list name a place (Runtime::Picture's rt_tile_run_copy), place 0 see-through.

          # +count+ background tiles for a run in +colors+ (place 0 first): the first's number, and
          # the palette: +held+ for a run in a list the game changes (#held_background_palette).
          def background_run(colors, count, held: nil, scene: nil, tile_scene: nil)
            palette = held || run_palette(background_palettes(scene), colors, backgrounds_in_message(scene))
            first = with_background_tiles_of(tile_scene) do
              at = @background_tiles.length
              refuse_too_many!(at + count - 1, @most_background_tiles, "backgrounds", background_tiles_error)
              count.times { @background_tiles << blank_tile }
              at
            end
            [first, palette]
          end

          # +count+ big tiles for a run in +colors+, each in the four places the console draws one from
          # (#background_big_cell), blank until the game shows a picture: each one's number, and the
          # palette.
          def background_big_run(colors, count, held: nil, scene: nil, tile_scene: nil)
            palette = held || run_palette(background_palettes(scene), colors, backgrounds_in_message(scene))
            numbers = with_background_tiles_of(tile_scene) do
              Array.new(count) do
                at = free_big_place
                refuse_too_many!(at + BIG_TILE_PLACES.last, @most_background_tiles, "backgrounds", background_tiles_error)
                BIG_TILE_PLACES.each { |offset| @background_tiles[at + offset] = blank_tile }
                at
              end
            end
            [numbers, palette]
          end

          # +values+, tiles as a painted run's list keeps them (32 bytes each, two places a byte, the
          # left one low), as the bytes of the console's own form.
          def in_console_form(values)
            values.each_slice(TILE_BYTES).flat_map do |tile|
              tile_bytes(tile.flat_map { |byte| [byte & 0x0F, (byte >> 4) & 0x0F] }).bytes
            end
          end

          # A sprite's picture +name+ of +width+ × +height+, painted from a list in +colors+: a piece
          # for each 8×8 tile, left to right and then top to bottom, as the list holds them.
          def sprite_run_picture(name, width, height, colors, number: @sprite_pictures.length)
            palette = run_palette(@sprite_palettes, colors, "sprites", @sprite_palettes_for.fetch(false))
            across = width / 8
            count = across * (height / 8)
            first = first_free_tiles(count)
            refuse_too_many!(first + count - 1, MOST_SPRITE_TILES, "sprites", sprite_tiles_error)
            pieces = (0...(height / 8)).flat_map do |down|
              (0...across).map do |left|
                @sprite_tiles[first + (down * across) + left] = blank_tile
                Piece.new(dx: left * 8, dy: down * 8, tile: first + (down * across) + left, palette: palette)
              end
            end
            @sprite_pictures[name] = SpritePicture.new(name: name, number: number, width: width, height: height, pieces: pieces)
          end

          # --- the colour memory ---

          # All 256 colours, as the console's colour memory holds them: two bytes each, the
          # backgrounds' eight palettes and then the sprites'. Colour 0 is the backdrop.
          def cgram
            colors = Array.new(256, 0)
            colors[0] = @backdrop
            @background_palettes.each_with_index { |list, p| list&.each_with_index { |c, i| colors[(p * PLACES) + i + 1] = c } }
            @sprite_palettes.each_with_index { |list, p| list&.each_with_index { |c, i| colors[128 + (p * PLACES) + i + 1] = c } }
            bar_lists = (@bar_palettes.length + BAR_PALETTES_A_LIST - 1) / BAR_PALETTES_A_LIST
            (1...(bar_lists * PLACES)).each { |at| colors[at] = 0 }
            @bar_palettes.each_with_index do |list, p|
              list.each_with_index { |c, i| colors[(p * (BAR_OWN_COLORS + 1)) + i + 1] = c }
            end
            colors.pack("v*")
          end

          # The colours a picture can show, as [first, count] runs of the colour memory: the
          # backdrop and the backgrounds' palettes the game's pictures use, then the sprites'. The
          # rest are never drawn from, so a fade has no need to move them.
          def colors_shown
            runs = [[0, [@background_palettes, *@scene_palettes.values].map(&:length).max * PLACES]]
            sprites = [@sprite_palettes, *@scene_sprite_palettes.values].map(&:length).max
            runs << [PALETTES * PLACES, sprites * PLACES] unless sprites.zero?
            runs
          end

          # The tiles in video memory from power-on: those every screen keeps, with those of +scene+,
          # the scene the game opens on, already beside them in a game that keeps tiles by scene.
          def sprite_tile_data(scene = nil) = ((@scene_sprite_stores.dig(scene, 0) || @sprite_tiles).map { |bytes| bytes || blank_tile }.join)
          def background_tile_data(scene = nil) = ((@scene_background_stores.dig(scene, 0) || @background_tiles).map { |bytes| bytes || blank_tile }.join)

          private

          def blank_tile = ("\0".b * TILE_BYTES)
          def blank_bar_tile = ("\0".b * BAR_TILE_BYTES)

          # The bar's list holding every one of +colors+, adding them to one with room, or starting
          # another of the eight; refused naming +bar+ where none is left.
          def bar_palette_for(colors, bar)
            found = @bar_palettes.index { |list| (colors - list).empty? }
            return found if found

            roomy = @bar_palettes.each_index.select { |p| (@bar_palettes[p] | colors).length <= BAR_OWN_COLORS }
                                 .max_by { |p| (@bar_palettes[p] & colors).length }
            return roomy.tap { @bar_palettes[roomy] |= colors } if roomy

            if @bar_palettes.length >= BAR_PALETTES
              raise BarArtTooColorful, "The tiles of the status bar :#{bar} use more colours than its layer holds. On a " \
                                       "Super Nintendo, a status bar beside two backgrounds uses tiles of four colours. " \
                                       "The layer holds #{BAR_PALETTES} lists of #{BAR_OWN_COLORS} colours, and each " \
                                       "tile uses one list. To fix this, use fewer colours in the bar's tiles."
            end

            @bar_palettes << colors.dup
            @bar_palettes.length - 1
          end

          # A four-colour tile's number: half of one of the backgrounds' places, the second half of
          # the last place started where it is free (BAR_TILE_BYTES). A place is never shared with a
          # sixteen-colour tile, and is not one #background_cell can find by its bytes. Each list of
          # places a scene keeps (#with_background_tiles_of) has a half free of its own.
          def bar_tile_number(bytes)
            @bar_tile_numbers[bytes] ||= begin
              open = @bar_open_slots.delete(@background_tiles)
              if open
                @background_tiles[open] = @background_tiles[open].byteslice(0, BAR_TILE_BYTES) + bytes
                (open * 2) + 1
              else
                slot = @background_tiles.index(nil) || @background_tiles.length
                refuse_too_many!(slot, [@most_background_tiles, BAR_TILE_SLOTS].min, "backgrounds", background_tiles_error)
                @background_tiles[slot] = bytes + blank_bar_tile
                @bar_open_slots[@background_tiles] = slot
                slot * 2
              end
            end
          end

          # The palettes of +palettes+ that hold a list the game changes, which nothing else can share.
          def held_in(palettes)
            return @held[:sprites] if palettes.equal?(@sprite_palettes)
            return @held[:backgrounds] if palettes.equal?(@background_palettes)

            sprites_of = @scene_sprite_palettes.find { |_, own| own.equal?(palettes) }
            return @scene_sprite_held.fetch(sprites_of.first) if sprites_of

            @scene_held.fetch(@scene_palettes.find { |_, own| own.equal?(palettes) }.first)
          end

          # What +scene+'s sprites bring in as it takes over, as #scene_colors says it.
          def scene_sprite_colors(scene)
            palettes = @scene_sprite_palettes.fetch(scene, [])
            changed = palettes.each_index.select { |palette| palettes[palette] && palettes[palette] != @sprite_palettes[palette] }
            changed.map { |palette| [sprite_palette_at(palette), palettes[palette]] }
          end

          # Every colour a picture of a sprite draws with.
          def sprite_image_colors(image)
            return (0...(image.width * image.height)).select { |at| image.drawn_at?(at) }.map { |at| image.color_at(at) }.uniq unless image.pieces

            pieces = (squares_here? ? image.pieces : image.small_pieces).reject { |_, _, own| own.bytes.all?(&:zero?) }
            pieces.flat_map { |_, _, own| own.bytes }.uniq.reject(&:zero?).map { |place| image.colors.fetch(place) & 0x7FFF }
          end

          # What the words of a refusal call +scene+'s backgrounds.
          def backgrounds_in_message(scene) = scene ? "backgrounds of the scene :#{Modes.strip_scene_prefix(scene)}" : "backgrounds"

          # The refusal for +palettes+ being full: the one that builds the game again with each scene
          # bringing its own colours in, where that has not been tried and is what would help.
          def too_much_error_for(palettes)
            return TooManySpriteColors if palettes.equal?(@sprite_palettes) && !@sprite_colors

            palettes.equal?(@background_palettes) && !@screen_colors ? TooManyBackgroundColors : TooMuch
          end

          # The refusal for the sprites' tiles being full: the one that builds the game again with each
          # scene bringing its own in, where that has not been tried.
          def sprite_tiles_error = @scene_tiles ? TooMuch : TooManySpriteTiles
          def background_tiles_error = @scene_background_tiles ? TooMuch : TooManyBackgroundTiles

          # [the first tile of +own+ that is not as +shared+ has it, every tile's bytes from there], or
          # nil for a scene with no copy, or nothing added to it.
          def tiles_past_shared(own, shared)
            return nil unless own

            first = own.each_index.find { |at| own[at] != shared[at] } or return nil
            [first, own[first..].map { |bytes| bytes || blank_tile }.join]
          end

          # The block, with the background tiles it makes kept in +scene+'s copy of the list. As
          # #with_sprite_tiles_of.
          def with_background_tiles_of(scene)
            return yield unless @scene_background_tiles && scene

            shared = [@background_tiles, @background_tile_numbers]
            @background_tiles, @background_tile_numbers = (@scene_background_stores[scene] ||= shared.map(&:dup))
            begin
              yield
            ensure
              @background_tiles, @background_tile_numbers = shared
            end
          end

          # The block, with the sprite tiles it makes kept in +scene+'s copy of the list, taken the
          # first time it is asked for. For nil, or in a game not built that way, in the list every
          # screen keeps.
          def with_sprite_tiles_of(scene)
            return yield unless @scene_tiles && scene

            shared = [@sprite_tiles, @sprite_tile_numbers, @sprite_square_numbers, @square_tile_numbers]
            @sprite_tiles, @sprite_tile_numbers, @sprite_square_numbers, @square_tile_numbers =
              (@scene_sprite_stores[scene] ||= shared.map(&:dup))
            @scene_of_sprite_tiles = scene
            begin
              yield
            rescue TooMuch => e
              raise unless e.instance_of?(TooMuch) && squares_here?

              raise ScreenSpritesFull.new(e.message, scene: scene)
            ensure
              @scene_of_sprite_tiles = nil
              @sprite_tiles, @sprite_tile_numbers, @sprite_square_numbers, @square_tile_numbers = shared
            end
          end

          # Are the sprite pictures being made now cut into squares where they can be?
          def squares_here? = @sprite_squares && !@small_sprite_scenes.include?(@scene_of_sprite_tiles)

          def sprite_tile_number(bytes)
            @sprite_tile_numbers[bytes] ||= begin
              number = first_free_tiles(1)
              refuse_too_many!(number, MOST_SPRITE_TILES, "sprites", sprite_tiles_error)
              @sprite_tiles[number] = bytes
              number
            end
          end

          # The first of +count+ free tiles in a row, or past the last where there are none. Tiles
          # a game paints are written one after the other, so they stay together.
          def first_free_tiles(count)
            (0..(MOST_SPRITE_TILES - count)).find { |at| @sprite_tiles[at, count].to_a.none? } || MOST_SPRITE_TILES
          end

          # The picture's squares of 16×16 with SQUARE_LEAST_PIECES or more drawn, taken out of
          # +cut+ and given back as pieces. What is left of +cut+ stays 8×8, and so does a square
          # there is no place for.
          def square_pieces(cut, image, palette)
            downs = (0..(image.height - SQUARE)).step(SQUARE).to_a
            acrosses = (0..(image.width - SQUARE)).step(SQUARE).to_a
            downs.product(acrosses).filter_map do |down, across|
              parts = [[across, down], [across + 8, down], [across, down + 8], [across + 8, down + 8]]
              next if parts.count { |part| cut.key?(part) } < SQUARE_LEAST_PIECES

              tile = sprite_square_number(parts.map { |part| cut[part] ? tile_bytes(cut[part]) : blank_tile })
              next unless tile

              parts.each { |part| cut.delete(part) }
              Piece.new(dx: across, dy: down, tile: tile, palette: palette, big: true)
            end
          end

          # A PICTURE THE GAME MADE OF PIECES (Assets::Image#pieces) is shown from those pieces, each
          # where the game put it and in its order, the first in front, and each ONE row of the
          # table: not cut again on a grid, which would turn a letter of 16×16 sitting off the grid
          # into several rows. A cartridge's own pieces overlap and sit anywhere, and a screen lifted
          # from one fits the table only as the rows it was made of. A piece that draws nothing takes
          # no row. Without squares (SNES#build) a big piece is its four quarters.
          #
          # Its colours are read from the pieces rather than the composed pixels: all of a piece can
          # lie under another, and its tile still needs them.
          def pieced_sprite_picture(name, image, mixed, held, scene, number)
            given = (squares_here? ? image.pieces : image.small_pieces).reject { |_, _, own| own.bytes.all?(&:zero?) }
            palettes = sprite_palettes(scene)
            palette = held || allocate_sprite_palette(mixed, scene) do |within|
              palette_for(palettes, sprite_image_colors(image), "sprites", within)
            end
            # Last given first: sprites go into the table back-most first (Lowering::Picture
            # #emit_present_objects), so the piece placed last is the one in front.
            pieces = given.map { |dx, dy, own| sprite_piece_from_places(dx, dy, own, image, palette, held, palettes) }.reverse
            SpritePicture.new(name: name, number: number, width: image.width, height: image.height, pieces: pieces)
          end

          # One piece of a game's own, of 8×8 or 16×16, its tiles shared with any piece alike. A big
          # piece with no place for its four tiles raises, and the game is built again without
          # squares (SNES#build).
          def sprite_piece_from_places(dx, dy, own, image, palette, held, palettes)
            ours = held ? own : own.bytes.map { |place| place.zero? ? 0 : palettes[palette].index(image.colors.fetch(place) & 0x7FFF) + 1 }
                                   .pack("C*")
            if Assets::Image.side(own) == Assets::PIECE_SIZE
              return Piece.new(dx: dx, dy: dy, tile: shared_sprite_tile_number(tile_bytes(ours.bytes)), palette: palette)
            end

            tile = sprite_square_number(Assets::Image.quarters(ours).map { |_, _, quarter| tile_bytes(quarter.bytes) })
            raise sprite_tiles_error, "The sprites use more squares of 16×16 than a Super Nintendo has room for." unless tile

            Piece.new(dx: dx, dy: dy, tile: tile, palette: palette, big: true)
          end

          # The number of a tile of 8×8, which may be one of a square's four.
          def shared_sprite_tile_number(bytes) = @square_tile_numbers[bytes] || sprite_tile_number(bytes)

          # The first of the four tiles of the square +tiles+ (left top, right top, left bottom,
          # right bottom), laid out as the console reads them, or nil with no place for them. Two
          # squares alike share their tiles.
          def sprite_square_number(tiles)
            @sprite_square_numbers.fetch(tiles.join) do |same|
              first = (0...MOST_SPRITE_TILES).find { |at| square_fits_at?(at) }
              next unless first

              square_tiles_from(first).zip(tiles) do |at, bytes|
                @sprite_tiles[at] = bytes
                @square_tile_numbers[bytes] ||= at
              end
              @sprite_square_numbers[same] = first
            end
          end

          def square_fits_at?(first)
            column = first % TILES_ACROSS
            row = first / TILES_ACROSS
            return false if column.odd? || row % TILE_ROWS_IN_PAGE == TILE_ROWS_IN_PAGE - 1

            square_tiles_from(first).all? { |at| at < MOST_SPRITE_TILES && @sprite_tiles[at].nil? }
          end

          def square_tiles_from(first) = [first, first + 1, first + TILES_ACROSS, first + TILES_ACROSS + 1]

          # The sprite palette the block allocates from the sets it is handed: those a picture that is
          # +mixed+ (or not) is drawn from, and where those are full, all eight in a scene of
          # +unmixed_scenes+ (#split_sprite_palettes!). The four come first, so a game they hold
          # keeps the palettes it had. Neither the block's palette_for nor held_palette changes a
          # set before refusing, so the second try starts from what the first found.
          def allocate_sprite_palette(mixed, scene)
            yield @sprite_palettes_for.fetch(mixed)
          rescue TooMuch
            raise if mixed || !@unmixed_scenes.include?(scene)

            yield (0...PALETTES)
          end

          # The palette of +palettes+ that holds every one of +colors+, adding them to one with
          # room where none does, or starting another — of the palettes +within+. +what+ names
          # whose palettes they are.
          def palette_for(palettes, colors, what, within = (0...PALETTES))
            if colors.length > OWN_COLORS
              raise TooMuch, "A picture of the #{what} uses #{colors.length} colours, and on a tiled screen a " \
                             "Super Nintendo tile shows #{OWN_COLORS} and see-through. To fix this, draw it in #{OWN_COLORS} colours or fewer."
            end

            held = held_in(palettes)
            used = within.select { |p| palettes[p] && !held.include?(p) }
            found = used.find { |p| (colors - palettes[p]).empty? }
            return found if found

            roomy = used.select { |p| (palettes[p] | colors).length <= OWN_COLORS }
                        .max_by { |p| (palettes[p] & colors).length }
            if roomy
              palettes[roomy] |= colors
              return roomy
            end
            unused = within.find { |p| palettes[p].nil? }
            unless unused
              raise too_much_error_for(palettes), "The pictures of the #{what} use more colours than a Super Nintendo can " \
                                            "show for them. It holds #{PALETTES} sets of #{OWN_COLORS} colours. To fix " \
                                            "this, use fewer colours in those pictures."
            end

            palettes[unused] = colors.dup
            unused
          end

          # The palette of +palettes+ whose first places are a run's +colors+ (past place 0) in their
          # order, starting one where none is. Other pictures' colours may join it later, after them.
          def run_palette(palettes, colors, what, within = (0...PALETTES))
            own = colors.drop(1)
            found = within.find { |p| palettes[p]&.take(own.length) == own }
            return found if found

            empty = within.find { |p| palettes[p].nil? || palettes[p].empty? }
            return empty.tap { palettes[empty] = own.dup } if empty

            raise too_much_error_for(palettes), "The pictures of the #{what} use more colours than a Super Nintendo can show " \
                                          "for them. It holds #{PALETTES} sets of #{OWN_COLORS} colours, and each list " \
                                          "of colours a game paints with takes a set of its own. To fix this, use " \
                                          "fewer colours or fewer lists."
          end

          def refuse_too_many!(count, most, what, error = TooMuch)
            return if count < most

            raise error, "The #{what} use more different 8×8 squares of picture than a Super Nintendo has room " \
                           "for (#{most}). To fix this, use fewer different pictures."
          end

          # The 32 bytes of a tile whose 64 pixels are +places+ (0 to 15), row by row: each row's
          # bits 0 and 1 as two bytes, all eight rows, then bits 2 and 3 the same way. The leftmost
          # pixel is the top bit of each byte.
          def tile_bytes(places)
            low = +"".b
            high = +"".b
            8.times do |row|
              planes = Array.new(4) do |plane|
                (0...8).sum { |column| ((places[(row * 8) + column] >> plane) & 1) << (7 - column) }
              end
              low << planes[0].chr << planes[1].chr
              high << planes[2].chr << planes[3].chr
            end
            low + high
          end
        end
      end
    end
  end
end
