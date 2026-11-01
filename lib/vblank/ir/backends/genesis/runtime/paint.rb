# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # A PAINTED SCREEN, as a Genesis keeps one: the interpreter's `screen :bitmap` is a grid of
          # colours the game changes pixel by pixel, and a Genesis has no such screen. Every picture it
          # shows is tiles, so a painted screen is a screen of tiles that happens to have a different
          # one in every place: 40 across and 28 down, 1120 tiles, each 8×8 pixels of four bits.
          #
          # THE PICTURE IS KEPT IN WORK RAM, in the form the video chip keeps a tile in (SCREEN): a
          # tile is 32 bytes, a row of eight pixels is four of them, and a byte is two pixels, the left
          # one in the top four bits. The tiles follow each other across the screen and then down, so the
          # picture is one run of 35,840 bytes that is copied to the same bytes in video RAM. Painting is
          # work done on that copy, and what it changes is noted a tile at a time (DIRTY), so a pass
          # that changed two tiles copies two tiles in the blank after it (rt_upload) and a whole
          # picture is copied only while the screen is still off (rt_upload_whole).
          #
          # THE COLOURS. A tile's pixel is four bits, a place in a list of sixteen colours, and the first
          # is see-through. So a painted screen shows up to fifteen colours and black: black is place 0,
          # which is see-through on the plane, and shows the backdrop, which is black too. Which place
          # is which colour is the game's (SNES::PaintedArt's way, Genesis::PaintedArt): every colour the
          # game can paint is known as it is built, and the code paints a place.
          #
          # THE ROUTINES take their numbers in D0, D1, D2... and are reached with JSR. Every one holds
          # painting to the area the game has opened (`inside`, AREA: a left, a top, a right and a
          # bottom, each a word, the screen's own to begin with).
          module Paint
            ACROSS = 40 # tiles
            DOWN = 28
            TILES = ACROSS * DOWN
            TILE_BYTES = 32
            SCREEN_BYTES = TILES * TILE_BYTES
            ROW_BYTES = ACROSS * TILE_BYTES # a row of tiles
            WIDTH = ACROSS * 8
            HEIGHT = DOWN * 8
            # What a picture's pixel holds where it is see-through.
            NOT_DRAWN = 0xFF

            # Where tile 1 is in video RAM: tile 0 is kept blank, so a map that names no tile shows nothing.
            FIRST_TILE_AT = TILE_BYTES

            SCREEN = "rt paint screen"
            DIRTY = "rt paint dirty"
            ANY_DIRTY = "rt paint any dirty"
            AREA = "rt paint area"
            COLORS = "rt paint colors"

            # The two bytes of work the fill keeps its colour in: the colour in a pixel's low four bits,
            # in its top four, and in both.
            SCRATCH = "rt paint scratch"
            LOW = 0
            HIGH = 1
            BOTH = 2

            # Each of the area's four words, by where it is.
            AREA_LEFT = 0
            AREA_TOP = 2
            AREA_RIGHT = 4
            AREA_BOTTOM = 6
            AREA_BYTES = 8

            module_function

            # The picture takes the top of work RAM below the stack, as one place that needs to be near
            # nothing; the rest are small.
            def reserve(memory)
              memory.reserve_last(SCREEN, SCREEN_BYTES)
              memory.reserve_last(DIRTY, TILES)
              memory.reserve(ANY_DIRTY, 2)
              memory.reserve(AREA, AREA_BYTES)
              memory.reserve(SCRATCH, 4)
              memory.reserve(CAMERA, 4)
            end

            # +patches+ is how many places the game keeps a patch of the screen in (SaveRegion).
            def emit(asm, memory, camera: false, colors: false)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              emit_start(asm, memory, at, colors: colors)
              emit_upload(asm, memory, at, camera: camera, colors: colors)
              emit_camera(asm, at) if camera
              emit_clear(asm, memory, at)
              emit_area(asm, at)
              emit_fill(asm, memory, at)
              emit_plot(asm, memory, at)
              emit_blit(asm, memory, at)
              emit_patches(asm, memory, at)
            end

            # rt_picture_start: the area the screen's own; the colours of the painted screen into the
            # colour memory; the map of the screen's plane, which names the tiles in the order they
            # come (tile 1 first) and is the same for ever; and every patch of the screen kept for
            # the game made empty. Done with the screen off, so none of it is seen.
            def emit_start(asm, memory, at, colors: false)
              h = Console::GenesisHardware
              asm.label("rt_picture_start")
              asm.move(:w, asm.imm(0), at.call(AREA, AREA_LEFT))
              asm.move(:w, asm.imm(0), at.call(AREA, AREA_TOP))
              asm.move(:w, asm.imm(WIDTH), at.call(AREA, AREA_RIGHT))
              asm.move(:w, asm.imm(HEIGHT), at.call(AREA, AREA_BOTTOM))
              asm.move(:l, asm.imm(h.command(h::WRITE_CRAM, 0)), asm.abs_l(h::VDP_CONTROL))
              asm.lea(asm.abs_l("paint colors"), asm.a(0))
              asm.move(:w, asm.imm(15), asm.d(1))
              asm.label("rt_picture_start_color")
              asm.move(:w, asm.post(0), asm.abs_l(h::VDP_DATA))
              asm.dbra(asm.d(1), "rt_picture_start_color")
              asm.jsr(asm.abs_l("rt_colors_start")) if colors
              asm.move(:l, asm.imm(h.command(h::WRITE_VRAM, MAP_AT)), asm.abs_l(h::VDP_CONTROL))
              asm.moveq(0, asm.d(0))
              asm.moveq(1, asm.d(1))
              asm.move(:w, asm.imm(DOWN - 1), asm.d(2))
              asm.label("rt_picture_start_row")
              asm.move(:w, asm.imm(ACROSS - 1), asm.d(3))
              asm.label("rt_picture_start_cell")
              asm.move(:w, asm.d(1), asm.abs_l(h::VDP_DATA))
              asm.addq(:w, 1, asm.d(1))
              asm.dbra(asm.d(3), "rt_picture_start_cell")
              asm.move(:w, asm.imm(MAP_ACROSS - ACROSS - 1), asm.d(3))
              asm.label("rt_picture_start_blank")
              asm.move(:w, asm.d(0), asm.abs_l(h::VDP_DATA))
              asm.dbra(asm.d(3), "rt_picture_start_blank")
              asm.dbra(asm.d(2), "rt_picture_start_row")
              emit_patches_emptied(asm)
              asm.rts

              asm.label("rt_picture_prepare")
              asm.rts
              asm.label("rt_tint_prepare")
              asm.jmp(asm.abs_l("rt_colors_prepared")) if colors
              asm.rts unless colors
            end

            # Where plane A's map is in video RAM, and how many cells across it is (64, whatever shows).
            MAP_AT = 0xC000
            MAP_ACROSS = 64

            # Every patch the game keeps (the table "paint patches": each a place and a size, both
            # longs, and a place of nought after the last) made empty, every byte NOT_DRAWN.
            def emit_patches_emptied(asm)
              asm.lea(asm.abs_l("paint patches"), asm.a(1))
              asm.label("rt_picture_start_patch")
              asm.move(:l, asm.post(1), asm.d(0))
              asm.branch(:eq, "rt_picture_start_patched")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.move(:l, asm.post(1), asm.d(1))
              asm.label("rt_picture_start_patch_byte")
              asm.move(:b, asm.imm(NOT_DRAWN), asm.post(0))
              asm.subq(:l, 1, asm.d(1))
              asm.branch(:ne, "rt_picture_start_patch_byte")
              asm.bra("rt_picture_start_patch")
              asm.label("rt_picture_start_patched")
            end

            # THE CAMERA (`camera x, y`, Reference#exec_camera) moves the window over the picture, which on a
            # Genesis is moving the plane that shows it: its horizontal and vertical scroll, written in the
            # blank with the tiles. The plane is 64 cells across and 32 down and the picture 40 and 28, so
            # the cells past the picture are empty and show the backdrop as the interpreter does, for a
            # window as far out as the plane goes: 192 pixels across (64 less 40 cells) and 32 down. Past
            # that the plane would come round to the picture again, so the camera is held there.
            #
            # rt_camera_to(x, y): the window's corner, held within what the plane can show.
            # rt_camera_written: the scroll registers made to say it.
            CAMERA = "rt camera" # the window's corner, a word each: across, then down
            CAMERA_ACROSS = 192
            CAMERA_DOWN = 32

            def emit_camera(asm, at)
              h = Console::GenesisHardware
              asm.label("rt_camera_to")
              [[0, CAMERA_ACROSS, 0], [1, CAMERA_DOWN, 2]].each do |register, most, place|
                kept = "rt_camera_to_#{place}"
                asm.cmp(:l, asm.imm(most), asm.d(register))
                asm.branch(:le, "#{kept}_low")
                asm.move(:l, asm.imm(most), asm.d(register))
                asm.label("#{kept}_low")
                asm.cmp(:l, asm.imm(-most), asm.d(register))
                asm.branch(:ge, "#{kept}_set")
                asm.move(:l, asm.imm(-most), asm.d(register))
                asm.label("#{kept}_set")
                asm.move(:w, asm.d(register), at.call(CAMERA, place))
              end
              asm.rts

              asm.label("rt_camera_written")
              asm.move(:l, asm.imm(h.command(h::WRITE_VRAM, Tiles::HSCROLL_AT)), asm.abs_l(h::VDP_CONTROL))
              asm.move(:w, at.call(CAMERA, 0), asm.d(0))
              asm.neg(:w, asm.d(0))
              asm.and(:w, asm.imm(0x3FF), asm.d(0))
              asm.move(:w, asm.d(0), asm.abs_l(h::VDP_DATA))
              asm.move(:l, asm.imm(h.command(h::WRITE_VSRAM, 0)), asm.abs_l(h::VDP_CONTROL))
              asm.move(:w, at.call(CAMERA, 2), asm.d(0))
              asm.and(:w, asm.imm(0x3FF), asm.d(0))
              asm.move(:w, asm.d(0), asm.abs_l(h::VDP_DATA))
              asm.rts
            end

            # rt_upload: every tile marked as changed copied to video RAM, in the blank, and its mark
            # taken off. The marks are looked at four at a time, so a pass that changed nothing near
            # most of the screen skips most of it in a few instructions. rt_upload_whole: the whole
            # picture, while the screen is still off.
            def emit_upload(asm, memory, at, camera: false, colors: false)
              h = Console::GenesisHardware
              asm.label("rt_upload")
              asm.jsr(asm.abs_l("rt_camera_written")) if camera
              asm.jsr(asm.abs_l("rt_colors_written")) if colors
              asm.tst(:w, at.call(ANY_DIRTY))
              asm.branch(:eq, "rt_upload_done")
              asm.clr(:w, at.call(ANY_DIRTY))
              asm.lea(asm.abs_l(memory[DIRTY]), asm.a(1))
              asm.moveq(0, asm.d(6)) # the first tile of the four looked at
              asm.move(:w, asm.imm(TILES / 4 - 1), asm.d(7))
              asm.label("rt_upload_group")
              asm.tst(:l, asm.ind(1))
              asm.branch(:eq, "rt_upload_group_clean")
              asm.moveq(3, asm.d(5))
              asm.label("rt_upload_tile")
              asm.tst(:b, asm.ind(1))
              asm.branch(:eq, "rt_upload_tile_clean")
              asm.clr(:b, asm.ind(1))
              asm.jsr(asm.abs_l("rt_upload_one"))
              asm.label("rt_upload_tile_clean")
              asm.addq(:l, 1, asm.a(1))
              asm.addq(:l, 1, asm.d(6))
              asm.dbra(asm.d(5), "rt_upload_tile")
              asm.bra("rt_upload_group_next")
              asm.label("rt_upload_group_clean")
              asm.addq(:l, 4, asm.a(1))
              asm.addq(:l, 4, asm.d(6))
              asm.label("rt_upload_group_next")
              asm.dbra(asm.d(7), "rt_upload_group")
              asm.label("rt_upload_done")
              asm.rts

              # rt_upload_one: tile D6 (counted from nought) of the copy into video RAM, 32 bytes.
              asm.label("rt_upload_one")
              asm.move(:l, asm.d(6), asm.d(0))
              asm.lsl(:l, 5, asm.d(0)) # the tile's place in the copy, and in video RAM past tile 0
              asm.lea(asm.abs_l(memory[SCREEN]), asm.a(0))
              asm.add(:l, asm.d(0), asm.a(0))
              asm.add(:l, asm.imm(FIRST_TILE_AT), asm.d(0))
              asm.move(:l, asm.d(0), asm.d(1))
              asm.and(:l, asm.imm(0x3FFF), asm.d(1))
              asm.swap(asm.d(1))
              asm.lsr(:l, 8, asm.d(0))
              asm.lsr(:l, 6, asm.d(0))
              asm.or(:l, asm.d(0), asm.d(1))
              asm.or(:l, asm.imm(h::WRITE_VRAM), asm.d(1))
              asm.move(:l, asm.d(1), asm.abs_l(h::VDP_CONTROL))
              8.times { asm.move(:l, asm.post(0), asm.abs_l(h::VDP_DATA)) }
              asm.rts

              asm.label("rt_upload_whole")
              asm.jsr(asm.abs_l("rt_camera_written")) if camera
              asm.jsr(asm.abs_l("rt_colors_written")) if colors
              asm.move(:l, asm.imm(h.command(h::WRITE_VRAM, FIRST_TILE_AT)), asm.abs_l(h::VDP_CONTROL))
              asm.lea(asm.abs_l(memory[SCREEN]), asm.a(0))
              asm.move(:w, asm.imm(SCREEN_BYTES / 4 - 1), asm.d(0))
              asm.label("rt_upload_whole_long")
              asm.move(:l, asm.post(0), asm.abs_l(h::VDP_DATA))
              asm.dbra(asm.d(0), "rt_upload_whole_long")
              emit_dirty_cleared(asm, memory, at)
              asm.rts
            end

            # Every mark taken off, for the copy the whole picture made.
            def emit_dirty_cleared(asm, memory, at)
              asm.lea(asm.abs_l(memory[DIRTY], TILES), asm.a(0))
              asm.moveq(0, asm.d(0))
              asm.move(:w, asm.imm(TILES / 4 - 1), asm.d(1))
              asm.label("rt_upload_whole_clean")
              asm.move(:l, asm.d(0), asm.pre(0))
              asm.dbra(asm.d(1), "rt_upload_whole_clean")
              asm.clr(:w, at.call(ANY_DIRTY))
            end

            # rt_paint_clear(color): the whole screen one colour — or, where painting is held to an
            # area, that and no more. The whole screen is the colour's four bits repeated through
            # the copy, eight longs at a time, and every tile marked as changed.
            def emit_clear(asm, memory, at)
              asm.label("rt_paint_clear")
              asm.tst(:w, at.call(AREA, AREA_LEFT))
              asm.branch(:ne, "rt_paint_clear_area")
              asm.tst(:w, at.call(AREA, AREA_TOP))
              asm.branch(:ne, "rt_paint_clear_area")
              asm.cmp(:w, asm.imm(WIDTH), at.call(AREA, AREA_RIGHT))
              asm.branch(:ne, "rt_paint_clear_area")
              asm.cmp(:w, asm.imm(HEIGHT), at.call(AREA, AREA_BOTTOM))
              asm.branch(:ne, "rt_paint_clear_area")
              asm.and(:l, asm.imm(0xF), asm.d(0))
              asm.mulu(asm.imm(0x1111), asm.d(0))
              asm.move(:l, asm.d(0), asm.d(1))
              asm.swap(asm.d(1))
              asm.or(:l, asm.d(1), asm.d(0)) # the colour in all eight nibbles
              (1..7).each { |register| asm.move(:l, asm.d(0), asm.d(register)) }
              asm.movea(:l, asm.d(0), asm.a(1))
              asm.lea(asm.abs_l(memory[SCREEN], SCREEN_BYTES), asm.a(0))
              asm.move(:w, asm.imm(TILES - 1), asm.d(0))
              asm.label("rt_paint_clear_tile")
              asm.movem_push(:l, :d1, :d2, :d3, :d4, :d5, :d6, :d7, :a1, via: 0)
              asm.dbra(asm.d(0), "rt_paint_clear_tile")
              asm.lea(asm.abs_l(memory[DIRTY], TILES), asm.a(0))
              asm.move(:l, asm.imm(0x01010101), asm.d(0))
              asm.move(:w, asm.imm(TILES / 4 - 1), asm.d(1))
              asm.label("rt_paint_clear_mark")
              asm.move(:l, asm.d(0), asm.pre(0))
              asm.dbra(asm.d(1), "rt_paint_clear_mark")
              asm.move(:w, asm.imm(1), at.call(ANY_DIRTY))
              asm.rts

              asm.label("rt_paint_clear_area")
              asm.move(:l, asm.d(0), asm.d(4))
              asm.move(:w, at.call(AREA, AREA_LEFT), asm.d(0))
              asm.ext(:l, asm.d(0))
              asm.move(:w, at.call(AREA, AREA_TOP), asm.d(1))
              asm.ext(:l, asm.d(1))
              asm.move(:w, at.call(AREA, AREA_RIGHT), asm.d(2))
              asm.ext(:l, asm.d(2))
              asm.sub(:l, asm.d(0), asm.d(2))
              asm.move(:w, at.call(AREA, AREA_BOTTOM), asm.d(3))
              asm.ext(:l, asm.d(3))
              asm.sub(:l, asm.d(1), asm.d(3))
              asm.jmp(asm.abs_l("rt_paint_fill"))
            end

            # rt_paint_area(x, y, w, h): painting held to that rectangle, held to the screen, from now
            # on. The area is a left, a top, a right and a bottom, each kept between 0 and the screen's
            # edge, so a rectangle with nothing on the screen is an empty one.
            def emit_area(asm, at)
              asm.label("rt_paint_area")
              asm.add(:l, asm.d(0), asm.d(2))
              asm.add(:l, asm.d(1), asm.d(3))
              [[0, WIDTH, AREA_LEFT], [1, HEIGHT, AREA_TOP], [2, WIDTH, AREA_RIGHT], [3, HEIGHT, AREA_BOTTOM]].each do |register, most, place|
                low = "rt_paint_area_low_#{place}"
                high = "rt_paint_area_high_#{place}"
                asm.tst(:l, asm.d(register))
                asm.branch(:pl, low)
                asm.moveq(0, asm.d(register))
                asm.label(low)
                asm.cmp(:l, asm.imm(most), asm.d(register))
                asm.branch(:le, high)
                asm.move(:l, asm.imm(most), asm.d(register))
                asm.label(high)
                asm.move(:w, asm.d(register), at.call(AREA, place))
              end
              asm.rts
            end

            # rt_paint_fill(x, y, w, h, color): the rectangle painted, held to the area. The picture is
            # worked a row at a time, and a row two pixels at a time (a byte): the odd pixel at its
            # start by itself, then whole bytes, then the odd pixel at its end.
            def emit_fill(asm, memory, at)
              asm.label("rt_paint_fill")
              asm.add(:l, asm.d(0), asm.d(2)) # the right edge
              asm.add(:l, asm.d(1), asm.d(3)) # the bottom edge
              emit_clip(asm, at)
              asm.cmp(:l, asm.d(2), asm.d(0))
              asm.branch(:ge, "rt_paint_fill_done")
              asm.cmp(:l, asm.d(3), asm.d(1))
              asm.branch(:ge, "rt_paint_fill_done")
              emit_colors_kept(asm, at)
              asm.jsr(asm.abs_l("rt_paint_mark"))
              asm.move(:l, asm.d(1), asm.d(5)) # the row
              asm.label("rt_paint_fill_row")
              emit_row_base(asm, memory)
              asm.move(:l, asm.d(0), asm.d(6)) # the pixel
              asm.btst(0, asm.d(6))
              asm.branch(:eq, "rt_paint_fill_pairs")
              emit_byte_address(asm)
              asm.and(:b, asm.imm(0xF0), asm.ind(2))
              asm.move(:b, at.call(SCRATCH, LOW), asm.d(1))
              asm.or(:b, asm.d(1), asm.ind(2))
              asm.addq(:l, 1, asm.d(6))
              asm.label("rt_paint_fill_pairs")
              asm.move(:l, asm.d(6), asm.d(1))
              asm.addq(:l, 1, asm.d(1))
              asm.cmp(:l, asm.d(2), asm.d(1))
              asm.branch(:ge, "rt_paint_fill_tail")
              emit_byte_address(asm)
              asm.move(:b, at.call(SCRATCH, BOTH), asm.ind(2))
              asm.addq(:l, 2, asm.d(6))
              asm.bra("rt_paint_fill_pairs")
              asm.label("rt_paint_fill_tail")
              asm.cmp(:l, asm.d(2), asm.d(6))
              asm.branch(:ge, "rt_paint_fill_next")
              emit_byte_address(asm)
              asm.and(:b, asm.imm(0x0F), asm.ind(2))
              asm.move(:b, at.call(SCRATCH, HIGH), asm.d(1))
              asm.or(:b, asm.d(1), asm.ind(2))
              asm.label("rt_paint_fill_next")
              asm.addq(:l, 1, asm.d(5))
              asm.cmp(:l, asm.d(3), asm.d(5))
              asm.branch(:lt, "rt_paint_fill_row")
              asm.label("rt_paint_fill_done")
              asm.rts

              emit_mark(asm, memory, at)
            end

            # The rectangle in D0 (left), D1 (top), D2 (right) and D3 (bottom) held to the area.
            def emit_clip(asm, at)
              [[0, AREA_LEFT, :ge], [1, AREA_TOP, :ge], [2, AREA_RIGHT, :le], [3, AREA_BOTTOM, :le]].each do |register, place, keeps|
                kept = "rt_paint_clip_#{place}"
                asm.move(:w, at.call(AREA, place), asm.d(5))
                asm.ext(:l, asm.d(5))
                asm.cmp(:l, asm.d(5), asm.d(register))
                asm.branch(keeps, kept)
                asm.move(:l, asm.d(5), asm.d(register))
                asm.label(kept)
              end
            end

            # The colour in D4 kept as the four bits, as the top four, and as both pixels of a byte.
            def emit_colors_kept(asm, at)
              asm.and(:b, asm.imm(0xF), asm.d(4))
              asm.move(:b, asm.d(4), at.call(SCRATCH, LOW))
              asm.move(:b, asm.d(4), asm.d(5))
              asm.lsl(:b, 4, asm.d(5))
              asm.move(:b, asm.d(5), at.call(SCRATCH, HIGH))
              asm.or(:b, asm.d(4), asm.d(5))
              asm.move(:b, asm.d(5), at.call(SCRATCH, BOTH))
            end

            # A1 = where row D5 starts in the copy: its row of tiles, and the row inside the tile.
            def emit_row_base(asm, memory)
              asm.move(:l, asm.d(5), asm.d(7))
              asm.lsr(:l, 3, asm.d(7))
              asm.mulu(asm.imm(ROW_BYTES), asm.d(7))
              asm.move(:l, asm.d(5), asm.d(1))
              asm.and(:l, asm.imm(7), asm.d(1))
              asm.lsl(:l, 2, asm.d(1))
              asm.add(:l, asm.d(1), asm.d(7))
              asm.movea(:l, asm.imm(memory[SCREEN]), asm.a(1))
              asm.add(:l, asm.d(7), asm.a(1))
            end

            # A2 = the byte of the copy that pixel D6 of the row A1 starts is in. A byte is two pixels, a
            # tile row four bytes, a tile 32: with b the pixel's byte in its row, tile (b >> 2) × 32
            # plus b & 3.
            def emit_byte_address(asm)
              asm.move(:l, asm.d(6), asm.d(7))
              asm.lsr(:l, 1, asm.d(7))
              asm.move(:l, asm.d(7), asm.d(1))
              asm.and(:l, asm.imm(3), asm.d(1))
              asm.lsr(:l, 2, asm.d(7))
              asm.lsl(:l, 5, asm.d(7))
              asm.add(:l, asm.d(1), asm.d(7))
              asm.lea(asm.idx(1, 0, 7), asm.a(2))
            end

            # rt_paint_mark: every tile the rectangle D0 (left), D1 (top), D2 (right), D3 (bottom) touches
            # marked as changed. Keeps D0 to D3.
            def emit_mark(asm, memory, at)
              asm.label("rt_paint_mark")
              asm.move(:l, asm.d(0), asm.d(5))
              asm.lsr(:l, 3, asm.d(5)) # the first tile across
              asm.move(:l, asm.d(2), asm.d(6))
              asm.subq(:l, 1, asm.d(6))
              asm.lsr(:l, 3, asm.d(6))
              asm.sub(:l, asm.d(5), asm.d(6)) # how many more across
              asm.move(:l, asm.d(1), asm.d(7))
              asm.lsr(:l, 3, asm.d(7)) # the first tile down
              asm.move(:l, asm.d(3), asm.d(4))
              asm.subq(:l, 1, asm.d(4))
              asm.lsr(:l, 3, asm.d(4))
              asm.sub(:l, asm.d(7), asm.d(4)) # how many more down
              asm.mulu(asm.imm(ACROSS), asm.d(7))
              asm.add(:l, asm.d(5), asm.d(7))
              asm.lea(asm.abs_l(memory[DIRTY]), asm.a(2))
              asm.add(:l, asm.d(7), asm.a(2))
              asm.label("rt_paint_mark_row")
              asm.move(:w, asm.d(6), asm.d(7))
              asm.movea(:l, asm.a(2), asm.a(3))
              asm.label("rt_paint_mark_tile")
              asm.move(:b, asm.imm(1), asm.post(3))
              asm.dbra(asm.d(7), "rt_paint_mark_tile")
              asm.lea(asm.disp(2, ACROSS), asm.a(2))
              asm.dbra(asm.d(4), "rt_paint_mark_row")
              asm.move(:w, asm.imm(1), at.call(ANY_DIRTY))
              asm.rts
            end

            # rt_paint_plot(x, y, color): one pixel of the copy set, and its tile marked as changed. The
            # caller has seen to the area. Uses D3, D4, A2 and A3.
            def emit_plot(asm, memory, at)
              asm.label("rt_paint_plot")
              asm.move(:l, asm.d(1), asm.d(3))
              asm.lsr(:l, 3, asm.d(3))
              asm.mulu(asm.imm(ACROSS), asm.d(3)) # the tile's row, counted in tiles
              asm.move(:l, asm.d(0), asm.d(4))
              asm.lsr(:l, 3, asm.d(4))
              asm.add(:l, asm.d(4), asm.d(3)) # the tile, counted from nought
              asm.lea(asm.abs_l(memory[DIRTY]), asm.a(3))
              asm.move(:b, asm.imm(1), asm.idx(3, 0, 3))
              asm.move(:w, asm.imm(1), at.call(ANY_DIRTY))
              asm.lsl(:l, 5, asm.d(3)) # ...and its place in the copy
              asm.move(:l, asm.d(1), asm.d(4))
              asm.and(:l, asm.imm(7), asm.d(4))
              asm.lsl(:l, 2, asm.d(4))
              asm.add(:l, asm.d(4), asm.d(3)) # the row inside the tile
              asm.move(:l, asm.d(0), asm.d(4))
              asm.lsr(:l, 1, asm.d(4))
              asm.and(:l, asm.imm(3), asm.d(4))
              asm.add(:l, asm.d(4), asm.d(3)) # the byte inside the row
              asm.movea(:l, asm.imm(memory[SCREEN]), asm.a(2))
              asm.add(:l, asm.d(3), asm.a(2))
              asm.btst(0, asm.d(0))
              asm.branch(:ne, "rt_paint_plot_right")
              asm.and(:b, asm.imm(0x0F), asm.ind(2))
              asm.move(:b, asm.d(2), asm.d(3))
              asm.lsl(:b, 4, asm.d(3))
              asm.or(:b, asm.d(3), asm.ind(2))
              asm.rts
              asm.label("rt_paint_plot_right")
              asm.and(:b, asm.imm(0xF0), asm.ind(2))
              asm.or(:b, asm.d(2), asm.ind(2))
              asm.rts
            end

            # rt_paint_read(x, y): D2 = the colour of that pixel of the copy. Uses D3, D4 and A2.
            def emit_read(asm, memory)
              asm.label("rt_paint_read")
              asm.move(:l, asm.d(1), asm.d(3))
              asm.lsr(:l, 3, asm.d(3))
              asm.mulu(asm.imm(ROW_BYTES), asm.d(3))
              asm.move(:l, asm.d(1), asm.d(4))
              asm.and(:l, asm.imm(7), asm.d(4))
              asm.lsl(:l, 2, asm.d(4))
              asm.add(:l, asm.d(4), asm.d(3))
              asm.move(:l, asm.d(0), asm.d(4))
              asm.lsr(:l, 3, asm.d(4))
              asm.lsl(:l, 5, asm.d(4))
              asm.add(:l, asm.d(4), asm.d(3))
              asm.move(:l, asm.d(0), asm.d(4))
              asm.lsr(:l, 1, asm.d(4))
              asm.and(:l, asm.imm(3), asm.d(4))
              asm.add(:l, asm.d(4), asm.d(3))
              asm.movea(:l, asm.imm(memory[SCREEN]), asm.a(2))
              asm.add(:l, asm.d(3), asm.a(2))
              asm.moveq(0, asm.d(2))
              asm.move(:b, asm.ind(2), asm.d(2))
              asm.btst(0, asm.d(0))
              asm.branch(:ne, "rt_paint_read_right")
              asm.lsr(:b, 4, asm.d(2))
              asm.label("rt_paint_read_right")
              asm.and(:l, asm.imm(0xF), asm.d(2))
              asm.rts
            end

            # rt_paint_blit(picture, x, y): picture number D0 drawn with its top-left at (x, y), pixel
            # by pixel: a pixel that is not drawn (NOT_DRAWN) leaves what is under it, and one outside
            # the area is not painted. rt_paint_blit_one_of(list, index, x, y): one of the pictures of
            # list D0, the one at index D1, or none for an index outside it. The pictures are the
            # table "paint pictures" (each a place, a width and a height) and the lists the table
            # "paint picture lists" (each a place, whose words are the count and the numbers).
            def emit_blit(asm, memory, at)
              emit_read(asm, memory)
              asm.label("rt_paint_blit_one_of")
              asm.lea(asm.abs_l("paint picture lists"), asm.a(0))
              asm.lsl(:l, 2, asm.d(0))
              asm.movea(:l, asm.idx(0, 0, 0), asm.a(0))
              asm.moveq(0, asm.d(4))
              asm.move(:w, asm.post(0), asm.d(4)) # how many pictures
              asm.cmp(:l, asm.d(4), asm.d(1))
              asm.branch(:cc, "rt_paint_blit_none") # an index below nought is a huge one
              asm.lsl(:l, 1, asm.d(1))
              asm.moveq(0, asm.d(0))
              asm.move(:w, asm.idx(0, 0, 1), asm.d(0))
              asm.move(:l, asm.d(2), asm.d(1))
              asm.move(:l, asm.d(3), asm.d(2))
              asm.bra("rt_paint_blit")
              asm.label("rt_paint_blit_none")
              asm.rts

              asm.label("rt_paint_blit")
              asm.lea(asm.abs_l("paint pictures"), asm.a(0))
              asm.lsl(:l, 3, asm.d(0))
              asm.add(:l, asm.d(0), asm.a(0))
              asm.movea(:l, asm.post(0), asm.a(1)) # the picture's pixels
              asm.moveq(0, asm.d(7))
              asm.move(:w, asm.post(0), asm.d(7)) # its width
              asm.moveq(0, asm.d(5))
              asm.move(:w, asm.ind(0), asm.d(5)) # its height
              asm.subq(:w, 1, asm.d(5))
              asm.movea(:l, asm.d(1), asm.a(4)) # the left
              asm.movea(:l, asm.d(2), asm.a(6)) # the row it is at
              asm.label("rt_paint_blit_row")
              asm.moveq(0, asm.d(6))
              asm.label("rt_paint_blit_pixel")
              asm.move(:b, asm.post(1), asm.d(2))
              asm.and(:l, asm.imm(0xFF), asm.d(2))
              asm.cmp(:l, asm.imm(NOT_DRAWN), asm.d(2))
              asm.branch(:eq, "rt_paint_blit_skip")
              asm.move(:l, asm.a(4), asm.d(0))
              asm.add(:l, asm.d(6), asm.d(0))
              asm.move(:l, asm.a(6), asm.d(1))
              emit_inside_area(asm, at, "rt_paint_blit_skip")
              asm.jsr(asm.abs_l("rt_paint_plot"))
              asm.label("rt_paint_blit_skip")
              asm.addq(:l, 1, asm.d(6))
              asm.cmp(:l, asm.d(7), asm.d(6))
              asm.branch(:lt, "rt_paint_blit_pixel")
              asm.addq(:l, 1, asm.a(6))
              asm.dbra(asm.d(5), "rt_paint_blit_row")
              asm.rts
            end

            # A jump to +outside+ unless the pixel (D0, D1) is inside the area. Uses D3.
            def emit_inside_area(asm, at, outside)
              [[0, AREA_LEFT, :lt], [0, AREA_RIGHT, :ge], [1, AREA_TOP, :lt], [1, AREA_BOTTOM, :ge]].each do |register, place, leaves|
                asm.move(:w, at.call(AREA, place), asm.d(3))
                asm.ext(:l, asm.d(3))
                asm.cmp(:l, asm.d(3), asm.d(register))
                asm.branch(leaves, outside)
              end
            end

            # rt_paint_save(place, x, y, w, h): the patch of the screen at (x, y), w by h, kept at +place+, a
            # byte a pixel, its colour or NOT_DRAWN where it is off the screen. rt_paint_restore(place,
            # x, y, w, h): a kept patch painted back, a pixel it holds nothing for left alone, and
            # painting held to the area as it is anywhere.
            def emit_patches(asm, memory, at)
              [["rt_paint_save", false], ["rt_paint_restore", true]].each do |label, restoring|
                asm.label(label)
                asm.movea(:l, asm.d(0), asm.a(0)) # the patch
                asm.move(:l, asm.d(3), asm.d(7)) # its width
                asm.move(:l, asm.d(4), asm.d(5))
                asm.subq(:l, 1, asm.d(5)) # rows left, less one
                asm.branch(:mi, "#{label}_done")
                asm.movea(:l, asm.d(1), asm.a(4))
                asm.movea(:l, asm.d(2), asm.a(6))
                asm.label("#{label}_row")
                asm.moveq(0, asm.d(6))
                asm.label("#{label}_pixel")
                asm.move(:l, asm.a(4), asm.d(0))
                asm.add(:l, asm.d(6), asm.d(0))
                asm.move(:l, asm.a(6), asm.d(1))
                restoring ? emit_restore_pixel(asm, at, label) : emit_save_pixel(asm, label)
                asm.addq(:l, 1, asm.d(6))
                asm.cmp(:l, asm.d(7), asm.d(6))
                asm.branch(:lt, "#{label}_pixel")
                asm.addq(:l, 1, asm.a(6))
                asm.dbra(asm.d(5), "#{label}_row")
                asm.label("#{label}_done")
                asm.rts
              end
            end

            # The pixel (D0, D1) into the patch at A0, or NOT_DRAWN where it is off the screen.
            def emit_save_pixel(asm, label)
              asm.move(:b, asm.imm(NOT_DRAWN), asm.d(2))
              asm.tst(:l, asm.d(0))
              asm.branch(:mi, "#{label}_kept")
              asm.tst(:l, asm.d(1))
              asm.branch(:mi, "#{label}_kept")
              asm.cmp(:l, asm.imm(WIDTH), asm.d(0))
              asm.branch(:ge, "#{label}_kept")
              asm.cmp(:l, asm.imm(HEIGHT), asm.d(1))
              asm.branch(:ge, "#{label}_kept")
              asm.jsr(asm.abs_l("rt_paint_read"))
              asm.label("#{label}_kept")
              asm.move(:b, asm.d(2), asm.post(0))
            end

            # The patch's next byte at A0 painted at the pixel (D0, D1), if it holds a colour and the
            # pixel is inside the area.
            def emit_restore_pixel(asm, at, label)
              asm.moveq(0, asm.d(2))
              asm.move(:b, asm.post(0), asm.d(2))
              asm.cmp(:l, asm.imm(NOT_DRAWN), asm.d(2))
              asm.branch(:eq, "#{label}_kept")
              emit_inside_area(asm, at, "#{label}_kept")
              asm.jsr(asm.abs_l("rt_paint_plot"))
              asm.label("#{label}_kept")
            end
          end
        end
      end
    end
  end
end
