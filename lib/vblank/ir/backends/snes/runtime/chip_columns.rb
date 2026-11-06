# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A PICTURE'S COLUMN STRETCHED DOWN THE SCREEN, ON THE SUPER FX: the walls of a first-person
          # view, painted by the chip (a cartridge with that chip, a routine marked `on_chip: true`).
          #
          # THE PICTURE IS PAINT'S, in the chip's RAM (ChipPaint): tiles of eight bits a pixel, 32 to
          # a row of them, each keeping its pixels in planes. One pixel is a bit in each of eight
          # bytes, and the eight pixels of a tile's row share those same eight bytes. So a column
          # painted on its own costs eight bytes read and eight written for every pixel, while eight
          # columns side by side in one tile cost eight bytes written for every eight pixels. That is
          # what this does: the columns a run draws are held back, eight neighbours at a time, and
          # painted a row of eight pixels at a time.
          #
          # HOLDING BACK. ChipCode writes each column the game draws (its x, top and height, where the
          # picture's column starts in the cartridge, the picture's height, how many columns wide the
          # strip is and whether the picture has see-through pixels) onto a QUEUE, and calls PROCESS
          # when the queue is full and FINISH as the run ends. PROCESS works out what the console's
          # lowering works out for a column (Lowering::Paint#emit_column_walk): the step down the
          # picture, the rows inside the area, and where the walk stands at the first of them. Each
          # column of the strip inside the area goes into a SLOT of the BATCH, the slot of its place
          # in its tile, and the batch is painted (PAINT) when a column comes that belongs to another
          # tile or to a slot already taken, and as the run ends. Nothing else a run on the chip does
          # reads the screen, so painting later paints the same picture.
          #
          # PAINTING A BATCH. First the tiles it covers are made ready, as Paint's rt_paint_mark does
          # (READY, below). Then each slot's column is walked down the picture into a scratch column
          # of bytes, a byte a pixel, one column of them for each slot (WALK). Then the chip's PLOT
          # paints the batch's rows from those bytes, a row of eight at a time (ROWS): PLOT keeps the
          # pixels of a tile's row and writes the row's eight bytes once all eight are in, or reads
          # them first and writes back only its own when fewer are.
          #
          # PLOT LEAVES A PIXEL OF PLACE 0 AS IT WAS. So the chip's own table of a picture's columns
          # (Lowering::Paint#column_sections) has place 0 for a see-through pixel, and its black
          # painted from another place of the same black (PaintedArt#place_never_nought). A RAGGED
          # batch, with a slot empty or a column whose top or bottom is not the others', fills its
          # scratch columns with nought first, so what no column covers is left as it was too.
          #
          # PLOT'S LAYOUT IS NOT PAINT'S, but one of its layouts can be made to land on Paint's. In
          # its "OBJ" layout PLOT takes the tile for (x, y) as y's top bit, then x's, then y's next
          # four bits, then x's next four, 64 bytes a tile from the start of the chip's RAM (fullsnes,
          # "SNES Cart GSU-n Bitmap"; bsnes, SuperFX::flushPixelCache). Paint's tile for a row r and a
          # tile column t is r / 8 * 32 + t. So the screen's (8t + p, r) is plotted at
          #
          #   x = (r & 64) * 2 | (t & 15) * 8 | p
          #   y = (r & 128) | (r & 56) * 2 | (t & 16) / 2 | (r & 7)
          #
          # which names the same tile, the same row in it and the same pixel of the row. Within a
          # tile's row of the screen x counts on by one, as PLOT moves on by itself, and y is the
          # same; a row down inside a tile is y one more.
          #
          # FIRST, THE TILES THE BATCH COVERS ARE MADE READY. A tile of an older generation is the
          # clear colour throughout whatever its bytes hold, so before any of it is painted its 64
          # bytes are made the clear colour's and its generation this one. A tile the batch paints
          # every pixel of (a batch that is not ragged, with no see-through pixels, and a tile from
          # its top to its bottom) is not filled first: every byte of it is written anyway. Such a
          # tile's cell of the
          # map, in work RAM, still shows the clear tile, which the chip cannot change: the tile goes
          # on the list READIED, and the console points its cell back at it when the chip stops
          # (Lowering::Chip). Each row of tiles keeps the leftmost and rightmost tile changed since
          # the last blank (Paint's DIRTY), which the console copies in before the run and back after.
          #
          # THE CHIP'S QUICK MEMORY. Code the chip runs from its 512-byte cache takes a cycle a byte,
          # and from the ROM five. PROCESS starts the cache where it begins, and the code comes in
          # the order of how often it runs: for every pixel (WALK, ROWS), every row of tiles (PLOT,
          # READY), every column (DIVIDE, the queue); what runs once a batch comes last, and may be
          # past the cache's end.
          module ChipColumns
            PROCESS = "chip columns process"
            FINISH = "chip columns finish"
            START = "chip columns start"
            PAINT = "chip columns paint"
            READY = "chip columns ready"
            WALK = "chip columns walk"
            ROWS = "chip columns rows"
            PLOT = "chip columns plot"
            DIVIDE = "chip columns divide"

            # A column on the queue, as ChipCode writes it: the offset of each word.
            X = 0
            TOP = 4
            HEIGHT = 8
            TEXELS = 12
            BANK = 14
            PICTURE_HEIGHT = 16
            ACROSS = 18
            SEE = 20
            ENTRY = 22
            QUEUE_ENTRIES = 16

            # A column of the batch, a slot of it, and the same worked out for the column at hand
            # (+record+): its first row on the screen, how many rows, where the walk stands at the
            # first (65536ths of a row of the picture, low half first) and its step, and where the
            # picture's column is in the cartridge.
            SLOT_Y = 0
            SLOT_ROWS = 2
            SLOT_AT = 4
            SLOT_STEP = 8
            SLOT_TEXELS = 12
            SLOT_BANK = 14
            SLOT = 16
            SLOTS = 8

            # A scratch column of bytes for each slot, as tall as the screen.
            SCRATCH_COLUMN = Paint::HEIGHT
            # PLOT's settings (POR): place 0 left as it was (bit 0 clear), in the OBJ layout (bit 4).
            PLOT_SETTINGS = 0x10

            # The 16-bit places in the chip's RAM it uses. +queue+ (QUEUE_ENTRIES of ENTRY bytes),
            # +queue_end+ where the next goes; +slots+ (SLOTS of SLOT bytes) and the batch's +mask+ of
            # slots taken, its tile +column+, its +top+ row and +bottom+ (just past), whether it is
            # +ragged+ and whether it has +holes+ (see-through pixels); +record+ (SLOT bytes), +see+,
            # +x+ (32 bits) and +across+ for the column at hand; +memo+, the last picture height,
            # column height (32 bits) and step (32 bits) worked out; +scratch+, the scratch columns;
            # +state+, words for the routines' own use; and what the console hands over of the
            # painted screen: the screen's +generation+, the clear colour's four words of planes
            # (+clear+), each row of tiles' leftmost and rightmost changed tile (+dirty+), the tiles
            # made ready (+readied+, after +readied_count+, the bytes of it in use), and the +area+
            # painting is held to (left, top, right, bottom, four bytes each).
            Places = Data.define(:queue, :queue_end, :slots, :mask, :column, :top, :bottom, :ragged, :holes, :record, :see,
                                 :x, :across, :memo, :scratch, :state, :generation, :clear, :dirty, :readied_count,
                                 :readied, :area) do
              def area_left = area[0]
              def area_top = area[1]
              def area_right = area[2]
              def area_bottom = area[3]
              def queue_limit = queue + (QUEUE_ENTRIES * ENTRY)
            end

            # The words of +state+: where PROCESS is on the queue, the ways back of PROCESS, FINISH
            # PAINT and PLOT, the row PLOT is at, the batch's PLOT x and y for its tile column, what READY
            # makes ready (the tile column, a first row and how many rows), and the rows of tiles it
            # need not fill with the clear colour (from +whole_from+ to just before +whole_to+).
            STATE = %i[at process_back finish_back paint_back plot_back row x_base y_base ready_rows whole_from whole_to].freeze
            STATE_BYTES = STATE.length * 2

            # The bytes of each of Places, for ChipCode to keep them.
            BYTES = { queue: QUEUE_ENTRIES * ENTRY, queue_end: 2, slots: SLOTS * SLOT, mask: 2, column: 2, top: 2,
                      bottom: 2, ragged: 2, holes: 2, record: SLOT, see: 2, x: 4, across: 2, memo: 10,
                      scratch: SLOTS * SCRATCH_COLUMN, state: STATE_BYTES }.freeze

            # The generations' place as the chip counts it, from the start of its RAM.
            GENERATIONS = ChipPaint::GENERATIONS - ChipPaint::COPY

            module_function

            # The routines into +gsu+. +multiply+ is the label of ChipSums's multiplication.
            def emit(gsu, places, multiply:)
              emit_start(gsu, places)
              emit_finish(gsu, places)
              gsu.label(PROCESS)
              gsu.sm(state(places, :process_back), 11)
              gsu.cache
              gsu.iwt(15, "chip columns entries")
              gsu.nop
              emit_walk(gsu)
              emit_rows(gsu)
              emit_plot(gsu, places)
              emit_ready(gsu, places)
              emit_divide(gsu)
              emit_entries(gsu, places, multiply)
              emit_paint(gsu, places)
            end

            # The word of +places+'s state for +what+ (STATE).
            def state(places, what) = places.state + (STATE.index(what) * 2)

            def emit_call(gsu, label)
              gsu.link(4)
              gsu.iwt(15, label)
              gsu.nop
            end

            def emit_return(gsu)
              gsu.jmp(11)
              gsu.nop
            end

            # START: the queue and the batch empty, and nothing worked out yet.
            def emit_start(gsu, places)
              gsu.label(START)
              gsu.iwt(0, places.queue)
              gsu.sm(places.queue_end, 0)
              gsu.ibt(0, 0)
              [places.mask, places.ragged, places.holes, places.memo, places.memo + 2, places.memo + 4].each { |at| gsu.sm(at, 0) }
              emit_return(gsu)
            end

            # FINISH: the queue worked through and the batch painted.
            def emit_finish(gsu, places)
              gsu.label(FINISH)
              gsu.sm(state(places, :finish_back), 11)
              emit_call(gsu, PROCESS)
              gsu.lm(0, places.mask)
              gsu.moves(0, 0)
              gsu.beq("chip columns finished")
              gsu.nop
              emit_call(gsu, PAINT)
              gsu.label("chip columns finished")
              gsu.lm(11, state(places, :finish_back))
              emit_return(gsu)
            end

            # WALK (LINK): R12 rows of the picture's column at R3 (in the bank ROMB has) into the
            # scratch bytes from R8 on, the walk standing at R5:R4 and stepping R7:R6 a row. Writing
            # R14 starts the read of the cartridge that GETB takes, five cycles later.
            def emit_walk(gsu)
              gsu.label(WALK)
              gsu.iwt(13, "chip columns walk row")
              gsu.label("chip columns walk row")
              gsu.from(3).to(14).add(5)
              gsu.with(4).add(6)
              gsu.with(5).adc(7)
              gsu.getb
              gsu.stb(8)
              gsu.loop
              gsu.inc(8)
              emit_return(gsu)
            end

            # ROWS (LINK): R12 rows of eight pixels plotted from the scratch columns, at R3 to R10, from
            # PLOT's x in R1 and y in R2.
            def emit_rows(gsu)
              gsu.label(ROWS)
              gsu.iwt(13, "chip columns row")
              gsu.label("chip columns row")
              (3..10).each do |pointer|
                gsu.ldb(pointer)
                gsu.inc(pointer)
                gsu.color
                gsu.plot
              end
              gsu.with(1).sub(gsu.imm(8))
              gsu.loop
              gsu.inc(2)
              emit_return(gsu)
            end

            # The queue worked through, a column at a time (#emit_column), and emptied.
            def emit_entries(gsu, places, multiply)
              gsu.label("chip columns entries")
              gsu.iwt(0, places.queue)
              gsu.sm(state(places, :at), 0)
              gsu.label("chip columns next entry")
              gsu.lm(10, state(places, :at))
              gsu.lm(0, places.queue_end)
              gsu.from(10).cmp(0)
              gsu.bne("chip columns entry")
              gsu.nop
              gsu.iwt(0, places.queue)
              gsu.sm(places.queue_end, 0)
              gsu.lm(11, state(places, :process_back))
              emit_return(gsu)
              gsu.label("chip columns entry")
              emit_column(gsu, places, multiply)
              gsu.lm(0, state(places, :at))
              gsu.ibt(1, ENTRY)
              gsu.add(1)
              gsu.sm(state(places, :at), 0)
              gsu.iwt(15, "chip columns next entry")
              gsu.nop
            end

            # The column at R10 on the queue, as Lowering::Paint#emit_column_walk works it out: the
            # step, the picture's height in 65536ths over the column's; the first row inside the
            # area and the last, the column's own rows held to the area; and where the walk stands at
            # the first, that row times the step. Then each column of its strip inside the area
            # across goes into the batch (#emit_strip). Registers: R3:R4 the column's height, R6:R7
            # the step, R8:R9 its top, R1:R2 the first row of it shown, R12:R13 the last.
            def emit_column(gsu, places, multiply)
              memo = places.memo
              gsu.move(9, 10)
              gsu.ibt(0, HEIGHT)
              gsu.with(9).add(0)
              gsu.to(3).ldw(9)
              2.times { gsu.inc(9) }
              gsu.to(4).ldw(9)
              gsu.ibt(0, PICTURE_HEIGHT - HEIGHT - 2)
              gsu.with(9).add(0)
              gsu.to(5).ldw(9)
              # The step: the last one again, for the same heights.
              [[memo, 5], [memo + 2, 3], [memo + 4, 4]].each do |at, register|
                gsu.lm(0, at)
                gsu.cmp(register)
                gsu.bne("chip columns divide anew")
                gsu.nop
              end
              gsu.lm(6, memo + 6)
              gsu.lm(7, memo + 8)
              gsu.bra("chip columns stepped")
              gsu.nop
              gsu.label("chip columns divide anew")
              gsu.sm(memo, 5)
              gsu.sm(memo + 2, 3)
              gsu.sm(memo + 4, 4)
              emit_call(gsu, DIVIDE)
              gsu.sm(memo + 6, 6)
              gsu.sm(memo + 8, 7)
              gsu.label("chip columns stepped")
              gsu.sm(places.record + SLOT_STEP, 6)
              gsu.sm(places.record + SLOT_STEP + 2, 7)
              # The top, and the first row shown: the area's top less it, nought at least.
              gsu.lm(10, state(places, :at))
              gsu.move(9, 10)
              gsu.ibt(0, TOP)
              gsu.with(9).add(0)
              gsu.to(8).ldw(9)
              2.times { gsu.inc(9) }
              gsu.to(9).ldw(9)
              gsu.lm(0, places.area_top)
              gsu.from(0).to(1).sub(8)
              gsu.ibt(0, 0)
              gsu.from(0).to(2).sbc(9)
              gsu.bpl("chip columns first shown")
              gsu.nop
              gsu.ibt(1, 0)
              gsu.ibt(2, 0)
              gsu.label("chip columns first shown")
              # The last: the area's bottom less the top, or the column's height if that is less.
              gsu.lm(0, places.area_bottom)
              gsu.from(0).to(12).sub(8)
              gsu.ibt(0, 0)
              gsu.from(0).to(13).sbc(9)
              gsu.from(3).to(0).sub(12)
              gsu.from(4).to(0).sbc(13)
              gsu.bge("chip columns last shown")
              gsu.nop
              gsu.move(12, 3)
              gsu.move(13, 4)
              gsu.label("chip columns last shown")
              # Nothing to walk unless the first is above the last.
              gsu.from(1).to(0).sub(12)
              gsu.from(2).to(0).sbc(13)
              gsu.blt("chip columns some shown")
              gsu.nop
              emit_jump(gsu, "chip columns entry done")
              gsu.label("chip columns some shown")
              gsu.from(12).to(0).sub(1)
              gsu.sm(places.record + SLOT_ROWS, 0)
              gsu.from(8).to(0).add(1)
              gsu.sm(places.record + SLOT_Y, 0)
              # Where the walk stands at the first row: nought for a column whose top is shown.
              gsu.from(1).to(0).or_(2)
              gsu.bne("chip columns walked in")
              gsu.nop
              gsu.sm(places.record + SLOT_AT, 0)
              gsu.sm(places.record + SLOT_AT + 2, 0)
              gsu.bra("chip columns at known")
              gsu.nop
              gsu.label("chip columns walked in")
              gsu.move(ChipSums::RIGHT_LOW, 6)
              gsu.move(ChipSums::RIGHT_HIGH, 7)
              emit_call(gsu, multiply)
              gsu.sm(places.record + SLOT_AT, ChipSums::LOW)
              gsu.sm(places.record + SLOT_AT + 2, ChipSums::HIGH)
              gsu.label("chip columns at known")
              # The rest of it, to the record: where the picture's column is, the strip's x and width,
              # and whether the picture has see-through pixels.
              gsu.lm(10, state(places, :at))
              gsu.move(9, 10)
              [[X, places.x], [X + 2, places.x + 2]].each do |_, at|
                gsu.ldw(9)
                gsu.sm(at, 0)
                2.times { gsu.inc(9) }
              end
              gsu.ibt(0, TEXELS - X - 4)
              gsu.with(9).add(0)
              [places.record + SLOT_TEXELS, places.record + SLOT_BANK].each do |at|
                gsu.ldw(9)
                gsu.sm(at, 0)
                2.times { gsu.inc(9) }
              end
              2.times { gsu.inc(9) }
              [places.across, places.see].each do |at|
                gsu.ldw(9)
                gsu.sm(at, 0)
                2.times { gsu.inc(9) }
              end
              emit_strip(gsu, places)
              gsu.label("chip columns entry done")
            end

            # A jump anywhere, for where a branch may not reach.
            def emit_jump(gsu, label)
              gsu.iwt(15, label)
              gsu.nop
            end

            # Each column of the strip, x on from the record's, that is inside the area across, into
            # the batch: painted first when the column is of another tile than the batch's or of a
            # slot already taken.
            def emit_strip(gsu, places)
              gsu.label("chip columns strip")
              gsu.lm(1, places.x)
              gsu.lm(2, places.x + 2)
              gsu.moves(0, 2)
              gsu.bne("chip columns outside")
              gsu.nop
              gsu.lm(0, places.area_left)
              gsu.from(1).cmp(0)
              gsu.bcc("chip columns outside")
              gsu.nop
              gsu.lm(0, places.area_right)
              gsu.from(1).cmp(0)
              gsu.bcc("chip columns inside")
              gsu.nop
              gsu.label("chip columns outside")
              emit_jump(gsu, "chip columns beside")
              gsu.label("chip columns inside")
              # R3 the tile column, R4 the slot's bit in the mask, R5 the slot.
              gsu.move(3, 1)
              3.times { gsu.with(3).lsr }
              gsu.from(1).to(5).and_(gsu.imm(7))
              gsu.ibt(4, 1)
              gsu.moves(0, 5)
              gsu.beq("chip columns bit found")
              gsu.nop
              gsu.move(12, 5)
              gsu.iwt(13, "chip columns bit")
              gsu.label("chip columns bit")
              gsu.with(4).add(4)
              gsu.loop
              gsu.nop
              gsu.label("chip columns bit found")
              gsu.lm(0, places.mask)
              gsu.moves(0, 0)
              gsu.beq("chip columns new batch")
              gsu.nop
              gsu.lm(0, places.column)
              gsu.cmp(3)
              gsu.bne("chip columns painted first")
              gsu.nop
              gsu.lm(0, places.mask)
              gsu.and_(4)
              gsu.beq("chip columns join")
              gsu.nop
              gsu.label("chip columns painted first")
              emit_call(gsu, PAINT)
              emit_jump(gsu, "chip columns strip")

              gsu.label("chip columns new batch")
              gsu.sm(places.column, 3)
              gsu.lm(0, places.record + SLOT_Y)
              gsu.sm(places.top, 0)
              gsu.lm(1, places.record + SLOT_ROWS)
              gsu.add(1)
              gsu.sm(places.bottom, 0)
              gsu.bra("chip columns slot")
              gsu.nop

              # Another column of the batch: one with a top or a bottom of its own makes it ragged,
              # and the batch's top and bottom take it in.
              gsu.label("chip columns join")
              gsu.lm(6, places.record + SLOT_Y)
              gsu.lm(7, places.record + SLOT_ROWS)
              gsu.with(7).add(6)
              gsu.lm(0, places.top)
              gsu.cmp(6)
              gsu.bne("chip columns ragged")
              gsu.nop
              gsu.lm(0, places.bottom)
              gsu.cmp(7)
              gsu.beq("chip columns even")
              gsu.nop
              gsu.label("chip columns ragged")
              gsu.ibt(0, 1)
              gsu.sm(places.ragged, 0)
              gsu.lm(0, places.top)
              gsu.from(6).cmp(0)
              gsu.bcs("chip columns top kept")
              gsu.nop
              gsu.sm(places.top, 6)
              gsu.label("chip columns top kept")
              gsu.lm(0, places.bottom)
              gsu.cmp(7)
              gsu.bcs("chip columns even")
              gsu.nop
              gsu.sm(places.bottom, 7)
              gsu.label("chip columns even")

              # The record into the slot, and the slot taken.
              gsu.label("chip columns slot")
              4.times { gsu.with(5).add(5) }
              gsu.iwt(0, places.slots)
              gsu.with(5).add(0)
              (0...SLOT).step(2) do |word|
                gsu.lm(0, places.record + word)
                gsu.stw(5)
                2.times { gsu.inc(5) }
              end
              gsu.lm(0, places.mask)
              gsu.or_(4)
              gsu.sm(places.mask, 0)
              gsu.lm(0, places.see)
              gsu.lm(1, places.holes)
              gsu.or_(1)
              gsu.sm(places.holes, 0)

              gsu.label("chip columns beside")
              gsu.lm(1, places.x)
              gsu.lm(2, places.x + 2)
              gsu.inc(1)
              gsu.bne("chip columns x on")
              gsu.nop
              gsu.inc(2)
              gsu.label("chip columns x on")
              gsu.sm(places.x, 1)
              gsu.sm(places.x + 2, 2)
              gsu.lm(0, places.across)
              gsu.dec(0)
              gsu.sm(places.across, 0)
              gsu.beq("chip columns strip done")
              gsu.nop
              emit_jump(gsu, "chip columns strip")
              gsu.label("chip columns strip done")
            end

            # DIVIDE (LINK): R7:R6 = the picture's height R5 in 65536ths over the column's height R4:R3,
            # which is above nought: binary long division, a bit of the number at a time from the
            # top, R9:R8 what is left over. When the column is taller than the picture, the first
            # sixteen bits of the quotient are all nought, and the division starts past them.
            def emit_divide(gsu)
              gsu.label(DIVIDE)
              gsu.ibt(6, 0)
              gsu.ibt(9, 0)
              gsu.moves(0, 4)
              gsu.bne("chip columns divide long")
              gsu.nop
              gsu.from(5).cmp(3)
              gsu.bcs("chip columns divide long")
              gsu.nop
              gsu.move(8, 5)
              gsu.ibt(7, 0)
              gsu.ibt(12, 16)
              gsu.bra("chip columns divide go")
              gsu.nop
              gsu.label("chip columns divide long")
              gsu.move(7, 5)
              gsu.ibt(8, 0)
              gsu.ibt(12, 32)
              gsu.label("chip columns divide go")
              gsu.iwt(13, "chip columns divide step")
              gsu.label("chip columns divide step")
              gsu.with(6).add(6)
              [7, 8, 9].each { |register| gsu.with(register).rol }
              gsu.from(8).to(0).sub(3)
              gsu.from(9).to(10).sbc(4)
              gsu.bcc("chip columns divide short")
              gsu.nop
              gsu.move(8, 0)
              gsu.move(9, 10)
              gsu.inc(6)
              gsu.label("chip columns divide short")
              gsu.loop
              gsu.nop
              emit_return(gsu)
            end

            # PAINT (LINK): the batch painted, and emptied.
            def emit_paint(gsu, places)
              gsu.label(PAINT)
              gsu.sm(state(places, :paint_back), 11)
              # Where PLOT's x and y start for the batch's tile column, and how many rows it has.
              gsu.lm(1, places.column)
              gsu.from(1).to(0).and_(gsu.imm(15))
              3.times { gsu.add(0) }
              gsu.sm(state(places, :x_base), 0)
              gsu.ibt(2, 16)
              gsu.from(1).to(0).and_(2)
              gsu.lsr
              gsu.sm(state(places, :y_base), 0)
              gsu.lm(0, places.top)
              gsu.lm(1, places.bottom)
              gsu.from(1).to(1).sub(0)
              gsu.sm(state(places, :ready_rows), 1)
              # A batch with a slot empty is ragged too.
              gsu.lm(0, places.mask)
              gsu.iwt(1, 0xFF)
              gsu.cmp(1)
              gsu.beq("chip columns all slots")
              gsu.nop
              gsu.sm(places.ragged, 1)
              gsu.label("chip columns all slots")
              emit_whole_rows(gsu, places)
              emit_call(gsu, READY)
              emit_fill(gsu, places)
              SLOTS.times { |slot| emit_slot_walk(gsu, places, slot) }
              emit_call(gsu, PLOT)
              gsu.ibt(0, 0)
              gsu.sm(places.mask, 0)
              gsu.sm(places.ragged, 0)
              gsu.sm(places.holes, 0)
              gsu.lm(11, state(places, :paint_back))
              emit_return(gsu)
            end

            # The rows of tiles READY need not fill with the clear colour: those the batch covers
            # from top to bottom, when it paints every pixel of them; none otherwise.
            def emit_whole_rows(gsu, places)
              gsu.ibt(0, 0)
              gsu.ibt(1, 0)
              gsu.lm(2, places.ragged)
              gsu.lm(3, places.holes)
              gsu.from(2).to(2).or_(3)
              gsu.bne("chip columns whole rows known")
              gsu.nop
              gsu.lm(0, places.top)
              gsu.add(gsu.imm(7))
              3.times { gsu.lsr }
              gsu.lm(1, places.bottom)
              3.times { gsu.with(1).lsr }
              gsu.label("chip columns whole rows known")
              gsu.sm(state(places, :whole_from), 0)
              gsu.sm(state(places, :whole_to), 1)
            end

            # A ragged batch's scratch columns all nought, as far down as the batch goes.
            def emit_fill(gsu, places)
              gsu.lm(0, places.ragged)
              gsu.moves(0, 0)
              gsu.beq("chip columns filled")
              gsu.nop
              gsu.iwt(5, places.scratch)
              gsu.iwt(7, SCRATCH_COLUMN)
              gsu.ibt(4, SLOTS)
              gsu.label("chip columns fill column")
              gsu.lm(12, state(places, :ready_rows))
              gsu.inc(12)
              gsu.with(12).lsr
              gsu.move(6, 5)
              gsu.ibt(0, 0)
              gsu.iwt(13, "chip columns fill word")
              gsu.label("chip columns fill word")
              gsu.stw(6)
              gsu.inc(6)
              gsu.loop
              gsu.inc(6)
              gsu.with(5).add(7)
              gsu.dec(4)
              gsu.bne("chip columns fill column")
              gsu.nop
              gsu.label("chip columns filled")
            end

            # Slot +slot+'s column walked into its scratch column, if the slot is taken.
            def emit_slot_walk(gsu, places, slot)
              skip = "chip columns slot #{slot} empty"
              gsu.lm(0, places.mask)
              gsu.iwt(1, 1 << slot)
              gsu.and_(1)
              gsu.beq(skip)
              gsu.nop
              gsu.iwt(9, places.slots + (slot * SLOT))
              gsu.ldw(9)
              2.times { gsu.inc(9) }
              gsu.lm(1, places.top)
              gsu.from(0).to(8).sub(1)
              gsu.iwt(1, places.scratch + (slot * SCRATCH_COLUMN))
              gsu.with(8).add(1)
              [12, 4, 5, 6, 7, 3].each do |register|
                gsu.to(register).ldw(9)
                2.times { gsu.inc(9) }
              end
              gsu.ldw(9)
              gsu.romb
              emit_call(gsu, WALK)
              gsu.label(skip)
            end

            # PLOT (LINK): the batch's rows plotted, a band of a tile's rows at a time, and PLOT's last
            # pixels written out (RPIX does that before it reads).
            def emit_plot(gsu, places)
              gsu.label(PLOT)
              gsu.sm(state(places, :plot_back), 11)
              gsu.ibt(0, PLOT_SETTINGS)
              gsu.cmode
              SLOTS.times { |slot| gsu.iwt(3 + slot, places.scratch + (slot * SCRATCH_COLUMN)) }
              gsu.lm(0, places.top)
              gsu.sm(state(places, :row), 0)
              gsu.label("chip columns band")
              gsu.lm(0, state(places, :row))
              # PLOT's y: the row's top bit, its tile row's low three bits a place up, the tile
              # column's fifth bit, and the row in the tile.
              gsu.ibt(12, -128)
              gsu.from(0).to(2).and_(12)
              gsu.ibt(12, 0x38)
              gsu.from(0).to(1).and_(12)
              gsu.with(1).add(1)
              gsu.with(2).or_(1)
              gsu.from(0).to(1).and_(gsu.imm(7))
              gsu.with(2).or_(1)
              gsu.lm(1, state(places, :y_base))
              gsu.with(2).or_(1)
              # PLOT's x: the row's 64 bit a place up, and the tile column's low four bits.
              gsu.ibt(12, 0x40)
              gsu.from(0).to(1).and_(12)
              gsu.with(1).add(1)
              gsu.lm(12, state(places, :x_base))
              gsu.with(1).or_(12)
              # The band: to the tile's foot, or the batch's bottom if that is sooner.
              gsu.from(0).to(12).and_(gsu.imm(7))
              gsu.ibt(13, 8)
              gsu.from(13).to(12).sub(12)
              gsu.lm(13, places.bottom)
              gsu.with(13).sub(0)
              gsu.from(13).cmp(12)
              gsu.bcs("chip columns band size")
              gsu.nop
              gsu.move(12, 13)
              gsu.label("chip columns band size")
              gsu.add(12)
              gsu.sm(state(places, :row), 0)
              emit_call(gsu, ROWS)
              gsu.lm(0, state(places, :row))
              gsu.lm(1, places.bottom)
              gsu.cmp(1)
              gsu.bcs("chip columns bands done")
              gsu.nop
              emit_jump(gsu, "chip columns band")
              gsu.label("chip columns bands done")
              gsu.rpix
              gsu.lm(11, state(places, :plot_back))
              emit_return(gsu)
            end

            # READY (LINK): the batch's tiles, in its column of tiles from its top for ready_rows
            # rows, made ready and marked changed.
            COLUMN = 1
            TILE_ROW = 2
            LAST_ROW = 3
            TILE = 4
            AT = 5
            PAIRS = 6
            CLEAR = 7
            GENERATION = 8

            def emit_ready(gsu, places)
              gsu.label(READY)
              gsu.lm(COLUMN, places.column)
              gsu.lm(TILE_ROW, places.top)
              gsu.lm(LAST_ROW, state(places, :ready_rows))
              gsu.with(LAST_ROW)
              gsu.add(TILE_ROW)
              gsu.dec(LAST_ROW)
              [TILE_ROW, LAST_ROW].each { |register| 3.times { gsu.with(register).lsr } }
              gsu.lm(GENERATION, places.generation)
              gsu.label("chip column tile")
              # TILE = TILE_ROW * 32 + COLUMN
              gsu.move(TILE, TILE_ROW)
              5.times { gsu.with(TILE).add(TILE) }
              gsu.with(TILE).add(COLUMN)
              emit_mark_changed(gsu, places)
              gsu.iwt(AT, GENERATIONS)
              gsu.with(AT).add(TILE)
              gsu.ldb(AT)
              gsu.from(0).cmp(GENERATION)
              gsu.beq("chip column tile ready")
              gsu.nop
              gsu.from(GENERATION).stb(AT)
              # Filled with the clear colour unless the batch paints all of it.
              gsu.lm(0, state(places, :whole_from))
              gsu.from(TILE_ROW).cmp(0)
              gsu.bcc("chip column tile filled")
              gsu.nop
              gsu.lm(0, state(places, :whole_to))
              gsu.from(TILE_ROW).cmp(0)
              gsu.bcc("chip column tile whole")
              gsu.nop
              gsu.label("chip column tile filled")
              emit_clear_tile(gsu, places)
              gsu.label("chip column tile whole")
              gsu.lm(0, places.readied_count)
              gsu.iwt(AT, places.readied)
              gsu.with(AT).add(0)
              gsu.from(TILE).stw(AT)
              gsu.add(gsu.imm(2))
              gsu.sm(places.readied_count, 0)
              gsu.label("chip column tile ready")
              gsu.from(TILE_ROW).cmp(LAST_ROW)
              gsu.beq("chip column tiles ready")
              gsu.nop
              gsu.inc(TILE_ROW)
              gsu.iwt(15, "chip column tile")
              gsu.nop
              gsu.label("chip column tiles ready")
              emit_return(gsu)
            end

            # The row of tiles' leftmost changed tile made COLUMN if it is further right, and its
            # rightmost if it is further left.
            def emit_mark_changed(gsu, places)
              gsu.move(AT, TILE_ROW)
              2.times { gsu.with(AT).add(AT) }
              gsu.iwt(0, places.dirty)
              gsu.with(AT).add(0)
              gsu.ldw(AT)
              gsu.from(COLUMN).cmp(0)
              gsu.bcs("chip column left kept")
              gsu.nop
              gsu.from(COLUMN).stw(AT)
              gsu.label("chip column left kept")
              gsu.inc(AT)
              gsu.inc(AT)
              gsu.ldw(AT)
              gsu.from(0).cmp(COLUMN)
              gsu.bcs("chip column right kept")
              gsu.nop
              gsu.from(COLUMN).stw(AT)
              gsu.label("chip column right kept")
            end

            # TILE's 64 bytes the clear colour: each of its eight rows the clear colour's four words.
            def emit_clear_tile(gsu, places)
              gsu.move(AT, TILE)
              6.times { gsu.with(AT).add(AT) }
              gsu.iwt(CLEAR, places.clear)
              gsu.ibt(PAIRS, 4)
              gsu.label("chip column clear pair")
              gsu.ldw(CLEAR)
              8.times do
                gsu.stw(AT)
                gsu.inc(AT)
                gsu.inc(AT)
              end
              gsu.inc(CLEAR)
              gsu.inc(CLEAR)
              gsu.dec(PAIRS)
              gsu.bne("chip column clear pair")
              gsu.nop
            end
          end
        end
      end
    end
  end
end
