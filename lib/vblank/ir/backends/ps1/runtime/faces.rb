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
          # own corners from there moved down to the start of what was handed back (rt_face_compact), once
          # more than a piece's worth lies there. Only
          # that piece can still be using any of it, so a piece cut on the picture again and again takes no
          # more of the pool than one cut once. POOL_CORNERS says why that is always enough.
          #
          # A LIT FACE (LIGHT_FLOOR_OFFSET_BYTES not nought) has a shade at each corner, its light, stepped like
          # the rest wherever a cut makes a corner, and is sent as shaded triangles, each corner with its
          # colour, which the chip steps across the triangle and multiplies each texel by (FacePieces says
          # why). It is cut no more than a face not lit.
          module Faces
            FACE = "rt face"
            PIECES = "face pieces"

            # FACE is in the scratchpad (Memory#reserve_scratchpad), the first thing given it, since every step
            # of filling a face reads it; so it is named from fp, which points there.
            FACE_BASE = :fp

            # THE STACK A FACE IS FILLED ON, in the scratchpad too. Each routine that calls another keeps
            # nine registers on the stack as it starts and takes them back as it ends (KEPT_REGISTERS),
            # and a face of many squares is hundreds of such calls; on the stack in main RAM each register
            # taken back waits for the bus. rt_fill_face moves the stack here for as long as it runs, and
            # back as it returns. The deepest it goes is FILL_STACK_FRAMES routines' worth: rt_fill_face,
            # rt_face_sweep down the rows, rt_face_row along each (or rt_face_sweep in its place, never
            # both), rt_face_send_piece (or rt_face_quad, which hands on to it in its place), and the cut or
            # the fan it calls. Every other routine those call keeps nothing on the stack. The interrupt can
            # come at the deepest, and the pad routines it calls keep their return addresses on the stack
            # too: INTERRUPT_STACK_BYTES more.
            FILL_STACK = "face fill stack"
            FILL_STACK_FRAMES = 5
            INTERRUPT_STACK_BYTES = 16

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
            # Nought for a face not lit; for a lit one, what its darkest light adds to a corner's colour, with
            # sixteen bits of fraction (FacePieces.light_floor).
            LIGHT_FLOOR_OFFSET_BYTES = 28
            # The least and the most of each of EXTENT_NUMBERS over the piece being sent, a word each, in
            # that order (rt_face_extents).
            EXTENTS_OFFSET_BYTES = 32
            EXTENT_NUMBERS = [FacePieces::TEXEL_U, FacePieces::TEXEL_V].freeze
            # Words of those rt_face_cell_sides borrows while it works, before any piece is sent: the face's
            # reach across and down, and its own return address.
            REACH_OFFSET_BYTES = EXTENTS_OFFSET_BYTES
            CELL_SIDES_RETURN_OFFSET_BYTES = EXTENTS_OFFSET_BYTES + 8
            # Words of those rt_face_row borrows between the pieces it sends, since nothing else reads them
            # until rt_face_send_piece sends one: how many corners the strip's run going back round passed
            # before a line, where in the strip it reached the line, and the crossing a square of four
            # corners made first (#emit_four_corner_cell).
            BACK_PASSED_OFFSET_BYTES = EXTENTS_OFFSET_BYTES
            BACK_REACHED_OFFSET_BYTES = EXTENTS_OFFSET_BYTES + 4
            CROSSING_OFFSET_BYTES = EXTENTS_OFFSET_BYTES + 8
            POOL_NEXT_OFFSET_BYTES = EXTENTS_OFFSET_BYTES + (EXTENT_NUMBERS.length * 8) # The pool's next free corner
            # The pool's next free corner as each piece waiting was put there, a word each.
            WAITING_MARKS_OFFSET_BYTES = POOL_NEXT_OFFSET_BYTES + 4
            # Where a face in perspective's squares start (FacePieces.each_cell): its least x, then its least
            # y, a word each, so a number's offset in a corner (X's or Y's) is its offset from here too.
            CELL_START_OFFSET_BYTES = WAITING_MARKS_OFFSET_BYTES + (FacePieces::MOST_WAITING * 4)
            # The width and the height of its cells (FacePieces.cell_side_shifts), in sixteenths, in the same
            # order, so a number's offset in a corner is its side's offset from here too.
            CELL_SIDE_OFFSET_BYTES = CELL_START_OFFSET_BYTES + 8
            # The line a cell's side past the face's right edge, and past its bottom, in sixteenths, a word
            # each in the same order as CELL_START_OFFSET_BYTES's: where the lines rt_face_sweep_lines and
            # rt_face_row_lines start end (FacePieces.past_edge?).
            STOP_LINE_OFFSET_BYTES = CELL_SIDE_OFFSET_BYTES + 8
            # Words rt_face_row keeps while it walks a strip: the strip's most x, and the corner of the
            # strip each run reached last, which a crossing on the edge from it is stepped from
            # (FacePieces::ChainWalk#cross).
            ROW_MOST_OFFSET_BYTES = STOP_LINE_OFFSET_BYTES + 8
            AHEAD_FROM_OFFSET_BYTES = ROW_MOST_OFFSET_BYTES + 4
            BEHIND_FROM_OFFSET_BYTES = AHEAD_FROM_OFFSET_BYTES + 4
            # rt_face_row_lines' return address, while it calls another routine.
            SEEK_RETURN_OFFSET_BYTES = BEHIND_FROM_OFFSET_BYTES + 4
            # The caller's stack pointer while rt_fill_face runs on FILL_STACK.
            CALLER_STACK_OFFSET_BYTES = SEEK_RETURN_OFFSET_BYTES + 4
            # The chip's texture window and drawing area as the last face set them, a word each, the window
            # first; nought while the chip has its own (rt_face_chip_put_back). See CHIP_WORDS.
            CHIP_OFFSET_BYTES = CALLER_STACK_OFFSET_BYTES + 4
            CHIP_WORDS = 3
            # The face's corners, as rt_face_corners read them from the list. Before them is room for a
            # list's header (Lists::HEADER), so that the list a place's drawing hands its corners in can be
            # kept here (Lowering::Faces#corners_list_in_face): its slots are then the corners, in the
            # scratchpad, and rt_face_corners has nothing to copy.
            CORNERS_LIST_OFFSET_BYTES = CHIP_OFFSET_BYTES + (CHIP_WORDS * 4)
            CORNERS_OFFSET_BYTES = CORNERS_LIST_OFFSET_BYTES + Lists::HEADER
            BYTES = CORNERS_OFFSET_BYTES + (Nodes::FillFace::MOST_CORNERS * LIST_CORNER_BYTES)

            # A corner in the pool: FacePieces::NUMBERS words, then the addresses of the two ends of the
            # edge a cut across the screen worked it out from (FacePieces::EDGE_START, EDGE_END); a corner of
            # the face has nought for its edge's end. A corner made otherwise leaves them as they were, and
            # nothing reads them.
            EDGE_START_OFFSET_BYTES = FacePieces::EDGE_START * 4
            EDGE_END_OFFSET_BYTES = FacePieces::EDGE_END * 4
            CORNER_BYTES = (FacePieces::EDGE_END + 1) * 4

            # A corner's light is held to LIGHTEST by testing its top half for nought (rt_fill_face), which
            # is right only while LIGHTEST is the whole bottom half.
            raise "rt_fill_face holds a light to 0xFFFF, not #{Nodes::FillFace::LIGHTEST}" unless Nodes::FillFace::LIGHTEST == 0xFFFF

            # A piece: its count, then the address of each corner.
            POLYGON_BYTES = 4 + (FacePieces::MOST_CORNERS * 4)
            # Where each number of a corner is (FacePieces::X to V).
            NUMBER_OFFSETS = (0...FacePieces::NUMBERS).to_h { |number| [number, number * 4] }.freeze
            # Must hold for rt_face_cell_sides, which reads a corner made in the pool and one as the list
            # holds it alike: x, y and the nearness at the same offsets in both.
            unless NUMBER_OFFSETS.values_at(FacePieces::X, FacePieces::Y, FacePieces::NEARNESS) == [0, 4, 16]
              raise "a corner in the pool keeps x, y and its nearness where the list's corner does not"
            end

            # The pieces, in PIECES: the face, two rests for cutting it into rows, a row, two rests for
            # cutting a row into squares, a square, two for cutting on the picture, then those waiting.
            POLYGONS = %i[face rows_a rows_b row squares_a squares_b square part_a part_b].freeze
            WAITING_OFFSET_BYTES = POLYGONS.length * POLYGON_BYTES
            # ...the corners rt_face_compact is moving, on their way down.
            COMPACT_OFFSET_BYTES = WAITING_OFFSET_BYTES + (FacePieces::MOST_WAITING * POLYGON_BYTES)
            POOL_OFFSET_BYTES = COMPACT_OFFSET_BYTES + (FacePieces::MOST_CORNERS * CORNER_BYTES)

            # HOW MANY CORNERS THE POOL HOLDS: the most that can be in use at once. A cut makes at most a
            # corner for each edge of the piece it cuts, so MOST_CORNERS. In use at once are the face's own,
            # the four cuts that hold it to the screen, every cut of rt_face_sweep's rest across the screen
            # one way and the other (its parts are handed back, the rest is not) or the two crossings
            # rt_face_row makes on each line along a strip in place of a cut, and on the picture and
            # between levels, for each piece waiting and for the part being sent, the corners it came off
            # the stack with and the cuts made since: three at the most before a part is sent, since a part
            # cut once across the picture, once down it and once between levels lies inside all three. The
            # smallest square is the one most cut.
            SWEEP_LINES = Console::PLAYSTATION.screen_size.sum { |side| (side >> FacePieces::LEAST_CELL_SHIFT) + 1 }
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

            FILL_STACK_BYTES = (FILL_STACK_FRAMES * KEPT_REGISTERS.length * 4) + INTERRUPT_STACK_BYTES

            # A FACE SENT STRAIGHT FROM ITS CORNERS (#emit_straight_face_records): one of up to STRAIGHT_CORNERS
            # corners that needs no cut at all, kept as it is worked out in the bottom of FILL_STACK, which
            # only the routines called from rt_fill_face use, and a straight face calls none that keeps
            # anything there. Each corner is STRAIGHT_CORNER_BYTES: its texel across, and down (and once the
            # face's least is known, the two as they are sent, in the first); its place as the chip takes it;
            # and on a lit face its colour.
            STRAIGHT_CORNERS = 4
            STRAIGHT_TEXEL_U_BYTES = 0
            STRAIGHT_TEXEL_V_BYTES = 4
            STRAIGHT_PLACE_BYTES = STRAIGHT_TEXEL_V_BYTES + 4
            STRAIGHT_COLOR_BYTES = STRAIGHT_PLACE_BYTES + 4
            STRAIGHT_CORNER_BYTES = STRAIGHT_COLOR_BYTES + 4
            # The interrupt can come while a straight face is worked out, and keeps its words below the stack
            # pointer, which stands below rt_fill_face's own kept registers.
            unless (STRAIGHT_CORNERS * STRAIGHT_CORNER_BYTES) + INTERRUPT_STACK_BYTES <= FILL_STACK_BYTES - (KEPT_REGISTERS.length * 4)
              raise "a straight face's corners do not fit below rt_fill_face's stack"
            end

            module_function

            # FILL_STACK and FACE, for a game that fills faces, in the scratchpad: asked for before anything
            # else is given any of it, so they are always there.
            def reserve(memory)
              memory.reserve_scratchpad(FILL_STACK, FILL_STACK_BYTES)
              memory.reserve_scratchpad(FACE, BYTES)
              [FILL_STACK, FACE].each do |name|
                raise LoweringError, "#{name} is not in the scratchpad" unless Memory.scratchpad?(memory[name])
              end
            end

            # The pieces' room, for a game that fills faces; asked for before the runtime is emitted, so
            # the region cleared at power-on takes it in.
            def reserve_pieces(memory) = memory.reserve(PIECES, PIECES_BYTES)

            def emit(asm, memory)
              at = Memory.distance_from_scratchpad(memory[FACE])
              pieces = memory[PIECES]
              polygon = ->(name) { pieces + (POLYGONS.index(name) * POLYGON_BYTES) }
              emit_face_corners_routine(asm, at)
              emit_fill_face_routine(asm, at, memory, polygon, pieces + POOL_OFFSET_BYTES)
              emit_sweep_routine(asm, at)
              emit_send_piece_routine(asm, at, polygon, pieces + WAITING_OFFSET_BYTES)
              emit_fan_routine(asm, at, memory)
              emit_cut_routine(asm, at)
              emit_extent_routine(asm)
              emit_extents_routine(asm, at)
              emit_copy_routine(asm)
              emit_compact_routine(asm, at, pieces + COMPACT_OFFSET_BYTES)
              emit_texel_routine(asm, at)
              emit_chip_put_back_routine(asm, at)
              emit_one_cell_routine(asm, at)
              emit_row_routine(asm, at, polygon)
              emit_column_corner_routine(asm, at)
              emit_quad_routine(asm, at, memory, polygon)
            end

            # WORKING OUT A FACE'S CELLS (rt_face_cell_sides), a section of its own, which the build places
            # after the game's code (Runtime.late_sections). It is a few hundred instructions run once for
            # each face cut into cells, a few dozen a pass, while the routines that send every face run
            # hundreds of times a pass beside the game's own. The processor keeps the last 4 KB of code it ran
            # by address, so code that grows ahead of those routines moves them and the game's code against
            # each other, and a place's pass gains or loses a frame on where they fall: placed last, this
            # routine moves nothing that runs often. Where a sweep's and a row's lines start and end
            # (rt_face_sweep_lines, rt_face_row_lines, which walks a strip's runs straight to a face's left
            # edge) are here for the same reason: once a sweep or a strip.
            def cells_section(memory)
              asm = R3000.new("runtime face cells")
              at = Memory.distance_from_scratchpad(memory[FACE])
              emit_cell_sides_routine(asm, at)
              emit_sweep_lines_routine(asm, at)
              emit_sweep_ending_routine(asm, at)
              emit_row_lines_routine(asm, at)
              emit_row_ending_routine(asm, at)
              asm.section
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

            # A FACE'S COMMANDS GO STRAIGHT TO THE CHIP'S PORT, not into the list of drawing commands the
            # painted screen sends by DMA (Runtime::DrawList). A place's faces are many small triangles the
            # chip draws faster than the processor works them out, so the processor seldom waits for it; and
            # writing each into the list in RAM cost the processor more than storing it to the port (Beetle
            # PSX measured, the floor of TestPS1PlaceFloorPace: its routines slower all round, and the list's
            # own routine dearer than the wait it saved). So rt_fill_face first has the list sent and drawn
            # (#emit_chip_word), which costs nothing while nothing else has been drawn since the last face, and
            # the face's commands follow it in the chip's queue.
            #
            # The command's first word through rt_gp0_port_word (Boot), +slot+ for the jump's delay slot.
            def emit_port_command(asm, &slot) = asm.jal("rt_gp0_port_word", &slot)

            # A triangle's words after its command's first, from +registers+ in order, stored to the port
            # through t1, which rt_gp0_port_word leaves holding the ports' base.
            def emit_words_stored(asm, registers)
              registers.each { |register| asm.sw(register, Console::PS1Hardware::GP0 & 0xFFFF, :t1) }
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
            # CORNERS_OFFSET_BYTES: straight from its slots when the list's slots are words, its first item
            # is in its first slot and it holds every number read (and not at all for the list kept there,
            # CORNERS_LIST_OFFSET_BYTES), and otherwise
            # through rt_list_get, so an index past the list's end stops the game as the interpreter's does
            # (Reference#check_list_index!).
            def emit_face_corners_routine(asm, at)
              most = Nodes::FillFace::MOST_CORNERS
              asm.label("rt_face_corners")
              asm.slti(:t0, :a1, most + 1)
              asm.bne(:t0, :zero, "rt_face_corners_held")
              asm.label("rt_face_corners_most")
              asm.li(:a1, most)
              asm.label("rt_face_corners_held")
              asm.sw(:a1, at + COUNT_OFFSET_BYTES, FACE_BASE)
              asm.slti(:t0, :a1, 3)
              asm.bne(:t0, :zero, "rt_face_corners_none")
              asm.sll(:t0, :a1, 1)
              asm.sll(:t1, :a1, 2)
              asm.addu(:t1, :t1, :t0) # six numbers a corner
              # A list of words whose first item is in its first slot, holding them all, is copied straight:
              # no index can be past its end, and its items are its slots in order.
              lists = Runtime::Lists
              asm.lhu(:t2, lists::FRONT, :a0)
              asm.bne(:t2, :zero, "rt_face_corners_one_by_one")
              asm.lhu(:t2, lists::SHIFT, :a0)
              asm.addiu(:t2, :t2, -2)
              asm.bne(:t2, :zero, "rt_face_corners_one_by_one")
              asm.lhu(:t2, lists::LENGTH, :a0)
              asm.sltu(:t2, :t2, :t1)
              asm.bne(:t2, :zero, "rt_face_corners_one_by_one")
              asm.label("rt_face_corners_straight")
              asm.addiu(:t2, :a0, lists::HEADER)
              asm.addiu(:t3, FACE_BASE, at + CORNERS_OFFSET_BYTES)
              # The list kept in FACE (CORNERS_LIST_OFFSET_BYTES) holds them where they are read already.
              asm.beq(:t2, :t3, "rt_face_corners_none")
              asm.label("rt_face_corners_word")
              asm.lw(:t4, 0, :t2)
              asm.addiu(:t2, :t2, 4)
              asm.sw(:t4, 0, :t3)
              asm.addiu(:t1, :t1, -1)
              asm.bne(:t1, :zero, "rt_face_corners_word") { asm.addiu(:t3, :t3, 4) }
              asm.jr(:ra)
              asm.label("rt_face_corners_one_by_one")
              asm.addiu(:sp, :sp, -16)
              asm.sw(:ra, 0, :sp)
              %i[s0 s1 s2].each_with_index { |register, i| asm.sw(register, 4 + (i * 4), :sp) }
              asm.move(:s0, :a0)
              asm.move(:s1, :t1)
              asm.move(:s2, :zero)
              asm.label("rt_face_corners_next")
              asm.move(:a0, :s0)
              asm.jal("rt_list_get") { asm.move(:a1, :s2) }
              asm.sll(:t0, :s2, 2)
              asm.addu(:t0, :t0, FACE_BASE)
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
            # window and drawing area are set for the face, and put back before the painted screen next
            # draws (rt_face_chip_put_back), since its drawing counts on the whole of video RAM and no
            # window (Runtime::Boot).
            def emit_fill_face_routine(asm, at, memory, polygon, pool)
              h = Console::PS1Hardware
              area = ->(offset) { Runtime.at(memory, Paint::AREA) + offset }
              face = polygon.call(:face)
              x = NUMBER_OFFSETS.fetch(FacePieces::X)
              y = NUMBER_OFFSETS.fetch(FacePieces::Y)
              asm.label("rt_fill_face")
              # On to FILL_STACK, the caller's stack pointer kept to go back to.
              asm.sw(:sp, at + CALLER_STACK_OFFSET_BYTES, FACE_BASE)
              asm.addiu(:sp, FACE_BASE, Memory.distance_from_scratchpad(memory[FILL_STACK]) +
                                        FILL_STACK_BYTES)
              emit_keep_registers(asm)
              [[LEFT_OFFSET_BYTES, Paint::AREA_LEFT_OFFSET_BYTES, :later], [TOP_OFFSET_BYTES, Paint::AREA_TOP_OFFSET_BYTES, :later],
               [RIGHT_OFFSET_BYTES, Paint::AREA_RIGHT_OFFSET_BYTES, :earlier], [BOTTOM_OFFSET_BYTES, Paint::AREA_BOTTOM_OFFSET_BYTES, :earlier]]
                .each do |edge, area_edge, keep|
                kept = "rt_fill_face_edge#{edge}"
                asm.lw(:t0, at + edge, FACE_BASE)
                asm.lw(:t1, area.call(area_edge), :gp)
                keep == :later ? asm.slt(:t2, :t0, :t1) : asm.slt(:t2, :t1, :t0)
                asm.beq(:t2, :zero, kept)
                asm.label("#{kept}_area")
                asm.move(:t0, :t1)
                asm.label(kept)
                asm.sw(:t0, at + edge, FACE_BASE)
              end
              # Nothing to draw between edges that meet or cross.
              %i[LEFT RIGHT TOP BOTTOM].each_slice(2) do |low, high|
                asm.lw(:t0, at + const_get("#{low}_OFFSET_BYTES"), FACE_BASE)
                asm.lw(:t1, at + const_get("#{high}_OFFSET_BYTES"), FACE_BASE)
                asm.slt(:t2, :t0, :t1)
                asm.beq(:t2, :zero, "rt_fill_face_done")
              end
              # s7 is 1 for a face sent straight from its corners (#emit_straight_face_records), nought for one
              # made into pieces.
              emit_straight_face_records(asm, at, memory)
              asm.b("rt_fill_face_chip") { asm.li(:s7, 1) }
              asm.label("rt_fill_face_pieces")
              asm.move(:s7, :zero)
              emit_face_corners_made(asm, at, face, pool)
              emit_jump_past_clip(asm, face)
              # Clipped to the screen's four sides, in sixteenths: above the left, below the right, then the
              # same down. Never to the face's edges, which the drawing area holds it to
              # (FacePieces.sent_unclipped? says why).
              [[x, 0, :above], [x, FacePieces::SCREEN_WIDTH * 16, :below], [y, 0, :above],
               [y, FacePieces::SCREEN_HEIGHT * 16, :below]].each do |number, line, side|
                from, below, above = side == :above ? [face, 0, polygon.call(:rows_a)] : [polygon.call(:rows_a), face, 0]
                asm.li(:a0, from)
                asm.li(:a1, below)
                asm.li(:a2, above)
                asm.li(:a3, number)
                asm.jal("rt_face_cut") { asm.li(:t4, line) }
              end
              asm.label("rt_fill_face_clipped")
              asm.li(:t0, face)
              asm.lw(:t0, 0, :t0)
              asm.slti(:t0, :t0, 3)
              asm.bne(:t0, :zero, "rt_fill_face_done")
              # The chip's texture window for the face's picture, and its drawing area the edges on the page
              # drawn into, the right and bottom ones the last drawn.
              #
              # A place's faces mostly show one picture between the same edges, so each word is sent only when
              # it differs from what the last face set (CHIP_OFFSET_BYTES), and the chip is given its own back
              # not after every face but before the next drawing that counts on them (rt_face_chip_put_back).
              asm.label("rt_fill_face_chip")
              asm.lw(:t0, at + PICTURE_OFFSET_BYTES, FACE_BASE)
              asm.lw(:a0, RECORD_WINDOW_OFFSET_BYTES, :t0)
              emit_chip_word(asm, at, 0)
              asm.lw(:s0, Runtime.at(memory, Paint::PAGE_Y), :gp)
              asm.lw(:t0, at + LEFT_OFFSET_BYTES, FACE_BASE)
              asm.lw(:t1, at + TOP_OFFSET_BYTES, FACE_BASE)
              asm.addu(:t1, :t1, :s0)
              asm.sll(:t1, :t1, 10)
              asm.or(:a0, :t0, :t1)
              asm.lui(:t0, h::GP0_DRAWING_AREA_TOP_LEFT >> 16)
              asm.or(:a0, :a0, :t0)
              emit_chip_word(asm, at, 1)
              asm.lw(:t0, at + RIGHT_OFFSET_BYTES, FACE_BASE)
              asm.addiu(:t0, :t0, -1)
              asm.lw(:t1, at + BOTTOM_OFFSET_BYTES, FACE_BASE)
              asm.addiu(:t1, :t1, -1)
              asm.addu(:t1, :t1, :s0)
              asm.sll(:t1, :t1, 10)
              asm.or(:a0, :t0, :t1)
              asm.lui(:t0, h::GP0_DRAWING_AREA_BOTTOM_RIGHT >> 16)
              asm.or(:a0, :a0, :t0)
              emit_chip_word(asm, at, 2)
              asm.bne(:s7, :zero, "rt_fill_face_straight")
              # Without perspective the face is one piece; in perspective it is cut into squares, a row at a
              # time.
              asm.lw(:t0, at + SPANS_OFFSET_BYTES, FACE_BASE)
              asm.bne(:t0, :zero, "rt_fill_face_squares")
              asm.label("rt_fill_face_one_piece")
              asm.li(:a0, face)
              asm.jal("rt_face_send_piece")
              asm.b("rt_fill_face_done")
              asm.label("rt_fill_face_squares")
              # The cells start at the face's least x and least y, and their width and height are the face's
              # own (FacePieces.cell_side_shifts).
              asm.li(:a0, face)
              asm.jal("rt_face_cell_sides")
              asm.sw(:v0, at + CELL_SIDE_OFFSET_BYTES + x, FACE_BASE)
              asm.sw(:v1, at + CELL_SIDE_OFFSET_BYTES + y, FACE_BASE)
              # A face reaching no further than a cell's width across and its height down crosses no line
              # strictly inside it (FacePieces.each_strip's first line is a side past its least), so it is
              # one cell, sent as it is without a sweep down it and along each row.
              asm.slt(:t0, :v0, :a2)
              asm.slt(:t1, :v1, :a3)
              asm.or(:t0, :t0, :t1)
              asm.beq(:t0, :zero, "rt_fill_face_one_piece")
              asm.li(:a0, face)
              asm.li(:a1, y)
              asm.li(:a2, polygon.call(:row))
              asm.li(:a3, polygon.call(:rows_a))
              asm.la(:t4, "rt_face_row")
              asm.jal("rt_face_sweep")
              asm.b("rt_fill_face_done")
              emit_straight_face_fan(asm, at, memory)
              asm.label("rt_fill_face_done")
              # The kept registers back, and the caller's stack.
              KEPT_REGISTERS.each_with_index { |register, i| asm.lw(register, i * 4, :sp) }
              asm.lw(:sp, at + CALLER_STACK_OFFSET_BYTES, FACE_BASE)
              asm.jr(:ra)
            end

            # The chip word in a0 (+which+ of CHIP_WORDS) sent unless the last face sent the same. Changes t0 to t3.
            #
            # The texture window, the first, is also where the list of drawing commands asks to be drawn
            # first: every command put in it sets the kept window to nought, so the face sending its window
            # has the list sent and drawn before it, and its own commands follow the list's in the chip's
            # queue (Runtime::DrawList#face_window_offset_bytes).
            def emit_chip_word(asm, at, which)
              kept = at + CHIP_OFFSET_BYTES + (which * 4)
              same = "rt_fill_face_chip_same_#{which}"
              asm.lw(:t0, kept, FACE_BASE)
              asm.beq(:t0, :a0, same)
              asm.label("rt_fill_face_chip_send_#{which}")
              asm.jal("rt_draw_list_finish") if which.zero?
              emit_port_command(asm)
              asm.sw(:a0, kept, FACE_BASE)
              asm.label(same)
            end

            # rt_face_chip_put_back: the chip's texture window and drawing area given back their own, the
            # whole of video RAM and no window, which the painted screen's drawing counts on (Runtime::Boot),
            # when a face has set them since they last were (CHIP_OFFSET_BYTES). The painted screen's
            # routines that draw call it first (#emit_chip_put_back_call), and the words go into the list of
            # drawing commands ahead of theirs (Runtime::DrawList). Changes t0 to t3, t8 and v1.
            def emit_chip_put_back_routine(asm, at)
              h = Console::PS1Hardware
              # The drawing area's first word, not the window's, which the list of drawing commands sets to
              # nought for a reason of its own (#emit_chip_word).
              asm.label("rt_face_chip_put_back")
              asm.lw(:t0, at + CHIP_OFFSET_BYTES + 4, FACE_BASE)
              asm.beq(:t0, :zero, "rt_face_chip_own")
              asm.label("rt_face_chip_set")
              asm.move(:t8, :ra)
              asm.move(:v1, :a0)
              DrawList.emit_command(asm, 1) { asm.lui(:a0, h::GP0_TEXTURE_WINDOW >> 16) }
              DrawList.emit_command(asm, 1) { asm.lui(:a0, h::GP0_DRAWING_AREA_TOP_LEFT >> 16) }
              asm.li(:a0, h::GP0_DRAWING_AREA_BOTTOM_RIGHT | (h::VRAM_WIDTH - 1) | ((h::VRAM_HEIGHT - 1) << 10))
              DrawList.emit_command(asm, 1)
              CHIP_WORDS.times { |which| asm.sw(:zero, at + CHIP_OFFSET_BYTES + (which * 4), FACE_BASE) }
              asm.move(:a0, :v1)
              asm.move(:ra, :t8)
              asm.label("rt_face_chip_own")
              asm.jr(:ra)
            end

            # A call of rt_face_chip_put_back from a routine that has not kept its return address yet: t9
            # holds it meanwhile. Changes t0 to t3, t8, t9 and v1.
            def emit_chip_put_back_call(asm)
              asm.move(:t9, :ra)
              asm.jal("rt_face_chip_put_back")
              asm.move(:ra, :t9)
            end

            # A FACE THE CHIP CAN DRAW AS IT IS, the way the console's own games sent most of a level's faces:
            # one of up to STRAIGHT_CORNERS corners that FacePieces.triangles would send without a cut, since
            # it is not clipped (FacePieces.sent_unclipped?), in perspective it lies inside one square
            # (FacePieces.each_cell), and its place on the picture reaches no further than PICTURE_REACH
            # (FacePieces.find_picture_cut). Its triangles are then FacePieces.send_fan's of its own corners,
            # and are sent from the corners rt_face_corners read, with no piece made in the pool, no extent
            # found twice and no fan routine to read them again: most faces of a place far off, a few pixels
            # big, cost little more than the words the chip is sent.
            #
            # Falls through with each corner's record made in FILL_STACK (STRAIGHT_ fields) and s7 free, or goes
            # to rt_fill_face_pieces, where the face is worked out from its corners afresh, as before. Changes
            # t0 to t9, a0 to a3, v0, v1 and s0 to s7.
            def emit_straight_face_records(asm, at, memory)
              records = Memory.distance_from_scratchpad(memory[FILL_STACK])
              emit_straight_face_bounds(asm, at)
              # Each corner's texel, worked out from the corner as rt_fill_face_corner works it out, and its
              # least and most each way: s4 and s5 across, s6 and s0 down. s7 is the page drawn into's top.
              asm.lw(:s7, Runtime.at(memory, Paint::PAGE_Y), :gp)
              asm.addiu(:s1, FACE_BASE, at + CORNERS_OFFSET_BYTES)
              asm.addiu(:s3, FACE_BASE, records)
              asm.lw(:s2, at + COUNT_OFFSET_BYTES, FACE_BASE)
              asm.li(:s4, 0x7FFF_FFFF)
              asm.li(:s5, -0x8000_0000)
              asm.move(:s6, :s4)
              asm.move(:s0, :s5)
              asm.label("rt_face_straight_corner")
              emit_straight_corner_texel(asm, at) do
                # Its place as the chip takes it (FacePieces.send_fan): rounded to whole pixels, and down from
                # the top of the page drawn into.
                asm.lw(:t2, 0, :s1)
                asm.lw(:t3, 4, :s1)
                asm.addiu(:t2, :t2, 8)
                asm.sra(:t2, :t2, 4)
                asm.addiu(:t3, :t3, 8)
                asm.sra(:t3, :t3, 4)
                asm.addu(:t3, :t3, :s7)
                asm.sll(:t3, :t3, 16)
                asm.andi(:t2, :t2, 0xFFFF)
                asm.or(:t3, :t3, :t2)
                asm.sw(:t3, STRAIGHT_PLACE_BYTES, :s3)
              end
              asm.sw(:t0, STRAIGHT_TEXEL_U_BYTES, :s3)
              asm.sw(:t1, STRAIGHT_TEXEL_V_BYTES, :s3)
              [[:t0, :s4, :s5, "u"], [:t1, :s6, :s0, "v"]].each do |texel, least, most, name|
                emit_keep_least_and_most(asm, texel, least, most, "rt_face_straight_#{name}")
              end
              emit_straight_corner_color(asm, at)
              asm.addiu(:s1, :s1, LIST_CORNER_BYTES)
              asm.addiu(:s2, :s2, -1)
              asm.bne(:s2, :zero, "rt_face_straight_corner") { asm.addiu(:s3, :s3, STRAIGHT_CORNER_BYTES) }
              # The picture's place moved down to a whole picture each way, and the face's reach from there no
              # further than PICTURE_REACH (rt_face_send_piece's test): t4 and t5 the moves.
              asm.lw(:t0, at + PICTURE_OFFSET_BYTES, FACE_BASE)
              [[:s4, :s5, RECORD_ACROSS_MASK_OFFSET_BYTES, :t4], [:s6, :s0, RECORD_DOWN_MASK_OFFSET_BYTES, :t5]].each do |least, most, mask, base|
                asm.lw(base, mask, :t0)
                asm.and(base, least, base)
                asm.subu(:t1, most, base)
                asm.slti(:t1, :t1, FacePieces::PICTURE_REACH + 1)
                asm.beq(:t1, :zero, "rt_fill_face_pieces")
              end
              # Each corner's texel as it is sent: moved by the whole pictures, each held to a byte, u | v << 8.
              asm.addiu(:s3, FACE_BASE, records)
              asm.lw(:s2, at + COUNT_OFFSET_BYTES, FACE_BASE)
              asm.label("rt_face_straight_texel")
              asm.lw(:t0, STRAIGHT_TEXEL_U_BYTES, :s3)
              asm.lw(:t1, STRAIGHT_TEXEL_V_BYTES, :s3)
              [[:t0, :t4, "u"], [:t1, :t5, "v"]].each do |texel, base, name|
                held = "rt_face_straight_held_#{name}"
                asm.subu(texel, texel, base)
                asm.slti(:t2, texel, 256)
                asm.bne(:t2, :zero, held)
                asm.label("rt_face_straight_most_#{name}")
                asm.li(texel, 255)
                asm.label(held)
              end
              asm.sll(:t1, :t1, 8)
              asm.or(:t0, :t0, :t1)
              asm.sw(:t0, STRAIGHT_TEXEL_U_BYTES, :s3)
              asm.addiu(:s2, :s2, -1)
              asm.bne(:s2, :zero, "rt_face_straight_texel") { asm.addiu(:s3, :s3, STRAIGHT_CORNER_BYTES) }
            end

            # The texel at the straight face's corner, as the list holds it at s1, into t0 (across) and t1
            # (down): the sums rt_fill_face_corner and rt_face_texel make for a corner made in the pool
            # (FacePieces.corner_from_list, .set_texel!), written here rather than called, and with each
            # multiply started before the instructions that do not wait on it, so the processor goes on
            # while the multiplier works. The block's instructions, which wait on none of it, go where the
            # processor would otherwise wait longest. Written again rather than calling rt_face_texel because,
            # measured on the floor of a thousand faces in perspective (the commit that made it says by how
            # much), the call cost each corner its sources stored and read back, a call and a return, and two
            # multiplies the processor sat waiting on; it is four corners a face for most of a place's faces.
            # The checked run holds the two to the same texels, through the picture. Changes t0 to t9.
            def emit_straight_corner_texel(asm, at)
              asm.lw(:t0, 8, :s1) # u
              asm.lw(:t1, 12, :s1) # v
              asm.lw(:t2, 16, :s1) # w
              asm.lw(:t3, at + SPANS_OFFSET_BYTES, FACE_BASE)
              asm.bne(:t3, :zero, "rt_face_straight_perspective")
              asm.sra(:t0, :t0, 16)
              asm.sra(:t1, :t1, 16)
              yield
              asm.b("rt_face_straight_texel_made")
              asm.label("rt_face_straight_perspective")
              # u w, as w is held to its least and its leading eleven bits found (rt_face_texel's sums).
              asm.mult(:t0, :t2)
              asm.slti(:t3, :t2, IR::Reciprocals::LEAST)
              asm.beq(:t3, :zero, "rt_face_straight_far_enough") { asm.move(:t3, :t2) }
              asm.label("rt_face_straight_too_far")
              asm.li(:t3, IR::Reciprocals::LEAST)
              asm.label("rt_face_straight_far_enough")
              asm.srl(:t3, :t3, 2)
              asm.move(:t4, :zero)
              [16, 8, 4, 2, 1].each do |places|
                kept = "rt_face_straight_lead#{places}"
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
              emit_product_bits(asm, :t6, 28) # u over the distance
              asm.mult(:t1, :t2) # v w
              asm.srlv(:t5, :t5, :t4) # the distance
              emit_product_bits(asm, :t7, 28) # v over the distance
              asm.mult(:t6, :t5)
              yield
              emit_product_bits(asm, :t0, 14)
              asm.mult(:t7, :t5)
              asm.sra(:t0, :t0, 16)
              emit_product_bits(asm, :t1, 14)
              asm.sra(:t1, :t1, 16)
              asm.label("rt_face_straight_texel_made")
            end

            # The product in HI and LO's bits from +bits+ up, into +into+, as #emit_mul_fix keeps them. Changes t9.
            def emit_product_bits(asm, into, bits)
              asm.mflo(into)
              asm.mfhi(:t9)
              asm.srl(into, into, bits)
              asm.sll(:t9, :t9, 32 - bits)
              asm.or(into, into, :t9)
            end

            # The first part of #emit_straight_face_records: on to rt_fill_face_pieces for a face of more than
            # STRAIGHT_CORNERS corners, one FacePieces.sent_unclipped? would clip, or one in perspective not
            # found to be one cell by the quick tests below (FacePieces.each_cell might cut it). t1 to t4 are the least and most a corner may be across and down, in
            # sixteenths; t7 to v1 the face's own.
            def emit_straight_face_bounds(asm, at)
              asm.lw(:t5, at + COUNT_OFFSET_BYTES, FACE_BASE)
              asm.slti(:t0, :t5, STRAIGHT_CORNERS + 1)
              asm.beq(:t0, :zero, "rt_fill_face_pieces")
              asm.lw(:t0, at + SPANS_OFFSET_BYTES, FACE_BASE)
              asm.move(:t1, :zero)
              asm.li(:t2, FacePieces::SCREEN_WIDTH * 16)
              asm.move(:t3, :zero)
              asm.li(:t4, FacePieces::SCREEN_HEIGHT * 16)
              asm.addiu(:t6, FACE_BASE, at + CORNERS_OFFSET_BYTES)
              asm.lw(:t7, 0, :t6)
              asm.move(:t8, :t7)
              asm.lw(:t9, 4, :t6)
              asm.move(:v1, :t9)
              asm.label("rt_face_straight_reach")
              asm.lw(:a0, 0, :t6)
              asm.lw(:a1, 4, :t6)
              [[:a0, :t1, :below], [:a0, :t2, :above], [:a1, :t3, :below], [:a1, :t4, :above]].each do |number, bound, past|
                past == :below ? asm.slt(:a2, number, bound) : asm.slt(:a2, bound, number)
                asm.bne(:a2, :zero, "rt_fill_face_pieces")
              end
              emit_keep_least_and_most(asm, :a0, :t7, :t8, "rt_face_straight_x")
              emit_keep_least_and_most(asm, :a1, :t9, :v1, "rt_face_straight_y")
              asm.addiu(:t5, :t5, -1)
              asm.bne(:t5, :zero, "rt_face_straight_reach") { asm.addiu(:t6, :t6, LIST_CORNER_BYTES) }
              asm.beq(:t0, :zero, "rt_face_straight_square")
              # In perspective, one cell (FacePieces.cell_side_shifts). A face reaching no further than the
              # least side either way, most of a place's faces, a few pixels big, is within its cells whatever
              # their sides; one off by no more than allowed whole is one cell (rt_face_one_cell). Any other
              # is made into pieces, where its cells' sides are worked out in full (rt_face_cell_sides), and
              # one that is one cell after all is sent as it is from there, as the same triangles.
              least_side = 16 << FacePieces::LEAST_CELL_SHIFT
              asm.subu(:t1, :t8, :t7)
              asm.subu(:t2, :v1, :t9)
              asm.slti(:a0, :t1, least_side + 1)
              asm.slti(:a1, :t2, least_side + 1)
              asm.and(:a0, :a0, :a1)
              asm.bne(:a0, :zero, "rt_face_straight_square")
              emit_straight_face_nearness(asm, at)
              emit_longer(asm, :t9, :t1, :t2, "rt_face_straight")
              asm.jal("rt_face_one_cell")
              asm.bne(:v0, :zero, "rt_fill_face_pieces")
              asm.label("rt_face_straight_square")
            end

            # t5 and t6, the least and the most nearness of the straight face's corners as the list holds
            # them (rt_face_corners). Changes t3, t4, a0 and a3.
            def emit_straight_face_nearness(asm, at)
              w = NUMBER_OFFSETS.fetch(FacePieces::NEARNESS)
              asm.addiu(:t3, FACE_BASE, at + CORNERS_OFFSET_BYTES)
              asm.lw(:t5, w, :t3)
              asm.move(:t6, :t5)
              asm.lw(:t4, at + COUNT_OFFSET_BYTES, FACE_BASE)
              asm.label("rt_face_straight_nearness")
              asm.addiu(:t4, :t4, -1)
              asm.beq(:t4, :zero, "rt_face_straight_nearness_done")
              asm.addiu(:t3, :t3, LIST_CORNER_BYTES)
              asm.lw(:a0, w, :t3)
              emit_keep_least_and_most(asm, :a0, :t5, :t6, "rt_face_straight_w")
              asm.b("rt_face_straight_nearness")
              asm.label("rt_face_straight_nearness_done")
            end

            # +number+ kept in +least+ when it is less and in +most+ when it is more; +label+ names the places
            # between. Changes +scratch+.
            def emit_keep_least_and_most(asm, number, least, most, label, scratch: :a3)
              asm.slt(scratch, number, least)
              asm.beq(scratch, :zero, "#{label}_not_least")
              asm.label("#{label}_least")
              asm.move(least, number)
              asm.label("#{label}_not_least")
              asm.slt(scratch, most, number)
              asm.beq(scratch, :zero, "#{label}_not_most")
              asm.label("#{label}_most")
              asm.move(most, number)
              asm.label("#{label}_not_most")
            end

            # A straight face's corner's colour at s3, from its light at s1, on a lit face (FacePieces.corner_from_list
            # and .corner_color): the light held to nought to LIGHTEST, moved up seven bits, the light floor
            # added, and its whole part held to FULL_COLOR in each of the word's three bytes. A face not lit
            # sends none.
            def emit_straight_corner_color(asm, at)
              asm.lw(:t0, at + LIGHT_FLOOR_OFFSET_BYTES, FACE_BASE)
              asm.beq(:t0, :zero, "rt_face_straight_colored")
              asm.lw(:t1, 20, :s1) # the light
              asm.bgez(:t1, "rt_face_straight_light_not_below")
              asm.label("rt_face_straight_light_below")
              asm.move(:t1, :zero)
              asm.label("rt_face_straight_light_not_below")
              asm.srl(:t2, :t1, 16)
              asm.beq(:t2, :zero, "rt_face_straight_light_held")
              asm.label("rt_face_straight_light_above")
              asm.li(:t1, Nodes::FillFace::LIGHTEST)
              asm.label("rt_face_straight_light_held")
              asm.sll(:t1, :t1, 7)
              asm.addu(:t1, :t1, :t0)
              asm.srl(:t1, :t1, 16)
              asm.sltiu(:t2, :t1, FacePieces::FULL_COLOR + 1)
              asm.bne(:t2, :zero, "rt_face_straight_color_held")
              asm.label("rt_face_straight_color_full")
              asm.li(:t1, FacePieces::FULL_COLOR)
              asm.label("rt_face_straight_color_held")
              asm.sll(:t2, :t1, 8)
              asm.or(:t2, :t2, :t1)
              asm.sll(:t1, :t1, 16)
              asm.or(:t1, :t1, :t2)
              asm.sw(:t1, STRAIGHT_COLOR_BYTES, :s3)
              asm.label("rt_face_straight_colored")
            end

            # rt_fill_face_straight: the straight face's triangles, a fan from its first corner as
            # FacePieces.send_fan sends it, each with an area sent (rt_face_fan's test), from the records
            # #emit_straight_face_records made. s5 is the first corner's record, s6 the second's of the
            # triangle, s2 how many triangles are left, s1 the picture's record and s4 not nought on a lit
            # face. On to rt_fill_face_done once sent.
            def emit_straight_face_fan(asm, at, memory)
              h = Console::PS1Hardware
              records = Memory.distance_from_scratchpad(memory[FILL_STACK])
              place = STRAIGHT_PLACE_BYTES
              next_place = STRAIGHT_CORNER_BYTES + place
              asm.label("rt_fill_face_straight")
              asm.lw(:s1, at + PICTURE_OFFSET_BYTES, FACE_BASE)
              asm.lw(:s4, at + LIGHT_FLOOR_OFFSET_BYTES, FACE_BASE)
              asm.addiu(:s5, FACE_BASE, records)
              asm.addiu(:s6, :s5, STRAIGHT_CORNER_BYTES)
              asm.lw(:s2, at + COUNT_OFFSET_BYTES, FACE_BASE)
              asm.addiu(:s2, :s2, -2)
              asm.label("rt_fill_face_straight_triangle")
              asm.lw(:t4, place, :s5)
              asm.lw(:t6, place, :s6)
              asm.lw(:t8, next_place, :s6)
              # Twice its area, signed, from the places sent: the page's top is in every y, and drops out.
              asm.sll(:a0, :t4, 16)
              asm.sra(:a0, :a0, 16)
              asm.sra(:a1, :t4, 16)
              [[:t6, :a2, :a3], [:t8, :t0, :v0]].each do |corner, across, down|
                asm.sll(across, corner, 16)
                asm.sra(across, across, 16)
                asm.subu(across, across, :a0)
                asm.sra(down, corner, 16)
                asm.subu(down, down, :a1)
              end
              asm.mult(:a2, :v0)
              asm.mflo(:t2)
              asm.mult(:t0, :a3)
              asm.mflo(:t3)
              asm.beq(:t2, :t3, "rt_fill_face_straight_next")
              asm.label("rt_fill_face_straight_send")
              asm.lw(:t5, STRAIGHT_TEXEL_U_BYTES, :s5)
              asm.lw(:t0, RECORD_TABLE_OFFSET_BYTES, :s1)
              asm.or(:t5, :t5, :t0)
              asm.lw(:t7, STRAIGHT_TEXEL_U_BYTES, :s6)
              asm.lw(:t0, RECORD_PAGE_OFFSET_BYTES, :s1)
              asm.or(:t7, :t7, :t0)
              asm.lw(:t9, STRAIGHT_CORNER_BYTES + STRAIGHT_TEXEL_U_BYTES, :s6)
              asm.bne(:s4, :zero, "rt_fill_face_straight_shaded")
              asm.label("rt_fill_face_straight_raw")
              emit_port_command(asm) { asm.lui(:a0, h::GP0_TEXTURED_TRIANGLE >> 16) }
              emit_words_stored(asm, %i[t4 t5 t6 t7 t8 t9])
              asm.b("rt_fill_face_straight_next")
              asm.label("rt_fill_face_straight_shaded")
              asm.lw(:a0, STRAIGHT_COLOR_BYTES, :s5)
              asm.lw(:a1, STRAIGHT_COLOR_BYTES, :s6)
              asm.lw(:a2, STRAIGHT_CORNER_BYTES + STRAIGHT_COLOR_BYTES, :s6)
              asm.lui(:t0, h::GP0_SHADED_TEXTURED_TRIANGLE >> 16)
              emit_port_command(asm) { asm.or(:a0, :a0, :t0) }
              emit_words_stored(asm, %i[t4 t5 a1 t6 t7 a2 t8 t9])
              asm.label("rt_fill_face_straight_next")
              asm.addiu(:s2, :s2, -1)
              asm.bne(:s2, :zero, "rt_fill_face_straight_triangle") { asm.addiu(:s6, :s6, STRAIGHT_CORNER_BYTES) }
              asm.b("rt_fill_face_done")
            end

            # On to rt_fill_face_clipped, past the cuts to the screen, for a face FacePieces.sent_unclipped?
            # holds is sent as it is: every corner on the screen.
            def emit_jump_past_clip(asm, face)
              [[FacePieces::X, FacePieces::SCREEN_WIDTH], [FacePieces::Y, FacePieces::SCREEN_HEIGHT]].each do |number, side|
                asm.li(:a0, face)
                asm.jal("rt_face_extent") { asm.li(:a1, NUMBER_OFFSETS.fetch(number)) }
                asm.bltz(:v0, "rt_fill_face_clip")
                asm.label("rt_fill_face_bounds_#{number}")
                asm.slti(:t0, :v1, (side * 16) + 1)
                asm.beq(:t0, :zero, "rt_fill_face_clip")
              end
              asm.b("rt_fill_face_clipped")
              asm.label("rt_fill_face_clip")
            end

            # rt_face_cell_sides: a0 = a piece of three corners or more, the face as clipped. v0 = the width of
            # the cells it is cut into and v1 their height, in sixteenths (FacePieces.cell_side_shifts); a2 =
            # its reach across and a3 down, in sixteenths; and its least x and y in CELL_START_OFFSET_BYTES.
            # Changes t0 to t9 and a0 to a3.
            #
            # It keeps nothing on the stack: the routines it calls (rt_face_one_cell, and the test of one
            # pair of sides, rt_face_cell_sides_within) are leaves, and its own return address waits in
            # CELL_SIDES_RETURN_OFFSET_BYTES. A look at the corners for their least and most; a face that is
            # one cell whole (rt_face_one_cell) goes no further. Any other has a second look, each corner's
            # share of the least nearness, a divide each, and Newell's sums (#emit_cell_side_slopes); then
            # the pairs of sides, a row's height at a time (#emit_cell_side_search).
            def emit_cell_sides_routine(asm, at)
              x = NUMBER_OFFSETS.fetch(FacePieces::X)
              y = NUMBER_OFFSETS.fetch(FacePieces::Y)
              w = NUMBER_OFFSETS.fetch(FacePieces::NEARNESS)
              asm.label("rt_face_cell_sides")
              asm.sw(:ra, at + CELL_SIDES_RETURN_OFFSET_BYTES, FACE_BASE)
              # a2 the first slot, a3 the one past the last.
              asm.lw(:t0, 0, :a0)
              asm.addiu(:a2, :a0, 4)
              asm.sll(:t0, :t0, 2)
              asm.addu(:a3, :a2, :t0)
              # The least and most x (t1, t2), y (t3, t4) and nearness (t5, t6).
              asm.li(:t1, 0x7FFF_FFFF)
              asm.li(:t2, -0x8000_0000)
              asm.move(:t3, :t1)
              asm.move(:t4, :t2)
              asm.move(:t5, :t1)
              asm.move(:t6, :t2)
              asm.move(:t0, :a2)
              asm.label("rt_face_cell_sides_reach")
              asm.lw(:t7, 0, :t0)
              asm.lw(:t8, x, :t7)
              emit_keep_least_and_most(asm, :t8, :t1, :t2, "rt_face_cell_sides_x", scratch: :t9)
              asm.lw(:t8, y, :t7)
              emit_keep_least_and_most(asm, :t8, :t3, :t4, "rt_face_cell_sides_y", scratch: :t9)
              asm.lw(:t8, w, :t7)
              emit_keep_least_and_most(asm, :t8, :t5, :t6, "rt_face_cell_sides_w", scratch: :t9)
              asm.addiu(:t0, :t0, 4)
              asm.bne(:t0, :a3, "rt_face_cell_sides_reach")
              asm.label("rt_face_cell_sides_reached")
              asm.sw(:t1, at + CELL_START_OFFSET_BYTES + x, FACE_BASE)
              asm.sw(:t3, at + CELL_START_OFFSET_BYTES + y, FACE_BASE)
              asm.subu(:t2, :t2, :t1)
              asm.sw(:t2, at + REACH_OFFSET_BYTES, FACE_BASE)
              asm.subu(:t4, :t4, :t3)
              asm.sw(:t4, at + REACH_OFFSET_BYTES + 4, FACE_BASE)
              # A face off by no more than allowed whole is one cell: the most sides, and its reach.
              emit_longer(asm, :t9, :t2, :t4, "rt_face_cell_sides_whole")
              asm.jal("rt_face_one_cell")
              asm.bne(:v0, :zero, "rt_face_cell_sides_sloping")
              asm.label("rt_face_cell_sides_one_cell")
              asm.li(:v0, 1 << (FacePieces::MOST_CELL_SHIFT + 4))
              asm.move(:v1, :v0)
              asm.move(:a2, :t2)
              asm.move(:a3, :t4)
              asm.lw(:ra, at + CELL_SIDES_RETURN_OFFSET_BYTES, FACE_BASE)
              asm.jr(:ra)
              asm.label("rt_face_cell_sides_sloping")
              emit_cell_side_slopes(asm)
              emit_cell_side_search(asm, at)
              emit_cell_side_within(asm)
            end

            # +into+ = the greater of +across+ and +down+; +label+ names the places between.
            def emit_longer(asm, into, across, down, label)
              asm.slt(into, across, down)
              asm.beq(into, :zero, "#{label}_longer") { asm.move(into, across) }
              asm.label("#{label}_taller")
              asm.move(into, down)
              asm.label("#{label}_longer")
            end

            # rt_face_one_cell: t5 = a face's least nearness, t6 its most, t9 its longer reach in sixteenths.
            # v0 = nought when it is off by no more than allowed whole, and so one cell
            # (FacePieces.cell_side_shifts): its change (FacePieces.nearness_change) times that reach in whole
            # pixels within the bound. t1 = the least over the share's bits, one at the least, which
            # #emit_cell_side_slopes divides by. A leaf; changes t7 to t9.
            #
            # Both rt_face_cell_sides and a face sent straight from its corners ask it: most of a place's faces
            # in perspective are a few pixels big or far off, and are one cell by it, which costs one divide.
            def emit_one_cell_routine(asm, at)
              bits = FacePieces::NEARNESS_CHANGE_BITS
              asm.label("rt_face_one_cell")
              asm.sra(:t1, :t5, bits)
              asm.bgtz(:t1, "rt_face_one_cell_over")
              asm.label("rt_face_one_cell_over_one")
              asm.li(:t1, 1)
              asm.label("rt_face_one_cell_over")
              asm.subu(:t7, :t6, :t5)
              asm.div(:t7, :t1) # signed, as Int32.div is
              # While the divide works: the reach in whole pixels, and v0 the bound.
              asm.sra(:t9, :t9, 4)
              asm.lw(:t8, at + SPANS_OFFSET_BYTES, FACE_BASE)
              asm.li(:v0, 1 << (bits + 2 + FacePieces::OFF_PIXELS_SHIFT))
              asm.addiu(:t8, :t8, -1)
              asm.bne(:t8, :zero, "rt_face_one_cell_bound")
              asm.label("rt_face_one_cell_every_pixel")
              asm.li(:v0, 1 << (bits + 2 + FacePieces::EVERY_PIXEL_OFF_PIXELS_SHIFT))
              asm.label("rt_face_one_cell_bound")
              asm.mflo(:t7)
              asm.slti(:t8, :t7, FacePieces::MOST_NEARNESS_CHANGE + 1)
              asm.bne(:t8, :zero, "rt_face_one_cell_change")
              asm.label("rt_face_one_cell_change_most")
              asm.li(:t7, FacePieces::MOST_NEARNESS_CHANGE)
              asm.label("rt_face_one_cell_change")
              asm.mult(:t7, :t9)
              asm.mflo(:t7)
              asm.jr(:ra) { asm.slt(:v0, :v0, :t7) }
            end

            # THE NEARNESS'S SLOPES ACROSS AND DOWN (FacePieces.nearness_slopes), from the corners a2 to a3,
            # the least nearness in t5 and t1 the least over the share's bits: t1 across, t2 down, with
            # SLOPE_BITS of fraction.
            #
            # Each corner's place in quarter pixels and its share, the last corner's then this one's in t2 to
            # t4 and t6, t8, t9; Newell's sums in v0 (nx), v1 (ny) and a0 (nz), each corner's terms with the
            # one before it. The first corner starts with no corner before (whose terms are nought) and is
            # looked at again at the end, which adds its terms with the last.
            def emit_cell_side_slopes(asm)
              x = NUMBER_OFFSETS.fetch(FacePieces::X)
              y = NUMBER_OFFSETS.fetch(FacePieces::Y)
              w = NUMBER_OFFSETS.fetch(FacePieces::NEARNESS)
              %i[t2 t3 t4 v0 v1 a0].each { |register| asm.move(register, :zero) }
              asm.move(:t0, :a2)
              asm.label("rt_face_cell_sides_corner")
              asm.lw(:t7, 0, :t0)
              asm.lw(:t9, w, :t7)
              asm.lw(:t6, x, :t7)
              asm.subu(:t9, :t9, :t5)
              asm.div(:t9, :t1) # signed, as Int32.div is
              asm.lw(:t8, y, :t7)
              asm.sra(:t6, :t6, FacePieces::PLACE_SHIFT)
              asm.sra(:t8, :t8, FacePieces::PLACE_SHIFT)
              asm.mflo(:t9)
              asm.slti(:t7, :t9, FacePieces::MOST_NEARNESS_CHANGE + 1)
              asm.bne(:t7, :zero, "rt_face_cell_sides_share")
              asm.label("rt_face_cell_sides_share_most")
              asm.li(:t9, FacePieces::MOST_NEARNESS_CHANGE)
              asm.label("rt_face_cell_sides_share")
              # nx += y e' - y' e, ny += e x' - e' x, nz += x y' - x' y: the last corner unprimed, this one
              # primed.
              [[:v0, :t3, :t9, :t8, :t4], [:v1, :t4, :t6, :t9, :t2], [:a0, :t2, :t8, :t6, :t3]].each do |sum, a, b, c, d|
                asm.mult(a, b)
                asm.mflo(:t7)
                asm.addu(sum, sum, :t7)
                asm.mult(c, d)
                asm.mflo(:t7)
                asm.subu(sum, sum, :t7)
              end
              asm.move(:t2, :t6)
              asm.move(:t3, :t8)
              asm.move(:t4, :t9)
              asm.addiu(:t0, :t0, 4)
              asm.bne(:t0, :a3, "rt_face_cell_sides_corner")
              # Past the last: the first again, once, ending one slot past it.
              asm.label("rt_face_cell_sides_round")
              asm.addiu(:t7, :a2, 4)
              asm.beq(:a3, :t7, "rt_face_cell_sides_summed")
              asm.label("rt_face_cell_sides_first_again")
              asm.move(:a3, :t7)
              asm.b("rt_face_cell_sides_corner") { asm.move(:t0, :a2) }
              asm.label("rt_face_cell_sides_summed")
              # No area, no slope; otherwise each slope is its sum's size moved up, over the area's, held to
              # MOST_SLOPE (a sum past a word's reach after the move turns negative, and is held too).
              asm.move(:t1, :zero)
              asm.beq(:a0, :zero, "rt_face_cell_sides_sloped") { asm.move(:t2, :zero) }
              asm.label("rt_face_cell_sides_area")
              emit_magnitude(asm, :a0)
              [[:v0, :t1, "across"], [:v1, :t2, "down"]].each do |sum, slope, way|
                emit_magnitude(asm, sum)
                asm.sll(sum, sum, FacePieces::SLOPE_SHIFT)
                asm.div(sum, :a0)
                asm.mflo(slope)
                asm.bltz(slope, "rt_face_cell_sides_steepest_#{way}")
                asm.label("rt_face_cell_sides_not_negative_#{way}")
                asm.li(:t7, FacePieces::MOST_SLOPE)
                asm.slt(:t7, :t7, slope)
                asm.beq(:t7, :zero, "rt_face_cell_sides_held_#{way}")
                asm.label("rt_face_cell_sides_steepest_#{way}")
                asm.li(slope, FacePieces::MOST_SLOPE)
                asm.label("rt_face_cell_sides_held_#{way}")
              end
              asm.label("rt_face_cell_sides_sloped")
            end

            # +number+ without its sign (FacePieces.magnitude). Changes t7.
            def emit_magnitude(asm, number)
              asm.sra(:t7, number, 31)
              asm.xor(number, number, :t7)
              asm.subu(number, number, :t7)
            end

            # THE PAIR OF SIDES CUTTING THE FACE INTO THE FEWEST CELLS (FacePieces.cell_side_shifts), from the
            # slopes in t1 and t2 and the reach kept in REACH_OFFSET_BYTES, into v0 and v1 in sixteenths, and
            # the return. t4 is the width's shift, up to t0, the widest worth trying; t5 the height's, from the
            # tallest worth trying down; t6 the fewest cells so far, and v0 and v1 the shifts that made them;
            # t3 the bound.
            def emit_cell_side_search(asm, at)
              least = FacePieces::LEAST_CELL_SHIFT
              asm.lw(:a2, at + REACH_OFFSET_BYTES, FACE_BASE)
              asm.lw(:a3, at + REACH_OFFSET_BYTES + 4, FACE_BASE)
              asm.lw(:t7, at + SPANS_OFFSET_BYTES, FACE_BASE)
              asm.li(:t3, 1 << (FacePieces::SLOPE_BITS + 2 + FacePieces::OFF_PIXELS_SHIFT))
              asm.addiu(:t7, :t7, -1)
              asm.bne(:t7, :zero, "rt_face_cell_sides_bound")
              asm.label("rt_face_cell_sides_every_pixel")
              asm.li(:t3, 1 << (FacePieces::SLOPE_BITS + 2 + FacePieces::EVERY_PIXEL_OFF_PIXELS_SHIFT))
              asm.label("rt_face_cell_sides_bound")
              # t0 the widest shift worth trying, t5 the tallest (FacePieces.covering_shift).
              emit_covering_shift(asm, :t0, :a2, "rt_face_cell_sides_widest_shift")
              emit_covering_shift(asm, :t5, :a3, "rt_face_cell_sides_tallest_shift")
              asm.li(:t4, least)
              asm.li(:t6, 0x7FFF_FFFF)
              asm.li(:v0, least)
              asm.li(:v1, least)
              # The widest cells within the bound at this height: wider while the next is within it.
              asm.label("rt_face_cell_sides_height")
              asm.slt(:t8, :t4, :t0)
              asm.beq(:t8, :zero, "rt_face_cell_sides_widest")
              asm.label("rt_face_cell_sides_wider")
              asm.jal("rt_face_cell_sides_within") { asm.addiu(:t7, :t4, 1) }
              asm.beq(:t8, :zero, "rt_face_cell_sides_widest")
              asm.label("rt_face_cell_sides_widened")
              asm.b("rt_face_cell_sides_height") { asm.addiu(:t4, :t4, 1) }
              asm.label("rt_face_cell_sides_widest")
              asm.jal("rt_face_cell_sides_within") { asm.move(:t7, :t4) }
              asm.beq(:t8, :zero, "rt_face_cell_sides_lower")
              # The cells: the columns the width makes times the rows the height makes (FacePieces.cells_along).
              asm.label("rt_face_cell_sides_count")
              [[:a2, :t4, :t9], [:a3, :t5, :a0]].each do |reach, shift, cells|
                asm.addiu(:t7, shift, 4)
                asm.addiu(cells, reach, -1)
                asm.srav(cells, cells, :t7)
                asm.addiu(cells, cells, 1)
              end
              asm.mult(:t9, :a0)
              asm.mflo(:t9)
              asm.slt(:t8, :t9, :t6)
              asm.beq(:t8, :zero, "rt_face_cell_sides_counted")
              asm.label("rt_face_cell_sides_fewer")
              asm.move(:t6, :t9)
              asm.move(:v0, :t4)
              asm.move(:v1, :t5)
              # One column, and lower cells only make more rows.
              asm.label("rt_face_cell_sides_counted")
              asm.beq(:t4, :t0, "rt_face_cell_sides_found")
              asm.label("rt_face_cell_sides_lower")
              asm.slti(:t8, :t5, least + 1)
              asm.bne(:t8, :zero, "rt_face_cell_sides_found")
              asm.label("rt_face_cell_sides_next_height")
              asm.b("rt_face_cell_sides_height") { asm.addiu(:t5, :t5, -1) }
              asm.label("rt_face_cell_sides_found")
              asm.lw(:ra, at + CELL_SIDES_RETURN_OFFSET_BYTES, FACE_BASE)
              asm.li(:t8, 1)
              asm.addiu(:v0, :v0, 4)
              asm.sllv(:v0, :t8, :v0)
              asm.addiu(:v1, :v1, 4)
              asm.jr(:ra) { asm.sllv(:v1, :t8, :v1) }
            end

            # +into+ = the least shift whose side cuts the reach in +reach+ (sixteenths) into one cell
            # (FacePieces.covering_shift); +label+ names the places between. Changes t7 and t8.
            def emit_covering_shift(asm, into, reach, label)
              asm.li(into, FacePieces::LEAST_CELL_SHIFT)
              asm.label(label)
              asm.slti(:t8, into, FacePieces::MOST_CELL_SHIFT)
              asm.beq(:t8, :zero, "#{label}_found")
              asm.label("#{label}_try")
              asm.addiu(:t7, into, 4)
              asm.addiu(:t8, reach, -1)
              asm.srav(:t8, :t8, :t7)
              asm.blez(:t8, "#{label}_found")
              asm.label("#{label}_wider")
              asm.b(label) { asm.addiu(into, into, 1) }
              asm.label("#{label}_found")
            end

            # rt_face_cell_sides_within: t7 = a width's shift, t5 a height's; t8 = 1 when cells of those sides
            # are within the bound in t3, from the slopes in t1 and t2 and the reach in a2 and a3, and nought
            # when not (FacePieces.cell_side_shifts' test). Each side is held to the reach that way, in whole
            # pixels. Changes t9, a0 and a1.
            def emit_cell_side_within(asm)
              asm.label("rt_face_cell_sides_within")
              asm.li(:t8, 1)
              [[:a0, :t7, :a2, "across"], [:a1, :t5, :a3, "down"]].each do |side, shift, reach, way|
                asm.sllv(side, :t8, shift)
                asm.sra(:t9, reach, 4)
                asm.slt(:t9, :t9, side) # the reach is the lesser
                asm.beq(:t9, :zero, "rt_face_cell_sides_side_#{way}")
                asm.label("rt_face_cell_sides_reach_#{way}")
                asm.sra(side, reach, 4)
                asm.label("rt_face_cell_sides_side_#{way}")
              end
              asm.mult(:t1, :a0)
              asm.mflo(:t9)
              asm.mult(:t2, :a1)
              asm.mflo(:t8)
              asm.addu(:t9, :t9, :t8)
              asm.slt(:t8, :t3, :t9)
              asm.bne(:t8, :zero, "rt_face_cell_sides_without")
              # The sum times the longer side.
              asm.label("rt_face_cell_sides_sum_within")
              asm.slt(:t8, :a0, :a1)
              asm.beq(:t8, :zero, "rt_face_cell_sides_longer")
              asm.label("rt_face_cell_sides_taller")
              asm.move(:a0, :a1)
              asm.label("rt_face_cell_sides_longer")
              asm.mult(:t9, :a0)
              asm.mflo(:t9)
              asm.slt(:t8, :t3, :t9)
              asm.jr(:ra) { asm.xori(:t8, :t8, 1) }
              asm.label("rt_face_cell_sides_without")
              asm.jr(:ra) { asm.move(:t8, :zero) }
            end

            # The face's corners as pieces' corners, into +face+ (FacePieces.corner_from_list): x and y, then
            # without perspective u and v, in perspective u and v over the distance and w; then each one's
            # texel. Each is made in the pool, from its start, and the pool's next free place is the one
            # after the last. Changes s1 to s4.
            def emit_face_corners_made(asm, at, face, pool)
              asm.li(:s1, face)
              asm.lw(:s2, at + COUNT_OFFSET_BYTES, FACE_BASE)
              asm.sw(:s2, 0, :s1)
              asm.addiu(:s1, :s1, 4)
              asm.addiu(:s3, FACE_BASE, at + CORNERS_OFFSET_BYTES)
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
              asm.lw(:t3, at + SPANS_OFFSET_BYTES, FACE_BASE)
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
              # The shade (FacePieces.corner_from_list): the light held to nought to LIGHTEST, moved up seven
              # bits, and the light floor added; nought for a face not lit.
              asm.lw(:t0, at + LIGHT_FLOOR_OFFSET_BYTES, FACE_BASE)
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
              asm.sll(:t1, :t1, 7)
              asm.addu(:t1, :t1, :t0)
              asm.sltu(:t0, :zero, :t0) # 1 for a lit face
              asm.subu(:t0, :zero, :t0) # every bit, for a lit face
              asm.and(:t1, :t1, :t0)
              asm.sw(:t1, NUMBER_OFFSETS.fetch(FacePieces::SHADE), :s4)
              asm.sw(:zero, EDGE_END_OFFSET_BYTES, :s4) # a corner of the face, on no edge of its own
              asm.addiu(:s1, :s1, 4)
              asm.addiu(:s4, :s4, CORNER_BYTES)
              asm.addiu(:s2, :s2, -1)
              asm.bne(:s2, :zero, "rt_fill_face_corner") { asm.addiu(:s3, :s3, LIST_CORNER_BYTES) }
              asm.sw(:s4, at + POOL_NEXT_OFFSET_BYTES, FACE_BASE)
            end

            # rt_face_sweep: a0 = a piece, a1 = which number it is cut along (X or Y's offset), a2 = where
            # each part before a line goes, a3 = two pieces, one after the other, the rest goes in by turns,
            # t4 = the routine each part of three corners or more is handed to in a0
            # (FacePieces.each_strip): cut along every multiple of the cells' side that way
            # (CELL_SIDE_OFFSET_BYTES) strictly inside the piece, the part before each line in turn, then the rest. Keeps s0 to s7. Whatever of the
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
              # The lines (rt_face_sweep_lines): s6 the first, s5 where they end; none for a piece wholly
              # before the face's left or top edge.
              asm.jal("rt_face_sweep_lines")
              asm.bne(:v0, :zero, "rt_face_sweep_done")
              asm.label("rt_face_sweep_line")
              asm.slt(:t0, :s6, :s5)
              asm.beq(:t0, :zero, "rt_face_sweep_end")
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
              asm.lw(:s7, at + POOL_NEXT_OFFSET_BYTES, FACE_BASE)
              asm.jalr(:s4) { asm.move(:a0, :s2) }
              asm.sw(:s7, at + POOL_NEXT_OFFSET_BYTES, FACE_BASE)
              asm.label("rt_face_sweep_next")
              asm.addu(:t0, :s1, FACE_BASE)
              asm.lw(:t0, at + CELL_SIDE_OFFSET_BYTES, :t0)
              asm.b("rt_face_sweep_line") { asm.addu(:s6, :s6, :t0) }
              # Past the lines: done at the stop line, and otherwise the rest, which reaches the most
              # (rt_face_sweep_ending).
              asm.label("rt_face_sweep_end")
              asm.j("rt_face_sweep_ending")
              asm.label("rt_face_sweep_rest")
              asm.lw(:t0, 0, :s0)
              asm.slti(:t0, :t0, 3)
              asm.bne(:t0, :zero, "rt_face_sweep_done")
              asm.label("rt_face_sweep_last")
              asm.jalr(:s4) { asm.move(:a0, :s0) }
              asm.label("rt_face_sweep_done")
              emit_return_with_registers(asm)
            end

            # rt_face_row: a0 = a strip of the face, between two of its rows' lines, cut into squares along the
            # columns' lines and each square sent (FacePieces.each_cell_in_strip): the strip's two runs from
            # its least x to its most walked across it (#emit_strip_runs), and each square made from the
            # corners each run passes and the crossings it makes. A square of four corners, most of them, is
            # sent by rt_face_quad (#emit_four_corner_cell); any other is put together in `square` and
            # handed to rt_face_send_piece. A strip no line crosses is sent as it is, and one without the two
            # runs is handed to rt_face_sweep.
            #
            # s0 is the strip, s7 where its corners end, s5 the line and s6 its most x. s1 is where the next
            # corner of the run going on round is in the strip and s2 that run's last crossing (or first
            # corner); s3 and s4 the same for the run going back round. a3 is `square` while it is put together.
            def emit_row_routine(asm, at, polygon)
              x = NUMBER_OFFSETS.fetch(FacePieces::X)
              square = polygon.call(:square)
              asm.label("rt_face_row")
              emit_keep_registers(asm)
              asm.move(:s0, :a0)
              emit_strip_runs(asm, at)
              # Each run from its first corner, then the lines (rt_face_row_lines).
              asm.lw(:s2, 0, :s1)
              emit_next_slot(asm, :s1, "rt_face_row_ahead_first")
              asm.lw(:s4, 0, :s3)
              emit_previous_slot(asm, :s3, "rt_face_row_behind_first")
              asm.jal("rt_face_row_lines")
              asm.bne(:v0, :zero, "rt_face_row_done")
              asm.label("rt_face_row_line")
              asm.slt(:t0, :s5, :s6)
              asm.beq(:t0, :zero, "rt_face_row_end")
              emit_four_corner_cell(asm, at, x)
              # Any other square: put together in `square`, and sent as any piece is.
              asm.label("rt_face_row_any")
              asm.jal("rt_face_row_left")
              emit_run_ahead(asm, at)
              emit_run_behind(asm, at)
              emit_send_square(asm, "rt_face_row_sent")
              asm.label("rt_face_row_next")
              asm.lw(:t0, at + CELL_SIDE_OFFSET_BYTES + x, FACE_BASE)
              asm.b("rt_face_row_line") { asm.addu(:s5, :s5, :t0) }
              # rt_face_row_left: `square` (a3) started with a square's left side, each run's last crossing
              # (or first corner), the run going back's first. Changes t0 and t1.
              asm.label("rt_face_row_left")
              asm.li(:a3, square)
              asm.sw(:zero, 0, :a3)
              emit_append(asm, :a3, :s4, "rt_face_row_left_behind")
              emit_append(asm, :a3, :s2, "rt_face_row_left_ahead")
              asm.jr(:ra)
              # Past the lines: done at the stop line, and otherwise the last square, to the most
              # (rt_face_row_ending).
              asm.label("rt_face_row_end")
              asm.j("rt_face_row_ending")
              emit_last_square(asm, x)
              emit_send_square(asm, "rt_face_row_done")
              emit_return_with_registers(asm)
              # A strip no line crosses, sent as it is.
              asm.label("rt_face_row_whole")
              asm.b("rt_face_row_done_send") { asm.move(:a3, :s0) }
              # A strip without the two runs, cut along every line by rt_face_sweep in place of this routine,
              # so that the stack goes no deeper.
              asm.label("rt_face_row_cut")
              asm.move(:a0, :s0)
              asm.li(:a1, x)
              asm.li(:a2, square)
              asm.li(:a3, polygon.call(:squares_a))
              asm.la(:t4, "rt_face_send_piece")
              KEPT_REGISTERS.each_with_index { |register, i| asm.lw(register, i * 4, :sp) }
              asm.j("rt_face_sweep") { asm.addiu(:sp, :sp, 4 * KEPT_REGISTERS.length) }
            end

            # THE LAST SQUARE, past the last line: each run's corners to the most, and those at the most; sent
            # by rt_face_quad where it is the two last crossings and two corners at the most, and otherwise put
            # together in `square` (a3) and falling through to be sent.
            def emit_last_square(asm, x)
              asm.label("rt_face_row_last")
              emit_x_at_slot(asm, :t0, :s1)
              asm.bne(:t0, :s6, "rt_face_row_last_any")
              emit_x_at_slot(asm, :t0, :s3)
              asm.bne(:t0, :s6, "rt_face_row_last_any")
              asm.move(:t1, :s1)
              emit_next_slot(asm, :t1, "rt_face_row_most_second")
              asm.bne(:t1, :s3, "rt_face_row_last_any")
              asm.label("rt_face_row_last_four")
              asm.move(:a0, :s4)
              asm.move(:a1, :s2)
              asm.lw(:a2, 0, :s1)
              asm.lw(:a3, 0, :s3)
              asm.jal("rt_face_quad")
              asm.b("rt_face_row_done")
              asm.label("rt_face_row_last_any")
              asm.jal("rt_face_row_left")
              # The run going on round's corners short of the most; then s1 is the first at the most.
              asm.label("rt_face_row_ahead_rest")
              asm.lw(:a1, 0, :s1)
              asm.lw(:t2, x, :a1)
              asm.beq(:t2, :s6, "rt_face_row_ahead_rested")
              asm.label("rt_face_row_ahead_rest_corner")
              emit_append(asm, :a3, :a1, "rt_face_row_ahead_rest_kept")
              emit_next_slot(asm, :s1, "rt_face_row_ahead_rest_next")
              asm.b("rt_face_row_ahead_rest")
              asm.label("rt_face_row_ahead_rested")
              # Those at the most, from s1 on round (FacePieces.end_of_run): t2 the last of them.
              asm.move(:t2, :s1)
              emit_end_of_run(asm, :s6, "rt_face_row_most_run")
              asm.move(:t2, :s1)
              emit_append_run(asm, "rt_face_row_most")
              # The run going back's corners not passed, short of the last at the most, in the strip's order:
              # from the one after the last at the most (t3, kept by #emit_append_run) on round to s3.
              emit_x_at_slot(asm, :t0, :s3)
              asm.beq(:t0, :s6, "rt_face_row_behind_rested")
              asm.label("rt_face_row_behind_rest")
              asm.move(:t2, :t3)
              emit_next_slot(asm, :t2, "rt_face_row_behind_rest_first")
              asm.move(:t3, :s3)
              emit_append_run(asm, "rt_face_row_behind_rest_run")
              asm.label("rt_face_row_behind_rested")
            end

            # THE SQUARE OF FOUR CORNERS, most of a big face's: neither run passes a corner of the strip before
            # the line s5 or meets one on it. It is then each run's last crossing (or first corner) and the
            # crossing each makes on this line, sent by rt_face_quad without being put together in `square`;
            # then on to rt_face_row_next. Any other square goes on to rt_face_row_any.
            def emit_four_corner_cell(asm, at, x)
              asm.lw(:a1, 0, :s1)
              asm.lw(:t1, x, :a1)
              asm.slt(:t0, :s5, :t1)
              asm.beq(:t0, :zero, "rt_face_row_any")
              asm.label("rt_face_row_four_behind")
              emit_x_at_slot(asm, :t1, :s3)
              asm.slt(:t0, :s5, :t1)
              asm.beq(:t0, :zero, "rt_face_row_any")
              asm.label("rt_face_row_four")
              asm.lw(:a0, at + AHEAD_FROM_OFFSET_BYTES, FACE_BASE)
              asm.jal("rt_face_column_corner") { asm.move(:a2, :s5) }
              asm.sw(:v0, at + CROSSING_OFFSET_BYTES, FACE_BASE)
              asm.lw(:a1, 0, :s3)
              asm.lw(:a0, at + BEHIND_FROM_OFFSET_BYTES, FACE_BASE)
              asm.jal("rt_face_column_corner") { asm.move(:a2, :s5) }
              # [the run going back's last crossing, the other run's, this line's on the other run, and on
              # the run going back], each run's last crossing then this line's.
              asm.move(:a0, :s4)
              asm.move(:a1, :s2)
              asm.lw(:a2, at + CROSSING_OFFSET_BYTES, FACE_BASE)
              asm.move(:a3, :v0)
              asm.move(:s4, :v0)
              asm.jal("rt_face_quad") { asm.move(:s2, :a2) }
              asm.b("rt_face_row_next")
            end

            # rt_face_sweep_lines: for rt_face_sweep, v0 the piece's least and s5 its most on the number at s1
            # (X or Y's offset). s6 = the first line (FacePieces.first_line). Where the line at or before the
            # face's left or top edge is past it (FacePieces.line_at_or_before), the piece is cut there, the
            # part before left out and the rest made s0, and s6 is the line after. s5 = the most, or the
            # line a cell's side past the right or bottom edge where that comes first, which is kept for the
            # sweep's end (STOP_LINE_OFFSET_BYTES, FacePieces.past_edge?). v0 = 1 for a piece wholly before
            # the left or top edge's line, which gives nothing, and nought otherwise. A routine of the cells'
            # section, run once a sweep, which keeps its return address in SEEK_RETURN_OFFSET_BYTES while
            # it calls rt_face_cut. Changes t0 to t9, a0 to a3, v1 and s7.
            def emit_sweep_lines_routine(asm, at)
              asm.label("rt_face_sweep_lines")
              asm.addu(:t3, :s1, FACE_BASE)
              asm.lw(:t2, at + CELL_START_OFFSET_BYTES, :t3)
              asm.lw(:t0, at + CELL_SIDE_OFFSET_BYTES, :t3)
              asm.subu(:t1, :zero, :t0)
              asm.subu(:t4, :v0, :t2)
              asm.and(:t4, :t4, :t1)
              asm.addu(:t4, :t4, :t2)
              asm.addu(:s6, :t4, :t0) # the first line
              # The edges each way: the left (or top) at LEFT_OFFSET_BYTES on from the number's offset, the
              # right (or bottom) at RIGHT_OFFSET_BYTES.
              asm.lw(:t4, at + LEFT_OFFSET_BYTES, :t3)
              asm.sll(:t4, :t4, 4)
              asm.lw(:t5, at + RIGHT_OFFSET_BYTES, :t3)
              asm.sll(:t5, :t5, 4)
              asm.addu(:t5, :t5, :t0)
              asm.sw(:t5, at + STOP_LINE_OFFSET_BYTES, :t3)
              asm.subu(:t4, :t4, :t2)
              asm.and(:t4, :t4, :t1)
              asm.addu(:t4, :t4, :t2) # the line at or before the left edge
              asm.slt(:t6, :t4, :s6)
              asm.bne(:t6, :zero, "rt_face_sweep_lines_from_first")
              asm.label("rt_face_sweep_lines_skip")
              asm.slt(:t6, :t4, :s5)
              asm.beq(:t6, :zero, "rt_face_sweep_lines_none")
              # Cut there, the part before it not kept and the rest into whichever of the two pieces s0 is
              # not in (as rt_face_sweep's loop puts it); then the line after.
              asm.label("rt_face_sweep_lines_skip_inside")
              asm.move(:s6, :t4)
              asm.sw(:ra, at + SEEK_RETURN_OFFSET_BYTES, FACE_BASE)
              asm.move(:s7, :s3)
              asm.bne(:s0, :s3, "rt_face_sweep_lines_into")
              asm.label("rt_face_sweep_lines_other")
              asm.addiu(:s7, :s3, POLYGON_BYTES)
              asm.label("rt_face_sweep_lines_into")
              asm.move(:a0, :s0)
              asm.move(:a1, :zero)
              asm.move(:a2, :s7)
              asm.move(:a3, :s1)
              asm.jal("rt_face_cut") { asm.move(:t4, :s6) }
              asm.move(:s0, :s7)
              asm.lw(:ra, at + SEEK_RETURN_OFFSET_BYTES, FACE_BASE)
              asm.addu(:t3, :s1, FACE_BASE)
              asm.lw(:t0, at + CELL_SIDE_OFFSET_BYTES, :t3)
              asm.lw(:t5, at + STOP_LINE_OFFSET_BYTES, :t3)
              asm.addu(:s6, :s6, :t0)
              asm.label("rt_face_sweep_lines_from_first")
              asm.slt(:t6, :t5, :s5)
              asm.beq(:t6, :zero, "rt_face_sweep_lines_made")
              asm.label("rt_face_sweep_lines_stop_first")
              asm.move(:s5, :t5)
              asm.label("rt_face_sweep_lines_made")
              asm.jr(:ra) { asm.move(:v0, :zero) }
              asm.label("rt_face_sweep_lines_none")
              asm.jr(:ra) { asm.li(:v0, 1) }
            end

            # rt_face_row_ending: rt_face_row past its lines (s5 the line it reached), on to rt_face_row_done
            # at the stop line (STOP_LINE_OFFSET_BYTES, FacePieces.past_edge?), and otherwise to
            # rt_face_row_last with s6 the strip's most again (ROW_MOST_OFFSET_BYTES). Changes t0 and t1.
            def emit_row_ending_routine(asm, at)
              x = NUMBER_OFFSETS.fetch(FacePieces::X)
              asm.label("rt_face_row_ending")
              asm.lw(:t0, at + STOP_LINE_OFFSET_BYTES + x, FACE_BASE)
              asm.slt(:t1, :s5, :t0)
              asm.beq(:t1, :zero, "rt_face_row_ending_stopped")
              asm.label("rt_face_row_ending_last")
              asm.lw(:s6, at + ROW_MOST_OFFSET_BYTES, FACE_BASE)
              asm.j("rt_face_row_last")
              asm.label("rt_face_row_ending_stopped")
              asm.j("rt_face_row_done")
            end

            # rt_face_sweep_ending: rt_face_sweep past its lines (s6 the line it reached), on to
            # rt_face_sweep_done at the stop line (STOP_LINE_OFFSET_BYTES, FacePieces.past_edge?) and to
            # rt_face_sweep_rest otherwise, the rest reaching the most. Changes t0, t1 and t3.
            def emit_sweep_ending_routine(asm, at)
              asm.label("rt_face_sweep_ending")
              asm.addu(:t3, :s1, FACE_BASE)
              asm.lw(:t1, at + STOP_LINE_OFFSET_BYTES, :t3)
              asm.slt(:t0, :s6, :t1)
              asm.beq(:t0, :zero, "rt_face_sweep_ending_stopped")
              asm.label("rt_face_sweep_ending_rest")
              asm.j("rt_face_sweep_rest")
              asm.label("rt_face_sweep_ending_stopped")
              asm.j("rt_face_sweep_done")
            end

            # rt_face_row_lines: for rt_face_row, with the strip's runs from their first corners (s1 to s4), s5
            # the first line and s6 the strip's most x. Each run's first corner made the one a crossing is
            # stepped from (AHEAD_FROM_OFFSET_BYTES, BEHIND_FROM_OFFSET_BYTES). Where the line at or before
            # the face's left edge is past s5 (FacePieces.each_cell_in_strip), each run walked straight to it
            # without a square put together, its crossing there the next square's left side, and s5 the
            # line after; v0 = 1 for a strip lying wholly before that line, which gives nothing. Then the
            # strip's most kept (ROW_MOST_OFFSET_BYTES), and s6 the line a cell's width past the right edge
            # where that comes first (STOP_LINE_OFFSET_BYTES, FacePieces.past_edge?); v0 = nought. A routine
            # of the cells' section, run once a strip, which keeps its return address in
            # SEEK_RETURN_OFFSET_BYTES while it calls rt_face_column_corner. Changes t0 to t9, a0 to a2, v0
            # and v1.
            def emit_row_lines_routine(asm, at)
              x = NUMBER_OFFSETS.fetch(FacePieces::X)
              asm.label("rt_face_row_lines")
              asm.sw(:s2, at + AHEAD_FROM_OFFSET_BYTES, FACE_BASE)
              asm.sw(:s4, at + BEHIND_FROM_OFFSET_BYTES, FACE_BASE)
              asm.lw(:t1, at + CELL_START_OFFSET_BYTES + x, FACE_BASE)
              asm.lw(:t0, at + CELL_SIDE_OFFSET_BYTES + x, FACE_BASE)
              asm.lw(:t2, at + LEFT_OFFSET_BYTES, FACE_BASE)
              asm.sll(:t2, :t2, 4)
              asm.subu(:t2, :t2, :t1)
              asm.subu(:t3, :zero, :t0)
              asm.and(:t2, :t2, :t3)
              asm.addu(:t2, :t2, :t1) # the line at or before the left edge
              asm.slt(:t3, :t2, :s5)
              asm.bne(:t3, :zero, "rt_face_row_lines_stop")
              asm.label("rt_face_row_lines_skip")
              asm.slt(:t3, :t2, :s6)
              asm.beq(:t3, :zero, "rt_face_row_lines_none")
              asm.label("rt_face_row_lines_seek")
              asm.move(:s5, :t2)
              asm.sw(:ra, at + SEEK_RETURN_OFFSET_BYTES, FACE_BASE)
              [[:s1, :s2, AHEAD_FROM_OFFSET_BYTES, "ahead"], [:s3, :s4, BEHIND_FROM_OFFSET_BYTES, "behind"]].each do |slot, crossing, from, name|
                label = "rt_face_row_seek_#{name}"
                step = ->(suffix) { name == "ahead" ? emit_next_slot(asm, slot, "#{label}_#{suffix}") : emit_previous_slot(asm, slot, "#{label}_#{suffix}") }
                asm.label(label)
                asm.lw(:a1, 0, slot)
                asm.lw(:t2, x, :a1)
                asm.slt(:t0, :t2, :s5)
                asm.beq(:t0, :zero, "#{label}_reached")
                asm.label("#{label}_passed")
                asm.sw(:a1, at + from, FACE_BASE)
                step.call("next")
                asm.b(label)
                asm.label("#{label}_reached")
                asm.bne(:t2, :s5, "#{label}_cross")
                asm.label("#{label}_on_line")
                asm.move(crossing, :a1)
                asm.sw(:a1, at + from, FACE_BASE)
                step.call("past_line")
                asm.b("#{label}_crossed")
                asm.label("#{label}_cross")
                asm.lw(:a0, at + from, FACE_BASE)
                asm.jal("rt_face_column_corner") { asm.move(:a2, :s5) }
                asm.move(crossing, :v0)
                asm.label("#{label}_crossed")
              end
              asm.lw(:t0, at + CELL_SIDE_OFFSET_BYTES + x, FACE_BASE)
              asm.lw(:ra, at + SEEK_RETURN_OFFSET_BYTES, FACE_BASE)
              asm.addu(:s5, :s5, :t0)
              asm.label("rt_face_row_lines_stop")
              asm.sw(:s6, at + ROW_MOST_OFFSET_BYTES, FACE_BASE)
              asm.lw(:t0, at + RIGHT_OFFSET_BYTES, FACE_BASE)
              asm.lw(:t1, at + CELL_SIDE_OFFSET_BYTES + x, FACE_BASE)
              asm.sll(:t0, :t0, 4)
              asm.addu(:t0, :t0, :t1)
              asm.sw(:t0, at + STOP_LINE_OFFSET_BYTES + x, FACE_BASE)
              asm.slt(:t1, :t0, :s6)
              asm.beq(:t1, :zero, "rt_face_row_lines_made")
              asm.label("rt_face_row_lines_stop_first")
              asm.move(:s6, :t0)
              asm.label("rt_face_row_lines_made")
              asm.jr(:ra) { asm.move(:v0, :zero) }
              asm.label("rt_face_row_lines_none")
              asm.jr(:ra) { asm.li(:v0, 1) }
            end

            # THE STRIP'S TWO RUNS (FacePieces.strip_chains), for the strip in s0: falls through with s5 the
            # first line, s6 its most x, s7 where its corners end, s1 where the last of its corners at its least
            # is in it and s3 the first; or goes to rt_face_row_whole where no line crosses it, and to
            # rt_face_row_cut where it has more than two corners at its least or x does not rise along both
            # runs. Changes t0 to t9, a0 to a3, v0 and v1.
            def emit_strip_runs(asm, at)
              x = NUMBER_OFFSETS.fetch(FacePieces::X)
              asm.jal("rt_face_extent") { asm.li(:a1, x) }
              # s5, the first line past the least (FacePieces.first_line); a strip it does not cross is one
              # square, sent as it is.
              asm.lw(:t1, at + CELL_START_OFFSET_BYTES + x, FACE_BASE)
              asm.lw(:t2, at + CELL_SIDE_OFFSET_BYTES + x, FACE_BASE)
              asm.subu(:t0, :v0, :t1)
              asm.subu(:t3, :zero, :t2)
              asm.and(:t0, :t0, :t3)
              asm.addu(:t0, :t0, :t1)
              asm.addu(:s5, :t0, :t2)
              asm.slt(:t0, :s5, :v1)
              asm.beq(:t0, :zero, "rt_face_row_whole")
              asm.label("rt_face_row_wide")
              asm.move(:s6, :v1)
              asm.lw(:t0, 0, :s0)
              asm.sll(:t0, :t0, 2)
              asm.addu(:s7, :s0, :t0)
              asm.addiu(:s7, :s7, 4)
              # The first corner at the least (v0) whose corner before is not: t2 where it is, t3 where the one
              # before is.
              asm.addiu(:t2, :s0, 4)
              asm.addiu(:t3, :s7, -4)
              asm.label("rt_face_row_first_least")
              emit_x_at_slot(asm, :t4, :t2)
              asm.bne(:t4, :v0, "rt_face_row_first_least_next")
              asm.label("rt_face_row_first_least_at")
              emit_x_at_slot(asm, :t4, :t3)
              asm.bne(:t4, :v0, "rt_face_row_first_least_found")
              asm.label("rt_face_row_first_least_next")
              asm.move(:t3, :t2)
              asm.b("rt_face_row_first_least") { asm.addiu(:t2, :t2, 4) }
              asm.label("rt_face_row_first_least_found")
              asm.move(:s3, :t2)
              emit_end_of_run(asm, :v0, "rt_face_row_least_run")
              asm.move(:s1, :t3)
              # No more than two at the least.
              asm.beq(:s3, :s1, "rt_face_row_least_one")
              emit_next_slot(asm, :t2, "rt_face_row_least_second")
              asm.bne(:t2, :s1, "rt_face_row_cut")
              asm.label("rt_face_row_least_one")
              # Round from the last at the least, x rising, to the first at the most; then t3 the last at it.
              asm.move(:t2, :s1)
              emit_rising_run(asm, :forward, "rt_face_row_rising_ahead")
              emit_end_of_run(asm, :s6, "rt_face_row_at_most")
              # Back round from the first at the least, x rising, to the last at the most.
              asm.move(:t2, :s3)
              emit_rising_run(asm, :back, "rt_face_row_rising_behind")
              asm.bne(:t2, :t3, "rt_face_row_cut")
              asm.label("rt_face_row_runs")
            end

            # +into+ = the x of the corner whose address is at +slot+. Changes a0.
            def emit_x_at_slot(asm, into, slot)
              asm.lw(:a0, 0, slot)
              asm.lw(into, NUMBER_OFFSETS.fetch(FacePieces::X), :a0)
            end

            # t3 = where the run of corners at the x +value+ that starts at t2 ends, going on round
            # (FacePieces.end_of_run). Changes t4, t5 and a0.
            def emit_end_of_run(asm, value, label)
              asm.move(:t3, :t2)
              asm.label(label)
              asm.move(:t5, :t3)
              emit_next_slot(asm, :t5, "#{label}_next")
              asm.beq(:t5, :t2, "#{label}_end")
              emit_x_at_slot(asm, :t4, :t5)
              asm.bne(:t4, value, "#{label}_end")
              asm.label("#{label}_on")
              asm.b(label) { asm.move(:t3, :t5) }
              asm.label("#{label}_end")
            end

            # From the corner at t2, round +way+ (:forward or :back) while x rises, to the first at the most
            # (s6): t2 then where that one is (FacePieces.rising_run); to rt_face_row_cut where x stops rising
            # first. Changes t4, t5, t6 and a0.
            def emit_rising_run(asm, way, label)
              emit_x_at_slot(asm, :t4, :t2)
              asm.label(label)
              asm.beq(:t4, :s6, "#{label}_most")
              asm.move(:t5, :t2)
              way == :forward ? emit_next_slot(asm, :t5, "#{label}_step") : emit_previous_slot(asm, :t5, "#{label}_step")
              emit_x_at_slot(asm, :t6, :t5)
              asm.slt(:a0, :t4, :t6)
              asm.beq(:a0, :zero, "rt_face_row_cut")
              asm.label("#{label}_rises")
              asm.move(:t2, :t5)
              asm.b(label) { asm.move(:t4, :t6) }
              asm.label("#{label}_most")
            end

            # +slot+ moved on to the next corner of the strip in s0, round from its last to its first (s7 is
            # where its corners end).
            def emit_next_slot(asm, slot, label)
              asm.addiu(slot, slot, 4)
              asm.bne(slot, :s7, "#{label}_kept")
              asm.label("#{label}_round")
              asm.addiu(slot, :s0, 4)
              asm.label("#{label}_kept")
            end

            # +slot+ moved back to the corner before in the strip in s0, round from its first to its last.
            # Changes t9.
            def emit_previous_slot(asm, slot, label)
              asm.addiu(:t9, :s0, 4)
              asm.bne(slot, :t9, "#{label}_kept")
              asm.label("#{label}_round")
              asm.move(slot, :s7)
              asm.label("#{label}_kept")
              asm.addiu(slot, slot, -4)
            end

            # The corners of the strip in s0 from t2 on round to t3 put on the end of `square` (a3). Changes t0,
            # t1, t2 and a1.
            def emit_append_run(asm, label)
              asm.label(label)
              asm.lw(:a1, 0, :t2)
              emit_append(asm, :a3, :a1, "#{label}_kept")
              asm.beq(:t2, :t3, "#{label}_done")
              emit_next_slot(asm, :t2, "#{label}_next")
              asm.b(label)
              asm.label("#{label}_done")
            end

            # The run going on round across the line s5 (FacePieces::ChainWalk#cross): each corner it passes
            # put on the end of `square` and made the corner it reached last (AHEAD_FROM_OFFSET_BYTES), then
            # its crossing, the corner on the line or one made there from that corner (rt_face_column_corner),
            # put on too.
            def emit_run_ahead(asm, at)
              x = NUMBER_OFFSETS.fetch(FacePieces::X)
              asm.label("rt_face_row_ahead")
              asm.lw(:a1, 0, :s1)
              asm.lw(:t2, x, :a1)
              asm.slt(:t0, :t2, :s5)
              asm.beq(:t0, :zero, "rt_face_row_ahead_reached")
              asm.label("rt_face_row_ahead_passed")
              asm.sw(:a1, at + AHEAD_FROM_OFFSET_BYTES, FACE_BASE)
              emit_append(asm, :a3, :a1, "rt_face_row_ahead_kept")
              emit_next_slot(asm, :s1, "rt_face_row_ahead_next")
              asm.b("rt_face_row_ahead")
              asm.label("rt_face_row_ahead_reached")
              asm.bne(:t2, :s5, "rt_face_row_ahead_cross")
              asm.label("rt_face_row_ahead_on_line")
              asm.move(:s2, :a1)
              asm.sw(:a1, at + AHEAD_FROM_OFFSET_BYTES, FACE_BASE)
              emit_next_slot(asm, :s1, "rt_face_row_ahead_past_line")
              asm.b("rt_face_row_ahead_crossed")
              asm.label("rt_face_row_ahead_cross")
              asm.lw(:a0, at + AHEAD_FROM_OFFSET_BYTES, FACE_BASE)
              asm.jal("rt_face_column_corner") { asm.move(:a2, :s5) }
              asm.move(:s2, :v0)
              asm.label("rt_face_row_ahead_crossed")
              emit_append(asm, :a3, :s2, "rt_face_row_ahead_crossing")
            end

            # The run going back round across the line s5, as #emit_run_ahead: its crossing put on the end of
            # `square`, then the corners it passed, in the strip's order, which is the way back along the run
            # (BACK_PASSED_OFFSET_BYTES counts them, and BACK_REACHED_OFFSET_BYTES is where it reached the line).
            def emit_run_behind(asm, at)
              x = NUMBER_OFFSETS.fetch(FacePieces::X)
              asm.sw(:zero, at + BACK_PASSED_OFFSET_BYTES, FACE_BASE)
              asm.label("rt_face_row_behind")
              asm.lw(:a1, 0, :s3)
              asm.lw(:t2, x, :a1)
              asm.slt(:t0, :t2, :s5)
              asm.beq(:t0, :zero, "rt_face_row_behind_reached")
              asm.label("rt_face_row_behind_passed")
              asm.sw(:a1, at + BEHIND_FROM_OFFSET_BYTES, FACE_BASE)
              asm.lw(:t0, at + BACK_PASSED_OFFSET_BYTES, FACE_BASE)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, at + BACK_PASSED_OFFSET_BYTES, FACE_BASE)
              emit_previous_slot(asm, :s3, "rt_face_row_behind_next")
              asm.b("rt_face_row_behind")
              asm.label("rt_face_row_behind_reached")
              asm.sw(:s3, at + BACK_REACHED_OFFSET_BYTES, FACE_BASE)
              asm.bne(:t2, :s5, "rt_face_row_behind_cross")
              asm.label("rt_face_row_behind_on_line")
              asm.move(:s4, :a1)
              asm.sw(:a1, at + BEHIND_FROM_OFFSET_BYTES, FACE_BASE)
              emit_previous_slot(asm, :s3, "rt_face_row_behind_past_line")
              asm.b("rt_face_row_behind_crossed")
              asm.label("rt_face_row_behind_cross")
              asm.lw(:a0, at + BEHIND_FROM_OFFSET_BYTES, FACE_BASE)
              asm.jal("rt_face_column_corner") { asm.move(:a2, :s5) }
              asm.move(:s4, :v0)
              asm.label("rt_face_row_behind_crossed")
              emit_append(asm, :a3, :s4, "rt_face_row_behind_crossing")
              asm.lw(:t2, at + BACK_REACHED_OFFSET_BYTES, FACE_BASE)
              asm.lw(:t3, at + BACK_PASSED_OFFSET_BYTES, FACE_BASE)
              asm.label("rt_face_row_behind_passed_back")
              asm.beq(:t3, :zero, "rt_face_row_behind_done")
              emit_next_slot(asm, :t2, "rt_face_row_behind_passed_slot")
              asm.lw(:a1, 0, :t2)
              emit_append(asm, :a3, :a1, "rt_face_row_behind_passed_kept")
              asm.b("rt_face_row_behind_passed_back") { asm.addiu(:t3, :t3, -1) }
              asm.label("rt_face_row_behind_done")
            end

            # `square` (a3) handed to rt_face_send_piece when it has three corners or more; then on to +done+.
            def emit_send_square(asm, done)
              asm.lw(:t0, 0, :a3)
              asm.slti(:t0, :t0, 3)
              asm.bne(:t0, :zero, done)
              asm.label("#{done}_send")
              asm.jal("rt_face_send_piece") { asm.move(:a0, :a3) }
              asm.label(done)
            end

            # rt_face_column_corner: a0 = a corner of a strip before the line a2 across, a1 = the corner its
            # edge reaches past the line at. v0 = the corner made where the edge crosses the line, in the
            # pool's next free place: the corner rt_face_cut makes there (FacePieces.corner_between, a line
            # across). Changes t0 to t9, a0, a1 and v1.
            def emit_column_corner_routine(asm, at)
              x = NUMBER_OFFSETS.fetch(FacePieces::X)
              asm.label("rt_face_column_corner")
              asm.move(:t0, :a0)
              asm.move(:t1, :a1)
              asm.lw(:t2, x, :t0)
              asm.lw(:t3, x, :t1)
              asm.subu(:t3, :t3, :t2)
              asm.subu(:t2, :a2, :t2)
              asm.sll(:t2, :t2, FacePieces::SHARE_BITS)
              asm.div(:t2, :t3)
              # While the divide works, as rt_face_cut does: the corner's place in the pool, and its x.
              asm.lw(:v0, at + POOL_NEXT_OFFSET_BYTES, FACE_BASE)
              asm.addiu(:a1, :v0, CORNER_BYTES)
              asm.sw(:a1, at + POOL_NEXT_OFFSET_BYTES, FACE_BASE)
              asm.sw(:a2, x, :v0)
              emit_step_number(asm, FacePieces::Y, share_from_divide: true)
              emit_step_number(asm, FacePieces::U_SOURCE)
              emit_step_number(asm, FacePieces::V_SOURCE)
              emit_step_number(asm, FacePieces::NEARNESS)
              # The shade on a lit face; on one not lit it is nought at both ends.
              asm.lw(:t2, at + LIGHT_FLOOR_OFFSET_BYTES, FACE_BASE)
              asm.beq(:t2, :zero, "rt_face_column_corner_unlit")
              emit_step_number(asm, FacePieces::SHADE)
              asm.b("rt_face_column_corner_shaded")
              asm.label("rt_face_column_corner_unlit")
              asm.sw(:zero, NUMBER_OFFSETS.fetch(FacePieces::SHADE), :v0)
              asm.label("rt_face_column_corner_shaded")
              asm.move(:v1, :ra)
              asm.jal("rt_face_texel") { asm.move(:a0, :v0) }
              asm.jr(:v1)
            end

            # rt_face_quad: a0 to a3 = the corners of a square of four (#emit_four_corner_cell), in order round it,
            # sent as FacePieces.send_cut_on_picture sends that piece. Most need no cut on the picture, and
            # are sent here as rt_face_fan would send them, its two triangles from the first corner, with no
            # piece made: s0 to s3 hold each corner's place as the chip takes it once worked out, s4 to s7
            # its place on the picture (s4 with the colour table), t4 to t7 its colour on a lit face, v0 the
            # picture's page and v1 not nought on a lit face. One that does need a cut is made the piece
            # `square` and handed to rt_face_send_piece.
            def emit_quad_routine(asm, at, memory, polygon)
              h = Console::PS1Hardware
              corners = %i[s0 s1 s2 s3]
              texels = %i[s4 s5 s6 s7]
              colors = %i[t4 t5 t6 t7]
              offset = ->(number) { NUMBER_OFFSETS.fetch(number) }
              asm.label("rt_face_quad")
              emit_keep_registers(asm)
              %i[a0 a1 a2 a3].zip(corners).each { |from, into| asm.move(into, from) }
              # Each corner's texel, t0 to t3 across and t4 to t7 down, and the picture's place each way moved
              # down to a whole picture, a1 and a2, the square's reach from there no further than PICTURE_REACH
              # (FacePieces.find_picture_cut).
              corners.each_with_index do |corner, i|
                asm.lw(:"t#{i}", offset.call(FacePieces::TEXEL_U), corner)
                asm.lw(:"t#{i + 4}", offset.call(FacePieces::TEXEL_V), corner)
              end
              asm.lw(:v0, at + PICTURE_OFFSET_BYTES, FACE_BASE)
              [[%i[t0 t1 t2 t3], RECORD_ACROSS_MASK_OFFSET_BYTES, :a1, "u"],
               [%i[t4 t5 t6 t7], RECORD_DOWN_MASK_OFFSET_BYTES, :a2, "v"]].each do |(first, *others), mask, base, name|
                asm.move(:t8, first)
                asm.move(:t9, first)
                others.each_with_index { |texel, i| emit_keep_least_and_most(asm, texel, :t8, :t9, "rt_face_quad_#{name}#{i}") }
                asm.lw(base, mask, :v0)
                asm.and(base, :t8, base)
                asm.subu(:t9, :t9, base)
                asm.slti(:t9, :t9, FacePieces::PICTURE_REACH + 1)
                asm.beq(:t9, :zero, "rt_face_quad_cut")
                asm.label("rt_face_quad_fits_#{name}")
              end
              # Each corner's place on the picture as it is sent: moved by the whole pictures, each held to a
              # byte, u | v << 8.
              texels.each_with_index do |texel, i|
                [[:"t#{i}", :a1, "u"], [:"t#{i + 4}", :a2, "v"]].each do |number, base, name|
                  held = "rt_face_quad_held_#{name}#{i}"
                  asm.subu(number, number, base)
                  asm.slti(:t8, number, 256)
                  asm.bne(:t8, :zero, held)
                  asm.label("rt_face_quad_most_#{name}#{i}")
                  asm.li(number, 255)
                  asm.label(held)
                end
                asm.sll(:t9, :"t#{i + 4}", 8)
                asm.or(texel, :"t#{i}", :t9)
              end
              asm.lw(:t0, RECORD_TABLE_OFFSET_BYTES, :v0)
              asm.lw(:v0, RECORD_PAGE_OFFSET_BYTES, :v0)
              asm.or(:s4, :s4, :t0)
              # On a lit face, each corner's colour (FacePieces.corner_color): the shade's whole part, held to
              # FULL_COLOR, in each of the word's three bytes.
              asm.lw(:v1, at + LIGHT_FLOOR_OFFSET_BYTES, FACE_BASE)
              asm.beq(:v1, :zero, "rt_face_quad_colored")
              corners.zip(colors).each_with_index do |(corner, color), i|
                held = "rt_face_quad_color_held#{i}"
                asm.lw(color, offset.call(FacePieces::SHADE), corner)
                asm.srl(color, color, 16)
                asm.sltiu(:t8, color, FacePieces::FULL_COLOR + 1)
                asm.bne(:t8, :zero, held)
                asm.label("rt_face_quad_color_full#{i}")
                asm.li(color, FacePieces::FULL_COLOR)
                asm.label(held)
                asm.sll(:t8, color, 8)
                asm.or(:t8, :t8, color)
                asm.sll(color, color, 16)
                asm.or(color, color, :t8)
              end
              asm.label("rt_face_quad_colored")
              # Each corner's place as the chip takes it (FacePieces.send_fan): rounded to whole pixels, and
              # down from the top of the page drawn into, (y + the page's top) << 16 | x.
              asm.lw(:a3, Runtime.at(memory, Paint::PAGE_Y), :gp)
              corners.each do |corner|
                asm.lw(:t0, offset.call(FacePieces::X), corner)
                asm.lw(:t1, offset.call(FacePieces::Y), corner)
                asm.addiu(:t0, :t0, 8)
                asm.sra(:t0, :t0, 4)
                asm.addiu(:t1, :t1, 8)
                asm.sra(:t1, :t1, 4)
                asm.addu(:t1, :t1, :a3)
                asm.sll(:t1, :t1, 16)
                asm.andi(:t0, :t0, 0xFFFF)
                asm.or(corner, :t1, :t0)
              end
              # The two triangles, (first, second, third) and (first, third, fourth), each sent if it has an
              # area (rt_face_fan's test).
              [[1, 2], [2, 3]].each_with_index do |(second, third), triangle|
                emit_quad_triangle(asm, h, corners, texels, colors, second, third, "rt_face_quad_triangle#{triangle}")
              end
              emit_return_with_registers(asm)
              # A square to cut on the picture: the piece `square`, and rt_face_send_piece in place of the rest.
              asm.label("rt_face_quad_cut")
              square = polygon.call(:square)
              asm.li(:a0, square)
              asm.li(:t0, 4)
              asm.sw(:t0, 0, :a0)
              corners.each_with_index { |corner, i| asm.sw(corner, 4 + (i * 4), :a0) }
              KEPT_REGISTERS.each_with_index { |register, i| asm.lw(register, i * 4, :sp) }
              asm.j("rt_face_send_piece") { asm.addiu(:sp, :sp, 4 * KEPT_REGISTERS.length) }
            end

            # One triangle of rt_face_quad, its first corner the square's and the others +second+ and
            # +third+ of +corners+, sent when it has an area; +label+ names the places between. Changes a0 to
            # a2, t0 to t3, t8 and t9.
            def emit_quad_triangle(asm, h, corners, texels, colors, second, third, label)
              # Twice its area, signed, from the places sent: the page's top is in every y, and drops out.
              asm.sll(:a0, corners[0], 16)
              asm.sra(:a0, :a0, 16)
              asm.sra(:a1, corners[0], 16)
              [[corners[second], :a2, :t0], [corners[third], :t8, :t9]].each do |corner, across, down|
                asm.sll(across, corner, 16)
                asm.sra(across, across, 16)
                asm.subu(across, across, :a0)
                asm.sra(down, corner, 16)
                asm.subu(down, down, :a1)
              end
              asm.mult(:a2, :t9)
              asm.mflo(:a2)
              asm.mult(:t8, :t0)
              asm.mflo(:t8)
              asm.beq(:a2, :t8, "#{label}_done")
              asm.label("#{label}_send")
              # The second corner's place on the picture with the picture's page.
              asm.or(:t9, texels[second], :v0)
              asm.bne(:v1, :zero, "#{label}_shaded")
              asm.label("#{label}_raw")
              emit_port_command(asm) { asm.lui(:a0, h::GP0_TEXTURED_TRIANGLE >> 16) }
              emit_words_stored(asm, [corners[0], texels[0], corners[second], :t9, corners[third], texels[third]])
              asm.b("#{label}_done")
              asm.label("#{label}_shaded")
              asm.lui(:t0, h::GP0_SHADED_TEXTURED_TRIANGLE >> 16)
              emit_port_command(asm) { asm.or(:a0, colors[0], :t0) }
              emit_words_stored(asm, [corners[0], texels[0], colors[second], corners[second], :t9, colors[third],
                                      corners[third], texels[third]])
              asm.label("#{label}_done")
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
              asm.lw(:s2, at + PICTURE_OFFSET_BYTES, FACE_BASE)
              asm.lw(:s5, at + POOL_NEXT_OFFSET_BYTES, FACE_BASE) # where the pool stood as this began
              asm.label("rt_face_send_part")
              asm.lw(:t0, 0, :s0)
              asm.slti(:t0, :t0, 3)
              asm.bne(:t0, :zero, "rt_face_send_waiting")
              asm.jal("rt_face_extents") { asm.move(:a0, :s0) }
              [[FacePieces::TEXEL_U, RECORD_ACROSS_MASK_OFFSET_BYTES], [FacePieces::TEXEL_V, RECORD_DOWN_MASK_OFFSET_BYTES]].each do |number, mask|
                fits = "rt_face_send_fits_#{number}"
                asm.lw(:v0, at + least_offset_bytes(number), FACE_BASE)
                asm.lw(:v1, at + least_offset_bytes(number) + 4, FACE_BASE)
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
              asm.addu(:t0, :t0, FACE_BASE)
              asm.lw(:a1, at + WAITING_MARKS_OFFSET_BYTES - 4, :t0)
              asm.label("rt_face_send_mark_found")
              # Moved down only once more than a piece's worth of corners is past the mark: up to that, the
              # room is the same as the moving would leave (POOL_CORNERS), and the moving costs more than it
              # gives back.
              asm.lw(:t0, at + POOL_NEXT_OFFSET_BYTES, FACE_BASE)
              asm.subu(:t0, :t0, :a1)
              asm.slti(:t0, :t0, (FacePieces::MOST_CORNERS * CORNER_BYTES) + 1)
              asm.bne(:t0, :zero, "rt_face_send_part")
              asm.label("rt_face_send_compact")
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
              asm.addu(:t0, :t0, FACE_BASE)
              asm.lw(:t1, at + POOL_NEXT_OFFSET_BYTES, FACE_BASE)
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
            #
            # EACH CORNER IS READ ONCE AND SENT FROM REGISTERS. The pieces and their corners are in main RAM,
            # which has no cache, so every load waits for the bus; writing each corner as it is sent into a
            # list there and reading it back for every triangle it is in cost more than working it out. The
            # first corner, which every triangle has, is kept in s6 (its place as the chip takes it), s7 (its
            # place on the picture with the colour table) and a3 (its colour on a lit face); the triangle's
            # second corner in t4, t5 and t6, and its third, the corner just read, in v0, a1 and a2. s0 is
            # where the next corner is in the piece and s1 how many are left; s3 and s4 the picture's place
            # moved down to a whole picture each way, s5 the top of the page drawn into, s2 the picture's
            # page, and v1 not nought on a lit face.
            def emit_fan_routine(asm, at, memory)
              h = Console::PS1Hardware
              asm.label("rt_face_fan")
              emit_keep_registers(asm)
              asm.addiu(:s0, :a0, 4)
              asm.lw(:s1, 0, :a0) # how many corners, three or more
              asm.lw(:t0, at + PICTURE_OFFSET_BYTES, FACE_BASE)
              asm.lw(:v0, at + least_offset_bytes(FacePieces::TEXEL_U), FACE_BASE)
              asm.lw(:t1, RECORD_ACROSS_MASK_OFFSET_BYTES, :t0)
              asm.and(:s3, :v0, :t1)
              asm.lw(:v0, at + least_offset_bytes(FacePieces::TEXEL_V), FACE_BASE)
              asm.lw(:t1, RECORD_DOWN_MASK_OFFSET_BYTES, :t0)
              asm.and(:s4, :v0, :t1)
              asm.lw(:s5, Runtime.at(memory, Paint::PAGE_Y), :gp)
              asm.lw(:v1, at + LIGHT_FLOOR_OFFSET_BYTES, FACE_BASE)
              asm.lw(:s2, RECORD_PAGE_OFFSET_BYTES, :t0)
              asm.lw(:t1, RECORD_TABLE_OFFSET_BYTES, :t0)
              emit_fan_corner(asm, %i[s6 s7 a3], "rt_face_fan_first")
              asm.or(:s7, :s7, :t1)
              emit_fan_corner(asm, %i[t4 t5 t6], "rt_face_fan_second")
              asm.addiu(:s1, :s1, -2)
              asm.label("rt_face_fan_triangle")
              emit_fan_corner(asm, %i[v0 a1 a2], "rt_face_fan_third")
              # Twice its area, signed: (bx - ax)(cy - ay) - (cx - ax)(by - ay), from the places sent, the
              # page's top in every y, where it drops out.
              asm.sll(:t0, :s6, 16)
              asm.sra(:t0, :t0, 16)
              asm.sra(:t1, :s6, 16)
              [[:t4, :t2, :t3], [:v0, :t8, :t9]].each do |corner, across, down|
                asm.sll(across, corner, 16)
                asm.sra(across, across, 16)
                asm.subu(across, across, :t0)
                asm.sra(down, corner, 16)
                asm.subu(down, down, :t1)
              end
              asm.mult(:t2, :t9)
              asm.mflo(:t2)
              asm.mult(:t8, :t3)
              asm.mflo(:t8)
              asm.beq(:t2, :t8, "rt_face_fan_next")
              asm.label("rt_face_fan_send")
              asm.or(:t9, :t5, :s2) # the second corner's place on the picture, with the page
              asm.bne(:v1, :zero, "rt_face_fan_shaded")
              asm.label("rt_face_fan_raw")
              emit_port_command(asm) { asm.lui(:a0, h::GP0_TEXTURED_TRIANGLE >> 16) }
              emit_words_stored(asm, %i[s6 s7 t4 t9 v0 a1])
              asm.b("rt_face_fan_next")
              # A lit face's: GP0 34h with the first corner's colour, then each corner's place and texel,
              # and the next corner's colour before its place.
              asm.label("rt_face_fan_shaded")
              asm.lui(:t0, h::GP0_SHADED_TEXTURED_TRIANGLE >> 16)
              emit_port_command(asm) { asm.or(:a0, :a3, :t0) }
              emit_words_stored(asm, %i[s6 s7 t6 t4 t9 a2 v0 a1])
              # The third corner is the next triangle's second.
              asm.label("rt_face_fan_next")
              asm.move(:t4, :v0)
              asm.move(:t5, :a1)
              asm.move(:t6, :a2)
              asm.addiu(:s1, :s1, -1)
              asm.bne(:s1, :zero, "rt_face_fan_triangle")
              asm.label("rt_face_fan_done")
              emit_return_with_registers(asm)
            end

            # The corner at s0 in the piece, as rt_face_fan sends it, into +into+ (its place as the chip takes
            # it, (y + the page's top) << 16 | x; its place on the picture, u | v << 8, moved by the whole
            # pictures s3 and s4 and each held to a byte; and on a lit face its colour, the shade's whole part
            # held to FULL_COLOR in each of the word's three bytes), and s0 moved on to the next. Changes t0,
            # t8, t9 and a0.
            def emit_fan_corner(asm, into, label)
              place, texel, color = into
              offset = ->(number) { NUMBER_OFFSETS.fetch(number) }
              asm.lw(:t8, 0, :s0)
              asm.addiu(:s0, :s0, 4)
              asm.lw(:t0, offset.call(FacePieces::X), :t8)
              asm.lw(place, offset.call(FacePieces::Y), :t8)
              asm.addiu(:t0, :t0, 8)
              asm.sra(:t0, :t0, 4)
              asm.andi(:t0, :t0, 0xFFFF)
              asm.addiu(place, place, 8)
              asm.sra(place, place, 4)
              asm.addu(place, place, :s5)
              asm.sll(place, place, 16)
              asm.or(place, place, :t0)
              [[FacePieces::TEXEL_U, :s3, :t9], [FacePieces::TEXEL_V, :s4, texel]].each do |number, base, number_into|
                held = "#{label}_held_#{number}"
                asm.lw(number_into, offset.call(number), :t8)
                asm.subu(number_into, number_into, base)
                asm.slti(:a0, number_into, 256)
                asm.bne(:a0, :zero, held)
                asm.label("#{label}_most_#{number}")
                asm.li(number_into, 255)
                asm.label(held)
              end
              asm.sll(texel, texel, 8)
              asm.or(texel, texel, :t9)
              asm.beq(:v1, :zero, "#{label}_colored")
              asm.lw(color, offset.call(FacePieces::SHADE), :t8)
              asm.srl(color, color, 16)
              asm.sltiu(:a0, color, FacePieces::FULL_COLOR + 1)
              asm.bne(:a0, :zero, "#{label}_color_held")
              asm.label("#{label}_color_full")
              asm.li(color, FacePieces::FULL_COLOR)
              asm.label("#{label}_color_held")
              asm.sll(:a0, color, 8)
              asm.or(:a0, :a0, color)
              asm.sll(color, color, 16)
              asm.or(color, color, :a0)
              asm.label("#{label}_colored")
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
              # A line across the screen: an end below it that a cut made, on the edge to the same far end,
              # gives way to the end it was worked out from, how far that is past the line in t2
              # (FacePieces.crossing_on_edge).
              asm.sltiu(:t9, :s3, NUMBER_OFFSETS.fetch(FacePieces::U_SOURCE))
              asm.beq(:t9, :zero, "rt_face_cut_from_edge")
              asm.label("rt_face_cut_edge_end")
              asm.lw(:t9, EDGE_END_OFFSET_BYTES, :t0)
              asm.bne(:t9, :t1, "rt_face_cut_from_edge")
              asm.label("rt_face_cut_edge_start")
              asm.lw(:t0, EDGE_START_OFFSET_BYTES, :t0)
              asm.addu(:t9, :t0, :s3)
              asm.lw(:t2, 0, :t9)
              asm.subu(:t2, :t2, :s4)
              asm.label("rt_face_cut_from_edge")
              asm.subu(:t3, :t3, :t2)
              asm.subu(:t2, :zero, :t2)
              asm.sll(:t2, :t2, FacePieces::SHARE_BITS)
              asm.div(:t2, :t3)
              # THE DIVIDE TAKES DOZENS OF CYCLES, and the processor goes on beside it until the share is
              # asked for (MFLO), which waits for what is left. So the corner made goes in the pool's next
              # free place, which way the cut goes is decided, and the first number to step is read and
              # its difference taken, all before the share is asked for: the first step of each way asks
              # for it (#emit_step_number, +share_from_divide+).
              asm.lw(:v0, at + POOL_NEXT_OFFSET_BYTES, FACE_BASE)
              asm.addiu(:a0, :v0, CORNER_BYTES)
              asm.sw(:a0, at + POOL_NEXT_OFFSET_BYTES, FACE_BASE)
              # On a line across the screen, only the numbers read again are stepped
              # (FacePieces::SCREEN_CUT_NUMBERS): the other of x and y, and what the texel is worked out
              # from. The texel itself is worked out where the corner is, below, and the number cut on is
              # the line. A nearness of a face not in perspective, and a shade of a face not lit, are
              # nought at both ends, so they are left nought rather than stepped. On the picture or
              # between levels only FacePieces::LATE_CUT_NUMBERS are stepped, the rest the start's.
              asm.sltiu(:t2, :s3, NUMBER_OFFSETS.fetch(FacePieces::U_SOURCE))
              asm.beq(:t2, :zero, "rt_face_cut_late")
              emit_screen_cut_corner(asm, at)
              emit_late_cut_corner(asm, at)
              asm.label("rt_face_cut_stepped")
              asm.addu(:t0, :v0, :s3)
              asm.sw(:s4, 0, :t0)
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
              emit_step_number(asm, y, share_from_divide: true)
              asm.b("rt_face_cut_sources")
              asm.label("rt_face_cut_down")
              emit_step_number(asm, x, share_from_divide: true)
              asm.label("rt_face_cut_sources")
              emit_step_number(asm, FacePieces::U_SOURCE)
              emit_step_number(asm, FacePieces::V_SOURCE)
              [[FacePieces::NEARNESS, SPANS_OFFSET_BYTES], [FacePieces::SHADE, LIGHT_FLOOR_OFFSET_BYTES]].each do |number, said|
                none = "rt_face_cut_none_#{number}"
                done = "rt_face_cut_stepped_#{number}"
                asm.lw(:t2, at + said, FACE_BASE)
                asm.beq(:t2, :zero, none)
                emit_step_number(asm, number)
                asm.b(done)
                asm.label(none)
                asm.sw(:zero, NUMBER_OFFSETS.fetch(number), :v0)
                asm.label(done)
              end
              # The two ends of the edge it was worked out from.
              asm.sw(:t0, EDGE_START_OFFSET_BYTES, :v0)
              asm.b("rt_face_cut_stepped") { asm.sw(:t1, EDGE_END_OFFSET_BYTES, :v0) }
            end

            # The corner a cut on the picture or between levels makes, at v0, from t0 the share t8 of the way
            # to t1, falling through to rt_face_cut_stepped: x and y stepped; each texel and the shade stepped
            # unless it is the number cut on (s3), which the line sets, and the shade only on a lit face (on
            # a face not lit it is nought at both ends); the rest the start's (FacePieces::LATE_CUT_NUMBERS).
            def emit_late_cut_corner(asm, at)
              asm.label("rt_face_cut_late")
              # The share is taken from the divide by the first step every corner makes, x's or y's, since
              # the others' steps can be passed over.
              share_taken = false
              FacePieces::NUMBERS.times do |number|
                if [FacePieces::X, FacePieces::Y].include?(number)
                  emit_step_number(asm, number, share_from_divide: !share_taken)
                  share_taken = true
                elsif FacePieces::LATE_CUT_NUMBERS.include?(number)
                  raise "a late cut steps #{number} before x or y, so the divide's share is not taken yet" unless share_taken

                  copied = "rt_face_cut_late_copied_#{number}"
                  stepped = "rt_face_cut_late_stepped_#{number}"
                  asm.li(:t2, NUMBER_OFFSETS.fetch(number))
                  asm.beq(:s3, :t2, stepped) # the line sets it
                  if number == FacePieces::SHADE
                    asm.lw(:t2, at + LIGHT_FLOOR_OFFSET_BYTES, FACE_BASE)
                    asm.beq(:t2, :zero, copied)
                  end
                  emit_step_number(asm, number)
                  if number == FacePieces::SHADE
                    asm.b(stepped)
                    asm.label(copied)
                    asm.sw(:zero, number * 4, :v0)
                  end
                  asm.label(stepped)
                else
                  asm.lw(:a0, number * 4, :t0)
                  asm.sw(:a0, number * 4, :v0)
                end
              end
            end

            # +number+ of the corner at t0 stepped the share t8 of the way to the one at t1, into the corner
            # at v0. Changes a0, a1 and t9. With +share_from_divide+, the share is taken into t8 from the
            # divide working it out once the number is read, rather than before.
            def emit_step_number(asm, number, share_from_divide: false)
              asm.lw(:a0, number * 4, :t0)
              asm.lw(:a1, number * 4, :t1)
              asm.subu(:a1, :a1, :a0)
              asm.mflo(:t8) if share_from_divide
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
              emit_extents_loop(asm, at, EXTENT_NUMBERS.zip(%i[t2 t4], %i[t3 t5]), "rt_face_extents")
            end

            # The loop of rt_face_extents over the numbers +kept+ ([number, the register for its least, for
            # its most] each), from +label+ to its return.
            def emit_extents_loop(asm, at, kept, label)
              asm.label(label)
              asm.lw(:t0, 0, :a0)
              asm.lw(:v0, 4, :a0)
              asm.addiu(:t1, :a0, 4)
              kept.each do |number, least, most|
                asm.lw(least, NUMBER_OFFSETS.fetch(number), :v0)
                asm.move(most, least)
              end
              asm.label("#{label}_corner")
              asm.addiu(:t0, :t0, -1)
              asm.beq(:t0, :zero, "#{label}_done")
              asm.addiu(:t1, :t1, 4)
              asm.lw(:v0, 0, :t1)
              kept.each do |number, least, most|
                not_least = "#{label}_not_least_#{number}"
                not_most = "#{label}_not_most_#{number}"
                asm.lw(:t8, NUMBER_OFFSETS.fetch(number), :v0)
                asm.slt(:t9, :t8, least)
                asm.beq(:t9, :zero, not_least)
                asm.label("#{label}_least_#{number}")
                asm.move(least, :t8)
                asm.label(not_least)
                asm.slt(:t9, most, :t8)
                asm.beq(:t9, :zero, not_most)
                asm.label("#{label}_most_#{number}")
                asm.move(most, :t8)
                asm.label(not_most)
              end
              asm.b("#{label}_corner")
              asm.label("#{label}_done")
              kept.each do |number, least, most|
                asm.sw(least, at + least_offset_bytes(number), FACE_BASE)
                asm.sw(most, at + least_offset_bytes(number) + 4, FACE_BASE)
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
              asm.sw(:t3, at + POOL_NEXT_OFFSET_BYTES, FACE_BASE)
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
              asm.lw(:t0, at + SPANS_OFFSET_BYTES, FACE_BASE)
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
