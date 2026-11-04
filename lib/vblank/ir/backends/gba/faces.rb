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

          # The word corner +k+'s +field+ (one of CORNER_FIELDS) is handed over in.
          def self.corner_word(field, k) = :"_face_#{field}#{k}"

          # The words a fill is handed: each corner, how many there are, the edges nothing outside
          # is drawn, and the picture — where its pixels start, how far a row's number is shifted to
          # find a row, the two masks that make it repeat, the number that means see-through (one no
          # picture holds, when it has none), and 1 when it is on the direct screen.
          CORNER_WORDS = MOST_CORNERS.times.flat_map { |k| CORNER_FIELDS.map { |field| corner_word(field, k) } }.freeze
          EDGE_WORDS = %i[_face_left _face_top _face_right _face_bottom].freeze
          PICTURE_WORDS = %i[_face_picture _face_shift _face_mask_x _face_mask_y _face_clear _face_rows_shift].freeze

          # What the routine keeps of each edge (see Reference::FaceEdge), and of the row it is on.
          EDGE_FIELDS = %w[first past x u v step_x step_u step_v].freeze
          ROW_ENDS = %i[_face_left_x _face_left_u _face_left_v _face_right_x _face_right_u _face_right_v].freeze

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
            MOST_CORNERS.times { |k| emit_edge(k) }
            @span_patches = []
            emit_branch(:bl, PATCH_ROUTINE)
            emit_rows
            emit(ASM.pop(4, 5, 6, 7, 8, 9, 10, 11, 15))
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

          # Edge +k+, from corner +k+ to the next (the first, after the last), its numbers kept in
          # its EDGE_FIELDS words. An edge past the face's corners crosses no row. r4-r7 hold one
          # end's x, y, u and v, and r8-r11 the other's; the upper end comes first.
          def emit_edge(k)
            level = gensym
            done = gensym
            ordered = gensym
            load_var(0, :_face_corners)
            emit(ASM.cmp_imm(0, k))
            emit_branch(:bcond, level, cond: :le)
            CORNER_FIELDS.each_with_index { |field, i| load_var(4 + i, corner_word(field, k)) }
            emit_load_next_corner(k)
            emit(ASM.cmp_reg(5, 9))
            emit_branch(:bcond, level, cond: :eq)
            emit_branch(:bcond, ordered, cond: :lt)
            4.times do |i| # the lower end came first: swap the two ends
              emit(ASM.mov_reg(0, 4 + i))
              emit(ASM.mov_reg(4 + i, 8 + i))
              emit(ASM.mov_reg(8 + i, 0))
            end
            place_label(ordered)

            emit_row_of(0, 5) # the first row whose middle it crosses...
            emit_row_of(1, 9) # ...and the row past its last
            store_var(0, edge_word(k, :first))
            store_var(1, edge_word(k, :past))
            emit(ASM.cmp_reg(0, 1))
            emit_branch(:bcond, level, cond: :ge) # it crosses no row's middle

            # How far one row is along it: 2**28 over its height, held as 24 fraction bits.
            emit(ASM.sub_reg(0, 9, 5))
            emit_number(1, 1 << 28)
            emit_call_divide_routine
            emit(ASM.mov_reg(9, 0))

            # How far its first row's middle is along it.
            load_var(0, edge_word(k, :first))
            emit(ASM.lsl_imm(0, 0, 4))
            emit(ASM.add_imm(0, 0, 8))
            emit(ASM.sub_reg(0, 0, 5))
            emit_mul_fix(5, 0, 9, 4)

            emit(ASM.sub_reg(8, 8, 4))
            emit(ASM.lsl_imm(8, 8, 12)) # across, in pixels with sixteen fraction bits
            emit(ASM.lsl_imm(4, 4, 12))
            emit(ASM.sub_reg(10, 10, 6))
            emit(ASM.sub_reg(11, 11, 7))
            [[4, 8, :x, :step_x], [6, 10, :u, :step_u], [7, 11, :v, :step_v]].each do |start, part, at, step|
              emit_mul_fix(0, part, 5, 24)
              emit(ASM.add_reg(0, start, 0))
              store_var(0, edge_word(k, at))
              emit_mul_fix(0, part, 9, 24)
              store_var(0, edge_word(k, step))
            end
            emit_branch(:b, done)

            place_label(level)
            emit_number(0, 0)
            store_var(0, edge_word(k, :first))
            store_var(0, edge_word(k, :past))
            place_label(done)
          end

          # r8-r11 = the corner after +k+: corner k + 1, or the first when +k+ is the last (r0 still
          # holds how many corners there are).
          def emit_load_next_corner(k)
            first = gensym
            loaded = gensym
            if k + 1 < MOST_CORNERS
              emit(ASM.cmp_imm(0, k + 1))
              emit_branch(:bcond, first, cond: :eq)
              CORNER_FIELDS.each_with_index { |field, i| load_var(8 + i, corner_word(field, k + 1)) }
              emit_branch(:b, loaded)
            end
            place_label(first)
            CORNER_FIELDS.each_with_index { |field, i| load_var(8 + i, corner_word(field, 0)) }
            place_label(loaded)
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
          # kept in ROW_ENDS. Fewer than two edges crossing it, and it is skipped.
          #
          #   r6 how many cross; r7-r9 the leftmost's x, u, v; r10, r11, lr the rightmost's
          def emit_row_ends(next_row)
            emit_number(6, 0)
            emit_number(7, Int32::MAX)
            emit_number(10, Int32::MIN)
            MOST_CORNERS.times do |k|
              skip = gensym
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
              emit(ASM.add_imm(6, 6, 1))
              emit(ASM.cmp_reg(1, 7))
              [[7, 1], [8, 2], [9, 3]].each { |to, from| emit(ASM.mov_reg_cond(:lt, to, from)) }
              emit(ASM.cmp_reg(1, 10))
              [[10, 1], [11, 2], [14, 3]].each { |to, from| emit(ASM.mov_reg_cond(:ge, to, from)) }
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
            emit(ASM.mov_reg(7, 1)) # r7 = the pixel past the last, kept across the divides

            emit_span_step(:_face_right_u, :_face_left_u, :_face_step_u)
            emit_span_step(:_face_right_v, :_face_left_v, :_face_step_v)

            # Held to the edges nothing outside is drawn, and to the screen.
            load_var(6, :_face_start)
            emit_clamp(6, :_face_left, :at_least)
            emit_clamp(6, 0, :at_least)
            emit_clamp(7, :_face_right, :at_most)
            emit_clamp(7, SCREEN_WIDTH, :at_most)
            emit(ASM.sub_reg(5, 7, 6)) # how many pixels are drawn
            emit(ASM.cmp_imm(5, 0))
            emit_branch(:bcond, next_row, cond: :le)

            # Where on the picture the first drawn pixel is: the row's left end, moved a step for
            # each pixel it was held in by.
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

            # Which pixel of the screen the first drawn one is, counting along the rows...
            load_var(4, :_face_row)
            emit_number(8, SCREEN_WIDTH)
            emit(ASM.mul(9, 4, 8))
            emit(ASM.add_reg(4, 9, 6))
            direct = gensym
            done = gensym
            load_var(8, :_face_direct)
            emit(ASM.cmp_imm(8, 0))
            emit_branch(:bcond, direct, cond: :ne)

            # ...a byte each on the hidden page of the tear-free screen...
            load_var(8, BACKBUF)
            emit(ASM.add_reg(4, 4, 8))
            emit_load_picture
            emit_pixels
            emit_branch(:b, done)

            # ...or two bytes each on the direct screen.
            place_label(direct)
            emit(ASM.lsl_imm(4, 4, 1))
            emit_number(8, VRAM_START)
            emit(ASM.add_reg(4, 4, 8))
            emit_load_picture
            emit_direct_pixels
            place_label(done)
          end

          def emit_load_picture
            load_var(6, :_face_picture)
            load_var(7, :_face_mask_x)
            load_var(8, :_face_mask_y)
            load_var(9, :_face_shift)
            load_var(10, :_face_clear)
          end

          # +step+ = (+right+ - +left+) divided by the row's count, by the shared divide routine.
          def emit_span_step(right, left, step)
            load_var(1, right)
            load_var(2, left)
            emit(ASM.sub_reg(1, 1, 2))
            load_var(0, :_face_span_count)
            emit_call_divide_routine
            store_var(0, step)
          end

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
          # number moved up log2 width. Each instruction's address is found from where this one
          # runs, since the routine runs where it was copied, not where the cartridge holds it.
          #
          #   r0 the across field, r1 the down field, r2 the row field, r3 an instruction's address,
          #   r4 the instruction
          def emit_patch_routine
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
            fields = { across: 0, down: 1, row: 2 }
            @span_patches.each do |site, kind|
              back = pos + 8 - site
              emit(ASM.sub_imm(3, 15, back & ~0xFF))
              emit(ASM.sub_imm(3, 3, back & 0xFF))
              emit(ASM.ldr(4, 3))
              emit(ASM.bic_imm(4, 4, SHIFT_FIELD))
              emit(ASM.orr_reg(4, 4, fields.fetch(kind)))
              emit(ASM.str(4, 3))
            end
            emit(ASM.bx(14))
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
