# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE FACES OF A PLACE, filled by the graphics chip. The processor cuts each face into pieces the
          # chip can draw and sends each piece as textured triangles (GP0 25h); the chip fills them, fast,
          # by its own rules. PS1::FacePieces says what is cut and why, in Ruby, and this is the same sums
          # in MIPS, number for number: the checked run holds the two to each other through the picture.
          #
          # WHAT DIFFERS FROM THE INTERPRETER'S PICTURE, and is the chip's: a corner is a whole pixel and
          # a whole texel; the chip samples a pixel's top-left corner, half a texel on; it steps the place
          # on the picture straight across each triangle, so a quad's two triangles bend it differently
          # from the interpreter's rows; and perspective is exact only at the corners of the squares a
          # face is cut into. Turning the place, cutting it at the near limit and where each corner lands
          # are the game's own statements, so those, and `screen_spot`, are the interpreter's to the bit.
          #
          # THE PICTURES are textures in video RAM beside the screen (PS1::TextureMemory), each at a place
          # in its page that is a multiple of its size, so the chip's texture window (GP0 E2h) repeats it
          # like wallpaper. A picture's record (RECORD_ fields) holds its window, its colour table and
          # page as a triangle names them, and its size as the masks the pieces' places are moved by.
          #
          # HOW IT IS CALLED. The lowering works out the face's numbers in the interpreter's order: the
          # picture (PICTURE_OFFSET_BYTES, its record's address), then the count, and rt_face_corners reads
          # the corners from the list; only when there are three or more are the edges and the perspective
          # worked out (LEFT_OFFSET_BYTES to SPANS_OFFSET_BYTES), and rt_fill_face called.
          #
          # THE PIECES are kept in RAM out of gp's reach (PIECES, made only for a game that fills faces):
          # each a count and up to FacePieces::MOST_CORNERS corners, POLYGON_BYTES in all. A piece holds
          # the ADDRESS of each of its corners, a word, not the corner's FacePieces::NUMBERS words: a cut
          # hands most of a piece's corners on to the pieces either side of its line unchanged, and the
          # main RAM the pieces are in has no cache, so copying a corner's eight words at every cut was most
          # of what cutting cost. The corners themselves are in the pool after the pieces (POOL_CORNERS):
          # the face's own first, then each corner a cut makes, taken from the pool's next free place
          # (POOL_NEXT_OFFSET_BYTES). A corner is never changed once made, so pieces can share it, as
          # FacePieces' pieces share their corners' arrays.
          #
          # The pool is handed back as the pieces finish with it: all of it as each face starts; whatever
          # the work on a part took, once rt_face_sweep has sent that part; and as a piece comes off the
          # waiting stack, everything past where the piece below it was put waiting (WAITING_MARKS), its
          # own corners from there moved down to the start of what was handed back (rt_face_compact). Only
          # that piece can still be using any of it, so a piece cut on the picture again and again takes no
          # more of the pool than one cut once. POOL_CORNERS says why that is always enough.
          #
          # A LIT FACE (LEVELS_OFFSET_BYTES not nought) has a shade at each corner, is cut along every
          # whole level, and each piece names its level's colour table (FacePieces says why). A face not
          # lit does none of that work.
          module Faces
            FACE = "rt face"
            PIECES = "face pieces"

            # A corner as the list holds it: x, y, u, v, w and its light, a word each
            # (Nodes::FillFace::CORNER_NUMBERS).
            LIST_CORNER_BYTES = Nodes::FillFace::CORNER_NUMBERS * 4

            # Where each number is in FACE, in bytes from its start.
            PICTURE_OFFSET_BYTES = 0
            COUNT_OFFSET_BYTES = 4
            LEFT_OFFSET_BYTES = 8
            TOP_OFFSET_BYTES = 12
            RIGHT_OFFSET_BYTES = 16
            BOTTOM_OFFSET_BYTES = 20
            SPANS_OFFSET_BYTES = 24
            SIDE_OFFSET_BYTES = 28 # the side of a square a face in perspective is cut into, in sixteenths
            LEVELS_OFFSET_BYTES = 32 # how many levels the face's shading has; nought for a face not lit
            TABLE_OFFSET_BYTES = 36 # the colour table the piece being sent names, as its first corner carries it
            # The least and the most of each of EXTENT_NUMBERS over the piece being sent, a word each, in
            # that order (rt_face_extents).
            EXTENTS_OFFSET_BYTES = 40
            EXTENT_NUMBERS = [FacePieces::TEXEL_U, FacePieces::TEXEL_V, FacePieces::SHADE].freeze
            POOL_NEXT_OFFSET_BYTES = EXTENTS_OFFSET_BYTES + (EXTENT_NUMBERS.length * 8) # the pool's next free corner
            # The pool's next free corner as each piece waiting was put there, a word each.
            WAITING_MARKS_OFFSET_BYTES = POOL_NEXT_OFFSET_BYTES + 4
            CORNERS_OFFSET_BYTES = WAITING_MARKS_OFFSET_BYTES + (FacePieces::MOST_WAITING * 4)
            BYTES = CORNERS_OFFSET_BYTES + (Nodes::FillFace::MOST_CORNERS * LIST_CORNER_BYTES)

            # A corner in the pool: FacePieces::NUMBERS words.
            CORNER_BYTES = FacePieces::NUMBERS * 4

            # A corner's light is held to LIGHTEST by testing its top half for nought (rt_fill_face), which
            # is right only while LIGHTEST is the whole bottom half.
            raise "rt_fill_face holds a light to 0xFFFF, not #{Nodes::FillFace::LIGHTEST}" unless Nodes::FillFace::LIGHTEST == 0xFFFF

            # A piece: its count, then the address of each corner.
            POLYGON_BYTES = 4 + (FacePieces::MOST_CORNERS * 4)
            # Where each number of a corner is (FacePieces::X to V).
            NUMBER_OFFSETS = (0...FacePieces::NUMBERS).to_h { |number| [number, number * 4] }.freeze

            # The pieces, in PIECES: the face, two rests for cutting it into rows, a row, two rests for
            # cutting a row into squares, a square, two for cutting on the picture, then those waiting.
            POLYGONS = %i[face rows_a rows_b row squares_a squares_b square part_a part_b].freeze
            WAITING_OFFSET_BYTES = POLYGONS.length * POLYGON_BYTES
            # ...and the corners of the piece being sent: x, y, u and v as a word, and y << 16 | x as the
            # chip takes it, a word each.
            SENT_CORNER_BYTES = 16
            SENT_OFFSET_BYTES = WAITING_OFFSET_BYTES + (FacePieces::MOST_WAITING * POLYGON_BYTES)
            # ...the corners rt_face_compact is moving, on their way down.
            COMPACT_OFFSET_BYTES = SENT_OFFSET_BYTES + (FacePieces::MOST_CORNERS * SENT_CORNER_BYTES)
            POOL_OFFSET_BYTES = COMPACT_OFFSET_BYTES + (FacePieces::MOST_CORNERS * CORNER_BYTES)

            # HOW MANY CORNERS THE POOL HOLDS: the most that can be in use at once. A cut makes at most a
            # corner for each edge of the piece it cuts, so MOST_CORNERS. In use at once are the face's own,
            # the four cuts that hold it to its edges, every cut of rt_face_sweep's rest across the screen
            # one way and the other (its parts are handed back, the rest is not), and on the picture and
            # between levels, for each piece waiting and for the part being sent, the corners it came off
            # the stack with and the cuts made since: three at the most before a part is sent, since a part
            # cut once across the picture, once down it and once between levels lies inside all three. The
            # smallest square is the one most cut.
            unless FacePieces::CELL_PIXELS >= FacePieces::EVERY_PIXEL_CELL_PIXELS
              raise "the pool is sized for squares of #{FacePieces::EVERY_PIXEL_CELL_PIXELS} pixels or more"
            end
            SWEEP_LINES = Console::PLAYSTATION.screen_size.sum { |side| (side / FacePieces::EVERY_PIXEL_CELL_PIXELS) + 1 }
            POOL_CORNERS = Nodes::FillFace::MOST_CORNERS +
                           (FacePieces::MOST_CORNERS * (4 + SWEEP_LINES + ((FacePieces::MOST_WAITING + 1) * (1 + 3))))
            PIECES_BYTES = POOL_OFFSET_BYTES + (POOL_CORNERS * CORNER_BYTES)

            # A picture's record: its texture window (GP0 E2h, whole), its colour table and its page each
            # moved up to the top half of a corner's u and v word, and its width and height as masks that
            # move a place down to a whole picture (the size taken from nought).
            RECORD_WINDOW_OFFSET_BYTES = 0
            RECORD_TABLE_OFFSET_BYTES = 4
            RECORD_PAGE_OFFSET_BYTES = 8
            RECORD_ACROSS_MASK_OFFSET_BYTES = 12
            RECORD_DOWN_MASK_OFFSET_BYTES = 16

            # IR::Reciprocals::TABLE, as the processor reads it.
            RECIPROCALS = "rt face reciprocals"

            # The registers a routine that calls others keeps on the stack.
            KEPT_REGISTERS = %i[ra s0 s1 s2 s3 s4 s5 s6 s7].freeze

            module_function

            def reserve(memory) = memory.reserve(FACE, BYTES)

            # The pieces' room, for a game that fills faces; asked for before the runtime is emitted, so
            # the region cleared at power-on takes it in.
            def reserve_pieces(memory) = memory.reserve(PIECES, PIECES_BYTES)

            def emit(asm, memory)
              at = Runtime.at(memory, FACE)
              pieces = memory[PIECES]
              polygon = ->(name) { pieces + (POLYGONS.index(name) * POLYGON_BYTES) }
              emit_face_corners_routine(asm, at)
              emit_fill_face_routine(asm, at, memory, polygon, pieces + POOL_OFFSET_BYTES)
              emit_sweep_routine(asm, at)
              emit_send_piece_routine(asm, at, polygon, pieces + WAITING_OFFSET_BYTES)
              emit_fan_routine(asm, at, memory, pieces + SENT_OFFSET_BYTES)
              emit_cut_routine(asm, at)
              emit_extent_routine(asm)
              emit_extents_routine(asm, at)
              emit_copy_routine(asm)
              emit_compact_routine(asm, at, pieces + COMPACT_OFFSET_BYTES)
              emit_texel_routine(asm, at)
            end

            # The reciprocal table, a section of its own.
            def reciprocals_section(holds)
              asm = R3000.new(RECIPROCALS, holds: holds)
              asm.label(RECIPROCALS)
              asm.data_words(IR::Reciprocals::TABLE)
              asm.section
            end

            # Int32.mul_fix(a, b, bits) into +into+: the whole product's bits from +bits+ up. Changes t9.
            def emit_mul_fix(asm, into, a, b, bits)
              asm.mult(a, b)
              asm.mflo(into)
              asm.mfhi(:t9)
              asm.srl(into, into, bits)
              asm.sll(:t9, :t9, 32 - bits)
              asm.or(into, into, :t9)
            end

            def emit_keep_registers(asm)
              asm.addiu(:sp, :sp, -4 * KEPT_REGISTERS.length)
              KEPT_REGISTERS.each_with_index { |register, i| asm.sw(register, i * 4, :sp) }
            end

            # The kept registers back, and the return, the stack given back in the jump's delay slot.
            def emit_return_with_registers(asm)
              KEPT_REGISTERS.each_with_index { |register, i| asm.lw(register, i * 4, :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4 * KEPT_REGISTERS.length) }
            end

            # +into+ = where the address of corner +number+ is in a piece, from the piece's start less its
            # count's word: the number times a word.
            def emit_corner_slot(asm, into, number) = asm.sll(into, number, 2)

            # The corner +corner+ (a register holding its address) put on the end of the piece in +piece+
            # (nought: none) while it has fewer than FacePieces::MOST_CORNERS; +label+ names where to go on.
            # Changes t0 and t1.
            def emit_append(asm, piece, corner, label)
              asm.beq(piece, :zero, label)
              asm.lw(:t0, 0, piece)
              asm.slti(:t1, :t0, FacePieces::MOST_CORNERS)
              asm.beq(:t1, :zero, label)
              emit_corner_slot(asm, :t1, :t0)
              asm.addu(:t1, :t1, piece)
              asm.sw(corner, 4, :t1)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, 0, piece)
              asm.label(label)
            end

            # rt_face_corners: a0 = the list of corners, a1 = how many. The count held to MOST_CORNERS and
            # kept in COUNT_OFFSET_BYTES; with three or more, each corner's numbers read from the list into
            # CORNERS_OFFSET_BYTES, through rt_list_get, so an index past the list's end stops the game as
            # the interpreter's does (Reference#check_list_index!).
            def emit_face_corners_routine(asm, at)
              most = Nodes::FillFace::MOST_CORNERS
              asm.label("rt_face_corners")
              asm.slti(:t0, :a1, most + 1)
              asm.bne(:t0, :zero, "rt_face_corners_held")
              asm.label("rt_face_corners_most")
              asm.li(:a1, most)
              asm.label("rt_face_corners_held")
              asm.sw(:a1, at + COUNT_OFFSET_BYTES, :gp)
              asm.slti(:t0, :a1, 3)
              asm.bne(:t0, :zero, "rt_face_corners_none")
              asm.addiu(:sp, :sp, -16)
              asm.sw(:ra, 0, :sp)
              %i[s0 s1 s2].each_with_index { |register, i| asm.sw(register, 4 + (i * 4), :sp) }
              asm.move(:s0, :a0)
              asm.sll(:t0, :a1, 1)
              asm.sll(:s1, :a1, 2)
              asm.addu(:s1, :s1, :t0) # six numbers a corner
              asm.move(:s2, :zero)
              asm.label("rt_face_corners_next")
              asm.move(:a0, :s0)
              asm.jal("rt_list_get") { asm.move(:a1, :s2) }
              asm.sll(:t0, :s2, 2)
              asm.addu(:t0, :t0, :gp)
              asm.sw(:v0, at + CORNERS_OFFSET_BYTES, :t0)
              asm.addiu(:s2, :s2, 1)
              asm.bne(:s2, :s1, "rt_face_corners_next")
              asm.lw(:ra, 0, :sp)
              %i[s0 s1 s2].each_with_index { |register, i| asm.lw(register, 4 + (i * 4), :sp) }
              asm.addiu(:sp, :sp, 16)
              asm.label("rt_face_corners_none")
              asm.jr(:ra)
            end

            # rt_fill_face: the face whose corners rt_face_corners read, its picture in PICTURE_OFFSET_BYTES
            # and its edges and perspective in LEFT_OFFSET_BYTES to SPANS_OFFSET_BYTES (FacePieces.triangles).
            #
            # The edges are held to the area `inside` holds drawing to (Runtime::Paint::AREA), which lies
            # inside the screen, as the interpreter draws a pixel only inside both. The chip's texture
            # window and drawing area are set for the face and put back after it, since the painted
            # screen's own drawing counts on the whole of video RAM and no window (Runtime::Boot).
            def emit_fill_face_routine(asm, at, memory, polygon, pool)
              h = Console::PS1Hardware
              area = ->(offset) { Runtime.at(memory, Paint::AREA) + offset }
              face = polygon.call(:face)
              x = NUMBER_OFFSETS.fetch(FacePieces::X)
              y = NUMBER_OFFSETS.fetch(FacePieces::Y)
              asm.label("rt_fill_face")
              emit_keep_registers(asm)
              [[LEFT_OFFSET_BYTES, Paint::AREA_LEFT_OFFSET_BYTES, :later], [TOP_OFFSET_BYTES, Paint::AREA_TOP_OFFSET_BYTES, :later],
               [RIGHT_OFFSET_BYTES, Paint::AREA_RIGHT_OFFSET_BYTES, :earlier], [BOTTOM_OFFSET_BYTES, Paint::AREA_BOTTOM_OFFSET_BYTES, :earlier]]
                .each do |edge, area_edge, keep|
                kept = "rt_fill_face_edge#{edge}"
                asm.lw(:t0, at + edge, :gp)
                asm.lw(:t1, area.call(area_edge), :gp)
                keep == :later ? asm.slt(:t2, :t0, :t1) : asm.slt(:t2, :t1, :t0)
                asm.beq(:t2, :zero, kept)
                asm.label("#{kept}_area")
                asm.move(:t0, :t1)
                asm.label(kept)
                asm.sw(:t0, at + edge, :gp)
              end
              # Nothing to draw between edges that meet or cross.
              %i[LEFT RIGHT TOP BOTTOM].each_slice(2) do |low, high|
                asm.lw(:t0, at + const_get(:"#{low}_OFFSET_BYTES"), :gp)
                asm.lw(:t1, at + const_get(:"#{high}_OFFSET_BYTES"), :gp)
                asm.slt(:t2, :t0, :t1)
                asm.beq(:t2, :zero, "rt_fill_face_done")
              end
              emit_face_corners_made(asm, at, face, pool)
              # Clipped to the four edges, in sixteenths: above the left, below the right, then the same
              # down.
              [[x, LEFT_OFFSET_BYTES, :above], [x, RIGHT_OFFSET_BYTES, :below], [y, TOP_OFFSET_BYTES, :above],
               [y, BOTTOM_OFFSET_BYTES, :below]].each do |number, edge, side|
                from, below, above = side == :above ? [face, 0, polygon.call(:rows_a)] : [polygon.call(:rows_a), face, 0]
                asm.li(:a0, from)
                asm.li(:a1, below)
                asm.li(:a2, above)
                asm.li(:a3, number)
                asm.lw(:t4, at + edge, :gp)
                asm.jal("rt_face_cut") { asm.sll(:t4, :t4, 4) }
              end
              asm.li(:t0, face)
              asm.lw(:t0, 0, :t0)
              asm.slti(:t0, :t0, 3)
              asm.bne(:t0, :zero, "rt_fill_face_done")
              # The chip's texture window for the face's picture, and its drawing area the edges on the page
              # drawn into, the right and bottom ones the last drawn.
              asm.lw(:t0, at + PICTURE_OFFSET_BYTES, :gp)
              asm.lw(:a0, RECORD_WINDOW_OFFSET_BYTES, :t0)
              asm.jal("rt_gp0_word")
              asm.lw(:s0, Runtime.at(memory, Paint::PAGE_Y), :gp)
              asm.lw(:t0, at + LEFT_OFFSET_BYTES, :gp)
              asm.lw(:t1, at + TOP_OFFSET_BYTES, :gp)
              asm.addu(:t1, :t1, :s0)
              asm.sll(:t1, :t1, 10)
              asm.or(:a0, :t0, :t1)
              asm.lui(:t0, h::GP0_DRAWING_AREA_TOP_LEFT >> 16)
              asm.jal("rt_gp0_word") { asm.or(:a0, :a0, :t0) }
              asm.lw(:t0, at + RIGHT_OFFSET_BYTES, :gp)
              asm.addiu(:t0, :t0, -1)
              asm.lw(:t1, at + BOTTOM_OFFSET_BYTES, :gp)
              asm.addiu(:t1, :t1, -1)
              asm.addu(:t1, :t1, :s0)
              asm.sll(:t1, :t1, 10)
              asm.or(:a0, :t0, :t1)
              asm.lui(:t0, h::GP0_DRAWING_AREA_BOTTOM_RIGHT >> 16)
              asm.jal("rt_gp0_word") { asm.or(:a0, :a0, :t0) }
              # Without perspective the face is one piece; in perspective it is cut into squares, a row at a
              # time.
              asm.lw(:t0, at + SPANS_OFFSET_BYTES, :gp)
              asm.bne(:t0, :zero, "rt_fill_face_squares")
              asm.label("rt_fill_face_whole")
              asm.li(:a0, face)
              asm.jal("rt_face_send_piece")
              asm.b("rt_fill_face_put_back")
              asm.label("rt_fill_face_squares")
              asm.li(:t1, FacePieces::CELL_PIXELS * 16)
              asm.addiu(:t2, :t0, -1)
              asm.bne(:t2, :zero, "rt_fill_face_side")
              asm.label("rt_fill_face_every_pixel")
              asm.li(:t1, FacePieces::EVERY_PIXEL_CELL_PIXELS * 16)
              asm.label("rt_fill_face_side")
              asm.sw(:t1, at + SIDE_OFFSET_BYTES, :gp)
              asm.li(:a0, face)
              asm.li(:a1, y)
              asm.li(:a2, polygon.call(:row))
              asm.li(:a3, polygon.call(:rows_a))
              asm.la(:t4, "rt_face_row")
              asm.jal("rt_face_sweep")
              asm.label("rt_fill_face_put_back")
              asm.jal("rt_gp0_word") { asm.lui(:a0, h::GP0_TEXTURE_WINDOW >> 16) }
              asm.jal("rt_gp0_word") { asm.lui(:a0, h::GP0_DRAWING_AREA_TOP_LEFT >> 16) }
              asm.li(:a0, h::GP0_DRAWING_AREA_BOTTOM_RIGHT | (h::VRAM_WIDTH - 1) | ((h::VRAM_HEIGHT - 1) << 10))
              asm.jal("rt_gp0_word")
              asm.label("rt_fill_face_done")
              emit_return_with_registers(asm)

              # rt_face_row: a0 = a row of the face, cut into squares along the columns (rt_face_sweep), each
              # square sent.
              asm.label("rt_face_row")
              asm.li(:a1, x)
              asm.li(:a2, polygon.call(:square))
              asm.li(:a3, polygon.call(:squares_a))
              asm.la(:t4, "rt_face_send_piece")
              asm.j("rt_face_sweep")
            end

            # The face's corners as pieces' corners, into +face+ (FacePieces.corner_from_list): x and y, then
            # without perspective u and v, in perspective u and v over the distance and w; then each one's
            # texel. Each is made in the pool, from its start, and the pool's next free place is the one
            # after the last. Changes s1 to s4.
            def emit_face_corners_made(asm, at, face, pool)
              asm.li(:s1, face)
              asm.lw(:s2, at + COUNT_OFFSET_BYTES, :gp)
              asm.sw(:s2, 0, :s1)
              asm.addiu(:s1, :s1, 4)
              asm.addiu(:s3, :gp, at + CORNERS_OFFSET_BYTES)
              asm.li(:s4, pool)
              asm.label("rt_fill_face_corner")
              asm.sw(:s4, 0, :s1)
              asm.lw(:t0, 0, :s3)
              asm.lw(:t1, 4, :s3)
              asm.sw(:t0, 0, :s4)
              asm.sw(:t1, 4, :s4)
              asm.lw(:t0, 8, :s3) # u
              asm.lw(:t1, 12, :s3) # v
              asm.lw(:t2, 16, :s3) # w
              asm.lw(:t3, at + SPANS_OFFSET_BYTES, :gp)
              asm.bne(:t3, :zero, "rt_fill_face_corner_perspective")
              asm.move(:t2, :zero)
              asm.b("rt_fill_face_corner_kept")
              asm.label("rt_fill_face_corner_perspective")
              emit_mul_fix(asm, :t0, :t0, :t2, 28)
              emit_mul_fix(asm, :t1, :t1, :t2, 28)
              asm.label("rt_fill_face_corner_kept")
              asm.sw(:t0, 8, :s4)
              asm.sw(:t1, 12, :s4)
              asm.sw(:t2, 16, :s4)
              asm.jal("rt_face_texel") { asm.move(:a0, :s4) }
              # The shade: the light held to nought to LIGHTEST, times the levels (nought for a face not lit).
              asm.lw(:t0, at + LEVELS_OFFSET_BYTES, :gp)
              asm.lw(:t1, 20, :s3) # the light
              asm.bgez(:t1, "rt_fill_face_light_not_below")
              asm.label("rt_fill_face_light_below")
              asm.move(:t1, :zero)
              asm.label("rt_fill_face_light_not_below")
              asm.srl(:t2, :t1, 16)
              asm.beq(:t2, :zero, "rt_fill_face_light_held")
              asm.label("rt_fill_face_light_above")
              asm.li(:t1, Nodes::FillFace::LIGHTEST)
              asm.label("rt_fill_face_light_held")
              asm.mult(:t1, :t0)
              asm.mflo(:t1)
              asm.sw(:t1, NUMBER_OFFSETS.fetch(FacePieces::SHADE), :s4)
              asm.addiu(:s1, :s1, 4)
              asm.addiu(:s4, :s4, CORNER_BYTES)
              asm.addiu(:s2, :s2, -1)
              asm.bne(:s2, :zero, "rt_fill_face_corner") { asm.addiu(:s3, :s3, LIST_CORNER_BYTES) }
              asm.sw(:s4, at + POOL_NEXT_OFFSET_BYTES, :gp)
            end

            # rt_face_sweep: a0 = a piece, a1 = which number it is cut along (X or Y's offset), a2 = where
            # each part before a line goes, a3 = two pieces, one after the other, the rest goes in by turns,
            # t4 = the routine each part of three corners or more is handed to in a0
            # (FacePieces.each_strip): cut along every multiple of SIDE_OFFSET_BYTES strictly inside the
            # piece, the part before each line in turn, then the rest. Keeps s0 to s7. Whatever of the
            # pool a part before a line took is handed back once it is sent; what the rest takes is the
            # caller's to hand back.
            def emit_sweep_routine(asm, at)
              asm.label("rt_face_sweep")
              emit_keep_registers(asm)
              asm.move(:s0, :a0) # the rest
              asm.move(:s1, :a1)
              asm.move(:s2, :a2)
              asm.move(:s3, :a3)
              asm.move(:s4, :t4)
              asm.jal("rt_face_extent") # a0 and a1 as handed in
              asm.move(:s5, :v1) # the most
              asm.lw(:t0, at + SIDE_OFFSET_BYTES, :gp)
              asm.subu(:t1, :zero, :t0)
              asm.and(:t1, :v0, :t1)
              asm.addu(:s6, :t1, :t0) # the first line
              asm.label("rt_face_sweep_line")
              asm.slt(:t0, :s6, :s5)
              asm.beq(:t0, :zero, "rt_face_sweep_rest")
              # The rest goes into whichever of the two it is not in now.
              asm.move(:s7, :s3)
              asm.bne(:s0, :s3, "rt_face_sweep_into")
              asm.label("rt_face_sweep_other")
              asm.addiu(:s7, :s3, POLYGON_BYTES)
              asm.label("rt_face_sweep_into")
              asm.move(:a0, :s0)
              asm.move(:a1, :s2)
              asm.move(:a2, :s7)
              asm.move(:a3, :s1)
              asm.jal("rt_face_cut") { asm.move(:t4, :s6) }
              asm.move(:s0, :s7)
              asm.lw(:t0, 0, :s2)
              asm.slti(:t0, :t0, 3)
              asm.bne(:t0, :zero, "rt_face_sweep_next")
              # What the part takes of the pool is handed back once it is sent: the rest's corners were
              # all made before it.
              asm.label("rt_face_sweep_part")
              asm.lw(:s7, at + POOL_NEXT_OFFSET_BYTES, :gp)
              asm.jalr(:s4) { asm.move(:a0, :s2) }
              asm.sw(:s7, at + POOL_NEXT_OFFSET_BYTES, :gp)
              asm.label("rt_face_sweep_next")
              asm.lw(:t0, at + SIDE_OFFSET_BYTES, :gp)
              asm.b("rt_face_sweep_line") { asm.addu(:s6, :s6, :t0) }
              asm.label("rt_face_sweep_rest")
              asm.lw(:t0, 0, :s0)
              asm.slti(:t0, :t0, 3)
              asm.bne(:t0, :zero, "rt_face_sweep_done")
              asm.label("rt_face_sweep_last")
              asm.jalr(:s4) { asm.move(:a0, :s0) }
              asm.label("rt_face_sweep_done")
              emit_return_with_registers(asm)
            end

            # rt_face_send_piece: a0 = a piece, cut on the picture until each part's places run no more than
            # FacePieces::PICTURE_REACH each way, and each part sent (FacePieces.send_cut_on_picture). s0 is
            # the part, s1 how many wait, s2 the picture's record, s3 where the part before a cut goes, s4 1
            # when the part past it is put waiting, s5 where the pool stood as the routine began.
            def emit_send_piece_routine(asm, at, polygon, waiting)
              part_a = polygon.call(:part_a)
              part_b = polygon.call(:part_b)
              asm.label("rt_face_send_piece")
              emit_keep_registers(asm)
              asm.move(:s0, :a0)
              asm.move(:s1, :zero)
              asm.lw(:s2, at + PICTURE_OFFSET_BYTES, :gp)
              asm.lw(:s5, at + POOL_NEXT_OFFSET_BYTES, :gp) # where the pool stood as this began
              asm.label("rt_face_send_part")
              asm.lw(:t0, 0, :s0)
              asm.slti(:t0, :t0, 3)
              asm.bne(:t0, :zero, "rt_face_send_waiting")
              asm.jal("rt_face_extents") { asm.move(:a0, :s0) }
              [[FacePieces::TEXEL_U, RECORD_ACROSS_MASK_OFFSET_BYTES], [FacePieces::TEXEL_V, RECORD_DOWN_MASK_OFFSET_BYTES]].each do |number, mask|
                fits = "rt_face_send_fits_#{number}"
                asm.lw(:v0, at + least_offset_bytes(number), :gp)
                asm.lw(:v1, at + least_offset_bytes(number) + 4, :gp)
                asm.lw(:t0, mask, :s2)
                asm.and(:t1, :v0, :t0) # the least, moved down to a whole picture
                asm.subu(:t2, :v1, :t1)
                asm.slti(:t2, :t2, FacePieces::PICTURE_REACH + 1)
                asm.bne(:t2, :zero, fits)
                asm.label("rt_face_send_cut_#{number}")
                asm.li(:a3, NUMBER_OFFSETS.fetch(number))
                asm.b("rt_face_send_cut") { asm.addiu(:t4, :t1, FacePieces::PICTURE_REACH) }
                asm.label(fits)
              end
              # A lit face: cut at the first whole level past the part's least shade, when its most is past
              # that (FacePieces.find_level_cut).
              asm.lw(:t0, at + LEVELS_OFFSET_BYTES, :gp)
              asm.beq(:t0, :zero, "rt_face_send_one_level")
              asm.label("rt_face_send_lit")
              asm.lw(:v0, at + least_offset_bytes(FacePieces::SHADE), :gp)
              asm.lw(:v1, at + least_offset_bytes(FacePieces::SHADE) + 4, :gp)
              asm.lui(:t0, 0xFFFF)
              asm.and(:t1, :v0, :t0)
              asm.lui(:t0, FacePieces::LEVEL_STEP >> 16)
              asm.addu(:t1, :t1, :t0) # the line
              asm.slt(:t2, :t1, :v1)
              asm.beq(:t2, :zero, "rt_face_send_one_level")
              asm.label("rt_face_send_cut_level")
              asm.li(:a3, NUMBER_OFFSETS.fetch(FacePieces::SHADE))
              asm.b("rt_face_send_cut") { asm.move(:t4, :t1) }
              asm.label("rt_face_send_one_level")
              asm.jal("rt_face_fan") { asm.move(:a0, :s0) }
              asm.label("rt_face_send_waiting")
              asm.beq(:s1, :zero, "rt_face_send_done")
              # The last to wait, copied out to be the part: its room is free for the next to wait. Of the
              # pool past where the piece below it was put waiting (or where this routine began), only this
              # part's corners are still used, so the rest is handed back.
              asm.addiu(:s1, :s1, -1)
              asm.li(:t0, POLYGON_BYTES)
              asm.mult(:s1, :t0)
              asm.mflo(:t0)
              asm.li(:a0, waiting)
              asm.addu(:a0, :a0, :t0)
              asm.li(:s0, part_a)
              asm.jal("rt_face_copy") { asm.move(:a1, :s0) }
              asm.move(:a1, :s5)
              asm.beq(:s1, :zero, "rt_face_send_mark_found")
              asm.label("rt_face_send_mark_below")
              asm.sll(:t0, :s1, 2)
              asm.addu(:t0, :t0, :gp)
              asm.lw(:a1, at + WAITING_MARKS_OFFSET_BYTES - 4, :t0)
              asm.label("rt_face_send_mark_found")
              asm.jal("rt_face_compact") { asm.move(:a0, :s0) }
              asm.b("rt_face_send_part")

              # Cut at t4 on the number at a3: the part before it into whichever of the two it is not in
              # now, and the part past it to wait, if there is room.
              asm.label("rt_face_send_cut")
              asm.li(:s3, part_a)
              asm.bne(:s0, :s3, "rt_face_send_cut_into")
              asm.label("rt_face_send_cut_other")
              asm.li(:s3, part_b)
              asm.label("rt_face_send_cut_into")
              asm.move(:a2, :zero)
              asm.move(:s4, :zero) # 1 once the part past the line is put waiting
              asm.slti(:t0, :s1, FacePieces::MOST_WAITING)
              asm.beq(:t0, :zero, "rt_face_send_cut_now")
              asm.label("rt_face_send_cut_wait")
              asm.li(:t0, POLYGON_BYTES)
              asm.mult(:s1, :t0)
              asm.mflo(:t0)
              asm.li(:a2, waiting)
              asm.addu(:a2, :a2, :t0)
              asm.addiu(:s1, :s1, 1)
              asm.li(:s4, 1)
              asm.label("rt_face_send_cut_now")
              asm.move(:a0, :s0)
              asm.jal("rt_face_cut") { asm.move(:a1, :s3) }
              # The pool's next free place once the part waiting is made, which is where it is handed back
              # to when that part comes off the stack.
              asm.beq(:s4, :zero, "rt_face_send_cut_made")
              asm.label("rt_face_send_cut_marked")
              asm.sll(:t0, :s1, 2)
              asm.addu(:t0, :t0, :gp)
              asm.lw(:t1, at + POOL_NEXT_OFFSET_BYTES, :gp)
              asm.sw(:t1, at + WAITING_MARKS_OFFSET_BYTES - 4, :t0)
              asm.label("rt_face_send_cut_made")
              asm.b("rt_face_send_part") { asm.move(:s0, :s3) }
              asm.label("rt_face_send_done")
              emit_return_with_registers(asm)
            end

            # rt_face_fan: a0 = a piece whose extents rt_face_extents has just found (rt_face_send_piece
            # calls it straight after), sent as a fan of textured triangles from its first corner
            # (FacePieces.send_fan): its places moved by whole pictures to start between nought and the
            # picture's size, each held to a byte, its corners rounded to whole pixels on the page drawn
            # into; a triangle with no area is left out.
            def emit_fan_routine(asm, at, memory, sent)
              h = Console::PS1Hardware
              port = h::GP0 & 0xFFFF
              offset = ->(number) { NUMBER_OFFSETS.fetch(number) }
              asm.label("rt_face_fan")
              emit_keep_registers(asm)
              asm.move(:s0, :a0)
              asm.lw(:s1, 0, :s0) # how many corners
              asm.lw(:s2, at + PICTURE_OFFSET_BYTES, :gp)
              asm.lw(:v0, at + least_offset_bytes(FacePieces::TEXEL_U), :gp)
              asm.lw(:t0, RECORD_ACROSS_MASK_OFFSET_BYTES, :s2)
              asm.and(:s3, :v0, :t0)
              asm.lw(:v0, at + least_offset_bytes(FacePieces::TEXEL_V), :gp)
              asm.lw(:t0, RECORD_DOWN_MASK_OFFSET_BYTES, :s2)
              asm.and(:s4, :v0, :t0)
              emit_fan_table(asm, at)
              asm.lw(:s5, Runtime.at(memory, Paint::PAGE_Y), :gp)
              # Each corner as it is sent: x, y, u | v << 8, and (y + the page's top) << 16 | x.
              asm.addiu(:t0, :s0, 4)
              asm.li(:t1, sent)
              asm.move(:t2, :s1)
              asm.label("rt_face_fan_corner")
              asm.lw(:t8, 0, :t0) # the corner
              asm.lw(:t3, offset.call(FacePieces::X), :t8)
              asm.addiu(:t3, :t3, 8)
              asm.sra(:t3, :t3, 4)
              asm.sw(:t3, 0, :t1)
              asm.lw(:t4, offset.call(FacePieces::Y), :t8)
              asm.addiu(:t4, :t4, 8)
              asm.sra(:t4, :t4, 4)
              asm.sw(:t4, 4, :t1)
              asm.addu(:t5, :t4, :s5)
              asm.sll(:t5, :t5, 16)
              asm.andi(:t6, :t3, 0xFFFF)
              asm.or(:t5, :t5, :t6)
              asm.sw(:t5, 12, :t1)
              [[FacePieces::TEXEL_U, :s3, :t5], [FacePieces::TEXEL_V, :s4, :t6]].each do |number, base, into|
                held = "rt_face_fan_held_#{number}"
                asm.lw(into, offset.call(number), :t8)
                asm.subu(into, into, base)
                asm.slti(:t7, into, 256)
                asm.bne(:t7, :zero, held)
                asm.label("rt_face_fan_most_#{number}")
                asm.li(into, 255)
                asm.label(held)
              end
              asm.sll(:t6, :t6, 8)
              asm.or(:t5, :t5, :t6)
              asm.sw(:t5, 8, :t1)
              asm.addiu(:t0, :t0, 4)
              asm.addiu(:t2, :t2, -1)
              asm.bne(:t2, :zero, "rt_face_fan_corner") { asm.addiu(:t1, :t1, SENT_CORNER_BYTES) }
              # The triangles: the first corner, then each next two. s6 is the second's place in the corners
              # sent, s7 where the last ends.
              asm.li(:s6, sent + SENT_CORNER_BYTES)
              asm.addiu(:t0, :s1, -1)
              asm.sll(:t0, :t0, 4)
              asm.li(:s7, sent)
              asm.addu(:s7, :s7, :t0)
              asm.label("rt_face_fan_triangle")
              asm.slt(:t0, :s6, :s7)
              asm.beq(:t0, :zero, "rt_face_fan_done")
              asm.li(:t5, sent)
              # Twice its area, signed: (bx - ax)(cy - ay) - (cx - ax)(by - ay).
              asm.lw(:t0, 0, :t5)
              asm.lw(:t1, 4, :t5)
              asm.lw(:t2, 0, :s6)
              asm.lw(:t3, 4, :s6)
              asm.lw(:t4, SENT_CORNER_BYTES, :s6)
              asm.lw(:t6, SENT_CORNER_BYTES + 4, :s6)
              asm.subu(:t2, :t2, :t0)
              asm.subu(:t3, :t3, :t1)
              asm.subu(:t4, :t4, :t0)
              asm.subu(:t6, :t6, :t1)
              asm.mult(:t2, :t6)
              asm.mflo(:t7)
              asm.mult(:t4, :t3)
              asm.mflo(:t8)
              asm.beq(:t7, :t8, "rt_face_fan_next")
              asm.label("rt_face_fan_send")
              # The words after the command, ready before it goes, as rt_gp0_word changes only t1 to t3.
              asm.lw(:t4, 12, :t5) # the first corner
              asm.lw(:t5, 8, :t5)
              asm.lw(:t0, at + TABLE_OFFSET_BYTES, :gp)
              asm.or(:t5, :t5, :t0)
              asm.lw(:t6, 12, :s6) # the second
              asm.lw(:t7, 8, :s6)
              asm.lw(:t0, RECORD_PAGE_OFFSET_BYTES, :s2)
              asm.or(:t7, :t7, :t0)
              asm.lw(:t8, SENT_CORNER_BYTES + 12, :s6) # the third
              asm.lw(:t9, SENT_CORNER_BYTES + 8, :s6)
              asm.jal("rt_gp0_word") { asm.lui(:a0, h::GP0_TEXTURED_TRIANGLE >> 16) }
              %i[t4 t5 t6 t7 t8 t9].each { |word| asm.sw(word, port, :t1) }
              asm.label("rt_face_fan_next")
              asm.b("rt_face_fan_triangle") { asm.addiu(:s6, :s6, SENT_CORNER_BYTES) }
              asm.label("rt_face_fan_done")
              emit_return_with_registers(asm)
            end

            # The colour table the piece in s0 names, into TABLE_OFFSET_BYTES, as the first corner of each
            # triangle carries it: the record's (in s2); on a lit face that moved down a line for each level
            # of the piece's least shade, held to the last level (FacePieces.send_fan), since a shading's
            # tables are a line apart (TextureMemory#shaded_table_field). Changes t0 to t3, v0 and v1.
            def emit_fan_table(asm, at)
              asm.lw(:t1, RECORD_TABLE_OFFSET_BYTES, :s2)
              asm.lw(:t0, at + LEVELS_OFFSET_BYTES, :gp)
              asm.beq(:t0, :zero, "rt_face_fan_table")
              asm.label("rt_face_fan_lit")
              asm.lw(:v0, at + least_offset_bytes(FacePieces::SHADE), :gp)
              asm.sra(:v0, :v0, 16) # the level
              asm.lw(:t0, at + LEVELS_OFFSET_BYTES, :gp)
              asm.slt(:t2, :v0, :t0)
              asm.bne(:t2, :zero, "rt_face_fan_level_held")
              asm.label("rt_face_fan_level_last")
              asm.addiu(:v0, :t0, -1)
              asm.label("rt_face_fan_level_held")
              asm.sll(:v0, :v0, 16 + 6) # a line of the table's field, in the top half of the word
              asm.lw(:t1, RECORD_TABLE_OFFSET_BYTES, :s2)
              asm.addu(:t1, :t1, :v0)
              asm.label("rt_face_fan_table")
              asm.sw(:t1, at + TABLE_OFFSET_BYTES, :gp)
            end

            # rt_face_cut: a0 = a piece, a1 = where the part at or before the line goes, a2 = where the part
            # at or past it goes (nought for either: not kept), a3 = the number cut on (its offset in a
            # corner), t4 = the line (FacePieces.cut). A corner on the line goes to both; where an edge
            # crosses it a corner is made once (FacePieces.corner_between, in the pool's next free place)
            # and goes to both. s0 is the piece, s5 its count, s6 the corner's number, s7 where its address
            # is in the piece and v1 the address; t5 and t6 how far the corner and the next are past the
            # line, t7 the next one's address; v0 the corner made.
            def emit_cut_routine(asm, at)
              asm.label("rt_face_cut")
              emit_keep_registers(asm)
              asm.move(:s0, :a0)
              asm.move(:s1, :a1)
              asm.move(:s2, :a2)
              asm.move(:s3, :a3)
              asm.move(:s4, :t4)
              [[:s1, "below"], [:s2, "above"]].each do |side, name|
                asm.beq(side, :zero, "rt_face_cut_no_#{name}")
                asm.label("rt_face_cut_empty_#{name}")
                asm.sw(:zero, 0, side)
                asm.label("rt_face_cut_no_#{name}")
              end
              asm.lw(:s5, 0, :s0)
              asm.move(:s6, :zero)
              asm.addiu(:s7, :s0, 4)
              asm.label("rt_face_cut_corner")
              asm.beq(:s6, :s5, "rt_face_cut_done")
              asm.addiu(:t0, :s6, 1)
              asm.bne(:t0, :s5, "rt_face_cut_next_found")
              asm.label("rt_face_cut_round")
              asm.move(:t0, :zero)
              asm.label("rt_face_cut_next_found")
              emit_corner_slot(asm, :t7, :t0)
              asm.addu(:t7, :t7, :s0)
              asm.lw(:t7, 4, :t7)
              asm.lw(:v1, 0, :s7)
              asm.addu(:t1, :t7, :s3)
              asm.lw(:t6, 0, :t1)
              asm.addu(:t1, :v1, :s3)
              asm.lw(:t5, 0, :t1)
              asm.subu(:t6, :t6, :s4)
              asm.subu(:t5, :t5, :s4)
              asm.bgtz(:t5, "rt_face_cut_not_below")
              asm.label("rt_face_cut_below")
              emit_append(asm, :s1, :v1, "rt_face_cut_not_below")
              asm.bltz(:t5, "rt_face_cut_not_above")
              asm.label("rt_face_cut_above")
              emit_append(asm, :s2, :v1, "rt_face_cut_not_above")
              # An edge crosses the line when neither end is on it and they are on its two sides.
              asm.beq(:t5, :zero, "rt_face_cut_step")
              asm.beq(:t6, :zero, "rt_face_cut_step")
              asm.xor(:t0, :t5, :t6)
              asm.bgez(:t0, "rt_face_cut_step")
              # From the end below the line (t0, how far past it t2) to the other (t1, t3).
              asm.label("rt_face_cut_crosses")
              asm.move(:t0, :v1)
              asm.move(:t1, :t7)
              asm.move(:t2, :t5)
              asm.bltz(:t5, "rt_face_cut_ends") { asm.move(:t3, :t6) }
              asm.label("rt_face_cut_from_next")
              asm.move(:t0, :t7)
              asm.move(:t1, :v1)
              asm.move(:t2, :t6)
              asm.move(:t3, :t5)
              asm.label("rt_face_cut_ends")
              asm.subu(:t3, :t3, :t2)
              asm.subu(:t2, :zero, :t2)
              asm.sll(:t2, :t2, FacePieces::SHARE_BITS)
              asm.div(:t2, :t3)
              # The corner made goes in the pool's next free place, while the divide works.
              asm.lw(:v0, at + POOL_NEXT_OFFSET_BYTES, :gp)
              asm.addiu(:a0, :v0, CORNER_BYTES)
              asm.sw(:a0, at + POOL_NEXT_OFFSET_BYTES, :gp)
              asm.mflo(:t8) # the share of the way along
              # On a line across the screen, only the numbers read again are stepped
              # (FacePieces::SCREEN_CUT_NUMBERS): the other of x and y, and what the texel is worked out
              # from. The texel itself is worked out where the corner is, below, and the number cut on is
              # the line. A nearness of a face not in perspective, and a shade of a face not lit, are
              # nought at both ends, so they are left nought rather than stepped. On the picture or
              # between levels only FacePieces::LATE_CUT_NUMBERS are stepped, the rest the start's.
              asm.sltiu(:t2, :s3, NUMBER_OFFSETS.fetch(FacePieces::U_SOURCE))
              asm.beq(:t2, :zero, "rt_face_cut_late")
              emit_screen_cut_corner(asm, at)
              asm.label("rt_face_cut_late")
              FacePieces::NUMBERS.times do |number|
                if FacePieces::LATE_CUT_NUMBERS.include?(number)
                  emit_step_number(asm, number)
                else
                  asm.lw(:a0, number * 4, :t0)
                  asm.sw(:a0, number * 4, :v0)
                end
              end
              asm.label("rt_face_cut_stepped")
              asm.addu(:t0, :v0, :s3)
              asm.sw(:s4, 0, :t0)
              # A line between two levels: the corner moved right by FacePieces::LEVEL_LINE_NUDGE.
              asm.li(:t0, NUMBER_OFFSETS.fetch(FacePieces::SHADE))
              asm.bne(:s3, :t0, "rt_face_cut_not_level")
              asm.label("rt_face_cut_level")
              asm.lw(:t0, NUMBER_OFFSETS.fetch(FacePieces::X), :v0)
              asm.addiu(:t0, :t0, FacePieces::LEVEL_LINE_NUDGE)
              asm.sw(:t0, NUMBER_OFFSETS.fetch(FacePieces::X), :v0)
              asm.label("rt_face_cut_not_level")
              # A line across the screen: the texel worked out where the corner is.
              asm.sltiu(:t0, :s3, NUMBER_OFFSETS.fetch(FacePieces::U_SOURCE))
              asm.beq(:t0, :zero, "rt_face_cut_made")
              asm.label("rt_face_cut_texel")
              asm.jal("rt_face_texel") { asm.move(:a0, :v0) }
              asm.label("rt_face_cut_made")
              emit_append(asm, :s1, :v0, "rt_face_cut_made_below")
              emit_append(asm, :s2, :v0, "rt_face_cut_step")
              asm.addiu(:s6, :s6, 1)
              asm.b("rt_face_cut_corner") { asm.addiu(:s7, :s7, 4) }
              asm.label("rt_face_cut_done")
              emit_return_with_registers(asm)
            end

            # The corner a cut across the screen makes, at v0, from the end below the line (t0) the share t8
            # of the way to the other (t1), then on to rt_face_cut_stepped: x stepped for a line along y (s3
            # Y's offset) and y for one along x, then FacePieces::SCREEN_CUT_NUMBERS' others.
            def emit_screen_cut_corner(asm, at)
              x = FacePieces::X
              y = FacePieces::Y
              asm.label("rt_face_cut_screen")
              asm.bne(:s3, :zero, "rt_face_cut_down")
              asm.label("rt_face_cut_across")
              emit_step_number(asm, y)
              asm.b("rt_face_cut_sources")
              asm.label("rt_face_cut_down")
              emit_step_number(asm, x)
              asm.label("rt_face_cut_sources")
              emit_step_number(asm, FacePieces::U_SOURCE)
              emit_step_number(asm, FacePieces::V_SOURCE)
              [[FacePieces::NEARNESS, SPANS_OFFSET_BYTES], [FacePieces::SHADE, LEVELS_OFFSET_BYTES]].each do |number, said|
                none = "rt_face_cut_none_#{number}"
                done = "rt_face_cut_stepped_#{number}"
                asm.lw(:t2, at + said, :gp)
                asm.beq(:t2, :zero, none)
                emit_step_number(asm, number)
                asm.b(done)
                asm.label(none)
                asm.sw(:zero, NUMBER_OFFSETS.fetch(number), :v0)
                asm.label(done)
              end
              asm.b("rt_face_cut_stepped")
            end

            # +number+ of the corner at t0 stepped the share t8 of the way to the one at t1, into the corner
            # at v0. Changes a0, a1 and t9.
            def emit_step_number(asm, number)
              asm.lw(:a0, number * 4, :t0)
              asm.lw(:a1, number * 4, :t1)
              asm.subu(:a1, :a1, :a0)
              emit_mul_fix(asm, :a1, :a1, :t8, FacePieces::SHARE_BITS)
              asm.addu(:a0, :a1, :a0)
              asm.sw(:a0, number * 4, :v0)
            end

            # rt_face_extent: a0 = a piece of one corner or more, a1 = a number's offset in a corner. v0 =
            # the least of that number, v1 the most. Changes t0 to t3.
            def emit_extent_routine(asm)
              asm.label("rt_face_extent")
              asm.lw(:t0, 0, :a0)
              asm.lw(:t2, 4, :a0)
              asm.addiu(:t1, :a0, 4)
              asm.addu(:t2, :t2, :a1)
              asm.lw(:v0, 0, :t2)
              asm.move(:v1, :v0)
              asm.label("rt_face_extent_corner")
              asm.addiu(:t0, :t0, -1)
              asm.beq(:t0, :zero, "rt_face_extent_done")
              asm.addiu(:t1, :t1, 4)
              asm.lw(:t2, 0, :t1)
              asm.addu(:t2, :t2, :a1)
              asm.lw(:t2, 0, :t2)
              asm.slt(:t3, :t2, :v0)
              asm.beq(:t3, :zero, "rt_face_extent_not_least")
              asm.label("rt_face_extent_least")
              asm.move(:v0, :t2)
              asm.label("rt_face_extent_not_least")
              asm.slt(:t3, :v1, :t2)
              asm.beq(:t3, :zero, "rt_face_extent_corner")
              asm.label("rt_face_extent_most")
              asm.b("rt_face_extent_corner") { asm.move(:v1, :t2) }
              asm.label("rt_face_extent_done")
              asm.jr(:ra)
            end

            # Where the least of +number+ (one of EXTENT_NUMBERS) over the piece being sent is in FACE; its
            # most is the word after.
            def least_offset_bytes(number) = EXTENTS_OFFSET_BYTES + (EXTENT_NUMBERS.index(number) * 8)

            # rt_face_extents: a0 = a piece of one corner or more; the least and the most of each of
            # EXTENT_NUMBERS over its corners into EXTENTS_OFFSET_BYTES, in one look at each corner rather
            # than one for each number. Changes t0 to t9 and v0.
            def emit_extents_routine(asm, at)
              kept = EXTENT_NUMBERS.zip(%i[t2 t4 t6], %i[t3 t5 t7])
              asm.label("rt_face_extents")
              asm.lw(:t0, 0, :a0)
              asm.lw(:v0, 4, :a0)
              asm.addiu(:t1, :a0, 4)
              kept.each do |number, least, most|
                asm.lw(least, NUMBER_OFFSETS.fetch(number), :v0)
                asm.move(most, least)
              end
              asm.label("rt_face_extents_corner")
              asm.addiu(:t0, :t0, -1)
              asm.beq(:t0, :zero, "rt_face_extents_done")
              asm.addiu(:t1, :t1, 4)
              asm.lw(:v0, 0, :t1)
              kept.each do |number, least, most|
                not_least = "rt_face_extents_not_least_#{number}"
                not_most = "rt_face_extents_not_most_#{number}"
                asm.lw(:t8, NUMBER_OFFSETS.fetch(number), :v0)
                asm.slt(:t9, :t8, least)
                asm.beq(:t9, :zero, not_least)
                asm.label("rt_face_extents_least_#{number}")
                asm.move(least, :t8)
                asm.label(not_least)
                asm.slt(:t9, most, :t8)
                asm.beq(:t9, :zero, not_most)
                asm.label("rt_face_extents_most_#{number}")
                asm.move(most, :t8)
                asm.label(not_most)
              end
              asm.b("rt_face_extents_corner")
              asm.label("rt_face_extents_done")
              kept.each do |number, least, most|
                asm.sw(least, at + least_offset_bytes(number), :gp)
                asm.sw(most, at + least_offset_bytes(number) + 4, :gp)
              end
              asm.jr(:ra)
            end

            # rt_face_copy: the piece at a0 copied to a1, its count and its corners' addresses. Changes t0
            # and t1.
            def emit_copy_routine(asm)
              asm.label("rt_face_copy")
              asm.lw(:t0, 0, :a0)
              asm.addiu(:t0, :t0, 1) # words, the count's with them
              asm.label("rt_face_copy_word")
              asm.lw(:t1, 0, :a0)
              asm.addiu(:a0, :a0, 4)
              asm.sw(:t1, 0, :a1)
              asm.addiu(:t0, :t0, -1)
              asm.bne(:t0, :zero, "rt_face_copy_word") { asm.addiu(:a1, :a1, 4) }
              asm.jr(:ra)
            end

            # rt_face_compact: a0 = a piece, a1 = a place in the pool past which only this piece's corners
            # are used. Each of its corners at or past a1 is moved down, in the piece's order, to start at
            # a1, and the pool's next free place is the one after the last. They go by +compacted+ first, so
            # no corner is written over before it is moved. Changes t0 to t7.
            def emit_compact_routine(asm, at, compacted)
              asm.label("rt_face_compact")
              asm.lw(:t0, 0, :a0)
              asm.addiu(:t1, :a0, 4)
              asm.li(:t2, compacted)
              asm.move(:t3, :a1) # where the next one moved ends up
              asm.label("rt_face_compact_corner")
              asm.beq(:t0, :zero, "rt_face_compact_moved")
              asm.lw(:t4, 0, :t1)
              asm.sltu(:t5, :t4, :a1)
              asm.bne(:t5, :zero, "rt_face_compact_next")
              asm.label("rt_face_compact_move")
              FacePieces::NUMBERS.times do |number|
                asm.lw(:t5, number * 4, :t4)
                asm.sw(:t5, number * 4, :t2)
              end
              asm.sw(:t3, 0, :t1)
              asm.addiu(:t2, :t2, CORNER_BYTES)
              asm.addiu(:t3, :t3, CORNER_BYTES)
              asm.label("rt_face_compact_next")
              asm.addiu(:t1, :t1, 4)
              asm.b("rt_face_compact_corner") { asm.addiu(:t0, :t0, -1) }
              asm.label("rt_face_compact_moved")
              asm.sw(:t3, at + POOL_NEXT_OFFSET_BYTES, :gp)
              asm.li(:t4, compacted)
              asm.move(:t6, :a1)
              asm.label("rt_face_compact_word")
              asm.beq(:t4, :t2, "rt_face_compact_done")
              asm.lw(:t5, 0, :t4)
              asm.addiu(:t4, :t4, 4)
              asm.sw(:t5, 0, :t6)
              asm.b("rt_face_compact_word") { asm.addiu(:t6, :t6, 4) }
              asm.label("rt_face_compact_done")
              asm.jr(:ra)
            end

            # rt_face_texel: a0 = a corner, its u and v the whole texel there (FacePieces.set_texel!): without
            # perspective a and b's whole parts; in perspective a and b times the distance, which is
            # IR::Reciprocals.distance of w (w held to LEAST, its leading eleven bits looked up, and the entry
            # moved down by as many places as w was, less two). Changes t0 to t6 and t9.
            def emit_texel_routine(asm, at)
              a = NUMBER_OFFSETS.fetch(FacePieces::U_SOURCE)
              b = NUMBER_OFFSETS.fetch(FacePieces::V_SOURCE)
              u = NUMBER_OFFSETS.fetch(FacePieces::TEXEL_U)
              v = NUMBER_OFFSETS.fetch(FacePieces::TEXEL_V)
              asm.label("rt_face_texel")
              asm.lw(:t0, at + SPANS_OFFSET_BYTES, :gp)
              asm.lw(:t1, a, :a0)
              asm.bne(:t0, :zero, "rt_face_texel_perspective")
              asm.lw(:t2, b, :a0)
              asm.sra(:t1, :t1, 16)
              asm.sw(:t1, u, :a0)
              asm.sra(:t2, :t2, 16)
              asm.jr(:ra) { asm.sw(:t2, v, :a0) }
              asm.label("rt_face_texel_perspective")
              asm.lw(:t2, NUMBER_OFFSETS.fetch(FacePieces::NEARNESS), :a0)
              asm.slti(:t3, :t2, IR::Reciprocals::LEAST)
              asm.beq(:t3, :zero, "rt_face_texel_far_enough")
              asm.label("rt_face_texel_too_far")
              asm.li(:t2, IR::Reciprocals::LEAST)
              asm.label("rt_face_texel_far_enough")
              # w is at least LEAST, so a quarter of it has eleven bits or more; it is moved down by 16, 8, 4,
              # 2 and 1 wherever what is left still has more than eleven, t4 counting how far.
              asm.srl(:t3, :t2, 2)
              asm.move(:t4, :zero)
              [16, 8, 4, 2, 1].each do |places|
                kept = "rt_face_texel_lead#{places}"
                asm.srl(:t5, :t3, places)
                asm.sltiu(:t6, :t5, IR::Reciprocals::LEADING)
                asm.bne(:t6, :zero, kept)
                asm.label("#{kept}_down")
                asm.move(:t3, :t5)
                asm.addiu(:t4, :t4, places)
                asm.label(kept)
              end
              asm.addiu(:t3, :t3, -IR::Reciprocals::LEADING)
              asm.sll(:t3, :t3, 2)
              asm.la(:t5, RECIPROCALS)
              asm.addu(:t5, :t5, :t3)
              asm.lw(:t5, 0, :t5)
              asm.srlv(:t5, :t5, :t4) # the distance
              emit_mul_fix(asm, :t1, :t1, :t5, 14)
              asm.sra(:t1, :t1, 16)
              asm.sw(:t1, u, :a0)
              asm.lw(:t2, b, :a0)
              emit_mul_fix(asm, :t2, :t2, :t5, 14)
              asm.sra(:t2, :t2, 16)
              asm.jr(:ra) { asm.sw(:t2, v, :a0) }
            end
          end
        end
      end
    end
  end
end
