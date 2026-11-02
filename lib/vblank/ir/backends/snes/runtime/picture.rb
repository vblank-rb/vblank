# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE PICTURE: the backgrounds and the sprites, set up at power-on and copied to the
          # console in the vertical blank after each pass.
          #
          # WHAT THE CONSOLE IS TOLD TO DRAW. Mode 1 (BGMODE): two background layers of sixteen-colour
          # tiles (BG1 in front of BG2) and a third of four-colour tiles the build does not use, and
          # 128 sprites over all of them. Video RAM, 32K words, is laid out once:
          #
          #   $0000-$3FFF  the backgrounds' tiles, 1024 of them (16 words each)
          #   $4000-$4FFF  BG1's map, up to 64×64 cells (a word each)
          #   $5000-$5FFF  BG2's map
          #   $6000-$7FFF  the sprites' tiles, 512 of them
          #
          # WHAT THE GAME CHANGES IS KEPT IN WORK RAM and copied in the blank (rt_upload): the
          # sprite table, written whole every pass a game places its sprites (a shadow of the
          # console's 544 bytes); a map put up, copied whole from the cartridge; single cells
          # changed (a queue of them); and where each layer is scrolled to. The console takes video
          # RAM and the sprite table only while it is not drawing, so it is all copied in the blank
          # with the screen on, as much as each blank has room for (Blank): a copy too long for one
          # blank (a map of 64×64 cells is 8K, or many cells) arrives over several, with the old
          # picture still up, and the pass is said to be shown once it is all there (Runtime::Frame's
          # SHOWN). The screen is never switched off for it, so no frame is black. A map arriving
          # over several blanks shows its first pieces before the rest.
          #
          #   rt_picture_start     at power-on: the registers, the tiles and the colours
          #   rt_picture_prepare   at the end of every pass, before the wait: a painted screen's
          #                        runs of tiles to send (Paint's rt_paint_prepare), nothing else
          #   rt_upload_whole      the first pass, with the screen still off
          #   rt_upload            what the pass changed, in the blank
          #   rt_sprites_begin     every sprite hidden, ready for a pass's sprites
          #   rt_sprite_place      one sprite placed: its pieces into the sprite table
          #   rt_background_put_up   a map onto a layer, from its corner (or keeping its scroll)
          #   rt_background_scroll   where a layer's view sits
          #   rt_set_cell          one cell of a layer's map changed
          #   rt_bar_place         a status bar's top put at a row (a game with a status bar)
          #   rt_bends_prepare     at the end of every pass: the line tables of the backgrounds bent
          #                        row by row, from the rows the game worked out (a game with bends)
          #   rt_tile_run_copy     a run's list made into its tiles, for the next blank (a game that
          #                        paints tiles from lists)
          #
          # A STATUS BAR is one of the two layers, shown from its top row to the bottom of the screen
          # and hidden above it, while the other layer is shown above it and hidden below. Which
          # layers the console draws is TM, one register for the whole screen; but the copying
          # engine can write a register a line at a time as the picture is drawn (HDMA), from a short
          # table: so channel 1 writes TM from a table of two or three steps, each a count of lines and
          # the value for them — the field's layer and the sprites down to the bar's top, then the
          # bar's layer and the sprites (BAR_TABLE). A step counts 127 lines at most, so a top lower
          # than that takes two. The bar's layer is scrolled up by its top, so its first row is there,
          # and its rows past its map show the backdrop: tile 0 is see-through. The table is made in
          # the blank, with the scroll, so the two always agree.
          #
          # A BACKGROUND BENT ROW BY ROW (`scroll_each_row`) is the same engine writing the layer's
          # scroll across, BGnHOFS, on every line (channel 2 for BG1, 3 for BG2). The game works out
          # each row's offset at every frame boundary, for the frame after, into the layer's
          # BEND_OFFSETS (Lowering::Picture#emit_bends); as the pass ends, each row's offset and the
          # layer's scroll, as the pass left it, go into a line table (rt_bends_prepare): two steps
          # of 112 lines each, each line two bytes, the register written twice, low byte then high.
          # There are two tables for each layer, and the blank switches the channel to the one just
          # made, so a pass whose copy takes several blanks never shows a table half made.
          #
          # TILES PAINTED FROM A LIST (a run, Builder::TileRuns) hold their pixels as the game writes
          # them: a byte is two pixels, the left one in the low four bits, a tile eight rows of four
          # bytes. The console keeps a tile's pixels in planes (SNES::Art#tile_bytes): for each row,
          # bit 0 of each of its eight pixels in one byte and bit 1 in the next, the leftmost pixel in
          # the top bit, and the same for bits 2 and 3 sixteen bytes on. So a copy takes each pixel's
          # four bits apart into four bytes, shifting one bit into each in turn (rt_tile_run_copy),
          # into the run's place in work RAM; the blank then copies that to the run's tiles in video
          # RAM. Each run's palette has its colours at the places the game named (SNES::Art#run_palette).
          module Picture
            BG_TILES = 0x0000
            LAYER_MAPS = [0x4000, 0x5000].freeze
            SPRITE_TILES = 0x6000
            # A row of the sprite table's size, in its two bits of the upper table: the larger of the
            # two sizes OBSEL names.
            SPRITE_SIZE_BIT = 2

            # The sprite table's shadow (544 bytes: 128 rows of four, then 32 bytes of each row's two
            # top bits), and the sprites the game placed in its last pass, for a reader: how many,
            # then for each, whose (SpriteNames's number), which picture, and where.
            SHADOW_OAM = "rt shadow oam"
            DRAWN = "rt drawn"
            DRAWN_BYTES = 8
            MOST_SPRITES = 128
            # The next row of the sprite table to write, counting down: the back-most sprite is
            # placed first, in the last row, since the console draws a lower row in front.
            NEXT_ROW = "rt next row"
            # Each layer's state: where the map to copy is (three bytes and a spare), how many bytes,
            # whether a copy is waiting, its map register, its grid's columns, and its scroll.
            LAYERS = "rt layers"
            LAYER_SOURCE = 0
            LAYER_BYTES = 4
            LAYER_PENDING = 6
            LAYER_SC = 8
            LAYER_COLUMNS = 10
            LAYER_SCROLL_X = 12
            LAYER_SCROLL_Y = 14
            LAYER_STATE_BYTES = 16
            # Cells changed since the last blank: how many, then each its video RAM address and word.
            CELLS = "rt cells"
            MOST_CELLS = 256
            # The most of a map copied at once: a quarter of a 64×64 map, half of what a blank holds.
            MAP_PIECE = 2048
            # A status bar's top row, its layer, whether either changed since the last blank, and the
            # table of lines the copying engine's channel 1 writes TM from (see the top).
            BAR = "rt bar"
            BAR_TOP = 0
            BAR_LAYER = 2
            BAR_CHANGED = 4
            BAR_TABLE = 6
            BAR_BYTES = BAR_TABLE + 8
            # What BAR_CHANGED says when the bar has left the screen, and not moved (rt_bar_gone).
            BAR_LEAVES = 2
            # In a game that tells its bar to cover sprites: whether it does. The table then leaves
            # the sprites out of TM from the bar down, so the console draws none on those lines.
            BAR_COVERS = "rt bar covers"
            BAR_CHANNEL = 0x10 # channel 1's registers, past channel 0's
            # Which layers TM shows on a tiled screen: BG1 and BG2 (a bit each) and the sprites.
            LAYERS_SHOWN = 0x13
            SPRITES_SHOWN = 0x10
            # The most lines one step of the table counts.
            MOST_STEP_LINES = 127
            SCREEN_HEIGHT = 224
            # The channels the copying engine writes registers on a line at a time, a bit each, as
            # HDMAEN takes them: the bar's and the bends' share the register, so it is written from
            # here whole.
            HDMA_CHANNELS = "rt hdma channels"
            # A bent layer's rows (a word each, the screen's height of them), its two line tables, and
            # for each layer which of its two the channel reads (0 or 1).
            def self.bend_offsets(layer) = "rt bend offsets #{layer}"
            def self.bend_tables(layer) = "rt bend tables #{layer}"
            BEND_SHOWN = "rt bend shown"
            # A bit for each layer a scene bends while that scene is away, in a game with such a
            # scene: the layer's rows go straight, and the next scene using it shows no bend.
            LAYERS_STRAIGHT = "rt layers straight"
            BEND_STEP_LINES = SCREEN_HEIGHT / 2
            REPEAT = 0x80 # a step's count with this bit: a new value on every line of it
            BEND_TABLE_BYTES = 1 + (BEND_STEP_LINES * 2) + 1 + (BEND_STEP_LINES * 2) + 1
            # A BEND THAT SAYS A THING ABOUT WHOLE BANDS OF ROWS needs no value for every line. A step
            # with no REPEAT bit writes the register once and leaves it for as many lines as it counts,
            # so such a layer's table is a step for each band, three bytes where the other is 450.
            # Its rows hold those steps in place of a word a row: each step BAND_STEP_BYTES, the lines
            # and then the offset, and lines of nought after the last.
            BAND_STEP_BYTES = 4
            MOST_BAND_STEPS = (SCREEN_HEIGHT * 2 / BAND_STEP_BYTES) - 1
            BEND_CHANNELS = [2, 3].freeze
            # Where a run's tiles are made in the console's form, and which runs are owed a copy to
            # video RAM in the next blank (a word each). The lowering's table "art tile runs" says,
            # for each run, sixteen bytes: its list's place and its staging's (three bytes and a
            # spare each), its first tile's word in video RAM, its tiles, its bytes, and a spare.
            def self.tile_run_staging(number) = "rt tile run #{number}"
            TILE_RUNS_OWED = "rt tile runs owed"
            RUN_ENTRY_BYTES = 16
            RUN_LIST = 0
            RUN_STAGING = 4
            RUN_PLACE = 8
            RUN_TILES = 10
            RUN_BYTES = 12
            # The direct page rt_tile_run_copy works on: the list's bytes and the staging (three bytes
            # and a spare each), the bytes the list holds, the tiles left, the staging's tile, and a
            # row's four planes.
            RunScratch = Data.define(:list, :out, :held, :tiles, :tile, :planes)

            # A sprite hidden: below the screen, where none of its eight rows shows.
            HIDDEN_Y = 224

            module_function

            # +bar+ for a game with a status bar, +bends+ for one with a background bent row by row,
            # +tile_runs+ the bytes of each run of tiles a game paints from a list.
            # What CGADSUB is told in the blank, in a game that turns a see-through layer solid.
            MATH = "rt see-through math"

            # What BGMODE is told in the next blank, in a game with a layer whose scenes show tiles of
            # two sizes: the console's one setting for each layer, told beside the scene's maps.
            TILE_SIZES = "rt tile sizes"
            TILED_MODE = 0x01

            # CGADSUB's bit that halves the sum.
            MATH_HALVES = 0x40

            # A SCENE'S OWN SPRITE TILES, in a game whose sprites do not fit video memory all at once,
            # waiting for the next blank to go in: where they are on the cartridge (three bytes and
            # a spare), how many bytes are left, where the next goes in video memory, and the byte
            # the sprite table is filled with while they go in.
            SCENE_TILES = "rt scene sprite tiles"
            SCENE_TILES_FROM = 0
            SCENE_TILES_LEFT = 4
            SCENE_TILES_PLACE = 6
            SCENE_TILES_FILL = 8
            SCENE_TILES_BYTES = 10

            # THE SAME FOR ITS BACKGROUND TILES, where they go, how many bytes and from where.
            SCENE_BACKGROUND_TILES = "rt scene background tiles"

            # INIDISP's bit that turns the picture off, which is also what lets video memory be written
            # on any line.
            DISPLAY_FORCED_OFF = 0x80

            # A row of the sprite table filled with this has every sprite below the bottom of the
            # screen, whatever its size.
            NO_SPRITE_FILL = 0xF0F0

            # The copying engine's mode bit that reads one place over and over.
            DMA_ONE_SOURCE = 0x08

            def reserve(memory, bar: false, bends: false, scene_bends: false, tile_runs: [], math_turns: false, bar_covers: false,
                        tile_sizes: false, scene_tiles: false, scene_background_tiles: false)
              memory.reserve(SCENE_TILES, SCENE_TILES_BYTES) if scene_tiles
              memory.reserve(SCENE_BACKGROUND_TILES, SCENE_TILES_BYTES) if scene_background_tiles
              memory.reserve(TILE_SIZES, 2) if tile_sizes
              memory.reserve(LAYERS_STRAIGHT, 2) if scene_bends
              memory.reserve(BAR_COVERS, 2) if bar_covers
              memory.reserve(MATH, 2) if math_turns
              memory.reserve(TILE_RUNS_OWED, tile_runs.length * 2) unless tile_runs.empty?
              tile_runs.each_with_index { |bytes, number| memory.reserve_far(tile_run_staging(number), bytes) }
              memory.reserve(BAR, BAR_BYTES) if bar
              memory.reserve(HDMA_CHANNELS, 2) if bar || bends
              if bends
                memory.reserve(BEND_SHOWN, LAYER_MAPS.length * 2)
                LAYER_MAPS.each_index do |layer|
                  memory.reserve_far(bend_offsets(layer), SCREEN_HEIGHT * 2)
                  memory.reserve_far(bend_tables(layer), BEND_TABLE_BYTES * 2)
                end
              end
              memory.reserve_far(SHADOW_OAM, 544)
              memory.reserve_far(DRAWN, 2 + (MOST_SPRITES * DRAWN_BYTES))
              memory.reserve(NEXT_ROW, 2)
              memory.reserve(LAYERS, LAYER_MAPS.length * LAYER_STATE_BYTES)
              memory.reserve(CELLS, 2 + (MOST_CELLS * 4))
            end

            # +work+ is four words of the direct page the routines use. +bar+ for a game with a
            # status bar; +bent+ the layers bent row by row, for a game with bends; +tile_runs+ how
            # many runs of tiles a game paints from lists, and +run_scratch+ RunScratch's places.
            # +see_through+ is the colour math a see-through layer needs, [the layers it mixes, the
            # layers behind them] a bit each, or nil (Lowering::Picture#refuse_unmade_see_through!).
            # +sprite_depths+ for a game with a sprite behind a background: rt_sprite_place takes a
            # sixth number then (Lowering::Picture#sprite_depths). +big_tiles+ is BGMODE's size bits for the
            # layers drawn from 16×16 tiles (Lowering::Picture#big_tile_layers). +sprite_squares+ for a
            # game with sprites' squares of 16×16: each piece carries its size then (Art::Piece#big).
            # +banded+ says the game's bends are kept as steps (Lowering::Picture#bends_by_bands?).
            def emit(asm, memory, work:, painted: false, bar: false, bent: [], banded: false, tile_runs: 0, run_scratch: nil, straight_tile_runs: false,
                     see_through: nil, sprite_depths: false, big_tiles: 0, sprite_squares: false, changing_colors: false,
                     math_turns: false, scene_bars: false)
              emit_start(asm, memory, painted, see_through, big_tiles, changing_colors, math_turns)
              emit_see_through_math(asm, memory) if math_turns
              emit_scene_tiles_noted(asm, memory) if memory.reserved?(SCENE_TILES)
              emit_scene_background_tiles_noted(asm, memory) if memory.reserved?(SCENE_BACKGROUND_TILES)
              emit_sprites(asm, memory, work, sprite_depths, sprite_squares)
              emit_backgrounds(asm, memory, work)
              emit_bar(asm, memory, scene_bars: scene_bars) if bar
              emit_bends_prepare(asm, memory, work, bent, banded) unless bent.empty?
              emit_tile_run_copy(asm, memory, run_scratch) if tile_runs.positive?
              emit_tile_run_straight(asm, memory, run_scratch) if straight_tile_runs
              emit_upload(asm, memory, work, painted, bar, bent, tile_runs, math_turns, scene_bars)
              asm.label("rt_picture_prepare")
              if painted
                asm.jml(asm.long("rt_paint_prepare"))
              elsif !bent.empty?
                asm.jml(asm.long("rt_bends_prepare"))
              else
                asm.rtl
              end
            end

            # The registers, then the tiles and the colours copied in while the screen is off — or,
            # for a +painted+ screen, Runtime::Paint's.
            def emit_start(asm, memory, painted, see_through = nil, big_tiles = 0, changing_colors = false, math_turns = false)
              h = Console::SNESHardware
              asm.label("rt_picture_start")
              # WRIO's top bit lets a read of SLHV latch the line the picture is on, which the copy
              # in the blank reads to know how much of the blank is left (Blank). It is the bit's
              # power-on value, which Boot clears.
              asm.sep(0x20)
              asm.lda(0x80)
              asm.sta(asm.abs(h::WRIO))
              asm.rep(0x20)
              if painted
                asm.jsl(asm.long("rt_paint_start"))
                asm.jml(asm.long("rt_sprites_begin"))
                return
              end

              asm.sep(0x20)
              asm.lda(TILED_MODE | big_tiles) # mode 1, every tile 8×8 but on the layers of +big_tiles+
              asm.sta(asm.abs(h::BGMODE))
              asm.sta(asm.abs(memory[TILE_SIZES])) if memory.reserved?(TILE_SIZES)
              asm.stz(asm.abs(h::BG12NBA)) # both layers' tiles at $0000
              asm.lda(SPRITE_TILES >> 13) # sprites' tiles at $6000, the next 256 straight after; 8×8 and 16×16
              asm.sta(asm.abs(h::OBSEL))
              LAYER_MAPS.each_with_index do |at, layer|
                asm.lda((at >> 10) << 2)
                asm.sta(asm.abs(h::BG1SC + layer))
              end
              asm.lda(0x13) # BG1, BG2 and the sprites on the main screen
              asm.sta(asm.abs(h::TM))
              emit_see_through(asm, memory, see_through, math_turns) if see_through
              asm.rep(0x20)
              emit_dma_to_vram(asm, BG_TILES, "art background tiles", "art background tiles bytes")
              emit_dma_to_vram(asm, SPRITE_TILES, "art sprite tiles", "art sprite tiles bytes")
              # The colours: 256 of them, from colour 0.
              asm.sep(0x20)
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              emit_dma(asm, h::DMA_TO_ONE_PORT, h::CGDATA, asm.imm("art colors"), asm.bank_of("art colors"), 512)
              asm.jsl(asm.long("rt_colors_start")) if changing_colors
              asm.jsl(asm.long("rt_sprites_begin"))
              asm.rtl
            end

            # A LAYER HALF SEE-THROUGH (8-bit A): the layers behind it on the sub screen as well (TS);
            # colour math adding the sub screen rather than the fixed colour (CGWSEL bit 1); and, on
            # the see-through layer's own pixels alone, adding and halving the sum (CGADSUB: bit 6
            # halves, the low bits name the layers, bit 7 left clear adds). The sprites are not named,
            # so a sprite in front stays solid. Where the sub screen shows nothing the console adds
            # the fixed colour unhalved, which is why the build wants a background covering the
            # screen behind the layer.
            #
            # A LAYER ADDED TO WHAT IS BEHIND IT is the same with bit 6 clear. A game can turn that
            # off and on again: CGADSUB takes the number it was last told, from the blank, so the
            # layer turns solid between two pictures (+math_turns+, rt_see_through_math).
            def emit_see_through(asm, memory, see_through, math_turns)
              h = Console::SNESHardware
              mixed, behind = see_through
              asm.lda(behind)
              asm.sta(asm.abs(h::TS))
              asm.lda(0x02)
              asm.sta(asm.abs(h::CGWSEL))
              asm.lda(mixed)
              asm.sta(asm.abs(h::CGADSUB))
              asm.sta(asm.abs(memory[MATH])) if math_turns
            end

            # rt_see_through_math(math): what CGADSUB is told in the next blank.
            def emit_see_through_math(asm, memory)
              asm.label("rt_see_through_math")
              asm.lda(asm.direct(Memory.register(0)))
              asm.sta(asm.abs(memory[MATH]))
              asm.rtl
            end

            # rt_scene_sprite_tiles(tiles, bytes, place): the tiles a scene taking over keeps to itself,
            # for the next blank (#emit_scene_tiles_upload).
            def emit_scene_tiles_noted(asm, memory)
              at = memory[SCENE_TILES]
              asm.label("rt_scene_sprite_tiles")
              asm.lda(asm.direct(Memory.register(0)))
              asm.sta(asm.abs(at + SCENE_TILES_FROM))
              asm.lda(asm.direct(Memory.register(0) + 2))
              asm.sta(asm.abs(at + SCENE_TILES_FROM + 2))
              asm.lda(asm.direct(Memory.register(1)))
              asm.sta(asm.abs(at + SCENE_TILES_LEFT))
              asm.lda(asm.direct(Memory.register(2)))
              asm.sta(asm.abs(at + SCENE_TILES_PLACE))
              asm.lda(NO_SPRITE_FILL)
              asm.sta(asm.abs(at + SCENE_TILES_FILL))
              asm.rtl
            end

            # In the blank after a scene takes over: its own tiles over the last scene's, a piece of
            # MAP_PIECE bytes at a time, however many blanks that takes (rt_blank_room waits for the
            # next), which is a pass that runs late. The sprites shown meanwhile would be drawn from
            # tiles that are changing under them, so the sprite table goes empty first, and the
            # table the pass made goes in with the rest of its picture as the last piece is in.
            def emit_scene_tiles_upload(asm, memory, work)
              h = Console::SNESHardware
              at = memory[SCENE_TILES]
              asm.lda(asm.abs(at + SCENE_TILES_LEFT))
              asm.branch_long(:beq, "rt_upload_scene_tiles_done")
              asm.lda(544)
              asm.jsr(asm.abs("rt_blank_room"))
              asm.stz(asm.abs(h::OAMADDL))
              fill = memory[SCENE_TILES] + SCENE_TILES_FILL
              emit_dma(asm, h::DMA_TO_ONE_PORT | DMA_ONE_SOURCE, h::OAMDATA, asm.imm(fill & 0xFFFF), fill >> 16, 544)
              emit_scene_tile_pieces(asm, at, work, "rt_upload_scene_tiles")
              asm.label("rt_upload_scene_tiles_done")
            end

            # rt_scene_background_tiles(table): the tiles a scene taking over keeps to itself, for the
            # next blank. The table says where they are on the cartridge, how many bytes and where they
            # go in video memory, since a scene's list is not finished as its arrival is written.
            def emit_scene_background_tiles_noted(asm, memory)
              at = memory[SCENE_BACKGROUND_TILES]
              asm.label("rt_scene_background_tiles")
              [SCENE_TILES_FROM, SCENE_TILES_FROM + 2, SCENE_TILES_LEFT, SCENE_TILES_PLACE].each do |field|
                asm.ldy(field)
                asm.lda(asm.ind_long_y(Memory.register(0)))
                asm.sta(asm.abs(at + field))
              end
              asm.rtl
            end

            # First of all in the blank after a scene takes over: its own background tiles over the
            # last scene's. The maps on the screen are drawn from those tiles, so the picture goes
            # off, as a Super Nintendo's own games turn it off to load a screen, and stays off until
            # the pass's whole picture has gone in (Frame's rt_show_pass turns it on). With it off
            # video memory takes writes on any line, so the copy need not wait for a blank, which
            # Blank's routines are told by the display being off.
            def emit_scene_background_tiles_upload(asm, memory, work)
              h = Console::SNESHardware
              at = memory[SCENE_BACKGROUND_TILES]
              asm.lda(asm.abs(at + SCENE_TILES_LEFT))
              asm.branch_long(:beq, "rt_upload_scene_background_tiles_done")
              asm.sep(0x20)
              asm.lda(DISPLAY_FORCED_OFF)
              asm.sta(asm.abs(h::INIDISP))
              asm.rep(0x20)
              asm.lda(asm.abs(memory[Frame::DISPLAY_ON]))
              asm.pha
              asm.stz(asm.abs(memory[Frame::DISPLAY_ON]))
              emit_scene_tile_pieces(asm, at, work, "rt_upload_scene_background_tiles_pieces")
              asm.label("rt_upload_scene_background_tiles_pieces_done")
              asm.pla
              asm.sta(asm.abs(memory[Frame::DISPLAY_ON]))
              asm.label("rt_upload_scene_background_tiles_done")
            end

            # What is left at +at+ (a SCENE_TILES record), a piece of MAP_PIECE bytes at a time, as the
            # blanks have room. +name+ the labels' start; it leaves by #{name}_done.
            def emit_scene_tile_pieces(asm, at, work, name)
              h = Console::SNESHardware
              asm.label("#{name}_piece")
              asm.lda(asm.abs(at + SCENE_TILES_LEFT))
              asm.branch_long(:beq, "#{name}_done")
              asm.cmp(MAP_PIECE)
              asm.bcc("#{name}_bytes")
              asm.lda(MAP_PIECE)
              asm.label("#{name}_bytes")
              asm.sta(asm.direct(work))
              asm.jsr(asm.abs("rt_blank_room"))
              asm.lda(asm.direct(work))
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              asm.lda(asm.abs(at + SCENE_TILES_PLACE))
              asm.sta(asm.abs(h::VMADDL))
              asm.lda(asm.abs(at + SCENE_TILES_FROM))
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              asm.sep(0x20)
              asm.lda(asm.abs(at + SCENE_TILES_FROM + 2))
              asm.sta(asm.abs(h::DMA_BASE + h::A1B))
              asm.lda(h::DMA_TO_TWO_PORTS)
              asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
              asm.lda(h::VMDATAL & 0xFF)
              asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
              asm.lda(asm.abs(at + SCENE_TILES_FROM))
              asm.clc
              asm.adc(asm.direct(work))
              asm.sta(asm.abs(at + SCENE_TILES_FROM))
              asm.lda(asm.direct(work))
              asm.lsr # a word of video RAM for every two bytes
              asm.clc
              asm.adc(asm.abs(at + SCENE_TILES_PLACE))
              asm.sta(asm.abs(at + SCENE_TILES_PLACE))
              asm.lda(asm.abs(at + SCENE_TILES_LEFT))
              asm.sec
              asm.sbc(asm.direct(work))
              asm.sta(asm.abs(at + SCENE_TILES_LEFT))
              asm.jmp(asm.abs("#{name}_piece"))
            end

            # A scroll register written with the 16-bit number in A: its low byte, then its high.
            def emit_scroll_register(asm, register)
              asm.sep(0x20)
              asm.sta(asm.abs(register))
              asm.xba
              asm.sta(asm.abs(register))
              asm.rep(0x20)
            end

            # Channel 0 copying from the cartridge to video RAM at +word_address+: +label+'s bytes,
            # as many as the word at +count_label+ says (none for nought).
            def emit_dma_to_vram(asm, word_address, label, count_label)
              h = Console::SNESHardware
              skip = "#{label} none"
              asm.lda(asm.long(count_label))
              asm.beq(skip)
              asm.tax
              asm.lda(word_address)
              asm.sta(asm.abs(h::VMADDL))
              asm.txa
              emit_dma(asm, h::DMA_TO_TWO_PORTS, h::VMDATAL, asm.imm(label), asm.bank_of(label), nil)
              asm.label(skip)
            end

            # Channel 0 copying to the picture chip's port +port+ in +mode+, from +source+ (an
            # immediate operand for the low 16 bits) in bank +bank+ (an immediate operand), +count+
            # bytes — or as many as A holds, for nil.
            def emit_dma(asm, mode, port, source, bank, count)
              h = Console::SNESHardware
              asm.sta(asm.abs(h::DMA_BASE + h::DASL)) if count.nil?
              unless count.nil?
                asm.lda(count)
                asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              end
              asm.lda(source)
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              asm.sep(0x20)
              asm.lda(bank)
              asm.sta(asm.abs(h::DMA_BASE + h::A1B))
              asm.lda(mode)
              asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
              asm.lda(port & 0xFF)
              asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
            end

            # SPRITES. rt_sprites_begin hides every row of the sprite table and forgets the sprites
            # of the last pass. rt_sprite_place(poses, pose, x, y, whose) places one: +poses+ is the
            # 24-bit place of the sprite's table of pictures (how many, then each picture's number),
            # +pose+ which of them it shows — none for a number outside the table — and +whose+ the
            # sprite's number for a reader (SpriteNames); in a game with sprites among the
            # backgrounds, a sixth number flips each piece's priority bits. Each piece of the picture is a row of the
            # table, at the sprite's place plus the piece's own; a piece wholly off the screen is not
            # written, and nor is any piece once the table's 128 rows are used.
            #
            # A ROW'S PLACE ON THE SCREEN is nine bits across and eight down, and both come round: a
            # piece at -3 across is kept as 509, which the console draws three columns off the left
            # edge, and one at -3 down as 253, which it draws with its top three rows above the
            # screen. So a piece that reaches the screen is written as its place's low bits, and one
            # that does not is not written at all, where coming round would show it somewhere else.
            #
            # A SQUARE OF 16×16 reaches eight pixels further, so with +squares+ every piece is asked
            # about that reach. A small piece just off an edge then takes a row and draws nothing,
            # which is a few rows at worst for what the squares save. Each piece carries its own
            # size bit, and a row's two bits in the upper table are that and across's ninth bit.
            def emit_sprites(asm, memory, work, depths = false, squares = false)
              reach = (squares ? Art::SQUARE : 8) - 1
              r = ->(n) { Memory.register(n) }
              # How many pieces are left: R5, or R6 where R5 is the sixth number, the priority bits
              # flipped in each piece's attributes (in front of every background, 3, made 2 or 1).
              count = depths ? r.call(6) : r.call(5)
              oam = memory[SHADOW_OAM]
              drawn = memory[DRAWN]
              pointer = work # the picture's pieces, three bytes and a spare
              piece_x = work + 4
              piece_y = work + 6

              asm.label("rt_sprites_begin")
              asm.ldx(0)
              asm.label("rt_sprites_begin_row")
              asm.lda(HIDDEN_Y << 8)
              asm.sta(asm.long_x(oam)) # x 0, y below the screen
              asm.lda(0)
              asm.sta(asm.long_x(oam, 2))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.cpx(512)
              asm.bne("rt_sprites_begin_row")
              asm.label("rt_sprites_begin_top_bits")
              asm.sta(asm.long_x(oam)) # A is nought: no row's top bits set
              asm.inx
              asm.inx
              asm.cpx(544)
              asm.bne("rt_sprites_begin_top_bits")
              asm.lda(MOST_SPRITES)
              asm.sta(asm.abs(memory[NEXT_ROW]))
              asm.lda(0)
              asm.sta(asm.long(drawn))
              asm.rtl

              asm.label("rt_sprite_place")
              # The pose: in the table, or no sprite.
              asm.lda(asm.direct(r.call(0)))
              asm.sta(asm.direct(pointer))
              asm.lda(asm.direct(r.call(0) + 2))
              asm.sta(asm.direct(pointer + 2))
              asm.lda(asm.direct(r.call(1) + 2))
              asm.bne("rt_sprite_place_none")
              asm.lda(asm.direct(r.call(1)))
              asm.cmp(asm.ind_long(pointer))
              asm.bcc("rt_sprite_place_posed")
              asm.label("rt_sprite_place_none")
              asm.rtl
              asm.label("rt_sprite_place_posed")
              asm.inc
              asm.asl
              asm.tay
              asm.lda(asm.ind_long_y(pointer)) # the picture's number
              asm.sta(asm.direct(r.call(1)))
              # The reader's row: whose, which picture, where.
              asm.lda(asm.long(drawn))
              asm.cmp(MOST_SPRITES)
              asm.bcs("rt_sprite_place_noted")
              asm.asl
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.direct(r.call(4)))
              asm.sta(asm.long_x(drawn, 2))
              asm.lda(asm.direct(r.call(1)))
              asm.sta(asm.long_x(drawn, 4))
              asm.lda(asm.direct(r.call(2)))
              asm.sta(asm.long_x(drawn, 6))
              asm.lda(asm.direct(r.call(3)))
              asm.sta(asm.long_x(drawn, 8))
              asm.lda(asm.long(drawn))
              asm.inc
              asm.sta(asm.long(drawn))
              asm.label("rt_sprite_place_noted")
              # A place outside -512..511 either way is off the screen whatever the piece.
              [r.call(2), r.call(3)].each do |at|
                asm.lda(asm.direct(at))
                asm.clc
                asm.adc(512)
                asm.tax
                asm.lda(asm.direct(at + 2))
                asm.adc(0) # with the carry from the low half: nought for every place in range
                asm.bne("rt_sprite_place_off")
                asm.cpx(1024)
                asm.bcs("rt_sprite_place_off")
              end
              # The picture's pieces.
              asm.lda(asm.direct(r.call(1)))
              asm.asl
              asm.adc(asm.direct(r.call(1))) # × 3: a 24-bit place each
              asm.tax
              asm.lda(asm.long_x("art sprite pictures"))
              asm.sta(asm.direct(pointer))
              asm.lda(asm.long_x("art sprite pictures", 2))
              asm.and_a(0x00FF)
              asm.sta(asm.direct(pointer + 2))
              asm.lda(asm.ind_long(pointer)) # how many pieces
              asm.sta(asm.direct(count))
              asm.ldy(2)
              asm.label("rt_sprite_place_piece")
              asm.lda(asm.direct(count))
              asm.bne("rt_sprite_place_more")
              asm.label("rt_sprite_place_off")
              asm.rtl
              asm.label("rt_sprite_place_more")
              asm.dec(asm.direct(count))
              asm.lda(asm.abs(memory[NEXT_ROW]))
              asm.beq("rt_sprite_place_off") # the table is full
              # Across: from the piece's reach left of the screen to 255 reaches the screen.
              asm.lda(asm.ind_long_y(pointer))
              asm.clc
              asm.adc(asm.direct(r.call(2)))
              asm.sta(asm.direct(piece_x))
              asm.clc
              asm.adc(reach)
              asm.cmp(256 + reach)
              asm.bcs("rt_sprite_place_skip")
              # Down: from its reach above to 223.
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(pointer))
              asm.clc
              asm.adc(asm.direct(r.call(3)))
              asm.sta(asm.direct(piece_y))
              asm.clc
              asm.adc(reach)
              asm.cmp(224 + reach)
              asm.bcs("rt_sprite_place_skip_down")
              # The row: the next free, counting down.
              asm.dec(asm.abs(memory[NEXT_ROW]))
              asm.lda(asm.abs(memory[NEXT_ROW]))
              asm.asl
              asm.asl
              asm.tax
              asm.sep(0x20)
              asm.lda(asm.direct(piece_x))
              asm.sta(asm.long_x(oam))
              asm.lda(asm.direct(piece_y))
              asm.sta(asm.long_x(oam, 1))
              asm.rep(0x20)
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(pointer)) # the tile, and its attributes above it
              asm.eor(asm.direct(r.call(5))) if depths
              asm.sta(asm.long_x(oam, 2))
              asm.iny
              asm.iny
              if squares
                emit_sprite_row_bits(asm, memory, pointer, piece_x, piece_y)
              else
                # Across's ninth bit, for a piece left of the screen: in the row's two bits, in the
                # byte of the 32 that holds four rows' each.
                asm.lda(asm.direct(piece_x))
                asm.bpl("rt_sprite_place_piece")
                asm.lda(asm.abs(memory[NEXT_ROW]))
                asm.and_a(3)
                asm.tax
                asm.lda(asm.long_x("rt_sprite_top_bit"))
                asm.and_a(0x00FF)
                asm.sta(asm.direct(piece_y))
              end
              asm.lda(asm.abs(memory[NEXT_ROW]))
              asm.lsr
              asm.lsr
              asm.tax
              asm.sep(0x20)
              asm.lda(asm.long_x(oam, 512))
              asm.ora(asm.direct(piece_y))
              asm.sta(asm.long_x(oam, 512))
              asm.rep(0x20)
              asm.brl("rt_sprite_place_piece")
              asm.label("rt_sprite_place_skip")
              asm.iny
              asm.iny
              asm.label("rt_sprite_place_skip_down")
              (squares ? 3 : 2).times do
                asm.iny
                asm.iny
              end
              asm.brl("rt_sprite_place_piece")
              if squares
                asm.label("rt_sprite_row_bits")
                4.times { |row| asm.data_bytes(*(0..3).map { |bits| bits << (row * 2) }) }
              else
                asm.label("rt_sprite_top_bit")
                asm.data_bytes(0x01, 0x04, 0x10, 0x40)
              end
            end

            # This piece's two bits for its row of the upper table, its size and across's ninth,
            # left in +bits_at+ shifted to the row's place in its byte, or on to the next piece with
            # both clear. +pointer+ with Y is at the piece's size.
            def emit_sprite_row_bits(asm, memory, pointer, piece_x, bits_at)
              asm.lda(asm.ind_long_y(pointer))
              asm.sta(asm.direct(bits_at))
              asm.iny
              asm.iny
              asm.lda(asm.direct(piece_x))
              asm.bpl("rt_sprite_place_on_screen")
              asm.inc(asm.direct(bits_at))
              asm.label("rt_sprite_place_on_screen")
              asm.lda(asm.direct(bits_at))
              asm.bne("rt_sprite_place_row_bits")
              asm.brl("rt_sprite_place_piece")
              asm.label("rt_sprite_place_row_bits")
              asm.lda(asm.abs(memory[NEXT_ROW]))
              asm.and_a(3)
              asm.asl
              asm.asl
              asm.ora(asm.direct(bits_at))
              asm.tax
              asm.lda(asm.long_x("rt_sprite_row_bits"))
              asm.and_a(0x00FF)
              asm.sta(asm.direct(bits_at))
            end

            # BACKGROUNDS. rt_background_put_up(layer, grid, from_corner): the grid numbered +grid+
            # (the table "art grids") copied onto +layer+ in the next blank, and with +from_corner+
            # its view at the corner. rt_background_scroll(layer, x, y). rt_set_cell(layer, column,
            # row, word): one cell of the layer's map, in the next blank.
            def emit_backgrounds(asm, memory, work)
              r = ->(n) { Memory.register(n) }
              layers = memory[LAYERS]

              asm.label("rt_layer_state") # X = where layer R0's state starts
              asm.lda(asm.direct(r.call(0)))
              4.times { asm.asl }
              asm.tax
              asm.rts

              asm.label("rt_background_put_up")
              asm.jsr(asm.abs("rt_layer_state"))
              asm.lda(asm.direct(r.call(1)))
              asm.asl
              asm.sta(asm.direct(work))
              asm.asl
              asm.asl
              asm.adc(asm.direct(work)) # × 10: an entry of the grids' table
              asm.tay
              [[0, LAYER_SOURCE], [2, LAYER_SOURCE + 2], [4, LAYER_BYTES], [6, LAYER_SC], [8, LAYER_COLUMNS]].each do |from, to|
                asm.tya
                asm.phx
                asm.tax
                asm.lda(asm.long_x("art grids", from))
                asm.plx
                asm.sta(asm.abs_x(layers + to))
              end
              asm.lda(1)
              asm.sta(asm.abs_x(layers + LAYER_PENDING))
              asm.lda(asm.direct(r.call(2)))
              asm.beq("rt_background_put_up_done")
              asm.stz(asm.abs_x(layers + LAYER_SCROLL_X))
              asm.stz(asm.abs_x(layers + LAYER_SCROLL_Y))
              asm.label("rt_background_put_up_done")
              asm.rtl

              asm.label("rt_background_scroll")
              asm.jsr(asm.abs("rt_layer_state"))
              asm.lda(asm.direct(r.call(1)))
              asm.sta(asm.abs_x(layers + LAYER_SCROLL_X))
              asm.lda(asm.direct(r.call(2)))
              asm.sta(asm.abs_x(layers + LAYER_SCROLL_Y))
              asm.rtl

              # The cell's address: the map's start, the screen of 32×32 it is in (the second across,
              # and below them the third and fourth — or the second, for a map one screen wide), and
              # its row and column in that screen.
              asm.label("rt_set_cell")
              asm.jsr(asm.abs("rt_layer_state"))
              asm.lda(asm.direct(r.call(2)))
              asm.and_a(31)
              5.times { asm.asl }
              asm.sta(asm.direct(work))
              asm.lda(asm.direct(r.call(1)))
              asm.and_a(31)
              asm.ora(asm.direct(work))
              asm.sta(asm.direct(work))
              asm.lda(asm.direct(r.call(1)))
              asm.and_a(32)
              asm.beq("rt_set_cell_left")
              asm.lda(asm.direct(work))
              asm.clc
              asm.adc(1024)
              asm.sta(asm.direct(work))
              asm.label("rt_set_cell_left")
              asm.lda(asm.direct(r.call(2)))
              asm.and_a(32)
              asm.beq("rt_set_cell_top")
              asm.lda(asm.abs_x(layers + LAYER_COLUMNS))
              asm.cmp(64)
              asm.lda(asm.direct(work))
              asm.bcc("rt_set_cell_narrow")
              asm.adc(2048 - 1) # the carry is set
              asm.bra("rt_set_cell_below")
              asm.label("rt_set_cell_narrow")
              asm.adc(1024)
              asm.label("rt_set_cell_below")
              asm.sta(asm.direct(work))
              asm.label("rt_set_cell_top")
              # The layer's map's start: layer 0's, or layer 1's.
              asm.lda(asm.direct(r.call(0)))
              asm.beq("rt_set_cell_first")
              asm.lda(LAYER_MAPS[1] - LAYER_MAPS[0])
              asm.label("rt_set_cell_first")
              asm.clc
              asm.adc(LAYER_MAPS[0])
              asm.adc(asm.direct(work))
              asm.sta(asm.direct(work))
              # Into the queue. A full queue stops the game, saying so (Frame::CELLS_FULL): the cell
              # would otherwise never reach the screen.
              asm.lda(asm.abs(memory[CELLS]))
              asm.cmp(MOST_CELLS)
              asm.bcc("rt_set_cell_room")
              asm.lda(Frame::CELLS_FULL)
              asm.jml(asm.long("rt_fault"))
              asm.label("rt_set_cell_room")
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.direct(work))
              asm.sta(asm.abs_x(memory[CELLS] + 2))
              asm.lda(asm.direct(r.call(3)))
              asm.sta(asm.abs_x(memory[CELLS] + 4))
              asm.inc(asm.abs(memory[CELLS]))
              asm.rtl
            end

            # STATUS BAR. rt_bar_place(layer, top): the bar on +layer+ shown from row +top+, held to
            # the screen (0 to its height, where none of it shows), from the next blank on.
            def emit_bar(asm, memory, scene_bars: false)
              r = ->(n) { Memory.register(n) }
              bar = memory[BAR]
              layers = memory[LAYERS]
              asm.label("rt_bar_place")
              asm.lda(asm.direct(r.call(1) + 2))
              asm.bmi("rt_bar_place_none")
              asm.bne("rt_bar_place_past")
              asm.lda(asm.direct(r.call(1)))
              asm.cmp(SCREEN_HEIGHT + 1)
              asm.bcc("rt_bar_place_top")
              asm.label("rt_bar_place_past")
              asm.lda(SCREEN_HEIGHT)
              asm.bra("rt_bar_place_top")
              asm.label("rt_bar_place_none")
              asm.lda(0)
              asm.label("rt_bar_place_top")
              asm.sta(asm.abs(bar + BAR_TOP))
              asm.lda(asm.direct(r.call(0)))
              asm.sta(asm.abs(bar + BAR_LAYER))
              # The layer scrolled up by the top: its first row there, and never across.
              asm.jsr(asm.abs("rt_layer_state"))
              asm.stz(asm.abs_x(layers + LAYER_SCROLL_X))
              asm.lda(asm.abs(bar + BAR_TOP))
              asm.eor(0xFFFF)
              asm.inc
              asm.sta(asm.abs_x(layers + LAYER_SCROLL_Y))
              asm.lda(1)
              asm.sta(asm.abs(bar + BAR_CHANGED))
              asm.rtl
              if scene_bars
                # rt_bar_gone(): a scene with no bar has taken over, so from the next blank the
                # line table stops and both layers and the sprites show on every line.
                asm.label("rt_bar_gone")
                asm.lda(BAR_LEAVES)
                asm.sta(asm.abs(bar + BAR_CHANGED))
                asm.rtl
              end
              return unless memory.reserved?(BAR_COVERS)

              # rt_bar_covers(covers): whether the sprites show from the bar's top down.
              asm.label("rt_bar_covers")
              asm.lda(asm.direct(r.call(0)))
              asm.sta(asm.abs(memory[BAR_COVERS]))
              asm.lda(1)
              asm.sta(asm.abs(bar + BAR_CHANGED))
              asm.rtl
            end

            # In the blank, if the bar moved: its table of lines made again, and channel 1 set to
            # write TM from it on every frame from the next. +work+'s words: the bar's layer's bit,
            # TM above the bar, TM from it down.
            def emit_bar_table(asm, memory, work, scene_bars: false)
              h = Console::SNESHardware
              bar = memory[BAR]
              table = bar + BAR_TABLE
              channel = h::DMA_BASE + BAR_CHANNEL
              asm.lda(asm.abs(bar + BAR_CHANGED))
              if memory.reserved?(BAR_COVERS) || scene_bars # the table's code is past a short branch's reach then
                asm.bne("rt_bar_table_changed")
                asm.brl("rt_bar_table_kept")
                asm.label("rt_bar_table_changed")
              else
                asm.beq("rt_bar_table_kept")
              end
              asm.stz(asm.abs(bar + BAR_CHANGED))
              if scene_bars
                asm.cmp(BAR_LEAVES)
                asm.bne("rt_bar_table_stays")
                asm.lda(asm.abs(memory[HDMA_CHANNELS]))
                asm.and_a(~(1 << (BAR_CHANNEL >> 4)) & 0xFFFF)
                asm.sta(asm.abs(memory[HDMA_CHANNELS]))
                asm.sep(0x20)
                asm.lda(LAYERS_SHOWN)
                asm.sta(asm.abs(h::TM))
                asm.rep(0x20)
                asm.brl("rt_bar_table_kept")
                asm.label("rt_bar_table_stays")
              end
              asm.lda(asm.abs(bar + BAR_LAYER))
              asm.inc # BG1's bit is 1, BG2's 2
              asm.sta(asm.direct(work))
              asm.lda(LAYERS_SHOWN)
              asm.eor(asm.direct(work))
              asm.sta(asm.direct(work + 2))
              asm.lda(asm.direct(work))
              asm.ora(SPRITES_SHOWN)
              asm.sta(asm.direct(work + 4))
              if memory.reserved?(BAR_COVERS)
                asm.lda(asm.abs(memory[BAR_COVERS]))
                asm.beq("rt_bar_table_sprites_kept")
                asm.lda(asm.direct(work))
                asm.sta(asm.direct(work + 4))
                asm.label("rt_bar_table_sprites_kept")
              end
              # The lines above the bar, in one step or two; none for a bar at the top.
              asm.ldx(0)
              asm.lda(asm.abs(bar + BAR_TOP))
              asm.beq("rt_bar_table_below")
              asm.cmp(MOST_STEP_LINES + 1)
              asm.bcc("rt_bar_table_one_step")
              asm.sec
              asm.sbc(MOST_STEP_LINES)
              asm.sep(0x20)
              asm.sta(asm.abs(table + 2))
              asm.lda(MOST_STEP_LINES)
              asm.sta(asm.abs(table))
              asm.lda(asm.direct(work + 2))
              asm.sta(asm.abs(table + 1))
              asm.sta(asm.abs(table + 3))
              asm.rep(0x20)
              asm.ldx(4)
              asm.bra("rt_bar_table_below")
              asm.label("rt_bar_table_one_step")
              asm.sep(0x20)
              asm.sta(asm.abs(table))
              asm.lda(asm.direct(work + 2))
              asm.sta(asm.abs(table + 1))
              asm.rep(0x20)
              asm.ldx(2)
              # From the bar down: a step of one line, then the end of the table, which holds the
              # value to the bottom of the screen.
              asm.label("rt_bar_table_below")
              asm.sep(0x20)
              asm.lda(1)
              asm.sta(asm.abs_x(table))
              asm.lda(asm.direct(work + 4))
              asm.sta(asm.abs_x(table + 1))
              asm.stz(asm.abs_x(table + 2))
              asm.stz(asm.abs(channel + h::DMAP)) # a byte a line, to one port, from the table itself
              asm.lda(h::TM & 0xFF)
              asm.sta(asm.abs(channel + h::BBAD))
              asm.lda(table >> 16)
              asm.sta(asm.abs(channel + h::A1B))
              asm.rep(0x20)
              asm.lda(table & 0xFFFF)
              asm.sta(asm.abs(channel + h::A1TL))
              asm.lda(asm.abs(memory[HDMA_CHANNELS]))
              asm.ora(1 << (BAR_CHANNEL >> 4))
              asm.sta(asm.abs(memory[HDMA_CHANNELS]))
              asm.label("rt_bar_table_kept")
            end

            # BENDS. rt_bends_prepare (JSL, as a pass ends): for each layer in +bent+, the line table
            # the channel is not reading made from the layer's rows and its scroll across: +work+ is
            # the table's place (three bytes and a spare) and the lines left of a step.
            def emit_bends_prepare(asm, memory, work, bent, banded)
              layers = memory[LAYERS]
              asm.label("rt_bends_prepare")
              bent.each do |layer|
                tables = memory[bend_tables(layer)]
                offsets = memory[bend_offsets(layer)]
                tag = "rt_bends_prepare_#{layer}"
                emit_skip_straight_layer(asm, memory, layer, "#{tag}_done")
                # The table not shown: the second, past the first, while the first is shown.
                asm.lda(asm.abs(memory[BEND_SHOWN] + (layer * 2)))
                asm.beq("#{tag}_second")
                asm.lda(0)
                asm.bra("#{tag}_chosen")
                asm.label("#{tag}_second")
                asm.lda(BEND_TABLE_BYTES)
                asm.label("#{tag}_chosen")
                asm.clc
                asm.adc(tables & 0xFFFF) # the tables are in one bank (Memory#reserve_far), so this never carries
                asm.sta(asm.direct(work))
                asm.lda(tables >> 16)
                asm.sta(asm.direct(work + 2))
                asm.ldy(0)
                asm.ldx(0)
                scroll = asm.abs(layers + (layer * LAYER_STATE_BYTES) + LAYER_SCROLL_X)
                if banded
                  emit_band_steps(asm, work, offsets, scroll, tag)
                else
                  emit_line_steps(asm, work, offsets, scroll, tag)
                end
                asm.sep(0x20)
                asm.lda(0) # the end of the table
                asm.sta(asm.ind_long_y(work))
                asm.rep(0x20)
                asm.label("#{tag}_done")
              end
              asm.rtl
            end

            # A value for every line, two steps of them, from a word a row.
            def emit_line_steps(asm, work, offsets, scroll, tag)
              2.times do |step|
                asm.sep(0x20)
                asm.lda(REPEAT | BEND_STEP_LINES)
                asm.sta(asm.ind_long_y(work))
                asm.rep(0x20)
                asm.iny
                asm.lda(BEND_STEP_LINES)
                asm.sta(asm.direct(work + 4))
                asm.label("#{tag}_line_#{step}")
                asm.lda(asm.long_x(offsets))
                asm.clc
                asm.adc(scroll)
                asm.sta(asm.ind_long_y(work))
                asm.iny
                asm.iny
                asm.inx
                asm.inx
                asm.dec(asm.direct(work + 4))
                asm.bne("#{tag}_line_#{step}")
              end
            end

            # A step for each band, from the steps the game kept.
            def emit_band_steps(asm, work, offsets, scroll, tag)
              asm.label("#{tag}_band")
              asm.lda(asm.long_x(offsets))
              asm.beq("#{tag}_bands_done")
              asm.sep(0x20)
              asm.sta(asm.ind_long_y(work))
              asm.rep(0x20)
              asm.iny
              asm.lda(asm.long_x(offsets + 2))
              asm.clc
              asm.adc(scroll)
              asm.sta(asm.ind_long_y(work))
              asm.iny
              asm.iny
              BAND_STEP_BYTES.times { asm.inx }
              asm.bra("#{tag}_band")
              asm.label("#{tag}_bands_done")
            end

            # On to +past+ while +layer+'s rows are straight (LAYERS_STRAIGHT), in a game that has
            # any that can be: a scene that bends it is away. The block's code runs just before.
            def emit_skip_straight_layer(asm, memory, layer, past)
              return unless memory.reserved?(LAYERS_STRAIGHT)

              bent_now = "#{past}_bent_now"
              asm.lda(asm.abs(memory[LAYERS_STRAIGHT]))
              asm.and_a(1 << layer)
              asm.beq(bent_now)
              yield if block_given?
              asm.brl(past)
              asm.label(bent_now)
            end

            # In the blank: each bent layer's channel switched to the table just made, writing the
            # layer's BGnHOFS twice a line (low byte, then high). A layer whose rows are straight has
            # its channel left off, so the scroll written once in the blank holds for every line.
            def emit_bends_shown(asm, memory, bent)
              h = Console::SNESHardware
              bent.each do |layer|
                tables = memory[bend_tables(layer)]
                channel = h::DMA_BASE + (BEND_CHANNELS.fetch(layer) << 4)
                shown = memory[BEND_SHOWN] + (layer * 2)
                tag = "rt_bends_shown_#{layer}"
                emit_skip_straight_layer(asm, memory, layer, "#{tag}_done") do
                  asm.lda(asm.abs(memory[HDMA_CHANNELS]))
                  asm.and_a(0xFFFF ^ (1 << BEND_CHANNELS.fetch(layer)))
                  asm.sta(asm.abs(memory[HDMA_CHANNELS]))
                end
                asm.lda(asm.abs(shown))
                asm.eor(1)
                asm.sta(asm.abs(shown))
                asm.beq("#{tag}_first")
                asm.lda(BEND_TABLE_BYTES)
                asm.label("#{tag}_first") # A is nought here for the first
                asm.clc
                asm.adc(tables & 0xFFFF)
                asm.sta(asm.abs(channel + h::A1TL))
                asm.sep(0x20)
                asm.lda(tables >> 16)
                asm.sta(asm.abs(channel + h::A1B))
                asm.lda(h::DMA_TO_ONE_PORT_TWICE)
                asm.sta(asm.abs(channel + h::DMAP))
                asm.lda((h::BG1HOFS + (layer * 2)) & 0xFF)
                asm.sta(asm.abs(channel + h::BBAD))
                asm.rep(0x20)
                asm.lda(asm.abs(memory[HDMA_CHANNELS]))
                asm.ora(1 << BEND_CHANNELS.fetch(layer))
                asm.sta(asm.abs(memory[HDMA_CHANNELS]))
                asm.label("#{tag}_done")
              end
            end

            # In the blank: the channels that write a register a line at a time switched on.
            def emit_hdma_on(asm, memory)
              asm.sep(0x20)
              asm.lda(asm.abs(memory[HDMA_CHANNELS]))
              asm.sta(asm.abs(Console::SNESHardware::HDMAEN))
              asm.rep(0x20)
            end

            # A run's scratch on the direct page.
            def run_scratch(memory)
              RunScratch.new(list: memory.scratch(4), out: memory.scratch(4), held: memory.scratch(2),
                             tiles: memory.scratch(2), tile: memory.scratch(2), planes: memory.scratch(4))
            end

            # TILES PAINTED FROM A LIST. rt_tile_run_copy(run): run number +run+'s list made into its
            # tiles in the console's form, at its staging, and owed to video RAM in the next blank.
            # Bytes past what the list holds are nought, see-through, as the interpreter reads them.
            def emit_tile_run_copy(asm, memory, s)
              asm.label("rt_tile_run_copy")
              emit_tile_run_opening(asm, memory, s, "rt_tile_run_copy")
              asm.label("rt_tile_run_copy_tile")
              asm.ldx(0) # the row, two bytes a row
              asm.label("rt_tile_run_copy_row")
              asm.sep(0x20)
              4.times do |byte|
                read = "rt_tile_run_copy_byte_#{byte}"
                asm.cpy(asm.direct(s.held))
                asm.bcs("#{read}_past")
                asm.lda(asm.ind_long_y(s.list))
                asm.bra(read)
                asm.label("#{read}_past")
                asm.lda(0)
                asm.label(read)
                asm.iny
                # Two pixels, the left one first: each of its four bits into its plane in turn.
                8.times do |bit|
                  asm.lsr
                  asm.rol(asm.direct(s.planes + (bit % 4)))
                end
              end
              asm.rep(0x20)
              # Planes 0 and 1 at the row's two bytes of the tile, planes 2 and 3 sixteen on.
              asm.phy
              asm.txa
              asm.clc
              asm.adc(asm.direct(s.tile))
              asm.tay
              asm.lda(asm.direct(s.planes))
              asm.sta(asm.ind_long_y(s.out))
              asm.tya
              asm.clc
              asm.adc(16)
              asm.tay
              asm.lda(asm.direct(s.planes + 2))
              asm.sta(asm.ind_long_y(s.out))
              asm.ply
              asm.inx
              asm.inx
              asm.cpx(16)
              asm.branch_long(:bne, "rt_tile_run_copy_row")
              asm.lda(asm.direct(s.tile))
              asm.clc
              asm.adc(32)
              asm.sta(asm.direct(s.tile))
              asm.dec(asm.direct(s.tiles))
              asm.branch_long(:bne, "rt_tile_run_copy_tile")
              asm.rtl
            end

            # rt_tile_run_straight(run): a list already in the console's own form
            # (`console_format: true`), byte for byte into the run's staging, a byte past the
            # list's length reading nought as it does above. A game has this only if it asks for it.
            def emit_tile_run_straight(asm, memory, s)
              asm.label("rt_tile_run_straight")
              emit_tile_run_opening(asm, memory, s, "rt_tile_run_straight")
              asm.lda(asm.direct(s.tiles))
              5.times { asm.asl } # 32 bytes a tile
              asm.sta(asm.direct(s.tile))
              asm.sep(0x20)
              asm.label("rt_tile_run_straight_byte")
              asm.cpy(asm.direct(s.held))
              asm.bcs("rt_tile_run_straight_past")
              asm.lda(asm.ind_long_y(s.list))
              asm.bra("rt_tile_run_straight_read")
              asm.label("rt_tile_run_straight_past")
              asm.lda(0)
              asm.label("rt_tile_run_straight_read")
              asm.sta(asm.ind_long_y(s.out))
              asm.iny
              asm.cpy(asm.direct(s.tile))
              asm.bne("rt_tile_run_straight_byte")
              asm.rep(0x20)
              asm.rtl
            end

            # What both copies start with: the run noted as owed, and its list, staging, tiles and
            # the bytes its list holds read out of its entry in "art tile runs". Leaves Y nought.
            def emit_tile_run_opening(asm, memory, s, name)
              r = ->(n) { Memory.register(n) }
              asm.lda(asm.direct(r.call(0)))
              asm.asl
              asm.tax
              asm.lda(1)
              asm.sta(asm.abs_x(memory[TILE_RUNS_OWED]))
              asm.txa
              3.times { asm.asl } # an entry of the table
              asm.tax
              [[RUN_LIST, s.list], [RUN_STAGING, s.out]].each do |at, to|
                asm.lda(asm.long_x("art tile runs", at))
                asm.sta(asm.direct(to))
                asm.lda(asm.long_x("art tile runs", at + 2))
                asm.sta(asm.direct(to + 2))
              end
              asm.lda(asm.long_x("art tile runs", RUN_TILES))
              asm.sta(asm.direct(s.tiles))
              # The bytes the list holds, its run's bytes at most; then from its first byte, past the
              # header (a list never straddles a bank, Memory#reserve_far).
              asm.ldy(Lists::LENGTH)
              asm.lda(asm.ind_long_y(s.list))
              asm.cmp(asm.long_x("art tile runs", RUN_BYTES))
              asm.bcc("#{name}_held")
              asm.lda(asm.long_x("art tile runs", RUN_BYTES))
              asm.label("#{name}_held")
              asm.sta(asm.direct(s.held))
              asm.lda(asm.direct(s.list))
              asm.clc
              asm.adc(Lists::HEADER)
              asm.sta(asm.direct(s.list))
              asm.stz(asm.direct(s.tile))
              asm.ldy(0) # the list's byte
            end

            # In the blank: each run owed a copy, its staging to its tiles in video RAM, a piece of
            # MAP_PIECE bytes at a time as the blanks have room. +work+: the piece's bytes, and the
            # run's entry of the table.
            def emit_tile_run_upload(asm, memory, work, tile_runs)
              h = Console::SNESHardware
              tile_runs.times do |number|
                done = "rt_upload_run#{number}_copied"
                piece = "rt_upload_run#{number}_piece"
                entry = number * RUN_ENTRY_BYTES
                owed = memory[TILE_RUNS_OWED] + (number * 2)
                asm.lda(asm.abs(owed))
                asm.branch_long(:beq, done)
                asm.stz(asm.abs(owed))
                asm.ldx(0)
                asm.label(piece)
                asm.txa
                asm.cmp(asm.long("art tile runs", entry + RUN_BYTES))
                asm.branch_long(:bcs, done)
                asm.stx(asm.direct(work))
                asm.lda(asm.long("art tile runs", entry + RUN_BYTES))
                asm.sec
                asm.sbc(asm.direct(work))
                asm.cmp(MAP_PIECE)
                asm.bcc("#{piece}_bytes")
                asm.lda(MAP_PIECE)
                asm.label("#{piece}_bytes")
                asm.sta(asm.direct(work))
                asm.jsr(asm.abs("rt_blank_room"))
                asm.lda(asm.direct(work))
                asm.sta(asm.abs(h::DMA_BASE + h::DASL))
                asm.txa
                asm.lsr # a word of video RAM for every two bytes
                asm.clc
                asm.adc(asm.long("art tile runs", entry + RUN_PLACE))
                asm.sta(asm.abs(h::VMADDL))
                asm.txa
                asm.clc
                asm.adc(asm.long("art tile runs", entry + RUN_STAGING)) # the staging is in one bank
                asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
                asm.sep(0x20)
                asm.lda(asm.long("art tile runs", entry + RUN_STAGING + 2))
                asm.sta(asm.abs(h::DMA_BASE + h::A1B))
                asm.lda(h::DMA_TO_TWO_PORTS)
                asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
                asm.lda(h::VMDATAL & 0xFF)
                asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
                asm.lda(1)
                asm.sta(asm.abs(h::MDMAEN))
                asm.rep(0x20)
                asm.txa
                asm.clc
                asm.adc(asm.direct(work))
                asm.tax
                asm.brl(piece)
                asm.label(done)
              end
            end

            # THE COPY IN THE BLANK, with the screen on (Blank says how). A map put up goes first, a
            # piece of MAP_PIECE bytes at a time as the blanks have room, with the old picture still
            # up; then, together in one blank, the sprite table, the colours, each layer's map
            # register and its scroll; then the cells changed, each when the blank has a line left
            # for it. A painted screen's copy is Paint's rt_paint_upload. With the screen still off,
            # before the first pass is shown, everything goes at once.
            def emit_upload(asm, memory, work, painted, bar, bent, tile_runs, math_turns = false, scene_bars = false)
              h = Console::SNESHardware
              layers = memory[LAYERS]
              # The first pass's, with the screen off (Frame switches it on), and every other's.
              asm.label("rt_upload_whole")
              asm.label("rt_upload")
              asm.jsr(asm.abs("rt_upload_copy"))
              asm.rtl

              asm.label("rt_upload_copy")
              asm.jsr(asm.abs("rt_blank_begin"))
              if painted
                asm.jmp(asm.abs("rt_paint_upload"))
                return
              end

              emit_scene_background_tiles_upload(asm, memory, work) if memory.reserved?(SCENE_BACKGROUND_TILES)

              # Each layer's map, if one is waiting, a piece at a time: X is how far it has got.
              LAYER_MAPS.each_with_index do |at, layer|
                state = layers + (layer * LAYER_STATE_BYTES)
                done = "rt_upload_layer#{layer}_copied"
                piece = "rt_upload_layer#{layer}_piece"
                asm.lda(asm.abs(state + LAYER_PENDING))
                asm.beq(done)
                asm.ldx(0)
                asm.label(piece)
                asm.txa
                asm.cmp(asm.abs(state + LAYER_BYTES))
                asm.bcs(done)
                asm.lda(asm.abs(state + LAYER_BYTES)) # the bytes left, MAP_PIECE at most
                asm.stx(asm.direct(work))
                asm.sec
                asm.sbc(asm.direct(work))
                asm.cmp(MAP_PIECE)
                asm.bcc("#{piece}_bytes")
                asm.lda(MAP_PIECE)
                asm.label("#{piece}_bytes")
                asm.sta(asm.direct(work))
                asm.jsr(asm.abs("rt_blank_room"))
                asm.lda(asm.direct(work))
                asm.sta(asm.abs(h::DMA_BASE + h::DASL))
                asm.txa
                asm.lsr # a word of video RAM for every two bytes
                asm.clc
                asm.adc(at)
                asm.sta(asm.abs(h::VMADDL))
                asm.txa
                asm.clc
                asm.adc(asm.abs(state + LAYER_SOURCE)) # a map is whole in one bank, so this never carries
                asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
                asm.sep(0x20)
                asm.lda(asm.abs(state + LAYER_SOURCE + 2))
                asm.sta(asm.abs(h::DMA_BASE + h::A1B))
                asm.lda(h::DMA_TO_TWO_PORTS)
                asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
                asm.lda(h::VMDATAL & 0xFF)
                asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
                asm.lda(1)
                asm.sta(asm.abs(h::MDMAEN))
                asm.rep(0x20)
                asm.txa
                asm.clc
                asm.adc(asm.direct(work))
                asm.tax
                asm.bra(piece)
                asm.label(done)
              end

              emit_scene_tiles_upload(asm, memory, work) if memory.reserved?(SCENE_TILES)
              emit_tile_run_upload(asm, memory, work, tile_runs)

              # The cells changed, each a word at its address. Many take more than a blank, so they
              # go before the colours: a frame between shows some of the cells in the old colours,
              # which is the pass's change arriving, and never the new colours over an old cell.
              asm.ldx(0)
              asm.label("rt_upload_cell")
              asm.lda(asm.abs(memory[CELLS]))
              asm.beq("rt_upload_cells_done")
              asm.jsr(asm.abs("rt_blank_time"))
              asm.dec(asm.abs(memory[CELLS]))
              asm.lda(asm.abs_x(memory[CELLS] + 2))
              asm.sta(asm.abs(h::VMADDL))
              asm.lda(asm.abs_x(memory[CELLS] + 4))
              asm.sta(asm.abs(h::VMDATAL))
              asm.inx
              asm.inx
              asm.inx
              asm.inx
              asm.bra("rt_upload_cell")
              asm.label("rt_upload_cells_done")

              # Together: the sprite table whole, the colours if a fade or a tint moved them, and
              # each layer's map register, for a map just put up, and scroll.
              tint_changed = memory[Tint::STATE] + Tint::CHANGED
              asm.lda(asm.abs(tint_changed))
              asm.beq("rt_upload_together_bytes")
              asm.lda(512)
              asm.label("rt_upload_together_bytes")
              asm.clc
              asm.adc(544)
              asm.jsr(asm.abs("rt_blank_room"))
              asm.stz(asm.abs(h::OAMADDL))
              emit_dma(asm, h::DMA_TO_ONE_PORT, h::OAMDATA, asm.imm(memory[SHADOW_OAM] & 0xFFFF),
                       memory[SHADOW_OAM] >> 16, 544)
              asm.jsr(asm.abs("rt_tint_upload"))
              if math_turns
                asm.sep(0x20)
                asm.lda(asm.abs(memory[MATH]))
                asm.sta(asm.abs(h::CGADSUB))
                asm.rep(0x20)
              end
              if memory.reserved?(TILE_SIZES)
                asm.sep(0x20)
                asm.lda(asm.abs(memory[TILE_SIZES]))
                asm.sta(asm.abs(h::BGMODE))
                asm.rep(0x20)
              end
              LAYER_MAPS.each_with_index do |at, layer|
                state = layers + (layer * LAYER_STATE_BYTES)
                kept = "rt_upload_layer#{layer}_register_kept"
                asm.lda(asm.abs(state + LAYER_PENDING))
                asm.beq(kept)
                asm.stz(asm.abs(state + LAYER_PENDING))
                asm.sep(0x20)
                asm.lda(asm.abs(state + LAYER_SC))
                asm.ora((at >> 10) << 2)
                asm.sta(asm.abs(h::BG1SC + layer))
                asm.rep(0x20)
                asm.label(kept)
                # The scroll, each register written twice, its low byte and then its high. The
                # screen's first row is the console's line 1, not line 0, so a layer shows the map
                # row one past its vertical scroll there: the scroll written is one less than the
                # game's, which puts the map's row where the game said.
                asm.lda(asm.abs(state + LAYER_SCROLL_X))
                emit_scroll_register(asm, h::BG1HOFS + (layer * 2))
                asm.lda(asm.abs(state + LAYER_SCROLL_Y))
                asm.dec
                emit_scroll_register(asm, h::BG1VOFS + (layer * 2))
              end
              emit_bar_table(asm, memory, work, scene_bars: scene_bars) if bar
              emit_bends_shown(asm, memory, bent)
              emit_hdma_on(asm, memory) if bar || !bent.empty?
              asm.rts
            end
          end
        end
      end
    end
  end
end
