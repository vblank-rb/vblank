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
          # A BACKGROUND IS A PLANE: a picture of its whole map, 256 × 256 pixels of 15-bit colour, kept in
          # video RAM beside the screen's pages (PS1::TextureMemory#reserve_planes says where). A map is
          # put on its plane once, as it goes up: the plane emptied with a fill, then each cell's tile
          # copied in from the sheet of tiles kept further along video RAM, video RAM to video RAM (GP0
          # 80h), a command of four words. A changed cell is one more copy. Then each frame the plane is
          # drawn as one textured rectangle the size of the screen, its corner in the plane where the
          # background is scrolled to. A rectangle's place in its texture is a byte across and a byte
          # down, which come round at 256 by themselves, so the map comes round as a background does.
          # A pixel of the plane that no tile draws is 0000h, which the chip leaves undrawn, so what is
          # behind shows through.
          #
          # A SPRITE is a picture the painted screen draws too (Runtime::Paint's rt_paint_blit), drawn in
          # front of every background, in the order the pass placed them (rt_sprite_place). The ones a pass
          # placed are kept in DRAWN, a row each, which a reader of the run reads back too.
          module Tiles
            h = Console::PS1Hardware

            # Each plane's state, PLANE_BYTES each: whether it is up, and where it is scrolled to.
            PLANES = "rt planes"
            PLANE_UP = 0
            PLANE_SCROLL_X = 4
            PLANE_SCROLL_Y = 8
            PLANE_BYTES = 16
            MOST_PLANES = 4

            # The fill command (its colour in its low 24 bits) for what shows where nothing is drawn.
            BACKDROP = "rt backdrop"

            # The sprites the last pass placed: how many, a word, then a row of DRAWN_BYTES for each:
            # whose it is (Backends::SpriteNames#name_number), which picture (#picture_number), and its
            # place across and down, a word each.
            DRAWN = "rt drawn sprites"
            DRAWN_BYTES = 16
            DRAWN_WHOSE = 0
            DRAWN_PICTURE = 4
            DRAWN_X = 8
            DRAWN_Y = 12
            MOST_SPRITES = Console::PLAYSTATION.sprites

            # A plane's side, in pixels and in cells of 8.
            PLANE_SIDE = 256
            PLANE_CELLS = PLANE_SIDE / 8

            # The label of the table of where each picture a sprite can show is in the painted art, by
            # its number (Backends::SpriteNames#picture_number), which the lowering writes.
            SPRITE_PICTURES = "tiles sprite pictures"

            # The copy inside video RAM: then where from (y << 16 | x), where to, and height << 16 | width.
            COPY_IN_VRAM = h::GP0_COPY_IN_VRAM
            CELL_SIZE = (8 << 16) | 8
            SCREEN_SIZE = (h::SCREEN_HEIGHT << 16) | h::SCREEN_WIDTH

            module_function

            def reserve(memory)
              memory.reserve(PLANES, MOST_PLANES * PLANE_BYTES)
              memory.reserve(BACKDROP, 4)
              memory.reserve(DRAWN, 4 + (MOST_SPRITES * DRAWN_BYTES))
            end

            # +places+ is each plane's corner in video RAM, [x, y], by its number; +faces+ whether the game
            # also fills the faces of a place, which leave the chip's texture window set.
            def emit(asm, memory, places:, faces: false)
              at = ->(name) { Runtime.at(memory, name) }
              emit_start(asm)
              emit_plane_routines(asm, at)
              emit_cell(asm)
              emit_sprites(asm, at)
              emit_draw(asm, at, places, faces)
              emit_plane_tables(asm, places)
            end

            # rt_tiles_start: two pages, one drawn while the other is shown (Runtime::Paint's
            # rt_paint_screen), since the whole picture is drawn again every pass.
            def emit_start(asm)
              asm.label("rt_tiles_start")
              asm.j("rt_paint_screen") { asm.li(:a0, 1) }
            end

            # v0 = the state of the plane numbered a0.
            def emit_plane_state(asm, at)
              asm.sll(:v0, :a0, 4)
              asm.addu(:v0, :v0, :gp)
              asm.addiu(:v0, :v0, at.call(PLANES))
            end

            # rt_plane_put_up: a0 = the plane, a1 = the map's cells (Lowering::Picture#grid_label: a word a
            # cell, row by row, PLANE_CELLS each way, each the place in video RAM of the tile it shows,
            # y << 16 | x, or nought for none), a2 = not nought to show it from its corner.
            # rt_plane_take_down: a0 = the plane. rt_plane_scroll: a0 = the plane, a1, a2 = where its view is.
            def emit_plane_routines(asm, at)
              port = Console::PS1Hardware::GP0 & 0xFFFF
              asm.label("rt_plane_put_up")
              asm.addiu(:sp, :sp, -20)
              asm.sw(:ra, 0, :sp)
              %i[s0 s1 s2 s3].each_with_index { |register, i| asm.sw(register, 4 + (i * 4), :sp) }
              emit_plane_state(asm, at)
              asm.li(:t0, 1)
              asm.sw(:t0, PLANE_UP, :v0)
              asm.beq(:a2, :zero, "rt_plane_put_up_view_kept")
              asm.sw(:zero, PLANE_SCROLL_X, :v0)
              asm.sw(:zero, PLANE_SCROLL_Y, :v0)
              asm.label("rt_plane_put_up_view_kept")
              emit_plane_place(asm, :s1, :a0)
              asm.move(:s2, :a1)
              # The plane emptied: every pixel 0000h, which the chip does not draw.
              asm.jal("rt_gp0_word") { asm.lui(:a0, Console::PS1Hardware::GP0_FILL >> 16) }
              asm.sw(:s1, port, :t1)
              asm.li(:t0, (PLANE_SIDE << 16) | PLANE_SIDE)
              asm.sw(:t0, port, :t1)
              asm.move(:s3, :zero)
              asm.label("rt_plane_put_up_cell")
              asm.lw(:s0, 0, :s2)
              asm.beq(:s0, :zero, "rt_plane_put_up_next")
              asm.jal("rt_gp0_word") { asm.lui(:a0, COPY_IN_VRAM >> 16) }
              asm.sw(:s0, port, :t1)
              asm.srl(:t5, :s3, 5)
              asm.sll(:t5, :t5, 19) # the row's top line, eight lines a row, in the top half
              asm.andi(:t6, :s3, PLANE_CELLS - 1)
              asm.sll(:t6, :t6, 3)
              asm.addu(:t5, :t5, :t6)
              asm.addu(:t5, :t5, :s1)
              asm.sw(:t5, port, :t1)
              asm.li(:t0, CELL_SIZE)
              asm.sw(:t0, port, :t1)
              asm.label("rt_plane_put_up_next")
              asm.addiu(:s3, :s3, 1)
              asm.slti(:t0, :s3, PLANE_CELLS * PLANE_CELLS)
              asm.bne(:t0, :zero, "rt_plane_put_up_cell") { asm.addiu(:s2, :s2, 4) }
              asm.lw(:ra, 0, :sp)
              %i[s0 s1 s2 s3].each_with_index { |register, i| asm.lw(register, 4 + (i * 4), :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, 20) }

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
            def emit_plane_place(asm, register, plane)
              asm.la(:t0, "rt_plane_places")
              asm.sll(:t9, plane, 2)
              asm.addu(:t0, :t0, :t9)
              asm.lw(register, 0, :t0)
            end

            # rt_plane_cell: a0 = the plane, a1, a2 = the cell's column and row, a3 = where the tile it is to
            # show is in video RAM (y << 16 | x), t4, t5 = how many columns and rows the map has. A cell
            # outside the map is left alone (Reference#change_cell). The tile is copied over the cell.
            def emit_cell(asm)
              port = Console::PS1Hardware::GP0 & 0xFFFF
              asm.label("rt_plane_cell")
              asm.sltu(:t0, :a1, :t4)
              asm.beq(:t0, :zero, "rt_plane_cell_done")
              asm.sltu(:t0, :a2, :t5)
              asm.beq(:t0, :zero, "rt_plane_cell_done")
              emit_plane_place(asm, :t6, :a0)
              asm.sll(:t7, :a2, 19)
              asm.addu(:t6, :t6, :t7)
              asm.sll(:t7, :a1, 3)
              asm.addu(:t6, :t6, :t7)
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.jal("rt_gp0_word") { asm.lui(:a0, COPY_IN_VRAM >> 16) }
              asm.sw(:a3, port, :t1)
              asm.sw(:t6, port, :t1)
              asm.li(:t0, CELL_SIZE)
              asm.sw(:t0, port, :t1)
              asm.lw(:ra, 0, :sp)
              asm.addiu(:sp, :sp, 4)
              asm.label("rt_plane_cell_done")
              asm.jr(:ra)
            end

            # rt_sprites_begin: no sprite placed yet this pass. rt_sprite_place: a0 = the table of the
            # sprite's pictures (how many, then each one's number, a word each), a1 = which it shows, a2, a3
            # = where, t4 = whose it is. A number naming none of its pictures places nothing
            # (Reference#object_pose_image).
            def emit_sprites(asm, at)
              drawn = at.call(DRAWN)
              asm.label("rt_sprites_begin")
              asm.jr(:ra) { asm.sw(:zero, drawn, :gp) }

              asm.label("rt_sprite_place")
              asm.lw(:t0, 0, :a0)
              asm.sltu(:t1, :a1, :t0)
              asm.beq(:t1, :zero, "rt_sprite_place_done")
              asm.sll(:t1, :a1, 2)
              asm.addu(:t1, :t1, :a0)
              asm.lw(:t1, 4, :t1)
              asm.lw(:t2, drawn, :gp)
              asm.sltiu(:t3, :t2, MOST_SPRITES)
              asm.beq(:t3, :zero, "rt_sprite_place_done")
              asm.sll(:t3, :t2, 4)
              asm.addu(:t3, :t3, :gp)
              asm.sw(:t4, drawn + 4 + DRAWN_WHOSE, :t3)
              asm.sw(:t1, drawn + 4 + DRAWN_PICTURE, :t3)
              asm.sw(:a2, drawn + 4 + DRAWN_X, :t3)
              asm.sw(:a3, drawn + 4 + DRAWN_Y, :t3)
              asm.addiu(:t2, :t2, 1)
              asm.sw(:t2, drawn, :gp)
              asm.label("rt_sprite_place_done")
              asm.jr(:ra)
            end

            # rt_tiles_draw: the whole picture, into the page this pass draws (Runtime::Paint::PAGE_Y). The
            # backdrop is a fill of the page; each plane that is up, the back one first, is a textured
            # rectangle the size of the screen from its page of video RAM; then each sprite the pass
            # placed, as the painted screen draws a picture.
            def emit_draw(asm, at, places, faces)
              h = Console::PS1Hardware
              port = h::GP0 & 0xFFFF
              page = at.call(Paint::PAGE_Y)
              asm.label("rt_tiles_draw")
              asm.addiu(:sp, :sp, -12)
              asm.sw(:ra, 0, :sp)
              asm.sw(:s0, 4, :sp)
              asm.sw(:s1, 8, :sp)
              asm.jal("rt_face_chip_put_back") if faces
              # The texels copied into a plane since the last picture are read afresh, not from the chip's cache.
              asm.jal("rt_gp0_word") { asm.lui(:a0, h::GP0_CLEAR_CACHE >> 16) }
              asm.lw(:a0, at.call(BACKDROP), :gp)
              asm.jal("rt_gp0_word")
              asm.lw(:t0, page, :gp)
              asm.sll(:t0, :t0, 16)
              asm.sw(:t0, port, :t1)
              asm.li(:t0, SCREEN_SIZE)
              asm.sw(:t0, port, :t1)
              (places.length - 1).downto(0) do |plane|
                state = at.call(PLANES) + (plane * PLANE_BYTES)
                skip = "rt_tiles_draw_not_#{plane}"
                asm.lw(:t0, state + PLANE_UP, :gp)
                asm.beq(:t0, :zero, skip)
                asm.li(:a0, plane_draw_mode(places.fetch(plane)))
                asm.jal("rt_gp0_word")
                asm.jal("rt_gp0_word") { asm.lui(:a0, h::GP0_TEXTURED_RECTANGLE >> 16) }
                asm.lw(:t0, page, :gp)
                asm.sll(:t0, :t0, 16)
                asm.sw(:t0, port, :t1)
                asm.lw(:t2, state + PLANE_SCROLL_Y, :gp)
                asm.lw(:t3, state + PLANE_SCROLL_X, :gp)
                asm.andi(:t2, :t2, PLANE_SIDE - 1)
                asm.sll(:t2, :t2, 8)
                asm.andi(:t3, :t3, PLANE_SIDE - 1)
                asm.or(:t2, :t2, :t3)
                asm.sw(:t2, port, :t1)
                asm.li(:t0, SCREEN_SIZE)
                asm.sw(:t0, port, :t1)
                asm.label(skip)
              end
              drawn = at.call(DRAWN)
              asm.lw(:s0, drawn, :gp)
              asm.addiu(:s1, :gp, drawn + 4)
              asm.label("rt_tiles_draw_sprite")
              asm.beq(:s0, :zero, "rt_tiles_draw_end")
              asm.lw(:t0, DRAWN_PICTURE, :s1)
              asm.la(:t1, SPRITE_PICTURES)
              asm.sll(:t0, :t0, 2)
              asm.addu(:t0, :t0, :t1)
              asm.lw(:a0, 0, :t0)
              asm.lw(:a1, DRAWN_X, :s1)
              asm.lw(:a2, DRAWN_Y, :s1)
              asm.jal("rt_paint_blit")
              asm.addiu(:s1, :s1, DRAWN_BYTES)
              asm.b("rt_tiles_draw_sprite") { asm.addiu(:s0, :s0, -1) }
              asm.label("rt_tiles_draw_end")
              asm.lw(:ra, 0, :sp)
              asm.lw(:s0, 4, :sp)
              asm.lw(:s1, 8, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 12) }
            end

            # The draw mode naming the texture page of the plane whose corner is +place+, at 15 bits.
            def plane_draw_mode((x, y))
              h = Console::PS1Hardware
              h::GP0_DRAW_MODE | (x / TextureMemory::PAGE_STEP_HALFWORDS) | ((y / TextureMemory::PAGE_TEXELS) << 4) |
                h::TEXTURE_15_BIT | h::DRAW_ON_SHOWN_PICTURE
            end

            # rt_plane_places: each plane's corner in video RAM, y << 16 | x, a word each.
            def emit_plane_tables(asm, places)
              asm.label("rt_plane_places")
              asm.data_words(places.map { |x, y| (y << 16) | x })
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
