# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # A TILED SCREEN, as a Genesis keeps one: two planes of tiles that scroll, and sprites over
          # them. Everything is in video RAM, which only the video chip's two ports reach, so the game
          # works on its own notes of what it wants (where each plane is scrolled to, which map each
          # shows, which cells changed, which sprites are placed) and the blank after each pass writes
          # them into the chip (rt_upload).
          #
          # VIDEO RAM, 64K, is laid out like this:
          #
          #   $0000        tile 0, which is blank: a cell of a map that names no tile shows nothing
          #   $0020-$B7FF  the game's tiles, one after another, backgrounds' and sprites' together
          #   $B800        the horizontal scroll table: the two planes' places, a word each
          #   $BC00        the sprite table, 80 rows of 8 bytes
          #   $C000        plane A's map, which draws over plane B's, and $E000 plane B's: 8K each,
          #                which holds the biggest map there is, 64 cells across and 64 down
          #
          # A MAP IS A GRID OF CELLS, a word each: the tile's number in the low eleven bits and its
          # palette in the two bits at 13. A plane is 32 or 64 cells across and down (the game's
          # backgrounds all have one size), and coming off one edge it comes round to the other, which is
          # what the interpreter's backgrounds do.
          #
          # THE SPRITE TABLE is a list the chip walks from row 0, each row naming the next by its
          # link, and it draws a row in front of the rows after it. A game places its sprites back to
          # front, so they are noted in that order and written to the table the other way round, the
          # last placed first, each linked to the one after, the last to nothing. A row draws a piece
          # of one to four tiles across and one to four down, from tiles that follow one another in
          # video memory down each column in turn; its size is in the byte above its link.
          #
          # A SCROLL REGISTER MOVES THE PLANE, not the view over it: a plane scrolled right by 5 shows
          # what was 5 pixels to the left. A game's view at x is the plane scrolled by -x. Vertically
          # it is the other way: the plane scrolled up by y shows what was y below.
          module Tiles
            PLANE_A_AT = 0xC000
            PLANE_B_AT = 0xE000
            SPRITES_AT = 0xBC00
            HSCROLL_AT = 0xB800
            TILES_AT = Art::TILE_BYTES

            MOST_SPRITES = Console::GENESIS.sprites
            # The cells the queue holds, each noted as the first word of the command that points the
            # chip at it (#cell_command), which has its plane in it, and its tile. A message box of
            # 30 by 8 cells opening in one pass fits, and the blank writes that many with time to
            # spare. A pass that changes more writes the queue early (#emit_queue_written_early).
            MOST_CELLS = 256
            CELL_BYTES = 4
            # A sprite piece's note, which is its row of the sprite table: how far down it is as the chip
            # counts (128 past the screen's corner), its size (Art::Piece#size_bits) and its link, the
            # tile and palette it is drawn with, and how far across it is.
            SPRITE_BYTES = 8
            # A sprite the reader of the running game is told of: whose, which picture, where.
            DRAWN = "rt drawn"
            DRAWN_BYTES = 8

            SCROLL = "rt scroll" # Each plane's left, then its top, a word each: plane A's, plane B's
            PENDING = "rt pending maps" # Each plane's grid still to be copied, a long each, or nought
            CELL_COUNT = "rt cell count"
            CELLS = "rt cells"
            SPRITE_COUNT = "rt sprite count"
            SPRITES = "rt sprites"

            # A set of colours a list holds, in the table Tint's rt_colors_hold reads: the palette's places, a word each.
            SET_BYTES = Art::OWN_COLORS * 2

            # How far past the screen's corner the chip counts a sprite's place from.
            SPRITE_ORIGIN = 128

            # In a game whose scenes each keep their own tiles (Art's +scene_tiles+): the table of the
            # arriving scene's tiles, still to be copied in the blank, or nought (rt_scene_tiles); and 1
            # while the screen is switched off for the copy.
            SCENE_TILES = "rt scene tiles"
            SCREEN_OFF_FOR_TILES = "rt screen off for tiles"

            # A scene's table of its own tiles (Lowering::Picture#scene_tile_sections): where they are on
            # the cartridge, how many long words, and where in video memory they go, a long each.
            SCENE_TILES_COUNT = 4
            SCENE_TILES_TO = 8

            module_function

            # +scene_tiles+ for a game whose scenes each bring their own tiles in as they take over.
            def reserve(memory, scene_tiles: false)
              memory.reserve(SCROLL, 8)
              memory.reserve(PENDING, 8)
              memory.reserve(CELL_COUNT, 2)
              memory.reserve(CELLS, MOST_CELLS * CELL_BYTES)
              memory.reserve(SPRITE_COUNT, 2)
              memory.reserve(SPRITES, MOST_SPRITES * SPRITE_BYTES)
              memory.reserve(DRAWN, 2 + (MOST_SPRITES * DRAWN_BYTES))
              return unless scene_tiles

              memory.reserve(SCENE_TILES, 4)
              memory.reserve(SCREEN_OFF_FOR_TILES, 2)
            end

            # +columns+ is how many cells across the planes are (32 or 64).
            # +colors+ for a game that changes its colours as it runs (Tint).
            # +scene_tiles+ for a game whose scenes each bring their own tiles in (#emit_scene_tiles).
            # +samples+ for a game that plays recordings (Picture#emit_dma_started).
            # +poses+ for a game with a sprite kept to one pose in video memory (Lowering::PoseRooms).
            # +blocks+ for a game that changes a block of cells in one step (#emit_block_noted).
            def emit(asm, memory, columns:, colors: false, scene_tiles: false, samples: false, runs: false, poses: false, blocks: false)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              emit_start(asm, colors: colors)
              emit_maps(asm, memory, at, columns, blocks: blocks)
              emit_sprites(asm, memory, at)
              emit_scene_tiles(asm, at) if scene_tiles
              emit_upload(asm, memory, at, columns, colors: colors, scene_tiles: scene_tiles, samples: samples, runs: runs,
                                                    poses: poses, blocks: blocks)
            end

            # A SCENE'S OWN TILES, brought in as it takes over. rt_scene_tiles(table) notes the table of
            # the arriving scene's tiles (D0), and the blank at the end of the pass copies them
            # (rt_scene_tiles_copied) over the last scene's, into the room past the tiles every screen shows.
            #
            # A scene's tiles are far more than the blank has time for: the blank is 38 lines, and the
            # video chip takes a few hundred tiles in that time even when it copies by itself. So the
            # screen is SWITCHED OFF for the copy, as the console's own games switch it off to load a
            # screen's art. With it off the video chip takes writes on any line, and the lines it draws
            # meanwhile show only the backdrop, never the new map over half-copied tiles or the old
            # scene's tiles under the new map. The maps, the cells and the sprites of the pass go in
            # after the tiles while it is still off, and it comes back on in the next blank
            # (#emit_upload), so the first frame drawn shows the whole of the new scene at once. The pass
            # takes the frames the copy took, which the frame count shows, as a slow pass's does.
            #
            # A scene that takes over before the screen first comes on finds it off already, and its tiles
            # go in with everything else copied then (Frame's rt_show_pass).
            def emit_scene_tiles(asm, at)
              h = Console::GenesisHardware
              asm.label("rt_scene_tiles")
              asm.move(:l, asm.d(0), at.call(SCENE_TILES))
              asm.rts

              asm.label("rt_scene_tiles_copied")
              asm.move(:l, at.call(SCENE_TILES), asm.d(0))
              asm.branch(:eq, "rt_scene_tiles_copied_done")
              asm.clr(:l, at.call(SCENE_TILES))
              asm.movea(:l, asm.d(0), asm.a(2))
              asm.tst(:l, asm.disp(2, SCENE_TILES_COUNT))
              asm.branch(:eq, "rt_scene_tiles_copied_done") # a scene with no tiles of its own
              asm.tst(:w, at.call(Frame::DISPLAY_ON))
              asm.branch(:eq, "rt_scene_tiles_copy")
              asm.move(:w, asm.imm(h::VDP_REGISTER | (h::REG_MODE2 << 8) | h::MODE2_SCREEN_OFF | h::MODE2_VBLANK_INTERRUPT | h::MODE2_DMA),
                       asm.abs_l(h::VDP_CONTROL))
              asm.move(:w, asm.imm(1), at.call(SCREEN_OFF_FOR_TILES))
              asm.label("rt_scene_tiles_copy")
              asm.move(:l, asm.disp(2, SCENE_TILES_TO), asm.d(0))
              asm.jsr(asm.abs_l("rt_vram_write_at"))
              asm.movea(:l, asm.ind(2), asm.a(0))
              asm.move(:l, asm.disp(2, SCENE_TILES_COUNT), asm.d(1))
              asm.subq(:l, 1, asm.d(1))
              asm.label("rt_scene_tiles_copy_long")
              asm.move(:l, asm.post(0), asm.abs_l(h::VDP_DATA))
              asm.dbra(asm.d(1), "rt_scene_tiles_copy_long")
              asm.label("rt_scene_tiles_copied_done")
              asm.rts
            end

            # rt_picture_start: the colours into the colour memory and the tiles into video RAM, with the
            # screen still off. The tiles are the long words of "art tiles", counted in "art tile bytes".
            def emit_start(asm, colors: false)
              h = Console::GenesisHardware
              asm.label("rt_picture_start")
              asm.move(:l, asm.imm(h.command(h::WRITE_CRAM, 0)), asm.abs_l(h::VDP_CONTROL))
              asm.lea(asm.abs_l("art colors"), asm.a(0))
              asm.move(:w, asm.imm(Art::PALETTES * Art::PLACES - 1), asm.d(1))
              asm.label("rt_picture_start_color")
              asm.move(:w, asm.post(0), asm.abs_l(h::VDP_DATA))
              asm.dbra(asm.d(1), "rt_picture_start_color")
              asm.jsr(asm.abs_l("rt_colors_start")) if colors
              asm.lea(asm.abs_l("art tile bytes"), asm.a(1))
              asm.move(:l, asm.ind(1), asm.d(1))
              asm.lsr(:l, 2, asm.d(1))
              asm.branch(:eq, "rt_picture_start_done")
              asm.subq(:l, 1, asm.d(1))
              asm.move(:l, asm.imm(h.command(h::WRITE_VRAM, TILES_AT)), asm.abs_l(h::VDP_CONTROL))
              asm.lea(asm.abs_l("art tiles"), asm.a(0))
              asm.label("rt_picture_start_tile")
              asm.move(:l, asm.post(0), asm.abs_l(h::VDP_DATA))
              asm.dbra(asm.d(1), "rt_picture_start_tile")
              asm.label("rt_picture_start_done")
              asm.rts

              asm.label("rt_picture_prepare")
              asm.rts
              asm.label("rt_tint_prepare")
              asm.jmp(asm.abs_l("rt_colors_prepared")) if colors
              asm.rts unless colors

              # rt_vram_write_at: the chip pointed at the video RAM address in D0, to be written. D1 is used.
              asm.label("rt_vram_write_at")
              asm.move(:l, asm.d(0), asm.d(1))
              asm.and(:l, asm.imm(0x3FFF), asm.d(1))
              asm.swap(asm.d(1))
              asm.lsr(:l, 8, asm.d(0))
              asm.lsr(:l, 6, asm.d(0))
              asm.or(:l, asm.d(0), asm.d(1))
              asm.or(:l, asm.imm(h::WRITE_VRAM), asm.d(1))
              asm.move(:l, asm.d(1), asm.abs_l(h::VDP_CONTROL))
              asm.rts
            end

            # THE MAPS. rt_background_put_up(plane, grid, reset): the grid (a place in "art grids":
            # where its cells are, how many across and how many down) is noted to be copied onto the plane
            # in the blank, and every cell the game changed on that plane before is let go, since the
            # map covers it; with +reset+ not nought the view goes back to the corner. rt_background_scroll
            # (plane, x, y): where the view of the plane is. rt_note_cell: one cell noted to change, the
            # queue written early when it is full. It takes the note as it is kept,
            # the command's first word in D1 and the cell's word in D3, and uses D4 and A0: where the
            # cell is was worked out by the game's line, which knows its plane and often its row
            # (Lowering::Picture#emit_cell_noted), so this is ten instructions.
            def emit_maps(asm, memory, at, columns, blocks: false)
              asm.label("rt_background_put_up")
              asm.lea(asm.abs_l("art grids"), asm.a(0))
              asm.lsl(:l, 3, asm.d(1))
              asm.add(:l, asm.d(1), asm.a(0))
              asm.lea(asm.abs_l(memory[PENDING]), asm.a(1))
              asm.move(:l, asm.d(0), asm.d(3))
              asm.lsl(:l, 2, asm.d(3))
              asm.move(:l, asm.a(0), asm.idx(1, 0, 3))
              emit_cells_of_plane_let_go(asm, memory, at, blocks: blocks)
              asm.tst(:l, asm.d(2))
              asm.branch(:eq, "rt_background_put_up_done")
              asm.lea(asm.abs_l(memory[SCROLL]), asm.a(1))
              asm.clr(:l, asm.idx(1, 0, 3))
              asm.label("rt_background_put_up_done")
              asm.rts

              asm.label("rt_background_scroll")
              asm.lea(asm.abs_l(memory[SCROLL]), asm.a(0))
              asm.lsl(:l, 2, asm.d(0))
              asm.move(:w, asm.d(1), asm.idx(0, 0, 0))
              asm.move(:w, asm.d(2), asm.idx(0, 2, 0))
              asm.rts

              asm.label("rt_note_cell")
              asm.move(:w, at.call(CELL_COUNT), asm.d(4))
              asm.cmp(:w, asm.imm(MOST_CELLS), asm.d(4))
              asm.branch(:cs, "rt_note_cell_room")
              emit_queue_written_early(asm)
              asm.label("rt_note_cell_room")
              asm.addq(:w, 1, at.call(CELL_COUNT))
              asm.add(:w, asm.d(4), asm.d(4)) # four bytes a note
              asm.add(:w, asm.d(4), asm.d(4))
              asm.lea(at.call(CELLS), asm.a(0))
              asm.move(:w, asm.d(1), asm.idx(0, 0, 4, :w))
              asm.move(:w, asm.d(3), asm.idx(0, 2, 4, :w))
              asm.rts

              emit_block_noted(asm, at, columns) if blocks
            end

            # A BLOCK OF CELLS IS THREE NOTES OF THE QUEUE (Nodes::SetTileBlock), written in the blank as
            # a console's own game writes a box: the chip pointed at the start of each row once, then
            # each cell of the row one word after another, the chip moving on by itself. The notes are:
            #
            #   the command's first word for the block's top left cell, with its top bit set (BLOCK_MARK),
            #     which no cell's has, since a cell's first word is a write to video memory
            #   how many cells across, then how many rows down
            #   how many bytes a row of the map is in the cartridge, or nought for a block of one cell
            #   the long word of where the block's top left cell is in the cartridge, or nought and the
            #     one cell's word
            #
            # rt_note_block: D0 and D1 the block's column and row, D2 and D3 how many across and down,
            # each as the game worked it out; D4 the cell's word for a block of one cell; A0 the
            # block's description in the cartridge (Lowering::Picture#emit_set_tile_block_of), BLOCK_BYTES:
            # the map's columns and rows, the command's first word for its plane's corner, and for a
            # block put back to the map, its bytes a row and where its cells are. The block is held
            # to the map first, as SetTile holds each cell, and one with no cells left notes nothing.
            # D0 to D4 and A0 are used.
            BLOCK_NOTES = 3
            BLOCK_MARK = 0x8000
            # Where a block's description keeps each of its words, in bytes from its start.
            BLOCK_COLUMNS_AT = 0
            BLOCK_ROWS_AT = 2
            BLOCK_COMMAND_AT = 4
            BLOCK_STRIDE_AT = 6
            BLOCK_SOURCE_AT = 8
            BLOCK_BYTES = 12

            def emit_block_noted(asm, at, columns)
              asm.label("rt_note_block")
              asm.movem_push(:l, :d4, :a1) # the cell's word is at 2(SP)
              [[0, 2, "rt_note_block_left"], [1, 3, "rt_note_block_top"]].each do |place, count, held|
                asm.tst(:l, asm.d(place)) # from before the map's edge: the cells before it left alone
                asm.branch(:pl, held)
                asm.add(:l, asm.d(place), asm.d(count))
                asm.moveq(0, asm.d(place))
                asm.label(held)
              end
              [[0, 2, BLOCK_COLUMNS_AT, "rt_note_block_right"], [1, 3, BLOCK_ROWS_AT, "rt_note_block_bottom"]].each do |place, count, limit, held|
                asm.moveq(0, asm.d(4)) # past the map's far edge: the cells past it left alone
                asm.move(:w, asm.disp(0, limit), asm.d(4))
                asm.sub(:l, asm.d(place), asm.d(4))
                asm.cmp(:l, asm.d(4), asm.d(count))
                asm.branch(:le, held)
                asm.move(:l, asm.d(4), asm.d(count))
                asm.label(held)
              end
              asm.tst(:l, asm.d(2))
              asm.branch(:le, "rt_note_block_done")
              asm.tst(:l, asm.d(3))
              asm.branch(:le, "rt_note_block_done")

              asm.moveq(0, asm.d(4))
              asm.move(:w, at.call(CELL_COUNT), asm.d(4))
              asm.cmp(:w, asm.imm(MOST_CELLS - BLOCK_NOTES + 1), asm.d(4))
              asm.branch(:cs, "rt_note_block_room")
              asm.move(:l, asm.a(0), asm.pre(M68000::SP))
              emit_queue_written_early(asm)
              asm.movea(:l, asm.post(M68000::SP), asm.a(0))
              asm.label("rt_note_block_room")
              asm.addq(:w, BLOCK_NOTES, at.call(CELL_COUNT))
              asm.lsl(:l, 2, asm.d(4)) # four bytes a note
              asm.lea(at.call(CELLS), asm.a(1))
              asm.add(:l, asm.d(4), asm.a(1))

              asm.move(:l, asm.d(1), asm.d(4))
              asm.lsl(:l, columns == 64 ? 6 : 5, asm.d(4))
              asm.add(:l, asm.d(0), asm.d(4))
              asm.add(:l, asm.d(4), asm.d(4)) # two bytes a cell
              asm.add(:w, asm.disp(0, BLOCK_COMMAND_AT), asm.d(4))
              asm.or(:w, asm.imm(BLOCK_MARK), asm.d(4))
              asm.move(:w, asm.d(4), asm.post(1))
              asm.move(:w, asm.d(2), asm.post(1))
              asm.move(:w, asm.d(3), asm.post(1))
              asm.move(:w, asm.disp(0, BLOCK_STRIDE_AT), asm.d(4))
              asm.move(:w, asm.d(4), asm.post(1))
              asm.branch(:eq, "rt_note_block_one_cell")
              asm.mulu(asm.d(1), asm.d(4)) # the block's first row in the cartridge
              asm.add(:l, asm.disp(0, BLOCK_SOURCE_AT), asm.d(4))
              asm.add(:l, asm.d(0), asm.d(4))
              asm.add(:l, asm.d(0), asm.d(4))
              asm.move(:l, asm.d(4), asm.post(1))
              asm.bra("rt_note_block_done")
              asm.label("rt_note_block_one_cell")
              asm.clr(:w, asm.post(1))
              asm.move(:w, asm.disp(M68000::SP, 2), asm.post(1))
              asm.label("rt_note_block_done")
              asm.movem_pop(:l, :d4, :a1)
              asm.rts
            end

            # A FULL QUEUE IS WRITTEN EARLY, and the cell that found it full is noted after, in a queue
            # empty again. Everything noted before it reaches video memory before it does, so the
            # order the game changed its cells in holds: the maps waiting to go up first, as the blank
            # puts them (a cell changed after a put-up lands on the new map), then the cells.
            #
            # The video chip takes writes while it draws, so this is safe on any line; what it costs is
            # that a frame drawn meanwhile can show part of the pass's change, as on the Advance. The
            # registers the game's line keeps are put back, and D1 and D3, the note, with them.
            def emit_queue_written_early(asm)
              kept = %i[d0 d1 d2 d3 d5 d6 d7 a1 a2 a3]
              asm.movem_push(:l, *kept)
              asm.jsr(asm.abs_l("rt_maps_and_cells_written"))
              asm.movem_pop(:l, *kept)
              asm.moveq(0, asm.d(4))
            end

            # THE COMMAND THAT POINTS THE CHIP AT A CELL is two words: the first holds the low fourteen
            # bits of the cell's address in video memory, and the second its top two, which are the same
            # for every cell of both maps. So a cell is noted with its first word worked out
            # (Lowering::Picture#emit_cell_command_word), and the blank writes that word, then this
            # command's second, then the cell.
            def cell_command
              h = Console::GenesisHardware
              h.command(h::WRITE_VRAM, PLANE_A_AT)
            end

            # The cells noted for plane D0 taken out of the queue, the rest kept in their order. A note
            # names its plane in its command word: plane B's map is 8K past plane A's, which is bit 13
            # of a cell's place, turned round here into bit 0. A block's notes go or stay together.
            # D1 is used.
            def emit_cells_of_plane_let_go(asm, memory, at, blocks: false)
              asm.move(:w, at.call(CELL_COUNT), asm.d(4))
              asm.branch(:eq, "rt_cells_let_go_done")
              asm.lea(asm.abs_l(memory[CELLS]), asm.a(1))
              asm.movea(:l, asm.a(1), asm.a(2))
              asm.moveq(0, asm.d(5)) # how many are kept
              asm.subq(:w, 1, asm.d(4))
              asm.label("rt_cells_let_go_cell")
              asm.move(:w, asm.post(1), asm.d(6))
              asm.move(:w, asm.post(1), asm.d(7))
              asm.move(:w, asm.d(6), asm.d(1))
              asm.rol(:w, 3, asm.d(1))
              asm.and(:w, asm.imm(1), asm.d(1))
              asm.cmp(:w, asm.d(0), asm.d(1))
              asm.branch(:eq, blocks ? "rt_cells_let_go_dropped" : "rt_cells_let_go_next")
              asm.move(:w, asm.d(6), asm.post(2))
              asm.move(:w, asm.d(7), asm.post(2))
              asm.addq(:w, 1, asm.d(5))
              if blocks
                asm.tst(:w, asm.d(6))
                asm.branch(:pl, "rt_cells_let_go_next")
                2.times { asm.move(:l, asm.post(1), asm.post(2)) } # a block's last two notes, kept with it
                asm.addq(:w, BLOCK_NOTES - 1, asm.d(5))
                asm.subq(:w, BLOCK_NOTES - 1, asm.d(4))
                asm.bra("rt_cells_let_go_next")
                asm.label("rt_cells_let_go_dropped")
                asm.tst(:w, asm.d(6))
                asm.branch(:pl, "rt_cells_let_go_next")
                asm.addq(:l, (BLOCK_NOTES - 1) * CELL_BYTES, asm.a(1)) # a block's last two notes, let go with it
                asm.subq(:w, BLOCK_NOTES - 1, asm.d(4))
              end
              asm.label("rt_cells_let_go_next")
              asm.dbra(asm.d(4), "rt_cells_let_go_cell")
              asm.move(:w, asm.d(5), at.call(CELL_COUNT))
              asm.label("rt_cells_let_go_done")
            end

            # SPRITES, PLACED IN ONE WALK. A pass places its sprites one after another, back to front,
            # with nothing else between them, so where the walk has got to stays in registers from
            # rt_sprites_begin to rt_sprites_end, as a console's own games keep it while they walk
            # their objects:
            #
            #   A2  where the next row of the sprite table is noted, which is just under the last one
            #   A3  where the next sprite's row for a reader goes (DRAWN)
            #   D4  the link the next row takes, which is also how many rows the table has left
            #
            # rt_sprites_begin forgets the sprites of the last pass and starts the walk, and
            # rt_sprites_end writes down how many rows and how many sprites it came to. Between them
            # the lowering only loads a sprite's numbers and calls (Lowering::Picture#emit_sprite_placing).
            #
            # rt_sprite_place places one sprite: A0 is its table of pictures (how many, then where each
            # picture's pieces are, a long each: #picture_words), D1 which of them it shows — none for a
            # number outside the table — D2 and D3 its place, and D0 the sprite's number for a reader
            # (SpriteNames). Each piece of the picture is a row of the table, at the sprite's place plus
            # the piece's own; a piece wholly off the screen is not written, and nor is any piece once
            # the table's 80 rows are used.
            #
            # A sprite DRAWN IN A LIST OF COLOURS (`draw_with`) is placed by rt_sprite_place_recolored,
            # which takes two numbers more: D6 is a table of how many lists it can be drawn with and the
            # palette of each, in the bits of a piece's word that name it, and D5 is the one the game
            # names now. Every piece is then drawn from that palette, and a D5 the table has no list for
            # draws it from the palette its own picture names.
            #
            # A READER'S ROW is four words: whose, which picture, where. A game has a row of it for
            # every sprite that can be up together, which the build holds to the table's 80
            # (Console::Description#sprite_places, Checks::TooManySprites): only a sprite that shows is
            # placed, and two scenes never up together count apart. So the walk never counts them.
            def emit_sprites(asm, memory, at)
              asm.label("rt_sprites_begin")
              asm.clr(:w, at.call(SPRITE_COUNT))
              asm.clr(:w, at.call(DRAWN))
              asm.lea(asm.abs_l(memory[SPRITES] + (MOST_SPRITES * SPRITE_BYTES)), asm.a(2))
              asm.lea(asm.abs_l(memory[DRAWN], 2), asm.a(3))
              asm.moveq(MOST_SPRITES, asm.d(4))
              asm.rts

              asm.label("rt_sprites_end")
              asm.moveq(MOST_SPRITES, asm.d(0))
              asm.sub(:w, asm.d(4), asm.d(0))
              asm.move(:w, asm.d(0), at.call(SPRITE_COUNT))
              asm.move(:l, asm.a(3), asm.d(0))
              asm.sub(:l, asm.imm(memory[DRAWN] + 2), asm.d(0))
              asm.lsr(:w, 3, asm.d(0))
              asm.move(:w, asm.d(0), at.call(DRAWN))
              asm.rts

              emit_sprite_placed(asm, recolored: false)
              emit_sprite_placed(asm, recolored: true)
              emit_pieces_tested(asm)
            end

            # A piece's word with the two bits that name its palette cleared, for a sprite drawn in a list.
            PALETTE_CLEARED = 0x9FFF

            # A PICTURE'S PIECES, as rt_sprite_place reads them: the picture's number for a reader, how
            # many pieces less one, the box they all lie in, then each piece as the row of the sprite
            # table it becomes, last long word first.
            #
            # The box is what lets a sprite standing wholly on the screen skip every test a piece
            # otherwise takes: its left edge from the sprite's place and how many places across the
            # screen keep the whole box on it, then the same for its top. A picture wider or taller
            # than the screen has no such place, and has nought there.
            #
            # A piece is its tile and palette, its left as the chip counts it from the sprite's place
            # (SPRITE_ORIGIN more), its top, and its size in the high byte with the link's byte empty.
            # +tiles_from+ is the tile in video memory the pictures' tile 0 is (Lowering::Picture#sprite_tiles_from).
            def picture_words(number, pieces, tiles_from)
              return [number, -1, 0, 0, 0, 0] if pieces.empty?

              left = pieces.map(&:dx).min
              top = pieces.map(&:dy).min
              across = pieces.map { |piece| piece.dx + (piece.columns * 8) }.max - left
              down = pieces.map { |piece| piece.dy + (piece.rows * 8) }.max - top
              [number, pieces.length - 1, left, [Paint::WIDTH - across + 1, 0].max, top, [Paint::HEIGHT - down + 1, 0].max] +
                pieces.flat_map do |piece|
                  [(piece.tile + tiles_from) | (piece.palette << Art::PALETTE_SHIFT), piece.dx + SPRITE_ORIGIN,
                   piece.dy + SPRITE_ORIGIN, piece.size_bits << 8]
                end
            end

            # Where a piece keeps each of its words (#picture_words).
            PIECE_LEFT = 2
            PIECE_TOP = 4
            PIECE_SIZE = 6
            PIECE_WORDS_BYTES = 8

            # rt_sprite_place, or rt_sprite_place_recolored: the sprite's picture found, its row for a
            # reader written, and, where it stands wholly on the screen, its pieces copied into the
            # table's notes with its place added, as a console's own games copy a frame's pieces: two
            # long words read, each added to, two written. Nothing of such a sprite is off the screen,
            # so no piece is tested, and the rows are known to be there before the first is written.
            #
            # A sprite any part of whose box is off the screen, or whose pieces the table has not rows
            # enough for, goes on to the loop that tests each piece (#emit_pieces_tested).
            #
            # THE NOTES ARE THE TABLE'S OWN ROWS, kept from the end of their room backwards: the piece
            # noted first, which is drawn behind the rest, is the table's last row, and each row links to
            # the row after it, the one noted before. So a row's link is known as it is noted, 80 less
            # how many are noted already, and the blank copies the rows as they stand
            # (#emit_sprite_table_written).
            #
            # A row's first long word is its top, then its size and its link in a byte each. The sprite's
            # top goes in the high half of D3 and the link in the low half, so one add puts both in: the
            # piece's size has an empty byte under it, which a link of 80 or less never carries out of.
            def emit_sprite_placed(asm, recolored:)
              name = recolored ? "rt_sprite_place_recolored" : "rt_sprite_place"
              asm.label(name)
              emit_palette_chosen(asm) if recolored
              asm.cmp(:l, asm.post(0), asm.d(1))
              asm.branch_near(:cc, "#{name}_done")
              asm.add(:w, asm.d(1), asm.d(1))
              asm.add(:w, asm.d(1), asm.d(1))
              asm.movea(:l, asm.idx(0, 0, 1, :w), asm.a(0)) # the picture
              asm.move(:w, asm.d(0), asm.post(3)) # the reader's row: whose
              asm.move(:w, asm.post(0), asm.post(3)) # which picture
              asm.move(:w, asm.d(2), asm.post(3))
              asm.move(:w, asm.d(3), asm.post(3)) # and where
              asm.move(:w, asm.post(0), asm.d(5)) # its pieces, less one
              asm.branch_near(:mi, "#{name}_done")
              asm.movea(:w, asm.post(0), asm.a(1)) # the box's left from the sprite's place
              asm.add(:l, asm.d(2), asm.a(1))
              asm.cmp(:w, asm.post(0), asm.a(1))
              asm.branch_near(:cc, "#{name}_off_across")
              asm.movea(:w, asm.post(0), asm.a(1)) # and its top
              asm.add(:l, asm.d(3), asm.a(1))
              asm.cmp(:w, asm.post(0), asm.a(1))
              asm.branch_near(:cc, "#{name}_off")
              asm.cmp(:w, asm.d(5), asm.d(4))
              asm.branch_near(:ls, "#{name}_off") # fewer rows left than pieces
              asm.swap(asm.d(3))
              asm.move(:w, asm.d(4), asm.d(3))
              emit_palette_masks(asm, name) if recolored
              asm.label("#{name}_piece")
              if recolored
                asm.move(:w, asm.post(0), asm.d(0))
                asm.and(:w, asm.d(6), asm.d(0))
                asm.or(:w, asm.d(7), asm.d(0))
                asm.swap(asm.d(0))
                asm.move(:w, asm.post(0), asm.d(0))
              else
                asm.move(:l, asm.post(0), asm.d(0))
              end
              asm.add(:w, asm.d(2), asm.d(0))
              asm.move(:l, asm.d(0), asm.pre(2)) # its tile and palette, and across
              asm.move(:l, asm.post(0), asm.d(0))
              asm.add(:l, asm.d(3), asm.d(0))
              asm.move(:l, asm.d(0), asm.pre(2)) # up and down, its size, and its link
              asm.subq(:w, 1, asm.d(3))
              asm.dbra(asm.d(5), "#{name}_piece")
              asm.move(:w, asm.d(3), asm.d(4))
              asm.label("#{name}_done")
              asm.rts
              asm.label("#{name}_off_across")
              asm.addq(:l, 4, asm.a(0)) # past the box's top
              asm.label("#{name}_off")
              return if recolored # the loop that tests each piece is next (#emit_sprites)

              asm.moveq(-1, asm.d(0))
              asm.movea(:l, asm.d(0), asm.a(4)) # every piece from the palette its picture names
              asm.bra("rt_sprite_place_tested")
            end

            # A4: the palette the sprite is drawn from, as the bits of a piece's word that name it, or -1 for the
            # one its picture names. D5 is the list the game names (negative or past the table's: none), D6 the table.
            def emit_palette_chosen(asm)
              asm.moveq(-1, asm.d(7))
              asm.movea(:l, asm.d(7), asm.a(4))
              asm.movea(:l, asm.d(6), asm.a(1))
              asm.moveq(0, asm.d(6))
              asm.move(:w, asm.post(1), asm.d(6))
              asm.cmp(:l, asm.d(6), asm.d(5))
              asm.branch(:cc, "rt_sprite_place_chosen")
              asm.lsl(:l, 1, asm.d(5))
              asm.moveq(0, asm.d(7))
              asm.move(:w, asm.idx(1, 0, 5), asm.d(7))
              asm.movea(:l, asm.d(7), asm.a(4))
              asm.label("rt_sprite_place_chosen")
            end

            # D6 and D7 from A4 (#emit_palette_chosen): the bits of a piece's word that are kept, and the
            # palette put in.
            def emit_palette_masks(asm, name)
              asm.moveq(-1, asm.d(6))
              asm.moveq(0, asm.d(7))
              asm.move(:l, asm.a(4), asm.d(0))
              asm.branch(:mi, "#{name}_piece")
              asm.move(:w, asm.imm(PALETTE_CLEARED), asm.d(6))
              asm.move(:w, asm.d(0), asm.d(7))
            end

            # rt_sprite_place_tested: THE PIECES OF A SPRITE THAT IS NOT WHOLLY ON THE SCREEN, each
            # tested by itself and noted if any of it shows and the table has a row for it. A0 is at
            # the first of them (#picture_words), D5 is how many less one, D2 and D3 the sprite's place,
            # and A4 its palette (#emit_palette_chosen).
            def emit_pieces_tested(asm)
              asm.label("rt_sprite_place_tested")
              asm.move(:w, asm.disp(0, PIECE_LEFT), asm.d(7))
              asm.ext(:l, asm.d(7))
              asm.add(:l, asm.d(2), asm.d(7)) # the piece's left, as the chip counts it
              asm.move(:w, asm.disp(0, PIECE_TOP), asm.d(1))
              asm.ext(:l, asm.d(1))
              asm.add(:l, asm.d(3), asm.d(1)) # its top
              asm.moveq(0, asm.d(6))
              asm.move(:w, asm.disp(0, PIECE_SIZE), asm.d(6))
              asm.lsr(:w, 8, asm.d(6)) # its size
              emit_piece_side(asm, 2) # its width, in pixels
              asm.add(:l, asm.d(7), asm.d(0))
              asm.cmp(:l, asm.imm(SPRITE_ORIGIN), asm.d(0))
              asm.branch(:le, "rt_sprite_place_skip") # its right edge at or past the screen's left
              asm.cmp(:l, asm.imm(Paint::WIDTH + SPRITE_ORIGIN), asm.d(7))
              asm.branch(:ge, "rt_sprite_place_skip")
              emit_piece_side(asm, 0) # its height
              asm.add(:l, asm.d(1), asm.d(0))
              asm.cmp(:l, asm.imm(SPRITE_ORIGIN), asm.d(0))
              asm.branch(:le, "rt_sprite_place_skip")
              asm.cmp(:l, asm.imm(Paint::HEIGHT + SPRITE_ORIGIN), asm.d(1))
              asm.branch(:ge, "rt_sprite_place_skip")
              asm.tst(:w, asm.d(4))
              asm.branch(:eq, "rt_sprite_place_full")
              asm.move(:w, asm.d(7), asm.pre(2))
              asm.move(:w, asm.ind(0), asm.d(0)) # its tile and palette
              asm.move(:l, asm.a(4), asm.d(7))
              asm.branch(:mi, "rt_sprite_place_own_palette")
              asm.and(:w, asm.imm(PALETTE_CLEARED), asm.d(0))
              asm.or(:w, asm.d(7), asm.d(0))
              asm.label("rt_sprite_place_own_palette")
              asm.move(:w, asm.d(0), asm.pre(2))
              asm.lsl(:w, 8, asm.d(6))
              asm.or(:w, asm.d(4), asm.d(6)) # the row's link
              asm.move(:w, asm.d(6), asm.pre(2))
              asm.move(:w, asm.d(1), asm.pre(2))
              asm.subq(:w, 1, asm.d(4))
              asm.label("rt_sprite_place_skip")
              asm.addq(:l, PIECE_WORDS_BYTES, asm.a(0))
              asm.dbra(asm.d(5), "rt_sprite_place_tested")
              asm.label("rt_sprite_place_full")
              asm.rts
            end

            # D0: one side of the piece whose size is in D6, in pixels — across from the two bits at
            # +shift+ 2, down from the two at 0, each a count of tiles less one.
            def emit_piece_side(asm, shift)
              asm.moveq(3, asm.d(0))
              if shift.zero?
                asm.and(:l, asm.d(6), asm.d(0))
              else
                asm.move(:l, asm.d(6), asm.d(0))
                asm.lsr(:l, shift, asm.d(0))
              end
              asm.addq(:l, 1, asm.d(0))
              asm.lsl(:l, 3, asm.d(0))
            end

            # rt_upload (and rt_upload_whole, which is the same, the screen being off): the colours, the
            # sprite table and the scroll, then the maps noted copied onto their planes and the cells
            # changed after them. The maps are last, being the longest: a whole map's copy runs past the
            # end of the blank (#emit_plane_map_copied), and what is written after it would be on the
            # screen a frame late.
            #
            # In a game whose scenes each bring their own tiles in, an arriving scene's go first, with the
            # screen switched off (#emit_scene_tiles), and the screen comes back on in the blank after
            # everything else is in.
            #
            # A sprite kept to one pose in video memory has the pose it changed to copied in before the
            # sprite table that shows it (Lowering::PoseRooms#pose_rooms_section), so the frame that first
            # shows the pose draws it from its own tiles. The copy is the video chip's, from the cartridge,
            # and the rooms together are held to what it moves in the blank (Lowering::PoseRooms::MOST_TILES).
            def emit_upload(asm, memory, at, columns, colors: false, scene_tiles: false, samples: false, runs: false, poses: false,
                            blocks: false)
              asm.label("rt_upload")
              asm.label("rt_upload_whole")
              asm.jsr(asm.abs_l("rt_scene_tiles_copied")) if scene_tiles
              asm.jsr(asm.abs_l("art runs uploaded")) if runs # Lowering::TileRuns#tile_runs_section, after a scene's own tiles
              asm.jsr(asm.abs_l("rt_colors_written")) if colors
              asm.jsr(asm.abs_l("art poses sent")) if poses
              emit_sprite_table_written(asm, memory, at)
              emit_scroll_written(asm, memory)
              asm.jsr(asm.abs_l("rt_maps_and_cells_written"))
              emit_screen_back_on(asm, at) if scene_tiles
              asm.rts

              # The maps noted and the cells changed after them, the part of the blank a full queue
              # of cells also writes (#emit_queue_written_early). D0 to D7 and A0 to A3 are used.
              asm.label("rt_maps_and_cells_written")
              [0, 1].each do |plane|
                asm.moveq(plane, asm.d(0))
                asm.jsr(asm.abs_l("rt_plane_map_copied"))
              end
              emit_cells_written(asm, memory, at, columns, blocks: blocks)
              asm.rts
              emit_plane_map_copied(asm, memory, columns)
              emit_vram_run_copied(asm, samples: samples)
            end

            # The screen, switched off for a scene's tiles, on again in the next blank.
            def emit_screen_back_on(asm, at)
              asm.tst(:w, at.call(SCREEN_OFF_FOR_TILES))
              asm.branch(:eq, "rt_upload_screen_was_on")
              asm.clr(:w, at.call(SCREEN_OFF_FOR_TILES))
              asm.jsr(asm.abs_l("rt_sleep_until_vblank"))
              asm.jsr(asm.abs_l("rt_screen_on"))
              asm.label("rt_upload_screen_was_on")
            end

            # THE GRID NOTED FOR PLANE +plane+, if any, COPIED ONTO IT BY THE VIDEO CHIP (DMA), straight
            # from the cartridge. A map of 64 by 64 cells is 8K, and the processor handing the chip a
            # word at a time (two instructions a cell, a move and a loop) takes a whole frame over it,
            # most of it while the screen is drawn, so the scene it brings arrives a frame late and the
            # music waits for it. The chip copies by itself about 200 bytes a line of the blank, which is
            # how the console's own games send a screen's map; that is nearly all of an 8K map in the
            # blank, and what is left goes in at the top of the next frame, the processor stopped meanwhile.
            #
            # SO THE ROWS THE VIEW SHOWS GO FIRST. The copy starts at the row of the plane at the top of
            # the view (where the pass left its scroll), runs to the grid's last row and comes round to
            # its first: the rows still going in as the frame starts are the ones just above the view,
            # which it does not show.
            #
            # A grid as wide as the plane is one run in the cartridge and on the plane, so it goes in two
            # copies, from the view's row to the end and from the first row to the view's; a narrower one
            # goes a row at a copy, each from the start of a row of the plane.
            #
            # rt_plane_map_copied: D0 is the plane, 0 for A and 1 for B, a long. Plane B's map is 8K past
            # plane A's, its notes four bytes past A's. D0 to D7, A0 to A3 are used.
            def emit_plane_map_copied(asm, memory, columns)
              shift = columns == 64 ? 6 : 5
              done = "rt_plane_map_done"
              asm.label("rt_plane_map_copied")
              asm.lea(asm.abs_l(memory[PENDING]), asm.a(2))
              asm.move(:l, asm.d(0), asm.d(4))
              asm.lsl(:l, 2, asm.d(4)) # the plane's notes, four bytes a plane
              asm.move(:l, asm.idx(2, 0, 4, :w), asm.d(1))
              asm.branch(:eq, done)
              asm.clr(:l, asm.idx(2, 0, 4, :w))
              asm.movea(:l, asm.d(1), asm.a(2))
              asm.movea(:l, asm.post(2), asm.a(1)) # the grid's cells
              asm.moveq(0, asm.d(6))
              asm.move(:w, asm.post(2), asm.d(6)) # cells across
              asm.moveq(0, asm.d(7))
              asm.move(:w, asm.ind(2), asm.d(7)) # rows
              asm.branch(:eq, done)
              asm.ror(:w, 3, asm.d(0)) # plane B: $2000
              asm.add(:l, asm.imm(PLANE_A_AT), asm.d(0))
              asm.movea(:l, asm.d(0), asm.a(2)) # the plane's map in video RAM
              asm.lea(asm.abs_l(memory[SCROLL], 2), asm.a(0))
              asm.move(:w, asm.idx(0, 0, 4, :w), asm.d(4)) # the view's top, from which the row it is on
              asm.lsr(:w, 3, asm.d(4))
              asm.and(:w, asm.imm(columns - 1), asm.d(4))
              asm.cmp(:w, asm.d(7), asm.d(4))
              asm.branch(:cs, "rt_plane_map_from")
              asm.moveq(0, asm.d(4)) # a view below the grid: from its first row
              asm.label("rt_plane_map_from")
              asm.move(:w, asm.d(7), asm.d(5)) # the rows still to copy
              asm.label("rt_plane_map_run")
              asm.moveq(1, asm.d(1)) # the rows in this copy: one, or to the end of a grid as wide as the plane
              asm.cmp(:w, asm.imm(columns), asm.d(6))
              asm.branch(:ne, "rt_plane_map_rows")
              asm.move(:w, asm.d(7), asm.d(1))
              asm.sub(:w, asm.d(4), asm.d(1))
              asm.label("rt_plane_map_rows")
              asm.sub(:w, asm.d(1), asm.d(5))
              asm.move(:w, asm.d(4), asm.d(0)) # from the row's cells in the cartridge
              asm.mulu(asm.d(6), asm.d(0))
              asm.add(:l, asm.d(0), asm.d(0))
              asm.movea(:l, asm.a(1), asm.a(0))
              asm.add(:l, asm.d(0), asm.a(0))
              asm.move(:l, asm.d(4), asm.d(0)) # to the start of its row of the plane
              asm.lsl(:l, shift + 1, asm.d(0))
              asm.add(:l, asm.a(2), asm.d(0))
              asm.add(:w, asm.d(1), asm.d(4)) # the next row, round to the first past the last
              asm.cmp(:w, asm.d(7), asm.d(4))
              asm.branch(:cs, "rt_plane_map_next")
              asm.moveq(0, asm.d(4))
              asm.label("rt_plane_map_next")
              asm.mulu(asm.d(6), asm.d(1)) # words
              asm.jsr(asm.abs_l("rt_vram_run_copied"))
              asm.tst(:w, asm.d(5))
              asm.branch(:ne, "rt_plane_map_run")
              asm.label(done)
              asm.rts
            end

            # rt_vram_run_copied: D1 words (one or more) from A0 on the cartridge copied by the chip to D0 in
            # video RAM. The chip counts its source within one 128K block, coming round to the block's
            # start past its end, so a run that crosses into the next block goes as two copies. D0 to
            # D3, A0 and A3 are used.
            def emit_vram_run_copied(asm, samples: false)
              asm.label("rt_vram_run_copied")
              asm.move(:l, asm.a(0), asm.d(2))
              asm.and(:l, asm.imm(0x1FFFF), asm.d(2))
              asm.neg(:l, asm.d(2))
              asm.add(:l, asm.imm(0x20000), asm.d(2))
              asm.lsr(:l, 1, asm.d(2)) # words to the end of the block
              asm.cmp(:l, asm.d(1), asm.d(2))
              asm.branch(:cc, "rt_vram_copy") # all of it in this block
              asm.movem_push(:l, :d0, :d1, :d2, :a0)
              asm.move(:l, asm.d(2), asm.d(1))
              asm.bsr("rt_vram_copy")
              asm.movem_pop(:l, :d0, :d1, :d2, :a0)
              asm.sub(:l, asm.d(2), asm.d(1))
              asm.add(:l, asm.d(2), asm.d(2)) # bytes
              asm.add(:l, asm.d(2), asm.d(0))
              asm.add(:l, asm.d(2), asm.a(0))
              emit_vram_copy(asm, samples: samples)
            end

            # rt_vram_copy: one copy by the chip, D1 words from A0 to D0 in video RAM, inside one 128K
            # block. The length and the source (halved, since the chip counts words) go into five registers
            # a byte each; the top two bits of the last are nought, a copy from the 68000's memory, the
            # cartridge or work RAM. D0, D2, D3 and A3 are used; D1 and A0 are kept.
            def emit_vram_copy(asm, samples: false)
              h = Console::GenesisHardware
              register = ->(number) { h::VDP_REGISTER | (number << 8) }
              asm.label("rt_vram_copy")
              asm.lea(asm.abs_l(h::VDP_CONTROL), asm.a(3))
              asm.move(:w, asm.imm(register.call(h::REG_DMA_LENGTH_LOW)), asm.d(2))
              asm.move(:b, asm.d(1), asm.d(2))
              asm.move(:w, asm.d(2), asm.ind(3))
              asm.move(:w, asm.d(1), asm.d(2))
              asm.lsr(:w, 8, asm.d(2))
              asm.or(:w, asm.imm(register.call(h::REG_DMA_LENGTH_HIGH)), asm.d(2))
              asm.move(:w, asm.d(2), asm.ind(3))
              asm.move(:l, asm.a(0), asm.d(3))
              asm.lsr(:l, 1, asm.d(3))
              asm.move(:w, asm.imm(register.call(h::REG_DMA_SOURCE_LOW)), asm.d(2))
              asm.move(:b, asm.d(3), asm.d(2))
              asm.move(:w, asm.d(2), asm.ind(3))
              asm.lsr(:l, 8, asm.d(3))
              asm.move(:w, asm.imm(register.call(h::REG_DMA_SOURCE_MIDDLE)), asm.d(2))
              asm.move(:b, asm.d(3), asm.d(2))
              asm.move(:w, asm.d(2), asm.ind(3))
              asm.lsr(:l, 8, asm.d(3))
              asm.and(:w, asm.imm(0x7F), asm.d(3))
              asm.or(:w, asm.imm(register.call(h::REG_DMA_SOURCE_HIGH)), asm.d(3))
              asm.move(:w, asm.d(3), asm.ind(3))
              # The command (Hardware.command) for D0, with the copy's bit.
              asm.move(:l, asm.d(0), asm.d(2))
              asm.lsr(:l, 8, asm.d(2))
              asm.lsr(:l, 6, asm.d(2))
              asm.and(:l, asm.imm(0x3FFF), asm.d(0))
              asm.swap(asm.d(0))
              asm.or(:l, asm.d(2), asm.d(0))
              asm.or(:l, asm.imm(h::WRITE_VRAM | h::COMMAND_DMA), asm.d(0))
              Picture.emit_dma_started(asm, asm.d(0), asm.ind(3), samples: samples)
              asm.rts
            end

            # The cells noted written one at a time, each with its place in the plane it is on, and
            # each block a row at a time (#emit_block_noted). +columns+ is how many cells across the
            # planes are, so how far the chip's address moves from one row to the next.
            def emit_cells_written(asm, memory, at, columns, blocks: false)
              h = Console::GenesisHardware
              asm.move(:w, at.call(CELL_COUNT), asm.d(7))
              asm.branch(:eq, "rt_upload_cells_done")
              asm.clr(:w, at.call(CELL_COUNT))
              asm.lea(asm.abs_l(memory[CELLS]), asm.a(1))
              asm.lea(asm.abs_l(h::VDP_CONTROL), asm.a(3))
              asm.lea(asm.abs_l(h::VDP_DATA), asm.a(2))
              asm.move(:w, asm.imm(cell_command & 0xFFFF), asm.d(0))
              asm.subq(:w, 1, asm.d(7))
              asm.label("rt_upload_cell")
              if blocks
                asm.move(:w, asm.post(1), asm.d(1))
                asm.branch(:mi, "rt_upload_block")
                asm.move(:w, asm.d(1), asm.ind(3))
              else
                asm.move(:w, asm.post(1), asm.ind(3))
              end
              asm.move(:w, asm.d(0), asm.ind(3))
              asm.move(:w, asm.post(1), asm.ind(2))
              asm.label("rt_upload_cell_next") if blocks
              asm.dbra(asm.d(7), "rt_upload_cell")
              if blocks
                asm.bra("rt_upload_cells_done")
                emit_block_written(asm, columns)
              end
              asm.label("rt_upload_cells_done")
            end

            # One block's notes (#emit_block_noted) written, D1 its first word. D1 to D6 and A0 are used.
            def emit_block_written(asm, columns)
              row_bytes = columns * 2
              asm.label("rt_upload_block")
              asm.and(:w, asm.imm(~BLOCK_MARK & 0xFFFF), asm.d(1))
              asm.move(:w, asm.post(1), asm.d(2))
              asm.subq(:w, 1, asm.d(2)) # across, counted down to nought
              asm.move(:w, asm.post(1), asm.d(3))
              asm.subq(:w, 1, asm.d(3)) # down, the same
              asm.moveq(0, asm.d(4))
              asm.move(:w, asm.post(1), asm.d(4)) # bytes a row of the map in the cartridge
              asm.move(:l, asm.post(1), asm.d(5)) # where its cells are, or the one cell's word
              asm.subq(:w, BLOCK_NOTES - 1, asm.d(7))
              asm.tst(:w, asm.d(4))
              asm.branch(:ne, "rt_upload_block_copied")

              asm.label("rt_upload_block_row")
              asm.move(:w, asm.d(1), asm.ind(3))
              asm.move(:w, asm.d(0), asm.ind(3))
              asm.move(:w, asm.d(2), asm.d(6))
              asm.label("rt_upload_block_cell")
              asm.move(:w, asm.d(5), asm.ind(2))
              asm.dbra(asm.d(6), "rt_upload_block_cell")
              asm.add(:w, asm.imm(row_bytes), asm.d(1))
              asm.dbra(asm.d(3), "rt_upload_block_row")
              asm.bra("rt_upload_cell_next")

              # Put back from the map in the cartridge: each row's cells, then on to the next row's.
              asm.label("rt_upload_block_copied")
              asm.movea(:l, asm.d(5), asm.a(0))
              asm.moveq(0, asm.d(6))
              asm.move(:w, asm.d(2), asm.d(6))
              asm.addq(:w, 1, asm.d(6))
              asm.add(:w, asm.d(6), asm.d(6))
              asm.sub(:l, asm.d(6), asm.d(4)) # what is left of a row of the map past the block's
              asm.label("rt_upload_block_copied_row")
              asm.move(:w, asm.d(1), asm.ind(3))
              asm.move(:w, asm.d(0), asm.ind(3))
              asm.move(:w, asm.d(2), asm.d(6))
              asm.label("rt_upload_block_copied_cell")
              asm.move(:w, asm.post(0), asm.ind(2))
              asm.dbra(asm.d(6), "rt_upload_block_copied_cell")
              asm.add(:l, asm.d(4), asm.a(0))
              asm.add(:w, asm.imm(row_bytes), asm.d(1))
              asm.dbra(asm.d(3), "rt_upload_block_copied_row")
              asm.bra("rt_upload_cell_next")
            end

            # The sprite table, the last sprite placed drawn first (see the note on the table above);
            # with no sprites, one row that is off the screen.
            #
            # The notes are rows already, each linked to the row after it and kept at the end of the
            # table (#emit_sprite_placed), so they are copied as they stand.
            # The chip starts at row 0 whatever is noted, so the row noted last, the one in front, is
            # written there, with the link it has: the row after its own. The rows after it go to their
            # own places, copied by the chip (#emit_sprite_rows_copied_by_chip). The row noted first is
            # the table's last, and its link is cleared here, since 80 names no row.
            def emit_sprite_table_written(asm, memory, at)
              h = Console::GenesisHardware
              notes_end = memory[SPRITES] + (MOST_SPRITES * SPRITE_BYTES)
              asm.move(:l, asm.imm(h.command(h::WRITE_VRAM, SPRITES_AT)), asm.abs_l(h::VDP_CONTROL))
              asm.lea(asm.abs_l(h::VDP_DATA), asm.a(2))
              asm.moveq(0, asm.d(0))
              asm.move(:w, at.call(SPRITE_COUNT), asm.d(5))
              asm.branch(:ne, "rt_upload_sprites_some")
              2.times { asm.move(:l, asm.d(0), asm.ind(2)) }
              asm.bra("rt_upload_sprites_done")
              asm.label("rt_upload_sprites_some")
              asm.clr(:b, asm.abs_l(notes_end - SPRITE_BYTES + 3))
              asm.move(:w, asm.d(5), asm.d(0))
              asm.lsl(:w, 3, asm.d(0))
              asm.lea(asm.abs_l(notes_end), asm.a(1))
              asm.sub(:w, asm.d(0), asm.a(1)) # the row noted last
              2.times { asm.move(:l, asm.post(1), asm.ind(2)) }
              asm.subq(:w, 1, asm.d(5))
              asm.branch(:eq, "rt_upload_sprites_done")
              emit_sprite_rows_copied_by_chip(asm)
              asm.label("rt_upload_sprites_done")
            end

            # THE REST OF THE ROWS, COPIED BY THE VIDEO CHIP ITSELF (DMA), as a console's own games send
            # their sprite table: the chip is told how many words, where they are in work RAM and where
            # they go, and reads them itself with the processor stopped, several times as fast as the
            # processor hands them over a long word at a time. The rows are in the notes in the order
            # and with the links the table wants, so they go as one run.
            #
            # A1 is at the note after the one written to row 0, D0 is the bytes of every row noted and
            # D5 the rows still to go. The rows go to their own places in the table: with D0 bytes
            # noted, that many before the row past the table's end, and one row on. The copy is
            # rt_vram_copy's, the maps' own (#emit_vram_copy).
            #
            # The rows cannot cross one of the chip's 128K blocks, where its count of the source wraps:
            # work RAM is the top 64K of the last one, and the notes end inside it.
            def emit_sprite_rows_copied_by_chip(asm)
              asm.move(:w, asm.d(5), asm.d(1))
              asm.lsl(:w, 2, asm.d(1)) # four words a row
              asm.movea(:l, asm.a(1), asm.a(0))
              asm.neg(:l, asm.d(0))
              asm.add(:l, asm.imm(SPRITES_AT + ((MOST_SPRITES + 1) * SPRITE_BYTES)), asm.d(0))
              asm.jsr(asm.abs_l("rt_vram_copy"))
            end

            # Where each plane's view is, into the horizontal scroll table (a plane moved right by the
            # distance the view moves left) and the vertical scroll memory (a plane moved up by the
            # distance the view moves down).
            def emit_scroll_written(asm, memory)
              h = Console::GenesisHardware
              asm.move(:l, asm.imm(h.command(h::WRITE_VRAM, HSCROLL_AT)), asm.abs_l(h::VDP_CONTROL))
              [0, 4].each do |plane|
                asm.move(:w, asm.abs_l(memory[SCROLL], plane), asm.d(0))
                asm.neg(:w, asm.d(0))
                asm.and(:w, asm.imm(0x3FF), asm.d(0))
                asm.move(:w, asm.d(0), asm.abs_l(h::VDP_DATA))
              end
              asm.move(:l, asm.imm(h.command(h::WRITE_VSRAM, 0)), asm.abs_l(h::VDP_CONTROL))
              [2, 6].each do |plane|
                asm.move(:w, asm.abs_l(memory[SCROLL], plane), asm.d(0))
                asm.and(:w, asm.imm(0x3FF), asm.d(0))
                asm.move(:w, asm.d(0), asm.abs_l(h::VDP_DATA))
              end
            end
          end
        end
      end
    end
  end
end
