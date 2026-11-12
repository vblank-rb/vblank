# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE PAINTED SCREEN: rectangles, pictures and the pages they are drawn into.
          #
          # WHERE THE PICTURE IS. The game's screen is the PlayStation's whole screen, 320 × 240
          # (Console::PLAYSTATION's screen size, which the interpreter plays too), and the picture is
          # that rectangle of video RAM at its top left, a 15-bit colour a pixel, red in the low five
          # bits: the interpreter's own colours, so a colour lands exactly. A tear-free screen keeps a
          # second page 256 lines down, at (0, 256), and draws into the one not shown (PAGE_Y holds
          # which); they trade places at the frame boundary (rt_paint_flip). Everything to the right of
          # x 320 holds the game's pictures (PS1::PaintedArt), and the 16 lines under each page their
          # colour tables (PS1::TextureMemory), copied in at power-on.
          #
          # HOW IT IS DRAWN. The graphics chip draws whatever reaches its GP0 port, a command at a time;
          # the painted screen's commands go into the list the DMA hands to it (Runtime::DrawList). A rectangle of one colour is one command (GP0 60h), and a picture is a
          # textured rectangle for each piece of it (GP0 65h), each texel's colour copied as it is, read
          # from the piece's colour table where it has one (PS1::TextureMemory). Neither is
          # dithered or blended, so the pixels are the colours the game named. The processor works out
          # what is inside the screen, and inside the area `inside` holds drawing to (AREA), before
          # anything is sent: the chip is given only the part that lands, so its own clipping is never
          # asked, and a number the game works out far off the screen never reaches the chip's 11-bit
          # corners.
          #
          # THE AREA is [left, top, right, bottom], the right and bottom one past the last pixel, kept
          # to the screen; the whole screen until `inside` sets another. A rectangle is kept to it as
          # the interpreter keeps every pixel it paints (Reference::Framebuffer#paintable?).
          module Paint
            AREA = "rt paint area"
            # Where each edge is in AREA, in bytes from its start.
            AREA_LEFT_OFFSET_BYTES = 0
            AREA_TOP_OFFSET_BYTES = 4
            AREA_RIGHT_OFFSET_BYTES = 8
            AREA_BOTTOM_OFFSET_BYTES = 12
            # The top line of the page drawn into: 0, or SECOND_PAGE_TOP_LINE on a tear-free screen.
            PAGE_Y = "rt paint page y"
            SECOND_PAGE_TOP_LINE = 256
            # 1 while the screen is tear-free, two pages.
            PAGED = "rt paint paged"
            # 1 when a pass's wait has ended and its page is to be shown (rt_paint_flip): a game that
            # halts shows the page it showed before, as the interpreter does.
            FLIP_OWED = "rt paint flip owed"
            # The top line of the page the last pass drew, kept as its wait begins, for a reader of the
            # run (PS1::HeadlessRun#read_picture_drawn).
            PASS_PAGE_Y = "rt paint pass page y"
            # The top line of the page the chip was last told to show (rt_paint_show_t0), and of the page
            # it showed as the last pass went on the screen (Frame#emit_show_pass): a reader holds the
            # first to the chip's own display start, and the second to the page the pass drew.
            SHOWN_PAGE_Y = "rt paint shown page y"
            PASS_SHOWN_PAGE_Y = "rt paint pass shown page y"

            # A SCREEN DRAWN BY NUMBER (PS1::PaintedNumbers) is drawn into the pages as any painted screen, and
            # shown from two pages of its own, right of them, from column PAGE_X: each pass's page is copied
            # there in its colours as the pass ends (rt_paint_numbers_shown), into the one not shown, which is
            # shown in the blank (SHOWN_COPY_PENDING). The copy reads the page through the colour table whose name
            # (TextureMemory::Table#field) is in NUMBERS_TABLE. PASS_PAGE_Y, SHOWN_PAGE_Y and PASS_SHOWN_PAGE_Y
            # then name the pages shown, from PAGE_X, which is where a reader reads them. A screen with sprites over
            # it is shown the same way (rt_paint_sprites_shown).
            PAGE_X = "rt paint page x"
            NUMBERS_TABLE = "rt paint numbers table"
            SHOWN_COPY_PENDING = "rt paint shown copy pending"
            # How wide a copy's piece is: half a texture page of bytes, its two triangles one texture page.
            NUMBERS_PIECE_PIXELS = 64

            # Each piece of a picture in the table PaintedArt writes: its place in the picture (two
            # halves), its size (two halves), the draw mode naming its texture page, and where in the
            # page it starts (v << 8 | u).
            PIECE_BYTES = 16

            module_function

            # +shown_apart+ for a screen shown from pages of its own (#shown_by).
            def reserve(memory, shown_apart: false)
              memory.reserve(AREA, 16)
              [PAGE_Y, PAGED, FLIP_OWED, PASS_PAGE_Y, SHOWN_PAGE_Y, PASS_SHOWN_PAGE_Y].each { |name| memory.reserve(name, 4) }
              [PAGE_X, NUMBERS_TABLE, SHOWN_COPY_PENDING].each { |name| memory.reserve(name, 4) } if shown_apart
            end

            # THE ROUTINE THAT COPIES A PASS'S PAGE ONTO THE PAGE SHOWN, for a painted screen shown from pages of its
            # own, from PAGE_X: a screen drawn by number (+by_number+, rt_paint_numbers_shown), or one with sprites
            # over it (+over_picture+, rt_paint_sprites_shown); nil for one shown from the pages it is drawn in.
            def shown_by(by_number:, over_picture:)
              raise LoweringError, "a painted screen drawn by number has no sprites over it" if by_number && over_picture
              return "rt_paint_numbers_shown" if by_number

              "rt_paint_sprites_shown" if over_picture
            end

            # +faces+ is whether the game fills the faces of a place, which leave the chip's drawing area
            # and texture window set for the next face (Faces#emit_chip_put_back_routine): then a fill and a
            # blit give the chip its own back first. +shown_by+ is #shown_by's routine, or nil.
            def emit(asm, memory, faces: false, shown_by: nil)
              at = ->(name) { Runtime.at(memory, name) }
              emit_start(asm, at)
              emit_area(asm, at)
              emit_fill(asm, at, faces)
              emit_blit(asm, at, faces)
              emit_pages(asm, at, !shown_by.nil?)
              emit_numbers_shown(asm, at) if shown_by == "rt_paint_numbers_shown"
              emit_sprites_shown(asm, at) if shown_by == "rt_paint_sprites_shown"
              emit_upload(asm)
              emit_patches(asm, at)
            end

            # SPRITES OVER THE PICTURE THE GAME PAINTS (`sprite ..., over_picture: true`) are drawn over it as it
            # goes to the screen and never into it (Reference#show_objects_over_picture): what the game paints stays
            # as it painted it, and a sprite that moves leaves nothing behind. So the screen is shown from pages of
            # its own, from PAGE_X, as one drawn by number is: as each pass ends its page is copied onto the page
            # shown that is not up, inside video RAM (GP0 80h), and the sprites the pass placed
            # (Runtime::Tiles::DRAWN) are drawn over the copy, the whole screen open to them, at the screen's own
            # places, which the chip's drawing offset (GP0 E5h) moves onto that page. The blank then shows it
            # (rt_paint_flip). A copy inside video RAM is the chip's alone: the processor touches no pixel.
            #
            # rt_paint_sprites_shown: a0 = the top line of the page drawn on to show. The area drawing is held to and
            # the page drawn on are given back as they were.
            SPRITES_SHOWN_KEPT = %i[s0 s1 s2 s3].freeze
            # The words kept on the stack besides the registers: the area's four, then PAGE_Y; and after them the page
            # drawn on.
            SPRITES_SHOWN_PUT_BACK = 5

            def emit_sprites_shown(asm, at)
              h = Console::PS1Hardware
              word = ->(index) { DrawList.word_offset_bytes(index) }
              drawn = at.call(Tiles::DRAWN)
              kept_bytes = 4 * (SPRITES_SHOWN_KEPT.length + 1)
              frame = kept_bytes + (4 * (SPRITES_SHOWN_PUT_BACK + 1))
              put_back = ->(i) { kept_bytes + (i * 4) }
              places = [AREA_LEFT_OFFSET_BYTES, AREA_TOP_OFFSET_BYTES, AREA_RIGHT_OFFSET_BYTES, AREA_BOTTOM_OFFSET_BYTES]
                       .map { |offset| at.call(AREA) + offset } + [at.call(PAGE_Y)]
              asm.label("rt_paint_sprites_shown")
              asm.addiu(:sp, :sp, -frame)
              asm.sw(:ra, 0, :sp)
              SPRITES_SHOWN_KEPT.each_with_index { |register, i| asm.sw(register, 4 + (i * 4), :sp) }
              places.each_with_index do |place, i|
                asm.lw(:t0, place, :gp)
                asm.sw(:t0, put_back.call(i), :sp)
              end
              # On a tear-free screen the sprites are placed again first, from the numbers the pass finished with
              # (Lowering::Picture#sprites_over_picture_section). The game's code changes the saved registers
              # without keeping them, so the page drawn on waits on the stack meanwhile.
              asm.sw(:a0, put_back.call(SPRITES_SHOWN_PUT_BACK), :sp)
              asm.lw(:t0, at.call(PAGED), :gp)
              asm.beq(:t0, :zero, "rt_paint_sprites_shown_placed")
              asm.jal(Lowering::Picture::SPRITES_OVER_PICTURE)
              asm.label("rt_paint_sprites_shown_placed")
              # s2: the page shown that is not up, its top line; s3: the page drawn on.
              asm.lw(:s3, put_back.call(SPRITES_SHOWN_PUT_BACK), :sp)
              asm.lw(:s2, at.call(SHOWN_PAGE_Y), :gp)
              asm.xori(:s2, :s2, SECOND_PAGE_TOP_LINE)
              asm.sw(:s2, at.call(PASS_PAGE_Y), :gp)
              DrawList.emit_command(asm, 4) { asm.lui(:a0, h::GP0_COPY_IN_VRAM >> 16) }
              asm.sll(:t0, :s3, 16)
              asm.sw(:t0, word.call(1), :t1)
              asm.lw(:t0, at.call(PAGE_X), :gp)
              asm.sll(:t2, :s2, 16)
              asm.or(:t0, :t0, :t2)
              asm.sw(:t0, word.call(2), :t1)
              asm.li(:t0, (h::SCREEN_HEIGHT << 16) | h::SCREEN_WIDTH)
              asm.sw(:t0, word.call(3), :t1)
              # The sprites, at the screen's places moved across onto the page shown, kept to the whole screen.
              asm.lw(:a0, at.call(PAGE_X), :gp)
              asm.lui(:t0, h::GP0_DRAWING_OFFSET >> 16)
              DrawList.emit_command(asm, 1) { asm.or(:a0, :a0, :t0) }
              asm.jal("rt_paint_start")
              asm.sw(:s2, at.call(PAGE_Y), :gp)
              asm.lw(:s0, drawn, :gp)
              asm.addiu(:s1, :gp, drawn + 4)
              asm.label("rt_paint_sprites_shown_next")
              asm.beq(:s0, :zero, "rt_paint_sprites_shown_end")
              asm.lw(:a0, Tiles::DRAWN_ART, :s1)
              asm.lw(:a1, Tiles::DRAWN_X, :s1)
              asm.lw(:a2, Tiles::DRAWN_Y, :s1)
              asm.jal("rt_paint_blit")
              asm.addiu(:s1, :s1, Tiles::DRAWN_BYTES)
              asm.b("rt_paint_sprites_shown_next") { asm.addiu(:s0, :s0, -1) }
              asm.label("rt_paint_sprites_shown_end")
              DrawList.emit_command(asm, 1) { asm.lui(:a0, h::GP0_DRAWING_OFFSET >> 16) }
              places.each_with_index do |place, i|
                asm.lw(:t0, put_back.call(i), :sp)
                asm.sw(:t0, place, :gp)
              end
              asm.jal("rt_draw_list_finish")
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(SHOWN_COPY_PENDING), :gp)
              asm.lw(:ra, 0, :sp)
              SPRITES_SHOWN_KEPT.each_with_index { |register, i| asm.lw(register, 4 + (i * 4), :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, frame) }
            end

            # rt_paint_numbers_shown: a0 = the top line of the page drawn by number to show. The colours walked
            # if they changed (Colors' rt_colors_shown), everything sent drawn, and the page copied in its colours
            # into the page shown from PAGE_X that is not up, which the blank shows (rt_paint_flip).
            #
            # THE COPY is the page read as a texture of a byte a pixel through the table in NUMBERS_TABLE, in
            # pieces NUMBERS_PIECE_PIXELS pixels wide, each a texture page of its own, as two triangles (GP0 25h,
            # raw: each texel's colour from the table as it is, neither blended nor dithered). A piece reads
            # twice its width in bytes, two a halfword, so each pixel is one halfword of the page: the chip's
            # rule for which texel a pixel shows (PS1::PolygonFill) puts pixel x of a piece at byte 2x or 2x + 1,
            # and the number is in both (PaintedNumbers). Its texels are cached by the chip, from before the
            # page was drawn into, so the cache is emptied first.
            NUMBERS_KEPT = %i[s0 s1 s2 s3 s4].freeze

            def emit_numbers_shown(asm, at)
              h = Console::PS1Hardware
              piece = NUMBERS_PIECE_PIXELS
              bottom = h::SCREEN_HEIGHT
              asm.label("rt_paint_numbers_shown")
              asm.addiu(:sp, :sp, -4 * (NUMBERS_KEPT.length + 1))
              asm.sw(:ra, 0, :sp)
              NUMBERS_KEPT.each_with_index { |register, i| asm.sw(register, 4 + (i * 4), :sp) }
              # s0: the piece's texture page, in a word's top half: the page's half of video RAM, 8 bits a texel.
              asm.srl(:s0, :a0, 8)
              asm.sll(:s0, :s0, 4)
              asm.ori(:s0, :s0, TextureMemory::DEPTH_BITS.fetch(8))
              asm.jal("rt_colors_shown") { asm.sll(:s0, :s0, 16) }
              asm.jal("rt_draw_list_finish")
              # s1: the page shown that is not up, its top line in a word's top half; s2: the piece's column.
              asm.lw(:s1, at.call(SHOWN_PAGE_Y), :gp)
              asm.xori(:s1, :s1, SECOND_PAGE_TOP_LINE)
              asm.sw(:s1, at.call(PASS_PAGE_Y), :gp)
              asm.sll(:s1, :s1, 16)
              asm.lw(:s2, at.call(PAGE_X), :gp)
              asm.lw(:s4, at.call(NUMBERS_TABLE), :gp)
              asm.sll(:s4, :s4, 16)
              asm.li(:s3, h::SCREEN_WIDTH / piece)
              asm.jal("rt_gp0_port_word") { asm.lui(:a0, h::GP0_CLEAR_CACHE >> 16) }
              asm.label("rt_paint_numbers_piece")
              # The top left, top right and bottom left corners, then the bottom right.
              asm.or(:t4, :s1, :s2)
              asm.addiu(:t5, :t4, piece)
              asm.lui(:t7, bottom)
              asm.addu(:t7, :t4, :t7)
              asm.addiu(:t8, :t7, piece)
              asm.jal("rt_gp0_port_word") { asm.lui(:a0, h::GP0_TEXTURED_TRIANGLE >> 16) }
              stored = ->(register) { asm.sw(register, h::GP0 & 0xFFFF, :t1) }
              stored.call(:t4)
              stored.call(:s4) # the table, u 0, v 0
              stored.call(:t5)
              asm.ori(:t6, :s0, piece * 2)
              stored.call(:t6) # the texture page, u at the piece's width in bytes, v 0
              stored.call(:t7)
              asm.li(:t6, bottom << 8)
              stored.call(:t6)
              asm.jal("rt_gp0_port_word") { asm.lui(:a0, h::GP0_TEXTURED_TRIANGLE >> 16) }
              stored.call(:t5)
              asm.ori(:t6, :s4, piece * 2)
              stored.call(:t6)
              stored.call(:t7)
              asm.ori(:t6, :s0, bottom << 8)
              stored.call(:t6)
              stored.call(:t8)
              asm.li(:t6, (bottom << 8) | (piece * 2))
              stored.call(:t6)
              # The next piece: a column of the page shown on, a texture page of the page drawn on.
              asm.addiu(:s2, :s2, piece)
              asm.lui(:t0, 1)
              asm.addu(:s0, :s0, :t0)
              asm.addiu(:s3, :s3, -1)
              asm.bgtz(:s3, "rt_paint_numbers_piece")
              asm.jal("rt_draw_list_finish")
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(SHOWN_COPY_PENDING), :gp)
              asm.lw(:ra, 0, :sp)
              NUMBERS_KEPT.each_with_index { |register, i| asm.lw(register, 4 + (i * 4), :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4 * (NUMBERS_KEPT.length + 1)) }
            end

            # What a patch keeps of the last save into it (Lowering::Paint#patch_state): how far into the
            # rectangle saved the part on the screen starts across and down, and how wide and tall it is, a
            # word each; a height of nought for nothing saved.
            PATCH_SKIP_X = 0
            PATCH_SKIP_Y = 4
            PATCH_WIDTH = 8
            PATCH_HEIGHT = 12
            PATCH_STATE_BYTES = 16

            # THE PATCH UNDER A SPRITE on a painted screen: the screen under it saved before it is drawn, and
            # put back before it moves (Reference#exec_save_region, #exec_restore_region). The patch is kept in
            # video RAM beside the pictures, and both are one copy inside video RAM (GP0 80h), which the chip
            # makes without the processor touching a pixel.
            #
            # rt_paint_save: a0, a1 = where, a2 = the patch's state, a3 = its corner in video RAM (y << 16 | x),
            # t4, t5 = its width and height. Only the part on the screen is saved, and the state says which.
            # rt_paint_restore: a0, a1 = where, a2, a3 = the state and the corner. The part saved goes back at
            # the same place in the rectangle, kept to the area drawing is held to; a patch nothing was saved
            # into puts nothing back.
            def emit_patches(asm, at)
              h = Console::PS1Hardware
              word = ->(index) { DrawList.word_offset_bytes(index) }
              asm.label("rt_paint_save")
              asm.li(:t0, h::SCREEN_WIDTH)
              emit_clip(asm, tag: "rt_paint_save_x", pos: :a0, size: :t4, low: :zero, high: :t0, start: :t6, length: :t7, skip: :t8,
                             empty: "rt_paint_save_none")
              asm.li(:t0, h::SCREEN_HEIGHT)
              emit_clip(asm, tag: "rt_paint_save_y", pos: :a1, size: :t5, low: :zero, high: :t0, start: :t9, length: :v0, skip: :v1,
                             empty: "rt_paint_save_none")
              asm.sw(:t8, PATCH_SKIP_X, :a2)
              asm.sw(:v1, PATCH_SKIP_Y, :a2)
              asm.sw(:t7, PATCH_WIDTH, :a2)
              asm.sw(:v0, PATCH_HEIGHT, :a2)
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              DrawList.emit_command(asm, 4) { asm.lui(:a0, h::GP0_COPY_IN_VRAM >> 16) }
              asm.lw(:t0, at.call(PAGE_Y), :gp)
              asm.addu(:t0, :t0, :t9)
              asm.sll(:t0, :t0, 16)
              asm.or(:t0, :t0, :t6)
              asm.sw(:t0, word.call(1), :t1)
              asm.sll(:t0, :v1, 16)
              asm.addu(:t0, :t0, :t8)
              asm.addu(:t0, :t0, :a3)
              asm.sw(:t0, word.call(2), :t1)
              asm.sll(:t0, :v0, 16)
              asm.or(:t0, :t0, :t7)
              asm.sw(:t0, word.call(3), :t1)
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
              asm.label("rt_paint_save_none")
              asm.jr(:ra) { asm.sw(:zero, PATCH_HEIGHT, :a2) }

              asm.label("rt_paint_restore")
              asm.lw(:t0, PATCH_HEIGHT, :a2)
              asm.beq(:t0, :zero, "rt_paint_restore_none")
              asm.lw(:t1, PATCH_SKIP_X, :a2)
              asm.lw(:t2, PATCH_SKIP_Y, :a2)
              asm.addu(:a0, :a0, :t1)
              asm.addu(:a1, :a1, :t2)
              asm.sll(:v0, :t2, 16)
              asm.addu(:v0, :v0, :t1)
              asm.addu(:v0, :v0, :a3) # where in the patch the part saved starts
              asm.move(:a3, :t0)
              asm.lw(:a2, PATCH_WIDTH, :a2)
              emit_clip_to_area(asm, at, tag: "rt_paint_restore", empty: "rt_paint_restore_none")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              DrawList.emit_command(asm, 4) { asm.lui(:a0, h::GP0_COPY_IN_VRAM >> 16) }
              asm.sll(:t0, :t9, 16)
              asm.addu(:t0, :t0, :t4)
              asm.addu(:t0, :t0, :v0)
              asm.sw(:t0, word.call(1), :t1)
              asm.lw(:t0, at.call(PAGE_Y), :gp)
              asm.addu(:t0, :t0, :t7)
              asm.sll(:t0, :t0, 16)
              asm.or(:t0, :t0, :t5)
              asm.sw(:t0, word.call(2), :t1)
              asm.sll(:t0, :t8, 16)
              asm.or(:t0, :t0, :t6)
              asm.sw(:t0, word.call(3), :t1)
              asm.lw(:ra, 0, :sp)
              asm.addiu(:sp, :sp, 4)
              asm.label("rt_paint_restore_none")
              asm.jr(:ra)
            end

            # rt_paint_start: the area the whole screen.
            def emit_start(asm, at)
              area = at.call(AREA)
              asm.label("rt_paint_start")
              asm.sw(:zero, area + AREA_LEFT_OFFSET_BYTES, :gp)
              asm.sw(:zero, area + AREA_TOP_OFFSET_BYTES, :gp)
              asm.li(:t0, Console::PS1Hardware::SCREEN_WIDTH)
              asm.sw(:t0, area + AREA_RIGHT_OFFSET_BYTES, :gp)
              asm.li(:t0, Console::PS1Hardware::SCREEN_HEIGHT)
              asm.jr(:ra) { asm.sw(:t0, area + AREA_BOTTOM_OFFSET_BYTES, :gp) }
            end

            # ONE SIDE OF A RECTANGLE KEPT BETWEEN TWO EDGES, in place: +pos+ and +size+ (registers
            # holding where it starts and how far it runs) between +low+ and +high+ (registers holding
            # the first place in and the first place past). Leaves where the part inside starts in
            # +start+ and how far it runs in +length+, and, when +skip+ names one, how far in from the
            # rectangle's own start that is. Jumps to +empty+ when nothing is inside. Changes t2 and t3.
            #
            # A game's numbers are 32 bits and the interpreter's sums never wrap, so the end is worked
            # out where it cannot: from a start below nought (start + size, a negative and a positive),
            # or as "is size past high - start" from one at nought or above (both under the screen's
            # size).
            def emit_clip(asm, tag:, pos:, size:, low:, high:, start:, length:, empty:, skip: nil)
              asm.blez(size, empty)
              asm.slt(:t2, pos, high)
              asm.beq(:t2, :zero, empty)
              asm.bltz(pos, "#{tag}_from_below")
              asm.subu(:t2, high, pos)
              asm.slt(:t3, :t2, size)
              asm.bne(:t3, :zero, "#{tag}_to_high")
              asm.b("#{tag}_end") { asm.addu(:t2, pos, size) }
              asm.label("#{tag}_to_high")
              asm.b("#{tag}_end") { asm.move(:t2, high) }
              asm.label("#{tag}_from_below")
              asm.addu(:t2, pos, size)
              asm.slt(:t3, high, :t2)
              asm.beq(:t3, :zero, "#{tag}_end")
              asm.move(:t2, high)
              asm.label("#{tag}_end")
              # t2 is the end; the start is the later of pos and low
              asm.move(start, pos)
              asm.slt(:t3, pos, low)
              asm.beq(:t3, :zero, "#{tag}_start")
              asm.move(start, low)
              asm.label("#{tag}_start")
              asm.slt(:t3, start, :t2)
              asm.beq(:t3, :zero, empty)
              asm.subu(length, :t2, start)
              asm.subu(skip, start, pos) if skip
            end

            # rt_paint_area: a0, a1, a2, a3 = x, y, width, height. Drawing is held to that rectangle,
            # kept to the screen, from now on (Reference::Framebuffer#draw_inside): it replaces the area
            # there was, as the interpreter's does. One with nothing on the screen holds every drawing
            # out.
            def emit_area(asm, at)
              area = at.call(AREA)
              asm.label("rt_paint_area")
              asm.move(:t0, :zero)
              asm.li(:t1, Console::PS1Hardware::SCREEN_WIDTH)
              emit_clip(asm, tag: "rt_paint_area_x", pos: :a0, size: :a2, low: :t0, high: :t1, start: :t4, length: :t5,
                             empty: "rt_paint_area_none")
              asm.li(:t1, Console::PS1Hardware::SCREEN_HEIGHT)
              emit_clip(asm, tag: "rt_paint_area_y", pos: :a1, size: :a3, low: :t0, high: :t1, start: :t6, length: :t7,
                             empty: "rt_paint_area_none")
              asm.sw(:t4, area + AREA_LEFT_OFFSET_BYTES, :gp)
              asm.sw(:t6, area + AREA_TOP_OFFSET_BYTES, :gp)
              asm.addu(:t4, :t4, :t5)
              asm.sw(:t4, area + AREA_RIGHT_OFFSET_BYTES, :gp)
              asm.addu(:t6, :t6, :t7)
              asm.jr(:ra) { asm.sw(:t6, area + AREA_BOTTOM_OFFSET_BYTES, :gp) }
              asm.label("rt_paint_area_none")
              asm.sw(:zero, area + AREA_LEFT_OFFSET_BYTES, :gp)
              asm.sw(:zero, area + AREA_TOP_OFFSET_BYTES, :gp)
              asm.sw(:zero, area + AREA_RIGHT_OFFSET_BYTES, :gp)
              asm.jr(:ra) { asm.sw(:zero, area + AREA_BOTTOM_OFFSET_BYTES, :gp) }
            end

            # rt_paint_fill: a0, a1, a2, a3 = x, y, width, height, t4 = the rectangle command with its
            # colour (GP0 60h). The part inside the area, as one rectangle on the page drawn into.
            # rt_paint_clear: a0 = the command; the whole area (Reference::Framebuffer#clear), sent to the chip
            # at once if the DMA is free (Runtime::DrawList's rt_draw_list_kick): the chip takes a while to
            # fill the screen, and does it while the processor works out what comes next.
            def emit_fill(asm, at, faces)
              area = at.call(AREA)
              asm.label("rt_paint_clear")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.move(:t4, :a0)
              asm.lw(:a0, area + AREA_LEFT_OFFSET_BYTES, :gp)
              asm.lw(:a1, area + AREA_TOP_OFFSET_BYTES, :gp)
              asm.lw(:a2, area + AREA_RIGHT_OFFSET_BYTES, :gp)
              asm.lw(:a3, area + AREA_BOTTOM_OFFSET_BYTES, :gp)
              asm.subu(:a2, :a2, :a0)
              asm.jal("rt_paint_fill") { asm.subu(:a3, :a3, :a1) }
              asm.lw(:ra, 0, :sp)
              asm.j("rt_draw_list_kick") { asm.addiu(:sp, :sp, 4) }

              asm.label("rt_paint_fill")
              Faces.emit_chip_put_back_call(asm) if faces
              asm.move(:v1, :t4) # the command, kept clear of what the clip leaves
              emit_clip_to_area(asm, at, tag: "rt_paint_fill", empty: "rt_paint_fill_none")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              DrawList.emit_command(asm, 3) { asm.move(:a0, :v1) }
              emit_corner_and_size(asm, at)
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
              asm.label("rt_paint_fill_none")
              asm.jr(:ra)
            end

            # A RECTANGLE KEPT TO THE AREA, both ways (#emit_clip): a0, a1, a2, a3 = x, y, width, height.
            # Leaves the part inside as t5, t7 (its corner) and t6, t8 (its width and height), and how far
            # in from the rectangle's own corner that is as t4 and t9; jumps to +empty+ when nothing is
            # inside. Changes t0 to t3.
            def emit_clip_to_area(asm, at, tag:, empty:)
              area = at.call(AREA)
              asm.lw(:t0, area + AREA_LEFT_OFFSET_BYTES, :gp)
              asm.lw(:t1, area + AREA_RIGHT_OFFSET_BYTES, :gp)
              emit_clip(asm, tag: "#{tag}_x", pos: :a0, size: :a2, low: :t0, high: :t1, start: :t5, length: :t6,
                             skip: :t4, empty: empty)
              asm.lw(:t0, area + AREA_TOP_OFFSET_BYTES, :gp)
              asm.lw(:t1, area + AREA_BOTTOM_OFFSET_BYTES, :gp)
              emit_clip(asm, tag: "#{tag}_y", pos: :a1, size: :a3, low: :t0, high: :t1, start: :t7, length: :t8,
                             skip: :t9, empty: empty)
            end

            # The corner and the size #emit_clip_to_area left, stored through t1 (as a DrawList command's
            # routine leaves it) as the next words of a command already begun: the corner as a place on the
            # page drawn into (its second word), the size as height << 16 | width (its last). A textured
            # rectangle has its texture's corner between the two (+between+, a block that stores it as the
            # third word). Changes v0.
            def emit_corner_and_size(asm, at, &between)
              asm.lw(:v0, at.call(PAGE_Y), :gp)
              asm.addu(:v0, :v0, :t7)
              asm.sll(:v0, :v0, 16)
              asm.or(:v0, :v0, :t5)
              asm.sw(:v0, DrawList.word_offset_bytes(1), :t1)
              between&.call
              asm.sll(:v0, :t8, 16)
              asm.or(:v0, :v0, :t6)
              asm.sw(:v0, DrawList.word_offset_bytes(between ? 3 : 2), :t1)
            end

            # rt_paint_blit: a0 = a picture's place in PaintedArt's table, a1, a2 = x, y. Each piece of it
            # that lands inside the area is a textured rectangle: the draw mode naming the piece's page,
            # then the rectangle from as far into the piece as the area cuts it. A see-through texel's
            # colour is 0000h, in the piece or in its colour table, which the chip leaves undrawn.
            #
            # rt_paint_blit_one_of: a0 = a list of pictures (its length, then each one's place), a1 = which,
            # a2, a3 = x, y. A number naming none of them, below nought or past the end, draws nothing.
            def emit_blit(asm, at, faces)
              h = Console::PS1Hardware
              asm.label("rt_paint_blit_one_of")
              asm.lw(:t0, 0, :a0)
              asm.sltu(:t1, :a1, :t0)
              asm.beq(:t1, :zero, "rt_paint_blit_done")
              asm.sll(:t1, :a1, 2)
              asm.addu(:t1, :a0, :t1)
              asm.lw(:a0, 4, :t1)
              asm.move(:a1, :a2)
              asm.move(:a2, :a3)

              asm.label("rt_paint_blit")
              asm.addiu(:sp, :sp, -20)
              asm.sw(:ra, 0, :sp)
              [:s0, :s1, :s2, :s3].each_with_index { |register, i| asm.sw(register, 4 + (i * 4), :sp) }
              asm.jal("rt_face_chip_put_back") if faces
              asm.lw(:s1, 0, :a0)
              asm.addiu(:s0, :a0, 4)
              asm.move(:s2, :a1)
              asm.move(:s3, :a2)
              asm.label("rt_paint_blit_piece")
              asm.beq(:s1, :zero, "rt_paint_blit_end")
              # The piece's corner is the picture's place and the piece's place in it, a sum of 32 bits
              # that wraps where the interpreter's does not: x near the largest number plus the piece's
              # place comes round to near the smallest. Both are about 2^31 from the screen, and a piece
              # reaches less than 2^16 past its corner, so the clip finds nothing inside either way, as
              # the interpreter draws nothing there (TestImage, a picture at the edge of the numbers).
              asm.lh(:a0, 0, :s0)
              asm.addu(:a0, :a0, :s2)
              asm.lh(:a1, 2, :s0)
              asm.addu(:a1, :a1, :s3)
              asm.lhu(:a2, 4, :s0)
              asm.lhu(:a3, 6, :s0)
              emit_clip_to_area(asm, at, tag: "rt_paint_blit", empty: "rt_paint_blit_next")
              # The draw mode, a command of one word, then the rectangle's four, sent whole.
              asm.lw(:a0, 8, :s0)
              DrawList.emit_command(asm, 1)
              DrawList.emit_command(asm, 4) { asm.lui(:a0, h::GP0_TEXTURED_RECTANGLE >> 16) }
              emit_corner_and_size(asm, at) do
                asm.lw(:v0, 12, :s0)
                asm.sll(:v1, :t9, 8)
                asm.addu(:v0, :v0, :v1)
                asm.addu(:v0, :v0, :t4)
                asm.sw(:v0, DrawList.word_offset_bytes(2), :t1)
              end
              asm.label("rt_paint_blit_next")
              asm.addiu(:s0, :s0, PIECE_BYTES)
              asm.b("rt_paint_blit_piece") { asm.addiu(:s1, :s1, -1) }
              asm.label("rt_paint_blit_end")
              asm.lw(:ra, 0, :sp)
              [:s0, :s1, :s2, :s3].each_with_index { |register, i| asm.lw(register, 4 + (i * 4), :sp) }
              asm.addiu(:sp, :sp, 20)
              asm.label("rt_paint_blit_done")
              asm.jr(:ra)
            end

            # TWO PAGES, OR ONE (Reference::Framebuffer#paged=).
            #
            # rt_paint_screen: a0 = 1 for a tear-free screen, 0 for one page. Becoming tear-free, the page
            # drawn so far goes on being drawn into and the other page, black, is shown in front of it;
            # becoming one page again, the page holding the drawing is shown and drawn into.
            #
            # rt_paint_flip: at the frame boundary, once the blank has begun, a tear-free screen shows the
            # page just drawn and draws into the other. Only after a pass's wait (FLIP_OWED).
            #
            # A SCREEN SHOWN FROM PAGES OF ITS OWN (+shown_apart+: drawn by number, or with sprites over it) never shows the pages it is drawn in: rt_paint_screen changes
            # which page is drawn into and shows nothing, and rt_paint_flip trades the pages drawn into as it
            # does, then shows the page from PAGE_X its pass's copy went into (SHOWN_COPY_PENDING).
            def emit_pages(asm, at, shown_apart)
              h = Console::PS1Hardware
              asm.label("rt_paint_screen")
              asm.lw(:t0, at.call(PAGED), :gp)
              asm.beq(:t0, :a0, "rt_paint_screen_same")
              asm.sw(:a0, at.call(PAGED), :gp)
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.lw(:t0, at.call(PAGE_Y), :gp)
              asm.beq(:a0, :zero, "rt_paint_screen_drawn")
              asm.xori(:t4, :t0, SECOND_PAGE_TOP_LINE)
              DrawList.emit_command(asm, 3) { asm.lui(:a0, h::GP0_FILL >> 16) }
              asm.sll(:t0, :t4, 16)
              asm.sw(:t0, DrawList.word_offset_bytes(1), :t1)
              asm.li(:t0, (h::SCREEN_HEIGHT << 16) | h::SCREEN_WIDTH)
              asm.sw(:t0, DrawList.word_offset_bytes(2), :t1)
              asm.move(:t0, :t4)
              # What was drawn so far, and the other page's black, drawn before the page shown changes
              # (Runtime::DrawList). The list's routines change only t1 to t3.
              asm.label("rt_paint_screen_drawn")
              asm.jal("rt_draw_list_finish")
              asm.lw(:ra, 0, :sp)
              asm.addiu(:sp, :sp, 4)
              asm.jr(:ra) if shown_apart
              # Show the page whose top line is in t0.
              asm.label("rt_paint_show_t0")
              asm.sll(:t1, :t0, 10)
              if shown_apart
                asm.lw(:t2, at.call(PAGE_X), :gp)
                asm.or(:t1, :t1, :t2)
              end
              asm.lui(:t2, h::GP1_DISPLAY_START >> 16)
              asm.or(:t1, :t1, :t2)
              asm.lui(:t2, h::IO >> 16)
              asm.sw(:t1, h::GP1 & 0xFFFF, :t2)
              asm.sw(:t0, at.call(SHOWN_PAGE_Y), :gp)
              asm.label("rt_paint_screen_same")
              asm.jr(:ra)

              asm.label("rt_paint_flip")
              asm.lw(:t0, at.call(FLIP_OWED), :gp)
              asm.sw(:zero, at.call(FLIP_OWED), :gp)
              asm.beq(:t0, :zero, shown_apart ? "rt_paint_flip_shown_apart" : "rt_paint_screen_same")
              asm.lw(:t0, at.call(PAGED), :gp)
              asm.beq(:t0, :zero, shown_apart ? "rt_paint_flip_shown_apart" : "rt_paint_screen_same")
              asm.lw(:t0, at.call(PAGE_Y), :gp)
              asm.xori(:t1, :t0, SECOND_PAGE_TOP_LINE)
              return asm.b("rt_paint_show_t0") { asm.sw(:t1, at.call(PAGE_Y), :gp) } unless shown_apart

              asm.sw(:t1, at.call(PAGE_Y), :gp)
              asm.label("rt_paint_flip_shown_apart")
              asm.lw(:t1, at.call(SHOWN_COPY_PENDING), :gp)
              asm.beq(:t1, :zero, "rt_paint_screen_same")
              asm.sw(:zero, at.call(SHOWN_COPY_PENDING), :gp)
              asm.lw(:t0, at.call(PASS_PAGE_Y), :gp)
              asm.b("rt_paint_show_t0")
            end

            # rt_paint_upload: every texture and colour table copied into video RAM, at power-on, from the
            # table "paint uploads" (PS1::TextureMemory#uploads): for each, where it goes (y << 16 | x), its
            # size in halfwords (height << 16 | width), where its halfwords are and how many words they
            # take; a nought after the last.
            #
            # THE PIXELS GO BY DMA, not a word at a time from the processor. While the chip takes a copy
            # in, it signals it has room for another word only once it has had time to store the last, and
            # time does not move on for it while the processor only asks (Beetle PSX measured: a picture
            # sent a word at a time had not arrived after 600 frames). The DMA controller hands the chip
            # each word as it asks for it: the copy's command goes first through the port, and channel 2,
            # which the chip takes words from (Runtime::DrawList's rt_draw_list_start), sends the pixels
            # from RAM a word a block until they are all gone.
            #
            # The commands drawn so far, video RAM made black among them (Boot), are sent and drawn first,
            # so the copies come after them and the port is the processor's alone meanwhile.
            def emit_upload(asm)
              h = Console::PS1Hardware
              asm.label("rt_paint_upload")
              asm.addiu(:sp, :sp, -8)
              asm.sw(:ra, 0, :sp)
              asm.sw(:s0, 4, :sp)
              asm.jal("rt_draw_list_finish")
              asm.la(:s0, "paint uploads")
              asm.label("rt_paint_upload_piece")
              asm.lw(:t4, 0, :s0)
              asm.beq(:t4, :zero, "rt_paint_upload_end")
              # The copy's three words go in one after another once the chip has room: it signals it has no
              # room for the third until it has the whole command (Beetle PSX measured), so asking
              # between them waits for ever. Its queue holds sixteen.
              asm.jal("rt_gp0_port_word") { asm.lui(:a0, h::GP0_COPY_TO_VRAM >> 16) }
              asm.lui(:t5, h::IO >> 16)
              asm.sw(:t4, h::GP0 & 0xFFFF, :t5)
              asm.lw(:t0, 4, :s0)
              asm.sw(:t0, h::GP0 & 0xFFFF, :t5)
              asm.lw(:t0, 8, :s0)
              asm.sw(:t0, h::DMA2_MADR & 0xFFFF, :t5)
              asm.lw(:t0, 12, :s0)
              asm.sll(:t0, :t0, 16)
              asm.ori(:t0, :t0, 1) # blocks of one word, as many as the pixels take
              asm.sw(:t0, h::DMA2_BCR & 0xFFFF, :t5)
              asm.li(:t0, h::DMA2_FROM_RAM_BY_BLOCKS)
              asm.sw(:t0, h::DMA2_CHCR & 0xFFFF, :t5)
              asm.lui(:t1, h::DMA_BUSY >> 16)
              asm.label("rt_paint_upload_wait")
              asm.lw(:t0, h::DMA2_CHCR & 0xFFFF, :t5)
              asm.and(:t0, :t0, :t1)
              asm.bne(:t0, :zero, "rt_paint_upload_wait")
              asm.b("rt_paint_upload_piece") { asm.addiu(:s0, :s0, 16) }
              asm.label("rt_paint_upload_end")
              # The chip keeps a small cache of the texels and colour table it read last; what it holds from
              # before the copies is thrown away, so the first picture drawn reads what was copied in.
              DrawList.emit_command(asm, 1) { asm.lui(:a0, h::GP0_CLEAR_CACHE >> 16) }
              asm.lw(:ra, 0, :sp)
              asm.lw(:s0, 4, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 8) }
            end
          end
        end
      end
    end
  end
end
