# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # Double-buffered (Mode 4) drawing, onto the hidden page.
        #
        # These mirror the direct-color fills Drawing makes, with two differences
        # forced by the indexed screen: a pixel is one byte (an index into the color
        # table), not two, so addresses and counts are in bytes; and video memory
        # can't be written a single byte at a time (a lone byte write hits both
        # halves of its 16-bit slot), so fills move whole 16-bit units — two pixels —
        # at once, and a block fill must start on an even column (a rect asked for an
        # odd one gets its two edge pixels written singly instead). The destination is
        # the hidden page, whose address lives in a run-time variable (BACKBUF) and
        # swaps every flip.
        #
        # Reaches Drawing's clip/column/digit-glyph helpers through {Framebuffer}
        # rather than through Drawing itself — the two screens share how they work,
        # not an object.
        class Buffered
          include Console::Hardware
          extend Console::Hardware # the screen's size, for the class-level rules the estimate asks

          def initialize(emitter:, primitives:, lowering:, framebuffer:, placement:)
            @emitter = emitter
            @primitives = primitives
            @lowering = lowering
            @framebuffer = framebuffer
            @placement = placement
            @layout = nil
          end

          attr_writer :layout

          def in_register(register) = Primitives::InRegister.new(register)

          # Clear the hidden page to a solid color: one DMA that repeats the packed
          # index word across the whole page.
          def emit_clear_screen_buffered(node)
            # Inside an area, "the whole page" is that area — which is a rectangle, and there is
            # already one way to fill one of those.
            if @framebuffer.clipping?
              return emit_buffered_rect(@framebuffer.clip_left, @framebuffer.clip_top, @framebuffer.clip_right - @framebuffer.clip_left,
                                        @framebuffer.clip_bottom - @framebuffer.clip_top, node.color)
            end

            scratch = emit_index_fill_word(node.color)
            return emit_shown_rows_filled(scratch, first: :hidden_page) if @layout.fills_shown_rows_alone?(1)

            @primitives.load_var(ACC, BACKBUF) # to the hidden page, wherever it is this frame
            count = SCREEN_WIDTH * @layout.shown_rows / 4 # 32-bit words, 4 indices each
            @primitives.emit_start_copy_engine(from: scratch, to: in_register(ACC), control: @framebuffer.dma_fill_control(count))
          end

          # The shown part of every row of a page, a row at a time (Framebuffer#emit_shown_rows_filled).
          def emit_shown_rows_filled(scratch, first:)
            @framebuffer.emit_shown_rows_filled(scratch, first: first, rows: @layout.shown_rows,
                                                         row_bytes: @layout.shown_columns, stride: SCREEN_WIDTH)
          end

          # Both pages in +color+, for a tear-free screen arriving over what another screen left.
          def emit_both_pages_filled(color)
            scratch = emit_index_fill_word(color)
            if @layout.fills_shown_rows_alone?(1)
              return [PAGE0, PAGE1].each { |page| emit_shown_rows_filled(scratch, first: page) }
            end

            count = SCREEN_WIDTH * @layout.shown_rows / 4
            [PAGE0, PAGE1].each do |page|
              @primitives.emit_start_copy_engine(from: scratch, to: page, control: @framebuffer.dma_fill_control(count))
            end
          end

          # A rectangle at a constant position/size, filled per row into the hidden
          # page, in Mode 4's packed block fill.
          #
          # A fill moves whole 16-bit units, so it can only START on an even column.
          # Asked for an odd one, the rect's first and last pixel each share a unit
          # with a pixel that is not part of the rect — so those two are written one
          # at a time (read the unit, change that pixel's half, write it back) and the
          # DMA fills the even middle between them. The column is known while
          # building, so which of the two shapes a row takes is settled here.
          def emit_fill_rect_buffered(node)
            x, y, w, h = @primitives.constant_ints!(node, x: node.x, y: node.y, w: node.w, h: node.h)
            @framebuffer.refuse_odd_width!(w, node.kind)
            emit_buffered_rect(x, y, w, h, node.color)
          end

          # Up to this many pairs of pixels, writing them out beats starting the block-fill
          # engine on time — and for most of the way on the code it takes as well.
          #
          # Counted off the emitted code, a row that starts the engine is twelve
          # instructions whatever it then moves (ten where the row's address is one the chip
          # can name outright), and a row written out is its address and then one instruction
          # per pair, which is three plus one per pair for most rows. So the written-out row
          # is the smaller one up to nine pairs, and it stays the faster one further than
          # that: starting the engine costs the register writes AND the stall while the
          # engine copies, which stops the CPU dead.
          #
          # From ten pairs to this many the written-out row is the bigger of the two, by up to
          # three instructions a row, and is kept for being the faster. Past here it would
          # cost more again, and a rectangle's rows are unrolled — so going further needs a
          # size budget the framework does not have, and it would spend the quick memory that
          # a game's hot routines are competing for.
          DIRECT_STORE_UNITS = 12

          # A class method because the estimate has to price a row the way this decides to
          # build it — pairs written out, or a transfer started.
          def self.direct_fill?(width) = width.positive? && (width / 2) <= DIRECT_STORE_UNITS

          def direct_fill?(w) = Buffered.direct_fill?(w)

          # The fill colour as one 16-bit unit — the same palette index in both of its
          # pixels — held for as long as a fixed-position rect's narrow rows need it.
          # (The run-time-positioned rect's own middle-width path uses this register for
          # its transfer count instead; the two never run together.)
          RECT_FILL = 7

          # ...and the same rectangle without the even-width promise, because an area can cut a
          # row down to an odd number of pixels however even the author's own rectangle was.
          def emit_buffered_rect(x, y, w, h, color)
            # Held to the area sideways once, before any row is emitted: every row of a
            # rectangle spans the same columns, so where it starts and stops is one answer.
            left = [x, @framebuffer.clip_left].max
            right = [x + w, @framebuffer.clip_right].min
            return if right <= left || h <= 0

            x = left
            w = right - left
            scratch = emit_index_fill_word(color)
            index = @layout.palette.index_of(color)

            # Which pixels cannot go in as pairs. A fill moves whole 16-bit units, so a run that
            # starts on an odd column shares its first unit with a pixel outside the rectangle,
            # and one holding an odd number of pixels shares its last. Either is written on its
            # own — read the unit, change that half, write it back — and the pairs between them
            # go in as one block.
            first_alone = x.odd?
            last_x = x + w - 1
            middle_x = first_alone ? x + 1 : x
            middle_w = w - (first_alone ? 1 : 0)
            last_alone = middle_w.odd?
            middle_w -= 1 if last_alone

            base = 6
            @primitives.load_var(base, BACKBUF) # the hidden page base, held for the whole rect
            # A row narrow enough to be written out needs the fill unit in a register, and it
            # is the same unit for every row — so it is loaded once here rather than per row.
            @emitter.emit_number(RECT_FILL, fill_unit(index)) if direct_fill?(middle_w)

            # A rect as wide as the screen is one unbroken run of memory: there is no gap
            # to skip between rows, because the next row starts exactly where the last one
            # ended. So the whole rect goes in as a single block transfer instead of one
            # per row — which for a full-width band (a sky, a floor, a letterbox) is the
            # difference between two instructions and a hundred and sixty.
            if full_width_rows?(x: x, y: y, w: w, h: h)
              return emit_buffered_row_fill(base: base, x: 0, row: y, w: w * h, scratch: scratch)
            end

            h.times do |dy|
              row = y + dy
              next unless (@framebuffer.clip_top...@framebuffer.clip_bottom).cover?(row)

              emit_write_index_pixel_const(base, x, row, index) if first_alone
              emit_buffered_row_fill(base: base, x: middle_x, row: row, w: middle_w, scratch: scratch) if middle_w.positive?
              emit_write_index_pixel_const(base, last_x, row, index) if last_alone
            end
          end

          # Can this rect go in as one transfer? Only if it spans the full screen width (so its
          # rows are contiguous) and every row of it may be painted (so there is nothing to skip
          # in the middle of the run). An area narrower than the screen breaks the first of
          # those, and one that starts below the top or stops above the bottom the second.
          #
          # The area is passed in rather than read, so the estimate can ask the same question:
          # it prices this shape and has no framebuffer to read a clip from.
          def self.one_transfer?(x:, y:, w:, h:, top: 0, bottom: SCREEN_HEIGHT,
                                 left: 0, right: SCREEN_WIDTH)
            x.zero? && w == SCREEN_WIDTH && h.positive? &&
              y >= top && (y + h) <= bottom && left.zero? && right == SCREEN_WIDTH
          end

          def full_width_rows?(x:, y:, w:, h:)
            Buffered.one_transfer?(x: x, y: y, w: w, h: h,
                                   top: @framebuffer.clip_top, bottom: @framebuffer.clip_bottom,
                                   left: @framebuffer.clip_left, right: @framebuffer.clip_right)
          end

          # One row of a rect into the hidden page: +w+ pixels from the even column +x+ of
          # +row+. +base+ is the register holding the hidden page base.
          #
          # A narrow row is written out as pairs of pixels rather than handed to the
          # block-fill engine, for the reason DIRECT_STORE_UNITS gives: starting the engine
          # costs the same whatever it then moves, so below that width the starting is most
          # of the work. A row of eight pixels goes in as four stores against the engine's
          # twelve instructions and its stall.
          def emit_buffered_row_fill(base:, x:, row:, w:, scratch:)
            return emit_buffered_row_stores(base: base, x: x, row: row, w: w) if direct_fill?(w)

            @primitives.emit_add_const(ACC, base, (row * SCREEN_WIDTH) + x, TMP) # that row: + byte offset (1 byte/pixel)
            @primitives.emit_start_copy_engine(from: scratch, to: in_register(ACC), control: dma_fill_control_16(w / 2))
          end

          # The same row written out: the fill unit — the palette index in both of its bytes,
          # held in RECT_FILL — stored a pair at a time. Every address here is settled while
          # building, so a row is one address built into r1 and then a store per pair at a
          # fixed offset from it.
          def emit_buffered_row_stores(base:, x:, row:, w:)
            @primitives.emit_add_const(1, base, (row * SCREEN_WIDTH) + x, ACC) # r1 = the row's first unit
            (w / 2).times { |unit| @emitter.emit(ASM.store_halfword_offset(RECT_FILL, 1, unit * 2)) }
          end

          # The 16-bit unit a packed fill writes: the palette index in both of its pixels.
          def fill_unit(index) = (index * 0x0101) & 0xFFFF

          # A rectangle at a run-time position, filled per row into the hidden page.
          #
          # Every edge settled while building goes straight to the same fixed-rect fill
          # fill_rect uses (#emit_buffered_rect) — clipped in Ruby, once, nothing for the
          # console to check. A width settled while building but at least one other edge
          # not gets the fits-whole check (#emit_buffered_fixed_width_rect): the
          # overwhelming common case is a rect that never actually crosses an edge, and
          # that one still gets the size-chosen, parity-branched shape a fixed rect does.
          # Anything else always needs the clip worked out at run time
          # (#emit_buffered_rect_at_computed), since neither the width nor the position is
          # known well enough while building to rule an edge out.
          def emit_draw_rect_at_buffered(node)
            x = @primitives.const_int(node.x)
            y = @primitives.const_int(node.y)
            w = @primitives.const_int(node.w)
            h = @primitives.const_int(node.h)
            return if w && w < 1 # a rect with no width draws nothing
            return if h && h < 1 # ...or no height

            return emit_buffered_rect(x, y, w, h, node.color) if x && y && w && h
            return emit_buffered_rect_at_computed(node, w) unless w

            emit_buffered_fixed_width_rect(node, w, h)
          end

          # Registers through the whole run: r2 the rect's (clipped, once it needs to be)
          # x, r3 its y — a running row number once #emit_row_address_setup has used it to
          # seed r4 — r4 the address of the row's first column, r5 scratch, r6 how many
          # rows are left when the height is one the game works out.
          RECT_X = 2
          RECT_Y = 3
          RECT_ROW = 4
          RECT_ADDR = 5
          RECT_ROWS_LEFT = 6

          # Put the hidden page's address of column 0 on the rect's first row in r4, once
          # for the whole rect.
          #
          # Every row after that starts exactly one screen width further on, so the rows
          # walk it down with a single add (#emit_advance_row) instead of working it out
          # again. Working it out again is what this used to do on every row: a multiply
          # by the screen width, a load of the hidden page's address, and an add — five
          # instructions before a single pixel was written. On a tall thin column, which is
          # what a per-column renderer draws hundreds of, that was the column: measured, a
          # rect cost the same per row at 2 pixels wide as at 16, because almost none of
          # the cost was the pixels.
          def emit_row_address_setup
            @emitter.emit_number(RECT_ADDR, SCREEN_WIDTH)
            @emitter.emit(ASM.mul(RECT_ROW, RECT_ADDR, RECT_Y)) # r4 = SCREEN_WIDTH * y, 1 byte/pixel
            @primitives.load_var(RECT_ADDR, BACKBUF)               # r5 = hidden page base
            @emitter.emit(ASM.add_reg(RECT_ROW, RECT_ROW, RECT_ADDR))
          end

          # One row down the screen: the address (240 bytes a row on this display, which
          # the chip can add in one instruction) and the row NUMBER — r3 is done seeding
          # r4 by the time the first row runs, so from here it tracks which row this is,
          # for #emit_buffered_computed_row's own top/bottom check.
          def emit_advance_row
            @emitter.emit(ASM.add_imm(RECT_ROW, RECT_ROW, SCREEN_WIDTH))
            @emitter.emit(ASM.add_imm(RECT_Y, RECT_Y, 1))
          end

          # +h+ is the height when it is settled while building — then the rows are
          # unrolled. It is nil when the game works the height out, and then the same
          # row is emitted once inside a counted loop that walks down the screen.
          def emit_buffered_rect_rows(w:, h:, scratch:, index:, starts_odd:)
            row = { w: w, scratch: scratch, index: index, starts_odd: starts_odd }
            emit_row_address_setup
            # Every row's middle is the same width, so whether it is written straight out
            # is settled here, once, along with the value it writes.
            emit_rect_fill_value(index) if direct_fill?(rect_row_parts(w, starts_odd).last)
            if h
              h.times do |dy|
                emit_advance_row unless dy.zero?
                emit_buffered_rect_row(**row)
              end
              return
            end

            @primitives.emit_row_loop(RECT_ROWS_LEFT) do
              emit_buffered_rect_row(**row)
              emit_advance_row
            end
          end

          # +starts_odd+ marks that the rect begins on an odd column, which is settled by here
          # (either the column is a plain number, or the caller branched on its low bit).
          # The width is a plain number too, so which pixels need splicing in one at a
          # time follows from the same rule the computed-width path works out as it runs:
          # the first pixel when the rect starts on an odd column, the last when it ends
          # on an even one. Both parities of width are covered — an odd width is not an
          # error here, just a rect with a different pair of ends.
          def emit_buffered_rect_row(w:, scratch:, index:, starts_odd:)
            left, right, middle_w = rect_row_parts(w, starts_odd)

            emit_splice_rect_edge(index: index, offset: 0, high: true) if left.positive?
            emit_buffered_rect_row_middle(offset: left, w: middle_w, scratch: scratch) if middle_w.positive?
            emit_splice_rect_edge(index: index, offset: w - 1, high: false) if right.positive?
          end

          # Which of a row's pixels need splicing in one at a time, and how many are left
          # in the middle. Every row of a rect has the same answer, so the callers work it
          # out once above the rows and it agrees with what each row then emits.
          def rect_row_parts(w, starts_odd)
            left = starts_odd ? 1 : 0
            right = (starts_odd ? w + 1 : w).odd? ? 1 : 0
            [left, right, w - left - right]
          end

          # Held for the whole of a computed-width rect: r7 the middle's transfer count
          # (0 when there is no middle), r8 whether the rect starts on an odd column
          # (which is also how far right of x its middle begins), r9 the column its last
          # pixel is in.
          RECT_MIDDLE = 7
          RECT_LEFT = 8
          RECT_RIGHT = 9

          # A rect whose width is settled while building but at least one other edge is
          # not — an author's own fixed size at a position the game works out, the health
          # bar every doc example for this verb draws. Checked once, at run time, whether
          # it already fits the area whole: if so, exactly the size-chosen, parity-branched
          # shape #emit_buffered_rect_rows gives a fixed rectangle runs, just with its
          # address built from a run-time x/y instead of one settled while building — the
          # overwhelming common case, and the one worth keeping cheap. Only a rect that
          # would actually cross an edge falls through to the general run-time clip
          # (#emit_buffered_rect_at_computed's tail), because that shape cannot promise
          # the width stays a plain number once the console has trimmed it.
          def emit_buffered_fixed_width_rect(node, w, h)
            scratch = emit_index_fill_word(node.color)
            index = @layout.palette.index_of(node.color)

            @framebuffer.eval_rect_position(node, x_reg: RECT_X, y_reg: RECT_Y, rows_reg: RECT_ROWS_LEFT)

            needs_clip = @emitter.gensym
            done = @emitter.gensym

            @emitter.emit(ASM.cmp_imm(RECT_X, @framebuffer.clip_left))
            @emitter.emit_branch(:bcond, needs_clip, cond: :lt)
            @primitives.emit_add_const(ACC, RECT_X, w, TMP)
            @emitter.emit(ASM.cmp_imm(ACC, @framebuffer.clip_right))
            @emitter.emit_branch(:bcond, needs_clip, cond: :gt)
            @emitter.emit(ASM.cmp_imm(RECT_Y, @framebuffer.clip_top))
            @emitter.emit_branch(:bcond, needs_clip, cond: :lt)
            if h
              @primitives.emit_add_const(ACC, RECT_Y, h, TMP)
            else
              @emitter.emit(ASM.add_reg(ACC, RECT_Y, RECT_ROWS_LEFT))
            end
            @emitter.emit(ASM.cmp_imm(ACC, @framebuffer.clip_bottom))
            @emitter.emit_branch(:bcond, needs_clip, cond: :gt)

            parity = Parity.of(node.x)
            rows = { w: w, h: h, scratch: scratch, index: index }
            if parity
              emit_buffered_rect_rows(**rows, starts_odd: parity == :odd)
            else
              odd_column = @emitter.gensym
              @emitter.emit(ASM.and_imm(ACC, RECT_X, 1))
              @emitter.emit(ASM.cmp_imm(ACC, 0))
              @emitter.emit_branch(:bcond, odd_column, cond: :ne)
              emit_buffered_rect_rows(**rows, starts_odd: false)
              @emitter.emit_branch(:b, done)
              @emitter.place_label(odd_column)
              emit_buffered_rect_rows(**rows, starts_odd: true)
            end
            @emitter.emit_branch(:b, done)

            @emitter.place_label(needs_clip)
            @emitter.emit_number(RECT_MIDDLE, w)
            emit_buffered_rect_clip_and_rows(node, scratch, index)

            @emitter.place_label(done)
          end

          # A rect with at least one edge the game works out as it runs, so the clip has
          # to happen at run time.
          #
          # Here a pixel is one byte, but video memory refuses to write a lone byte — the
          # smallest write covers two side-by-side pixels, one unit. So a rect that
          # starts or ends halfway through a unit has to have that pixel spliced in on
          # its own: read the unit, change only this pixel's half, write it back. The
          # rest, an even number of pixels starting on an even column, goes in as a
          # block fill. Both ends come down to one rule, worked out once above the rows
          # because every row of a rect starts and ends in the same columns:
          #
          #   - the first pixel needs splicing when the rect starts on an odd column;
          #   - the last one needs splicing when it ends on an even column;
          #   - what is left between them is always an even number of pixels beginning
          #     on an even column, which is exactly what a block fill wants.
          #
          # x and width settle to one clipped span before any row fires — a rect has one
          # x for its whole height — and every row then checks its own y against the
          # area (#emit_buffered_computed_row), because a run-time y or height means a
          # run-time set of rows survives: an unclipped row is what wrapped a rect onto
          # its neighbor.
          def emit_buffered_rect_at_computed(node, w)
            scratch = emit_index_fill_word(node.color)
            index = @layout.palette.index_of(node.color)

            @framebuffer.eval_rect_position(node, x_reg: RECT_X, y_reg: RECT_Y,
                                     rows_reg: RECT_ROWS_LEFT, width_reg: RECT_MIDDLE)
            @emitter.emit_number(RECT_MIDDLE, w) if w # a fixed width isn't loaded above

            emit_buffered_rect_clip_and_rows(node, scratch, index)
          end

          # The clip, and the rows it leaves for, shared by #emit_buffered_rect_at_computed
          # (always this shape) and #emit_buffered_fixed_width_rect (the fallback
          # once a fits-whole rect turns out not to). Assumes r2/r3 (x/y) and r7 (the raw,
          # unclipped width) are already loaded, and r6 (rows left) is too when the height
          # is not settled while building.
          def emit_buffered_rect_clip_and_rows(node, scratch, index)
            done = @emitter.gensym

            # right = x + width, unclipped, worked out before x itself is touched.
            @emitter.emit(ASM.add_reg(RECT_RIGHT, RECT_X, RECT_MIDDLE))
            keep_right = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(RECT_RIGHT, @framebuffer.clip_right))
            @emitter.emit_branch(:bcond, keep_right, cond: :le)
            @emitter.emit_number(RECT_RIGHT, @framebuffer.clip_right)
            @emitter.place_label(keep_right)

            keep_left = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(RECT_X, @framebuffer.clip_left))
            @emitter.emit_branch(:bcond, keep_left, cond: :ge)
            @emitter.emit_number(RECT_X, @framebuffer.clip_left)
            @emitter.place_label(keep_left)

            # A rect the game shrank to nothing, or slid entirely off the area, draws
            # nothing — and a block fill asked for zero units would move 65536 of them,
            # so this is not optional.
            @emitter.emit(ASM.sub_reg(RECT_MIDDLE, RECT_RIGHT, RECT_X))
            @emitter.emit(ASM.cmp_imm(RECT_MIDDLE, 0))
            @emitter.emit_branch(:bcond, done, cond: :le)

            @emitter.emit(ASM.sub_imm(RECT_RIGHT, RECT_RIGHT, 1))       # the last column, one back from "past the end"
            @emitter.emit(ASM.and_imm(RECT_LEFT, RECT_X, 1))            # starts on an odd column?
            @emitter.emit(ASM.and_imm(ACC, RECT_RIGHT, 1))
            @emitter.emit(ASM.rsb_imm(ACC, ACC, 1))                     # ends on an even one?
            @emitter.emit(ASM.sub_reg(RECT_MIDDLE, RECT_MIDDLE, RECT_LEFT)) # what the two ends
            @emitter.emit(ASM.sub_reg(RECT_MIDDLE, RECT_MIDDLE, ACC))       # do not cover

            # Turn that into a transfer count, or leave it at zero to mean "no middle".
            no_middle = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(RECT_MIDDLE, 0))
            @emitter.emit_branch(:bcond, no_middle, cond: :eq)
            @emitter.emit(ASM.lsr_imm(RECT_MIDDLE, RECT_MIDDLE, 1)) # two pixels per unit moved
            @emitter.emit_number(TMP, dma_fill_control_16(0))
            @emitter.emit(ASM.orr_reg(RECT_MIDDLE, RECT_MIDDLE, TMP))
            @emitter.place_label(no_middle)

            height = @primitives.const_int(node.h)
            @emitter.emit_number(RECT_ROWS_LEFT, height) if height
            emit_row_address_setup
            @primitives.emit_row_loop(RECT_ROWS_LEFT) do
              emit_buffered_computed_row(index: index, scratch: scratch)
              emit_advance_row
            end
            @emitter.place_label(done)
          end

          # One row of a computed-width rect: skipped outright if its y falls outside
          # the area (a row above or below it draws nothing, not a row wrapped onto its
          # neighbor); else at most two spliced pixels with a block fill between them,
          # which of the three actually run having been decided above the loop.
          def emit_buffered_computed_row(index:, scratch:)
            row_skip = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(RECT_Y, @framebuffer.clip_top))
            @emitter.emit_branch(:bcond, row_skip, cond: :lt)
            @emitter.emit(ASM.cmp_imm(RECT_Y, @framebuffer.clip_bottom))
            @emitter.emit_branch(:bcond, row_skip, cond: :ge)

            skip_left = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(RECT_LEFT, 0))
            @emitter.emit_branch(:bcond, skip_left, cond: :eq)
            emit_splice_column(index: index, col_reg: RECT_X, high: true)
            @emitter.place_label(skip_left)

            skip_middle = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(RECT_MIDDLE, 0))
            @emitter.emit_branch(:bcond, skip_middle, cond: :eq)
            @emitter.emit(ASM.add_reg(RECT_ADDR, RECT_ROW, RECT_X))
            @emitter.emit(ASM.add_reg(RECT_ADDR, RECT_ADDR, RECT_LEFT)) # past a spliced first pixel
            @primitives.emit_start_copy_engine(from: scratch, to: in_register(RECT_ADDR), control: in_register(RECT_MIDDLE))
            @emitter.place_label(skip_middle)

            skip_right = @emitter.gensym
            @emitter.emit(ASM.and_imm(ACC, RECT_RIGHT, 1))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, skip_right, cond: :ne) # ends on an odd column: nothing to splice
            emit_splice_column(index: index, col_reg: RECT_RIGHT, high: false)
            @emitter.place_label(skip_right)

            @emitter.place_label(row_skip)
          end

          # Splice one pixel of a rect into the hidden page: the pixel in the column
          # +col_reg+ holds, on the row whose address r4 holds. Its unit also holds a
          # pixel outside the rect, so read the unit, replace only this pixel's half,
          # and write it back. An odd column is the HIGH half of its unit, so its
          # address needs the low bit cleared to name the unit.
          def emit_splice_column(index:, col_reg:, high:)
            @emitter.emit(ASM.add_reg(RECT_ADDR, RECT_ROW, col_reg))
            if high
              @emitter.emit(ASM.lsr_imm(RECT_ADDR, RECT_ADDR, 1))
              @emitter.emit(ASM.lsl_imm(RECT_ADDR, RECT_ADDR, 1))
            end
            @emitter.emit(ASM.load_halfword(ACC, RECT_ADDR))
            emit_splice_index_const(ACC, index, high)
            @emitter.emit(ASM.store_halfword(ACC, RECT_ADDR))
          end

          def emit_rect_fill_value(index)
            @emitter.emit_number(RECT_FILL, (index << 8) | index)
          end

          # Fill the middle of one row of a fits-whole, run-time-positioned rect: +w+
          # pixels starting +offset+ columns right of the rect's x, on the row whose
          # address r4 holds.
          #
          # A narrow middle is written straight out, one 16-bit store per pair of pixels,
          # rather than handing it to the block-fill engine. Starting that engine costs the
          # same whatever it then moves — the register writes, and the stall while it copies
          # — so for a pair or two the starting is nearly all of the work, and a two-pixel
          # column would cost more per row than a one-pixel one that only splices.
          #
          # Past DIRECT_STORE_UNITS the engine is worth starting; see the constant above for
          # where that line sits and what it is measured against.
          def emit_buffered_rect_row_middle(offset:, w:, scratch:)
            return emit_buffered_rect_row_dma(offset: offset, w: w, scratch: scratch) unless direct_fill?(w)

            @emitter.emit(ASM.add_reg(RECT_ADDR, RECT_ROW, RECT_X))
            @primitives.emit_add_const(RECT_ADDR, RECT_ADDR, offset, ACC)
            (w / 2).times { |unit| @emitter.emit(ASM.store_halfword_offset(RECT_FILL, RECT_ADDR, unit * 2)) }
          end

          # DMA one row of a fits-whole, run-time-positioned rect: +w+ pixels starting
          # +offset+ columns right of the rect's x, on the row whose address r4 holds.
          def emit_buffered_rect_row_dma(offset:, w:, scratch:)
            @emitter.emit(ASM.add_reg(RECT_ADDR, RECT_ROW, RECT_X))
            @primitives.emit_add_const(RECT_ADDR, RECT_ADDR, offset, ACC)
            @primitives.emit_start_copy_engine(from: scratch, to: in_register(RECT_ADDR), control: dma_fill_control_16(w / 2))
          end

          # Splice one edge pixel of a fits-whole, run-time-positioned rect into the
          # hidden page: the pixel +offset+ columns right of the rect's x, on the row
          # whose address r4 holds. Its 16-bit unit also holds a pixel outside the rect,
          # so read the unit, replace only this pixel's half, and write it back. The
          # rect's x is odd here, which makes the left edge the high half of its unit and
          # the right edge (x + w - 1, an even column, since the width is even) the low
          # half of its own — so only the left edge's address needs its low bit cleared.
          def emit_splice_rect_edge(index:, offset:, high:)
            @emitter.emit(ASM.add_reg(RECT_ADDR, RECT_ROW, RECT_X))
            @primitives.emit_add_const(RECT_ADDR, RECT_ADDR, offset, ACC)
            if high
              @emitter.emit(ASM.lsr_imm(RECT_ADDR, RECT_ADDR, 1)) # clear the low bit ->
              @emitter.emit(ASM.lsl_imm(RECT_ADDR, RECT_ADDR, 1)) # r5 = the containing unit's address
            end
            @emitter.emit(ASM.load_halfword(ACC, RECT_ADDR))      # r0 = the current pixel pair
            emit_splice_index_const(ACC, index, high)
            @emitter.emit(ASM.store_halfword(ACC, RECT_ADDR))
          end

          # Stash a solid fill color as a word of four packed indices in IWRAM and
          # return its address — the fixed source a Mode 4 DMA fill re-reads. A 16-bit
          # fill reads its low half (two indices); a 32-bit fill reads all four.
          def emit_index_fill_word(color)
            index = @layout.palette.index_of(color)
            word = index * 0x01010101 # the same index in all four bytes
            scratch = @primitives.var_addr(Primitives::FILL_SCRATCH)
            @primitives.store_word_immediate(word, scratch)
            scratch
          end

          # The DMA3 control word for a source-fixed 16-bit fill of +count+ halfwords —
          # the Mode 4 fill unit (two packed indices per halfword).
          def dma_fill_control_16(count)
            count | DMA_ENABLE | DMA_SRC_FIXED # 16-bit is the default (DMA_16BIT == 0)
          end

          # Draw a line of text on the hidden page. Each lit font pixel is a single
          # color index (one byte), but the indexed screen can't take a lone byte
          # write, so each pixel is a read-modify-write: read the 16-bit unit that
          # contains it, splice the index into the correct half, write it back. The
          # glyph positions are known while building, so which half each pixel lands in
          # is settled here, not at run time. Off-screen pixels are dropped.
          #
          # A line in one of two colours is painted once too: the slot is worked out first
          # and held in a register the pixel writes splice from, where one colour splices a
          # number written into each of them.
          def emit_draw_text_buffered(node)
            x, y = @primitives.constant_ints!(node, x: node.x, y: node.y)
            index = @layout.palette.index_of(node.color) unless node.picked
            @framebuffer.emit_text_color(node, TEXT_INDEX) { |color| @layout.palette.index_of(color) } if node.picked
            points = @framebuffer.text_points(node, x, y)
            return emit_text_points_call(points, index) if points.length >= Framebuffer::TEXT_POINTS_LINE

            base = 6
            @primitives.load_var(base, BACKBUF) # the hidden page base, held for the whole line

            points.each do |point|
              emit_write_index_pixel_const(base, point % SCREEN_WIDTH, point / SCREEN_WIDTH, index || TEXT_INDEX, held: node.picked)
            end
          end

          # A line in a table: the colour's slot in r0, then the table and how many it holds.
          def emit_text_points_call(points, index)
            index ? @emitter.emit_number(ACC, index) : @emitter.emit(ASM.mov_reg(ACC, TEXT_INDEX))
            @emitter.emit_load_data_address(TMP, @framebuffer.text_points_blob(points))
            @emitter.emit_number(SPARE, points.length)
            @text_points_used = true
            @placement.emit_call_cold_routine(TEXT_POINTS)
          end

          TEXT_POINTS = Messages::MadeNames.make(:buffered_text_points_routine)

          # The routine that stamps a table of pixels onto the hidden page: r0 the colour's slot, r1
          # the table, r2 how many. Each pixel is half of a 16-bit unit, read, spliced and written
          # back, and which half is the pixel's column being odd.
          def emit_text_points_routine
            return unless @text_points_used

            pixel = @emitter.gensym
            odd = @emitter.gensym
            write = @emitter.gensym
            @emitter.emit(ASM.loop_forever) # fall-through guard
            @emitter.place_label(TEXT_POINTS)
            @emitter.emit(ASM.push(14))
            @primitives.load_var(9, BACKBUF)
            @emitter.place_label(pixel)
            @emitter.emit(ASM.load_halfword(3, 1))
            @emitter.emit(ASM.add_imm(1, 1, 2))
            @emitter.emit(ASM.add_reg(10, 9, 3))             # the pixel's byte
            @emitter.emit(ASM.lsr_imm(10, 10, 1))
            @emitter.emit(ASM.lsl_imm(10, 10, 1))            # r10 = the 16-bit unit it is in
            @emitter.emit(ASM.load_halfword(11, 10))
            @emitter.emit(ASM.tst_imm(3, 1))
            @emitter.emit_branch(:bcond, odd, cond: :ne)
            emit_splice_index_reg(11, 0, false)
            @emitter.emit_branch(:b, write)
            @emitter.place_label(odd)
            emit_splice_index_reg(11, 0, true)
            @emitter.place_label(write)
            @emitter.emit(ASM.store_halfword(11, 10))
            @emitter.emit(ASM.subs_imm(2, 2, 1))
            @emitter.emit_branch(:bcond, pixel, cond: :ne)
            @emitter.emit(ASM.pop(15))
            @emitter.place_label(DerivedNames.routine_end(TEXT_POINTS))
          end

          # Where a two-colour line's slot waits while its pixels are written: clear of the
          # page base (r6) and of the two a pixel write works in (r0 and r1).
          TEXT_INDEX = 7

          # Render one run-time digit on the hidden page through the shared glyph-
          # walking routine for this font (see #emit_digit_routines) — the tear-free
          # (indexed) counterpart of Drawing#emit_draw_digit_data, and built the same
          # way: the digit is already in r0 from evaluating node.value, and x, y and
          # the palette index follow as arguments in r1-r3 rather than being baked
          # into a fresh copy of the loop at every digit place.
          def emit_draw_digit_data_buffered(node, font, width, x, y)
            index = @layout.palette.index_of(node.color)
            @lowering.value(node.value)             # r0 = the digit (0..9)
            @emitter.emit_number(1, x)
            @emitter.emit_number(2, y)
            @emitter.emit_number(3, index)
            @placement.emit_call_cold_routine(digit_routine_label(node.font, font, width))
          end

          # The shared routine's label for a font, reserved the first time a digit in
          # that font is drawn on this screen and emitted once, later, by
          # #emit_digit_routines. Named apart from Drawing's own digit routine (same
          # font, different plot) since a program can cross between the two screens.
          def digit_routine_label(font_name, font, width)
            @digit_routines ||= {}
            @digit_routines[font_name] ||= begin
              @pending_digit_routines ||= []
              @pending_digit_routines << [font_name, font, width]
              Messages::MadeNames.make(:buffered_digit_routine, font: font_name)
            end
          end

          # Emit every shared digit routine this screen actually used, once each, after
          # the program's own code (see GBA#lower) — same shape as Drawing's own (a
          # fall-through guard, a label, a body, a return), because like that one this
          # is only ever reached by a call.
          #
          # x, y and the palette index arrive as arguments (r1, r2, r3); they move into
          # r10, r11 and r8 first, because the glyph table lookup that follows needs
          # r1-r3 back as scratch — and because loading the hidden page base in the
          # :hold phase below reaches for r12 (ADDR, see Primitives#emit_var_address_base) to
          # build its address, which would silently overwrite the index if it were
          # held there instead.
          def emit_digit_routines
            return unless @pending_digit_routines

            @pending_digit_routines.each do |font_name, font, width|
              @emitter.emit(ASM.loop_forever) # fall-through guard: only ever entered by the call above
              @emitter.place_label(Messages::MadeNames.make(:buffered_digit_routine, font: font_name))
              @emitter.emit(ASM.push(14))
              @emitter.emit(ASM.mov_reg(10, 1)) # r10 = x, held across the routine
              @emitter.emit(ASM.mov_reg(11, 2)) # r11 = y
              @emitter.emit(ASM.mov_reg(8, 3))  # r8 = the palette index
              @framebuffer.emit_digit_glyph_loop(font_name, font, width) do |phase|
                case phase
                when :hold then @primitives.load_var(9, BACKBUF)          # r9 = the hidden page base, held
                when :plot then emit_plot_digit_index(10, 11, 8)
                end
              end
              @emitter.emit(ASM.pop(15))
              # Where it ends, so a profile of the finished game can say how much of a frame
              # went into drawing digits. A routine the lowering makes has no other record of
              # its span — func_ranges only knows routines somebody wrote.
              @emitter.place_label(DerivedNames.routine_end(Messages::MadeNames.make(:buffered_digit_routine, font: font_name)))
            end
          end

          # Splice one glyph pixel's palette index onto the hidden page: find its byte at
          # (x+col, y+row), read the 16-bit unit that contains it, overwrite just that
          # pixel's byte — low for an even column, high for an odd one — and write it
          # back, since the indexed screen can't take a lone byte write. r9 holds the page
          # base; x_reg/y_reg/index_reg are the shared routine's arguments (see
          # #emit_digit_routines); r5/r4 are the live row/col; r0–r3 are scratch.
          def emit_plot_digit_index(x_reg, y_reg, index_reg)
            @emitter.emit(ASM.add_reg(0, y_reg, 5))          # r0 = screen_y = y + row
            @emitter.emit_number(1, SCREEN_WIDTH)
            @emitter.emit(ASM.mul(2, 0, 1))                  # r2 = screen_y * width
            @emitter.emit(ASM.add_reg(0, x_reg, 4))          # r0 = screen_x = x + col
            @emitter.emit(ASM.add_reg(2, 2, 0))              # r2 = byte offset = screen_y*width + screen_x
            @emitter.emit(ASM.add_reg(1, 9, 2))              # r1 = page_base + offset (the pixel's byte, maybe odd)
            @emitter.emit(ASM.lsr_imm(1, 1, 1))              # clear the low bit ->
            @emitter.emit(ASM.lsl_imm(1, 1, 1))              # r1 = the containing 16-bit unit's address
            @emitter.emit(ASM.load_halfword(0, 1))           # r0 = the current pixel pair
            # width is even, so the offset's parity is the column's: 0 = low/even byte.
            @emitter.emit(ASM.and_imm(3, 2, 1))              # r3 = screen_x & 1
            @emitter.emit(ASM.cmp_imm(3, 0))
            high = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit_branch(:bcond, high, cond: :ne)
            emit_splice_index_reg(0, index_reg, false) # even column: the low byte
            @emitter.emit_branch(:b, done)
            @emitter.place_label(high)
            emit_splice_index_reg(0, index_reg, true)  # odd column: the high byte
            @emitter.place_label(done)
            @emitter.emit(ASM.store_halfword(0, 1))          # write the spliced pair back
          end

          # The same splice as #emit_splice_index_const, with the index arriving in a
          # register rather than a build-time constant — what the shared digit routine
          # needs, since one routine's index varies with which digit call reached it.
          def emit_splice_index_reg(reg, index_reg, high)
            if high
              @emitter.emit(ASM.and_imm(reg, reg, 0x00FF))         # keep the left (low) pixel
              @emitter.emit(ASM.orr_reg_lsl(reg, reg, index_reg, 8)) # set the right (high) pixel
            else
              @emitter.emit(ASM.and_imm(reg, reg, 0xFF00))         # keep the right (high) pixel
              @emitter.emit(ASM.orr_reg(reg, reg, index_reg))      # set the left (low) pixel
            end
          end

          # Plot one pixel on the hidden page. With constant coordinates the target
          # half is known while building; with a computed coordinate it's found from
          # the live x at run time.
          def emit_pixel_buffered(node)
            index = @layout.palette.index_of(node.color)
            xi = @primitives.const_int(node.x)
            yi = @primitives.const_int(node.y)

            if xi && yi
              return unless @framebuffer.in_bounds?(xi, yi)

              base = 6
              @primitives.load_var(base, BACKBUF)
              emit_write_index_pixel_const(base, xi, yi, index)
            else
              emit_pixel_buffered_runtime(node, index)
            end
          end

          # Read-modify-write one pixel at a build-time-constant position: overwrite
          # its byte inside the 16-bit unit, leaving the paired pixel untouched.
          # +base_reg+ holds the hidden page base. Uses r0/r1 as scratch.
          # +index+ is the slot itself, or — with +held+ — the register already holding it.
          def emit_write_index_pixel_const(base_reg, px, py, index, held: false)
            halfword_offset = ((py * SCREEN_WIDTH) + px) & ~1 # start of the pixel's 16-bit unit
            @primitives.emit_add_const(1, base_reg, halfword_offset, ACC) # r1 = &unit (scratch r0)
            @emitter.emit(ASM.load_halfword(ACC, 1))                   # r0 = the current pixel pair
            held ? emit_splice_index_reg(ACC, index, px.odd?) : emit_splice_index_const(ACC, index, px.odd?)
            @emitter.emit(ASM.store_halfword(ACC, 1))
          end

          # Read-modify-write one pixel whose coordinates are computed at run time: the
          # address and which half to touch both come from the live x/y. r2/r3 hold
          # x/y; r1 the unit address; r0 the value being spliced; r4/r5 scratch.
          #
          # ## Why a pixel is a read, a change and a write
          #
          # A pixel here is one byte, a number picking out of the colour table, but video memory
          # takes only whole 16-bit units, so a lone byte cannot be stored. The unit holding the
          # pixel is read, its half is replaced, and the unit written back:
          #
          #   unit at an even address:  [ low byte: even x | high byte: odd x ]
          #   read it (r0), keep the half that is not ours, put the colour number in ours, store it.
          def emit_pixel_buffered_runtime(node, index)
            @lowering.value(node.x)
            @emitter.emit(ASM.mov_reg(2, ACC))
            @lowering.value(node.y)
            @emitter.emit(ASM.mov_reg(3, ACC))

            @emitter.emit_number(4, SCREEN_WIDTH)    # a byte a pixel, so a row is SCREEN_WIDTH bytes
            @emitter.emit(ASM.mul(4, 3, 4))          # r4 = y * width
            @emitter.emit(ASM.add_reg(4, 4, 2))      # r4 = y*width + x (byte offset)
            @primitives.load_var(5, BACKBUF)            # r5 = hidden page base
            @emitter.emit(ASM.add_reg(1, 5, 4))      # r1 = base + byte offset (maybe odd)
            @emitter.emit(ASM.lsr_imm(1, 1, 1))      # clear the low bit ->
            @emitter.emit(ASM.lsl_imm(1, 1, 1))      # r1 = the containing 16-bit unit's address
            @emitter.emit(ASM.load_halfword(ACC, 1)) # r0 = the current pixel pair

            @emitter.emit(ASM.and_imm(4, 2, 1))      # r4 = x & 1 (0 = left/low byte, 1 = right/high)
            @emitter.emit(ASM.cmp_imm(4, 0))
            high = @emitter.gensym
            done = @emitter.gensym
            @emitter.emit_branch(:bcond, high, cond: :ne)
            emit_splice_index_const(ACC, index, false) # even x: low byte
            @emitter.emit_branch(:b, done)
            @emitter.place_label(high)
            emit_splice_index_const(ACC, index, true)  # odd x: high byte
            @emitter.place_label(done)
            @emitter.emit(ASM.store_halfword(ACC, 1))
          end

          # Replace one byte of the 16-bit pixel pair in +reg+ with +index+, keeping
          # the other pixel: the high byte when +high+ (an odd column), else the low.
          def emit_splice_index_const(reg, index, high)
            if high
              @emitter.emit(ASM.and_imm(reg, reg, 0x00FF))     # keep the left (low) pixel
              @emitter.emit(ASM.orr_imm(reg, reg, index << 8)) # set the right (high) pixel
            else
              @emitter.emit(ASM.and_imm(reg, reg, 0xFF00))     # keep the right (high) pixel
              @emitter.emit(ASM.orr_imm(reg, reg, index))      # set the left (low) pixel
            end
          end

          # One column of a picture, stretched to a height the game works out — on the
          # tear-free screen.
          #
          # It walks down the screen and asks which picture row belongs at each screen row,
          # exactly as the direct-color screen does, because that is what makes the two
          # screens and the interpreter land every pixel in the same place. What differs is
          # the two things this screen forces: a pixel is one BYTE (a number picking a color
          # out of the shared table) rather than two, and video memory refuses a lone byte —
          # the smallest write covers a side-by-side pair of pixels. So every pixel is a
          # read of its pair, a splice of its own half, and a write back.
          #
          # Two questions are answered once here that the other screen asks at every pixel,
          # and both come from the same fact: a column has one x for its whole height.
          #
          #   - The screen's left and right edges. A column is either on the screen or it is
          #     not, so it is tested before the first row instead of at every one.
          #   - Which half of the pair to write. A row is an even number of bytes across, so
          #     the parity of a pixel's address is the parity of its column — the same half,
          #     every row, all the way down. That also means the unit's address needs no
          #     rounding as it walks: it starts on the pair the column sits in and steps one
          #     screen width per row.
          def emit_draw_column_at_buffered(node)
            bmp = @layout.bitmaps.fetch(node.name) do
              raise LoweringError, "draw_column_at of undefined image #{node.name.inspect}"
            end
            width = node.width || 1
            # The number no colour has, which a row is asked about — unless every row the walk
            # reaches is a pixel, and then none is.
            clear = @layout.indexed_bitmaps[node.name] unless @framebuffer.column_rows_all_pixels?(node.name)

            done = @emitter.gensym
            @framebuffer.emit_column_setup(node, bmp, done, blob: @framebuffer.column_blob(node.name), pixel_bytes: 1,
                                                            by_column: true)
            @framebuffer.emit_column_runs(node.name, bmp, done) do |leave|
              # Clipped BEFORE the destination is worked out, so the destination points at the
              # first row that shows rather than at a row above the screen.
              @framebuffer.emit_clip_column_rows(leave)
              emit_column_destination

              # A strip wholly inside the edges writes with nothing to test; one hanging over an
              # edge takes a second copy of the rows that tests each of its pixels. A strip one
              # pixel wide has no second case — it is inside or it draws nothing.
              clipped = @emitter.gensym
              @emitter.emit(ASM.cmp_imm(COLUMN_X, @framebuffer.clip_left))
              @emitter.emit_branch(:bcond, clipped, cond: :lt)
              @emitter.emit_number(TMP, @framebuffer.clip_right - width)
              @emitter.emit(ASM.cmp_reg(COLUMN_X, TMP))
              @emitter.emit_branch(:bcond, clipped, cond: :gt)

              emit_buffered_column_bodies(width, clear, Parity.of(node.x))
              @emitter.emit_branch(:b, leave) if width > 1
              @emitter.place_label(clipped)
              emit_buffered_column_rows { emit_buffered_column_row(width, clear, nil) } if width > 1
            end
            @emitter.place_label(done)
          end

          # The strip writes whole pairs where it can, which needs to know whether it starts on
          # an even column or an odd one. Proved while building, that is one copy of the rows —
          # a view drawing its strips two pixels wide writes `col * 2`, and twice anything is
          # even. Otherwise the low bit is tested once, here, and each answer gets its own copy:
          # every row of a strip starts in the same column, so a test inside the walk would ask
          # the same question a hundred and sixty times over.
          def emit_buffered_column_bodies(width, clear, parity)
            if parity
              return emit_buffered_column_rows do
                emit_buffered_column_row(width, clear, parity == :odd)
              end
            end

            odd = @emitter.gensym
            both = @emitter.gensym
            @emitter.emit(ASM.and_imm(ACC, COLUMN_X, 1))
            @emitter.emit(ASM.cmp_imm(ACC, 0))
            @emitter.emit_branch(:bcond, odd, cond: :ne)
            emit_buffered_column_rows { emit_buffered_column_row(width, clear, false) }
            @emitter.emit_branch(:b, both)
            @emitter.place_label(odd)
            emit_buffered_column_rows { emit_buffered_column_row(width, clear, true) }
            @emitter.place_label(both)
          end

          # The unit the strip's first row writes into: the hidden page, that row, and the
          # column rounded down to the pair it shares. A top above the screen makes this an
          # address before the page, which is fine — the walk steps forward to it and writes
          # nothing until the row is on screen.
          def emit_column_destination
            @emitter.emit_number(TMP, SCREEN_WIDTH)
            @emitter.emit(ASM.mul(COLUMN_DEST, COLUMN_Y, TMP)) # 1 byte a pixel, so this is bytes
            @primitives.load_var(TMP, BACKBUF)
            @emitter.emit(ASM.add_reg(COLUMN_DEST, COLUMN_DEST, TMP))
            @emitter.emit(ASM.lsr_imm(TMP, COLUMN_X, 1)) # clear the low bit ->
            @emitter.emit(ASM.lsl_imm(TMP, TMP, 1))      # ...the pair this column sits in
            @emitter.emit(ASM.add_reg(COLUMN_DEST, COLUMN_DEST, TMP))
          end

          # The walk down the screen. The destination steps one screen width a row, which is
          # why the pair it points at needed rounding only once: a row is an even number of
          # bytes across, so every row of a strip sits the same way inside its pair. That is
          # also why the walk keeps no count of which screen row it is on — the destination
          # already holds it, and nothing in the walk asks.
          def emit_buffered_column_rows
            @primitives.emit_row_loop(COLUMN_ROWS) do
              yield
              @emitter.emit(ASM.add_reg(COLUMN_POS, COLUMN_POS, COLUMN_STEP))
              @emitter.emit(ASM.add_imm(COLUMN_DEST, COLUMN_DEST, SCREEN_WIDTH)) # one row down
            end
          end

          # One row of the strip: which picture row belongs at this screen row, read it, and
          # write it across — unless the row is off the top or bottom of the screen, in which
          # case the walk goes on without drawing, so a wall taller than the screen still lands
          # where it should. +starts_odd+ is nil in the copy that has to test each pixel.
          def emit_buffered_column_row(width, clear, starts_odd)
            skip = @emitter.gensym
            emit_read_column_number(clear, skip)

            if starts_odd.nil?
              width.times { |dx| emit_buffered_column_pixel_clipped(dx) }
            else
              emit_buffered_column_units(width, starts_odd)
            end
            @emitter.place_label(skip)
          end

          # number = column[pos >> 16], COLUMN_SRC already pointing at the picture's column in
          # its column-by-column copy (see Framebuffer#column_blob), so a row's number is the
          # next byte down rather than a whole picture width along — one load, no multiply.
          # Leaves it in ACC, or jumps to +skip+ when the pixel is see-through. Nothing holds
          # the row back — see the note on the direct screen's reader for why it cannot run past
          # the picture.
          def emit_read_column_number(clear, skip)
            @emitter.emit(ASM.ldrb_reg_lsr(ACC, COLUMN_SRC, COLUMN_POS, COLUMN_FIXED))

            # A see-through pixel carries the one number that is not any color in the table,
            # so it means "leave this one alone" and the pair is not touched at all.
            return unless clear

            @emitter.emit_number(TMP, clear)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, skip, cond: :eq)
          end

          # WHICH 16-BIT UNITS a strip of +width+ pixels touches, and what each one needs. A
          # unit whose both pixels belong to the strip is written outright — no read, no
          # splice, since nothing of it survives. Only a unit the strip half covers has to be
          # read and spliced. That is what makes a strip cheaper than its pixels: three pixels
          # are one whole pair and one splice, not three splices.
          def column_units(width, starts_odd)
            first = starts_odd ? 1 : 0 # the strip's first pixel, as a byte within its pair
            (first...(first + width)).group_by { |byte| byte / 2 }.map do |unit, bytes|
              kind = if bytes.length == 2 then :both
                     elsif bytes.first.even? then :low
                     else :high
                     end
              [unit * 2, kind]
            end
          end

          def emit_buffered_column_units(width, starts_odd)
            units = column_units(width, starts_odd)
            # The number in both halves, for the units the strip covers whole.
            @emitter.emit(ASM.orr_reg_lsl(SPARE, ACC, ACC, 8)) if units.any? { |(_, kind)| kind == :both }

            units.each do |offset, kind|
              next @emitter.emit(ASM.store_halfword_offset(SPARE, COLUMN_DEST, offset)) if kind == :both

              @emitter.emit(ASM.load_halfword_offset(TMP, COLUMN_DEST, offset))
              if kind == :high
                @emitter.emit(ASM.and_imm(TMP, TMP, 0x00FF))
                @emitter.emit(ASM.orr_reg_lsl(TMP, TMP, ACC, 8))
              else
                @emitter.emit(ASM.and_imm(TMP, TMP, 0xFF00))
                @emitter.emit(ASM.orr_reg(TMP, TMP, ACC))
              end
              @emitter.emit(ASM.store_halfword_offset(TMP, COLUMN_DEST, offset))
            end
          end

          # One pixel of a strip that hangs off an edge: its own column is tested, and which
          # half of its pair it lands in is worked out as it goes. The dear way of doing it,
          # and only the strips at the edges of the screen ever run it.
          def emit_buffered_column_pixel_clipped(offset)
            past = @emitter.gensym
            @emitter.emit(ASM.add_imm(SPARE, COLUMN_X, offset))
            @emitter.emit(ASM.cmp_imm(SPARE, @framebuffer.clip_left))
            @emitter.emit_branch(:bcond, past, cond: :lt)
            @emitter.emit(ASM.cmp_imm(SPARE, @framebuffer.clip_right))
            @emitter.emit_branch(:bcond, past, cond: :ge)

            # The pixel's own byte, then the pair it sits in and which half of it that is.
            @emitter.emit(ASM.and_imm(TMP, COLUMN_X, 1))
            @emitter.emit(ASM.add_imm(TMP, TMP, offset))
            @emitter.emit(ASM.add_reg(TMP, TMP, COLUMN_DEST))
            @emitter.emit(ASM.and_imm(HIGH, TMP, 1))
            @emitter.emit(ASM.lsr_imm(TMP, TMP, 1))
            @emitter.emit(ASM.lsl_imm(TMP, TMP, 1))
            @emitter.emit(ASM.load_halfword(SPARE, TMP))

            high = @emitter.gensym
            wrote = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(HIGH, 0))
            @emitter.emit_branch(:bcond, high, cond: :ne)
            @emitter.emit(ASM.and_imm(SPARE, SPARE, 0xFF00))
            @emitter.emit(ASM.orr_reg(SPARE, SPARE, ACC))
            @emitter.emit_branch(:b, wrote)
            @emitter.place_label(high)
            @emitter.emit(ASM.and_imm(SPARE, SPARE, 0x00FF))
            @emitter.emit(ASM.orr_reg_lsl(SPARE, SPARE, ACC, 8))
            @emitter.place_label(wrote)
            @emitter.emit(ASM.store_halfword(SPARE, TMP))
            @emitter.place_label(past)
          end

          # Stamp a tile at a place known while building, leaving the pixels of +see_through+ (a tile
          # with the see-through pixels marked, Image#with_tile_see_through_marked) as they are. A row
          # copy cannot skip a pixel, so each row is written a pair of pixels at a time, the unit
          # video memory takes: a pair both drawn is copied across whole, a pair with one drawn pixel
          # has that half spliced in, and a pair with none is not touched. Pixels outside the draw
          # area are left out the same way, so nothing is written past the end of a line.
          #
          # The pairs are the screen's: a tile at an odd column, or of an odd width, has a pixel of
          # its own in a pair whose other half is another's. A pair both drawn whose two pixels sit
          # on one halfword of the tile too is copied as it is; otherwise its two bytes are read
          # one at a time and put together.
          #
          # Must only be asked of a tile #stamp_by_pairs? accepts. A tile whose pixels all draw, in
          # whole pairs of the screen's, is blitted whole instead (#emit_blit_buffered).
          def emit_stamp_tile_buffered(node, see_through)
            x = @primitives.const_int(node.x)
            y = @primitives.const_int(node.y)
            @emitter.emit_load_data_address(BLIT_SRC, @framebuffer.indexed_blob(node.name))
            @primitives.load_var(BLIT_TO, BACKBUF)
            see_through.height.times do |row|
              next unless (@framebuffer.clip_top...@framebuffer.clip_bottom).cover?(y + row)

              emit_stamp_row_in_pairs(see_through, row, x, y + row)
            end
          end

          # Whether +picture+ (a tile with its see-through pixels marked) at the place +node+ has to be
          # stamped by #emit_stamp_tile_buffered: the place is known while building, and some pixel of
          # the tile is not drawn or the tile is not whole pairs of the screen's (an odd column or
          # width), which a row copy cannot take.
          def stamp_by_pairs?(node, picture)
            x = @primitives.const_int(node.x)
            return false unless x && @primitives.const_int(node.y)
            return true if x.odd? || picture.width.odd?

            (0...(picture.width * picture.height)).any? { |at| !picture.drawn_at?(at) }
          end

          # How far, in pixels, one base address of a row's stamp reaches: a halfword's load and
          # store take an offset of under 256 bytes, so a wider row is stamped from a new base
          # every this many pixels.
          STAMP_REACH = 240

          # One row of a see-through stamp. Both base registers point at the same screen column, the
          # first of a pair, one on the page and one in the tile (a column before the tile's first,
          # for a tile at an odd column), so a pixel's offset is the same from either.
          def emit_stamp_row_in_pairs(picture, row, x, screen_row)
            first = x & ~1
            pairs = (first...(x + picture.width)).step(2).filter_map do |column|
              low = stamped_pixel?(picture, row, column - x, column)
              high = stamped_pixel?(picture, row, column + 1 - x, column + 1)
              [column, low, high] if low || high
            end
            pairs.group_by { |column, _, _| (column - first) / STAMP_REACH }.each_value do |reach|
              base = first + (((reach.first[0] - first) / STAMP_REACH) * STAMP_REACH)
              tile_at = (row * picture.width) + base - x
              @primitives.emit_add_const(BLIT_FROM, BLIT_SRC, tile_at, SPARE)
              @primitives.emit_add_const(BLIT_LEFT, BLIT_TO, (screen_row * SCREEN_WIDTH) + base, SPARE)
              reach.each do |column, low, high|
                emit_stamp_pair(column - base, low, high, tile_halfword: tile_at.even?)
              end
            end
          end

          # One pair of pixels of a stamp, +offset+ bytes past both bases: its +low+ and +high+ pixels
          # each written where it is drawn. +tile_halfword+ is whether the pair is one halfword of the
          # tile as well as of the page.
          def emit_stamp_pair(offset, low, high, tile_halfword:)
            if low && high && tile_halfword
              @emitter.emit(ASM.load_halfword_offset(ACC, BLIT_FROM, offset))
            elsif low && high
              @emitter.emit(ASM.ldrb_offset(ACC, BLIT_FROM, offset))
              @emitter.emit(ASM.ldrb_offset(SPARE, BLIT_FROM, offset + 1))
              @emitter.emit(ASM.orr_reg_lsl(ACC, ACC, SPARE, 8))
            else
              @emitter.emit(ASM.ldrb_offset(ACC, BLIT_FROM, offset + (low ? 0 : 1)))
              @emitter.emit(ASM.load_halfword_offset(SPARE, BLIT_LEFT, offset))
              emit_splice_index_reg(SPARE, ACC, !low)
              return @emitter.emit(ASM.store_halfword_offset(SPARE, BLIT_LEFT, offset))
            end
            @emitter.emit(ASM.store_halfword_offset(ACC, BLIT_LEFT, offset))
          end

          # Whether the tile's pixel at +column+ of its +row+, which lands on the screen's
          # +screen_column+, is stamped: it is one of the tile's, draws something, and sits inside the
          # draw area.
          def stamped_pixel?(picture, row, column, screen_column)
            (0...picture.width).cover?(column) && picture.drawn_at?((row * picture.width) + column) &&
              (@framebuffer.clip_left...@framebuffer.clip_right).cover?(screen_column)
          end

          # Draw a whole picture on the hidden page.
          #
          # The picture is shipped a second time as one number a pixel (see
          # GBA#prepare_indexed_bitmaps), so a row of it is already the bytes the screen
          # wants and a row copy is a straight run of memory — the same shape the
          # direct-color blit has, with a byte a pixel instead of two.
          #
          # What makes it a straight copy is that everything lines up in pairs. Video
          # memory here takes two pixels at a time and will not take one, so the copying
          # engine moves 16-bit units and every end of the run has to fall on one: the
          # column the picture starts at, the picture's own width, and therefore the part
          # of each row that survives clipping. An even column and an even width give all
          # three, which is why both are asked for rather than worked around.
          def emit_blit_buffered(node, bmp)
            refuse_see_through_blit!(node.name) if @layout.indexed_bitmaps[node.name]
            refuse_odd_blit_column!(node) unless Parity.even?(node.x)
            refuse_odd_blit_width!(node.name, bmp) unless bmp.width.even?

            emit_blit_rows_buffered(node, bmp)
          end

          # Registers held for the whole picture: r6 the picture's numbers in the
          # cartridge, r7 its left column, r8 its top row. The rest are worked out afresh
          # each row, exactly as the direct-color engine does — a picture is a handful of
          # rows, not the hundreds a per-column renderer walks, so there is nothing here
          # worth hoisting.
          BLIT_SRC = 6
          BLIT_X = 7
          BLIT_Y = 8
          BLIT_ROW_Y = 9
          BLIT_UNITS = 4
          BLIT_FROM = 5
          BLIT_TO = 3
          BLIT_LEFT = 10
          BLIT_RIGHT = 11

          # One clipped row copy per row of the picture, unrolled. A row above or below
          # the area is dropped whole; a row hanging off a side is narrowed to the part
          # that shows, so nothing is ever written past the end of a line and onto the
          # start of the next one.
          def emit_blit_rows_buffered(node, bmp)
            @lowering.value(node.x)
            @emitter.emit(ASM.mov_reg(BLIT_X, ACC))
            @lowering.value(node.y)
            @emitter.emit(ASM.mov_reg(BLIT_Y, ACC))
            @emitter.emit_load_data_address(BLIT_SRC, @framebuffer.indexed_blob(node.name))

            bmp.height.times { |row| emit_blit_row_buffered(bmp, row) }
          end

          #
          # ## A row, from the picture to the page
          #
          #   picture row (bytes):     [ ..cut.. | shown part, r4 pixels | ..cut.. ]
          #   copied by the engine:                r5 ---------------------> r3
          #   hidden page, line r9:    [          ...      r3 ........ ]
          #
          # Each row goes through the same five steps below: is the line on the page, which part
          # of the row is left after the sides, the odd single pixels at an area's edge, the two
          # addresses, and the copy.
          def emit_blit_row_buffered(bmp, row)
            skip = @emitter.gensym
            @primitives.emit_add_const(BLIT_ROW_Y, BLIT_Y, row, SPARE)
            @emitter.emit(ASM.cmp_imm(BLIT_ROW_Y, @framebuffer.clip_top))
            @emitter.emit_branch(:bcond, skip, cond: :lt)
            @emitter.emit(ASM.cmp_imm(BLIT_ROW_Y, @framebuffer.clip_bottom))
            @emitter.emit_branch(:bcond, skip, cond: :ge)

            emit_blit_row_span(bmp, skip)
            emit_blit_row_odd_ends(bmp, row, skip)
            emit_blit_row_addresses(bmp, row)
            emit_blit_row_copy
            @emitter.place_label(skip)
          end

          # What is left of this row after the sides: r10 its first column, r11 one past
          # its last, r4 how many pixels that is. A row entirely off to one side leaves.
          def emit_blit_row_span(bmp, skip)
            @emitter.emit(ASM.mov_reg(BLIT_LEFT, BLIT_X))
            @emitter.emit(ASM.cmp_imm(BLIT_X, @framebuffer.clip_left))
            keep_left = @emitter.gensym
            @emitter.emit_branch(:bcond, keep_left, cond: :ge)
            @emitter.emit_number(BLIT_LEFT, @framebuffer.clip_left)
            @emitter.place_label(keep_left)

            @primitives.emit_add_const(BLIT_RIGHT, BLIT_X, bmp.width, SPARE)
            @emitter.emit(ASM.cmp_imm(BLIT_RIGHT, @framebuffer.clip_right))
            keep_right = @emitter.gensym
            @emitter.emit_branch(:bcond, keep_right, cond: :le)
            @emitter.emit_number(BLIT_RIGHT, @framebuffer.clip_right)
            @emitter.place_label(keep_right)

            @emitter.emit(ASM.sub_reg(BLIT_UNITS, BLIT_RIGHT, BLIT_LEFT))
            @emitter.emit(ASM.cmp_imm(BLIT_UNITS, 0))
            @emitter.emit_branch(:bcond, skip, cond: :le)
          end

          # The ends of a row cut by an area with an odd edge. The picture starts on an even
          # column and is an even number of pixels wide, so only an area's edge can cut a row
          # halfway through a pair. A pixel left alone at either end is written on its own — read
          # the pair, change that half, write it back — and the row is narrowed past it, so the
          # copy between moves whole pairs. Without this the copy dropped those pixels, and a row
          # cut down to the one pixel asked the copy engine for no pairs, which it reads as its
          # biggest count: it wrote over all of video memory. The edges are settled while
          # building, so an area with even edges, and the whole screen, emit none of this.
          def emit_blit_row_odd_ends(bmp, row, skip)
            left_odd = @framebuffer.clip_left.odd?
            right_odd = @framebuffer.clip_right.odd?
            return unless left_odd || right_odd

            emit_blit_row_end_pixel(bmp, row, BLIT_LEFT, high: true, after: -> { @emitter.emit(ASM.add_imm(BLIT_LEFT, BLIT_LEFT, 1)) }) if left_odd
            emit_blit_row_end_pixel(bmp, row, BLIT_RIGHT, high: false, before: -> { @emitter.emit(ASM.sub_imm(BLIT_RIGHT, BLIT_RIGHT, 1)) }) if right_odd
            @emitter.emit(ASM.sub_reg(BLIT_UNITS, BLIT_RIGHT, BLIT_LEFT))
            @emitter.emit(ASM.cmp_imm(BLIT_UNITS, 0))
            @emitter.emit_branch(:bcond, skip, cond: :le)
          end

          # One end of the row written alone when the end in +column+ is odd. The left end's
          # first pixel is then the right half of its pair (+high+); the right end, one past the
          # last pixel, leaves that last pixel as the left half of its own. +before+ and +after+
          # move the end past the pixel, so +column+ names that pixel's column while it is written.
          def emit_blit_row_end_pixel(bmp, row, column, high:, before: nil, after: nil)
            whole = @emitter.gensym
            @emitter.emit(ASM.tst_imm(column, 1))
            @emitter.emit_branch(:bcond, whole, cond: :eq)
            before&.call
            @emitter.emit(ASM.sub_reg(ACC, column, BLIT_X))         # how far into the picture's row
            @primitives.emit_add_const(ACC, ACC, row * bmp.width, SPARE)
            @emitter.emit(ASM.ldrb_reg(ACC, BLIT_SRC, ACC))         # r0 = its colour slot
            @emitter.emit_number(SPARE, SCREEN_WIDTH)
            @emitter.emit(ASM.mul(TMP, BLIT_ROW_Y, SPARE))
            @emitter.emit(ASM.add_reg(TMP, TMP, column))
            @primitives.load_var(SPARE, BACKBUF)
            @emitter.emit(ASM.add_reg(TMP, TMP, SPARE))
            @emitter.emit(ASM.bic_imm(TMP, TMP, 1)) if high         # the pair it is the right half of
            @emitter.emit(ASM.load_halfword(SPARE, TMP))
            emit_splice_index_reg(SPARE, ACC, high)
            @emitter.emit(ASM.store_halfword(SPARE, TMP))
            after&.call
            @emitter.place_label(whole)
          end

          # Where the row is read from (r5) and written to (r3). Both are byte addresses
          # and both are even: the picture's width is even so a row starts on a pair, and
          # the column is even so what the sides cut off is a whole number of pairs.
          def emit_blit_row_addresses(bmp, row)
            @emitter.emit(ASM.sub_reg(BLIT_FROM, BLIT_LEFT, BLIT_X))     # how much of the row the left edge ate
            @primitives.emit_add_const(BLIT_FROM, BLIT_FROM, row * bmp.width, SPARE)
            @emitter.emit(ASM.add_reg(BLIT_FROM, BLIT_SRC, BLIT_FROM))

            @emitter.emit_number(SPARE, SCREEN_WIDTH)
            @emitter.emit(ASM.mul(BLIT_TO, BLIT_ROW_Y, SPARE)) # a byte a pixel, so this is already bytes
            @emitter.emit(ASM.add_reg(BLIT_TO, BLIT_TO, BLIT_LEFT))
            @primitives.load_var(SPARE, BACKBUF)
            @emitter.emit(ASM.add_reg(BLIT_TO, BLIT_TO, SPARE))
          end

          # Hand the row to the copying engine: two pixels a unit, source and destination
          # both stepping forward.
          def emit_blit_row_copy
            @emitter.emit(ASM.lsr_imm(BLIT_UNITS, BLIT_UNITS, 1))
            @emitter.emit_number(SPARE, DMA_ENABLE)
            @emitter.emit(ASM.orr_reg(BLIT_UNITS, BLIT_UNITS, SPARE))
            @primitives.emit_start_copy_engine(from: in_register(BLIT_FROM), to: in_register(BLIT_TO),
                                   control: in_register(BLIT_UNITS))
          end

          # Why the screen wants pairs, said the same way in every one of these three. It is
          # the one fact behind all of them, and a person who reads it once has read it.
          TAKES_PAIRS = "The screen takes two pixels at a time and will not take one."

          def refuse_see_through_blit!(name)
            raise LoweringError,
                  "The picture :#{name} has see-through pixels. The tear-free screen " \
                  "(`tear_free: true`) cannot draw a see-through picture yet. It draws a solid " \
                  "picture. Draw this picture with no see-through pixels, or drop `tear_free:` to " \
                  "use the direct-color screen, where a see-through picture works."
          end

          def refuse_odd_blit_column!(node)
            column = @primitives.const_int(node.x)
            found = column ? "This picture starts at column #{column}." : "The game works this column out as it runs."
            fix = column ? "Move the picture one pixel." : "Work the column out as an even number. Multiply it by 2."
            raise LoweringError,
                  "On the tear-free screen (`tear_free: true`), a picture must start at an even " \
                  "column. #{found} #{TAKES_PAIRS} The framework cannot copy a picture that starts " \
                  "halfway through a pair. #{fix}"
          end

          def refuse_odd_blit_width!(name, bmp)
            raise LoweringError,
                  "On the tear-free screen (`tear_free: true`), a picture must have an even width. " \
                  "The picture :#{name} is #{bmp.width} pixels wide. #{TAKES_PAIRS} The framework " \
                  "cannot copy a row that ends halfway through a pair. Add a column to the picture, " \
                  "or drop `tear_free:` to use the direct-color screen."
          end
        end
      end
    end
  end
end
