# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE FACES OF A PLACE, filled exactly as the interpreter fills them (Reference#exec_fill_face):
          # the same sums, in the same order, on the same 32-bit numbers, so every pixel lands where the
          # interpreter's lands and shows the picture's pixel the interpreter's shows.
          #
          # WHY THE PROCESSOR WORKS OUT EVERY PIXEL, AND NOT THE GRAPHICS CHIP. The chip can fill a
          # textured four-sided shape by itself, and that is how a PlayStation game drew its walls. But it
          # fills by rules of its own, and none of them is the interpreter's (psx-spx, "GPU Render
          # Polygon Commands"; Beetle PSX's gpu_polygon.cpp):
          #
          # - a corner is a whole pixel (signed 11 bits), where the interpreter's corners are in sixteenths
          #   of a pixel, so an edge lands up to half a pixel away;
          # - its edges are walked by its own fixed-point steps from those whole corners, and a quad is
          #   two triangles, each with its own steps;
          # - a corner's place on the picture is a whole texel (8 bits each way), where the interpreter's
          #   is in 65536ths, and it steps the place across each triangle, where the interpreter steps it
          #   across each row from the row's two ends, dividing by the row's length;
          # - it has no perspective at all, only the straight steps.
          #
          # Each of those moves pixels of a face by a pixel, or the picture under them by a texel, and the
          # face must match the interpreter's with no pixel let off. So the processor walks the face as the
          # interpreter does, and the chip is handed only the finished pixels: each run of a row that the
          # picture does not leave see-through is copied into video RAM (GP0 A0h) from a row of pixels in
          # RAM, as a picture is copied in at power-on. A copy is not drawn, so nothing of the chip's
          # drawing rules can touch it: the pixels are the interpreter's, bit for bit.
          #
          # THE PICTURES are in RAM as the colours themselves, a halfword a pixel, row by row (each with
          # its top bit set, and nought for see-through, as Runtime::Paint's textures hold them), so a
          # pixel is one load. Their sides are powers of two, as a place's pictures are, so a place on
          # the picture is held to the picture by a mask and a row found by a shift.
          #
          # HOW IT IS CALLED. The lowering works out the face's numbers in the interpreter's order: the
          # picture (PICTURE_OFFSET_BYTES, the address of its record: the pixels, log2 of its width, its width less one,
          # its height less one), then the count, and rt_face_corners reads the corners from the list;
          # only when there are three or more are the edges and the perspective worked out (LEFT_OFFSET_BYTES to
          # SPANS_OFFSET_BYTES), and rt_fill_face called.
          module Faces
            FACE = "rt face"

            # A corner: x, y, u, v, w and its light, a word each (Nodes::FillFace::CORNER_NUMBERS). The
            # routines below find a corner by multiplying its number by six with two shifts, so a change
            # to that count stops the build here rather than drawing from the wrong place.
            CORNER_BYTES = Nodes::FillFace::CORNER_NUMBERS * 4
            raise "Runtime::Faces finds a corner as six words" unless CORNER_BYTES == 24

            # An edge: its first row and the row past its last, then x, u, v and w where it crosses its
            # first row, then each one's step a row (Reference::FaceEdge).
            EDGE_FIRST_ROW_OFFSET_BYTES = 0
            EDGE_PAST_ROW_OFFSET_BYTES = 4
            EDGE_AT_OFFSET_BYTES = 8
            EDGE_STEP_OFFSET_BYTES = 24
            EDGE_BYTES = 40

            # Where each number is in FACE, in bytes from its start.
            PICTURE_OFFSET_BYTES = 0
            COUNT_OFFSET_BYTES = 4
            LEFT_OFFSET_BYTES = 8
            TOP_OFFSET_BYTES = 12
            RIGHT_OFFSET_BYTES = 16
            BOTTOM_OFFSET_BYTES = 20
            SPANS_OFFSET_BYTES = 24
            EDGE_COUNT_OFFSET_BYTES = 28
            LAST_ROW_OFFSET_BYTES = 32
            START_OFFSET_BYTES = 36 # where the row's pixels start
            ROW_COUNT_OFFSET_BYTES = 40 # ...and how many it has
            ROW_END_OFFSET_BYTES = 44 # the pixel past the last one drawn of the row
            RUN_X_OFFSET_BYTES = 48 # where the pixels waiting in BUFFER_OFFSET_BYTES go
            FROM_OFFSET_BYTES = 52 # the row's left end: x, u, v, w
            STEP_OFFSET_BYTES = 68 # the row's steps a pixel: u, v, w
            NEAR_AT_OFFSET_BYTES = 80 # in perspective, how far along the row the last place worked out is, and it
            NEAR_U_OFFSET_BYTES = 84
            NEAR_V_OFFSET_BYTES = 88
            FAR_AT_OFFSET_BYTES = 92 # ...and how far along the next is
            CORNERS_OFFSET_BYTES = 96 # the corners, CORNER_BYTES each
            EDGES_OFFSET_BYTES = CORNERS_OFFSET_BYTES + (Nodes::FillFace::MOST_CORNERS * CORNER_BYTES)
            BUFFER_OFFSET_BYTES = EDGES_OFFSET_BYTES + (Nodes::FillFace::MOST_CORNERS * EDGE_BYTES)
            BYTES = BUFFER_OFFSET_BYTES + (Console::PS1Hardware::SCREEN_WIDTH * 2)

            # A picture's record: where its pixels are, log2 of its width, and its width and height less
            # one.
            RECORD_PIXELS_OFFSET_BYTES = 0
            RECORD_SHIFT_OFFSET_BYTES = 4
            RECORD_ACROSS_MASK_OFFSET_BYTES = 8
            RECORD_DOWN_MASK_OFFSET_BYTES = 12

            # IR::Reciprocals::TABLE, as the processor reads it.
            RECIPROCALS = "rt face reciprocals"

            module_function

            def reserve(memory) = memory.reserve(FACE, BYTES)

            def emit(asm, memory)
              at = Runtime.at(memory, FACE)
              buffer = memory[FACE] + BUFFER_OFFSET_BYTES
              emit_face_corners_routine(asm, at)
              emit_fill_face_routine(asm, at, memory)
              emit_face_edges_routine(asm, at)
              emit_face_rows_routine(asm, at)
              emit_face_row_routines(asm, at, buffer)
              emit_face_place_routine(asm, at)
              emit_face_flush_routine(asm, at, memory, buffer)
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

            # rt_face_corners: a0 = the list of corners, a1 = how many. The count held to MOST_CORNERS and
            # kept in COUNT_OFFSET_BYTES; with three or more, each corner's numbers read from the list into CORNERS_OFFSET_BYTES,
            # through rt_list_get, so an index past the list's end stops the game as the interpreter's
            # does (Reference#check_list_index!).
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

            # rt_fill_face: the face whose corners rt_face_corners read, its picture in PICTURE_OFFSET_BYTES and its
            # edges and perspective in LEFT_OFFSET_BYTES to SPANS_OFFSET_BYTES. Keeps s0 to s7.
            #
            # The edges nothing outside is drawn are held to the screen, and to the area `inside` holds
            # drawing to (Runtime::Paint::AREA), which lies inside the screen: the interpreter draws a
            # pixel only inside both (Reference::Framebuffer#paintable?). In perspective, each corner's
            # place on the picture becomes the place over the distance (Reference::FaceEdges.in_perspective).
            def emit_fill_face_routine(asm, at, memory)
              area = ->(offset) { Runtime.at(memory, Paint::AREA) + offset }
              asm.label("rt_fill_face")
              asm.addiu(:sp, :sp, -36)
              asm.sw(:ra, 0, :sp)
              KEPT_REGISTERS.each_with_index { |register, i| asm.sw(register, 4 + (i * 4), :sp) }
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
              asm.lw(:t0, at + SPANS_OFFSET_BYTES, :gp)
              asm.beq(:t0, :zero, "rt_fill_face_edges")
              asm.lw(:s1, at + COUNT_OFFSET_BYTES, :gp)
              asm.addiu(:s0, :gp, at + CORNERS_OFFSET_BYTES)
              asm.label("rt_fill_face_perspective")
              asm.lw(:t0, 8, :s0) # u
              asm.lw(:t1, 12, :s0) # v
              asm.lw(:t2, 16, :s0) # w
              emit_mul_fix(asm, :t0, :t0, :t2, 28)
              emit_mul_fix(asm, :t1, :t1, :t2, 28)
              asm.sw(:t0, 8, :s0)
              asm.sw(:t1, 12, :s0)
              asm.addiu(:s1, :s1, -1)
              asm.bne(:s1, :zero, "rt_fill_face_perspective") { asm.addiu(:s0, :s0, CORNER_BYTES) }
              asm.label("rt_fill_face_edges")
              asm.jal("rt_face_edges")
              asm.jal("rt_face_rows")
              asm.lw(:ra, 0, :sp)
              KEPT_REGISTERS.each_with_index { |register, i| asm.lw(register, 4 + (i * 4), :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, 36) }
            end

            KEPT_REGISTERS = %i[s0 s1 s2 s3 s4 s5 s6 s7].freeze

            # rt_face_edges: each pair of corners next to each other round the face made an edge in EDGES_OFFSET_BYTES,
            # in the order the corners go round, and their number in EDGE_COUNT_OFFSET_BYTES (Reference::FaceEdges.of):
            # none for a pair level with each other, or whose edge crosses no row's middle. Changes s0 to s6.
            #
            # An edge is taken from its upper corner down (s2) to its lower (s3). How far one row is along
            # it, with 24 fraction bits, is one divide; where it first crosses a row's middle is worked out
            # from it (Reference::FaceEdges.edge).
            def emit_face_edges_routine(asm, at)
              asm.label("rt_face_edges")
              asm.lw(:s1, at + COUNT_OFFSET_BYTES, :gp)
              asm.move(:s0, :zero) # the corner
              asm.addiu(:s4, :gp, at + EDGES_OFFSET_BYTES) # where the next edge goes
              asm.sw(:zero, at + EDGE_COUNT_OFFSET_BYTES, :gp)
              asm.label("rt_face_edges_next")
              asm.addiu(:t0, :s0, 1) # the next corner round, the first after the last
              asm.bne(:t0, :s1, "rt_face_edges_pair")
              asm.label("rt_face_edges_round")
              asm.move(:t0, :zero)
              asm.label("rt_face_edges_pair")
              [[:s2, :s0], [:s3, :t0]].each do |into, corner|
                asm.sll(:t1, corner, 3)
                asm.sll(into, corner, 4)
                asm.addu(into, into, :t1) # 24 bytes a corner
                asm.addu(into, into, :gp)
                asm.addiu(into, into, at + CORNERS_OFFSET_BYTES)
              end
              asm.lw(:t1, 4, :s2)
              asm.lw(:t2, 4, :s3)
              asm.beq(:t1, :t2, "rt_face_edges_skip")
              asm.slt(:t3, :t1, :t2)
              asm.bne(:t3, :zero, "rt_face_edges_ordered")
              asm.label("rt_face_edges_swap")
              asm.move(:t3, :s2)
              asm.move(:s2, :s3)
              asm.move(:s3, :t3)
              asm.label("rt_face_edges_ordered")
              asm.lw(:t1, 4, :s2) # the top corner's y
              asm.lw(:t2, 4, :s3) # the bottom corner's
              asm.addiu(:t3, :t1, 7)
              asm.sra(:t3, :t3, 4) # the first row
              asm.addiu(:t4, :t2, 7)
              asm.sra(:t4, :t4, 4) # the row past the last
              asm.slt(:t5, :t3, :t4)
              asm.beq(:t5, :zero, "rt_face_edges_skip")
              asm.sw(:t3, EDGE_FIRST_ROW_OFFSET_BYTES, :s4)
              asm.sw(:t4, EDGE_PAST_ROW_OFFSET_BYTES, :s4)
              asm.subu(:t2, :t2, :t1)
              asm.lui(:t5, 0x1000) # 1 << 28
              asm.div(:t5, :t2)
              asm.mflo(:s5) # along a row
              asm.sll(:t3, :t3, 4)
              asm.addiu(:t3, :t3, 8)
              asm.subu(:t3, :t3, :t1)
              emit_mul_fix(asm, :s6, :t3, :s5, 4) # into the first row
              # x moved up 12 bits, then u, v and w: each edge's start and step from its two ends.
              4.times do |part|
                field = part.zero? ? 0 : part + 1
                asm.lw(:t1, field * 4, :s2)
                asm.lw(:t2, field * 4, :s3)
                asm.subu(:t2, :t2, :t1)
                if part.zero?
                  asm.sll(:t1, :t1, 12)
                  asm.sll(:t2, :t2, 12)
                end
                emit_mul_fix(asm, :t3, :t2, :s6, 24)
                asm.addu(:t3, :t3, :t1)
                asm.sw(:t3, EDGE_AT_OFFSET_BYTES + (part * 4), :s4)
                emit_mul_fix(asm, :t3, :t2, :s5, 24)
                asm.sw(:t3, EDGE_STEP_OFFSET_BYTES + (part * 4), :s4)
              end
              asm.lw(:t0, at + EDGE_COUNT_OFFSET_BYTES, :gp)
              asm.addiu(:s4, :s4, EDGE_BYTES)
              asm.addiu(:t0, :t0, 1)
              asm.sw(:t0, at + EDGE_COUNT_OFFSET_BYTES, :gp)
              asm.label("rt_face_edges_skip")
              asm.addiu(:s0, :s0, 1)
              asm.bne(:s0, :s1, "rt_face_edges_next")
              asm.jr(:ra)
            end

            # rt_face_rows: every row from the first an edge crosses to the last, held to TOP_OFFSET_BYTES and BOTTOM_OFFSET_BYTES.
            # On each, the edges crossing it are found, and the row is filled from where the leftmost
            # crosses it to where the rightmost does (Reference#exec_fill_face): the first of the leftmost,
            # and the last of the rightmost, as the interpreter picks between edges crossing at one place.
            # A row two edges do not cross is passed over.
            #
            # s0 is the row. Each edge crossing it is at its x a row on from where it starts (t7), and t8
            # and t9 hold the leftmost and rightmost edges found so far, t3 and t4 their x.
            def emit_face_rows_routine(asm, at)
              asm.label("rt_face_rows")
              asm.lw(:t0, at + EDGE_COUNT_OFFSET_BYTES, :gp)
              asm.addiu(:sp, :sp, -4)
              asm.beq(:t0, :zero, "rt_face_rows_done") { asm.sw(:ra, 0, :sp) }
              # The first row any edge crosses and the last, held to TOP_OFFSET_BYTES and BOTTOM_OFFSET_BYTES.
              asm.addiu(:t1, :gp, at + EDGES_OFFSET_BYTES)
              asm.lw(:s0, EDGE_FIRST_ROW_OFFSET_BYTES, :t1)
              asm.lw(:t2, EDGE_PAST_ROW_OFFSET_BYTES, :t1)
              asm.label("rt_face_rows_span")
              asm.addiu(:t0, :t0, -1)
              asm.beq(:t0, :zero, "rt_face_rows_spanned")
              asm.addiu(:t1, :t1, EDGE_BYTES)
              asm.lw(:t3, EDGE_FIRST_ROW_OFFSET_BYTES, :t1)
              asm.lw(:t4, EDGE_PAST_ROW_OFFSET_BYTES, :t1)
              asm.slt(:t5, :t3, :s0)
              asm.beq(:t5, :zero, "rt_face_rows_first")
              asm.label("rt_face_rows_earlier")
              asm.move(:s0, :t3)
              asm.label("rt_face_rows_first")
              asm.slt(:t5, :t2, :t4)
              asm.beq(:t5, :zero, "rt_face_rows_span")
              asm.label("rt_face_rows_later")
              asm.b("rt_face_rows_span") { asm.move(:t2, :t4) }
              asm.label("rt_face_rows_spanned")
              asm.lw(:t3, at + TOP_OFFSET_BYTES, :gp)
              asm.slt(:t5, :s0, :t3)
              asm.beq(:t5, :zero, "rt_face_rows_top")
              asm.label("rt_face_rows_below_top")
              asm.move(:s0, :t3)
              asm.label("rt_face_rows_top")
              asm.lw(:t3, at + BOTTOM_OFFSET_BYTES, :gp)
              asm.slt(:t5, :t3, :t2)
              asm.beq(:t5, :zero, "rt_face_rows_bottom")
              asm.label("rt_face_rows_past_bottom")
              asm.move(:t2, :t3)
              asm.label("rt_face_rows_bottom")
              asm.sw(:t2, at + LAST_ROW_OFFSET_BYTES, :gp)
              # The picture, for the whole face: its pixels in v1, and a1, a2 and a3 the shift and masks.
              asm.lw(:t0, at + PICTURE_OFFSET_BYTES, :gp)
              asm.lw(:v1, RECORD_PIXELS_OFFSET_BYTES, :t0)
              asm.lw(:a1, RECORD_SHIFT_OFFSET_BYTES, :t0)
              asm.lw(:a2, RECORD_ACROSS_MASK_OFFSET_BYTES, :t0)
              asm.lw(:a3, RECORD_DOWN_MASK_OFFSET_BYTES, :t0)

              asm.label("rt_face_rows_next")
              asm.lw(:t0, at + LAST_ROW_OFFSET_BYTES, :gp)
              asm.slt(:t1, :s0, :t0)
              asm.beq(:t1, :zero, "rt_face_rows_done")
              asm.lw(:t0, at + EDGE_COUNT_OFFSET_BYTES, :gp)
              asm.addiu(:t1, :gp, at + EDGES_OFFSET_BYTES)
              asm.move(:t2, :zero) # how many cross the row
              asm.label("rt_face_rows_edge")
              asm.lw(:t5, EDGE_FIRST_ROW_OFFSET_BYTES, :t1)
              asm.lw(:t6, EDGE_PAST_ROW_OFFSET_BYTES, :t1)
              asm.slt(:t7, :s0, :t5)
              asm.bne(:t7, :zero, "rt_face_rows_edge_next")
              asm.slt(:t7, :s0, :t6)
              asm.beq(:t7, :zero, "rt_face_rows_edge_next")
              asm.subu(:t7, :s0, :t5) # rows along it
              asm.lw(:t5, EDGE_STEP_OFFSET_BYTES, :t1)
              asm.lw(:t6, EDGE_AT_OFFSET_BYTES, :t1)
              asm.mult(:t5, :t7)
              asm.mflo(:t5)
              asm.addu(:t5, :t5, :t6) # its x on this row
              asm.bne(:t2, :zero, "rt_face_rows_compare")
              asm.label("rt_face_rows_first_crossing")
              asm.move(:t3, :t5)
              asm.move(:t4, :t5)
              asm.move(:t8, :t1)
              asm.b("rt_face_rows_counted") { asm.move(:t9, :t1) }
              asm.label("rt_face_rows_compare")
              asm.slt(:t6, :t5, :t3)
              asm.beq(:t6, :zero, "rt_face_rows_not_left")
              asm.label("rt_face_rows_left")
              asm.move(:t3, :t5)
              asm.move(:t8, :t1)
              asm.label("rt_face_rows_not_left")
              asm.slt(:t6, :t5, :t4)
              asm.bne(:t6, :zero, "rt_face_rows_counted")
              asm.label("rt_face_rows_right")
              asm.move(:t4, :t5)
              asm.move(:t9, :t1)
              asm.label("rt_face_rows_counted")
              asm.addiu(:t2, :t2, 1)
              asm.label("rt_face_rows_edge_next")
              asm.addiu(:t0, :t0, -1)
              asm.bne(:t0, :zero, "rt_face_rows_edge") { asm.addiu(:t1, :t1, EDGE_BYTES) }
              asm.slti(:t0, :t2, 2)
              asm.bne(:t0, :zero, "rt_face_rows_passed")
              asm.label("rt_face_rows_two")
              asm.move(:a0, :t8)
              asm.jal("rt_face_row") { asm.move(:t0, :t9) }
              asm.label("rt_face_rows_passed")
              asm.b("rt_face_rows_next") { asm.addiu(:s0, :s0, 1) }
              asm.label("rt_face_rows_done")
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
            end

            # rt_face_row: a0 = the leftmost edge crossing row s0, t0 = the rightmost. The pixels of the row
            # whose middles lie between where they cross it (Reference#fill_face_row): where each crosses
            # it worked out (FROM_OFFSET_BYTES, and the right one's in t1 to t4), the row's steps a pixel (STEP_OFFSET_BYTES), and
            # its pixels from the later of where it starts and LEFT_OFFSET_BYTES to the earlier of where it stops and
            # RIGHT_OFFSET_BYTES, a run at a time between the parts the picture leaves see-through.
            def emit_face_row_routines(asm, at, buffer)
              asm.label("rt_face_row")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              # Where the right edge crosses the row: t1 to t4.
              emit_edge_on_row(asm, :t0, %i[t1 t2 t3 t4])
              # ...and the left, into FROM_OFFSET_BYTES.
              emit_edge_on_row(asm, :a0, %i[t5 t6 t7 t8])
              %i[t5 t6 t7 t8].each_with_index { |register, i| asm.sw(register, at + FROM_OFFSET_BYTES + (i * 4), :gp) }
              # The pixels whose middles are inside: from the first at or past each end's middle.
              asm.addiu(:t5, :t5, 0x7FFF)
              asm.sra(:t5, :t5, 16) # start
              asm.addiu(:t1, :t1, 0x7FFF)
              asm.sra(:t1, :t1, 16) # stop
              asm.subu(:t9, :t1, :t5) # count
              asm.blez(:t9, "rt_face_row_done")
              asm.sw(:t5, at + START_OFFSET_BYTES, :gp)
              asm.sw(:t9, at + ROW_COUNT_OFFSET_BYTES, :gp)
              # The steps a pixel: what each changes by across the row, over the count.
              [[:t2, :t6], [:t3, :t7], [:t4, :t8]].each_with_index do |(right, left), i|
                asm.subu(right, right, left)
                asm.div(right, :t9)
                asm.mflo(right)
                asm.sw(right, at + STEP_OFFSET_BYTES + (i * 4), :gp)
              end
              # The first pixel and the one past the last.
              asm.lw(:t0, at + LEFT_OFFSET_BYTES, :gp)
              asm.slt(:t2, :t5, :t0)
              asm.bne(:t2, :zero, "rt_face_row_left")
              asm.label("rt_face_row_from_start")
              asm.move(:t0, :t5)
              asm.label("rt_face_row_left")
              asm.lw(:t2, at + RIGHT_OFFSET_BYTES, :gp)
              asm.slt(:t3, :t1, :t2)
              asm.beq(:t3, :zero, "rt_face_row_right")
              asm.label("rt_face_row_to_stop")
              asm.move(:t2, :t1)
              asm.label("rt_face_row_right")
              asm.slt(:t3, :t0, :t2)
              asm.beq(:t3, :zero, "rt_face_row_done")
              asm.sw(:t2, at + ROW_END_OFFSET_BYTES, :gp)
              asm.move(:s1, :t0) # x
              asm.sw(:s1, at + RUN_X_OFFSET_BYTES, :gp)
              asm.li(:s7, buffer)
              asm.lw(:t3, at + SPANS_OFFSET_BYTES, :gp)
              asm.bne(:t3, :zero, "rt_face_row_perspective")
              # Without perspective: one straight step across the whole row.
              asm.label("rt_face_row_straight")
              asm.subu(:t4, :s1, :t5) # how far along
              asm.lw(:s5, at + STEP_OFFSET_BYTES, :gp)
              asm.lw(:s6, at + STEP_OFFSET_BYTES + 4, :gp)
              asm.lw(:s3, at + FROM_OFFSET_BYTES + 4, :gp)
              asm.lw(:s4, at + FROM_OFFSET_BYTES + 8, :gp)
              asm.mult(:s5, :t4)
              asm.mflo(:t6)
              asm.addu(:s3, :s3, :t6)
              asm.mult(:s6, :t4)
              asm.mflo(:t6)
              asm.addu(:s4, :s4, :t6)
              asm.jal("rt_face_run") { asm.move(:s2, :t2) }
              asm.b("rt_face_row_end")

              # In perspective: the place worked out exactly every span of pixels along and at the row's end,
              # and stepped straight between (Reference#place_between).
              # The interpreter keeps each place it works out by how far along it is, so the far place of
              # one span is the near place of the next, worked out once; so is it here (NEAR_AT_OFFSET_BYTES, NEAR_U_OFFSET_BYTES,
              # NEAR_V_OFFSET_BYTES).
              asm.label("rt_face_row_perspective")
              asm.lw(:t5, at + START_OFFSET_BYTES, :gp)
              asm.lw(:t3, at + SPANS_OFFSET_BYTES, :gp)
              asm.subu(:t4, :s1, :t5) # how far along
              asm.divu(:t4, :t3)
              asm.mflo(:t6)
              asm.mult(:t6, :t3)
              asm.mflo(:t6) # the last multiple of the span at or before
              asm.sw(:t6, at + NEAR_AT_OFFSET_BYTES, :gp)
              asm.jal("rt_face_place") { asm.move(:a0, :t6) }
              asm.sw(:v0, at + NEAR_U_OFFSET_BYTES, :gp)
              asm.sw(:a0, at + NEAR_V_OFFSET_BYTES, :gp)
              asm.label("rt_face_row_span")
              # The far place: a span on, or the row's end.
              asm.lw(:t6, at + NEAR_AT_OFFSET_BYTES, :gp)
              asm.lw(:t3, at + SPANS_OFFSET_BYTES, :gp)
              asm.lw(:t7, at + ROW_COUNT_OFFSET_BYTES, :gp)
              asm.addu(:t8, :t6, :t3)
              asm.slt(:t9, :t8, :t7)
              asm.bne(:t9, :zero, "rt_face_row_far")
              asm.label("rt_face_row_far_end")
              asm.move(:t8, :t7)
              asm.label("rt_face_row_far")
              asm.sw(:t8, at + FAR_AT_OFFSET_BYTES, :gp)
              asm.jal("rt_face_place") { asm.move(:a0, :t8) }
              # The steps between: what each changes by from the near place to the far, over the pixels
              # between; and the far place kept as the next span's near one.
              asm.lw(:t6, at + NEAR_AT_OFFSET_BYTES, :gp)
              asm.lw(:t8, at + FAR_AT_OFFSET_BYTES, :gp)
              asm.lw(:t0, at + NEAR_U_OFFSET_BYTES, :gp)
              asm.lw(:t1, at + NEAR_V_OFFSET_BYTES, :gp)
              asm.subu(:t7, :t8, :t6) # pixels between
              asm.subu(:t2, :v0, :t0)
              asm.subu(:t3, :a0, :t1)
              asm.sw(:v0, at + NEAR_U_OFFSET_BYTES, :gp)
              asm.sw(:a0, at + NEAR_V_OFFSET_BYTES, :gp)
              asm.sw(:t8, at + NEAR_AT_OFFSET_BYTES, :gp)
              emit_divide_by_pixels(asm, :s5, :t2, :t7, "rt_face_row_across")
              emit_divide_by_pixels(asm, :s6, :t3, :t7, "rt_face_row_down")
              # The place at this pixel: the near place stepped on to it.
              asm.lw(:t5, at + START_OFFSET_BYTES, :gp)
              asm.subu(:t4, :s1, :t5)
              asm.subu(:t4, :t4, :t6)
              asm.mult(:s5, :t4)
              asm.mflo(:s3)
              asm.addu(:s3, :s3, :t0)
              asm.mult(:s6, :t4)
              asm.mflo(:s4)
              asm.addu(:s4, :s4, :t1)
              # Up to the far place, or the row's last pixel drawn.
              asm.addu(:s2, :t5, :t8)
              asm.lw(:t6, at + ROW_END_OFFSET_BYTES, :gp)
              asm.slt(:t7, :s2, :t6)
              asm.bne(:t7, :zero, "rt_face_row_span_end")
              asm.label("rt_face_row_span_to_end")
              asm.move(:s2, :t6)
              asm.label("rt_face_row_span_end")
              asm.jal("rt_face_run")
              asm.lw(:t6, at + ROW_END_OFFSET_BYTES, :gp)
              asm.bne(:s1, :t6, "rt_face_row_span")

              asm.label("rt_face_row_end")
              asm.jal("rt_face_flush")
              asm.label("rt_face_row_done")
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }

              emit_face_run_routine(asm, at)
            end

            # Int32.div(+number+, +pixels+) into +into+, for a span of +pixels+ (above nought): one, eight,
            # or the few at a row's end. A divide takes the processor 36 cycles, so the two lengths a span
            # nearly always is are done without one: by one, the number itself; by eight, a shift, with
            # seven added to a number below nought first, so it rounds toward nought as the divide does.
            # Changes t9.
            def emit_divide_by_pixels(asm, into, number, pixels, tag)
              asm.addiu(:t9, pixels, -1)
              asm.bne(:t9, :zero, "#{tag}_not_one")
              asm.label("#{tag}_one")
              asm.b("#{tag}_done") { asm.move(into, number) }
              asm.label("#{tag}_not_one")
              asm.addiu(:t9, pixels, -8)
              asm.bne(:t9, :zero, "#{tag}_divide")
              asm.label("#{tag}_eight")
              asm.sra(:t9, number, 31)
              asm.andi(:t9, :t9, 7)
              asm.addu(:t9, :t9, number)
              asm.b("#{tag}_done") { asm.sra(into, :t9, 3) }
              asm.label("#{tag}_divide")
              asm.div(number, pixels)
              asm.mflo(into)
              asm.label("#{tag}_done")
            end

            # The x, u, v and w where the edge at +edge+ crosses row s0, into +into+: each where it
            # crosses its first row, stepped on as many rows (Reference::FaceEdge#at). Changes t9.
            def emit_edge_on_row(asm, edge, into)
              asm.lw(:t9, EDGE_FIRST_ROW_OFFSET_BYTES, edge)
              asm.subu(:t9, :s0, :t9)
              into.each_with_index do |register, i|
                asm.lw(register, EDGE_STEP_OFFSET_BYTES + (i * 4), edge)
                asm.mult(register, :t9)
                asm.mflo(register)
                asm.lw(:at, EDGE_AT_OFFSET_BYTES + (i * 4), edge)
                asm.addu(register, register, :at)
              end
            end

            # rt_face_run: pixels s1 up to s2 of row s0, the place on the picture starting at s3 across and
            # s4 down and stepping s5 and s6 a pixel. Each pixel is the picture's at its place, held to the
            # picture (Reference#fill_face_row): one load. A see-through pixel ends the run waiting in the
            # row's pixels (s7 is where the next goes), and the next run starts past it.
            def emit_face_run_routine(asm, at)
              asm.label("rt_face_run")
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.label("rt_face_run_pixel")
              asm.sra(:t0, :s3, 16)
              asm.and(:t0, :t0, :a2)
              asm.sra(:t1, :s4, 16)
              asm.and(:t1, :t1, :a3)
              asm.sllv(:t1, :t1, :a1)
              asm.addu(:t0, :t0, :t1)
              asm.sll(:t0, :t0, 1)
              asm.addu(:t0, :t0, :v1)
              asm.lhu(:t0, 0, :t0)
              asm.addu(:s3, :s3, :s5)
              asm.addu(:s4, :s4, :s6)
              # The pixel goes into the row's pixels either way; only one the picture draws is kept.
              asm.beq(:t0, :zero, "rt_face_run_see_through") { asm.sh(:t0, 0, :s7) }
              asm.addiu(:s7, :s7, 2)
              asm.label("rt_face_run_on")
              asm.addiu(:s1, :s1, 1)
              asm.bne(:s1, :s2, "rt_face_run_pixel")
              asm.lw(:ra, 0, :sp)
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
              asm.label("rt_face_run_see_through")
              asm.jal("rt_face_flush")
              asm.addiu(:t0, :s1, 1)
              asm.b("rt_face_run_on") { asm.sw(:t0, at + RUN_X_OFFSET_BYTES, :gp) }
            end

            # rt_face_place: a0 = how far along the row. v0 and a0 = the place on the picture there, exactly
            # (Reference#place_in_perspective): the place over the distance and one over the distance
            # stepped on from the row's left end, then the place over the distance times the distance.
            # Changes t0 to t9.
            def emit_face_place_routine(asm, at)
              asm.label("rt_face_place")
              [[:t0, 4, 0], [:t1, 8, 4], [:t2, 12, 8]].each do |register, from, step|
                asm.lw(:t3, at + STEP_OFFSET_BYTES + step, :gp)
                asm.lw(register, at + FROM_OFFSET_BYTES + from, :gp)
                asm.mult(:t3, :a0)
                asm.mflo(:t3)
                asm.addu(register, register, :t3)
              end
              # IR::Reciprocals.distance: w held to LEAST, its leading eleven bits looked up, and the
              # entry moved down by as many places as w was, less two.
              asm.slti(:t3, :t2, IR::Reciprocals::LEAST)
              asm.beq(:t3, :zero, "rt_face_place_far_enough")
              asm.label("rt_face_place_too_far")
              asm.li(:t2, IR::Reciprocals::LEAST)
              asm.label("rt_face_place_far_enough")
              # w is at least LEAST, so a quarter of it has eleven bits or more; it is moved down by 16, 8,
              # 4, 2 and 1 wherever what is left still has more than eleven, t4 counting how far.
              asm.srl(:t3, :t2, 2)
              asm.move(:t4, :zero)
              [16, 8, 4, 2, 1].each do |places|
                kept = "rt_face_place_lead#{places}"
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
              emit_mul_fix(asm, :v0, :t0, :t5, 14)
              emit_mul_fix(asm, :a0, :t1, :t5, 14)
              asm.jr(:ra)
            end

            # rt_face_flush: the run waiting in the row's pixels (from the buffer's start up to s7) copied
            # into video RAM at RUN_X_OFFSET_BYTES on row s0 of the page drawn into (GP0 A0h), and the buffer emptied.
            # The copy's three words go through the port, and its pixels by DMA, a word a block, as
            # Runtime::Paint#emit_upload sends a picture: the chip takes a copy's pixels only as fast as it
            # stores them. An odd count's last word carries one pixel, and the chip leaves its other half.
            # Changes t0 to t5 and a0.
            def emit_face_flush_routine(asm, at, memory, buffer)
              h = Console::PS1Hardware
              asm.label("rt_face_flush")
              asm.li(:t4, buffer)
              asm.subu(:t4, :s7, :t4)
              asm.beq(:t4, :zero, "rt_face_flush_none")
              asm.srl(:t4, :t4, 1) # how many pixels
              asm.addiu(:sp, :sp, -4)
              asm.sw(:ra, 0, :sp)
              asm.jal("rt_gp0_word") { asm.lui(:a0, h::GP0_COPY_TO_VRAM >> 16) }
              asm.lw(:t0, Runtime.at(memory, Paint::PAGE_Y), :gp)
              asm.lw(:t2, at + RUN_X_OFFSET_BYTES, :gp)
              asm.addu(:t0, :t0, :s0)
              asm.sll(:t0, :t0, 16)
              asm.or(:t0, :t0, :t2)
              asm.sw(:t0, h::GP0 & 0xFFFF, :t1)
              asm.lui(:t0, 1) # one line
              asm.or(:t0, :t0, :t4)
              asm.sw(:t0, h::GP0 & 0xFFFF, :t1)
              asm.li(:t0, h::GP1_DMA_DIRECTION | h::DMA_TO_GP0)
              asm.sw(:t0, h::GP1 & 0xFFFF, :t1)
              asm.li(:t0, buffer)
              asm.sw(:t0, h::DMA2_MADR & 0xFFFF, :t1)
              asm.addiu(:t4, :t4, 1)
              asm.srl(:t4, :t4, 1) # how many words
              asm.sll(:t0, :t4, 16)
              asm.ori(:t0, :t0, 1) # blocks of one word
              asm.sw(:t0, h::DMA2_BCR & 0xFFFF, :t1)
              asm.li(:t0, h::DMA2_FROM_RAM_BY_BLOCKS)
              asm.sw(:t0, h::DMA2_CHCR & 0xFFFF, :t1)
              asm.lui(:t2, h::DMA_BUSY >> 16)
              asm.label("rt_face_flush_wait")
              asm.lw(:t0, h::DMA2_CHCR & 0xFFFF, :t1)
              asm.and(:t0, :t0, :t2)
              asm.bne(:t0, :zero, "rt_face_flush_wait")
              asm.li(:t0, h::GP1_DMA_DIRECTION)
              asm.sw(:t0, h::GP1 & 0xFFFF, :t1)
              asm.lw(:ra, 0, :sp)
              asm.addiu(:sp, :sp, 4)
              asm.label("rt_face_flush_none")
              asm.li(:s7, buffer)
              asm.jr(:ra)
            end
          end
        end
      end
    end
  end
end
