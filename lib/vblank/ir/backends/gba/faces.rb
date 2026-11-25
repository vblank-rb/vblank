# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # Filling a face with its picture (Nodes::FillFace), the part of drawing a place that is
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
        #     is, with how far each moves a row. One division an edge, which for an edge of
        #     ordinary height is a multiply by a reciprocal from a table
        #     (#emit_divide_by_count_routine); the rest are long multiplies kept to their middle bits.
        #   - ROWS: each edge that crosses the row gives where it crosses, worked out from its
        #     first row by a multiply. The one furthest left starts the row and the one furthest
        #     right ends it.
        #   - SPANS: the place on the picture stepped by one amount a pixel (two divisions a row,
        #     for across and for down), each pixel read from the picture.
        #
        # The tear-free screen takes two pixels at a time. There a pixel is one byte, and video
        # memory refuses a lone byte. So a picture with no see-through pixel is drawn a pair at a
        # time, both worked out and the pair written whole (#emit_pixel_pairs); only a pixel left
        # over at either end of a row reads its pair, puts its own half in and writes the pair back.
        # A picture with see-through pixels goes a pair at a time too, and reads a pair back only
        # where one of its two pixels is see-through (#emit_see_through_pixel_pairs, and in
        # perspective #emit_run_pair).
        #
        # The direct screen is filled too, two bytes of colour a pixel. A game draws a place only
        # on the tear-free screen (Builder#draw_place), but a program can hold a fill without a
        # place, and the conformance fixture does, on the direct screen every kind there is is
        # played on: refusing it there would leave the kind unplayed on the cartridge.
        #
        # What the routine is told travels in words of work memory (CORNER_WORDS, EDGE_WORDS and
        # PICTURE_WORDS): every value is worked out where the face is written and stored there, and
        # then the routine is called.
        class Faces
          # The statements this part writes (Lowering#statements_written_by), each by its own method.
          STATEMENT_KINDS = %i[draw_place fill_face].freeze

          def emit_statement(node)
            case node.kind
            when :draw_place then emit_draw_place(node)
            when :fill_face then emit_fill_face(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          include Console::Hardware

          ROUTINE = :__fill_face_routine
          # Where a face lying wholly outside the window jumps to: the routine's way out.
          OUTSIDE_WINDOW_LABEL = DerivedNames.sub_label(ROUTINE, :out)

          MOST_CORNERS = Nodes::FillFace::MOST_CORNERS
          CORNER_FIELDS = %w[x y u v].freeze

          # ...and the fifth number of a corner, one over its distance, which only a picture in
          # perspective reads, and the sixth, its light, which only a lit fill reads; the fields
          # come in the corner list in this order.
          LISTED_FIELDS = (CORNER_FIELDS + %w[w light]).freeze

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
          EDGE_FIELDS = %w[first past x u v w step_x step_u step_v step_w shade step_shade].freeze
          ROW_ENDS = %i[_face_left_u _face_left_v _face_right_u _face_right_v].freeze

          # The routine's own working words: how far apart a row's picture is worked out in
          # perspective (nought for never), the two tables of reciprocals, and the row, the span and
          # the stretch of it being drawn; for a lit fill, its shading's table (nought when unlit)
          # and how many levels it has, and the shade at each end of an edge and of a row, its step
          # a pixel and the shade where a span starts; and where the picture's entry the PICTURE_WORDS
          # were last copied from is (#emit_picture_entry).
          WORKING_WORDS = %i[_face_corners _face_direct _face_perspective _face_reciprocals _face_distances _face_row
                             _face_rows_end _face_start _face_span_count _face_step_u _face_step_v _face_step_w
                             _face_left_w _face_right_w _face_top_w _face_bottom_w _face_row_base _face_first
                             _face_past _face_along _face_far_along _face_near_u _face_near_v _face_far_u
                             _face_far_v _face_du _face_dv _face_edge_corner _face_corners_end _face_edge_words
                             _face_pending _face_shading _face_levels _face_top_shade _face_bottom_shade
                             _face_left_shade _face_right_shade _face_step_shade _face_shade _face_run_end
                             _face_moved_w _face_over_u _face_over_v _face_over_w _face_stretch_u
                             _face_stretch_v _face_stretch_w _face_entry].freeze

          # Every word the routine reads or writes, which the lowering names before any of the game's
          # own variables (GBA#lower), so each is in reach of one instruction. A word past that reach
          # takes four, and the routine reads a word in some hundred places: left to the game's order
          # of naming, a game with many variables would make the routine too big for its room. The
          # hidden page's address is the drawing's word and not the routine's, but the routine reads
          # it each row, so it is named here too (#refuse_words_named_late! holds the list whole).
          def self.words
            CORNER_WORDS + EDGE_WORDS + PICTURE_WORDS + ROW_ENDS + WORKING_WORDS +
              MOST_CORNERS.times.flat_map { |k| EDGE_FIELDS.map { |field| :"_face_edge#{k}_#{field}" } } + [BACKBUF]
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
            @shadings = {}
            @shading_tables = {}
            @corner_lists_in_words = Set.new
          end

          # The program's shadings by name, and the tear-free screen's palette (nil without one),
          # which a lit fill's tables are made from.
          def prepare_shadings(program, palette:)
            @shadings = program.walk.select { |node| node.kind == :shading }.to_h { |node| [node.name, node] }
            @palette = palette
            @lit = self.class.lights_faces?(program)
            @runs = self.class.stretch_runs(program)
            @see_through_runs = self.class.see_through_runs(program)
            spans = self.class.perspectives_drawn(program)
            @cuts_stretches = spans.nil? || spans.any? { |span| span > SPLIT_PIXELS }
          end

          # Which runs of whole stretches the routine has: 8 for :every_8_pixels
          # (#emit_whole_stretches), 16 for :every_16_pixels (#emit_long_stretches), each only for
          # a game that draws a place with it. A run is a thousand bytes and more of quick memory,
          # and one run that served both would cost every turn the test of which it is. Without its
          # run, a stretch is drawn the slow way, the same pixels.
          def self.stretch_runs(program)
            spans = perspectives_drawn(program)
            spans ? STRETCH_RUNS & spans : STRETCH_RUNS
          end

          # The perspectives the program's faces are filled with (Nodes::FillFace::PERSPECTIVE_SPANS'
          # numbers): each drawing of a place's, and each fill's given as a number of its own. Nil
          # for a fill whose perspective is worked out as the game runs outside any drawing of a
          # place, which could be any.
          def self.perspectives_drawn(program)
            nodes = program.walk.to_a
            return nil if nodes.none? { |node| node.kind == :draw_place } &&
                          nodes.any? { |node| node.kind == :fill_face && node.perspective.kind != :int }

            nodes.filter_map do |node|
              case node.kind
              when :draw_place then Nodes::FillFace::PERSPECTIVE_SPANS.fetch(node.perspective)
              when :fill_face then node.perspective.value if node.perspective.kind == :int
              end
            end.uniq
          end

          # Does this program fill a face? Then it needs the routine, and the divide it calls.
          def self.fills_faces?(program) = program.walk.any? { |node| node.kind == :fill_face }

          # Does it light one (Nodes::Shading)? Then the routine has a lit copy of each of its
          # loops, and is that much bigger; a game that lights none carries none of them.
          def self.lights_faces?(program) = program.walk.any? { |node| node.kind == :fill_face && node.shading }

          # Which runs of whole stretches have a twin for pictures with see-through pixels, a grate
          # or a door with gaps (#emit_run_pair): of Faces.stretch_runs, those the game fills a face
          # with such a picture in. Each twin is a thousand bytes and more of quick memory, so a
          # game that draws none carries none, and a grate drawn only without perspective, or
          # every pixel, carries none either. A picture that names a see-through colour none of
          # its pixels has is drawn as one with none (#picture_entry).
          #
          # A drawing of a place fills with its own perspective, in the routines it calls (a place's
          # fills are in a routine its drawings share); a fill outside one with its own number, or,
          # worked out as the game runs, with any (as Faces.perspectives_drawn).
          def self.see_through_runs(program)
            pictures = ScreenLayout.bitmaps_of(program).slice(*pictures_filled(program))
            clear = pictures.filter_map { |name, picture| name if see_through?(picture) }.to_set
            return [] if clear.empty?

            routines = program.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
            shows = ->(node) { fills_reached(node, routines).any? { |fill| fill.pictures.any? { clear.include?(_1) } } }
            spans = perspectives_drawn(program) && program.walk.filter_map do |node|
              case node.kind
              when :draw_place then Nodes::FillFace::PERSPECTIVE_SPANS.fetch(node.perspective) if shows.call(node)
              when :fill_face then node.perspective.value if node.perspective.kind == :int && shows.call(node)
              end
            end
            spans ? stretch_runs(program) & spans : stretch_runs(program)
          end

          # The fills inside +node+ and inside every routine it calls, and they call, by name in
          # +routines+, each routine once.
          def self.fills_reached(node, routines, seen = Set.new)
            fills = node.walk.select { |each| each.kind == :fill_face }
            node.walk.flat_map(&:callees).uniq.each do |name|
              next unless (body = routines[name]) && seen.add?(name)

              fills.concat(fills_reached(body, routines, seen))
            end
            fills
          end
          private_class_method :fills_reached

          # Whether some pixel of +picture+ is its see-through colour.
          def self.see_through?(picture) = !picture.transparent.nil? && picture.pixels.unpack("v*").include?(picture.transparent)

          # The room the quick memory keeps for the routine, lit or not, with its runs of whole
          # stretches, and the twins for see-through pictures of +see_through_runs+ (see
          # ROUTINE_BYTES).
          def self.routine_bytes(lit:, runs: STRETCH_RUNS, see_through_runs: [])
            room = lit ? LIT_ROUTINE_BYTES : ROUTINE_BYTES
            if runs.include?(LONG_STRETCH)
              room -= lit ? LIT_RUN_BYTES : RUN_BYTES unless runs.include?(STRETCH)
              room += lit ? LIT_LONG_RUN_BYTES : LONG_RUN_BYTES
            end
            return room if see_through_runs.empty?

            room += lit ? LIT_SEE_THROUGH_PAIR_BYTES : SEE_THROUGH_PAIR_BYTES
            room += lit ? LIT_SEE_THROUGH_RUN_BYTES : SEE_THROUGH_RUN_BYTES if see_through_runs.include?(STRETCH)
            room += lit ? LIT_SEE_THROUGH_LONG_RUN_BYTES : SEE_THROUGH_LONG_RUN_BYTES if see_through_runs.include?(LONG_STRETCH)
            room
          end

          # The pictures a fill reads as the game runs, which the cartridge carries whatever else
          # draws them.
          def self.pictures_filled(program) = program.walk.flat_map { |node| node.kind == :fill_face ? node.pictures : [] }.uniq

          # A place's statements: what the place's routine is told, and the call (see
          # Nodes::DrawPlace). The routine works the sums out here as it does everywhere.
          def emit_draw_place(node)
            node.children.each { |statement| @lowering.statement(statement) }
          end

          # A place's corner list is kept in the routine's own corner words, so a fill hands its
          # corners over by writing nothing at all. The list and the words hold the same numbers in
          # the same order (a corner's CORNER_NUMBERS, LISTED_FIELDS), and a place's drawing writes
          # every number the fill reads into the list before each fill, then reads none of them after
          # it: the routine works a picture in perspective into its corners' u and v, and a lit one
          # its lights, in the words themselves. So two places' lists can share the words too.
          #
          # Only a place's own list, which IR::PlaceDrawing writes and reads as above; a fill of
          # another list is handed its corners by copying them, since its game may read the list
          # again. The names of the lists kept in the words, from +declarations+ ([list_new, shifted]).
          def corner_lists_in_words(program, declarations)
            filled = program.walk.filter_map { |node| node.corners if node.kind == :fill_face }.to_set
            @corner_lists_in_words = declarations.filter_map do |node, ring|
              kind, parts = Messages::MadeNames.read(node.name)
              next unless filled.include?(node.name) && kind == :place_part && parts[:part] == "corners"
              next unless !ring && (node.width || :word) == :word && node.capacity == CORNER_WORDS.length

              node.name
            end.to_set
          end

          # The fill: its corners read out of their list into the routine's words (unless the list is
          # kept in them, #corner_lists_in_words), its picture's entry out of the fill's table of
          # pictures, and the routine called. A count under three draws nothing, and one past
          # MOST_CORNERS is held to it.
          def emit_fill_face(node)
            done = @emitter.gensym
            @lowering.value(node.count)
            @emitter.emit_number(TMP, MOST_CORNERS)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit(ASM.mov_reg_cond(:gt, ACC, TMP))
            @emitter.emit(ASM.cmp_imm(ACC, 3))
            @emitter.emit_branch(:bcond, done, cond: :lt)
            @primitives.store_var(ACC, :_face_corners)
            emit_copy_corners(node) unless @corner_lists_in_words.include?(node.corners)
            emit_shading_words(node) if @lit
            node.edges.zip(EDGE_WORDS).each do |value, word|
              @lowering.value(value)
              @primitives.store_var(ACC, word)
            end
            emit_picture_entry(node)
            @emitter.emit_number(ACC, @lowering.mode == :buffered ? 0 : 1)
            @primitives.store_var(ACC, :_face_direct)
            @lowering.value(node.perspective)
            @primitives.store_var(ACC, :_face_perspective)
            @divide.emit_call_routine_at(@routine_iwram)
            @emitter.place_label(done)
          end

          # The fill's corners copied out of their list into the routine's words. Only the face's own
          # corners: the routine reads no corner past its count, and a face of four corners is most
          # faces, so the copy stops there.
          def emit_copy_corners(node)
            copied = @emitter.gensym
            CORNER_WORDS.each_with_index do |word, at|
              corner, field = at.divmod(LISTED_FIELDS.length)
              emit_branch_past_corner_count(corner, copied, TMP) if field.zero?
              next if node.shading.nil? && field == LISTED_FIELDS.index("light")

              @lowering.value(Build.list_get(node.corners, Build.int(at)))
              @primitives.store_var(ACC, word)
            end
            @emitter.place_label(copied)
          end

          # On to +past+ when corner +corner+ is past the face's own: from the fourth on, the corner
          # count read into +reg+ and compared. A face of three corners or four is most faces, so the
          # work for the corners after its last is left undone.
          def emit_branch_past_corner_count(corner, past, reg)
            return if corner < 3

            @primitives.load_var(reg, :_face_corners)
            @emitter.emit(ASM.cmp_imm(reg, corner))
            @emitter.emit_branch(:bcond, past, cond: :le)
          end

          # Where the routine runs in the quick memory, which TopOfQuickMemory keeps for it; nil
          # for a game that fills no face.
          def reserve_fill_face_routine(at:)
            @routine_iwram = at
          end

          # Copy the routine from the cartridge into the quick memory, once, at power-on, with the
          # words every fill hands it alike: where its two tables are, which nothing writes after.
          # No picture's entry is marked as copied, since the console's memory is not nought at
          # power-on.
          def emit_copy_fill_face_routine
            return unless @routine_iwram

            @divide.copy_routine(ROUTINE, @routine_iwram)
            @emitter.emit_load_data_address(ACC, reciprocal_table)
            @primitives.store_var(ACC, :_face_reciprocals)
            @emitter.emit_load_data_address(ACC, distance_table)
            @primitives.store_var(ACC, :_face_distances)
            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, :_face_entry)
          end

          # Where the routine runs, by name, for a profile to report against.
          def fill_face_routine_addresses
            return {} unless @routine_iwram

            { ROUTINE => @routine_iwram...(@routine_iwram + @emitter.routine_bytes(ROUTINE)) }
          end

          # The routine, made once for a game that fills a face, after the game's own code, and
          # copied into the quick memory at power-on. It reads nothing beside itself: its jumps are
          # all within it, and every number and address it uses is built an instruction at a time.
          def emit_fill_face_routine
            return unless @routine_iwram

            @emitter.refuse_open_number_table!("The routine that fills a face")
            @emitter.emit(ASM.loop_forever) # entered only by a call
            @emitter.place_label(ROUTINE)
            start = @emitter.pos
            @emitter.emit(ASM.push(4, 5, 6, 7, 8, 9, 10, 11, 14))
            emit_skip_face_outside_edges(OUTSIDE_WINDOW_LABEL)
            emit_corners_in_perspective
            emit_corners_lit if @lit
            emit_edges
            @span_patches = []
            @moved_up_patches = []
            @clear_patches = []
            @emitter.emit_branch(:bl, PATCH_ROUTINE)
            emit_rows
            @emitter.place_label(OUTSIDE_WINDOW_LABEL)
            @emitter.emit(ASM.pop(4, 5, 6, 7, 8, 9, 10, 11, 15))
            emit_span_pixels_routine
            emit_divide_by_count_routine
            emit_place_in_perspective_routine
            emit_pixel_in_perspective_routine(lit: false)
            if @lit
              emit_pixel_in_perspective_routine(lit: true)
              emit_shade_color_routine
            end
            if @see_through_runs.any?
              emit_see_through_pair_routine(lit: false)
              emit_see_through_pair_routine(lit: true) if @lit
            end
            emit_patch_routine
            @emitter.place_label(DerivedNames.routine_end(ROUTINE))
            refuse_words_named_late!(start...@emitter.pos)
            refuse_oversized_routine!(@emitter.pos - start)
          end

          # The room the quick memory keeps for the routine, and for its lit form. Every word it
          # names is one instruction away (Faces.words are named before any of the game's), so its
          # size is the same in every game that has the same runs; each leaves a little to spare.
          # The rooms are the routine's with the :every_8_pixels run and not the :every_16_pixels
          # one, kept for a game with no :every_16_pixels run whichever it has. A game with that
          # run has the room after them more, less the :every_8_pixels run's room where it has
          # none of that (the lit routine has an unlit and a lit run of each).
          ROUTINE_BYTES = 6_144
          LIT_ROUTINE_BYTES = 9_728
          RUN_BYTES = 1_328
          LIT_RUN_BYTES = 2_884
          LONG_RUN_BYTES = 1_788
          LIT_LONG_RUN_BYTES = 3_760
          # A game that fills a face in perspective with a see-through picture has the room after
          # these more: the routines a pair with a see-through pixel calls
          # (#emit_see_through_pair_routine) with the patch routine's writing of the see-through
          # number (#emit_patch_clear), and the twin of each run it has (Faces.see_through_runs).
          SEE_THROUGH_PAIR_BYTES = 128
          LIT_SEE_THROUGH_PAIR_BYTES = 256
          SEE_THROUGH_RUN_BYTES = 1_536
          LIT_SEE_THROUGH_RUN_BYTES = 3_340
          SEE_THROUGH_LONG_RUN_BYTES = 1_912
          LIT_SEE_THROUGH_LONG_RUN_BYTES = 4_132

          def refuse_oversized_routine!(size)
            room = self.class.routine_bytes(lit: @lit, runs: @runs, see_through_runs: @see_through_runs)
            return if size <= room

            raise LoweringError, "The routine that fills a face came to #{size} bytes, and the quick memory keeps " \
                                 "#{room} for it. This is a fault in VBlank, not in the game."
          end

          # A word the routine names that FACES.WORDS DOES NOT is given its place where the routine
          # first names it, after the game's own variables: in a game of a thousand variables that
          # is past one instruction's reach, and each of its reads takes four instructions where it
          # took one. So the routine's size would grow with the game, and only a big game would find
          # out. Every game builds the routine, so this check stops the smallest of them instead.
          def refuse_words_named_late!(span)
            late = @primitives.variables_named_in(span) - self.class.words
            return if late.empty?

            raise LoweringError, "The routine that fills a face names #{late.join(", ")}, which Faces.words does " \
                                 "not list. This is a fault in VBlank, not in the game."
          end

          private

          def edge_word(k, field) = :"_face_edge#{k}_#{field}"

          def corner_word(field, k) = self.class.corner_word(field, k)

          # The picture's entry, from a table of the fill's pictures in the cartridge: its number,
          # worked out as the game runs, held to the ends of the table, and the entry's words
          # copied to the routine's. Nothing else writes those words, so where the entry copied
          # last is kept, and an entry already there is not copied again: a place's faces are
          # most often filled with one picture after another the same.
          def emit_picture_entry(node)
            copied = @emitter.gensym
            @lowering.value(node.picture)
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit(ASM.mov_imm_cond(:lt, ACC, 0))
            @emitter.emit_number(TMP, node.pictures.length - 1)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit(ASM.mov_reg_cond(:gt, ACC, TMP))
            @emitter.emit_number(TMP, PICTURE_ENTRY_BYTES)
            @emitter.emit(ASM.mul(SPARE, ACC, TMP))
            @emitter.emit_load_data_address(ACC, picture_table(node.pictures))
            @emitter.emit(ASM.add_reg(SPARE, SPARE, ACC))
            @primitives.load_var(TMP, :_face_entry)
            @emitter.emit(ASM.cmp_reg(SPARE, TMP))
            @emitter.emit_branch(:bcond, copied, cond: :eq)
            @primitives.store_var(SPARE, :_face_entry)
            PICTURE_WORDS.each_with_index do |word, i|
              @emitter.emit(ASM.ldr_offset(ACC, SPARE, i * 4))
              @primitives.store_var(ACC, word)
            end
            @emitter.place_label(copied)
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
            clear = nil unless self.class.see_through?(bmp)
            [0, bmp.width.bit_length - 1, bmp.width - 1, bmp.height - 1, clear || NO_CLEAR, bmp.height.bit_length - 1]
          end

          # A lit fill (Nodes::Shading) hands the routine its shading's table and how many levels it
          # has; an unlit one hands it nought for the table, which is how the routine tells.
          def emit_shading_words(node)
            if node.shading
              @emitter.emit_load_data_address(ACC, shading_table(node.shading))
              @primitives.store_var(ACC, :_face_shading)
              @emitter.emit_number(ACC, @shadings.fetch(node.shading).levels.length)
              @primitives.store_var(ACC, :_face_levels)
            else
              @emitter.emit_number(ACC, 0)
              @primitives.store_var(ACC, :_face_shading)
            end
          end

          # The shading as a TABLE, made once for each shading and screen.
          #
          # On the tear-free screen a pixel is a palette number, so the table is one row of 256
          # bytes for each level, darkest first: for each palette number, the number of the colour
          # it becomes at that level. A colour the shading does not list keeps its own number. The
          # palette holds every colour a level can give, since a lit fill's colours are counted into
          # it (Palette#shaded_colors). Then a pixel's colour at its level is one load: the table,
          # plus the level times 256, plus the pixel's number.
          #
          # On the direct screen a pixel is its colour, and a table by colour would be 64 KB. So the
          # table is the shading's colours, which a pixel's colour is looked for among, and then
          # for each level the colour each becomes: a word for how many colours there are, then
          # those colours and the levels' colours, two bytes each.
          def shading_table(name)
            buffered = @lowering.mode == :buffered
            @shading_tables[[name, buffered]] ||= :"__fill_face_shading_#{@shading_tables.length}".tap do |blob|
              shading = @shadings.fetch(name)
              @emitter.data_blobs[blob] = buffered ? palette_shading_bytes(shading) : color_shading_bytes(shading)
            end
          end

          # A palette number whose colour the shading lists, but whose colour at a level the
          # palette does not hold, keeps its own number: no lit picture holds that colour (the
          # palette has every level of each colour one does), so no lit pixel ever looks it up.
          # The colour is on the screen for something else, a clear or a line of text.
          #
          # A number the palette gave to one place of the shading, for a lit picture of numbers whose
          # place holds an earlier place's colour and darkens apart from it (Palette#place_at_slot),
          # darkens by that place.
          def palette_shading_bytes(shading)
            places = shading.places
            shading.levels.flat_map do |level|
              (0...256).map do |number|
                place = number < @palette.size ? @palette.place_at_slot(shading.name, number) || places[@palette.color_at(number)] : nil
                shaded = place && shading.colors[level[place]]
                shaded && @palette.holds_color?(shaded) ? @palette.index_of(shaded) : number
              end
            end.pack("C*")
          end

          # A pixel here is found among the colours, so a picture given as numbers into the shading
          # darkens by its first place of each colour: no place is drawn on this screen (only a
          # fill written straight into a program is), so nothing tells two places apart here.
          def color_shading_bytes(shading)
            shaded = shading.levels.flat_map { |level| level.map { |place| shading.colors[place] } }
            [shading.colors.length].pack("l<") + (shading.colors + shaded).pack("v*")
          end

          # A picture in perspective walks u and v over the distance down the edges, not u and v
          # (Reference::FaceEdges.in_perspective): each corner's u and v times its w, down 28 bits.
          #
          # The corners are side by side in memory (see #emit_edges), so this is a loop over them.
          #
          #   r0 corners left, r3 a corner's words, r4 its w, r6 its u or v
          def emit_corners_in_perspective
            straight = @emitter.gensym
            @primitives.load_var(0, :_face_perspective)
            @emitter.emit(ASM.cmp_imm(0, 0))
            @emitter.emit_branch(:bcond, straight, cond: :eq)
            emit_each_corner do
              @emitter.emit(ASM.ldr_offset(4, 3, corner_offset(:w)))
              %i[u v].each do |field|
                @emitter.emit(ASM.ldr_offset(6, 3, corner_offset(field)))
                emit_mul_fix(6, 6, 4, 28)
                @emitter.emit(ASM.str_offset(6, 3, corner_offset(field)))
              end
            end
            emit_whole_stretch_words
            @emitter.place_label(straight)
          end

          # What the run of whole stretches reads that is the same for every row of a face
          # (#emit_whole_stretches): a first guess at how far one over the distance is moved down
          # (#emit_distance_near_last), which must be one the search could have left.
          def emit_whole_stretch_words
            @emitter.emit_number(1, LEAST_MOVED)
            @primitives.store_var(1, :_face_moved_w)
          end

          # A lit FILL's corners, each light held to 0..LIGHTEST and made its shade, times the
          # levels (Reference::Shade#shaded_corner), so a shade's top sixteen bits are its level.
          #
          #   r0 corners left, r3 a corner's words, r4 the levels, r5 the shade, r6 a corner's
          #   light, r1 LIGHTEST
          def emit_corners_lit
            unlit = @emitter.gensym
            @primitives.load_var(4, :_face_shading)
            @emitter.emit(ASM.cmp_imm(4, 0))
            @emitter.emit_branch(:bcond, unlit, cond: :eq)
            @primitives.load_var(4, :_face_levels)
            @emitter.emit_number(1, Nodes::FillFace::LIGHTEST)
            emit_each_corner do
              @emitter.emit(ASM.ldr_offset(6, 3, corner_offset(:light)))
              @emitter.emit(ASM.cmp_imm(6, 0))
              @emitter.emit(ASM.mov_imm_cond(:lt, 6, 0))
              @emitter.emit(ASM.cmp_reg(6, 1))
              @emitter.emit(ASM.mov_reg_cond(:gt, 6, 1))
              @emitter.emit(ASM.mul(5, 6, 4))
              @emitter.emit(ASM.str_offset(5, 3, corner_offset(:light)))
            end
            @emitter.place_label(unlit)
          end

          # The block's instructions once for each of the face's corners (three to MOST_CORNERS),
          # with r3 at the corner's words and r0 counting down. The block must keep r0 and r3.
          def emit_each_corner
            each = @emitter.gensym
            @primitives.load_var(0, :_face_corners)
            @emitter.emit_number(3, @primitives.var_addr(corner_word(:x, 0)))
            @emitter.place_label(each)
            yield
            @emitter.emit(ASM.add_imm(3, 3, CORNER_BYTES))
            @emitter.emit(ASM.subs_imm(0, 0, 1))
            @emitter.emit_branch(:bcond, each, cond: :ne)
          end

          # The byte offset of corner field +field+ from the start of a corner's words.
          def corner_offset(field) = 4 * LISTED_FIELDS.index(field.to_s)

          # How many bytes one corner's words and one edge's words take, each set of words side by
          # side in the order Faces.words names them.
          CORNER_BYTES = 4 * LISTED_FIELDS.length
          EDGE_BYTES = 4 * EDGE_FIELDS.length

          # The byte offset of edge field +field+ from the start of an edge's words.
          def edge_offset(field) = 4 * EDGE_FIELDS.index(field.to_s)

          # Every edge of the face's own corners, one turn of a loop each (see #emit_edge_body); the
          # words of an edge past them keep whatever an earlier face left, and nothing reads them, as
          # every loop over the edges stops at the corner count. The corners' words and the
          # edges' are side by side in memory (Faces.words is named first, in order), so each turn
          # steps from one corner's words and one edge's to the next, the two places kept in words
          # of their own with where the corners end; that is checked here, since a different
          # layout would read the wrong words.
          def emit_edges
            refuse_scattered_words!
            top = @emitter.gensym
            finished = @emitter.gensym
            @emitter.emit_number(0, @primitives.var_addr(edge_word(0, :first)))
            @primitives.store_var(0, :_face_edge_words)
            @emitter.emit_number(2, @primitives.var_addr(corner_word(:x, 0)))
            @primitives.store_var(2, :_face_edge_corner)
            @primitives.load_var(1, :_face_corners)
            @emitter.emit_number(0, CORNER_BYTES)
            @emitter.emit(ASM.mul(3, 1, 0))
            @emitter.emit(ASM.add_reg(3, 2, 3))
            @primitives.store_var(3, :_face_corners_end)
            @emitter.place_label(top)
            @primitives.load_var(2, :_face_edge_corner)
            @primitives.load_var(1, :_face_corners_end)
            @emitter.emit(ASM.cmp_reg(2, 1))
            @emitter.emit_branch(:bcond, finished, cond: :ge)
            emit_edge_body
            @primitives.load_var(2, :_face_edge_corner)
            @emitter.emit(ASM.add_imm(2, 2, CORNER_BYTES))
            @primitives.store_var(2, :_face_edge_corner)
            @primitives.load_var(3, :_face_edge_words)
            @emitter.emit(ASM.add_imm(3, 3, EDGE_BYTES))
            @primitives.store_var(3, :_face_edge_words)
            @emitter.emit_branch(:b, top)
            @emitter.place_label(finished)
          end

          def refuse_scattered_words!
            corners = MOST_CORNERS.times.flat_map { |k| LISTED_FIELDS.map { |field| @primitives.var_addr(corner_word(field, k)) } }
            edges = MOST_CORNERS.times.flat_map { |k| EDGE_FIELDS.map { |field| @primitives.var_addr(edge_word(k, field)) } }
            stepped = STEPPED_WORDS.map { |word| @primitives.var_addr(word) } # read together (#emit_far_end_of_whole_stretch)
            return if [corners, edges, stepped].all? { |words| words.each_cons(2).all? { |one, other| other == one + 4 } }

            raise LoweringError, "The words of the routine that fills a face are not side by side. This is a fault " \
                                 "in VBlank, not in the game."
          end

          # The edge from the corner whose words r2 is at to the next (the first, after the last: r1
          # is where the face's corners end), its numbers kept in its EDGE_FIELDS words, which the
          # edge-words word is at. r4-r7 hold one end's x, y, u and v, and r8-r11 the other's; the
          # upper end comes first, which is settled before either is read, by which corner r2 and
          # r3 are at. r3 is then the edge's words wherever one is written.
          def emit_edge_body
            level = @emitter.gensym
            done = @emitter.gensym
            wrapped = @emitter.gensym
            @emitter.emit(ASM.add_imm(3, 2, CORNER_BYTES))
            @emitter.emit(ASM.cmp_reg(3, 1))
            @emitter.emit_branch(:bcond, wrapped, cond: :ne)
            @emitter.emit_number(3, @primitives.var_addr(corner_word(:x, 0))) # the last corner's edge ends at the first
            @emitter.place_label(wrapped)
            @emitter.emit(ASM.ldr_offset(5, 2, corner_offset(:y)))
            @emitter.emit(ASM.ldr_offset(9, 3, corner_offset(:y)))
            @emitter.emit(ASM.cmp_reg(5, 9))
            @emitter.emit_branch(:bcond, level, cond: :eq)
            @emitter.emit(ASM.mov_reg_cond(:gt, 0, 2)) # the lower end came first: take the corners the other way
            @emitter.emit(ASM.mov_reg_cond(:gt, 2, 3))
            @emitter.emit(ASM.mov_reg_cond(:gt, 3, 0))
            @emitter.emit(ASM.ldmia(2, 4, 5, 6, 7)) # x, y, u and v are a corner's first four words
            @emitter.emit(ASM.ldmia(3, 8, 9, 10, 11))
            ends = [%i[w _face_top_w _face_bottom_w]]
            ends << %i[light _face_top_shade _face_bottom_shade] if @lit
            ends.each do |field, top, bottom|
              @emitter.emit(ASM.ldr_offset(1, 2, corner_offset(field)))
              @primitives.store_var(1, top)
              @emitter.emit(ASM.ldr_offset(1, 3, corner_offset(field)))
              @primitives.store_var(1, bottom)
            end

            emit_row_of(0, 5) # the first row whose middle it crosses...
            emit_row_of(1, 9) # ...and the row past its last
            @primitives.load_var(3, :_face_edge_words)
            @emitter.emit(ASM.str_offset(0, 3, edge_offset(:first)))
            @emitter.emit(ASM.str_offset(1, 3, edge_offset(:past)))
            @emitter.emit(ASM.cmp_reg(0, 1))
            @emitter.emit_branch(:bcond, level, cond: :ge) # it crosses no row's middle

            # How far one row is along it: 2**28 over its height, held as 24 fraction bits.
            @emitter.emit(ASM.sub_reg(0, 9, 5))
            @emitter.emit_number(1, 1 << 28)
            @emitter.emit_branch(:bl, DIVIDE_ROUTINE)
            @emitter.emit(ASM.mov_reg(9, 0))

            # How far its first row's middle is along it.
            @primitives.load_var(3, :_face_edge_words)
            @emitter.emit(ASM.ldr_offset(0, 3, edge_offset(:first)))
            @emitter.emit(ASM.lsl_imm(0, 0, 4))
            @emitter.emit(ASM.add_imm(0, 0, 8))
            @emitter.emit(ASM.sub_reg(0, 0, 5))
            emit_mul_fix(5, 0, 9, 4)

            @emitter.emit(ASM.sub_reg(8, 8, 4))
            @emitter.emit(ASM.lsl_imm(8, 8, 12)) # across, in pixels with sixteen fraction bits
            @emitter.emit(ASM.lsl_imm(4, 4, 12))
            @emitter.emit(ASM.sub_reg(10, 10, 6))
            @emitter.emit(ASM.sub_reg(11, 11, 7))
            @primitives.load_var(3, :_face_edge_words)
            [[4, 8, :x, :step_x], [6, 10, :u, :step_u], [7, 11, :v, :step_v]].each do |start, part, at, step|
              emit_mul_fix(0, part, 5, 24)
              @emitter.emit(ASM.add_reg(0, start, 0))
              @emitter.emit(ASM.str_offset(0, 3, edge_offset(at)))
              emit_mul_fix(0, part, 9, 24)
              @emitter.emit(ASM.str_offset(0, 3, edge_offset(step)))
            end
            # w only matters in perspective, and the shade only to a lit fill.
            sloped = [[:_face_perspective, :_face_top_w, :_face_bottom_w, :w, :step_w]]
            sloped << [:_face_shading, :_face_top_shade, :_face_bottom_shade, :shade, :step_shade] if @lit
            sloped.each do |wanted, top, bottom, at, step|
              skip = @emitter.gensym
              @primitives.load_var(0, wanted)
              @emitter.emit(ASM.cmp_imm(0, 0))
              @emitter.emit_branch(:bcond, skip, cond: :eq)
              @primitives.load_var(6, top)
              @primitives.load_var(10, bottom)
              @emitter.emit(ASM.sub_reg(10, 10, 6))
              emit_mul_fix(0, 10, 5, 24)
              @emitter.emit(ASM.add_reg(0, 6, 0))
              @emitter.emit(ASM.str_offset(0, 3, edge_offset(at)))
              emit_mul_fix(0, 10, 9, 24)
              @emitter.emit(ASM.str_offset(0, 3, edge_offset(step)))
              @emitter.place_label(skip)
            end
            @emitter.emit_branch(:b, done)

            @emitter.place_label(level)
            @primitives.load_var(3, :_face_edge_words)
            @emitter.emit_number(0, 0)
            @emitter.emit(ASM.str_offset(0, 3, edge_offset(:first)))
            @emitter.emit(ASM.str_offset(0, 3, edge_offset(:past)))
            @emitter.place_label(done)
          end

          # A face wholly past one edge of what may be drawn draws nothing, and is left at once,
          # before its edges are worked out: a division each. A face beside the view, or behind a
          # doorway's window, is most of the faces of a place seen from inside.
          #
          # Its rows are the ones whose middles its corners' heights span, so a face whose lowest
          # corner's row is above the top, or whose highest is at or below the bottom, has none.
          # Across, where a row starts and ends is worked out along an edge, and can come out a
          # pixel either way of where the corner itself lands, so the test across leaves a pixel to
          # spare: a face it keeps may still draw nothing, and the rows find that out as before.
          #
          #   r4 the least across, r5 the most, r6 the least down, r7 the most; r0 the corners
          #   left, r3 a corner's words
          def emit_skip_face_outside_edges(out)
            each = @emitter.gensym
            @primitives.load_var(0, :_face_corners)
            @emitter.emit_number(3, @primitives.var_addr(corner_word(:x, 0)))
            @emitter.emit(ASM.ldr_offset(4, 3, corner_offset(:x)))
            @emitter.emit(ASM.mov_reg(5, 4))
            @emitter.emit(ASM.ldr_offset(6, 3, corner_offset(:y)))
            @emitter.emit(ASM.mov_reg(7, 6))
            @emitter.emit(ASM.sub_imm(0, 0, 1))
            @emitter.place_label(each)
            @emitter.emit(ASM.add_imm(3, 3, CORNER_BYTES))
            @emitter.emit(ASM.ldr_offset(1, 3, corner_offset(:x)))
            @emitter.emit(ASM.cmp_reg(1, 4))
            @emitter.emit(ASM.mov_reg_cond(:lt, 4, 1))
            @emitter.emit(ASM.cmp_reg(1, 5))
            @emitter.emit(ASM.mov_reg_cond(:gt, 5, 1))
            @emitter.emit(ASM.ldr_offset(1, 3, corner_offset(:y)))
            @emitter.emit(ASM.cmp_reg(1, 6))
            @emitter.emit(ASM.mov_reg_cond(:lt, 6, 1))
            @emitter.emit(ASM.cmp_reg(1, 7))
            @emitter.emit(ASM.mov_reg_cond(:gt, 7, 1))
            @emitter.emit(ASM.subs_imm(0, 0, 1))
            @emitter.emit_branch(:bcond, each, cond: :ne)
            [4, 5, 6, 7].each { |reg| emit_row_of(reg, reg) } # each as the pixel its middle reaches

            # A face crossing no row's middle draws nothing either. An edge's rows run from the row of
            # its upper end to the row of its lower one (#emit_edge_body), so every row of the face is
            # at or below the row of its highest corner and above the row of its lowest: where those
            # are the same row, no edge has a row at all. The shared drawing passes over such a face
            # when it is drawn whole (IR::PlaceDrawing#whole_face_statements); this is the fill's own
            # test, two instructions, for a face cut at the near limit and a fill written in a program.
            @emitter.emit(ASM.cmp_reg(6, 7))
            @emitter.emit_branch(:bcond, out, cond: :ge)

            emit_edge_bound(1, :_face_left, 0, :at_least)
            @emitter.emit(ASM.cmp_reg(5, 1))
            @emitter.emit_branch(:bcond, out, cond: :lt)
            emit_edge_bound(1, :_face_right, SCREEN_WIDTH, :at_most)
            @emitter.emit(ASM.cmp_reg(4, 1))
            @emitter.emit_branch(:bcond, out, cond: :gt)
            emit_edge_bound(1, :_face_top, 0, :at_least)
            @emitter.emit(ASM.cmp_reg(7, 1))
            @emitter.emit_branch(:bcond, out, cond: :le)
            emit_edge_bound(1, :_face_bottom, SCREEN_HEIGHT, :at_most)
            @emitter.emit(ASM.cmp_reg(6, 1))
            @emitter.emit_branch(:bcond, out, cond: :ge)
          end

          # +reg+ = the edge in word +edge+, held to at least or at most +screen+ (r0 is spare, so
          # the corner count is read again where it is needed).
          def emit_edge_bound(reg, edge, screen, way)
            @primitives.load_var(reg, edge)
            @emitter.emit_number(0, screen)
            @emitter.emit(ASM.cmp_reg(reg, 0))
            @emitter.emit(ASM.mov_reg_cond(way == :at_least ? :lt : :gt, reg, 0))
          end

          # +into+ = the row whose middle is at or below the screen position in +from+ (in
          # sixteenths of a pixel): (from + 7) >> 4, the shift keeping the sign.
          def emit_row_of(into, from)
            @emitter.emit(ASM.add_imm(into, from, 7))
            @emitter.emit(ASM.asr_imm(into, into, 4))
          end

          # +into+ = Int32.mul_fix(+a+, +b+, +bits+): the whole product, its low 32 bits taken from
          # +bits+ up. r1 and r2 hold the product's halves, so neither is a factor.
          def emit_mul_fix(into, a, b, bits)
            @emitter.emit(ASM.smull(1, 2, a, b))
            @emitter.emit(ASM.lsr_imm(1, 1, bits))
            @emitter.emit(ASM.orr_reg_lsl(into, 1, 2, 32 - bits))
          end

          # Every row any edge crosses, held to the edges nothing outside is drawn and to the
          # screen, each filled from its leftmost crossing to its rightmost.
          def emit_rows
            top = @emitter.gensym
            next_row = @emitter.gensym
            done = @emitter.gensym

            # The rows any edge crosses: from the least first row to the greatest past one, over
            # each edge's words in turn (r3), r2 counting them down.
            each = @emitter.gensym
            skip = @emitter.gensym
            @emitter.emit_number(4, Int32::MAX)
            @emitter.emit_number(5, Int32::MIN)
            @emitter.emit_number(3, @primitives.var_addr(edge_word(0, :first)))
            @primitives.load_var(2, :_face_corners) # an edge past the corners is never worked out (#emit_edges)
            @emitter.place_label(each)
            @emitter.emit(ASM.ldr_offset(0, 3, edge_offset(:first)))
            @emitter.emit(ASM.ldr_offset(1, 3, edge_offset(:past)))
            @emitter.emit(ASM.cmp_reg(0, 1))
            @emitter.emit_branch(:bcond, skip, cond: :ge)
            @emitter.emit(ASM.cmp_reg(0, 4))
            @emitter.emit(ASM.mov_reg_cond(:lt, 4, 0))
            @emitter.emit(ASM.cmp_reg(1, 5))
            @emitter.emit(ASM.mov_reg_cond(:gt, 5, 1))
            @emitter.place_label(skip)
            @emitter.emit(ASM.add_imm(3, 3, EDGE_BYTES))
            @emitter.emit(ASM.subs_imm(2, 2, 1))
            @emitter.emit_branch(:bcond, each, cond: :ne)
            emit_clamp(4, :_face_top, :at_least)
            emit_clamp(4, 0, :at_least)
            emit_clamp(5, :_face_bottom, :at_most)
            emit_clamp(5, SCREEN_HEIGHT, :at_most)
            @primitives.store_var(4, :_face_row)
            @primitives.store_var(5, :_face_rows_end)

            @emitter.place_label(top)
            @primitives.load_var(4, :_face_row)
            @primitives.load_var(0, :_face_rows_end)
            @emitter.emit(ASM.cmp_reg(4, 0))
            @emitter.emit_branch(:bcond, done, cond: :ge)
            emit_row_ends(next_row)
            emit_span(next_row)
            @emitter.place_label(next_row)
            @primitives.load_var(4, :_face_row)
            @emitter.emit(ASM.add_imm(4, 4, 1))
            @primitives.store_var(4, :_face_row)
            @emitter.emit_branch(:b, top)
            @emitter.place_label(done)
          end

          # +reg+ held to at least (+:at_least+) or at most (+:at_most+) +bound+: a word of memory,
          # or a number. r0 is spare.
          def emit_clamp(reg, bound, way)
            bound.is_a?(Symbol) ? @primitives.load_var(0, bound) : @emitter.emit_number(0, bound)
            @emitter.emit(ASM.cmp_reg(reg, 0))
            @emitter.emit(ASM.mov_reg_cond(way == :at_least ? :lt : :gt, reg, 0))
          end

          # Where the row in r4 starts and ends: of the edges crossing it, the one furthest left
          # (the first such) and the one furthest right (the last such), each its x, u and v: u
          # and v kept in ROW_ENDS, x left in r7 and r10 for the span, which is all that reads it
          # (#emit_span), and its w and shade in the left and right words. Fewer than two edges
          # crossing it, and it is skipped.
          #
          #   r6 how many cross; r7-r9 the leftmost's x, u, v; r10, r11, lr the rightmost's;
          #   r0 the crossing's w, r5 its shade
          def emit_row_ends(next_row)
            @emitter.emit_number(6, 0)
            @emitter.emit_number(7, Int32::MAX)
            @emitter.emit_number(10, Int32::MIN)
            counted = @emitter.gensym
            MOST_CORNERS.times do |k|
              skip = @emitter.gensym
              not_left = @emitter.gensym
              not_right = @emitter.gensym
              emit_branch_past_corner_count(k, counted, 0) # an edge past the corners is never worked out
              @primitives.load_var(0, edge_word(k, :first))
              @emitter.emit(ASM.cmp_reg(4, 0))
              @emitter.emit_branch(:bcond, skip, cond: :lt)
              @primitives.load_var(1, edge_word(k, :past))
              @emitter.emit(ASM.cmp_reg(4, 1))
              @emitter.emit_branch(:bcond, skip, cond: :ge)
              @emitter.emit(ASM.sub_reg(0, 4, 0)) # rows since its first
              emit_crossing(k, 1, :x, :step_x)
              emit_crossing(k, 2, :u, :step_u)
              emit_crossing(k, 3, :v, :step_v)
              if @lit
                # The shade in r5 and then w in r0, in place of the rows, each read through r12.
                @primitives.load_var(5, edge_word(k, :step_shade))
                @emitter.emit(ASM.mul(5, 0, 5))
                @primitives.load_var(12, edge_word(k, :shade))
                @emitter.emit(ASM.add_reg(5, 12, 5))
                @primitives.load_var(12, edge_word(k, :step_w))
                @emitter.emit(ASM.mul(0, 12, 0))
                @primitives.load_var(12, edge_word(k, :w))
                @emitter.emit(ASM.add_reg(0, 12, 0))
              else
                emit_crossing(k, 0, :w, :step_w) # last: it takes the place of the rows
              end
              @emitter.emit(ASM.add_imm(6, 6, 1))
              @emitter.emit(ASM.cmp_reg(1, 7))
              @emitter.emit_branch(:bcond, not_left, cond: :ge)
              [[7, 1], [8, 2], [9, 3]].each { |to, from| @emitter.emit(ASM.mov_reg(to, from)) }
              @primitives.store_var(0, :_face_left_w)
              @primitives.store_var(5, :_face_left_shade) if @lit
              @emitter.place_label(not_left)
              @emitter.emit(ASM.cmp_reg(1, 10))
              @emitter.emit_branch(:bcond, not_right, cond: :lt)
              [[10, 1], [11, 2], [14, 3]].each { |to, from| @emitter.emit(ASM.mov_reg(to, from)) }
              @primitives.store_var(0, :_face_right_w)
              @primitives.store_var(5, :_face_right_shade) if @lit
              @emitter.place_label(not_right)
              @emitter.place_label(skip)
            end
            @emitter.place_label(counted)
            @emitter.emit(ASM.cmp_imm(6, 2))
            @emitter.emit_branch(:bcond, next_row, cond: :lt)
            [8, 9, 11, 14].zip(ROW_ENDS).each { |reg, word| @primitives.store_var(reg, word) }
          end

          # +into+ = edge +k+'s +at+ moved +step+ for each row in r0. r5 is spare.
          def emit_crossing(k, into, at, step)
            @primitives.load_var(5, edge_word(k, step))
            @emitter.emit(ASM.mul(into, 5, 0))
            @primitives.load_var(5, edge_word(k, at))
            @emitter.emit(ASM.add_reg(into, 5, into))
          end

          # The row's pixels: the ones whose middles lie between its two ends, held to the left
          # and right edges and the screen, each the picture's pixel at its place on the picture.
          def emit_span(next_row)
            half = (1 << 15) - 1
            @emitter.emit_number(2, half)
            @emitter.emit(ASM.add_reg(0, 7, 2)) # the row's two ends are still in r7 and r10 (#emit_row_ends)
            @emitter.emit(ASM.asr_imm(0, 0, 16)) # the first pixel
            @emitter.emit(ASM.add_reg(1, 10, 2))
            @emitter.emit(ASM.asr_imm(1, 1, 16)) # the pixel past the last
            @emitter.emit(ASM.sub_reg(3, 1, 0))
            @emitter.emit(ASM.cmp_imm(3, 0))
            @emitter.emit_branch(:bcond, next_row, cond: :le)
            @primitives.store_var(0, :_face_start)
            @primitives.store_var(3, :_face_span_count)
            @emitter.emit(ASM.mov_reg(6, 0))
            @emitter.emit(ASM.mov_reg(7, 1))

            # Held to the edges nothing outside is drawn, and to the screen.
            emit_clamp(6, :_face_left, :at_least)
            emit_clamp(6, 0, :at_least)
            emit_clamp(7, :_face_right, :at_most)
            emit_clamp(7, SCREEN_WIDTH, :at_most)
            @emitter.emit(ASM.sub_reg(5, 7, 6)) # how many pixels are drawn
            @emitter.emit(ASM.cmp_imm(5, 0))
            @emitter.emit_branch(:bcond, next_row, cond: :le)
            @primitives.store_var(6, :_face_first)
            @primitives.store_var(7, :_face_past)
            emit_row_base
            emit_row_shade if @lit

            in_perspective = @emitter.gensym
            @primitives.load_var(0, :_face_perspective)
            @emitter.emit(ASM.cmp_imm(0, 0))
            @emitter.emit_branch(:bcond, in_perspective, cond: :ne)

            # Without perspective the place on the picture steps evenly from the row's left end: so
            # where the first drawn pixel is, a step for each pixel it was held in by.
            emit_span_step(:_face_right_u, :_face_left_u, :_face_step_u)
            emit_span_step(:_face_right_v, :_face_left_v, :_face_step_v)
            @primitives.load_var(6, :_face_first)
            @primitives.load_var(0, :_face_start)
            @emitter.emit(ASM.sub_reg(4, 6, 0))
            @primitives.load_var(2, :_face_step_u)
            @emitter.emit(ASM.mul(0, 2, 4))
            @primitives.load_var(1, :_face_left_u)
            @emitter.emit(ASM.add_reg(0, 1, 0))
            @primitives.load_var(3, :_face_step_v)
            @emitter.emit(ASM.mul(1, 3, 4))
            @primitives.load_var(8, :_face_left_v)
            @emitter.emit(ASM.add_reg(1, 8, 1))
            @primitives.load_var(7, :_face_past)
            @emitter.emit(ASM.sub_reg(5, 7, 6))
            emit_pixel_address(4, 6)
            @emitter.emit_branch(:bl, SPAN_PIXELS_ROUTINE)
            @emitter.emit_branch(:b, next_row)

            @emitter.place_label(in_perspective)
            emit_span_in_perspective(next_row)
          end

          # A lit ROW's shade: each end's held to the levels there are (Reference::Shade#held_row_end),
          # its step a pixel, and the shade at the first pixel drawn. The shade steps evenly across
          # the row whatever the perspective, so a stretch in perspective starts from these too.
          #
          #   r2 the most a shade can be, r1 an end's shade
          def emit_row_shade
            unlit = @emitter.gensym
            @primitives.load_var(0, :_face_shading)
            @emitter.emit(ASM.cmp_imm(0, 0))
            @emitter.emit_branch(:bcond, unlit, cond: :eq)
            @primitives.load_var(2, :_face_levels)
            @emitter.emit(ASM.lsl_imm(2, 2, 16))
            @emitter.emit(ASM.sub_imm(2, 2, 1))
            %i[_face_left_shade _face_right_shade].each do |word|
              @primitives.load_var(1, word)
              @emitter.emit(ASM.cmp_imm(1, 0))
              @emitter.emit(ASM.mov_imm_cond(:lt, 1, 0))
              @emitter.emit(ASM.cmp_reg(1, 2))
              @emitter.emit(ASM.mov_reg_cond(:gt, 1, 2))
              @primitives.store_var(1, word)
            end
            emit_span_step(:_face_right_shade, :_face_left_shade, :_face_step_shade)
            @primitives.load_var(0, :_face_first)
            @primitives.load_var(1, :_face_start)
            @emitter.emit(ASM.sub_reg(0, 0, 1))
            emit_shade_along(0, 2, 1)
            @emitter.place_label(unlit)
          end

          # The shade word = the row's left end's shade, a step for each pixel in +along+ (a
          # register). +into+ and +spare+ are spare.
          def emit_shade_along(along, into, spare)
            @primitives.load_var(spare, :_face_step_shade)
            @emitter.emit(ASM.mul(into, along, spare))
            @primitives.load_var(spare, :_face_left_shade)
            @emitter.emit(ASM.add_reg(into, spare, into))
            @primitives.store_var(into, :_face_shade)
          end

          # Where the row being drawn starts in the screen's memory: on the hidden page of the
          # tear-free screen, a byte a pixel; on the direct screen, two.
          def emit_row_base
            direct = @emitter.gensym
            done = @emitter.gensym
            @primitives.load_var(4, :_face_row)
            @emitter.emit_number(8, SCREEN_WIDTH)
            @emitter.emit(ASM.mul(9, 4, 8))
            @primitives.load_var(8, :_face_direct)
            @emitter.emit(ASM.cmp_imm(8, 0))
            @emitter.emit_branch(:bcond, direct, cond: :ne)
            @primitives.load_var(8, BACKBUF)
            @emitter.emit(ASM.add_reg(9, 9, 8))
            @emitter.emit_branch(:b, done)
            @emitter.place_label(direct)
            @emitter.emit(ASM.lsl_imm(9, 9, 1))
            @emitter.emit_number(8, VRAM_START)
            @emitter.emit(ASM.add_reg(9, 9, 8))
            @emitter.place_label(done)
            @primitives.store_var(9, :_face_row_base)
          end

          # +into+ = where pixel +across+ (a register) of the row is in the screen's memory. r8 is
          # spare.
          def emit_pixel_address(into, across)
            @primitives.load_var(into, :_face_row_base)
            @primitives.load_var(8, :_face_direct)
            @emitter.emit(ASM.cmp_imm(8, 0))
            @emitter.emit(ASM.mov_reg(8, across))
            @emitter.emit(ASM.mov_reg_lsl_cond(:ne, 8, across, 1))
            @emitter.emit(ASM.add_reg(into, into, 8))
          end

          # A row in perspective (Reference#fill_face_row): the place on the picture worked out
          # exactly every so many pixels from the row's start (the perspective word: eight, or one)
          # and at its end, and stepped evenly between, one stretch at a time. Each stretch is drawn
          # by the routine that draws pixels stepping evenly, the same as a row without perspective,
          # so a stretch of a picture with no see-through pixel goes two pixels at a time.
          #
          # The along words count pixels from the row's start: first and past are the drawn part's,
          # along and far-along the stretch's two ends, near and far the place at each.
          #
          # A row on the tear-free screen whose first drawn pixel starts a stretch is not drawn
          # here at all: the fast run takes it from its first stretch to its last pixel
          # (#emit_whole_stretches), and comes back only for a row held in at its right end. A
          # picture with see-through pixels takes the run's twin, in a game that has one
          # (Faces.see_through_runs). So the place at the row's first stretch is worked out here
          # only for a row the fast run did not take.
          def emit_span_in_perspective(next_row)
            stretch = @emitter.gensym
            slow = @emitter.gensym
            nothing = @emitter.gensym
            @primitives.load_var(1, :_face_start) # r6 and r7 are still the drawn part's ends, across the screen
            @emitter.emit(ASM.sub_reg(6, 6, 1))
            @primitives.store_var(6, :_face_first)
            @emitter.emit(ASM.sub_reg(7, 7, 1))
            @primitives.store_var(7, :_face_past)
            @primitives.load_var(3, :_face_perspective)
            @emitter.emit(ASM.rsb_imm(3, 3, 0))
            @emitter.emit(ASM.and_reg(0, 6, 3)) # the stretch the first drawn pixel is in starts here
            @primitives.store_var(0, :_face_along)
            emit_span_step(:_face_right_u, :_face_left_u, :_face_step_u)
            emit_span_step(:_face_right_v, :_face_left_v, :_face_step_v)
            emit_span_step(:_face_right_w, :_face_left_w, :_face_step_w)

            @emitter.place_label(stretch)
            fast = @emitter.gensym
            emit_branch_to_whole_stretches(fast)
            emit_near_place_of_first_stretch
            @emitter.place_label(slow)
            emit_far_along
            @primitives.store_var(0, :_face_far_along)
            @emitter.emit_branch(:bl, SAMPLE_ROUTINE)
            @primitives.store_var(0, :_face_far_u)
            @primitives.store_var(1, :_face_far_v)
            [%i[_face_far_u _face_near_u _face_du], %i[_face_far_v _face_near_v _face_dv]].each do |far, near, step|
              @primitives.load_var(1, far)
              @primitives.load_var(2, near)
              @emitter.emit(ASM.sub_reg(1, 1, 2))
              @primitives.load_var(0, :_face_far_along)
              @primitives.load_var(2, :_face_along)
              @emitter.emit(ASM.sub_reg(0, 0, 2))
              @emitter.emit_branch(:bl, DIVIDE_ROUTINE)
              @primitives.store_var(0, step)
            end

            # The drawn part of the stretch: r6 its first pixel, r7 the one past its last, along.
            @primitives.load_var(6, :_face_along)
            @primitives.load_var(0, :_face_first)
            @emitter.emit(ASM.cmp_reg(6, 0))
            @emitter.emit(ASM.mov_reg_cond(:lt, 6, 0))
            @primitives.load_var(7, :_face_far_along)
            @primitives.load_var(0, :_face_past)
            @emitter.emit(ASM.cmp_reg(7, 0))
            @emitter.emit(ASM.mov_reg_cond(:gt, 7, 0))
            @emitter.emit(ASM.sub_reg(5, 7, 6))
            @emitter.emit(ASM.cmp_imm(5, 0))
            @emitter.emit_branch(:bcond, nothing, cond: :le)
            @primitives.load_var(0, :_face_along)
            @emitter.emit(ASM.sub_reg(4, 6, 0)) # pixels into the stretch it starts
            @primitives.load_var(2, :_face_du)
            @emitter.emit(ASM.mul(0, 2, 4))
            @primitives.load_var(1, :_face_near_u)
            @emitter.emit(ASM.add_reg(0, 1, 0))
            @primitives.load_var(3, :_face_dv)
            @emitter.emit(ASM.mul(1, 3, 4))
            @primitives.load_var(8, :_face_near_v)
            @emitter.emit(ASM.add_reg(1, 8, 1))
            emit_shade_along(6, 8, 7) if @lit # an unlit fill's, nothing reads
            @primitives.load_var(8, :_face_start)
            @emitter.emit(ASM.add_reg(6, 6, 8)) # the pixel across the screen
            emit_pixel_address(4, 6)
            @emitter.emit_branch(:bl, SPAN_PIXELS_ROUTINE)

            @emitter.place_label(nothing)
            @primitives.load_var(0, :_face_far_along)
            @primitives.store_var(0, :_face_along)
            @primitives.load_var(0, :_face_far_u)
            @primitives.store_var(0, :_face_near_u)
            @primitives.load_var(0, :_face_far_v)
            @primitives.store_var(0, :_face_near_v)
            @primitives.load_var(0, :_face_along)
            @primitives.load_var(1, :_face_past)
            @emitter.emit(ASM.cmp_reg(0, 1))
            @emitter.emit_branch(:bcond, stretch, cond: :lt)
            @emitter.emit_branch(:b, next_row)
            [false, *(@lit ? [true] : [])].each do |lit|
              run = lit ? lit_label(fast) : fast
              emit_whole_stretches(run, slow, next_row, lit: lit) if @runs.include?(STRETCH)
              emit_long_stretches(long_label(run), slow, next_row, lit: lit) if @runs.include?(LONG_STRETCH)
              emit_every_pixel_run(every_pixel_label(run), next_row, lit: lit)
              run = lit ? lit_label(see_through_label(fast)) : see_through_label(fast)
              emit_whole_stretches(run, slow, next_row, lit: lit, see_through: true) if @see_through_runs.include?(STRETCH)
              if @see_through_runs.include?(LONG_STRETCH)
                emit_long_stretches(long_label(run), slow, next_row, lit: lit, see_through: true)
              end
            end
          end

          # r0 = where the stretch starting at along ends (Reference#stretch_ends): the next
          # multiple of the perspective word, or the row's end, or SPLIT_PIXELS on for a long
          # stretch cut in two. A stretch that starts off the multiples is the second part of a
          # cut one, and is not cut again.
          #
          #   r1 along, r3 the perspective word, r2, r6, lr and the address register the sums
          def emit_far_along
            return emit_far_along_uncut unless @cuts_stretches

            done = @emitter.gensym
            @primitives.load_var(1, :_face_along)
            @primitives.load_var(3, :_face_perspective)
            @emitter.emit(ASM.rsb_imm(0, 3, 0))
            @emitter.emit(ASM.and_reg(0, 1, 0))
            @emitter.emit(ASM.add_reg(0, 0, 3))
            @primitives.load_var(2, :_face_span_count)
            @emitter.emit(ASM.cmp_reg(0, 2))
            @emitter.emit(ASM.mov_reg_cond(:gt, 0, 2))
            @emitter.emit(ASM.cmp_imm(3, SPLIT_PIXELS))
            @emitter.emit_branch(:bcond, done, cond: :le)
            @emitter.emit(ASM.sub_imm(6, 3, 1))
            @emitter.emit(ASM.tst_reg(1, 6))
            @emitter.emit_branch(:bcond, done, cond: :ne)
            @emitter.emit(ASM.add_imm(6, 1, SPLIT_PIXELS))
            @emitter.emit(ASM.cmp_reg(0, 6))
            @emitter.emit_branch(:bcond, done, cond: :le)
            @primitives.load_var(2, :_face_step_w)
            @emitter.emit(ASM.mul(14, 2, 1))
            @primitives.load_var(3, :_face_left_w)
            @emitter.emit(ASM.add_reg(3, 3, 14)) # one over the distance at the stretch's start
            @emitter.emit(ASM.lsl_imm(2, 2, 3)) # its change over SPLIT_PIXELS
            emit_branch_unless_fast_change(done, 2, 3)
            @emitter.emit(ASM.mov_reg(0, 6))
            @emitter.place_label(done)
          end

          # #emit_far_along for a game whose stretches are never cut (none longer than
          # SPLIT_PIXELS): along on by the perspective word, held to the row's end.
          def emit_far_along_uncut
            @primitives.load_var(0, :_face_along)
            @primitives.load_var(3, :_face_perspective)
            @emitter.emit(ASM.add_reg(0, 0, 3))
            @primitives.load_var(2, :_face_span_count)
            @emitter.emit(ASM.cmp_reg(0, 2))
            @emitter.emit(ASM.mov_reg_cond(:gt, 0, 2))
          end

          # On to +slow+ unless one over the distance changes fast (Reference#fast_change?): +change+,
          # its change over SPLIT_PIXELS pixels, more than a sixteenth of +w+ either way.
          def emit_branch_unless_fast_change(slow, change, w)
            fast = @emitter.gensym
            @emitter.emit(ASM.cmp_reg_asr(change, w, 4))
            @emitter.emit_branch(:bcond, fast, cond: :gt)
            @emitter.emit(ASM.cmn_reg_asr(change, w, 4))
            @emitter.emit_branch(:bcond, slow, cond: :ge)
            @emitter.place_label(fast)
          end

          SPLIT_PIXELS = IR::Nodes::FillFace::SPLIT_PIXELS

          # The place at the near end of a row's first stretch, worked out for a stretch drawn
          # here. Only the first stretch needs it: each one after takes the far end of the one
          # before. The first is the one that starts at or before the first drawn pixel, since
          # every later stretch starts past it.
          def emit_near_place_of_first_stretch
            known = @emitter.gensym
            @primitives.load_var(0, :_face_along)
            @primitives.load_var(1, :_face_first)
            @emitter.emit(ASM.cmp_reg(0, 1))
            @emitter.emit_branch(:bcond, known, cond: :gt)
            @emitter.emit_branch(:bl, SAMPLE_ROUTINE)
            @primitives.store_var(0, :_face_near_u)
            @primitives.store_var(1, :_face_near_v)
            @emitter.place_label(known)
          end

          # The fast runs are named from +fast+, the label of the unlit run of whole stretches: its
          # lit twin, and beside each the run that works out every pixel, which
          # #emit_branch_by_perspective reaches by this name.
          def lit_label(fast) = DerivedNames.sub_label(fast, :lit)
          def every_pixel_label(run) = DerivedNames.sub_label(run, :every_pixel)
          def long_label(run) = DerivedNames.sub_label(run, :every_16_pixels)
          def see_through_label(fast) = DerivedNames.sub_label(fast, :see_through)

          # The words the run of whole stretches keeps: u, v and w over the distance at the
          # stretch's start and each one's step over a whole stretch, which the run reads and
          # writes together and so must be side by side in this order (#refuse_scattered_words!);
          # and where its whole stretches end, along. How far u and v are moved up for the
          # picture's repeat is written into the instructions instead (#emit_moved_up).
          WHOLE_STRETCH_WORDS = %i[_face_over_u _face_over_v _face_over_w _face_stretch_u _face_stretch_v
                                   _face_stretch_w _face_run_end].freeze
          STEPPED_WORDS = WHOLE_STRETCH_WORDS.first(6).freeze

          # The pixels a whole stretch covers, worked out exactly at its ends: eight, the turn of
          # the run of whole stretches; and sixteen, two turns, for :every_16_pixels.
          STRETCH = 8
          LONG_STRETCH = 16
          STRETCH_RUNS = [STRETCH, LONG_STRETCH].freeze

          # On to +fast+ when the stretch about to be drawn starts at a drawn pixel, on the
          # tear-free screen. Those rows take a loop of their own from there on
          # (#emit_whole_stretches, or #emit_every_pixel_run), lit or not. A picture with
          # see-through pixels takes the twin of a run of whole stretches (#see_through_label) where
          # the game has one (Faces.see_through_runs), and no other: every pixel in perspective, or
          # in a setting with no twin, it goes the slow way.
          #
          #   r0 where the stretch starts, along; r2 where the drawn part of the row ends
          def emit_branch_to_whole_stretches(fast)
            not_whole = @emitter.gensym
            see_through = DerivedNames.sub_label(fast, :see_through_branch)
            @primitives.load_var(0, :_face_along)
            @primitives.load_var(1, :_face_first)
            @emitter.emit(ASM.cmp_reg(0, 1))
            @emitter.emit_branch(:bcond, not_whole, cond: :lt)
            @primitives.load_var(2, :_face_past)
            @primitives.load_var(3, :_face_span_count)
            @emitter.emit(ASM.cmp_reg(2, 3))
            @emitter.emit(ASM.mov_reg_cond(:gt, 2, 3))
            @primitives.load_var(3, :_face_direct)
            @emitter.emit(ASM.cmp_imm(3, 0))
            @emitter.emit_branch(:bcond, not_whole, cond: :ne)
            @primitives.load_var(3, :_face_clear)
            @emitter.emit(ASM.add_imm(3, 3, 1)) # NO_CLEAR is -1
            @emitter.emit(ASM.cmp_imm(3, 0))
            see_through_runs = @see_through_runs.any?
            @emitter.emit_branch(:bcond, see_through_runs ? see_through : not_whole, cond: :ne)
            emit_branch_by_shading(fast, not_whole, runs: @runs)
            if see_through_runs
              @emitter.emit_branch(:b, not_whole)
              @emitter.place_label(see_through)
              emit_branch_by_shading(see_through_label(fast), not_whole, runs: @see_through_runs, every_pixel: false)
            end
            @emitter.place_label(not_whole)
          end

          # On to +fast+ or its lit twin by the shading word, and from there by the perspective
          # word (#emit_branch_by_perspective). Lit, a perspective with no run goes on to
          # +not_whole+; unlit it falls through.
          def emit_branch_by_shading(fast, not_whole, runs:, every_pixel: true)
            @primitives.load_var(1, :_face_shading) if @lit
            @primitives.load_var(3, :_face_perspective)
            lit_branch = DerivedNames.sub_label(fast, :lit_branch)
            if @lit
              @emitter.emit(ASM.cmp_imm(1, 0))
              @emitter.emit_branch(:bcond, lit_branch, cond: :ne)
            end
            emit_branch_by_perspective(fast, runs: runs, every_pixel: every_pixel)
            return unless @lit

            @emitter.emit_branch(:b, not_whole)
            @emitter.place_label(lit_branch)
            emit_branch_by_perspective(lit_label(fast), runs: runs, every_pixel: every_pixel)
          end

          # On to +fast+ for a stretch every eight pixels, or its long twin (#long_label) for every
          # sixteen from a multiple of sixteen (a stretch that starts between is the second part of
          # one cut in two), or its every-pixel run for every pixel (unless not +every_pixel+), by
          # the perspective word in r3. r0 is along. Only to the +runs+ the game has
          # (Faces.stretch_runs, or for a see-through picture Faces.see_through_runs): a game that
          # did not name a setting has no run for it, and the slow way draws the same pixels.
          def emit_branch_by_perspective(fast, runs:, every_pixel: true)
            if every_pixel
              @emitter.emit(ASM.cmp_imm(3, 1))
              @emitter.emit_branch(:bcond, every_pixel_label(fast), cond: :eq)
            end
            if runs.include?(STRETCH)
              @emitter.emit(ASM.cmp_imm(3, STRETCH))
              @emitter.emit_branch(:bcond, fast, cond: :eq)
            end
            return unless runs.include?(LONG_STRETCH)

            @emitter.emit(ASM.cmp_imm(3, LONG_STRETCH))
            emit_if(:eq, ASM.tst_imm(0, LONG_STRETCH - 1))
            @emitter.emit_branch(:bcond, long_label(fast), cond: :eq)
          end

          # Every pixel in perspective, the whole drawn part of the row in one loop: each pixel's
          # place worked out exactly from u, v and w over the distance, which step a pixel at a time
          # in r0-r2, and the pixels written a pair at a time, a pixel at either end on its own.
          # Then on to +next_row+.
          #
          #   r4 where the pixel is in the screen's memory, r6-r9 the picture, lr and r3 a pair
          #
          # +lit+, each pixel is shaded as it is worked out (PIXEL_IN_PERSPECTIVE_LIT_ROUTINE).
          def emit_every_pixel_run(start, next_row, lit:)
            even = @emitter.gensym
            pairs = @emitter.gensym
            tail = @emitter.gensym
            pixel = lit ? PIXEL_IN_PERSPECTIVE_LIT_ROUTINE : PIXEL_IN_PERSPECTIVE_ROUTINE
            @emitter.place_label(start)
            @primitives.load_var(5, :_face_first)
            emit_shade_along(5, 0, 1) if lit
            [[0, :_face_step_u, :_face_left_u], [1, :_face_step_v, :_face_left_v],
             [2, :_face_step_w, :_face_left_w]].each do |into, step, left|
              @primitives.load_var(3, step)
              @emitter.emit(ASM.mul(into, 3, 5))
              @primitives.load_var(3, left)
              @emitter.emit(ASM.add_reg(into, 3, into))
            end
            @primitives.load_var(3, :_face_past)
            @emitter.emit(ASM.sub_reg(3, 3, 5))
            @primitives.store_var(3, :_face_run_end) # how many pixels
            @primitives.load_var(3, :_face_start)
            @emitter.emit(ASM.add_reg(5, 5, 3))
            emit_pixel_address(4, 5)
            emit_load_picture
            @emitter.emit(ASM.tst_imm(4, 1))
            @emitter.emit_branch(:bcond, even, cond: :eq)
            @emitter.emit_branch(:bl, pixel)
            @emitter.emit(ASM.bic_imm(5, 4, 1))
            @emitter.emit(ASM.load_halfword(14, 5))
            @emitter.emit(ASM.and_imm(14, 14, 0xFF))
            @emitter.emit(ASM.orr_reg_lsl(14, 14, 3, 8))
            @emitter.emit(ASM.store_halfword(14, 5))
            @emitter.emit(ASM.add_imm(4, 4, 1))
            emit_run_pixels_less(1)
            @emitter.place_label(even)
            @emitter.place_label(pairs)
            @primitives.load_var(5, :_face_run_end)
            @emitter.emit(ASM.cmp_imm(5, 2))
            @emitter.emit_branch(:bcond, tail, cond: :lt)
            @emitter.emit_branch(:bl, pixel)
            @primitives.store_var(3, :_face_pending)
            @emitter.emit_branch(:bl, pixel)
            @primitives.load_var(14, :_face_pending)
            @emitter.emit(ASM.orr_reg_lsl(14, 14, 3, 8))
            @emitter.emit(ASM.store_halfword_post(14, 4, 2))
            emit_run_pixels_less(2)
            @emitter.emit_branch(:b, pairs)
            @emitter.place_label(tail)
            @emitter.emit(ASM.cmp_imm(5, 0))
            @emitter.emit_branch(:bcond, next_row, cond: :eq)
            @emitter.emit_branch(:bl, pixel)
            @emitter.emit(ASM.load_halfword(14, 4))
            @emitter.emit(ASM.and_imm(14, 14, 0xFF00))
            @emitter.emit(ASM.orr_reg(14, 14, 3))
            @emitter.emit(ASM.store_halfword(14, 4))
            @emitter.emit_branch(:b, next_row)
          end

          PIXEL_IN_PERSPECTIVE_ROUTINE = DerivedNames.sub_label(ROUTINE, :pixel_in_perspective)
          PIXEL_IN_PERSPECTIVE_LIT_ROUTINE = DerivedNames.sub_label(ROUTINE, :pixel_in_perspective_lit)

          def emit_run_pixels_less(count)
            @primitives.load_var(5, :_face_run_end)
            @emitter.emit(ASM.sub_imm(5, 5, count))
            @primitives.store_var(5, :_face_run_end)
          end

          # r3 = the picture's pixel at u, v and w over the distance in r0-r2, which then step a
          # pixel on (Reference#place_in_perspective, and the texel as #emit_picture_place finds it).
          # Called with its return in lr; r5 and r10-r12 are spare.
          #
          # The +lit+ one shades the pixel at the shade word's level and steps the shade word on.
          def emit_pixel_in_perspective_routine(lit:)
            @emitter.place_label(lit ? PIXEL_IN_PERSPECTIVE_LIT_ROUTINE : PIXEL_IN_PERSPECTIVE_ROUTINE)
            into = 3
            @emitter.emit(ASM.mov_reg(3, 2))
            emit_distance(3, 10, 11)
            @emitter.emit(ASM.smull(10, 11, 0, 3))
            @emitter.emit(ASM.lsr_imm(10, 10, 14))
            @emitter.emit(ASM.orr_reg_lsl(10, 10, 11, 18)) # u
            @emitter.emit(ASM.smull(11, 12, 1, 3))
            @emitter.emit(ASM.lsr_imm(11, 11, 14))
            @emitter.emit(ASM.orr_reg_lsl(11, 11, 12, 18)) # v
            @emitter.emit(ASM.asr_imm(12, 11, 16))
            @emitter.emit(ASM.and_reg(12, 12, 8))
            @emitter.emit(ASM.mov_reg_lsl_reg(12, 12, 9))
            @emitter.emit(ASM.asr_imm(11, 10, 16))
            @emitter.emit(ASM.and_reg(11, 11, 7))
            @emitter.emit(ASM.orr_reg(12, 12, 11))
            @emitter.emit(ASM.ldrb_reg(into, 6, 12))
            if lit
              @primitives.load_var(5, :_face_shade)
              @emitter.emit(ASM.lsr_imm(10, 5, 16))
              @emitter.emit(ASM.orr_reg_lsl(10, into, 10, 8))
              @primitives.load_var(11, :_face_shading)
              @emitter.emit(ASM.ldrb_reg(into, 11, 10))
              emit_shade_step_in_memory(shade: 5, step: 11) # lr is the way back
            end
            [[0, :_face_step_u], [1, :_face_step_v], [2, :_face_step_w]].each do |over, step|
              @primitives.load_var(5, step)
              @emitter.emit(ASM.add_reg(over, over, 5))
            end
            @emitter.emit(ASM.bx(14))
          end

          # A row from a stretch's start to its end, in registers: the run of whole stretches, and
          # then the row's last stretch, the pixels left over. Entered with the stretch's start,
          # along, in r0, where the drawn part of the row ends in r2 and the perspective word in r3.
          # There is a run for :every_8_pixels (#emit_whole_stretches) and one for :every_16_pixels
          # (#emit_long_stretches), each only in a game that draws with it (Faces.stretch_runs), so
          # neither pays for telling the two apart.
          #
          # The run goes round once for every eight pixels, all drawn: a turn. A turn's far end is
          # worked out exactly and its eight pixels stepped evenly from the near end, two at a time,
          # as #emit_pixel_pairs does, the pairs written whole. The far end is then the next turn's
          # near end. The first near end is found by the same instructions, written once more ahead
          # of the loop: the run starts a turn before the row's, and that first far end is the first
          # turn's near end.
          #
          # A turn need not start on a pair: one that starts on the right half of a pair keeps its
          # last pixel back, and the next turn's first pixel makes up a pair with it. The first such
          # pixel's other half, before the run, and the last kept back, after it, are read and
          # written back with the half beside them. Every turn of a row starts on the same half of a
          # pair, so each half's pixels end with a jump back to the loop's top of their own, and no
          # branch is taken past the other half's.
          #
          # The row's last stretch is under eight pixels, or under sixteen for :every_16_pixels, to
          # the row's end (#emit_last_stretch). A row held in at its right end has pixels past the
          # drawn part that set its last stretch's length, so that one goes back to +slow+, a
          # stretch at a time, with the near end in its words.
          #
          #   r8, r9 u and v at the turn's start; r4 where it is in the screen's memory; r6 the
          #   picture; r7 the pixel kept back, with its mark above its byte; r5 the turns left;
          #   r10 how far one over the distance was last moved down (#emit_distance_near_last);
          #   r0-r3, r11, r12 and lr the sums
          #
          # +lit+, the shade starts at the run's first pixel and is kept in its word between
          # turns, and r8-r10 hold the shade, its step and the table while a turn's pixels are
          # drawn, so u and v at the far end wait in their words, and so does how far one over the
          # distance was moved.
          #
          # +see_through+, the twin for a picture with see-through pixels: each pair is tested as it
          # is drawn (#emit_run_pair), and a pixel kept back that is see-through is never written.
          def emit_whole_stretches(fast, slow, next_row, lit:, see_through: false)
            even = @emitter.gensym
            top = @emitter.gensym
            odd = @emitter.gensym
            last = @emitter.gensym
            @emitter.place_label(fast)
            @emitter.emit(ASM.sub_reg(5, 2, 0))
            @emitter.emit(ASM.lsr_imm(5, 5, 3)) # how many turns
            @emitter.emit(ASM.lsl_imm(1, 5, 3))
            @emitter.emit(ASM.add_reg(1, 0, 1))
            @primitives.store_var(1, :_face_run_end)
            emit_run_start(even, lit: lit)
            if lit
              # A second copy of the far end's instructions would make the lit routine bigger than
              # it need be, so its loop's first turn is marked, works out the near end and draws
              # nothing.
              @emitter.emit(ASM.orr_imm(7, 7, NEAR_END_UNKNOWN))
            else
              emit_first_near_end
              @emitter.emit(ASM.cmp_imm(5, 0))
              @emitter.emit_branch(:bcond, last, cond: :le)
            end

            @emitter.place_label(top)
            emit_far_end_of_whole_stretch(lit: lit)
            near_end = @emitter.gensym
            if lit
              @emitter.emit(ASM.tst_imm(7, NEAR_END_UNKNOWN))
              @emitter.emit_branch(:bcond, near_end, cond: :ne)
            end
            emit_whole_stretch_steps(lit: lit, shift: 3)
            @emitter.emit(ASM.tst_imm(7, KEPT_BACK))
            @emitter.emit_branch(:bcond, odd, cond: :ne)
            4.times { emit_run_pair(lit: lit, see_through: see_through) }
            emit_next_whole_stretch(top, lit: lit)
            @emitter.emit_branch(:b, last)
            emit_near_end_of_lit_run(near_end, top, last, cond: :gt) if lit
            @emitter.place_label(odd)
            emit_odd_turn_pixels(lit: lit, see_through: see_through)
            emit_next_whole_stretch(top, lit: lit)

            @emitter.place_label(last)
            emit_last_stretch(slow, next_row, lit: lit, see_through: see_through)
          end

          # The run for :every_16_pixels. A stretch of sixteen is two turns. The first works the far
          # end out sixteen pixels on and steps a sixteenth of the way a pixel; the second goes on
          # stepping from where the first stopped and works nothing out, which is what the longer
          # stretch saves: the end of the first's pixels goes straight back to them. Where one over
          # the distance changes fast the stretch is cut in two (Reference#stretch_ends), and each
          # of its turns is one of eight (TURN_AFTER_CUT), as #emit_whole_stretches's are. The row's
          # last stretch of sixteen, cut short by the row's end, is left to the last stretch, unless
          # more than eight pixels of it are drawn and it is cut in two: its first part is then the
          # run's last turn (#emit_run_turns).
          #
          # The registers are #emit_whole_stretches's, but r5, which holds the turns as
          # #emit_run_turns says. +see_through+ as there.
          def emit_long_stretches(fast, slow, next_row, lit:, see_through: false)
            even = @emitter.gensym
            top = @emitter.gensym
            odd = @emitter.gensym
            last = @emitter.gensym
            draw = @emitter.gensym
            cut_turn = @emitter.gensym
            loaded = @emitter.gensym
            @emitter.place_label(fast)
            emit_run_turns
            emit_run_start(even, lit: lit)
            if lit
              # Its first turn too is marked (see #emit_whole_stretches), and is a turn of eight,
              # which steps one turn on, onto the run's start.
              @emitter.emit(ASM.orr_imm(7, 7, NEAR_END_UNKNOWN))
              @emitter.emit(ASM.orr_imm(5, 5, TURN_AFTER_CUT))
            else
              emit_first_near_end
              @emitter.emit(ASM.cmp_imm(5, 0))
              @emitter.emit_branch(:bcond, last, cond: :lt)
            end

            @emitter.place_label(top)
            @emitter.emit(ASM.tst_imm(5, TURN_AFTER_CUT))
            @emitter.emit_branch(:bcond, cut_turn, cond: :ne)
            emit_long_turn(loaded, lit: lit)
            @emitter.place_label(draw)
            @emitter.emit(ASM.tst_imm(7, KEPT_BACK))
            @emitter.emit_branch(:bcond, odd, cond: :ne)
            even_pixels = @emitter.gensym
            @emitter.place_label(even_pixels)
            4.times { emit_run_pair(lit: lit, see_through: see_through) }
            emit_next_long_turn(top, even_pixels, lit: lit)
            @emitter.emit_branch(:b, last)
            near_end = @emitter.gensym
            emit_cut_turn(cut_turn, loaded, near_end, draw, lit: lit)
            emit_near_end_of_lit_run(near_end, top, last, cond: :ge) if lit
            @emitter.place_label(odd)
            emit_odd_turn_pixels(lit: lit, see_through: see_through)
            emit_next_long_turn(top, odd, lit: lit)

            @emitter.place_label(last)
            emit_last_stretch(slow, next_row, lit: lit, see_through: see_through)
          end

          # What both runs do before their loop: the words their turns step, each a turn back (the
          # first turn steps onto the run's start), the picture, where the first pixel is, and the
          # other half of the pair a turn starting on its right half makes up. On to +even+.
          def emit_run_start(even, lit:)
            emit_shade_along(0, 3, 1) if lit
            [%i[_face_over_u _face_left_u _face_step_u _face_stretch_u],
             %i[_face_over_v _face_left_v _face_step_v _face_stretch_v],
             %i[_face_over_w _face_left_w _face_step_w _face_stretch_w]].each do |over, left, step, stretch|
              @primitives.load_var(1, step)
              @emitter.emit(ASM.mul(3, 1, 0))
              @primitives.load_var(2, left)
              @emitter.emit(ASM.add_reg(3, 2, 3))
              @emitter.emit(ASM.lsl_imm(1, 1, 3)) # eight steps, a turn's
              @emitter.emit(ASM.sub_reg(3, 3, 1)) # a turn back: the first turn steps onto the run's start
              @primitives.store_var(3, over)
              @primitives.store_var(1, stretch)
            end
            @primitives.load_var(6, :_face_picture)
            @primitives.load_var(1, :_face_start)
            @emitter.emit(ASM.add_reg(1, 0, 1))
            emit_pixel_address(4, 1)
            @emitter.emit_number(7, 0)
            @emitter.emit(ASM.tst_imm(4, 1))
            @emitter.emit_branch(:bcond, even, cond: :eq)
            @emitter.emit(ASM.sub_imm(4, 4, 1)) # the pair it starts the right half of
            @emitter.emit(ASM.load_halfword(7, 4))
            @emitter.emit(ASM.and_imm(7, 7, 0xFF))
            @emitter.emit(ASM.orr_imm(7, 7, KEPT_BACK))
            @emitter.place_label(even)
          end

          # An unlit run's first near end, ahead of the loop, in r8 and r9.
          def emit_first_near_end
            @primitives.load_var(10, :_face_moved_w)
            emit_far_end_of_whole_stretch(lit: false)
            @emitter.emit(ASM.mov_reg(8, 12))
            @emitter.emit(ASM.mov_reg(9, 14))
          end

          # A turn starting on the right half of a pair: its first pixel makes up the pair kept
          # back, and its last is kept back in turn. +see_through+, the pair the first makes up is
          # tested as any other is, and so is the kept-back one's half.
          def emit_odd_turn_pixels(lit:, see_through: false)
            if see_through
              emit_see_through_run_pixel(12, row: 14, lit: lit)
              emit_kept_back_as_left_half(lit: lit)
              emit_pair_unless_see_through(lit: lit)
              3.times { emit_run_pair(lit: lit, see_through: true) }
              emit_see_through_run_pixel(7, row: 12, lit: lit)
            else
              emit_pair_pixel(14, lit: lit)
              @emitter.emit(ASM.orr_reg_lsl(11, 7, 14, 8))
              @emitter.emit(ASM.store_halfword_post(11, 4, 2))
              3.times { emit_pair(lit: lit) }
              emit_pair_pixel(7, lit: lit)
            end
            @emitter.emit(ASM.orr_imm(7, 7, KEPT_BACK))
          end

          # The turns of an :every_16_pixels run, counted in r5, with what kind of turn comes next
          # in its low bits: the turns left less one, times TURN_COUNTED, and the TURN_ marks. So a
          # run with no turn left is below nought, and taking a turn off is one subtract whose flags
          # say whether one is left. r1 is where the turns end, along, which is kept in its word.
          #
          # Two turns for each whole stretch of sixteen, and one more for a last stretch with more
          # than eight pixels drawn that is cut in two (#emit_branch_unless_fast_change, from one
          # over the distance at its start).
          #
          #   r0 where the run starts, along; r2 where the drawn part ends; r3 and then the sums
          #   with r6 and lr
          def emit_run_turns
            no_last_turn = @emitter.gensym
            @emitter.emit(ASM.sub_reg(5, 2, 0))
            @emitter.emit(ASM.lsr_imm(5, 5, 4)) # how many whole stretches of sixteen
            @emitter.emit(ASM.lsl_imm(1, 5, 4))
            @emitter.emit(ASM.add_reg(1, 0, 1))
            @emitter.emit(ASM.lsl_imm(5, 5, TURN_SHIFT + 1)) # two turns each
            @emitter.emit(ASM.sub_reg(6, 2, 1))
            @emitter.emit(ASM.cmp_imm(6, SPLIT_PIXELS))
            @emitter.emit_branch(:bcond, no_last_turn, cond: :le)
            @primitives.load_var(6, :_face_step_w)
            @emitter.emit(ASM.mul(14, 6, 1))
            @primitives.load_var(3, :_face_left_w)
            @emitter.emit(ASM.add_reg(3, 3, 14)) # one over the distance where the whole stretches end
            @emitter.emit(ASM.lsl_imm(6, 6, 3)) # its change over SPLIT_PIXELS
            emit_branch_unless_fast_change(no_last_turn, 6, 3)
            @emitter.emit(ASM.add_imm(1, 1, SPLIT_PIXELS))
            @emitter.emit(ASM.add_imm(5, 5, TURN_COUNTED))
            @emitter.place_label(no_last_turn)
            @emitter.emit(ASM.sub_imm(5, 5, TURN_COUNTED))
            @primitives.store_var(1, :_face_run_end)
          end

          # What r5 holds in an :every_16_pixels run (#emit_run_turns): the turns left less one,
          # from bit TURN_SHIFT, and below them the marks for the next turn. TURN_STEPPED_ON marks a
          # turn that goes on stepping from the last, the second of an uncut stretch of sixteen;
          # TURN_AFTER_CUT a turn of eight, the second part of a stretch cut in two (or a lit run's
          # first).
          TURN_SHIFT = 3
          TURN_COUNTED = 1 << TURN_SHIFT
          TURN_STEPPED_ON = 2
          TURN_AFTER_CUT = 4

          # The first turn of a stretch of sixteen, at the loop's top (the second of an uncut one
          # never comes back there: #emit_next_long_turn). It loads the stretch's words and asks
          # whether the stretch is cut in two (#emit_branch_unless_fast_change, from its step and
          # one over the distance at its start). Cut, it is a turn of eight, from +loaded+ in
          # #emit_cut_turn, and the next is marked to be one too. Uncut, two turns' steps are added,
          # the far end worked out and a sixteenth of the way a pixel stepped, and on into the
          # pixels below it.
          def emit_long_turn(loaded, lit:)
            uncut = @emitter.gensym
            steps = stretch_step_registers(lit)
            emit_load_stretch_words(lit)
            emit_branch_unless_fast_change(uncut, steps.last, 3)
            @emitter.emit(ASM.orr_imm(5, 5, TURN_AFTER_CUT))
            @emitter.emit_branch(:b, loaded)
            @emitter.place_label(uncut)
            [0, 2, 3].zip(steps).each { |over, step| @emitter.emit(ASM.add_reg_lsl(over, over, step, 1)) }
            @emitter.emit(ASM.orr_imm(5, 5, TURN_STEPPED_ON))
            emit_far_end_from_stepped_words(lit)
            emit_whole_stretch_steps(lit: lit, shift: 4)
          end

          # A turn of eight in an :every_16_pixels run, at +cut_turn+: the mark cleared, the far end
          # a turn on, an eighth of the way a pixel, and on to +draw+. A lit run's first turn goes to
          # +near_end+ instead.
          def emit_cut_turn(cut_turn, loaded, near_end, draw, lit:)
            @emitter.place_label(cut_turn)
            @emitter.emit(ASM.bic_imm(5, 5, TURN_AFTER_CUT))
            emit_far_end_of_whole_stretch(lit: lit, loaded: loaded)
            if lit
              @emitter.emit(ASM.tst_imm(7, NEAR_END_UNKNOWN))
              @emitter.emit_branch(:bcond, near_end, cond: :ne)
            end
            emit_whole_stretch_steps(lit: lit, shift: 3)
            @emitter.emit_branch(:b, draw)
          end

          # Back to +top+ while turns are left; lit, the shade kept in its word and the far end
          # taken back from its words first.
          def emit_next_whole_stretch(top, lit:)
            if lit
              @primitives.store_var(8, :_face_shade)
              @primitives.load_var(8, :_face_far_u)
              @primitives.load_var(9, :_face_far_v)
            end
            @emitter.emit(ASM.subs_imm(5, 5, 1))
            @emitter.emit_branch(:bcond, top, cond: :gt)
          end

          # The turn after the pixels just drawn, in an :every_16_pixels run. The second turn of an
          # uncut stretch of sixteen (TURN_STEPPED_ON) is back to +pixels+, the same half's, at once:
          # its steps, and lit its shade, go on in their registers, and an uncut stretch is whole,
          # so that turn is always left. Any other is back to +top+ while turns are left; lit, the
          # shade kept in its word and the far end taken back from its words first.
          def emit_next_long_turn(top, pixels, lit:)
            @emitter.emit(ASM.tst_imm(5, TURN_STEPPED_ON))
            emit_if(:ne, ASM.bic_imm(5, 5, TURN_STEPPED_ON))
            emit_if(:ne, ASM.sub_imm(5, 5, TURN_COUNTED))
            @emitter.emit_branch(:bcond, pixels, cond: :ne)
            if lit
              @primitives.store_var(8, :_face_shade)
              @primitives.load_var(8, :_face_far_u)
              @primitives.load_var(9, :_face_far_v)
            end
            @emitter.emit(ASM.subs_imm(5, 5, TURN_COUNTED))
            @emitter.emit_branch(:bcond, top, cond: :ge)
          end

          # A lit run's first turn, marked NEAR_END_UNKNOWN, at +near_end+: the far end just worked
          # out is the first turn's near end, so it is kept, the mark cleared, and on to +top+
          # for the first turn, or to +last+ for a row with none. +cond+ is when r5 says a turn
          # is left: above nought counting turns, at least nought counting them less one.
          def emit_near_end_of_lit_run(near_end, top, last, cond:)
            @emitter.place_label(near_end)
            @emitter.emit(ASM.mov_reg(8, 12))
            @emitter.emit(ASM.mov_reg(9, 14))
            @emitter.emit(ASM.bic_imm(7, 7, NEAR_END_UNKNOWN))
            @emitter.emit(ASM.cmp_imm(5, 0))
            @emitter.emit_branch(:bcond, top, cond: cond)
            @emitter.emit_branch(:b, last)
          end

          # The marks the run keeps above the kept-back pixel's byte in r7: that a pixel is kept
          # back, the left half of a pair waiting for its right half, and, lit, that the place at
          # the turn's near end is not worked out yet. A pair is written from its low sixteen
          # bits, so a mark never reaches the screen.
          KEPT_BACK = 0x10000
          NEAR_END_UNKNOWN = 0x20000

          # The far end of the turn: u, v and w over the distance each a turn on, read and written
          # back together, and from them u in r12 and v in lr, exactly. Those two are where
          # #emit_whole_stretch_steps wants them, so nothing moves them on the way. A turn of
          # sixteen's cut in two comes in at +loaded+ with the words read (#emit_long_turn), and an
          # uncut one has a copy of its own of all but the first instructions.
          #
          #   r1 where the words are, r3 the distance; unlit, r11, r12 and lr the steps, and then
          #   r11 and r1 the sums; lit, r10-r12 the steps and then r10 and r11 the sums
          def emit_far_end_of_whole_stretch(lit:, loaded: nil)
            emit_load_stretch_words(lit)
            @emitter.place_label(loaded) if loaded
            [0, 2, 3].zip(stretch_step_registers(lit)).each { |over, step| @emitter.emit(ASM.add_reg(over, over, step)) }
            emit_far_end_from_stepped_words(lit)
          end

          # The far end from the words stepped on in r0, r2 and r3, written back first (see
          # #emit_far_end_of_whole_stretch).
          def emit_far_end_from_stepped_words(lit)
            words = @primitives.var_addr(STEPPED_WORDS.first)
            low, high = spare_pair(lit)
            @emitter.emit(ASM.stmia(1, 0, 2, 3))
            held = WordsBase.new(register: 1, address: words) unless lit
            emit_distance_near_last(3, 10, 11, held: held)
            @emitter.emit(ASM.smull(low, high, 0, 3))
            @emitter.emit(ASM.lsr_imm(low, low, 14))
            @emitter.emit(ASM.orr_reg_lsl(12, low, high, 18)) # u at the far end
            @emitter.emit(ASM.smull(low, high, 2, 3))
            @emitter.emit(ASM.lsr_imm(low, low, 14))
            @emitter.emit(ASM.orr_reg_lsl(14, low, high, 18)) # v at the far end
          end

          # The stepped words read: u, v and w over the distance at the turn's near end in r0, r2
          # and r3, each one's step over a turn in the registers #stretch_step_registers names, and
          # their address in r1.
          def emit_load_stretch_words(lit)
            words = @primitives.var_addr(STEPPED_WORDS.first)
            if ASM.encode_rotated_immediate(words - IWRAM_START)
              @emitter.emit_number(1, IWRAM_START)
              @emitter.emit(ASM.add_imm(1, 1, words - IWRAM_START))
            else
              @emitter.emit_number(1, words)
            end
            @emitter.emit(ASM.ldmia(1, 0, 2, 3, *stretch_step_registers(lit)))
          end

          # Where a turn's steps of u, v and w over the distance are read into.
          def stretch_step_registers(lit) = lit ? [10, 11, 12] : [11, 12, 14]

          # What a turn's eight pixels step from: u and v at its near end and an eighth of the way
          # to its far end (r12 and lr; a sixteenth, +shift+ 4, for the first turn of an uncut
          # stretch of sixteen), each moved up for the picture's repeat, in r0-r3 as
          # #emit_pair_pixel reads them. The far end is left as the next turn's near end, in r8
          # and r9.
          #
          # +lit+, the pixels are shaded as #emit_shaded_number does, so r8-r10 take the shade, its
          # step and the table, and the far end waits in its words. Their address is built in r1,
          # since r12 holds u.
          def emit_whole_stretch_steps(lit:, shift:)
            across, down = spare_pair(lit)
            if lit
              base = WordsBase.new(register: 1, address: IWRAM_START)
              @emitter.emit_number(1, IWRAM_START)
              @emitter.emit(ASM.str_offset(12, 1, base.offset_to(@primitives.var_addr(:_face_far_u))))
              @emitter.emit(ASM.str_offset(14, 1, base.offset_to(@primitives.var_addr(:_face_far_v))))
            end
            emit_stretch_step(across, 12, 8, shift)
            emit_stretch_step(down, 14, 9, shift)
            emit_moved_up(0, 8, :across)
            @emitter.emit(ASM.mov_reg(8, 12))
            emit_moved_up(2, across, :across)
            emit_moved_up(3, down, :down)
            emit_moved_up(1, 9, :down)
            @emitter.emit(ASM.mov_reg(9, 14))
            emit_load_shade if lit
          end

          # The two registers free between a whole stretch's far end and its pixels, which take
          # its two long multiplies' halves and then its two steps: lit, r10 and r11 are free until
          # the shading's table goes in r10; unlit, r10 holds how far one over the distance was
          # moved, and r1 is free once the far end's words are read.
          def spare_pair(lit) = lit ? [10, 11] : [11, 1]

          # +into+ = +from+ moved up for the picture's repeat (see #emit_pixel_pairs): 16 less
          # log2 of its width (+axis+ :across) or of its height (:down). The shift is written in as
          # the routine starts (#emit_patch_routine), so it is one instruction and no load.
          #
          # Must be emitted as a picture of one pixel's shift, 16: the pixels' written-in shifts
          # start as that picture's (all nought), and the patch routine passes over these whenever
          # the first pixel's already match.
          def emit_moved_up(into, from, axis)
            @moved_up_patches << [@emitter.pos, axis]
            @emitter.emit(ASM.lsl_imm(into, from, 16))
          end

          # A lit pair loop's shade in r8, its step a pixel in r9 and the shading's table in r10.
          def emit_load_shade
            @primitives.load_var(8, :_face_shade)
            @primitives.load_var(9, :_face_step_shade)
            @primitives.load_var(10, :_face_shading)
          end

          # The row's last stretch, after its whole ones: the pixels from where those ended to the
          # row's end, under a stretch. Its far end is the row's end, worked out exactly
          # (SAMPLE_ROUTINE), and its step the way there divided by its length, so one pixel alone
          # needs neither: it is the near end's. Then on to +next_row+.
          #
          # A pixel at a time, each making up a pair with the one kept back or kept back itself,
          # and the last one kept back written with the half beside it.
          #
          # A row held in at its right end has a last stretch longer than its drawn part, so its
          # step is not found from the pixels left. With drawn pixels left it goes to +slow+, the
          # kept-back pixel written first and the near end in its words.
          #
          #   r0 where the whole stretches ended, along; r1 where the drawn part ends; r2 the
          #   row's length; r5 the pixels left; r10 and r11 what the far end's routine would lose
          #
          # +see_through+, each pair made up is tested as the run's are (#emit_last_stretch_pixel).
          def emit_last_stretch(slow, next_row, lit:, see_through: false)
            held_in = @emitter.gensym
            steps_known = @emitter.gensym
            pixel = @emitter.gensym
            finished = @emitter.gensym
            @primitives.load_var(0, :_face_run_end)
            @primitives.load_var(1, :_face_past)
            @primitives.load_var(2, :_face_span_count)
            @emitter.emit(ASM.cmp_reg(1, 2))
            @emitter.emit_branch(:bcond, held_in, cond: :lt)
            @emitter.emit(ASM.sub_reg(5, 2, 0))
            @emitter.emit(ASM.cmp_imm(5, 1))
            @emitter.emit_branch(:bcond, finished, cond: :lt)
            @emitter.emit_branch(:bcond, steps_known, cond: :eq)
            @emitter.emit(ASM.mov_reg(10, 4))
            @emitter.emit(ASM.mov_reg(11, 7))
            @emitter.emit(ASM.mov_reg(0, 2))
            @emitter.emit_branch(:bl, SAMPLE_ROUTINE)
            @emitter.emit(ASM.mov_reg(4, 10))
            @emitter.emit(ASM.mov_reg(7, 11))
            @emitter.emit(ASM.mov_reg(11, 1)) # v at the far end
            @primitives.load_var(6, :_face_picture)
            @primitives.load_var(5, :_face_span_count)
            @primitives.load_var(2, :_face_run_end)
            @emitter.emit(ASM.sub_reg(5, 5, 2))
            @emitter.emit(ASM.sub_reg(1, 0, 8))
            @emitter.emit(ASM.mov_reg(0, 5))
            @emitter.emit_branch(:bl, DIVIDE_ROUTINE)
            @emitter.emit(ASM.mov_reg(10, 0)) # the step across
            @emitter.emit(ASM.sub_reg(1, 11, 9))
            @emitter.emit(ASM.mov_reg(0, 5))
            @emitter.emit_branch(:bl, DIVIDE_ROUTINE)
            @emitter.emit(ASM.mov_reg(3, 0)) # the step down
            @emitter.emit(ASM.mov_reg(2, 10))
            @emitter.place_label(steps_known)
            emit_moved_up(0, 8, :across)
            emit_moved_up(2, 2, :across)
            emit_moved_up(1, 9, :down)
            emit_moved_up(3, 3, :down)
            emit_load_shade if lit
            @emitter.place_label(pixel)
            emit_last_stretch_pixel(lit: lit, see_through: see_through)
            @emitter.emit(ASM.subs_imm(5, 5, 1))
            @emitter.emit_branch(:bcond, pixel, cond: :ne)
            @emitter.place_label(finished)
            emit_kept_back_pixel(lit: lit, see_through: see_through)
            @emitter.emit_branch(:b, next_row)

            @emitter.place_label(held_in)
            emit_kept_back_pixel(lit: lit, see_through: see_through)
            @emitter.emit(ASM.cmp_reg(0, 1))
            @emitter.emit_branch(:bcond, next_row, cond: :ge)
            @primitives.store_var(0, :_face_along)
            @primitives.store_var(8, :_face_near_u)
            @primitives.store_var(9, :_face_near_v)
            @emitter.emit_branch(:b, slow)
          end

          # One pixel of the last stretch: it makes up a pair with the one kept back, or is kept
          # back itself. +see_through+, the pair is tested as the run's are, the pixel worked out
          # into r12 for it.
          def emit_last_stretch_pixel(lit:, see_through:)
            unless see_through
              emit_pair_pixel(14, lit: lit)
              @emitter.emit(ASM.tst_imm(7, KEPT_BACK))
              emit_if(:ne, ASM.orr_reg_lsl(11, 7, 14, 8))
              emit_if(:ne, ASM.store_halfword_post(11, 4, 2))
              @emitter.emit(ASM.mov_imm_cond(:ne, 7, 0))
              emit_if(:eq, ASM.orr_imm(7, 14, KEPT_BACK))
              return
            end

            kept = @emitter.gensym
            emit_see_through_run_pixel(12, row: 14, lit: lit)
            @emitter.emit(ASM.tst_imm(7, KEPT_BACK))
            emit_if(:eq, ASM.orr_imm(7, 12, KEPT_BACK))
            @emitter.emit_branch(:bcond, kept, cond: :eq)
            emit_kept_back_as_left_half(lit: lit)
            emit_pair_unless_see_through(lit: lit)
            @emitter.emit_number(7, 0)
            @emitter.place_label(kept)
          end

          # The pixel kept back, if one is, written with the half of its pair beside it. lr is
          # spare. +see_through+, one that is see-through is not written.
          def emit_kept_back_pixel(lit: false, see_through: false)
            if see_through
              if lit
                @emitter.emit(ASM.tst_imm(7, SEE_THROUGH_MARK))
                emit_if(:ne, ASM.bic_imm(7, 7, KEPT_BACK))
              else
                @emitter.emit(ASM.and_imm(14, 7, 0xFF))
                emit_cmp_clear(14)
                emit_if(:eq, ASM.bic_imm(7, 7, KEPT_BACK))
              end
            end
            @emitter.emit(ASM.tst_imm(7, KEPT_BACK))
            emit_if(:ne, ASM.load_halfword(14, 4))
            emit_if(:ne, ASM.and_imm(14, 14, 0xFF00))
            emit_if(:ne, ASM.orr_reg(14, 14, 7))
            emit_if(:ne, ASM.store_halfword(14, 4))
          end

          # +into+ = (+far+ - +near+) / 2**+shift+, truncated toward nought as Int32.div does: a shift
          # down, after adding one less than 2**+shift+ to a number below nought, which the subtract's
          # own flags tell.
          def emit_stretch_step(into, far, near, shift)
            emit_setting_flags(ASM.sub_reg(into, far, near))
            emit_if(:mi, ASM.add_imm(into, into, (1 << shift) - 1))
            @emitter.emit(ASM.asr_imm(into, into, shift))
          end

          # +reg+ = the distance for one over it in +reg+ (IR::Reciprocals.distance): held to the
          # least, its leading eleven bits found by halving the shift five times (+moved+ counts it),
          # and the table's entry for them moved back down. +spare+ is a spare register.
          def emit_distance(reg, moved, spare)
            emit_leading_bits(reg, moved, spare)
            @emitter.emit(ASM.sub_imm(spare, reg, IR::Reciprocals::LEADING))
            emit_distance_from_table(reg, moved, spare)
          end

          # +reg+ held to the least one over a distance there is, and moved down to its leading
          # eleven bits, +moved+ counting how far.
          def emit_leading_bits(reg, moved, spare)
            @emitter.emit_number(spare, IR::Reciprocals::LEAST)
            @emitter.emit(ASM.cmp_reg(reg, spare))
            @emitter.emit(ASM.mov_reg_cond(:lt, reg, spare))
            @emitter.emit_number(moved, 0)
            # It has more than eleven bits left when moving it down past them leaves something,
            # which the move itself tells (it is above nought here, so no sign comes into it).
            [16, 8, 4, 2, 1].each do |shift|
              emit_setting_flags(ASM.lsr_imm(spare, reg, 10 + shift))
              emit_if(:ne, ASM.lsr_imm(reg, reg, shift))
              @emitter.emit(ASM.add_imm_cond(:ne, moved, moved, shift))
            end
          end

          # +reg+ = the table's entry numbered in +spare+ (the leading bits, less the first entry's),
          # moved back down by +moved+ less the two places the table is short by. +moved+ is left
          # two less, unless it is +held+ (see #emit_distance_near_last), when +spare+ takes that.
          def emit_distance_from_table(reg, moved, spare, held: nil)
            if held
              @emitter.emit(ASM.ldr_offset(reg, held.register, held.offset_to(@primitives.var_addr(:_face_distances))))
            else
              @primitives.load_var(reg, :_face_distances)
            end
            @emitter.emit(ASM.ldr_reg_lsl(reg, reg, spare, 2))
            less = held ? spare : moved
            @emitter.emit(ASM.sub_imm(less, moved, 2))
            @emitter.emit(ASM.mov_reg_lsr_reg(reg, reg, less))
          end

          # The least a one over a distance is moved down to its leading eleven bits: what the
          # least one there is, is moved.
          LEAST_MOVED = IR::Reciprocals::LEAST.bit_length - 11

          # #emit_distance for a run of numbers close to one another, as one over the distance is
          # from one stretch of a row to the next: tried first with how far the last one was moved
          # down, which is kept in a word. That is right when it leaves eleven bits with the top
          # one set, and nearly always does; only otherwise is it searched for and kept.
          #
          # The word never holds less than LEAST_MOVED (a face in perspective starts it there, and
          # a search leaves no less), so a number under the least there is never passes the try,
          # and is held to the least by the search as it must be.
          #
          # Held in +moved+ for a whole run (+held+ given, a WordsBase), the word is read before
          # the run and written only when a search changes it, and +moved+ is left as it was. The
          # table's address is then read through the WordsBase rather than built.
          def emit_distance_near_last(reg, moved, spare, held: nil)
            found = @emitter.gensym
            @primitives.load_var(moved, :_face_moved_w) unless held
            @emitter.emit(ASM.mov_reg_lsr_reg(spare, reg, moved))
            @emitter.emit(ASM.sub_imm(spare, spare, IR::Reciprocals::LEADING))
            @emitter.emit(ASM.cmp_imm(spare, IR::Reciprocals::LEADING))
            @emitter.emit_branch(:bcond, found, cond: :lo)
            emit_leading_bits(reg, moved, spare)
            @primitives.store_var(moved, :_face_moved_w)
            @emitter.emit(ASM.sub_imm(spare, reg, IR::Reciprocals::LEADING))
            @emitter.place_label(found)
            emit_distance_from_table(reg, moved, spare, held: held)
          end

          # A register holding the address of one of the routine's words, through which the
          # others near it are read without building their addresses.
          WordsBase = Data.define(:register, :address) do
            # How far +word_address+ is from the one held, refused past the 4095 bytes a load's
            # offset reaches.
            def offset_to(word_address)
              offset = word_address - address
              return offset if offset.abs <= 0xFFF

              raise LoweringError, "The routine that fills a face lost track of where its words are. " \
                                   "This is a fault in VBlank, not in the game."
            end
          end

          SPAN_PIXELS_ROUTINE = DerivedNames.sub_label(ROUTINE, :span_pixels)
          SAMPLE_ROUTINE = DerivedNames.sub_label(ROUTINE, :place_in_perspective)
          DIVIDE_ROUTINE = DerivedNames.sub_label(ROUTINE, :divide_by_count)

          # The pixels of a stretch of a row, stepping evenly: r0 u, r1 v, r2 the step across, r3
          # the step down, r4 where the first is in the screen's memory, r5 how many (one or more).
          # Called with its return in lr; uses every register but the stack.
          def emit_span_pixels_routine
            direct = @emitter.gensym
            done = @emitter.gensym
            @emitter.place_label(SPAN_PIXELS_ROUTINE)
            @emitter.emit(ASM.push(14))
            @primitives.load_var(11, :_face_direct)
            emit_load_picture
            @emitter.emit(ASM.cmp_imm(11, 0))
            @emitter.emit_branch(:bcond, direct, cond: :ne)
            emit_pixels
            @emitter.emit_branch(:b, done)
            @emitter.place_label(direct)
            emit_direct_pixels
            @emitter.place_label(done)
            @emitter.emit(ASM.pop(15))
          end

          # Where on the picture, in perspective, +along+ (r0) pixels into the row
          # (Reference#place_in_perspective): u over the distance, v over it and one over it, each
          # stepped from the row's left end, and the distance found from the last in the table of
          # IR::Reciprocals (its leading eleven bits, found by halving the shift five times), which
          # times the first two gives u and v. Answers u in r0 and v in r1.
          #
          #   r6 u over the distance, r7 v over it, r4 one over it, r5 how far it was moved down
          def emit_place_in_perspective_routine
            @emitter.place_label(SAMPLE_ROUTINE)
            [[6, :_face_step_u, :_face_left_u], [7, :_face_step_v, :_face_left_v],
             [4, :_face_step_w, :_face_left_w]].each do |into, step, left|
              @primitives.load_var(1, step)
              @emitter.emit(ASM.mul(into, 1, 0))
              @primitives.load_var(1, left)
              @emitter.emit(ASM.add_reg(into, 1, into))
            end
            emit_distance(4, 5, 1)
            emit_mul_fix(0, 6, 4, 14)
            emit_mul_fix(1, 7, 4, 14)
            @emitter.emit(ASM.bx(14))
          end

          # +instruction+ made to run only under +cond+.
          def emit_if(cond, instruction)
            word = instruction.unpack1("V")
            @emitter.emit([(word & 0x0FFFFFFF) | (ASM.resolve_cond(cond) << 28)].pack("V"))
          end

          # +instruction+ made to set the flags from its answer as well.
          def emit_setting_flags(instruction)
            @emitter.emit([instruction.unpack1("V") | 0x00100000].pack("V"))
          end

          # +step+ = (+right+ - +left+) divided by the row's count, truncated toward nought as
          # Int32.div does.
          def emit_span_step(right, left, step)
            @primitives.load_var(1, right)
            @primitives.load_var(2, left)
            @emitter.emit(ASM.sub_reg(1, 1, 2))
            @primitives.load_var(0, :_face_span_count)
            @emitter.emit_branch(:bl, DIVIDE_ROUTINE)
            @primitives.store_var(0, step)
          end

          def emit_load_picture
            @primitives.load_var(6, :_face_picture)
            @primitives.load_var(7, :_face_mask_x)
            @primitives.load_var(8, :_face_mask_y)
            @primitives.load_var(9, :_face_shift)
            @primitives.load_var(10, :_face_clear)
          end

          # r0 = r1 divided by the count in r0 (one or more), truncated toward nought as Int32.div
          # does: how far a row, or a stretch of one, steps a pixel.
          #
          # A row is seldom wide, so most counts are under RECIPROCALS, and for those the divide is
          # a multiply: the number's size times 2**32 / count rounded up, top half kept. Rounding up
          # makes that the true quotient or one more (the excess is the number times under one
          # 2**32th of the count, so under one), and one more is seen by multiplying back. A count
          # of one is the number itself; a wider row takes the shared divide routine.
          #
          # An edge's height takes it too (#emit_edge_body): in sixteenths of a pixel, so an edge
          # under 32 rows high is in the table.
          #
          # The table's way calls nothing, so it goes back by the link register as it is and keeps
          # no return on the stack; only the wide count's call of the shared routine saves it.
          #
          #   r0 the count, r1 the number, r2 its size, r3 the reciprocal and then the product's
          #   top half, r12 its bottom half; r4-r11 are kept
          def emit_divide_by_count_routine
            routine = @emitter.gensym
            @emitter.place_label(DIVIDE_ROUTINE)
            @emitter.emit(ASM.cmp_imm(0, 1))
            @emitter.emit(ASM.mov_reg_cond(:eq, 0, 1))
            emit_if(:eq, ASM.bx(14))
            @emitter.emit(ASM.cmp_imm(0, RECIPROCALS))
            @emitter.emit_branch(:bcond, routine, cond: :ge)
            @primitives.load_var(3, :_face_reciprocals)
            @emitter.emit(ASM.ldr_reg_lsl(3, 3, 0, 2))
            @emitter.emit(ASM.mov_reg(2, 1))
            @emitter.emit(ASM.cmp_imm(1, 0))
            @emitter.emit(ASM.rsb_imm_cond(:lt, 2, 1, 0))
            @emitter.emit(ASM.umull(12, 3, 2, 3))
            @emitter.emit(ASM.mul(12, 3, 0))
            @emitter.emit(ASM.cmp_reg(12, 2))
            @emitter.emit(ASM.sub_imm_cond(:hi, 3, 3, 1))
            @emitter.emit(ASM.cmp_imm(1, 0))
            @emitter.emit(ASM.rsb_imm_cond(:lt, 3, 3, 0))
            @emitter.emit(ASM.mov_reg(0, 3))
            @emitter.emit(ASM.bx(14))
            @emitter.place_label(routine)
            @emitter.emit(ASM.push(14))
            @divide.emit_call_divide_routine
            @emitter.emit(ASM.pop(15))
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
            @emitter.emit(ASM.asr_imm(into, 1, 16))
            @emitter.emit(ASM.and_reg(into, into, 8))
            @emitter.emit(ASM.mov_reg_lsl_reg(into, into, 9))
            @emitter.emit(ASM.asr_imm(12, 0, 16))
            @emitter.emit(ASM.and_reg(12, 12, 7))
            @emitter.emit(ASM.orr_reg(into, into, 12))
          end

          # The pixels of a span on the tear-free screen, two at a time: by one loop when the
          # picture has no see-through pixel, and by another when it has.
          #
          #   r0 u, r1 v, r2 the step across, r3 the step down, r4 the pixel's byte on the page,
          #   r5 how many are left, r6 the picture's palette numbers, r7 and r8 the masks that
          #   make it repeat, r9 the shift to a row, r10 the see-through number, r11, r12 and lr
          #   spare
          #
          # A lit fill has a copy of each of its own, each pixel's palette number then looked up in
          # the shading's table at its level, so an unlit fill pays nothing for it.
          def emit_pixels
            done = @emitter.gensym
            lit_pixels = @emitter.gensym
            if @lit
              @primitives.load_var(11, :_face_shading)
              @emitter.emit(ASM.cmp_imm(11, 0))
              @emitter.emit_branch(:bcond, lit_pixels, cond: :ne)
            end
            emit_both_pixel_pair_loops(done, lit: false)
            if @lit
              @emitter.emit_branch(:b, done)
              @emitter.place_label(lit_pixels)
              emit_both_pixel_pair_loops(done, lit: true)
            end
            @emitter.place_label(done)
          end

          # The pair loop for a picture with no see-through pixel and the one for a picture with
          # some, each pixel shaded when +lit+.
          #
          # The two loops share their ends, since the routine has only so much room in the quick
          # memory: what both start from, the pixel a span starts with on the right half of a pair,
          # and the one it ends with on the left half (+last+). Each of those pixels is held against
          # the see-through number, which for a picture with none is a number no pixel is.
          def emit_both_pixel_pair_loops(done, lit:)
            even = @emitter.gensym
            see_through = @emitter.gensym
            last = @emitter.gensym
            # Lit, the shading's table takes r10, so the see-through number is in r7 until the count.
            clear = lit ? 7 : 10
            emit_pair_loop_setup(lit: lit)
            @primitives.load_var(clear, :_face_clear) if lit
            @emitter.emit(ASM.tst_imm(4, 1))
            @emitter.emit_branch(:bcond, even, cond: :eq)
            emit_lone_pixel(:high, lit: lit, clear: clear)
            @emitter.emit(ASM.subs_imm(5, 5, 1))
            @emitter.emit_branch(:bcond, done, cond: :eq)
            @emitter.place_label(even)
            @emitter.emit(ASM.add_imm(11, clear, 1)) # NO_CLEAR is -1
            @emitter.emit(ASM.cmp_imm(11, 0))
            @emitter.emit_branch(:bcond, see_through, cond: :ne)
            emit_pixel_pairs(done, last, lit: lit)
            @emitter.place_label(see_through)
            emit_see_through_pixel_pairs(last, lit: lit)
          end

          # A picture with see-through pixels, a pair at a time too. A grate or a door with gaps is
          # mostly runs: bars that are all drawn and gaps that are all see-through. So the two
          # pixels of a pair are worked out as #emit_pixel_pairs works them out, and then:
          #
          #   - neither is see-through: the pair is written whole, as there, for two compares more;
          #   - both are: nothing is written, and the pair is passed over;
          #   - one is: the pair is read from video memory, the drawn half put in, and written back.
          #     Only a pair an edge of a bar falls inside pays those trips to video memory, where a
          #     pixel at a time every drawn pixel paid them.
          #
          # The loop counts pixels, two a turn, so what is left at its end says whether a last
          # pixel stands alone. That frees a register a lit fill needs: its shade, its step and its
          # table take r8, r9 and r10, so the see-through number is in r5 there, where the count was.
          #
          #   r7 the pixels left, less two; r10 the see-through number (lit: r5); r11 and lr the two
          #   pixels, r12 spare
          #
          # LIT, a pixel's number is looked up in the shading's table before the pair is looked at,
          # and no number is left to mean see-through. So a see-through pixel is marked with a bit
          # above the byte (SEE_THROUGH_MARK), which no palette number has.
          #
          # +last+ is placed at the pixel a span ends with on the left half of a pair, which the
          # other loop jumps to as well, with the see-through number where this one keeps it.
          def emit_see_through_pixel_pairs(last, lit: false)
            pairs = @emitter.gensym
            tail = @emitter.gensym
            mixed = @emitter.gensym
            counted = @emitter.gensym
            past = @emitter.gensym
            clear = lit ? 5 : 10
            @emitter.emit(ASM.sub_imm(7, 5, 2))
            @primitives.load_var(5, :_face_clear) if lit
            @emitter.emit(ASM.cmp_imm(7, 0))
            @emitter.emit_branch(:bcond, tail, cond: :lt)
            @emitter.place_label(pairs)
            emit_see_through_pair(mixed, clear, lit: lit)
            @emitter.place_label(counted)
            @emitter.emit(ASM.subs_imm(7, 7, 2))
            @emitter.emit_branch(:bcond, pairs, cond: :ge)

            # What is left is two less than nought for none and one less for a pixel on its own: a
            # span ending on the left half of a pair.
            @emitter.place_label(tail)
            @emitter.emit(ASM.tst_imm(7, 1))
            @emitter.emit_branch(:bcond, past, cond: :eq)
            @emitter.place_label(last)
            emit_lone_pixel(:low, lit: lit, clear: clear)
            @emitter.emit_branch(:b, past)

            @emitter.place_label(mixed)
            emit_pair_with_see_through_pixel(counted, clear, lit: lit)
            @emitter.place_label(past)
          end

          # The bit a lit fill marks a see-through pixel with, above the byte a palette number is.
          SEE_THROUGH_MARK = 0x100

          # Two pixels side by side, written as their pair when neither is see-through, and the
          # pair after it next; a pair with a see-through pixel goes to +mixed+.
          def emit_see_through_pair(mixed, clear, lit:)
            if lit
              [11, 14].each do |into|
                emit_pair_pixel(into)
                @emitter.emit(ASM.cmp_reg(into, clear))
                emit_shaded_number(into) # changes no flag
                emit_if(:eq, ASM.orr_imm(into, into, SEE_THROUGH_MARK))
              end
              @emitter.emit(ASM.orr_reg(12, 11, 14))
              @emitter.emit(ASM.tst_imm(12, SEE_THROUGH_MARK))
              @emitter.emit_branch(:bcond, mixed, cond: :ne)
            else
              emit_pair_pixel(11)
              emit_pair_pixel(14)
              @emitter.emit(ASM.cmp_reg(11, clear))
              emit_if(:ne, ASM.cmp_reg(14, clear))
              @emitter.emit_branch(:bcond, mixed, cond: :eq)
            end
            @emitter.emit(ASM.orr_reg_lsl(11, 11, 14, 8))
            @emitter.emit(ASM.store_halfword_post(11, 4, 2))
          end

          # A pair with a see-through pixel: passed over when both are, and otherwise read from
          # video memory, the drawn half put in, and written back. Then on to +counted+.
          def emit_pair_with_see_through_pixel(counted, clear, lit:)
            if lit
              @emitter.emit(ASM.and_reg(12, 11, 14))
              @emitter.emit(ASM.tst_imm(12, SEE_THROUGH_MARK))
              @emitter.emit(ASM.add_imm_cond(:ne, 4, 4, 2))
              @emitter.emit_branch(:bcond, counted, cond: :ne)
              @emitter.emit(ASM.load_halfword(12, 4))
              @emitter.emit(ASM.tst_imm(11, SEE_THROUGH_MARK))
              left_see_through = :ne
              right_see_through = :eq
            else
              @emitter.emit(ASM.cmp_reg(11, clear))
              emit_if(:eq, ASM.cmp_reg(14, clear))
              @emitter.emit(ASM.add_imm_cond(:eq, 4, 4, 2))
              @emitter.emit_branch(:bcond, counted, cond: :eq)
              @emitter.emit(ASM.load_halfword(12, 4))
              @emitter.emit(ASM.cmp_reg(11, clear))
              left_see_through = :eq
              right_see_through = :ne
            end
            emit_if(left_see_through, ASM.and_imm(12, 12, 0xFF))
            emit_if(left_see_through, ASM.orr_reg_lsl(12, 12, 14, 8))
            emit_if(right_see_through, ASM.and_imm(12, 12, 0xFF00))
            emit_if(right_see_through, ASM.orr_reg(12, 12, 11))
            @emitter.emit(ASM.store_halfword_post(12, 4, 2))
            @emitter.emit_branch(:b, counted)
          end

          # A picture with no see-through pixel covers every pixel of the span, so two pixels side
          # by side are worked out together and written as one pair. Video memory takes nothing
          # smaller than a pair, so a pixel written alone has to read its pair, put its half in and
          # write it back: three trips to video memory for every pixel, against one for two.
          #
          # Where on the picture, in fewer steps. The picture repeats, so of u only its whole part
          # held to the picture's width matters ((u >> 16) & (width - 1)), and that is bits 16 up to
          # 16 + log2(width) of u. Moved up to the top of the word (u << (16 - log2 width)) they are
          # the word's top bits: one shift down reads them, held to the width for nothing, because
          # whatever was above them has fallen off the top. Adding the step moved up the same way
          # keeps them exactly the bits adding the plain step would have made. So is v. A pixel is
          # then two instructions and a load: add the pixel across to the picture's start, take the
          # row from v, and load from the start plus the row moved up a row's width.
          #
          # Those shifts are the picture's, and this code runs in work memory. An instruction's shift
          # is a number inside it, and the picture is only known as the game runs, so before the
          # rows the routine writes the picture's three shifts into the loop's own instructions
          # (#emit_patch_routine). That is what the routine being copied into the quick memory
          # allows: the cartridge cannot be written, and the quick memory can. The other way, a
          # shift held in a register, costs a cycle more each time, three a pixel.
          #
          #   r7 the pairs left; r8 log2 of the picture's height; r11, r12 and lr the two pixels and a row
          #
          # LIT (+lit+), r8 is the shade instead, r9 its step a pixel and r10 the shading's table,
          # and the lone pixels read the picture's shifts from memory.
          #
          # What it starts from, and the pixel a span starts with on the right half of a pair, are
          # behind it (#emit_both_pixel_pair_loops); the pixel a span ends with on the left
          # half is at +last+, in the other loop.
          def emit_pixel_pairs(done, last, lit: false)
            pairs = @emitter.gensym
            tail = @emitter.gensym

            # The pairs, two to a turn of the loop, so the loop's own count and jump are paid once
            # for four pixels. An odd number of pairs starts at the second of the two.
            second = @emitter.gensym
            @emitter.emit(ASM.lsr_imm(7, 5, 1)) # how many pairs
            @emitter.emit(ASM.cmp_imm(7, 0))
            @emitter.emit_branch(:bcond, tail, cond: :eq)
            @emitter.emit(ASM.add_imm(7, 7, 1))
            @emitter.emit(ASM.tst_imm(7, 1)) # an odd number of pairs leaves (pairs + 1) even
            @emitter.emit(ASM.lsr_imm(7, 7, 1))
            @emitter.emit_branch(:bcond, second, cond: :eq)
            @emitter.place_label(pairs)
            emit_pair(lit: lit)
            @emitter.place_label(second)
            emit_pair(lit: lit)
            @emitter.emit(ASM.subs_imm(7, 7, 1))
            @emitter.emit_branch(:bcond, pairs, cond: :ne)

            # A span ending on the left half of a pair: that pixel on its own. Lit, the other loop
            # keeps the see-through number where the count is here.
            @emitter.place_label(tail)
            @emitter.emit(ASM.tst_imm(5, 1))
            @emitter.emit_branch(:bcond, done, cond: :eq)
            @primitives.load_var(5, :_face_clear) if lit
            @emitter.emit_branch(:b, last)
          end

          # What a pair loop starts from: u, v and their steps moved up for the picture's repeat
          # (see #emit_pixel_pairs), r8 log2 of the picture's height, and lit, the shade in r8, its
          # step a pixel in r9 and the shading's table in r10.
          def emit_pair_loop_setup(lit:)
            @primitives.load_var(8, :_face_rows_shift)
            @emitter.emit(ASM.rsb_imm(11, 9, 16)) # u and its step moved up 16 - log2 width...
            @emitter.emit(ASM.mov_reg_lsl_reg(0, 0, 11))
            @emitter.emit(ASM.mov_reg_lsl_reg(2, 2, 11))
            @emitter.emit(ASM.rsb_imm(11, 8, 16)) # ...and v and its step 16 - log2 height
            @emitter.emit(ASM.mov_reg_lsl_reg(1, 1, 11))
            @emitter.emit(ASM.mov_reg_lsl_reg(3, 3, 11))
            return unless lit

            @primitives.load_var(8, :_face_shade)
            @primitives.load_var(9, :_face_step_shade)
            @primitives.load_var(10, :_face_shading)
          end

          # Two pixels side by side, written as their pair, and the pair after it next.
          def emit_pair(lit: false)
            emit_pair_pixel(11, lit: lit)
            emit_pair_pixel(14, lit: lit)
            @emitter.emit(ASM.orr_reg_lsl(11, 11, 14, 8))
            @emitter.emit(ASM.store_halfword_post(11, 4, 2))
          end

          # One pixel of a pair into +into+, and u and v a step on. Its three shifts are written in
          # as the routine starts, so each is emitted as nought and its place noted. +row+ is the
          # register the picture's row is found in, r12 unless given.
          def emit_pair_pixel(into, lit: false, row: 12)
            @span_patches << [@emitter.pos, :across]
            @emitter.emit(ASM.add_reg_lsr(into, 6, 0, 0))
            @span_patches << [@emitter.pos, :down]
            @emitter.emit(ASM.lsr_imm(row, 1, 32))
            @span_patches << [@emitter.pos, :row]
            @emitter.emit(ASM.ldrb_reg_lsl(into, into, row, 0))
            @emitter.emit(ASM.add_reg(0, 0, 2))
            @emitter.emit(ASM.add_reg(1, 1, 3))
            emit_shaded_number(into, spare: row) if lit
          end

          # LIT: the palette number in +into+ made the one its colour becomes at the shade in r8,
          # from the shading's table in r10 (a row of 256 a level), and the shade a step on (r9).
          # Four instructions, one of them a load. +spare+ (r12 unless given) is spare.
          def emit_shaded_number(into, spare: 12)
            @emitter.emit(ASM.lsr_imm(spare, 8, 16))
            @emitter.emit(ASM.orr_reg_lsl(spare, into, spare, 8))
            @emitter.emit(ASM.ldrb_reg(into, 10, spare))
            @emitter.emit(ASM.add_reg(8, 8, 9))
          end

          # A pair in a run of whole stretches (#emit_whole_stretches, #emit_long_stretches): for a
          # picture with no see-through pixel written whole (#emit_pair); for one with some
          # (+see_through+) tested as #emit_see_through_pixel_pairs tests its pairs, with no
          # register to spare. The run holds every register, so the see-through number is written
          # into the compares themselves as the routine starts (#emit_cmp_clear), and a pair
          # with a see-through pixel is a call (#emit_see_through_pair_routine): a pair with none
          # pays three instructions for the test, two compares and the call not made.
          #
          #   r11 and r12 the two pixels, lr spare until the call takes it
          def emit_run_pair(lit:, see_through:)
            return emit_pair(lit: lit) unless see_through

            emit_see_through_run_pixel(11, row: 12, lit: lit)
            emit_see_through_run_pixel(12, row: 14, lit: lit)
            emit_pair_unless_see_through(lit: lit)
          end

          # One pixel of a see-through picture's pair into +into+, +row+ spare. Lit, it is shaded,
          # and marked SEE_THROUGH_MARK when its palette number was the see-through one.
          def emit_see_through_run_pixel(into, row:, lit:)
            emit_pair_pixel(into, row: row)
            return unless lit

            emit_cmp_clear(into)
            emit_shaded_number(into, spare: row) # changes no flag
            emit_if(:eq, ASM.orr_imm(into, into, SEE_THROUGH_MARK))
          end

          # The pixel kept back in r7 as the left half of a pair, in r11, without the run's marks:
          # unlit its byte, lit its byte and its SEE_THROUGH_MARK.
          def emit_kept_back_as_left_half(lit:)
            @emitter.emit(lit ? ASM.bic_imm(11, 7, KEPT_BACK) : ASM.and_imm(11, 7, 0xFF))
          end

          # The pair in r11 and r12 written whole when neither is see-through, and the pair after it
          # next; otherwise left to the routine for a pair with a see-through pixel.
          def emit_pair_unless_see_through(lit:)
            if lit
              @emitter.emit(ASM.orr_reg(14, 11, 12))
              @emitter.emit(ASM.tst_imm(14, SEE_THROUGH_MARK))
              drawn = :eq
            else
              emit_cmp_clear(11)
              emit_cmp_clear(12, cond: :ne)
              drawn = :ne
            end
            emit_if(drawn, ASM.orr_reg_lsl(11, 11, 12, 8))
            emit_if(drawn, ASM.store_halfword_post(11, 4, 2))
            @emitter.emit_branch(:bl, see_through_pair_label(lit), cond: drawn == :eq ? :ne : :eq)
          end

          # Compares +reg+ with the picture's see-through number, which the patch routine writes
          # in (#emit_patch_clear): emitted as a compare with nought, its place noted. Made to run
          # only under +cond+ when given. The see-through number is a palette number, under 256,
          # so it fits the compare's eight bits with no turn.
          def emit_cmp_clear(reg, cond: nil)
            @clear_patches << @emitter.pos
            instruction = ASM.cmp_imm(reg, 0)
            cond ? emit_if(cond, instruction) : @emitter.emit(instruction)
          end

          SEE_THROUGH_PAIR_ROUTINE = DerivedNames.sub_label(ROUTINE, :see_through_pair)
          LIT_SEE_THROUGH_PAIR_ROUTINE = DerivedNames.sub_label(ROUTINE, :see_through_pair_lit)

          def see_through_pair_label(lit) = lit ? LIT_SEE_THROUGH_PAIR_ROUTINE : SEE_THROUGH_PAIR_ROUTINE

          # A pair with a see-through pixel, from a run of whole stretches: r11 its left pixel and
          # r12 its right, r4 where it is in the screen's memory, which is left a pair on. Both
          # see-through, nothing is written; one, the pair is read from video memory, the drawn
          # half put in, and written back, the see-through one's own register taking what was
          # read. Called with its return in lr; changes r4, r11, r12 and the flags, and no other.
          #
          # Unlit, a see-through pixel is the see-through number (#emit_cmp_clear); +lit+, it is
          # marked SEE_THROUGH_MARK.
          def emit_see_through_pair_routine(lit:)
            @emitter.place_label(see_through_pair_label(lit))
            if lit
              @emitter.emit(ASM.tst_imm(11, SEE_THROUGH_MARK))
              emit_if(:ne, ASM.tst_imm(12, SEE_THROUGH_MARK))
              both = :ne
            else
              emit_cmp_clear(11)
              emit_cmp_clear(12, cond: :eq)
              both = :eq
            end
            @emitter.emit(ASM.add_imm_cond(both, 4, 4, 2))
            emit_if(both, ASM.bx(14))
            if lit
              @emitter.emit(ASM.tst_imm(11, SEE_THROUGH_MARK))
              left = :ne
            else
              emit_cmp_clear(11)
              left = :eq
            end
            right = left == :eq ? :ne : :eq
            emit_if(left, ASM.load_halfword(11, 4))
            emit_if(left, ASM.and_imm(11, 11, 0xFF))
            emit_if(left, ASM.orr_reg_lsl(11, 11, 12, 8))
            emit_if(right, ASM.load_halfword(12, 4))
            emit_if(right, ASM.and_imm(12, 12, 0xFF00))
            emit_if(right, ASM.orr_reg(11, 11, 12))
            @emitter.emit(ASM.store_halfword_post(11, 4, 2))
            @emitter.emit(ASM.bx(14))
          end

          # One pixel alone, the +half+ (:low or :high) of its pair, put in with what the other
          # half holds. Its shifts are held in registers: it is once a row at most. Lit, r8 and
          # r9 hold the shade, so the shifts are read from memory instead. +clear+ is the register
          # holding the see-through number, for a picture with see-through pixels: a pixel of that
          # number is worked out and stepped past the same, and not written.
          def emit_lone_pixel(half, lit: false, clear: nil)
            width_shift, rows_shift = lit ? [14, 11] : [9, 8]
            if lit
              @primitives.load_var(width_shift, :_face_shift)
              @primitives.load_var(rows_shift, :_face_rows_shift)
            end
            @emitter.emit(ASM.rsb_imm(12, rows_shift, 32))
            @emitter.emit(ASM.mov_reg_lsr_reg(12, 1, 12)) # down...
            @emitter.emit(ASM.mov_reg_lsl_reg(12, 12, width_shift)) # ...as where its row starts
            @emitter.emit(ASM.rsb_imm(11, width_shift, 32))
            @emitter.emit(ASM.mov_reg_lsr_reg(11, 0, 11)) # across
            @emitter.emit(ASM.add_reg(11, 11, 12))
            @emitter.emit(ASM.ldrb_reg(11, 6, 11))
            @emitter.emit(ASM.cmp_reg(11, clear)) if clear # nothing from here to the store changes a flag
            emit_shaded_number(11) if lit
            @emitter.emit(ASM.bic_imm(12, 4, 1))
            @emitter.emit(ASM.load_halfword(14, 12))
            if half == :high
              @emitter.emit(ASM.and_imm(14, 14, 0xFF))
              @emitter.emit(ASM.orr_reg_lsl(14, 14, 11, 8))
            else
              @emitter.emit(ASM.and_imm(14, 14, 0xFF00))
              @emitter.emit(ASM.orr_reg(14, 14, 11))
            end
            clear ? emit_if(:ne, ASM.store_halfword(14, 12)) : @emitter.emit(ASM.store_halfword(14, 12))
            @emitter.emit(ASM.add_reg(0, 0, 2))
            @emitter.emit(ASM.add_reg(1, 1, 3))
            @emitter.emit(ASM.add_imm(4, 4, 1))
          end

          PATCH_ROUTINE = DerivedNames.sub_label(ROUTINE, :patch)

          # Where a shift sits in an instruction: five bits from bit 7.
          SHIFT_FIELD = 0x1F << 7

          # Write the picture's shifts into the pair loop (see #emit_pixel_pairs), called once a face
          # before its rows. Across, the pixel is the top log2(width) bits of u, a shift down of
          # 32 - log2 width (32 written as nought); down, the same of v; and a row starts the row's
          # number moved up log2 width. Each pixel's three instructions are side by side, and where
          # each pixel's are is kept in a table just before this routine, as how far back from the
          # table they start; the table's own address is found from where this routine runs, since
          # it runs where it was copied, not where the cartridge holds it.
          #
          # The few instructions that move u and v up (#emit_moved_up) have their entries after the
          # pixels', each with its lowest bit set for one moving v (an instruction is four bytes
          # along, so that bit is spare), and the compares that take the see-through number have
          # theirs after those (#emit_patch_clear), written whether the shifts need it or not.
          #
          #   r0 the across field, r1 the down field, r2 the row field, r3 the table, r4 how many
          #   are left, r5 a pixel's instructions, r6 an instruction, r7 the next entry
          def emit_patch_routine
            sites = refuse_unpaired_patch_sites!
            table = @emitter.pos
            entries = sites.map { |site| table - site }
            entries << 0 if entries.length.odd?
            entries += @moved_up_patches.map { |site, axis| (table - site) | (axis == :down ? 1 : 0) }
            entries << 0 if entries.length.odd?
            clear_entries_at = 2 * entries.length
            entries += @clear_patches.map { |site| table - site }
            entries << 0 if entries.length.odd?
            @emitter.emit(entries.pack("v*"))
            @emitter.place_label(PATCH_ROUTINE)
            back = @emitter.pos + 8 - table
            @emitter.emit(ASM.sub_imm(3, 15, back & ~0xFF))
            @emitter.emit(ASM.sub_imm(3, 3, back & 0xFF))
            emit_patch_clear(clear_entries_at)
            @primitives.load_var(2, :_face_shift)
            @primitives.load_var(1, :_face_rows_shift)
            @emitter.emit(ASM.rsb_imm(0, 2, 32))
            @emitter.emit(ASM.and_imm(0, 0, 31))
            @emitter.emit(ASM.lsl_imm(0, 0, 7))
            @emitter.emit(ASM.rsb_imm(1, 1, 32))
            @emitter.emit(ASM.and_imm(1, 1, 31))
            @emitter.emit(ASM.lsl_imm(1, 1, 7))
            @emitter.emit(ASM.lsl_imm(2, 2, 7))
            # Nothing to do when the instructions already hold these shifts, as they do for every
            # face after the first that shows a picture of the same size: the first pixel decides,
            # for the shifts that move u and v up too.
            patch = @emitter.gensym
            @emitter.emit(ASM.load_halfword(5, 3))
            @emitter.emit(ASM.sub_reg(5, 3, 5))
            3.times do |field|
              @emitter.emit(ASM.ldr_offset(6, 5, 4 * field))
              @emitter.emit(ASM.and_imm(6, 6, SHIFT_FIELD))
              @emitter.emit(ASM.cmp_reg(6, field))
              @emitter.emit_branch(:bcond, patch, cond: :ne)
            end
            @emitter.emit(ASM.bx(14))
            @emitter.place_label(patch)
            @emitter.emit_number(4, sites.length)
            @emitter.emit(ASM.mov_reg(7, 3))
            each = @emitter.gensym
            @emitter.place_label(each)
            @emitter.emit(ASM.load_halfword(5, 7))
            @emitter.emit(ASM.add_imm(7, 7, 2))
            @emitter.emit(ASM.sub_reg(5, 3, 5))
            3.times do |field|
              @emitter.emit(ASM.ldr_offset(6, 5, 4 * field))
              @emitter.emit(ASM.bic_imm(6, 6, SHIFT_FIELD))
              @emitter.emit(ASM.orr_reg(6, 6, field))
              @emitter.emit(ASM.str_offset(6, 5, 4 * field))
            end
            @emitter.emit(ASM.subs_imm(4, 4, 1))
            @emitter.emit_branch(:bcond, each, cond: :ne)
            @emitter.emit(ASM.add_imm(7, 7, 2)) if sites.length.odd? # past the pixels' last entry, a pad
            emit_patch_moved_up
            @emitter.emit(ASM.bx(14))
          end

          # The shifts that move u AND v UP for the picture's repeat (#emit_moved_up): 16 less
          # log2 of the picture's width or height, into each instruction that takes one, from the
          # entries after the pixels' (r7 the first). They follow from the same two numbers as the
          # pixels' shifts, so they need writing exactly when those do.
          #
          #   r0 the across field, r1 the down field, r3 the table, r4 how many are left, r5 an
          #   entry and then the instruction's address, r6 the instruction, r7 the next entry
          def emit_patch_moved_up
            each = @emitter.gensym
            @primitives.load_var(0, :_face_shift)
            @emitter.emit(ASM.rsb_imm(0, 0, 16))
            @emitter.emit(ASM.lsl_imm(0, 0, 7))
            @primitives.load_var(1, :_face_rows_shift)
            @emitter.emit(ASM.rsb_imm(1, 1, 16))
            @emitter.emit(ASM.lsl_imm(1, 1, 7))
            return if @moved_up_patches.empty?

            @emitter.emit_number(4, @moved_up_patches.length)
            @emitter.place_label(each)
            @emitter.emit(ASM.load_halfword(5, 7))
            @emitter.emit(ASM.add_imm(7, 7, 2))
            @emitter.emit(ASM.tst_imm(5, 1))
            @emitter.emit(ASM.bic_imm(5, 5, 1))
            @emitter.emit(ASM.sub_reg(5, 3, 5))
            @emitter.emit(ASM.ldr(6, 5))
            @emitter.emit(ASM.bic_imm(6, 6, SHIFT_FIELD))
            emit_if(:eq, ASM.orr_reg(6, 6, 0))
            emit_if(:ne, ASM.orr_reg(6, 6, 1))
            @emitter.emit(ASM.str(6, 5))
            @emitter.emit(ASM.subs_imm(4, 4, 1))
            @emitter.emit_branch(:bcond, each, cond: :ne)
          end

          # The see-through number, written into each compare that takes it (#emit_cmp_clear): the
          # low eight bits of the instruction, its first byte, from the entries +at+ bytes into the
          # table on. Nothing to do when the first already holds it, as it does for every face
          # after the first that shows the same picture, nor in a game with no such compare. A
          # picture with none has NO_CLEAR, which no run that compares is entered with.
          #
          #   r3 the table, r0 the number, r4 how many are left, r5 an entry and then the
          #   instruction's address, r6 the byte there, r7 the next entry
          def emit_patch_clear(at)
            return if @clear_patches.empty?

            done = @emitter.gensym
            each = @emitter.gensym
            @primitives.load_var(0, :_face_clear)
            @emitter.emit(ASM.and_imm(0, 0, 0xFF))
            @emitter.emit_number(7, at)
            @emitter.emit(ASM.add_reg(7, 3, 7))
            @emitter.emit(ASM.load_halfword(5, 7))
            @emitter.emit(ASM.sub_reg(5, 3, 5))
            @emitter.emit(ASM.ldrb_offset(6, 5, 0))
            @emitter.emit(ASM.cmp_reg(6, 0))
            @emitter.emit_branch(:bcond, done, cond: :eq)
            @emitter.emit_number(4, @clear_patches.length)
            @emitter.place_label(each)
            @emitter.emit(ASM.load_halfword(5, 7))
            @emitter.emit(ASM.add_imm(7, 7, 2))
            @emitter.emit(ASM.sub_reg(5, 3, 5))
            @emitter.emit(ASM.strb(0, 5))
            @emitter.emit(ASM.subs_imm(4, 4, 1))
            @emitter.emit_branch(:bcond, each, cond: :ne)
            @emitter.place_label(done)
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

          # The shade word a step on, through the registers +shade+ and +step+ (r11 and lr unless
          # given).
          def emit_shade_step_in_memory(shade: 11, step: 14)
            @primitives.load_var(shade, :_face_shade)
            @primitives.load_var(step, :_face_step_shade)
            @emitter.emit(ASM.add_reg(shade, shade, step))
            @primitives.store_var(shade, :_face_shade)
          end

          # The pixels of a span on the direct screen: each the picture's colour, two bytes, read
          # and written whole. The registers are as #emit_pixels has them, r4 counting two bytes a
          # pixel and r6 the picture's colours.
          #
          # Lit, each colour drawn is looked for among the shading's (#emit_shade_color_routine)
          # and the shade kept in memory: the slow way, for the screen no place is drawn on.
          def emit_direct_pixels
            return emit_direct_pixel_loop(lit: false) unless @lit

            unlit = @emitter.gensym
            done = @emitter.gensym
            @primitives.load_var(11, :_face_shading)
            @emitter.emit(ASM.cmp_imm(11, 0))
            @emitter.emit_branch(:bcond, unlit, cond: :eq)
            emit_direct_pixel_loop(lit: true)
            @emitter.emit_branch(:b, done)
            @emitter.place_label(unlit)
            emit_direct_pixel_loop(lit: false)
            @emitter.place_label(done)
          end

          def emit_direct_pixel_loop(lit:)
            pixel = @emitter.gensym
            skip = @emitter.gensym
            @emitter.place_label(pixel)
            emit_picture_place(11)
            @emitter.emit(ASM.lsl_imm(11, 11, 1))
            @emitter.emit(ASM.add_reg(11, 6, 11))
            @emitter.emit(ASM.load_halfword(11, 11))
            @emitter.emit(ASM.cmp_reg(11, 10))
            @emitter.emit_branch(:bcond, skip, cond: :eq)
            @emitter.emit_branch(:bl, SHADE_COLOR_ROUTINE) if lit
            @emitter.emit(ASM.store_halfword(11, 4))
            @emitter.place_label(skip)
            emit_shade_step_in_memory if lit
            @emitter.emit(ASM.add_reg(0, 0, 2))
            @emitter.emit(ASM.add_reg(1, 1, 3))
            @emitter.emit(ASM.add_imm(4, 4, 2))
            @emitter.emit(ASM.subs_imm(5, 5, 1))
            @emitter.emit_branch(:bcond, pixel, cond: :ne)
          end

          SHADE_COLOR_ROUTINE = DerivedNames.sub_label(ROUTINE, :shade_color)

          # r11 = the colour in r11 at the shade word's level, on the direct screen: looked for
          # among the shading's colours, and if it is one of them, the colour its place becomes at
          # that level (see #shading_table); if not, left as it is. Called with its return in lr;
          # keeps every register but r11 and r12.
          #
          #   r12 the shading's colours, r0 how many, r1 the place, r2 a colour, then the level, r3
          #   the shade
          def emit_shade_color_routine
            look = @emitter.gensym
            found = @emitter.gensym
            done = @emitter.gensym
            @emitter.place_label(SHADE_COLOR_ROUTINE)
            @emitter.emit(ASM.push(0, 1, 2, 3, 14))
            @primitives.load_var(3, :_face_shade)
            @primitives.load_var(12, :_face_shading)
            @emitter.emit(ASM.ldr_offset(0, 12, 0))
            @emitter.emit(ASM.add_imm(12, 12, 4))
            @emitter.emit_number(1, 0)
            @emitter.place_label(look)
            @emitter.emit(ASM.cmp_reg(1, 0))
            @emitter.emit_branch(:bcond, done, cond: :ge)
            @emitter.emit(ASM.add_reg(2, 1, 1))
            @emitter.emit(ASM.add_reg(2, 12, 2))
            @emitter.emit(ASM.load_halfword(2, 2))
            @emitter.emit(ASM.cmp_reg(2, 11))
            @emitter.emit_branch(:bcond, found, cond: :eq)
            @emitter.emit(ASM.add_imm(1, 1, 1))
            @emitter.emit_branch(:b, look)
            @emitter.place_label(found)
            @emitter.emit(ASM.lsr_imm(2, 3, 16))
            @emitter.emit(ASM.add_imm(2, 2, 1)) # past the colours themselves
            @emitter.emit(ASM.mul(11, 2, 0))
            @emitter.emit(ASM.add_reg(11, 11, 1))
            @emitter.emit(ASM.add_reg(11, 11, 11))
            @emitter.emit(ASM.add_reg(11, 12, 11))
            @emitter.emit(ASM.load_halfword(11, 11))
            @emitter.place_label(done)
            @emitter.emit(ASM.pop(0, 1, 2, 3, 15))
          end
        end
      end
    end
  end
end
