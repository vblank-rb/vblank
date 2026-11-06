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
            # The cells a game may change in one pass, each noted as its plane, its place in it and its tile.
            MOST_CELLS = 64
            CELL_BYTES = 6
            # A sprite piece's note: where it is on the screen as the chip counts (128 past the screen's
            # corner), the tile and palette it is drawn with, and its size (Art::Piece#size_bits).
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
            def emit(asm, memory, columns:, colors: false, scene_tiles: false)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              emit_start(asm, colors: colors)
              emit_maps(asm, memory, at, columns)
              emit_sprites(asm, memory, at)
              emit_scene_tiles(asm, at) if scene_tiles
              emit_upload(asm, memory, at, columns, colors: colors, scene_tiles: scene_tiles)
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
            # (plane, x, y): where the view of the plane is. rt_set_cell(plane, column, row, cell): one
            # cell noted to change, the game stopped when it changes more than a queue holds.
            def emit_maps(asm, memory, at, columns)
              shift = columns == 64 ? 6 : 5
              asm.label("rt_background_put_up")
              asm.lea(asm.abs_l("art grids"), asm.a(0))
              asm.lsl(:l, 3, asm.d(1))
              asm.add(:l, asm.d(1), asm.a(0))
              asm.lea(asm.abs_l(memory[PENDING]), asm.a(1))
              asm.move(:l, asm.d(0), asm.d(3))
              asm.lsl(:l, 2, asm.d(3))
              asm.move(:l, asm.a(0), asm.idx(1, 0, 3))
              emit_cells_of_plane_let_go(asm, memory, at)
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

              asm.label("rt_set_cell")
              asm.move(:w, at.call(CELL_COUNT), asm.d(4))
              asm.cmp(:w, asm.imm(MOST_CELLS), asm.d(4))
              asm.branch(:cs, "rt_set_cell_room")
              asm.moveq(Frame::CELLS_FULL, asm.d(0))
              asm.jmp(asm.abs_l("rt_fault"))
              asm.label("rt_set_cell_room")
              asm.and(:l, asm.imm(0xFFFF), asm.d(4))
              asm.mulu(asm.imm(CELL_BYTES), asm.d(4))
              asm.lea(asm.abs_l(memory[CELLS]), asm.a(0))
              asm.add(:l, asm.d(4), asm.a(0))
              asm.move(:w, asm.d(0), asm.post(0))
              asm.lsl(:l, shift, asm.d(2))
              asm.add(:l, asm.d(1), asm.d(2))
              asm.move(:w, asm.d(2), asm.post(0))
              asm.move(:w, asm.d(3), asm.post(0))
              asm.addq(:w, 1, at.call(CELL_COUNT))
              asm.rts
            end

            # The cells noted for plane D0 taken out of the queue, the rest kept in their order.
            def emit_cells_of_plane_let_go(asm, memory, at)
              asm.move(:w, at.call(CELL_COUNT), asm.d(4))
              asm.branch(:eq, "rt_cells_let_go_done")
              asm.lea(asm.abs_l(memory[CELLS]), asm.a(1))
              asm.movea(:l, asm.a(1), asm.a(2))
              asm.moveq(0, asm.d(5)) # how many are kept
              asm.subq(:w, 1, asm.d(4))
              asm.label("rt_cells_let_go_cell")
              asm.move(:w, asm.post(1), asm.d(6))
              asm.move(:w, asm.post(1), asm.d(7))
              asm.cmp(:w, asm.d(0), asm.d(6))
              asm.branch(:ne, "rt_cells_let_go_keep")
              asm.addq(:l, 2, asm.a(1))
              asm.bra("rt_cells_let_go_next")
              asm.label("rt_cells_let_go_keep")
              asm.move(:w, asm.d(6), asm.post(2))
              asm.move(:w, asm.d(7), asm.post(2))
              asm.move(:w, asm.post(1), asm.post(2))
              asm.addq(:w, 1, asm.d(5))
              asm.label("rt_cells_let_go_next")
              asm.dbra(asm.d(4), "rt_cells_let_go_cell")
              asm.move(:w, asm.d(5), at.call(CELL_COUNT))
              asm.label("rt_cells_let_go_done")
            end

            # SPRITES. rt_sprites_begin forgets the sprites of the last pass. rt_sprite_place(poses, pose,
            # x, y, whose, which, palettes) places one: +poses+ is the place of the sprite's table of pictures
            # (how many, then each picture's number), +pose+ which of them it shows — none for a number outside
            # the table — and +whose+ the sprite's number for a reader (SpriteNames). Each piece of the
            # picture is a row of the table, at the sprite's place plus the piece's own; a piece wholly
            # off the screen is not written, and nor is any piece once the table's 80 rows are used.
            #
            # A sprite DRAWN IN A LIST OF COLOURS (`draw_with`) names, in +palettes+, a table of how many lists
            # it can be drawn with and the palette of each, in the bits of a piece's word that name it; +which+
            # is the one the game names now. Every piece is then drawn from that palette, and a +which+ the
            # table has no list for draws it from the palette its own picture names. A sprite drawn with
            # none has nought for +palettes+.
            def emit_sprites(asm, memory, at)
              asm.label("rt_sprites_begin")
              asm.clr(:w, at.call(SPRITE_COUNT))
              asm.clr(:w, at.call(DRAWN))
              asm.rts

              asm.label("rt_sprite_place")
              emit_palette_chosen(asm)
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.moveq(0, asm.d(5))
              asm.move(:w, asm.post(0), asm.d(5))
              asm.cmp(:l, asm.d(5), asm.d(1))
              asm.branch(:cc, "rt_sprite_place_done")
              asm.lsl(:l, 1, asm.d(1))
              asm.moveq(0, asm.d(6))
              asm.move(:w, asm.idx(0, 0, 1), asm.d(6)) # the picture's number
              emit_drawn_note(asm, memory, at)
              asm.lea(asm.abs_l("art sprite pictures"), asm.a(0))
              asm.lsl(:l, 2, asm.d(6))
              asm.movea(:l, asm.idx(0, 0, 6), asm.a(0))
              asm.moveq(0, asm.d(5))
              asm.move(:w, asm.post(0), asm.d(5))
              asm.subq(:w, 1, asm.d(5))
              asm.branch(:mi, "rt_sprite_place_done")
              asm.label("rt_sprite_place_piece")
              asm.moveq(0, asm.d(7))
              asm.move(:w, asm.post(0), asm.d(7))
              asm.add(:l, asm.d(2), asm.d(7)) # the piece's left
              asm.moveq(0, asm.d(1))
              asm.move(:w, asm.post(0), asm.d(1))
              asm.add(:l, asm.d(3), asm.d(1)) # its top
              asm.move(:w, asm.post(0), asm.d(0)) # its tile and palette
              asm.move(:l, asm.a(4), asm.d(6))
              asm.branch(:mi, "rt_sprite_place_own_palette")
              asm.and(:w, asm.imm(0x9FFF), asm.d(0))
              asm.or(:w, asm.d(6), asm.d(0))
              asm.label("rt_sprite_place_own_palette")
              asm.moveq(0, asm.d(6))
              asm.move(:w, asm.post(0), asm.d(6)) # its size
              emit_piece_written(asm, memory, at)
              asm.dbra(asm.d(5), "rt_sprite_place_piece")
              asm.label("rt_sprite_place_done")
              asm.rts
            end

            # A4: the palette the sprite is drawn from, as the bits of a piece's word that name it, or -1 for the
            # one its picture names. D5 is the list the game names (negative or past the table's: none), D6 the table.
            def emit_palette_chosen(asm)
              asm.moveq(-1, asm.d(7))
              asm.movea(:l, asm.d(7), asm.a(4))
              asm.tst(:l, asm.d(6))
              asm.branch(:eq, "rt_sprite_place_chosen")
              asm.movea(:l, asm.d(6), asm.a(3))
              asm.moveq(0, asm.d(6))
              asm.move(:w, asm.post(3), asm.d(6))
              asm.cmp(:l, asm.d(6), asm.d(5))
              asm.branch(:cc, "rt_sprite_place_chosen")
              asm.lsl(:l, 1, asm.d(5))
              asm.moveq(0, asm.d(7))
              asm.move(:w, asm.idx(3, 0, 5), asm.d(7))
              asm.movea(:l, asm.d(7), asm.a(4))
              asm.label("rt_sprite_place_chosen")
            end

            # The reader's row for the sprite: whose, which picture, where. D2 and D3 are its place.
            def emit_drawn_note(asm, memory, at)
              asm.moveq(0, asm.d(5))
              asm.move(:w, at.call(DRAWN), asm.d(5))
              asm.cmp(:w, asm.imm(MOST_SPRITES), asm.d(5))
              asm.branch(:cc, "rt_sprite_place_noted")
              asm.lsl(:l, 3, asm.d(5))
              asm.lea(asm.abs_l(memory[DRAWN], 2), asm.a(1))
              asm.add(:l, asm.d(5), asm.a(1))
              asm.move(:w, asm.d(4), asm.post(1))
              asm.move(:w, asm.d(6), asm.post(1))
              asm.move(:w, asm.d(2), asm.post(1))
              asm.move(:w, asm.d(3), asm.post(1))
              asm.addq(:w, 1, at.call(DRAWN))
              asm.label("rt_sprite_place_noted")
            end

            # The piece at (D7, D1) with the tile and palette in D0 and the size in D6 into the table, if any
            # of it is on the screen and the table has a row for it.
            def emit_piece_written(asm, memory, at)
              emit_piece_side(asm, 2) # its width, in pixels
              asm.add(:l, asm.d(7), asm.d(4))
              asm.branch(:le, "rt_sprite_place_skip") # its right edge at or past the screen's left
              asm.cmp(:l, asm.imm(Paint::WIDTH), asm.d(7))
              asm.branch(:ge, "rt_sprite_place_skip")
              emit_piece_side(asm, 0) # its height
              asm.add(:l, asm.d(1), asm.d(4))
              asm.branch(:le, "rt_sprite_place_skip")
              asm.cmp(:l, asm.imm(Paint::HEIGHT), asm.d(1))
              asm.branch(:ge, "rt_sprite_place_skip")
              asm.moveq(0, asm.d(4))
              asm.move(:w, at.call(SPRITE_COUNT), asm.d(4))
              asm.cmp(:w, asm.imm(MOST_SPRITES), asm.d(4))
              asm.branch(:cc, "rt_sprite_place_done")
              asm.mulu(asm.imm(SPRITE_BYTES), asm.d(4))
              asm.lea(asm.abs_l(memory[SPRITES]), asm.a(1))
              asm.add(:l, asm.d(4), asm.a(1))
              asm.add(:l, asm.imm(SPRITE_ORIGIN), asm.d(7))
              asm.add(:l, asm.imm(SPRITE_ORIGIN), asm.d(1))
              asm.move(:w, asm.d(7), asm.post(1))
              asm.move(:w, asm.d(1), asm.post(1))
              asm.move(:w, asm.d(0), asm.post(1))
              asm.move(:w, asm.d(6), asm.post(1))
              asm.addq(:w, 1, at.call(SPRITE_COUNT))
              asm.label("rt_sprite_place_skip")
            end

            # D4: one side of the piece whose size is in D6, in pixels — across from the two bits at
            # +shift+ 2, down from the two at 0, each a count of tiles less one.
            def emit_piece_side(asm, shift)
              asm.moveq(3, asm.d(4))
              if shift.zero?
                asm.and(:l, asm.d(6), asm.d(4))
              else
                asm.move(:l, asm.d(6), asm.d(4))
                asm.lsr(:l, shift, asm.d(4))
              end
              asm.addq(:l, 1, asm.d(4))
              asm.lsl(:l, 3, asm.d(4))
            end

            # rt_upload (and rt_upload_whole, which is the same, the screen being off): the maps noted
            # are copied onto their planes, the cells changed after them written, then the sprite table
            # and the scroll. The colours are first, being the shortest, since a map's copy can run past the end of the
            # blank and what is written after it is on the screen a frame late.
            #
            # In a game whose scenes each bring their own tiles in, an arriving scene's go first, with the
            # screen switched off (#emit_scene_tiles), and the screen comes back on in the blank after
            # everything else is in.
            def emit_upload(asm, memory, at, columns, colors: false, scene_tiles: false)
              asm.label("rt_upload")
              asm.label("rt_upload_whole")
              asm.jsr(asm.abs_l("rt_scene_tiles_copied")) if scene_tiles
              asm.jsr(asm.abs_l("rt_colors_written")) if colors
              [[0, PLANE_A_AT], [1, PLANE_B_AT]].each { |plane, base| emit_plane_map_copied(asm, memory, plane, base, columns) }
              emit_cells_written(asm, memory, at)
              emit_sprite_table_written(asm, memory, at)
              emit_scroll_written(asm, memory)
              emit_screen_back_on(asm, at) if scene_tiles
              asm.rts
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

            # The grid noted for plane +plane+, if any, copied row by row onto it: each row is
            # as many cells as the map has across, from the start of a row of the plane.
            def emit_plane_map_copied(asm, memory, plane, base, columns)
              h = Console::GenesisHardware
              shift = columns == 64 ? 6 : 5
              skip = "rt_upload_no_map_#{plane}"
              asm.move(:l, asm.abs_l(memory[PENDING], plane * 4), asm.d(0))
              asm.branch(:eq, skip)
              asm.movea(:l, asm.d(0), asm.a(2))
              asm.clr(:l, asm.abs_l(memory[PENDING], plane * 4))
              asm.movea(:l, asm.post(2), asm.a(0))
              asm.moveq(0, asm.d(2))
              asm.move(:w, asm.post(2), asm.d(2)) # cells across
              asm.moveq(0, asm.d(3))
              asm.move(:w, asm.ind(2), asm.d(3)) # rows
              asm.moveq(0, asm.d(4)) # the row
              asm.label("rt_upload_map_row_#{plane}")
              asm.cmp(:l, asm.d(3), asm.d(4))
              asm.branch(:ge, skip)
              asm.move(:l, asm.d(4), asm.d(0))
              asm.lsl(:l, shift + 1, asm.d(0)) # a row of the plane is its cells across, two bytes each
              asm.add(:l, asm.imm(base), asm.d(0))
              asm.jsr(asm.abs_l("rt_vram_write_at"))
              asm.move(:w, asm.d(2), asm.d(5))
              asm.subq(:w, 1, asm.d(5))
              asm.label("rt_upload_map_cell_#{plane}")
              asm.move(:w, asm.post(0), asm.abs_l(h::VDP_DATA))
              asm.dbra(asm.d(5), "rt_upload_map_cell_#{plane}")
              asm.addq(:l, 1, asm.d(4))
              asm.bra("rt_upload_map_row_#{plane}")
              asm.label(skip)
            end

            # The cells noted written one at a time, each with its place in the plane it is on.
            def emit_cells_written(asm, memory, at)
              h = Console::GenesisHardware
              asm.move(:w, at.call(CELL_COUNT), asm.d(7))
              asm.branch(:eq, "rt_upload_cells_done")
              asm.clr(:w, at.call(CELL_COUNT))
              asm.lea(asm.abs_l(memory[CELLS]), asm.a(1))
              asm.subq(:w, 1, asm.d(7))
              asm.label("rt_upload_cell")
              asm.moveq(0, asm.d(0))
              asm.move(:w, asm.post(1), asm.d(0))
              asm.and(:l, asm.imm(1), asm.d(0))
              asm.lsl(:l, 8, asm.d(0))
              asm.lsl(:l, 5, asm.d(0)) # 8K a plane
              asm.add(:l, asm.imm(PLANE_A_AT), asm.d(0))
              asm.moveq(0, asm.d(3))
              asm.move(:w, asm.post(1), asm.d(3))
              asm.lsl(:l, 1, asm.d(3))
              asm.add(:l, asm.d(3), asm.d(0))
              asm.move(:w, asm.post(1), asm.d(2))
              asm.jsr(asm.abs_l("rt_vram_write_at"))
              asm.move(:w, asm.d(2), asm.abs_l(h::VDP_DATA))
              asm.dbra(asm.d(7), "rt_upload_cell")
              asm.label("rt_upload_cells_done")
            end

            # The sprite table, the last sprite placed in the first row (see the note on the table above);
            # with no sprites, one row that is off the screen.
            def emit_sprite_table_written(asm, memory, at)
              h = Console::GenesisHardware
              asm.move(:l, asm.imm(h.command(h::WRITE_VRAM, SPRITES_AT)), asm.abs_l(h::VDP_CONTROL))
              asm.moveq(0, asm.d(5))
              asm.move(:w, at.call(SPRITE_COUNT), asm.d(5))
              asm.branch(:ne, "rt_upload_sprites_some")
              asm.moveq(0, asm.d(0))
              4.times { asm.move(:w, asm.d(0), asm.abs_l(h::VDP_DATA)) }
              asm.bra("rt_upload_sprites_done")
              asm.label("rt_upload_sprites_some")
              asm.move(:l, asm.d(5), asm.d(0))
              asm.mulu(asm.imm(SPRITE_BYTES), asm.d(0))
              asm.lea(asm.abs_l(memory[SPRITES] - SPRITE_BYTES), asm.a(1))
              asm.add(:l, asm.d(0), asm.a(1)) # the last row noted
              asm.moveq(1, asm.d(6))
              asm.label("rt_upload_sprite")
              asm.move(:w, asm.disp(1, 2), asm.abs_l(h::VDP_DATA)) # up and down
              asm.move(:w, asm.d(6), asm.d(0)) # the next row, or none after the last
              asm.cmp(:w, asm.d(5), asm.d(6))
              asm.branch(:ne, "rt_upload_sprite_linked")
              asm.moveq(0, asm.d(0))
              asm.label("rt_upload_sprite_linked")
              asm.move(:w, asm.disp(1, 6), asm.d(1))
              asm.lsl(:w, 8, asm.d(1))
              asm.or(:w, asm.d(1), asm.d(0))
              asm.move(:w, asm.d(0), asm.abs_l(h::VDP_DATA)) # its size, and its link
              asm.move(:w, asm.disp(1, 4), asm.abs_l(h::VDP_DATA)) # its tile and palette
              asm.move(:w, asm.ind(1), asm.abs_l(h::VDP_DATA)) # across
              asm.lea(asm.disp(1, -SPRITE_BYTES), asm.a(1))
              asm.addq(:w, 1, asm.d(6))
              asm.cmp(:w, asm.d(5), asm.d(6))
              asm.branch(:ls, "rt_upload_sprite")
              asm.label("rt_upload_sprites_done")
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
