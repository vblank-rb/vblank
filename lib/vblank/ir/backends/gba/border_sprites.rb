# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # A SMALLER SCREEN SHOWN IN THE MIDDLE OF THE ADVANCE'S, WITH A BORDER ROUND IT: a game laid out
        # for the Game Boy Color's 160×144, built for the Advance (Console::AdvanceKit::COLOR_SCREEN).
        #
        # The game itself is lowered exactly as any other; what changes is where its picture lands on
        # the screen, and what fills the rest. Three of the console's own parts do it, and no drawing
        # verb learns anything:
        #
        # - THE PICTURE MOVES BY ITS SCROLL. A background shows its map from the place its scroll
        #   registers name, so a background scrolled 40 pixels further left and 8 further up shows
        #   the game's top-left corner at (40, 8) on the screen. Every write of a scroll takes the
        #   corner off (#emit_corner_off_scroll). A painted screen is the console's third
        #   background, drawn through the same turning-and-resizing numbers a turning background has,
        #   whose "reference point" sets which pixel of the picture is drawn at the screen's corner:
        #   pointed at (-40, -8) the picture lands at (40, 8) too (#emit_painted_screen_corner).
        # - THE SPRITES MOVE AS THEY ARE COPIED. A sprite's place is written into a copy of the
        #   console's sprite table (SpriteDrawing::HeldTable), never into the console's own, and that
        #   copy is put into the console's table once a frame, between frames, adding the corner to
        #   each place as it goes. So a sprite stands where the game put it, inside the game's screen,
        #   whatever wrote its place.
        # - THE BORDER IS SPRITES IN FRONT OF EVERYTHING. The first rows of the console's table
        #   (BORDER_ROWS of them, Console::AdvanceKit::BORDER_SPRITES) hold sprites that cover the
        #   border exactly and nothing else, written whenever the table is cleared and never touched
        #   again. A sprite nearer the top of the table is drawn in front of one further down, and
        #   these are at the very top and in front of every background, so whatever the game's
        #   picture has past its own edges (a background's map runs on; a sprite can stand half off)
        #   is behind them. Their pictures are the last 240 tiles of sprite memory, where a painted
        #   screen never reaches, so they stay put through any change of screen; and their sixteen
        #   colours are the last group of the sprites' table, which the game's own sprites never use
        #   (refused at ScreenLayout#refuse_sprite_colors_over_border!).
        #
        # A whole-screen fade or tint would darken the border too, since the console blends every
        # layer it is told to across the whole screen. So the display's first window is the game's
        # screen: inside it every layer shows and the blend applies, and outside it only the sprites
        # (which there are the border's) show, and nothing is blended (#emit_window).
        #
        # What the game sees is a 160×144 screen. `screen_width` and `screen_height` give that size, the
        # interpreter plays the game on one, and every frame of the cartridge's middle is that
        # picture.
        class BorderSprites
          include Console::Hardware

          # One sprite of the border: where it stands on the screen and its size, in pixels.
          Piece = Data.define(:x, :y, :width, :height) do
            def tiles = (width / 8) * (height / 8)
          end

          # The sizes a sprite is drawn at, each with its two numbers in the table: its shape (square,
          # wide, tall) and its size within that shape.
          SHAPES = Ractor.make_shareable({
            [8, 8] => [0, 0], [16, 16] => [0, 1], [32, 32] => [0, 2], [64, 64] => [0, 3],
            [16, 8] => [1, 0], [32, 8] => [1, 1], [32, 16] => [1, 2], [64, 32] => [1, 3],
            [8, 16] => [2, 0], [8, 32] => [2, 1], [16, 32] => [2, 2], [32, 64] => [2, 3]
          })

          # The rows of the console's sprite table the border holds: the first ones.
          BORDER_ROWS = Console::AdvanceKit::BORDER_SPRITES

          # The group of sixteen colours the border's sprites read: the last.
          COLOR_GROUP = PaletteBanks::BANKS - 1

          # How many tiles of sprite memory the border's pictures take, at the end of it.
          def self.tiles_for(console) = border_area(console) / 64

          def self.border_area(console)
            whole = console.whole_screen_size
            (whole[0] * whole[1]) - (console.screen_width * console.screen_height)
          end

          # The border for +program+, or nil where it shows its screen whole. +emitter+, +primitives+
          # and +uploads+ are the build's, which the code putting it up is written through.
          def self.for(program, emitter:, primitives:, uploads:)
            console = program.described_console
            return nil unless console.bordered?

            new(program, console, emitter: emitter, primitives: primitives, uploads: uploads)
          end

          include EmitterCalls

          def initialize(program, console, emitter:, primitives:, uploads:)
            @emitter = emitter
            @primitives = primitives
            @uploads = uploads
            @whole = console.whole_screen_size
            @left, @top = console.border_corner
            @inner = console.screen_size
            @pixels = picture_of(program)
            @pieces = cover_border
            if @pieces.size > BORDER_ROWS
              raise LoweringError, "the border needs #{@pieces.size} sprites, and #{BORDER_ROWS} rows are kept for it"
            end

            # The border's colours in the order first met; place 0 of the group is see-through, so
            # each is at its index and one.
            @colors = @pixels.each_with_index.filter_map { |color, at| color if in_border?(at) }.uniq
            @places = @colors.each_with_index.to_h { |color, at| [color, at + 1] }
            @first_tile = (OBJ_TILES - tiles_for_pieces)
          end

          # Every tile of sprite memory, counting 32 bytes a tile from its start.
          OBJ_TILES = 1024

          # The cartridge data the border needs: its rows of the sprite table, its pictures and its
          # colours, by the names they are copied by.
          ROWS_BLOB = :__border_rows
          TILES_BLOB = :__border_tiles
          COLORS_BLOB = :__border_colors

          def blobs = { ROWS_BLOB => rows_bytes, TILES_BLOB => tiles_bytes, COLORS_BLOB => [0, *@colors].pack("v*") }

          # Put the border up: its rows of the sprite table, its pictures and its colours. Run whenever
          # the sprite table has just been cleared, which is at power-on and on coming back to a screen
          # that painted over sprite memory, so it is in front from the first frame shown.
          def emit_put_up
            @uploads.emit_dma_blob(ROWS_BLOB, OAM_START, BORDER_ROWS * 4)
            @uploads.emit_dma_blob(TILES_BLOB, SpriteDrawing::OBJ_TILE_BASE + (@first_tile * 32), tiles_for_pieces * 16)
            @uploads.emit_dma_blob(COLORS_BLOB, OBJ_PALETTE + (COLOR_GROUP * 32), @colors.size + 1)
          end

          # The display's first window round the game's screen, and the painted screen's corner, once
          # at power-on: both stay as they are told through every change of screen.
          def emit_at_power_on
            emit_window
            emit_painted_screen_corner
          end

          # A scroll of +offset+ along one way (:x or :y), as the register is told it: the corner
          # taken off, kept to the register's nine bits.
          def scroll_value(offset, way) = (offset - corner(way)) & 0x1FF

          # The scroll in ACC, made the register's: the corner taken off.
          def emit_corner_off_scroll(way)
            emit(ASM.sub_imm(ACC, ACC, corner(way)))
          end

          # ...and a painted screen's reference point in ACC, which counts in 256ths of a pixel.
          def emit_corner_off_reference(way)
            emit(ASM.sub_imm(ACC, ACC, corner(way) * FIXED_ONE))
          end

          # MOVE A SPRITE'S ROW BY THE CORNER, as it is copied into the console's table: the first half
          # of the row in ACC holds its row on the screen in its low eight bits, the second its column
          # in its low nine. Each is a count the table wraps round, so the corner is added to that
          # count alone and the bits above it, which set how the sprite is drawn, are kept. +scratch+
          # is a register free to use.
          def emit_row_moved_by_corner(scratch)
            emit(ASM.add_imm(scratch, ACC, @top))
            emit(ASM.and_imm(scratch, scratch, 0xFF))
            emit(ASM.bic_imm(ACC, ACC, 0xFF))
            emit(ASM.orr_reg(ACC, ACC, scratch))
          end

          def emit_column_moved_by_corner(scratch)
            emit(ASM.lsl_imm(scratch, ACC, 23))
            emit(ASM.add_imm(scratch, scratch, @left << 23))
            emit(ASM.lsr_imm(scratch, scratch, 23))
            emit(ASM.bic_imm(ACC, ACC, 0xFF))
            emit(ASM.bic_imm(ACC, ACC, 0x100))
            emit(ASM.orr_reg(ACC, ACC, scratch))
          end

          def corner(way) = way == :x ? @left : @top

          private

          # Inside the window: every layer, and the blend. Outside: the sprites alone, unblended.
          def emit_window
            write_reg16(REG_WIN0H, (@left << 8) | (@left + @inner[0]))
            write_reg16(REG_WIN0V, (@top << 8) | (@top + @inner[1]))
            write_reg16(REG_WININ, WIN_ALL_LAYERS | WIN_EFFECT)
            write_reg16(REG_WINOUT, WIN_OBJ)
          end

          # The painted screen upright and at its own size, with the picture's corner at the game's.
          def emit_painted_screen_corner
            write_reg16(REG_BG2PA, FIXED_ONE)
            write_reg16(REG_BG2PB, 0)
            write_reg16(REG_BG2PC, 0)
            write_reg16(REG_BG2PD, FIXED_ONE)
            store_word_immediate(-@left * FIXED_ONE, REG_BG2X)
            store_word_immediate(-@top * FIXED_ONE, REG_BG2Y)
          end

          def tiles_for_pieces = @pieces.sum(&:tiles)

          def picture_of(program)
            unless program.border
              return Graphics::Border.default(whole: @whole, inner: @inner)
            end

            width, height = program.border_size
            Graphics::Border.whole_picture(width: width, height: height, pixels: program.border, whole: @whole)
          end

          def in_border?(at)
            x = at % @whole[0]
            y = at / @whole[0]
            x < @left || x >= @left + @inner[0] || y < @top || y >= @top + @inner[1]
          end

          # The border as four rectangles, the bands above and below the whole width and the two sides
          # between them, each covered with sprites.
          def cover_border
            right = @left + @inner[0]
            bottom = @top + @inner[1]
            [[0, 0, @whole[0], @top], [0, bottom, @whole[0], @whole[1] - bottom],
             [0, @top, @left, @inner[1]], [right, @top, @whole[0] - right, @inner[1]]]
              .flat_map { |x, y, w, h| cover(x, y, w, h) }
          end

          # Sprites covering the rectangle exactly, biggest first: the biggest size that fits at its
          # corner, then the strip to its right and the rest below. Every side is whole tiles, and a
          # tile is a size of its own, so the rectangle is always covered.
          def cover(x, y, width, height)
            return [] if width <= 0 || height <= 0

            size = SHAPES.keys.select { |w, h| w <= width && h <= height }.max_by { |w, h| [w * h, w] }
            w, h = size
            [Piece.new(x: x, y: y, width: w, height: h), *cover(x + w, y, width - w, h),
             *cover(x, y + h, width, height - h)]
          end

          # Each piece's row of the sprite table: its place, its shape and size, its first tile, drawn
          # in front of every background (priority 0) from the border's group of colours.
          def rows_bytes
            tile = @first_tile
            rows = @pieces.map do |piece|
              shape, size = SHAPES.fetch([piece.width, piece.height])
              row = [(piece.y & 0xFF) | (shape << 14), (piece.x & 0x1FF) | (size << 14), tile | (COLOR_GROUP << 12), 0]
              tile += piece.tiles
              row
            end
            hidden = [SpriteDrawing::OBJ_HIDDEN_ATTR0, 0, 0, 0]
            (rows + Array.new(BORDER_ROWS - rows.size) { hidden }).flatten.pack("v*")
          end

          # Each piece's pictures, its tiles one after another row by row as the console reads a
          # sprite's (one-dimensional mapping), four bits a pixel, the left one of each pair low.
          def tiles_bytes
            @pieces.flat_map do |piece|
              (0...(piece.height / 8)).flat_map do |ty|
                (0...(piece.width / 8)).flat_map { |tx| tile_bytes(piece.x + (tx * 8), piece.y + (ty * 8)) }
              end
            end.pack("C*")
          end

          def tile_bytes(x, y)
            (0...8).flat_map do |row|
              (0...8).step(2).map do |col|
                low = @places.fetch(@pixels[((y + row) * @whole[0]) + x + col])
                high = @places.fetch(@pixels[((y + row) * @whole[0]) + x + col + 1])
                low | (high << 4)
              end
            end
          end
        end
      end
    end
  end
end
