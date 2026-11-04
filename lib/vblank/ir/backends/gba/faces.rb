# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # FILLING A FACE WITH ITS PICTURE (Nodes::FillFace), the part of drawing a place that is
        # a pixel at a time. Everything before it — turning each point to the viewer, cutting the
        # face at the near limit and finding where each corner lands — is ordinary statements the
        # lowering makes as it makes any (IR::PlaceDrawing); this is the one routine written by
        # hand.
        #
        # The routine does what Reference#exec_fill_face says, sum for sum, so every pixel lands
        # where the interpreter puts it:
        #
        #   - EDGES, once a face: for each edge, the first row whose middle it crosses and the
        #     row past its last, and where it crosses its first row and where on the picture that
        #     is, with how far each moves a row. One division an edge, by the shared divide
        #     routine; the rest are long multiplies kept to their middle bits.
        #   - ROWS: each edge that crosses the row gives where it crosses, worked out from its
        #     first row by a multiply. The one furthest left starts the row and the one furthest
        #     right ends it.
        #   - SPANS: the place on the picture stepped by one amount a pixel (two divisions a row,
        #     for across and for down), each pixel read from the picture.
        #
        # THE TEAR-FREE SCREEN TAKES TWO PIXELS AT A TIME. There a pixel is one byte, and video
        # memory refuses a lone byte. So a picture with no see-through pixel is drawn a pair at a
        # time, both worked out and the pair written whole (#emit_pixel_pairs); only a pixel left
        # over at either end of a row, and every pixel of a picture with see-through pixels, reads
        # its pair, puts its own half in and writes the pair back.
        #
        # THE DIRECT SCREEN IS FILLED TOO, two bytes of colour a pixel. A game draws a place only
        # on the tear-free screen (Builder#draw_place), but a program can hold a fill without a
        # place, and the conformance fixture does, on the direct screen every kind there is is
        # played on: refusing it there would leave the kind unplayed on the cartridge.
        #
        # What the routine is told travels in words of work memory (CORNER_WORDS, EDGE_WORDS and
        # PICTURE_WORDS): every value is worked out where the face is written and stored there, and
        # then the routine is called.
        class Faces
          include Console::Hardware
          include EmitterCalls

          ROUTINE = :__fill_face_routine

          MOST_CORNERS = Nodes::FillFace::MOST_CORNERS
          CORNER_FIELDS = %w[x y u v].freeze

          # ...and the fifth number of a corner, one over its distance, which only a picture in
          # perspective reads; the fields come in the corner list in this order.
          LISTED_FIELDS = (CORNER_FIELDS + %w[w]).freeze

          # The word corner +k+'s +field+ (one of LISTED_FIELDS) is handed over in.
          def self.corner_word(field, k) = :"_face_#{field}#{k}"

          # The words a fill is handed: each corner, how many there are, the edges nothing outside
          # is drawn, and the picture — where its pixels start, how far a row's number is shifted to
          # find a row, the two masks that make it repeat, the number that means see-through (one no
          # picture holds, when it has none), and 1 when it is on the direct screen.
          CORNER_WORDS = MOST_CORNERS.times.flat_map { |k| LISTED_FIELDS.map { |field| corner_word(field, k) } }.freeze
          EDGE_WORDS = %i[_face_left _face_top _face_right _face_bottom].freeze
          PICTURE_WORDS = %i[_face_picture _face_shift _face_mask_x _face_mask_y _face_clear _face_rows_shift].freeze

          # What the routine keeps of each edge (see Reference::FaceEdge), and of the row it is on.
          EDGE_FIELDS = %w[first past x u v w step_x step_u step_v step_w].freeze
          ROW_ENDS = %i[_face_left_x _face_left_u _face_left_v _face_right_x _face_right_u _face_right_v].freeze

          # The routine's own working words: how far apart a row's picture is worked out in
          # perspective (nought for never), the two tables of reciprocals, and the row, the span and
          # the stretch of it being drawn.
          WORKING_WORDS = %i[_face_corners _face_direct _face_perspective _face_reciprocals _face_distances _face_row
                             _face_rows_end _face_start _face_span_count _face_step_u _face_step_v _face_step_w
                             _face_left_w _face_right_w _face_top_w _face_bottom_w _face_row_base _face_first
                             _face_past _face_along _face_far_along _face_near_u _face_near_v _face_far_u
                             _face_far_v _face_du _face_dv _face_edge_at _face_edge_words _face_pending].freeze

          # EVERY WORD THE ROUTINE READS OR WRITES, which the lowering names before any of the game's
          # own variables (GBA#lower), so each is in reach of one instruction. A word past that reach
          # takes four, and the routine reads a word in some hundred places: left to the game's order
          # of naming, a game with many variables would make the routine too big for its room.
          def self.words
            CORNER_WORDS + EDGE_WORDS + PICTURE_WORDS + ROW_ENDS + WORKING_WORDS +
              MOST_CORNERS.times.flat_map { |k| EDGE_FIELDS.map { |field| :"_face_edge#{k}_#{field}" } }
          end

          # The number no palette number or colour is, for a picture with no see-through pixel.
          NO_CLEAR = -1

          # One picture's entry in a fill's table of pictures: the PICTURE_WORDS, a word each.
          PICTURE_ENTRY_BYTES = 4 * PICTURE_WORDS.length

          # +pictures+ answers, for a picture's name, [the picture, the number meaning see-through
          # among its palette numbers].
          def initialize(emitter:, primitives:, lowering:, divide:, framebuffer:, pictures:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @divide = divide
            @framebuffer = framebuffer
            @pictures = pictures
            @routine_iwram = nil
            @picture_tables = {}
          end

          # Does this program fill a face? Then it needs the routine, and the divide it calls.
          def self.fills_faces?(program) = program.walk.any? { |node| node.kind == :fill_face }

          # The pictures a fill reads as the game runs, which the cartridge carries whatever else
          # draws them.
          def self.pictures_filled(program) = program.walk.flat_map { |node| node.kind == :fill_face ? node.pictures : [] }.uniq

          # A place's statements: what the place's routine is told, and the call (see
          # Nodes::DrawPlace). The routine works the sums out here as it does everywhere.
          def emit_draw_place(node)
            node.children.each { |statement| @lowering.statement(statement) }
          end

          # The fill: its corners read out of their list into the routine's words, its picture's
          # entry out of the fill's table of pictures, and the routine called. A count under three
          # draws nothing, and one past MOST_CORNERS is held to it.
          def emit_fill_face(node)
            done = gensym
            @lowering.value(node.count)
            emit_number(TMP, MOST_CORNERS)
            emit(ASM.cmp_reg(ACC, TMP))
            emit(ASM.mov_reg_cond(:gt, ACC, TMP))
            emit(ASM.cmp_imm(ACC, 3))
            emit_branch(:bcond, done, cond: :lt)
            store_var(ACC, :_face_corners)
            CORNER_WORDS.each_with_index do |word, at|
              @lowering.value(Build.list_get(node.corners, Build.int(at)))
              store_var(ACC, word)
            end
            node.edges.zip(EDGE_WORDS).each do |value, word|
              @lowering.value(value)
              store_var(ACC, word)
            end
            emit_picture_entry(node)
            emit_number(ACC, @lowering.mode == :buffered ? 0 : 1)
            store_var(ACC, :_face_direct)
            emit_load_data_address(ACC, reciprocal_table)
            store_var(ACC, :_face_reciprocals)
            emit_load_data_address(ACC, distance_table)
            store_var(ACC, :_face_distances)
            @lowering.value(node.perspective)
            store_var(ACC, :_face_perspective)
            @divide.emit_call_routine_at(@routine_iwram)
            place_label(done)
          end

          # Where the routine runs in the quick memory, which TopOfQuickMemory keeps for it; nil
          # for a game that fills no face.
          def reserve_fill_face_routine(at:)
            @routine_iwram = at
          end

          # Copy the routine from the cartridge into the quick memory, once, at power-on.
          def emit_copy_fill_face_routine
            @divide.copy_routine(ROUTINE, :"#{ROUTINE}_end", @routine_iwram) if @routine_iwram
          end

          # Where the routine runs, by name, for a profile to report against.
          def fill_face_routine_addresses
            return {} unless @routine_iwram

            size = @emitter.labels.fetch(:"#{ROUTINE}_end") - @emitter.labels.fetch(ROUTINE)
            { ROUTINE => @routine_iwram...(@routine_iwram + size) }
          end

          # THE ROUTINE, made once for a game that fills a face, after the game's own code, and
          # copied into the quick memory at power-on. It reads nothing beside itself: its jumps are
          # all within it, and every number and address it uses is built an instruction at a time.
          def emit_fill_face_routine
            return unless @routine_iwram

            @emitter.refuse_open_number_table!("The routine that fills a face")
            emit(ASM.loop_forever) # entered only by a call
            place_label(ROUTINE)
            start = pos
            emit(ASM.push(4, 5, 6, 7, 8, 9, 10, 11, 14))
            emit_skip_face_outside_edges(:"#{ROUTINE}_out")
            emit_corners_in_perspective
            emit_edges
            @span_patches = []
            emit_branch(:bl, PATCH_ROUTINE)
            emit_rows
            place_label(:"#{ROUTINE}_out")
            emit(ASM.pop(4, 5, 6, 7, 8, 9, 10, 11, 15))
            emit_span_pixels_routine
            emit_divide_by_count_routine
            emit_place_in_perspective_routine
            emit_pixel_in_perspective_routine
            emit_patch_routine
            place_label(:"#{ROUTINE}_end")
            refuse_oversized_routine!(pos - start)
          end

          # The room the quick memory keeps for the routine. A variable it names is reached in one
          # or two instructions, and in up to four for a game whose variables run past what one
          # instruction reaches, so this is what it comes to with every one of them at four.
          ROUTINE_BYTES = 7_168

          def refuse_oversized_routine!(size)
            return if size <= ROUTINE_BYTES

            raise LoweringError, "The routine that fills a face came to #{size} bytes, and the quick memory keeps " \
                                 "#{ROUTINE_BYTES} for it. This is a fault in VBlank, not in the game."
          end

          private

          def edge_word(k, field) = :"_face_edge#{k}_#{field}"

          def corner_word(field, k) = self.class.corner_word(field, k)

          # THE PICTURE'S ENTRY, from a table of the fill's pictures in the cartridge: its number,
          # worked out as the game runs, held to the ends of the table, and the entry's words
          # copied to the routine's.
          def emit_picture_entry(node)
            @lowering.value(node.picture)
            emit(ASM.cmp_imm(ACC, 0))
            emit(ASM.mov_imm_cond(:lt, ACC, 0))
            emit_number(TMP, node.pictures.length - 1)
            emit(ASM.cmp_reg(ACC, TMP))
            emit(ASM.mov_reg_cond(:gt, ACC, TMP))
            emit_number(TMP, PICTURE_ENTRY_BYTES)
            emit(ASM.mul(SPARE, ACC, TMP))
            emit_load_data_address(ACC, picture_table(node.pictures))
            emit(ASM.add_reg(SPARE, SPARE, ACC))
            PICTURE_WORDS.each_with_index do |word, i|
              emit(ASM.ldr_offset(ACC, SPARE, i * 4))
              store_var(ACC, word)
            end
          end

          # The table a picture in perspective finds a distance in (IR::Reciprocals), made once.
          def distance_table
            blob = :__fill_face_distances
            @emitter.data_blobs[blob] ||= IR::Reciprocals::TABLE.pack("l<*")
            blob
          end

          # The table of reciprocals the span step reads (see #emit_span_step), made once.
          def reciprocal_table
            blob = :__fill_face_reciprocals
            @emitter.data_blobs[blob] ||= self.class.reciprocal_words.pack("L<*")
            blob
          end

          # The table of +pictures+ for the screen being drawn, one entry each, made once for each
          # list of pictures and screen.
          def picture_table(pictures)
            buffered = @lowering.mode == :buffered
            @picture_tables[[pictures, buffered]] ||= :"__fill_face_pictures_#{@picture_tables.length}".tap do |blob|
              @emitter.data_blobs[blob] = pictures.map { |name| picture_entry(name, buffered) }.flatten.pack("l<*")
              pictures.each_with_index do |name, i|
                @emitter.link_data(blob, i * PICTURE_ENTRY_BYTES, buffered ? @framebuffer.indexed_blob(name) : name)
              end
            end
          end

          # A picture's entry, its first word filled in once the cartridge is laid out. A picture
          # that names a see-through colour but has no pixel of it is drawn as one with none, which
          # is the quicker way (see #emit_pixel_pairs).
          def picture_entry(name, buffered)
            bmp, indexed_clear = @pictures.call(name)
            clear = buffered ? indexed_clear : bmp.transparent
            clear = nil unless bmp.transparent && bmp.pixels.unpack("v*").include?(bmp.transparent)
            [0, bmp.width.bit_length - 1, bmp.width - 1, bmp.height - 1, clear || NO_CLEAR, bmp.height.bit_length - 1]
          end

          # A PICTURE IN PERSPECTIVE walks u and v over the distance down the edges, not u and v
          # (Reference::FaceEdges.in_perspective): each corner's u and v times its w, down 28 bits.
          #
          #   r0 how many corners, r4 a corner's w, r6 its u or v
          def emit_corners_in_perspective
            straight = gensym
            load_var(0, :_face_perspective)
            emit(ASM.cmp_imm(0, 0))
            emit_branch(:bcond, straight, cond: :eq)
            load_var(0, :_face_corners)
            MOST_CORNERS.times do |k|
              if k >= 3
                emit(ASM.cmp_imm(0, k))
                emit_branch(:bcond, straight, cond: :le)
              end
              load_var(4, corner_word(:w, k))
              %i[u v].each do |field|
                load_var(6, corner_word(field, k))
                emit_mul_fix(6, 6, 4, 28)
                store_var(6, corner_word(field, k))
              end
            end
            place_label(straight)
          end

          # How many bytes one corner's words and one edge's words take, each set of words side by
          # side in the order Faces.words names them.
          CORNER_BYTES = 4 * LISTED_FIELDS.length
          EDGE_BYTES = 4 * EDGE_FIELDS.length

          # The byte offset of edge field +field+ from the start of an edge's words.
          def edge_offset(field) = 4 * EDGE_FIELDS.index(field.to_s)

          # Every edge, one turn of a loop each (see #emit_edge_body). The corners' words and the
          # edges' are side by side in memory (Faces.words is named first, in order), so each turn
          # reaches its corner and edge by where the first ones are; that is checked here, since a
          # different layout would read the wrong words.
          def emit_edges
            refuse_scattered_words!
            top = gensym
            finished = gensym
            emit_number(0, 0)
            store_var(0, :_face_edge_at)
            place_label(top)
            load_var(0, :_face_edge_at)
            emit(ASM.cmp_imm(0, MOST_CORNERS))
            emit_branch(:bcond, finished, cond: :ge)
            emit_edge_body
            load_var(0, :_face_edge_at)
            emit(ASM.add_imm(0, 0, 1))
            store_var(0, :_face_edge_at)
            emit_branch(:b, top)
            place_label(finished)
          end

          def refuse_scattered_words!
            corners = MOST_CORNERS.times.flat_map { |k| LISTED_FIELDS.map { |field| var_addr(corner_word(field, k)) } }
            edges = MOST_CORNERS.times.flat_map { |k| EDGE_FIELDS.map { |field| var_addr(edge_word(k, field)) } }
            return if [corners, edges].all? { |words| words.each_cons(2).all? { |one, other| other == one + 4 } }

            raise LoweringError, "The words of the routine that fills a face are not side by side. This is a fault " \
                                 "in VBlank, not in the game."
          end

          # The edge whose number is in the edge-at word, from that corner to the next (the first,
          # after the last), its numbers kept in its EDGE_FIELDS words. An edge past the face's
          # corners crosses no row. r4-r7 hold one end's x, y, u and v, and r8-r11 the other's; the
          # upper end comes first. r2 is the corner's words, r3 the next corner's, and r3 again
          # the edge's words wherever one is written.
          def emit_edge_body
            level = gensym
            done = gensym
            ordered = gensym
            wrapped = gensym
            load_var(0, :_face_edge_at)
            emit_number(1, EDGE_BYTES)
            emit(ASM.mul(2, 0, 1))
            emit_number(3, var_addr(edge_word(0, :first)))
            emit(ASM.add_reg(2, 2, 3))
            store_var(2, :_face_edge_words)
            load_var(1, :_face_corners)
            emit(ASM.cmp_reg(0, 1))
            emit_branch(:bcond, level, cond: :ge)
            emit_number(3, CORNER_BYTES)
            emit(ASM.mul(2, 0, 3))
            emit_number(3, var_addr(corner_word(:x, 0)))
            emit(ASM.add_reg(2, 2, 3))
            emit(ASM.add_imm(3, 2, CORNER_BYTES))
            emit(ASM.add_imm(0, 0, 1))
            emit(ASM.cmp_reg(0, 1))
            emit_branch(:bcond, wrapped, cond: :ne)
            emit_number(3, var_addr(corner_word(:x, 0))) # the last corner's edge ends at the first
            place_label(wrapped)
            4.times do |i|
              emit(ASM.ldr_offset(4 + i, 2, 4 * i))
              emit(ASM.ldr_offset(8 + i, 3, 4 * i))
            end
            emit(ASM.ldr_offset(1, 2, 16))
            store_var(1, :_face_top_w)
            emit(ASM.ldr_offset(1, 3, 16))
            store_var(1, :_face_bottom_w)
            emit(ASM.cmp_reg(5, 9))
            emit_branch(:bcond, level, cond: :eq)
            emit_branch(:bcond, ordered, cond: :lt)
            4.times do |i| # the lower end came first: swap the two ends
              emit(ASM.mov_reg(0, 4 + i))
              emit(ASM.mov_reg(4 + i, 8 + i))
              emit(ASM.mov_reg(8 + i, 0))
            end
            load_var(0, :_face_top_w) # ...and the two ends' w
            load_var(1, :_face_bottom_w)
            store_var(1, :_face_top_w)
            store_var(0, :_face_bottom_w)
            place_label(ordered)

            emit_row_of(0, 5) # the first row whose middle it crosses...
            emit_row_of(1, 9) # ...and the row past its last
            load_var(3, :_face_edge_words)
            emit(ASM.str_offset(0, 3, edge_offset(:first)))
            emit(ASM.str_offset(1, 3, edge_offset(:past)))
            emit(ASM.cmp_reg(0, 1))
            emit_branch(:bcond, level, cond: :ge) # it crosses no row's middle

            # How far one row is along it: 2**28 over its height, held as 24 fraction bits.
            emit(ASM.sub_reg(0, 9, 5))
            emit_number(1, 1 << 28)
            emit_call_divide_routine
            emit(ASM.mov_reg(9, 0))

            # How far its first row's middle is along it.
            load_var(3, :_face_edge_words)
            emit(ASM.ldr_offset(0, 3, edge_offset(:first)))
            emit(ASM.lsl_imm(0, 0, 4))
            emit(ASM.add_imm(0, 0, 8))
            emit(ASM.sub_reg(0, 0, 5))
            emit_mul_fix(5, 0, 9, 4)

            emit(ASM.sub_reg(8, 8, 4))
            emit(ASM.lsl_imm(8, 8, 12)) # across, in pixels with sixteen fraction bits
            emit(ASM.lsl_imm(4, 4, 12))
            emit(ASM.sub_reg(10, 10, 6))
            emit(ASM.sub_reg(11, 11, 7))
            load_var(3, :_face_edge_words)
            [[4, 8, :x, :step_x], [6, 10, :u, :step_u], [7, 11, :v, :step_v]].each do |start, part, at, step|
              emit_mul_fix(0, part, 5, 24)
              emit(ASM.add_reg(0, start, 0))
              emit(ASM.str_offset(0, 3, edge_offset(at)))
              emit_mul_fix(0, part, 9, 24)
              emit(ASM.str_offset(0, 3, edge_offset(step)))
            end
            load_var(0, :_face_perspective) # w only matters in perspective
            emit(ASM.cmp_imm(0, 0))
            emit_branch(:bcond, done, cond: :eq)
            load_var(6, :_face_top_w)
            load_var(10, :_face_bottom_w)
            emit(ASM.sub_reg(10, 10, 6))
            emit_mul_fix(0, 10, 5, 24)
            emit(ASM.add_reg(0, 6, 0))
            emit(ASM.str_offset(0, 3, edge_offset(:w)))
            emit_mul_fix(0, 10, 9, 24)
            emit(ASM.str_offset(0, 3, edge_offset(:step_w)))
            emit_branch(:b, done)

            place_label(level)
            load_var(3, :_face_edge_words)
            emit_number(0, 0)
            emit(ASM.str_offset(0, 3, edge_offset(:first)))
            emit(ASM.str_offset(0, 3, edge_offset(:past)))
            place_label(done)
          end

          # A FACE WHOLLY PAST ONE EDGE OF WHAT MAY BE DRAWN draws nothing, and is left at once,
          # before its edges are worked out: a division each. A face beside the view, or behind a
          # doorway's window, is most of the faces of a place seen from inside.
          #
          # Its rows are the ones whose middles its corners' heights span, so a face whose lowest
          # corner's row is above the top, or whose highest is at or below the bottom, has none.
          # Across, where a row starts and ends is worked out along an edge, and can come out a
          # pixel either way of where the corner itself lands, so the test across leaves a pixel to
          # spare: a face it keeps may still draw nothing, and the rows find that out as before.
          #
          #   r4 the least across, r5 the most, r6 the least down, r7 the most; r0 how many corners
          def emit_skip_face_outside_edges(out)
            load_var(0, :_face_corners)
            load_var(4, corner_word(:x, 0))
            emit(ASM.mov_reg(5, 4))
            load_var(6, corner_word(:y, 0))
            emit(ASM.mov_reg(7, 6))
            (1...MOST_CORNERS).each do |k|
              past = gensym
              if k >= 3
                emit(ASM.cmp_imm(0, k))
                emit_branch(:bcond, past, cond: :le)
              end
              load_var(1, corner_word(:x, k))
              emit(ASM.cmp_reg(1, 4))
              emit(ASM.mov_reg_cond(:lt, 4, 1))
              emit(ASM.cmp_reg(1, 5))
              emit(ASM.mov_reg_cond(:gt, 5, 1))
              load_var(1, corner_word(:y, k))
              emit(ASM.cmp_reg(1, 6))
              emit(ASM.mov_reg_cond(:lt, 6, 1))
              emit(ASM.cmp_reg(1, 7))
              emit(ASM.mov_reg_cond(:gt, 7, 1))
              place_label(past)
            end
            [4, 5, 6, 7].each { |reg| emit_row_of(reg, reg) } # each as the pixel its middle reaches

            emit_edge_bound(1, :_face_left, 0, :at_least)
            emit(ASM.cmp_reg(5, 1))
            emit_branch(:bcond, out, cond: :lt)
            emit_edge_bound(1, :_face_right, SCREEN_WIDTH, :at_most)
            emit(ASM.cmp_reg(4, 1))
            emit_branch(:bcond, out, cond: :gt)
            emit_edge_bound(1, :_face_top, 0, :at_least)
            emit(ASM.cmp_reg(7, 1))
            emit_branch(:bcond, out, cond: :le)
            emit_edge_bound(1, :_face_bottom, SCREEN_HEIGHT, :at_most)
            emit(ASM.cmp_reg(6, 1))
            emit_branch(:bcond, out, cond: :ge)
          end

          # +reg+ = the edge in word +edge+, held to at least or at most +screen+ (r0 is spare, so
          # the corner count is read again where it is needed).
          def emit_edge_bound(reg, edge, screen, way)
            load_var(reg, edge)
            emit_number(0, screen)
            emit(ASM.cmp_reg(reg, 0))
            emit(ASM.mov_reg_cond(way == :at_least ? :lt : :gt, reg, 0))
          end

          # +into+ = the row whose middle is at or below the screen position in +from+ (in
          # sixteenths of a pixel): (from + 7) >> 4, the shift keeping the sign.
          def emit_row_of(into, from)
            emit(ASM.add_imm(into, from, 7))
            emit(ASM.asr_imm(into, into, 4))
          end

          # +into+ = Int32.mul_fix(+a+, +b+, +bits+): the whole product, its low 32 bits taken from
          # +bits+ up. r1 and r2 hold the product's halves, so neither is a factor.
          def emit_mul_fix(into, a, b, bits)
            emit(ASM.smull(1, 2, a, b))
            emit(ASM.lsr_imm(1, 1, bits))
            emit(ASM.orr_reg_lsl(into, 1, 2, 32 - bits))
          end

          # Every row any edge crosses, held to the edges nothing outside is drawn and to the
          # screen, each filled from its leftmost crossing to its rightmost.
          def emit_rows
            top = gensym
            next_row = gensym
            done = gensym

            # The rows any edge crosses: from the least first row to the greatest past one.
            emit_number(4, Int32::MAX)
            emit_number(5, Int32::MIN)
            MOST_CORNERS.times do |k|
              skip = gensym
              load_var(0, edge_word(k, :first))
              load_var(1, edge_word(k, :past))
              emit(ASM.cmp_reg(0, 1))
              emit_branch(:bcond, skip, cond: :ge)
              emit(ASM.cmp_reg(0, 4))
              emit(ASM.mov_reg_cond(:lt, 4, 0))
              emit(ASM.cmp_reg(1, 5))
              emit(ASM.mov_reg_cond(:gt, 5, 1))
              place_label(skip)
            end
            emit_clamp(4, :_face_top, :at_least)
            emit_clamp(4, 0, :at_least)
            emit_clamp(5, :_face_bottom, :at_most)
            emit_clamp(5, SCREEN_HEIGHT, :at_most)
            store_var(4, :_face_row)
            store_var(5, :_face_rows_end)

            place_label(top)
            load_var(4, :_face_row)
            load_var(0, :_face_rows_end)
            emit(ASM.cmp_reg(4, 0))
            emit_branch(:bcond, done, cond: :ge)
            emit_row_ends(next_row)
            emit_span(next_row)
            place_label(next_row)
            load_var(4, :_face_row)
            emit(ASM.add_imm(4, 4, 1))
            store_var(4, :_face_row)
            emit_branch(:b, top)
            place_label(done)
          end

          # +reg+ held to at least (+:at_least+) or at most (+:at_most+) +bound+: a word of memory,
          # or a number. r0 is spare.
          def emit_clamp(reg, bound, way)
            bound.is_a?(Symbol) ? load_var(0, bound) : emit_number(0, bound)
            emit(ASM.cmp_reg(reg, 0))
            emit(ASM.mov_reg_cond(way == :at_least ? :lt : :gt, reg, 0))
          end

          # Where the row in r4 starts and ends: of the edges crossing it, the one furthest left
          # (the first such) and the one furthest right (the last such), each its x, u and v,
          # kept in ROW_ENDS, and its w in the left-w and right-w words. Fewer than two edges
          # crossing it, and it is skipped.
          #
          #   r6 how many cross; r7-r9 the leftmost's x, u, v; r10, r11, lr the rightmost's;
          #   r0 the crossing's w
          def emit_row_ends(next_row)
            emit_number(6, 0)
            emit_number(7, Int32::MAX)
            emit_number(10, Int32::MIN)
            MOST_CORNERS.times do |k|
              skip = gensym
              not_left = gensym
              not_right = gensym
              load_var(0, edge_word(k, :first))
              emit(ASM.cmp_reg(4, 0))
              emit_branch(:bcond, skip, cond: :lt)
              load_var(1, edge_word(k, :past))
              emit(ASM.cmp_reg(4, 1))
              emit_branch(:bcond, skip, cond: :ge)
              emit(ASM.sub_reg(0, 4, 0)) # rows since its first
              emit_crossing(k, 1, :x, :step_x)
              emit_crossing(k, 2, :u, :step_u)
              emit_crossing(k, 3, :v, :step_v)
              emit_crossing(k, 0, :w, :step_w) # last: it takes the place of the rows
              emit(ASM.add_imm(6, 6, 1))
              emit(ASM.cmp_reg(1, 7))
              emit_branch(:bcond, not_left, cond: :ge)
              [[7, 1], [8, 2], [9, 3]].each { |to, from| emit(ASM.mov_reg(to, from)) }
              store_var(0, :_face_left_w)
              place_label(not_left)
              emit(ASM.cmp_reg(1, 10))
              emit_branch(:bcond, not_right, cond: :lt)
              [[10, 1], [11, 2], [14, 3]].each { |to, from| emit(ASM.mov_reg(to, from)) }
              store_var(0, :_face_right_w)
              place_label(not_right)
              place_label(skip)
            end
            emit(ASM.cmp_imm(6, 2))
            emit_branch(:bcond, next_row, cond: :lt)
            [7, 8, 9, 10, 11, 14].zip(ROW_ENDS).each { |reg, word| store_var(reg, word) }
          end

          # +into+ = edge +k+'s +at+ moved +step+ for each row in r0. r5 is spare.
          def emit_crossing(k, into, at, step)
            load_var(5, edge_word(k, step))
            emit(ASM.mul(into, 5, 0))
            load_var(5, edge_word(k, at))
            emit(ASM.add_reg(into, 5, into))
          end

          # The row's pixels: the ones whose middles lie between its two ends, held to the left
          # and right edges and the screen, each the picture's pixel at its place on the picture.
          def emit_span(next_row)
            half = (1 << 15) - 1
            emit_number(2, half)
            load_var(0, :_face_left_x)
            emit(ASM.add_reg(0, 0, 2))
            emit(ASM.asr_imm(0, 0, 16)) # the first pixel
            load_var(1, :_face_right_x)
            emit(ASM.add_reg(1, 1, 2))
            emit(ASM.asr_imm(1, 1, 16)) # the pixel past the last
            emit(ASM.sub_reg(3, 1, 0))
            emit(ASM.cmp_imm(3, 0))
            emit_branch(:bcond, next_row, cond: :le)
            store_var(0, :_face_start)
            store_var(3, :_face_span_count)
            emit(ASM.mov_reg(6, 0))
            emit(ASM.mov_reg(7, 1))

            # Held to the edges nothing outside is drawn, and to the screen.
            emit_clamp(6, :_face_left, :at_least)
            emit_clamp(6, 0, :at_least)
            emit_clamp(7, :_face_right, :at_most)
            emit_clamp(7, SCREEN_WIDTH, :at_most)
            emit(ASM.sub_reg(5, 7, 6)) # how many pixels are drawn
            emit(ASM.cmp_imm(5, 0))
            emit_branch(:bcond, next_row, cond: :le)
            store_var(6, :_face_first)
            store_var(7, :_face_past)
            emit_row_base

            in_perspective = gensym
            load_var(0, :_face_perspective)
            emit(ASM.cmp_imm(0, 0))
            emit_branch(:bcond, in_perspective, cond: :ne)

            # Without perspective the place on the picture steps evenly from the row's left end: so
            # where the first drawn pixel is, a step for each pixel it was held in by.
            emit_span_step(:_face_right_u, :_face_left_u, :_face_step_u)
            emit_span_step(:_face_right_v, :_face_left_v, :_face_step_v)
            load_var(6, :_face_first)
            load_var(0, :_face_start)
            emit(ASM.sub_reg(4, 6, 0))
            load_var(2, :_face_step_u)
            emit(ASM.mul(0, 2, 4))
            load_var(1, :_face_left_u)
            emit(ASM.add_reg(0, 1, 0))
            load_var(3, :_face_step_v)
            emit(ASM.mul(1, 3, 4))
            load_var(8, :_face_left_v)
            emit(ASM.add_reg(1, 8, 1))
            load_var(7, :_face_past)
            emit(ASM.sub_reg(5, 7, 6))
            emit_pixel_address(4, 6)
            emit_branch(:bl, SPAN_PIXELS_ROUTINE)
            emit_branch(:b, next_row)

            place_label(in_perspective)
            emit_span_in_perspective(next_row)
          end

          # Where the row being drawn starts in the screen's memory: on the hidden page of the
          # tear-free screen, a byte a pixel; on the direct screen, two.
          def emit_row_base
            direct = gensym
            done = gensym
            load_var(4, :_face_row)
            emit_number(8, SCREEN_WIDTH)
            emit(ASM.mul(9, 4, 8))
            load_var(8, :_face_direct)
            emit(ASM.cmp_imm(8, 0))
            emit_branch(:bcond, direct, cond: :ne)
            load_var(8, BACKBUF)
            emit(ASM.add_reg(9, 9, 8))
            emit_branch(:b, done)
            place_label(direct)
            emit(ASM.lsl_imm(9, 9, 1))
            emit_number(8, VRAM_START)
            emit(ASM.add_reg(9, 9, 8))
            place_label(done)
            store_var(9, :_face_row_base)
          end

          # +into+ = where pixel +across+ (a register) of the row is in the screen's memory. r8 is
          # spare.
          def emit_pixel_address(into, across)
            load_var(into, :_face_row_base)
            load_var(8, :_face_direct)
            emit(ASM.cmp_imm(8, 0))
            emit(ASM.mov_reg(8, across))
            emit(ASM.mov_reg_lsl_cond(:ne, 8, across, 1))
            emit(ASM.add_reg(into, into, 8))
          end

          # A ROW IN PERSPECTIVE (Reference#fill_face_row): the place on the picture worked out
          # exactly every so many pixels from the row's start (the perspective word: eight, or one)
          # and at its end, and stepped evenly between, one stretch at a time. Each stretch is drawn
          # by the routine that draws pixels stepping evenly, the same as a row without perspective,
          # so a stretch of a picture with no see-through pixel goes two pixels at a time.
          #
          # The along words count pixels from the row's start: first and past are the drawn part's,
          # along and far-along the stretch's two ends, near and far the place at each.
          def emit_span_in_perspective(next_row)
            stretch = gensym
            nothing = gensym
            emit_span_step(:_face_right_u, :_face_left_u, :_face_step_u)
            emit_span_step(:_face_right_v, :_face_left_v, :_face_step_v)
            emit_span_step(:_face_right_w, :_face_left_w, :_face_step_w)
            load_var(1, :_face_start)
            %i[_face_first _face_past].each do |word|
              load_var(0, word)
              emit(ASM.sub_reg(0, 0, 1))
              store_var(0, word)
            end
            load_var(0, :_face_first)
            load_var(3, :_face_perspective)
            emit(ASM.rsb_imm(3, 3, 0))
            emit(ASM.and_reg(0, 0, 3)) # the stretch the first drawn pixel is in starts here
            store_var(0, :_face_along)
            emit_branch(:bl, SAMPLE_ROUTINE)
            store_var(0, :_face_near_u)
            store_var(1, :_face_near_v)

            place_label(stretch)
            fast = gensym
            emit_branch_to_whole_stretches(fast)
            load_var(0, :_face_along)
            load_var(3, :_face_perspective)
            emit(ASM.add_reg(0, 0, 3))
            load_var(2, :_face_span_count)
            emit(ASM.cmp_reg(0, 2))
            emit(ASM.mov_reg_cond(:gt, 0, 2))
            store_var(0, :_face_far_along)
            emit_branch(:bl, SAMPLE_ROUTINE)
            store_var(0, :_face_far_u)
            store_var(1, :_face_far_v)
            [%i[_face_far_u _face_near_u _face_du], %i[_face_far_v _face_near_v _face_dv]].each do |far, near, step|
              load_var(1, far)
              load_var(2, near)
              emit(ASM.sub_reg(1, 1, 2))
              load_var(0, :_face_far_along)
              load_var(2, :_face_along)
              emit(ASM.sub_reg(0, 0, 2))
              emit_branch(:bl, DIVIDE_ROUTINE)
              store_var(0, step)
            end

            # The drawn part of the stretch: r6 its first pixel, r7 the one past its last, along.
            load_var(6, :_face_along)
            load_var(0, :_face_first)
            emit(ASM.cmp_reg(6, 0))
            emit(ASM.mov_reg_cond(:lt, 6, 0))
            load_var(7, :_face_far_along)
            load_var(0, :_face_past)
            emit(ASM.cmp_reg(7, 0))
            emit(ASM.mov_reg_cond(:gt, 7, 0))
            emit(ASM.sub_reg(5, 7, 6))
            emit(ASM.cmp_imm(5, 0))
            emit_branch(:bcond, nothing, cond: :le)
            load_var(0, :_face_along)
            emit(ASM.sub_reg(4, 6, 0)) # pixels into the stretch it starts
            load_var(2, :_face_du)
            emit(ASM.mul(0, 2, 4))
            load_var(1, :_face_near_u)
            emit(ASM.add_reg(0, 1, 0))
            load_var(3, :_face_dv)
            emit(ASM.mul(1, 3, 4))
            load_var(8, :_face_near_v)
            emit(ASM.add_reg(1, 8, 1))
            load_var(8, :_face_start)
            emit(ASM.add_reg(6, 6, 8)) # the pixel across the screen
            emit_pixel_address(4, 6)
            emit_branch(:bl, SPAN_PIXELS_ROUTINE)

            place_label(nothing)
            load_var(0, :_face_far_along)
            store_var(0, :_face_along)
            load_var(0, :_face_far_u)
            store_var(0, :_face_near_u)
            load_var(0, :_face_far_v)
            store_var(0, :_face_near_v)
            load_var(0, :_face_along)
            load_var(1, :_face_past)
            emit(ASM.cmp_reg(0, 1))
            emit_branch(:bcond, stretch, cond: :lt)
            emit_branch(:b, next_row)
            emit_whole_stretches(fast, stretch)
            emit_every_pixel_run(:"#{fast}_every_pixel", next_row)
          end

          # The words the run of whole stretches keeps: u, v and w over the distance at the
          # stretch's start, each one's step over a whole stretch, how far the run goes, and how far
          # u and v are moved up for the picture's repeat (see #emit_pixel_pairs).
          WHOLE_STRETCH_WORDS = %i[_face_over_u _face_over_v _face_over_w _face_stretch_u _face_stretch_v
                                   _face_stretch_w _face_run_end _face_moved_u _face_moved_v].freeze

          # The pixels a whole stretch covers, worked out exactly at its ends: eight.
          STRETCH = 8

          # On to +fast+ when the stretch about to be drawn starts a run of WHOLE STRETCHES: eight
          # pixels in perspective, all of them drawn, of a picture with no see-through pixel, on the
          # tear-free screen. Those take a loop of their own (#emit_whole_stretches).
          #
          #   r0 where the stretch starts, along; r2 where the run must end
          def emit_branch_to_whole_stretches(fast)
            not_whole = gensym
            load_var(0, :_face_along)
            load_var(1, :_face_first)
            emit(ASM.cmp_reg(0, 1))
            emit_branch(:bcond, not_whole, cond: :lt)
            load_var(2, :_face_past)
            load_var(3, :_face_span_count)
            emit(ASM.cmp_reg(2, 3))
            emit(ASM.mov_reg_cond(:gt, 2, 3))
            emit(ASM.add_imm(1, 0, STRETCH))
            emit(ASM.cmp_reg(1, 2))
            emit_branch(:bcond, not_whole, cond: :gt)
            load_var(3, :_face_direct)
            emit(ASM.cmp_imm(3, 0))
            emit_branch(:bcond, not_whole, cond: :ne)
            load_var(3, :_face_clear)
            emit(ASM.add_imm(3, 3, 1)) # NO_CLEAR is -1
            emit(ASM.cmp_imm(3, 0))
            emit_branch(:bcond, not_whole, cond: :ne)
            load_var(3, :_face_perspective)
            emit(ASM.cmp_imm(3, 1))
            emit_branch(:bcond, :"#{fast}_every_pixel", cond: :eq)
            emit(ASM.cmp_imm(3, STRETCH))
            emit_branch(:bcond, fast, cond: :eq)
            place_label(not_whole)
          end

          # EVERY PIXEL IN PERSPECTIVE, the whole drawn part of the row in one loop: each pixel's
          # place worked out exactly from u, v and w over the distance, which step a pixel at a time
          # in r0-r2, and the pixels written a pair at a time, a pixel at either end on its own.
          # Then on to +next_row+.
          #
          #   r4 where the pixel is in the screen's memory, r6-r9 the picture, lr and r3 a pair
          def emit_every_pixel_run(start, next_row)
            even = gensym
            pairs = gensym
            tail = gensym
            place_label(start)
            load_var(5, :_face_first)
            [[0, :_face_step_u, :_face_left_u], [1, :_face_step_v, :_face_left_v],
             [2, :_face_step_w, :_face_left_w]].each do |into, step, left|
              load_var(3, step)
              emit(ASM.mul(into, 3, 5))
              load_var(3, left)
              emit(ASM.add_reg(into, 3, into))
            end
            load_var(3, :_face_past)
            emit(ASM.sub_reg(3, 3, 5))
            store_var(3, :_face_run_end) # how many pixels
            load_var(3, :_face_start)
            emit(ASM.add_reg(5, 5, 3))
            emit_pixel_address(4, 5)
            emit_load_picture
            emit(ASM.tst_imm(4, 1))
            emit_branch(:bcond, even, cond: :eq)
            emit_branch(:bl, PIXEL_IN_PERSPECTIVE_ROUTINE)
            emit(ASM.bic_imm(5, 4, 1))
            emit(ASM.load_halfword(14, 5))
            emit(ASM.and_imm(14, 14, 0xFF))
            emit(ASM.orr_reg_lsl(14, 14, 3, 8))
            emit(ASM.store_halfword(14, 5))
            emit(ASM.add_imm(4, 4, 1))
            emit_run_pixels_less(1)
            place_label(even)
            place_label(pairs)
            load_var(5, :_face_run_end)
            emit(ASM.cmp_imm(5, 2))
            emit_branch(:bcond, tail, cond: :lt)
            emit_branch(:bl, PIXEL_IN_PERSPECTIVE_ROUTINE)
            store_var(3, :_face_pending)
            emit_branch(:bl, PIXEL_IN_PERSPECTIVE_ROUTINE)
            load_var(14, :_face_pending)
            emit(ASM.orr_reg_lsl(14, 14, 3, 8))
            emit(ASM.store_halfword_post(14, 4, 2))
            emit_run_pixels_less(2)
            emit_branch(:b, pairs)
            place_label(tail)
            emit(ASM.cmp_imm(5, 0))
            emit_branch(:bcond, next_row, cond: :eq)
            emit_branch(:bl, PIXEL_IN_PERSPECTIVE_ROUTINE)
            emit(ASM.load_halfword(14, 4))
            emit(ASM.and_imm(14, 14, 0xFF00))
            emit(ASM.orr_reg(14, 14, 3))
            emit(ASM.store_halfword(14, 4))
            emit_branch(:b, next_row)
          end

          PIXEL_IN_PERSPECTIVE_ROUTINE = :"#{ROUTINE}_pixel_in_perspective".freeze

          def emit_run_pixels_less(count)
            load_var(5, :_face_run_end)
            emit(ASM.sub_imm(5, 5, count))
            store_var(5, :_face_run_end)
          end

          # r3 = the picture's pixel at u, v and w over the distance in r0-r2, which then step a
          # pixel on (Reference#place_in_perspective, and the texel as #emit_picture_place finds it).
          # Called with its return in lr; r5 and r10-r12 are spare.
          def emit_pixel_in_perspective_routine
            place_label(PIXEL_IN_PERSPECTIVE_ROUTINE)
            into = 3
            emit(ASM.mov_reg(3, 2))
            emit_distance(3, 10, 11)
            emit(ASM.smull(10, 11, 0, 3))
            emit(ASM.lsr_imm(10, 10, 14))
            emit(ASM.orr_reg_lsl(10, 10, 11, 18)) # u
            emit(ASM.smull(11, 12, 1, 3))
            emit(ASM.lsr_imm(11, 11, 14))
            emit(ASM.orr_reg_lsl(11, 11, 12, 18)) # v
            emit(ASM.asr_imm(12, 11, 16))
            emit(ASM.and_reg(12, 12, 8))
            emit(ASM.mov_reg_lsl_reg(12, 12, 9))
            emit(ASM.asr_imm(11, 10, 16))
            emit(ASM.and_reg(11, 11, 7))
            emit(ASM.orr_reg(12, 12, 11))
            emit(ASM.ldrb_reg(into, 6, 12))
            [[0, :_face_step_u], [1, :_face_step_v], [2, :_face_step_w]].each do |over, step|
              load_var(5, step)
              emit(ASM.add_reg(over, over, 5))
            end
            emit(ASM.bx(14))
          end

          # A RUN OF WHOLE STRETCHES, from the stretch whose start is in the along word for as long
          # as each is eight pixels all drawn, then back to +general+ for whatever is left of the
          # row. Each stretch's far end is worked out exactly and the eight pixels stepped evenly
          # from the near end, two at a time, as #emit_pixel_pairs does, the pairs written whole.
          #
          # A stretch need not start on a pair: one that starts on the right half of a pair keeps
          # its last pixel back, and the next stretch's first pixel makes up a pair with it. The
          # first such pixel's other half, before the run, and the last kept back, after it, are
          # read and written back with the half beside them.
          #
          #   r8, r9 u and v at the stretch's start; r4 where it is in the screen's memory; r6 the
          #   picture; r7 the pixel kept back; r0-r3, r5, r10-r12 and lr the sums
          def emit_whole_stretches(fast, general)
            even = gensym
            odd = gensym
            done = gensym
            place_label(fast)
            store_var(2, :_face_run_end)
            [%i[_face_over_u _face_left_u _face_step_u _face_stretch_u],
             %i[_face_over_v _face_left_v _face_step_v _face_stretch_v],
             %i[_face_over_w _face_left_w _face_step_w _face_stretch_w]].each do |over, left, step, stretch|
              load_var(1, step)
              emit(ASM.mul(3, 1, 0))
              load_var(2, left)
              emit(ASM.add_reg(3, 2, 3))
              store_var(3, over)
              emit(ASM.lsl_imm(1, 1, 3)) # eight steps
              store_var(1, stretch)
            end
            load_var(1, :_face_shift)
            emit(ASM.rsb_imm(1, 1, 16))
            store_var(1, :_face_moved_u)
            load_var(1, :_face_rows_shift)
            emit(ASM.rsb_imm(1, 1, 16))
            store_var(1, :_face_moved_v)
            load_var(6, :_face_picture)
            load_var(1, :_face_start)
            emit(ASM.add_reg(5, 0, 1))
            emit_pixel_address(4, 5)
            load_var(8, :_face_near_u)
            load_var(9, :_face_near_v)
            emit(ASM.tst_imm(4, 1))
            emit_branch(:bcond, even, cond: :eq)
            emit(ASM.sub_imm(4, 4, 1)) # the pair it starts the right half of
            emit(ASM.load_halfword(7, 4))
            emit(ASM.and_imm(7, 7, 0xFF))
            emit_branch(:b, odd)

            place_label(even)
            emit_whole_stretch(:even)
            emit_branch_to_next_stretch(even)
            emit_branch(:b, done)

            place_label(odd)
            emit_whole_stretch(:odd)
            emit_branch_to_next_stretch(odd)
            emit(ASM.load_halfword(14, 4)) # the kept-back pixel, with the half beside it
            emit(ASM.and_imm(14, 14, 0xFF00))
            emit(ASM.orr_reg(14, 14, 7))
            emit(ASM.store_halfword(14, 4))

            place_label(done)
            store_var(8, :_face_near_u)
            store_var(9, :_face_near_v)
            emit_branch(:b, general)
          end

          # One whole stretch: its far end's u and v exactly, the steps between, and its eight
          # pixels, starting on a pair (+parity+ :even) or on a pair's right half (:odd).
          def emit_whole_stretch(parity)
            [[0, :_face_over_u, :_face_stretch_u], [2, :_face_over_v, :_face_stretch_v],
             [3, :_face_over_w, :_face_stretch_w]].each do |into, over, stretch|
              load_var(into, over)
              load_var(1, stretch)
              emit(ASM.add_reg(into, into, 1))
              store_var(into, over)
            end
            emit_distance(3, 5, 1) # r3 the far end's distance
            emit(ASM.smull(10, 11, 0, 3))
            emit(ASM.lsr_imm(10, 10, 14))
            emit(ASM.orr_reg_lsl(0, 10, 11, 18)) # u at the far end
            emit(ASM.smull(10, 11, 2, 3))
            emit(ASM.lsr_imm(10, 10, 14))
            emit(ASM.orr_reg_lsl(2, 10, 11, 18)) # v at the far end
            store_var(0, :_face_far_u)
            store_var(2, :_face_far_v)
            emit_eighth(10, 0, 8) # the step across
            emit_eighth(11, 2, 9) # the step down
            load_var(5, :_face_moved_u)
            emit(ASM.mov_reg_lsl_reg(0, 8, 5))
            emit(ASM.mov_reg_lsl_reg(2, 10, 5))
            load_var(5, :_face_moved_v)
            emit(ASM.mov_reg_lsl_reg(1, 9, 5))
            emit(ASM.mov_reg_lsl_reg(3, 11, 5))
            if parity == :even
              4.times { emit_pair }
            else
              emit_pair_pixel(14)
              emit(ASM.orr_reg_lsl(11, 7, 14, 8))
              emit(ASM.store_halfword_post(11, 4, 2))
              3.times { emit_pair }
              emit_pair_pixel(7)
            end
            load_var(8, :_face_far_u)
            load_var(9, :_face_far_v)
          end

          # On to +top+ for the next whole stretch while one is left in the run.
          def emit_branch_to_next_stretch(top)
            load_var(0, :_face_along)
            emit(ASM.add_imm(0, 0, STRETCH))
            store_var(0, :_face_along)
            load_var(2, :_face_run_end)
            emit(ASM.add_imm(1, 0, STRETCH))
            emit(ASM.cmp_reg(1, 2))
            emit_branch(:bcond, top, cond: :le)
          end

          # +into+ = (+far+ - +near+) / 8, truncated toward nought as Int32.div does: a shift down,
          # after adding seven to a number below nought.
          def emit_eighth(into, far, near)
            emit(ASM.sub_reg(into, far, near))
            emit(ASM.asr_imm(1, into, 31))
            emit(ASM.add_reg_lsr(into, into, 1, 29))
            emit(ASM.asr_imm(into, into, 3))
          end

          # +reg+ = the distance for one over it in +reg+ (IR::Reciprocals.distance): held to the
          # least, its leading eleven bits found by halving the shift five times (+moved+ counts it),
          # and the table's entry for them moved back down. +spare+ is a spare register.
          def emit_distance(reg, moved, spare)
            emit_number(spare, IR::Reciprocals::LEAST)
            emit(ASM.cmp_reg(reg, spare))
            emit(ASM.mov_reg_cond(:lt, reg, spare))
            emit_number(moved, 0)
            [16, 8, 4, 2, 1].each do |shift|
              emit_number(spare, 1 << (10 + shift))
              emit(ASM.cmp_reg(reg, spare))
              emit_if(:ge, ASM.lsr_imm(reg, reg, shift))
              emit(ASM.add_imm_cond(:ge, moved, moved, shift))
            end
            load_var(spare, :_face_distances)
            emit(ASM.sub_imm(reg, reg, IR::Reciprocals::LEADING))
            emit(ASM.ldr_reg_lsl(reg, spare, reg, 2))
            emit(ASM.sub_imm(moved, moved, 2))
            emit(ASM.mov_reg_lsr_reg(reg, reg, moved))
          end

          SPAN_PIXELS_ROUTINE = :"#{ROUTINE}_span_pixels".freeze
          SAMPLE_ROUTINE = :"#{ROUTINE}_place_in_perspective".freeze
          DIVIDE_ROUTINE = :"#{ROUTINE}_divide_by_count".freeze

          # THE PIXELS OF A STRETCH OF A ROW, stepping evenly: r0 u, r1 v, r2 the step across, r3
          # the step down, r4 where the first is in the screen's memory, r5 how many (one or more).
          # Called with its return in lr; uses every register but the stack.
          def emit_span_pixels_routine
            direct = gensym
            done = gensym
            place_label(SPAN_PIXELS_ROUTINE)
            emit(ASM.push(14))
            load_var(11, :_face_direct)
            emit_load_picture
            emit(ASM.cmp_imm(11, 0))
            emit_branch(:bcond, direct, cond: :ne)
            emit_pixels
            emit_branch(:b, done)
            place_label(direct)
            emit_direct_pixels
            place_label(done)
            emit(ASM.pop(15))
          end

          # WHERE ON THE PICTURE, IN PERSPECTIVE, +along+ (r0) pixels into the row
          # (Reference#place_in_perspective): u over the distance, v over it and one over it, each
          # stepped from the row's left end, and the distance found from the last in the table of
          # IR::Reciprocals (its leading eleven bits, found by halving the shift five times), which
          # times the first two gives u and v. Answers u in r0 and v in r1.
          #
          #   r6 u over the distance, r7 v over it, r4 one over it, r5 how far it was moved down
          def emit_place_in_perspective_routine
            place_label(SAMPLE_ROUTINE)
            [[6, :_face_step_u, :_face_left_u], [7, :_face_step_v, :_face_left_v],
             [4, :_face_step_w, :_face_left_w]].each do |into, step, left|
              load_var(1, step)
              emit(ASM.mul(into, 1, 0))
              load_var(1, left)
              emit(ASM.add_reg(into, 1, into))
            end
            emit_number(1, IR::Reciprocals::LEAST)
            emit(ASM.cmp_reg(4, 1))
            emit(ASM.mov_reg_cond(:lt, 4, 1))
            emit_number(5, 0)
            [16, 8, 4, 2, 1].each do |shift|
              emit_number(1, 1 << (10 + shift))
              emit(ASM.cmp_reg(4, 1))
              emit_if(:ge, ASM.lsr_imm(4, 4, shift))
              emit(ASM.add_imm_cond(:ge, 5, 5, shift))
            end
            load_var(1, :_face_distances)
            emit(ASM.sub_imm(4, 4, IR::Reciprocals::LEADING))
            emit(ASM.ldr_reg_lsl(4, 1, 4, 2))
            emit(ASM.sub_imm(5, 5, 2))
            emit(ASM.mov_reg_lsr_reg(4, 4, 5))
            emit_mul_fix(0, 6, 4, 14)
            emit_mul_fix(1, 7, 4, 14)
            emit(ASM.bx(14))
          end

          # +instruction+ made to run only under +cond+.
          def emit_if(cond, instruction)
            word = instruction.unpack1("V")
            emit([(word & 0x0FFFFFFF) | (ASM.resolve_cond(cond) << 28)].pack("V"))
          end

          # +step+ = (+right+ - +left+) divided by the row's count, truncated toward nought as
          # Int32.div does.
          def emit_span_step(right, left, step)
            load_var(1, right)
            load_var(2, left)
            emit(ASM.sub_reg(1, 1, 2))
            load_var(0, :_face_span_count)
            emit_branch(:bl, DIVIDE_ROUTINE)
            store_var(0, step)
          end

          def emit_load_picture
            load_var(6, :_face_picture)
            load_var(7, :_face_mask_x)
            load_var(8, :_face_mask_y)
            load_var(9, :_face_shift)
            load_var(10, :_face_clear)
          end

          # r0 = r1 divided by the count in r0 (one or more), truncated toward nought as Int32.div
          # does: how far a row, or a stretch of one, steps a pixel.
          #
          # A ROW IS SELDOM WIDE, so most counts are under RECIPROCALS, and for those the divide is
          # a multiply: the number's size times 2**32 / count rounded up, top half kept. Rounding up
          # makes that the true quotient or one more (the excess is the number times under one
          # 2**32th of the count, so under one), and one more is seen by multiplying back. A count
          # of one is the number itself; a wider row takes the shared divide routine.
          #
          #   r0 the count, r1 the number, r2 its size, r3 the reciprocal, r4 and r5 the product
          def emit_divide_by_count_routine
            routine = gensym
            done = gensym
            place_label(DIVIDE_ROUTINE)
            emit(ASM.push(14))
            emit(ASM.cmp_imm(0, 1))
            emit(ASM.mov_reg_cond(:eq, 0, 1))
            emit_branch(:bcond, done, cond: :eq)
            emit(ASM.cmp_imm(0, RECIPROCALS))
            emit_branch(:bcond, routine, cond: :ge)
            load_var(3, :_face_reciprocals)
            emit(ASM.ldr_reg_lsl(3, 3, 0, 2))
            emit(ASM.mov_reg(2, 1))
            emit(ASM.cmp_imm(1, 0))
            emit(ASM.rsb_imm_cond(:lt, 2, 1, 0))
            emit(ASM.umull(4, 5, 2, 3))
            emit(ASM.mul(4, 5, 0))
            emit(ASM.cmp_reg(4, 2))
            emit(ASM.sub_imm_cond(:hi, 5, 5, 1))
            emit(ASM.cmp_imm(1, 0))
            emit(ASM.rsb_imm_cond(:lt, 5, 5, 0))
            emit(ASM.mov_reg(0, 5))
            emit_branch(:b, done)
            place_label(routine)
            emit_call_divide_routine
            place_label(done)
            emit(ASM.pop(15))
          end

          # How many counts the table of reciprocals covers (see #emit_divide_by_count_routine): wider than the
          # screen, so only a row reaching well past its edges takes the divide routine.
          RECIPROCALS = 512

          # The table: for each count from two up, 2**32 divided by it, rounded up. The first two
          # entries are never read.
          def self.reciprocal_words = [0, 0] + (2...RECIPROCALS).map { |count| -(-(1 << 32) / count) }

          # +into+ = which pixel of the picture is at u (r0), v (r1): the row, from the top bits of v
          # held to the picture's height and moved up a row's width, and the pixel along it. r12 is
          # spare.
          def emit_picture_place(into)
            emit(ASM.asr_imm(into, 1, 16))
            emit(ASM.and_reg(into, into, 8))
            emit(ASM.mov_reg_lsl_reg(into, into, 9))
            emit(ASM.asr_imm(12, 0, 16))
            emit(ASM.and_reg(12, 12, 7))
            emit(ASM.orr_reg(into, into, 12))
          end

          # The pixels of a span on the tear-free screen: two at a time when the picture has no
          # see-through pixel, one at a time when it has.
          #
          #   r0 u, r1 v, r2 the step across, r3 the step down, r4 the pixel's byte on the page,
          #   r5 how many are left, r6 the picture's palette numbers, r7 and r8 the masks that
          #   make it repeat, r9 the shift to a row, r10 the see-through number, r11, r12 and lr
          #   spare
          def emit_pixels
            one_at_a_time = gensym
            done = gensym
            emit(ASM.add_imm(11, 10, 1)) # NO_CLEAR is -1
            emit(ASM.cmp_imm(11, 0))
            emit_branch(:bcond, one_at_a_time, cond: :ne)
            emit_pixel_pairs(done)
            place_label(one_at_a_time)
            emit_single_pixels
            place_label(done)
          end

          # A picture with no see-through pixel covers every pixel of the span, so two pixels side
          # by side are worked out together and written as one pair. Video memory takes nothing
          # smaller than a pair, so a pixel written alone has to read its pair, put its half in and
          # write it back: three trips to video memory for every pixel, against one for two.
          #
          # WHERE ON THE PICTURE, IN FEWER STEPS. The picture repeats, so of u only its whole part
          # held to the picture's width matters ((u >> 16) & (width - 1)), and that is bits 16 up to
          # 16 + log2(width) of u. Moved up to the top of the word (u << (16 - log2 width)) they are
          # the word's top bits: one shift down reads them, held to the width for nothing, because
          # whatever was above them has fallen off the top. Adding the step moved up the same way
          # keeps them exactly the bits adding the plain step would have made. So is v. A pixel is
          # then two instructions and a load: add the pixel across to the picture's start, take the
          # row from v, and load from the start plus the row moved up a row's width.
          #
          # THOSE SHIFTS ARE THE PICTURE'S, AND THIS CODE RUNS IN WORK MEMORY. An instruction's shift
          # is a number inside it, and the picture is only known as the game runs, so before the
          # rows the routine writes the picture's three shifts into the loop's own instructions
          # (#emit_patch_routine). That is what the routine being copied into the quick memory
          # allows: the cartridge cannot be written, and the quick memory can. The other way, a
          # shift held in a register, costs a cycle more each time, three a pixel.
          #
          #   r7 the pairs left; r8 log2 of the picture's height; r11, r12 and lr the two pixels and a row
          def emit_pixel_pairs(done)
            pairs = gensym
            even = gensym
            tail = gensym
            load_var(8, :_face_rows_shift)
            emit(ASM.rsb_imm(11, 9, 16)) # u and its step moved up 16 - log2 width...
            emit(ASM.mov_reg_lsl_reg(0, 0, 11))
            emit(ASM.mov_reg_lsl_reg(2, 2, 11))
            emit(ASM.rsb_imm(11, 8, 16)) # ...and v and its step 16 - log2 height
            emit(ASM.mov_reg_lsl_reg(1, 1, 11))
            emit(ASM.mov_reg_lsl_reg(3, 3, 11))

            # A span starting on the right half of a pair: that pixel on its own.
            emit(ASM.tst_imm(4, 1))
            emit_branch(:bcond, even, cond: :eq)
            emit_lone_pixel(:high)
            emit(ASM.subs_imm(5, 5, 1))
            emit_branch(:bcond, done, cond: :eq)
            place_label(even)

            # The pairs, two to a turn of the loop, so the loop's own count and jump are paid once
            # for four pixels. An odd number of pairs starts at the second of the two.
            second = gensym
            emit(ASM.lsr_imm(7, 5, 1)) # how many pairs
            emit(ASM.cmp_imm(7, 0))
            emit_branch(:bcond, tail, cond: :eq)
            emit(ASM.add_imm(7, 7, 1))
            emit(ASM.tst_imm(7, 1)) # an odd number of pairs leaves (pairs + 1) even
            emit(ASM.lsr_imm(7, 7, 1))
            emit_branch(:bcond, second, cond: :eq)
            place_label(pairs)
            emit_pair
            place_label(second)
            emit_pair
            emit(ASM.subs_imm(7, 7, 1))
            emit_branch(:bcond, pairs, cond: :ne)

            # A span ending on the left half of a pair: that pixel on its own.
            place_label(tail)
            emit(ASM.tst_imm(5, 1))
            emit_branch(:bcond, done, cond: :eq)
            emit_lone_pixel(:low)
            emit_branch(:b, done)
          end

          # Two pixels side by side, written as their pair, and the pair after it next.
          def emit_pair
            emit_pair_pixel(11)
            emit_pair_pixel(14)
            emit(ASM.orr_reg_lsl(11, 11, 14, 8))
            emit(ASM.store_halfword_post(11, 4, 2))
          end

          # One pixel of a pair into +into+, and u and v a step on. Its three shifts are written in
          # as the routine starts, so each is emitted as nought and its place noted.
          def emit_pair_pixel(into)
            @span_patches << [pos, :across]
            emit(ASM.add_reg_lsr(into, 6, 0, 0))
            @span_patches << [pos, :down]
            emit(ASM.lsr_imm(12, 1, 32))
            @span_patches << [pos, :row]
            emit(ASM.ldrb_reg_lsl(into, into, 12, 0))
            emit(ASM.add_reg(0, 0, 2))
            emit(ASM.add_reg(1, 1, 3))
          end

          # One pixel alone, the +half+ (:low or :high) of its pair, put in with what the other
          # half holds. Its shifts are held in registers: it is once a row at most.
          def emit_lone_pixel(half)
            emit(ASM.rsb_imm(12, 9, 32))
            emit(ASM.mov_reg_lsr_reg(11, 0, 12)) # across
            emit(ASM.rsb_imm(12, 8, 32))
            emit(ASM.mov_reg_lsr_reg(12, 1, 12)) # down
            emit(ASM.mov_reg_lsl_reg(12, 12, 9))
            emit(ASM.add_reg(11, 11, 12))
            emit(ASM.ldrb_reg(11, 6, 11))
            emit(ASM.bic_imm(12, 4, 1))
            emit(ASM.load_halfword(14, 12))
            if half == :high
              emit(ASM.and_imm(14, 14, 0xFF))
              emit(ASM.orr_reg_lsl(14, 14, 11, 8))
            else
              emit(ASM.and_imm(14, 14, 0xFF00))
              emit(ASM.orr_reg(14, 14, 11))
            end
            emit(ASM.store_halfword(14, 12))
            emit(ASM.add_reg(0, 0, 2))
            emit(ASM.add_reg(1, 1, 3))
            emit(ASM.add_imm(4, 4, 1))
          end

          PATCH_ROUTINE = :"#{ROUTINE}_patch".freeze

          # Where a shift sits in an instruction: five bits from bit 7.
          SHIFT_FIELD = 0x1F << 7

          # WRITE THE PICTURE'S SHIFTS INTO THE PAIR LOOP (see #emit_pixel_pairs), called once a face
          # before its rows. Across, the pixel is the top log2(width) bits of u, a shift down of
          # 32 - log2 width (32 written as nought); down, the same of v; and a row starts the row's
          # number moved up log2 width. Each pixel's three instructions are side by side, and where
          # each pixel's are is kept in a table just before this routine, as how far back from the
          # table they start; the table's own address is found from where this routine runs, since
          # it runs where it was copied, not where the cartridge holds it.
          #
          #   r0 the across field, r1 the down field, r2 the row field, r3 the table, r4 how many
          #   are left, r5 a pixel's instructions, r6 an instruction, r7 the next entry
          def emit_patch_routine
            sites = refuse_unpaired_patch_sites!
            table = pos
            entries = sites.map { |site| table - site }
            entries << 0 if entries.length.odd?
            emit(entries.pack("v*"))
            place_label(PATCH_ROUTINE)
            load_var(2, :_face_shift)
            load_var(1, :_face_rows_shift)
            emit(ASM.rsb_imm(0, 2, 32))
            emit(ASM.and_imm(0, 0, 31))
            emit(ASM.lsl_imm(0, 0, 7))
            emit(ASM.rsb_imm(1, 1, 32))
            emit(ASM.and_imm(1, 1, 31))
            emit(ASM.lsl_imm(1, 1, 7))
            emit(ASM.lsl_imm(2, 2, 7))
            back = pos + 8 - table
            emit(ASM.sub_imm(3, 15, back & ~0xFF))
            emit(ASM.sub_imm(3, 3, back & 0xFF))
            # Nothing to do when the instructions already hold these shifts, as they do for every
            # face after the first that shows a picture of the same size: the first pixel's say.
            patch = gensym
            emit(ASM.load_halfword(5, 3))
            emit(ASM.sub_reg(5, 3, 5))
            3.times do |field|
              emit(ASM.ldr_offset(6, 5, 4 * field))
              emit(ASM.and_imm(6, 6, SHIFT_FIELD))
              emit(ASM.cmp_reg(6, field))
              emit_branch(:bcond, patch, cond: :ne)
            end
            emit(ASM.bx(14))
            place_label(patch)
            emit_number(4, sites.length)
            emit(ASM.mov_reg(7, 3))
            each = gensym
            place_label(each)
            emit(ASM.load_halfword(5, 7))
            emit(ASM.add_imm(7, 7, 2))
            emit(ASM.sub_reg(5, 3, 5))
            3.times do |field|
              emit(ASM.ldr_offset(6, 5, 4 * field))
              emit(ASM.bic_imm(6, 6, SHIFT_FIELD))
              emit(ASM.orr_reg(6, 6, field))
              emit(ASM.str_offset(6, 5, 4 * field))
            end
            emit(ASM.subs_imm(4, 4, 1))
            emit_branch(:bcond, each, cond: :ne)
            emit(ASM.bx(14))
          end

          # Where each pixel's three patched instructions start, checked to be across, down and
          # row, side by side, as #emit_pair_pixel lays them.
          def refuse_unpaired_patch_sites!
            @span_patches.each_slice(3).map do |(across, *rest)|
              expected = [[across[0], :across], [across[0] + 4, :down], [across[0] + 8, :row]]
              unless [across, *rest] == expected
                raise LoweringError, "The routine that fills a face lost track of the instructions it writes the " \
                                     "picture's shifts into. This is a fault in VBlank, not in the game."
              end
              across[0]
            end
          end

          # The pixels of a span one at a time: for a picture with see-through pixels, where a pixel
          # that is not drawn leaves its half of the pair as it was.
          def emit_single_pixels
            pixel = gensym
            skip = gensym
            odd = gensym
            put = gensym
            place_label(pixel)
            emit_picture_place(11)
            emit(ASM.ldrb_reg(11, 6, 11))
            emit(ASM.cmp_reg(11, 10))
            emit_branch(:bcond, skip, cond: :eq)
            emit(ASM.bic_imm(12, 4, 1))            # the pair this pixel shares
            emit(ASM.load_halfword(14, 12))
            emit(ASM.tst_imm(4, 1))
            emit_branch(:bcond, odd, cond: :ne)
            emit(ASM.and_imm(14, 14, 0xFF00))
            emit(ASM.orr_reg(14, 14, 11))
            emit_branch(:b, put)
            place_label(odd)
            emit(ASM.and_imm(14, 14, 0xFF))
            emit(ASM.orr_reg_lsl(14, 14, 11, 8))
            place_label(put)
            emit(ASM.store_halfword(14, 12))
            place_label(skip)
            emit(ASM.add_reg(0, 0, 2))
            emit(ASM.add_reg(1, 1, 3))
            emit(ASM.add_imm(4, 4, 1))
            emit(ASM.subs_imm(5, 5, 1))
            emit_branch(:bcond, pixel, cond: :ne)
          end

          # The pixels of a span on the direct screen: each the picture's colour, two bytes, read
          # and written whole. The registers are as #emit_pixels has them, r4 counting two bytes a
          # pixel and r6 the picture's colours.
          def emit_direct_pixels
            pixel = gensym
            skip = gensym
            place_label(pixel)
            emit_picture_place(11)
            emit(ASM.lsl_imm(11, 11, 1))
            emit(ASM.add_reg(11, 6, 11))
            emit(ASM.load_halfword(11, 11))
            emit(ASM.cmp_reg(11, 10))
            emit_branch(:bcond, skip, cond: :eq)
            emit(ASM.store_halfword(11, 4))
            place_label(skip)
            emit(ASM.add_reg(0, 0, 2))
            emit(ASM.add_reg(1, 1, 3))
            emit(ASM.add_imm(4, 4, 2))
            emit(ASM.subs_imm(5, 5, 1))
            emit_branch(:bcond, pixel, cond: :ne)
          end
        end
      end
    end
  end
end
