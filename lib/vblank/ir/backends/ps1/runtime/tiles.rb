# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # A SCREEN DRAWN FROM TILES, with its sprites in front: what a Game Boy Advance shows with its tile
          # and sprite hardware, which the PlayStation does not have. Its graphics chip draws whatever it is
          # sent, so the runtime sends the whole picture again at the end of every pass (rt_tiles_draw):
          # the backdrop, each background back to front, then each sprite. That is how the console's own 2D
          # games drew.
          #
          # A BACKGROUND IS A PLANE: a picture of its whole map, 256 × 256 pixels or more, kept in video RAM
          # beside the screen's pages (PS1::TextureMemory#reserve_planes says where). A map is put on its
          # plane once, as it goes up: the plane emptied with a fill, then each cell's tile copied in from
          # the sheet of tiles kept further along video RAM, video RAM to video RAM (GP0 80h), a command of
          # four words. A changed cell is one more copy. Then each frame the plane is drawn as one textured
          # rectangle the size of the screen, its corner in the plane where the background is scrolled to. A
          # rectangle's place in its texture is a byte across and a byte down, which come round at 256 by
          # themselves, so the map comes round as a background does.
          #
          # A PLANE HOLDS PLACES IN A COLOUR TABLE, 4 or 8 bits a texel (PS1::PlaneColors), not colours: so a
          # halfword of video RAM holds four texels or two, and the chip reads a quarter or half of what it
          # would at 15 bits as it draws the plane; and a colour the game changes is one entry of the
          # background's table written again (Runtime::Colors). The background up on the plane names its
          # table (PLANE_TABLE). A plane of more colours than a table holds keeps them at 15 bits. How deep
          # each plane is is fixed when the game is built (rt_plane_shifts), so a tile on the sheet, a cell
          # copied and the fill that empties the plane are each that many halfwords narrower.
          #
          # A texel of the plane that no tile draws is nought: the table's place 0, which holds 0000h, or the
          # colour 0000h itself, which the chip leaves undrawn, so what is behind shows through.
          #
          # A SPRITE is a picture the painted screen draws too (Runtime::Paint's rt_paint_blit), drawn in
          # front of every background, in the order the pass placed them (rt_sprite_place). The ones a pass
          # placed are kept in DRAWN, a row each, which a reader of the run reads back too.
          module Tiles
            h = Console::PS1Hardware

            # Each plane's state, PLANE_BYTES each: whether it is up, where it is scrolled to, the map's
            # width and height in pixels less one, which a place on it is masked with to come round, the colour
            # table of the background up on it as a textured rectangle names it (in the word's top half), how
            # many texels a halfword holds, as a shift (rt_plane_shifts), and how deep the background up on it
            # sits in the stack (IR::Stacking's level, BAR_LEVEL for a status bar).
            PLANES = "rt planes"
            PLANE_UP = 0
            PLANE_SCROLL_X = 4
            PLANE_SCROLL_Y = 8
            PLANE_WIDTH_MASK = 12
            PLANE_HEIGHT_MASK = 16
            PLANE_TABLE = 20
            PLANE_SHIFT = 24
            PLANE_LEVEL = 28
            PLANE_BYTES = 32
            MOST_PLANES = 4

            # A STATUS BAR takes no level of the stack: it is drawn in front of every background and behind
            # every sprite (Reference#repaint_view). Its plane's level is this, which no level is.
            BAR_LEVEL = -1
            # The row the status bar up shows from, kept between 0 and the screen's height (rt_bar_place); and
            # whether it hides the sprites under it, not nought for yes (rt_bar_covers). One bar shows at a time.
            BAR_TOP = "rt bar top"
            BAR_COVERS = "rt bar covers"
            # How many rows from the top the backgrounds are drawn in this pass: down to the top of the status
            # bar up, or the whole screen (Reference#scenery_rows).
            SCENERY_ROWS = "rt scenery rows"

            # The fill command (its colour in its low 24 bits) for what shows where nothing is drawn.
            BACKDROP = "rt backdrop"

            # WHAT THE RUNTIME DRAWS A GAME'S TILED SCREEN WITH, worked out as the game is built
            # (Lowering::Picture#tiled_screen): each plane's place in video RAM (TextureMemory::Plane), how many
            # bits a texel each is kept at, the planes whose every background draws every pixel (+opaque+), the
            # planes a status bar goes up on (+bar_planes+), and +levels+: nil where every sprite is drawn in
            # front of every background in the order the pass placed them, or how many levels the stack has,
            # each drawn in turn, its backgrounds and then its sprites (Reference#repaint_view).
            Screen = Data.define(:places, :depths, :opaque, :bar_planes, :levels)

            # The sprites the last pass placed: how many, a word, then a row of DRAWN_BYTES for each:
            # whose it is (Backends::SpriteNames#name_number), which picture (#picture_number), its place
            # across and down, and where the picture it is drawn as is in the painted art (one of its
            # picture's in other colours, for a sprite drawn with them), a word each.
            DRAWN = "rt drawn sprites"
            DRAWN_BYTES = 32
            DRAWN_WHOSE = 0
            DRAWN_PICTURE = 4
            DRAWN_X = 8
            DRAWN_Y = 12
            DRAWN_ART = 16
            DRAWN_LEVEL = 20 # how deep it sits, for a screen drawn level by level (Screen#levels)
            MOST_SPRITES = Console::PLAYSTATION.sprites
            # A picture in a sprite's table: its number, and where it is in the painted art.
            POSE_BYTES = 8

            # A texture page's side (TextureMemory::PAGE_TEXELS, loaded after the runtime), which a plane is one
            # or two of each way.
            PAGE_SIDE = 256

            # The copy inside video RAM: then where from (y << 16 | x), where to, and height << 16 | width.
            COPY_IN_VRAM = h::GP0_COPY_IN_VRAM
            # A cell's side in texels, and the halfwords a texel takes at 15 bits; a plane of places takes fewer.
            CELL_TEXELS = 8
            SCREEN_SIZE = (h::SCREEN_HEIGHT << 16) | h::SCREEN_WIDTH
            # How far a halfword's texels count is shifted at each depth: one at 15 bits, two at 8, four at 4.
            SHIFT_BY_DEPTH = { 15 => 0, 8 => 1, 4 => 2 }.freeze

            module_function

            def reserve(memory)
              memory.reserve(PLANES, MOST_PLANES * PLANE_BYTES)
              memory.reserve(BACKDROP, 4)
              reserve_sprites(memory)
              memory.reserve(BAR_TOP, 4)
              memory.reserve(BAR_COVERS, 4)
              memory.reserve(SCENERY_ROWS, 4)
            end

            # The sprites a pass placed alone (DRAWN), for a painted screen with sprites over it
            # (Runtime::Paint's rt_paint_sprites_shown draws them).
            def reserve_sprites(memory) = memory.reserve(DRAWN, 4 + (MOST_SPRITES * DRAWN_BYTES))

            # The routines that place sprites alone (#emit_sprites), for a painted screen with sprites over it.
            def emit_sprite_places(asm, memory) = emit_sprites(asm, ->(name) { Runtime.at(memory, name) }, levels: false)

            # +screen+ is what the game's tiled screen is drawn with (Screen); +faces+ whether the game also fills
            # the faces of a place, which leave the chip's texture window set; +colors+ whether its colours change
            # as it runs (Runtime::Colors).
            def emit(asm, memory, screen:, faces: false, colors: false)
              at = ->(name) { Runtime.at(memory, name) }
              emit_start(asm)
              emit_plane_routines(asm, at)
              emit_cell(asm)
              emit_sprites(asm, at, levels: !screen.levels.nil?)
              emit_bar(asm, at) unless screen.bar_planes.empty?
              emit_draw(asm, at, screen, faces, colors)
              emit_sprites_at_level(asm, at) if screen.levels
              emit_plane_drawing(asm, at, bar: !screen.bar_planes.empty?)
              emit_plane_tables(asm, screen.places, screen.depths)
            end

            # rt_tiles_start: two pages, one drawn while the other is shown (Runtime::Paint's
            # rt_paint_screen), since the whole picture is drawn again every pass.
            def emit_start(asm)
              asm.label("rt_tiles_start")
              asm.j("rt_paint_screen") { asm.li(:a0, 1) }
            end

            # v0 = the state of the plane numbered a0.
            def emit_plane_state(asm, at)
              asm.sll(:v0, :a0, 5)
              asm.addu(:v0, :v0, :gp)
              asm.addiu(:v0, :v0, at.call(PLANES))
            end

            PUT_UP_KEPT = %i[s0 s1 s2 s3 s4 s5 s6 s7].freeze

            # rt_plane_put_up: a0 = the plane, a1 = the map's cells (Lowering::Picture#grid_label: a word a
            # cell, row by row, each the place in video RAM of the tile it shows, y << 16 | x, or nought for
            # none), a2 = not nought to show it from its corner, a3 = how many columns the map's grid has as a
            # power of two (5 for 32, 6 for 64), t4 = how many rows it has, t5 = the background's colour table
            # (PLANE_TABLE), t6 = how deep it sits (PLANE_LEVEL). The map's grid is the plane's size until another
            # goes up on it, so the plane comes round where the map's grid does.
            # rt_plane_take_down: a0 = the plane. rt_plane_scroll: a0 = the plane, a1, a2 = where its view is.
            #
            # s4 and s5 are the plane's width and height in texels, s7 its shift (PLANE_SHIFT).
            def emit_plane_routines(asm, at)
              word = ->(index) { DrawList.word_offset_bytes(index) }
              asm.label("rt_plane_put_up")
              asm.addiu(:sp, :sp, -4 * (PUT_UP_KEPT.length + 1))
              asm.sw(:ra, 0, :sp)
              PUT_UP_KEPT.each_with_index { |register, i| asm.sw(register, 4 + (i * 4), :sp) }
              emit_plane_state(asm, at)
              asm.li(:t0, 1)
              asm.sw(:t0, PLANE_UP, :v0)
              asm.beq(:a2, :zero, "rt_plane_put_up_view_kept")
              asm.sw(:zero, PLANE_SCROLL_X, :v0)
              asm.sw(:zero, PLANE_SCROLL_Y, :v0)
              asm.label("rt_plane_put_up_view_kept")
              asm.sw(:t5, PLANE_TABLE, :v0)
              asm.sw(:t6, PLANE_LEVEL, :v0)
              emit_plane_shift(asm, :s7, :a0)
              asm.sw(:s7, PLANE_SHIFT, :v0)
              asm.li(:t0, 8)
              asm.sllv(:s4, :t0, :a3) # the width in pixels
              asm.addiu(:t0, :s4, -1)
              asm.sw(:t0, PLANE_WIDTH_MASK, :v0)
              asm.sll(:s5, :t4, 3) # the height in pixels
              asm.addiu(:t0, :s5, -1)
              asm.sw(:t0, PLANE_HEIGHT_MASK, :v0)
              asm.move(:s6, :a3)
              emit_plane_place(asm, :s1, :a0)
              asm.sllv(:s3, :t4, :a3) # how many cells
              asm.move(:s2, :a1)
              # The plane emptied, a page's height at a time (a fill is at most 511 lines): every pixel
              # 0000h, which the chip does not draw.
              asm.move(:s0, :zero)
              asm.label("rt_plane_put_up_fill")
              DrawList.emit_command(asm, 3) { asm.lui(:a0, Console::PS1Hardware::GP0_FILL >> 16) }
              asm.sll(:t0, :s0, 16)
              asm.addu(:t0, :t0, :s1)
              asm.sw(:t0, word.call(1), :t1)
              asm.srlv(:t2, :s4, :s7) # the width in halfwords
              asm.li(:t0, PAGE_SIDE << 16)
              asm.or(:t0, :t0, :t2)
              asm.sw(:t0, word.call(2), :t1)
              asm.addiu(:s0, :s0, PAGE_SIDE)
              asm.slt(:t0, :s0, :s5)
              asm.bne(:t0, :zero, "rt_plane_put_up_fill")
              # Then each cell's tile, from the last cell back to the first.
              asm.label("rt_plane_put_up_cell")
              asm.addiu(:s3, :s3, -1)
              asm.bltz(:s3, "rt_plane_put_up_end")
              asm.sll(:t0, :s3, 2)
              asm.addu(:t0, :t0, :s2)
              asm.lw(:s0, 0, :t0)
              asm.beq(:s0, :zero, "rt_plane_put_up_cell")
              DrawList.emit_command(asm, 4) { asm.lui(:a0, COPY_IN_VRAM >> 16) }
              asm.sw(:s0, word.call(1), :t1)
              asm.srlv(:t5, :s3, :s6)
              asm.sll(:t5, :t5, 19) # the row's top line, eight lines a row, in the top half
              asm.li(:t6, 1)
              asm.sllv(:t6, :t6, :s6)
              asm.addiu(:t6, :t6, -1)
              asm.and(:t6, :t6, :s3)
              asm.sll(:t6, :t6, 3)
              asm.srlv(:t6, :t6, :s7) # the column's left edge, in halfwords
              asm.addu(:t5, :t5, :t6)
              asm.addu(:t5, :t5, :s1)
              asm.sw(:t5, word.call(2), :t1)
              emit_cell_size(asm, :t0, :s7)
              asm.b("rt_plane_put_up_cell") { asm.sw(:t0, word.call(3), :t1) }
              asm.label("rt_plane_put_up_end")
              asm.lw(:ra, 0, :sp)
              PUT_UP_KEPT.each_with_index { |register, i| asm.lw(register, 4 + (i * 4), :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4 * (PUT_UP_KEPT.length + 1)) }

              asm.label("rt_plane_take_down")
              emit_plane_state(asm, at)
              asm.jr(:ra) { asm.sw(:zero, PLANE_UP, :v0) }

              asm.label("rt_plane_scroll")
              emit_plane_state(asm, at)
              asm.sw(:a1, PLANE_SCROLL_X, :v0)
              asm.jr(:ra) { asm.sw(:a2, PLANE_SCROLL_Y, :v0) }
            end

            # +register+ = the corner in video RAM of the plane numbered +plane+ (a register), y << 16 | x,
            # from the table rt_plane_places. Changes t0 and t9.
            def emit_plane_place(asm, register, plane) = emit_plane_table_word(asm, register, plane, "rt_plane_places")

            # +register+ = the shift of the plane numbered +plane+ (PLANE_SHIFT), from the table rt_plane_shifts.
            # Changes t0 and t9.
            def emit_plane_shift(asm, register, plane) = emit_plane_table_word(asm, register, plane, "rt_plane_shifts")

            def emit_plane_table_word(asm, register, plane, table)
              asm.la(:t0, table)
              asm.sll(:t9, plane, 2)
              asm.addu(:t0, :t0, :t9)
              asm.lw(register, 0, :t0)
            end

            # +register+ = the size of a cell as a copy inside video RAM takes it, height << 16 | width in
            # halfwords, on a plane of the shift in +shift+. Changes t2.
            def emit_cell_size(asm, register, shift)
              asm.li(:t2, CELL_TEXELS)
              asm.srlv(:t2, :t2, shift)
              asm.lui(register, CELL_TEXELS)
              asm.or(register, register, :t2)
            end

            # rt_plane_cell: a0 = the plane, a1, a2 = the cell's column and row, a3 = where the tile it is to
            # show is in video RAM (y << 16 | x), t4, t5 = how many columns and rows the map has. A cell
            # outside the map is left alone (Reference#change_cell). The tile is copied over the cell.
            def emit_cell(asm)
              word = ->(index) { DrawList.word_offset_bytes(index) }
              asm.label("rt_plane_cell")
              asm.sltu(:t0, :a1, :t4)
              asm.beq(:t0, :zero, "rt_plane_cell_done")
              asm.sltu(:t0, :a2, :t5)
              asm.beq(:t0, :zero, "rt_plane_cell_done")
              emit_plane_shift(asm, :t8, :a0)
              emit_plane_place(asm, :t6, :a0)
              asm.sll(:t7, :a2, 19)
              asm.addu(:t6, :t6, :t7)
              asm.sll(:t7, :a1, 3)
              asm.srlv(:t7, :t7, :t8)
              asm.addu(:t6, :t6, :t7)
              emit_cell_size(asm, :t9, :t8)
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              DrawList.emit_command(asm, 4) { asm.lui(:a0, COPY_IN_VRAM >> 16) }
              asm.sw(:a3, word.call(1), :t1)
              asm.sw(:t6, word.call(2), :t1)
              asm.sw(:t9, word.call(3), :t1)
              asm.lw(:ra, 0, :sp)
              asm.addiu(:sp, :sp, 4)
              asm.label("rt_plane_cell_done")
              asm.jr(:ra)
            end

            # rt_sprites_begin: no sprite placed yet this pass. rt_sprite_place: a0 = the table of the
            # sprite's pictures (how many, then for each its number and where it is in the painted art, a word
            # each: POSE_BYTES), a1 = which it shows, a2, a3 = where, t4 = whose it is, and on a screen drawn level
            # by level (+levels+, Screen#levels) t5 = how deep it sits. A number naming none of its pictures places
            # nothing (Reference#object_pose_image).
            def emit_sprites(asm, at, levels:)
              drawn = at.call(DRAWN)
              asm.label("rt_sprites_begin")
              asm.jr(:ra) { asm.sw(:zero, drawn, :gp) }

              asm.label("rt_sprite_place")
              asm.lw(:t0, 0, :a0)
              asm.sltu(:t1, :a1, :t0)
              asm.beq(:t1, :zero, "rt_sprite_place_done")
              asm.sll(:t1, :a1, 3)
              asm.addu(:t1, :t1, :a0)
              asm.lw(:t6, 8, :t1)
              asm.lw(:t1, 4, :t1)
              asm.lw(:t2, drawn, :gp)
              asm.sltiu(:t3, :t2, MOST_SPRITES)
              asm.beq(:t3, :zero, "rt_sprite_place_done")
              asm.sll(:t3, :t2, 5)
              asm.addu(:t3, :t3, :gp)
              asm.sw(:t4, drawn + 4 + DRAWN_WHOSE, :t3)
              asm.sw(:t5, drawn + 4 + DRAWN_LEVEL, :t3) if levels
              asm.sw(:t6, drawn + 4 + DRAWN_ART, :t3)
              asm.sw(:t1, drawn + 4 + DRAWN_PICTURE, :t3)
              asm.sw(:a2, drawn + 4 + DRAWN_X, :t3)
              asm.sw(:a3, drawn + 4 + DRAWN_Y, :t3)
              asm.addiu(:t2, :t2, 1)
              asm.sw(:t2, drawn, :gp)
              asm.label("rt_sprite_place_done")
              asm.jr(:ra)
            end

            # A STATUS BAR is a plane drawn from the row its top is at down to the bottom of the screen, its map
            # from its corner, never scrolled (Reference#paint_status_bar): one textured rectangle, since a bar's map
            # is one texture page at most (32 cells each way), no wider than the map, so the columns past it show
            # the backdrop rather than the map come round. The rows past its map are the plane's empty texels.
            #
            # rt_bar_place: a0 = the row its top is at, kept between 0 and the screen's height
            # (Reference#exec_place_bar). rt_bar_covers: a0 = not nought to hide the sprites under it.
            # rt_bar_draw: a0 = the bar's plane's state, a1 = the draw mode naming the page at its corner.
            def emit_bar(asm, at)
              h = Console::PS1Hardware
              word = ->(index) { DrawList.word_offset_bytes(index) }
              asm.label("rt_bar_place")
              asm.bgez(:a0, "rt_bar_place_below_top")
              asm.move(:a0, :zero)
              asm.label("rt_bar_place_below_top")
              asm.slti(:t0, :a0, h::SCREEN_HEIGHT)
              asm.bne(:t0, :zero, "rt_bar_place_on_screen")
              asm.li(:a0, h::SCREEN_HEIGHT)
              asm.label("rt_bar_place_on_screen")
              asm.jr(:ra) { asm.sw(:a0, at.call(BAR_TOP), :gp) }

              asm.label("rt_bar_covers")
              asm.jr(:ra) { asm.sw(:a0, at.call(BAR_COVERS), :gp) }

              asm.label("rt_bar_draw")
              asm.lw(:t4, at.call(BAR_TOP), :gp)
              asm.li(:t5, h::SCREEN_HEIGHT)
              asm.subu(:t5, :t5, :t4) # how many rows it shows
              asm.blez(:t5, "rt_bar_draw_none")
              asm.move(:t6, :a0)
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              DrawList.emit_command(asm, 1) { asm.move(:a0, :a1) }
              DrawList.emit_command(asm, 4) { asm.lui(:a0, h::GP0_TEXTURED_RECTANGLE >> 16) }
              asm.lw(:t0, at.call(Paint::PAGE_Y), :gp)
              asm.addu(:t0, :t0, :t4)
              asm.sll(:t0, :t0, 16)
              asm.sw(:t0, word.call(1), :t1)
              asm.lw(:t0, PLANE_TABLE, :t6) # its corner, 0 across and 0 down in the page, and its colour table
              asm.sw(:t0, word.call(2), :t1)
              asm.lw(:t0, PLANE_WIDTH_MASK, :t6)
              asm.addiu(:t0, :t0, 1)
              asm.slti(:t2, :t0, h::SCREEN_WIDTH)
              asm.bne(:t2, :zero, "rt_bar_draw_fits")
              asm.li(:t0, h::SCREEN_WIDTH)
              asm.label("rt_bar_draw_fits")
              asm.sll(:t5, :t5, 16)
              asm.or(:t0, :t0, :t5)
              asm.sw(:t0, word.call(3), :t1)
              asm.lw(:ra, 0, :sp)
              asm.addiu(:sp, :sp, 4)
              asm.label("rt_bar_draw_none")
              asm.jr(:ra)
            end

            # The registers rt_tiles_draw keeps: s0 and s1 walk the sprites, s2 and s3 are the status bar up's
            # plane state (nought for none) and draw mode, s4 the level being drawn (Screen#levels).
            DRAW_KEPT = %i[s0 s1 s2 s3 s4].freeze

            # rt_tiles_draw: the whole picture, into the page this pass draws (Runtime::Paint::PAGE_Y), as the
            # interpreter paints it (Reference#repaint_view). The backdrop is a fill of the page; then the status
            # bar up, if one is; then each plane that is up, the back one first, a textured rectangle the size of
            # the screen from its page of video RAM, down to the bar's top; then each sprite the pass placed, as
            # the painted screen draws a picture. A screen whose stack puts a background in front of a sprite, or
            # whose sprites change layer (Screen#levels), is drawn a level at a time instead: the planes at the
            # level, then the sprites at it. Last, a bar that covers sprites is drawn again over them, on the
            # backdrop.
            #
            # A PLANE THAT DRAWS EVERY PIXEL hides the backdrop and every plane behind it, so while one is up the
            # drawing starts at it: the front-most of them up is found first, and nothing behind it is sent to the
            # chip, which would fill the whole screen for each only to have it covered. Not while a status bar
            # shows, below whose top no plane is drawn.
            def emit_draw(asm, at, screen, faces, colors)
              h = Console::PS1Hardware
              bar = !screen.bar_planes.empty?
              frame = 4 * (DRAW_KEPT.length + 1)
              asm.label("rt_tiles_draw")
              asm.addiu(:sp, :sp, -frame)
              asm.sw(:ra, 0, :sp)
              DRAW_KEPT.each_with_index { |register, i| asm.sw(register, 4 + (i * 4), :sp) }
              # Must come first: the colours the pass changed are in their tables before anything reads them.
              asm.jal("rt_colors_shown") if colors
              asm.jal("rt_face_chip_put_back") if faces
              # The texels copied into a plane since the last picture are read afresh, not from the chip's cache.
              DrawList.emit_command(asm, 1) { asm.lui(:a0, h::GP0_CLEAR_CACHE >> 16) }
              emit_bar_search(asm, at, screen) if bar
              unless screen.opaque.empty?
                asm.bne(:s2, :zero, "rt_tiles_draw_backdrop") if bar
                screen.opaque.sort.each do |plane|
                  asm.lw(:t0, at.call(PLANES) + (plane * PLANE_BYTES) + PLANE_UP, :gp)
                  asm.bne(:t0, :zero, "rt_tiles_draw_from_#{plane}")
                end
              end
              asm.label("rt_tiles_draw_backdrop")
              emit_backdrop_fill(asm, at, top: nil)
              # The backdrop and each background are a fill or rectangles the size of the screen, which the
              # chip takes long to draw: each goes to it as soon as the DMA is free (rt_draw_list_kick).
              asm.jal("rt_draw_list_kick")
              emit_bar_draw_call(asm, "rt_tiles_draw_scenery") if bar
              if screen.levels
                emit_draw_by_level(asm, at, screen)
              else
                emit_planes_then_sprites(asm, at, screen)
              end
              emit_bar_over_sprites(asm, at) if bar
              asm.lw(:ra, 0, :sp)
              DRAW_KEPT.each_with_index { |register, i| asm.lw(register, 4 + (i * 4), :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, frame) }
              emit_opaque_level_starts(asm, at, screen) if screen.levels
            end

            # A fill of the backdrop's colour, over the whole page, or from row +top+ (a register) down.
            def emit_backdrop_fill(asm, at, top:)
              h = Console::PS1Hardware
              asm.lw(:a0, at.call(BACKDROP), :gp)
              DrawList.emit_command(asm, 3)
              asm.lw(:t0, at.call(Paint::PAGE_Y), :gp)
              asm.addu(:t0, :t0, top) if top
              asm.sll(:t0, :t0, 16)
              asm.sw(:t0, DrawList.word_offset_bytes(1), :t1)
              if top
                asm.li(:t0, h::SCREEN_HEIGHT)
                asm.subu(:t0, :t0, top)
                asm.sll(:t0, :t0, 16)
                asm.ori(:t0, :t0, h::SCREEN_WIDTH)
              else
                asm.li(:t0, SCREEN_SIZE)
              end
              asm.sw(:t0, DrawList.word_offset_bytes(2), :t1)
            end

            # THE STATUS BAR UP, if one is: s2 = its plane's state, or nought, and s3 = the draw mode naming its page;
            # and SCENERY_ROWS set to the rows the backgrounds are drawn in, down to its top, or the whole screen.
            def emit_bar_search(asm, at, screen)
              asm.li(:t0, Console::PS1Hardware::SCREEN_HEIGHT)
              asm.sw(:t0, at.call(SCENERY_ROWS), :gp)
              asm.move(:s2, :zero)
              screen.bar_planes.each do |plane|
                state = at.call(PLANES) + (plane * PLANE_BYTES)
                other = "rt_tiles_draw_no_bar_on_#{plane}"
                asm.lw(:t0, state + PLANE_UP, :gp)
                asm.beq(:t0, :zero, other)
                asm.lw(:t0, state + PLANE_LEVEL, :gp)
                asm.bgez(:t0, other)
                asm.addiu(:s2, :gp, state)
                asm.li(:s3, plane_draw_mode(screen.places.fetch(plane), screen.depths.fetch(plane)))
                asm.lw(:t0, at.call(BAR_TOP), :gp)
                asm.sw(:t0, at.call(SCENERY_ROWS), :gp)
                asm.label(other)
              end
            end

            # The status bar up drawn, if one is (s2, s3), going on at +past+.
            def emit_bar_draw_call(asm, past)
              asm.beq(:s2, :zero, past)
              asm.move(:a0, :s2)
              asm.jal("rt_bar_draw") { asm.move(:a1, :s3) }
              asm.jal("rt_draw_list_kick")
              asm.label(past)
            end

            # A STATUS BAR THAT COVERS SPRITES (Reference#paint_bar_over_sprites): its rows filled with the
            # backdrop again, over the sprites, and the bar drawn on that.
            def emit_bar_over_sprites(asm, at)
              asm.beq(:s2, :zero, "rt_tiles_draw_uncovered")
              asm.lw(:t0, at.call(BAR_COVERS), :gp)
              asm.beq(:t0, :zero, "rt_tiles_draw_uncovered")
              asm.lw(:t4, at.call(BAR_TOP), :gp)
              asm.slti(:t0, :t4, Console::PS1Hardware::SCREEN_HEIGHT)
              asm.beq(:t0, :zero, "rt_tiles_draw_uncovered")
              emit_backdrop_fill(asm, at, top: :t4)
              emit_bar_draw_call(asm, "rt_tiles_draw_uncovered")
            end

            # Each plane that is up, the back one first, and then every sprite, in the order the pass placed
            # them. A status bar's plane is drawn by itself (#emit_bar_draw_call).
            def emit_planes_then_sprites(asm, at, screen)
              (screen.places.length - 1).downto(0) do |plane|
                state = at.call(PLANES) + (plane * PLANE_BYTES)
                skip = "rt_tiles_draw_not_#{plane}"
                asm.lw(:t0, state + PLANE_UP, :gp)
                asm.beq(:t0, :zero, skip)
                if screen.bar_planes.include?(plane)
                  asm.lw(:t0, state + PLANE_LEVEL, :gp)
                  asm.bltz(:t0, skip)
                end
                asm.label("rt_tiles_draw_from_#{plane}") if screen.opaque.include?(plane)
                emit_plane_draw_call(asm, screen, state, plane)
                asm.label(skip)
              end
              drawn = at.call(DRAWN)
              asm.lw(:s0, drawn, :gp)
              asm.addiu(:s1, :gp, drawn + 4)
              asm.label("rt_tiles_draw_sprite")
              asm.beq(:s0, :zero, "rt_tiles_draw_sprites_end")
              asm.lw(:a0, DRAWN_ART, :s1)
              asm.lw(:a1, DRAWN_X, :s1)
              asm.lw(:a2, DRAWN_Y, :s1)
              asm.jal("rt_paint_blit")
              asm.addiu(:s1, :s1, DRAWN_BYTES)
              asm.b("rt_tiles_draw_sprite") { asm.addiu(:s0, :s0, -1) }
              asm.label("rt_tiles_draw_sprites_end")
            end

            def emit_plane_draw_call(asm, screen, state, plane)
              asm.addiu(:a0, :gp, state)
              asm.li(:a1, plane_draw_mode(screen.places.fetch(plane), screen.depths.fetch(plane)))
              asm.jal("rt_plane_draw")
              asm.jal("rt_draw_list_kick")
            end

            # THE PICTURE A LEVEL AT A TIME (Reference#repaint_view), s4 the level: at each, the planes up whose
            # background sits there, the back one first, then the sprites placed at it (rt_sprites_draw_at_level).
            # A status bar's plane sits at no level (BAR_LEVEL), so is never one of them.
            def emit_draw_by_level(asm, at, screen)
              asm.move(:s4, :zero)
              asm.label("rt_tiles_draw_level")
              (screen.places.length - 1).downto(0) do |plane|
                state = at.call(PLANES) + (plane * PLANE_BYTES)
                skip = "rt_tiles_draw_not_#{plane}"
                asm.lw(:t0, state + PLANE_UP, :gp)
                asm.beq(:t0, :zero, skip)
                asm.lw(:t0, state + PLANE_LEVEL, :gp)
                asm.bne(:t0, :s4, skip)
                emit_plane_draw_call(asm, screen, state, plane)
                asm.label(skip)
              end
              asm.jal("rt_sprites_draw_at_level") { asm.move(:a0, :s4) }
              asm.addiu(:s4, :s4, 1)
              asm.slti(:t0, :s4, screen.levels)
              asm.bne(:t0, :zero, "rt_tiles_draw_level")
            end

            # Where the drawing starts from a plane that draws every pixel, on a screen drawn a level at a time: at
            # its level, with nothing behind it drawn. Planes behind it at its own level are still drawn, and
            # covered.
            def emit_opaque_level_starts(asm, at, screen)
              screen.opaque.each do |plane|
                asm.label("rt_tiles_draw_from_#{plane}")
                asm.lw(:s4, at.call(PLANES) + (plane * PLANE_BYTES) + PLANE_LEVEL, :gp)
                asm.b("rt_tiles_draw_level")
              end
            end

            # rt_sprites_draw_at_level: a0 = a level; every sprite the pass placed at it, in the order placed.
            def emit_sprites_at_level(asm, at)
              drawn = at.call(DRAWN)
              asm.label("rt_sprites_draw_at_level")
              asm.addiu(:sp, :sp, -16)
              asm.sw(:ra, 0, :sp)
              asm.sw(:s0, 4, :sp)
              asm.sw(:s1, 8, :sp)
              asm.sw(:s2, 12, :sp)
              asm.move(:s2, :a0)
              asm.lw(:s0, drawn, :gp)
              asm.addiu(:s1, :gp, drawn + 4)
              asm.label("rt_sprites_draw_at_level_next")
              asm.beq(:s0, :zero, "rt_sprites_draw_at_level_end")
              asm.lw(:t0, DRAWN_LEVEL, :s1)
              asm.bne(:t0, :s2, "rt_sprites_draw_at_level_other")
              asm.lw(:a0, DRAWN_ART, :s1)
              asm.lw(:a1, DRAWN_X, :s1)
              asm.lw(:a2, DRAWN_Y, :s1)
              asm.jal("rt_paint_blit")
              asm.label("rt_sprites_draw_at_level_other")
              asm.addiu(:s1, :s1, DRAWN_BYTES)
              asm.b("rt_sprites_draw_at_level_next") { asm.addiu(:s0, :s0, -1) }
              asm.label("rt_sprites_draw_at_level_end")
              asm.lw(:ra, 0, :sp)
              asm.lw(:s0, 4, :sp)
              asm.lw(:s1, 8, :sp)
              asm.lw(:s2, 12, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 16) }
            end

            # The draw mode naming the texture page at the corner of +place+ (TextureMemory::Plane), at +depth+ bits.
            def plane_draw_mode(place, depth)
              h = Console::PS1Hardware
              h::GP0_DRAW_MODE | (place.x / TextureMemory::PAGE_STEP_HALFWORDS) | ((place.y / TextureMemory::PAGE_TEXELS) << 4) |
                TextureMemory::DEPTH_BITS.fetch(depth) | h::DRAW_ON_SHOWN_PICTURE
            end

            PLANE_DRAW_KEPT = %i[s0 s1 s2 s3 s4 s5 s6 s7].freeze

            # rt_plane_draw: a0 = a plane's state, a1 = the draw mode naming the page at its corner. The screen is
            # covered by textured rectangles, each from one texture page of the plane: a rectangle's place in its
            # page is a byte each way, so each runs from where the view is in a page to that page's edge or the
            # screen's, and the next starts in the next page, back at the plane's first past its last (the map
            # comes round). A plane of one page each way is so drawn in up to two rectangles across and two down.
            #
            # s2 and s3 are the screen's line and the plane's at the top of a band, s4 the band's height; s5 and
            # s6 the screen's column and the plane's at the left of a rectangle, s7 its width.
            #
            # In a game with a status bar (+bar+) the bands go down to the bar's top (SCENERY_ROWS), and a bar at
            # the top of the screen leaves nothing of the plane to draw.
            def emit_plane_drawing(asm, at, bar:)
              h = Console::PS1Hardware
              word = ->(index) { DrawList.word_offset_bytes(index) }
              rows = at.call(SCENERY_ROWS) if bar
              asm.label("rt_plane_draw")
              if bar
                asm.lw(:t0, rows, :gp)
                asm.blez(:t0, "rt_plane_draw_none")
              end
              asm.addiu(:sp, :sp, -4 * (PLANE_DRAW_KEPT.length + 1))
              asm.sw(:ra, 0, :sp)
              PLANE_DRAW_KEPT.each_with_index { |register, i| asm.sw(register, 4 + (i * 4), :sp) }
              asm.move(:s0, :a0)
              asm.move(:s1, :a1)
              asm.lw(:t0, PLANE_SCROLL_Y, :s0)
              asm.lw(:t1, PLANE_HEIGHT_MASK, :s0)
              asm.and(:s3, :t0, :t1)
              asm.move(:s2, :zero)
              asm.label("rt_plane_draw_band")
              emit_run_to_page_edge(asm, :s4, :s3, h::SCREEN_HEIGHT, :s2, "rt_plane_draw_band_fits", limit_at: rows)
              asm.lw(:t0, PLANE_SCROLL_X, :s0)
              asm.lw(:t1, PLANE_WIDTH_MASK, :s0)
              asm.and(:s6, :t0, :t1)
              asm.move(:s5, :zero)
              asm.label("rt_plane_draw_piece")
              emit_run_to_page_edge(asm, :s7, :s6, h::SCREEN_WIDTH, :s5, "rt_plane_draw_piece_fits")
              # The page: the corner's, then for each page across as many 64s of halfwords as 256 texels take
              # (four at 15 bits, two at 8, one at 4), and one down.
              asm.lw(:t4, PLANE_SHIFT, :s0)
              asm.li(:t5, 2)
              asm.subu(:t5, :t5, :t4)
              asm.srl(:t0, :s6, 8)
              asm.sllv(:t0, :t0, :t5)
              asm.srl(:t1, :s3, 8)
              asm.sll(:t1, :t1, 4)
              asm.addu(:a0, :s1, :t0)
              DrawList.emit_command(asm, 1) { asm.addu(:a0, :a0, :t1) }
              DrawList.emit_command(asm, 4) { asm.lui(:a0, h::GP0_TEXTURED_RECTANGLE >> 16) }
              asm.lw(:t0, at.call(Paint::PAGE_Y), :gp)
              asm.addu(:t0, :t0, :s2)
              asm.sll(:t0, :t0, 16)
              asm.or(:t0, :t0, :s5)
              asm.sw(:t0, word.call(1), :t1)
              asm.andi(:t2, :s3, PAGE_SIDE - 1)
              asm.sll(:t2, :t2, 8)
              asm.andi(:t3, :s6, PAGE_SIDE - 1)
              asm.or(:t2, :t2, :t3)
              asm.lw(:t4, PLANE_TABLE, :s0)
              asm.or(:t2, :t2, :t4)
              asm.sw(:t2, word.call(2), :t1)
              asm.sll(:t0, :s4, 16)
              asm.or(:t0, :t0, :s7)
              asm.sw(:t0, word.call(3), :t1)
              asm.addu(:s5, :s5, :s7)
              asm.addu(:s6, :s6, :s7)
              asm.lw(:t1, PLANE_WIDTH_MASK, :s0)
              asm.and(:s6, :s6, :t1)
              asm.slti(:t0, :s5, h::SCREEN_WIDTH)
              asm.bne(:t0, :zero, "rt_plane_draw_piece")
              asm.addu(:s2, :s2, :s4)
              asm.addu(:s3, :s3, :s4)
              asm.lw(:t1, PLANE_HEIGHT_MASK, :s0)
              asm.and(:s3, :s3, :t1)
              if bar
                asm.lw(:t1, rows, :gp)
                asm.slt(:t0, :s2, :t1)
              else
                asm.slti(:t0, :s2, h::SCREEN_HEIGHT)
              end
              asm.bne(:t0, :zero, "rt_plane_draw_band")
              asm.lw(:ra, 0, :sp)
              PLANE_DRAW_KEPT.each_with_index { |register, i| asm.lw(register, 4 + (i * 4), :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4 * (PLANE_DRAW_KEPT.length + 1)) }
              return unless bar

              asm.label("rt_plane_draw_none")
              asm.jr(:ra)
            end

            # +run+ = how far from +place+ (in the plane) to its page's edge, or from +shown+ to the screen's
            # edge at +screen+ (or at the row in the word +limit_at+ from gp), whichever is nearer. Changes t0 to t2.
            def emit_run_to_page_edge(asm, run, place, screen, shown, fits, limit_at: nil)
              asm.andi(:t0, place, PAGE_SIDE - 1)
              asm.li(:t1, PAGE_SIDE)
              asm.subu(run, :t1, :t0)
              if limit_at
                asm.lw(:t1, limit_at, :gp)
              else
                asm.li(:t1, screen)
              end
              asm.subu(:t1, :t1, shown)
              asm.slt(:t2, :t1, run)
              asm.beq(:t2, :zero, fits)
              asm.move(run, :t1)
              asm.label(fits)
            end

            # rt_plane_places: each plane's corner in video RAM, y << 16 | x, a word each; rt_plane_shifts: each
            # plane's shift (PLANE_SHIFT), a word each.
            def emit_plane_tables(asm, places, depths)
              asm.label("rt_plane_places")
              asm.data_words(places.map { |place| (place.y << 16) | place.x })
              asm.label("rt_plane_shifts")
              asm.data_words(depths.map { |depth| SHIFT_BY_DEPTH.fetch(depth) })
            end

            # The fill command that shows +color+ (a 15-bit colour) where nothing is drawn.
            def backdrop_command(color)
              Console::PS1Hardware::GP0_FILL | Console::PS1Hardware.command_color(color.to_i & 0x7FFF)
            end
          end
        end
      end
    end
  end
end
