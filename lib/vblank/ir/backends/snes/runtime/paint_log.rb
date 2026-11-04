# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A PAINTED SCREEN THAT PAINTS AND SENDS ONLY WHAT CHANGED, on a plain cartridge (Paint).
          #
          # A game on a painted screen usually clears it every pass and paints it all again: a menu
          # clears and writes its four rows, a score clears and writes its digits. Painting a tile of
          # eight bits a pixel is slow on this processor (each pixel is in eight planes), and a
          # blank holds only a few thousand bytes, so painting and sending every tile again each
          # pass takes several frames. Yet a pass that looks like the last one changes no byte of
          # video RAM at all. The console's own games never paint their text again: it is drawn
          # once and stays.
          #
          # So a painting here is not done when the game asks for it. It is WRITTEN DOWN (the LOG:
          # what it was, its numbers and the area it was held to), and each tile it covers takes
          # it into its KEY, a 32-bit number worked out from every painting that covered the tile
          # since the screen was last cleared, in order, starting from the clear colour (SEED).
          # Two tiles with the same key were painted the same way, so they hold the same pixels.
          # As the pass ends (rt_paint_flush), each tile the pass covered has its key compared with
          # the key of what the copy holds for it (KEYS_COPY):
          #
          #   the same          nothing to do: the copy and video RAM already hold it
          #   not the same      the tile is made the clear colour and painted again (REPAINT)
          #   painted already   in this generation, at an earlier flush: painted again on top
          #
          # Then each painting of the log that covers a tile to paint is done again, whole. A
          # painting only ever puts its colours over pixels, never mixes them with what is under, so
          # doing every painting that covers a tile again, in order, over a tile that already shows
          # them changes nothing (rt_paint_replay sees that each such tile has all of its done). A
          # tile whose copy changed is UNSENT until the blank copies it to video RAM, so only those
          # go.
          #
          # A key is a hash, so two different ways of painting a tile could in principle come to the
          # same number and the tile would keep its old pixels. With 32 bits that is about one in
          # four thousand million for each tile that changes; the hash is chosen so a small change
          # of a number (a place moved by one) changes the whole key.
          #
          # THE MAP SENDS ONLY THE CELLS THAT CHANGED. A clear points every cell back at the clear
          # tile, and a tile painted in the new generation points its cell at itself again, so a
          # pass that paints the same tiles changes no cell. The cells of the tiles readied in a
          # generation (READIED) are looked at again when it ends, with those readied in this pass
          # (MAP_DIRTY); each row's changed cells go as one run (MAP_RUNS).
          #
          # Reading the screen needs it painted: keeping a sprite's patch (rt_paint_save) and putting
          # it back (rt_paint_restore) paint what is written down first, keeping the direct page
          # (rt_paint_flush_keeping). So does a full log.
          #
          #   rt_paint_apply_deferred_clear  a clear held back while the pass drew what the last one
          #                       did, made once it does not (DEFERRED_CLEAR)
          #   rt_paint_op_begin   a painting starts: written down after a flush, if the log is full
          #   rt_paint_mark       its tiles take its key
          #   rt_paint_log_append it is written down
          #   rt_paint_flush      what is written down painted, into the tiles whose key changed
          #   rt_paint_map_runs   as a pass ends: the cells of the map that changed, row by row
          module PaintLog
            KEYS_NOW = "rt paint keys now"
            KEYS_COPY = "rt paint keys copy"
            # For each tile, the key of what its slot of video RAM holds, set as it is sent: a tile
            # painted on the way through a pass (a flush with the log full) and ending as it was
            # is not sent again (rt_paint_slot_behind).
            KEYS_SHOWN = "rt paint keys shown"
            # For each tile, the generation the copy's tile was last painted in; the same as the
            # screen's means the copy holds this generation's paintings up to the last flush.
            PAINTED_IN = "rt paint painted in"
            # For each tile, a byte: the flush that is painting it again, its STAMP. A stamp comes
            # round after 256 flushes, so a tile can be taken for one being painted when it is not;
            # painting it again does no harm (see the top), it only costs the time.
            REPAINT = "rt paint repaint"
            STAMP = "rt paint stamp"
            # For each tile, a byte: not nought while its slot of video RAM is behind the copy.
            UNSENT = "rt paint unsent"
            # For each row of tiles, the leftmost and rightmost tile (a word each, as Paint::DIRTY,
            # which says the tiles covered since the last pass): readied in this generation; cells
            # to look at again.
            READIED = "rt paint readied"
            MAP_DIRTY = "rt paint map dirty"
            # The runs of cells to send, each its first cell and how many, and their bytes, each
            # counted Paint::RUN_SETTING_UP more.
            MAP_RUNS = "rt paint map runs"
            MAP_RUNS_END = "rt paint map runs end"
            MAP_RUN_BYTES = "rt paint map run bytes"
            # The log: each painting ENTRY_BYTES, its kind, the area, the first five working numbers,
            # then its rows of tiles, top and bottom, its first and last tile across, and a word for
            # the flush.
            #
            # A pass of more paintings than the log holds paints what is written down when it fills,
            # and every tile painted on both sides of that is painted twice (and its key compared
            # with one the pass had not finished), so the log takes what work RAM has left once the
            # game's own places are known, up to MOST_LOG_ENTRIES, and LEAST_LOG_ENTRIES at least.
            LOG = "rt paint log"
            LOG_END = "rt paint log end"
            LEAST_LOG_ENTRIES = 128
            MOST_LOG_ENTRIES = 512
            ENTRY_BYTES = 44
            ENTRY_AREA = 2
            ENTRY_NUMBERS = 10
            NUMBER_BYTES = 20
            ENTRY_TOP = 30
            ENTRY_BOTTOM = 32
            ENTRY_FIRST = 34
            ENTRY_LAST = 36
            # Whether the flush at hand paints it again (rt_paint_replay).
            ENTRY_AGAIN = 38
            # Its hash (OP_HASH), so its tiles can take it in again without working it out.
            ENTRY_HASH = 40
            # A PASS THAT DRAWS WHAT THE LAST ONE DREW. Most passes that clear the screen go on to
            # paint exactly what the pass before painted, in the same order: a menu standing still,
            # a screen of text. Writing each painting down and taking it into its tiles' keys costs
            # far more than asking whether it is the painting the last pass wrote down at the same
            # place in the log. So the first clear of a pass, to the colour the screen is cleared
            # to already, is DEFERRED while the log the last pass left is whole (LAST_PASS_END: how
            # far it goes, or NO_LAST_PASS): the screen still shows the last pass, and each painting
            # the same as the one written down at LOG_END is passed over, LOG_END moved past it. A
            # pass that ends having matched the whole of the last pass's log changes nothing, and
            # nothing is painted or sent.
            #
            # The first painting that differs (or a pass that stops short, or anything that reads
            # the copy) makes the clear at last (rt_paint_apply_deferred_clear): the next
            # generation, and the paintings matched so far taken into their tiles' keys from their
            # entries, as if each had been written down as it came. From there the pass goes on as
            # any other.
            #
            # The log is whole when nothing painted it mid-pass since the clear (LOG_WHOLE: a full
            # log, or a patch kept or put back), and it stays the screen's when nothing was
            # painted at once after it (rt_paint_mark_now forgets it).
            DEFERRED_CLEAR = "rt paint deferred clear"
            LAST_PASS_END = "rt paint last pass end"
            LOG_WHOLE = "rt paint log whole"
            NO_LAST_PASS = 0xFFFF
            # The painting at hand: its kind, the bytes of its working numbers it is known by, and
            # its hash; the hash of a clear to the clear colour, a fresh tile's key; whether the log
            # is being painted; and how many patches have been put back, which each make a hash of
            # their own.
            OP_KIND = "rt paint op kind"
            OP_BYTES = "rt paint op bytes"
            OP_HASH = "rt paint op hash"
            SEED = "rt paint seed"
            REPLAYING = "rt paint replaying"
            # Whether paintings are written down: from a clear of the whole screen to the end of the
            # pass. A pass that has not cleared the screen paints on what the last one left, so no
            # tile it covers can come out as it was, and writing its paintings down would only cost
            # time: they are done at once (rt_paint_mark_now), their tiles' keys kept all the same.
            LOGGING = "rt paint logging"
            # Whether the flush puts the tiles on the runs to send (rt_paint_flush_sending).
            SENDING = "rt paint sending"
            RESTORES = "rt paint restores"
            # The direct page, kept while a flush paints in the middle of a routine.
            KEPT_PAGE = "rt paint kept page"
            KIND_FILL = 1
            KIND_BLIT = 2
            KIND_CLEAR = 3
            # The ways a painting is known to rt_paint_hash, by the bytes of working numbers and the
            # step between the words hashed: a rectangle's five numbers whole, a picture's three by
            # their low words, and a clear's place.
            HASHED_NUMBERS = Ractor.make_shareable([[20, 2], [12, 4], [4, 2]])
            # The high word of a put-back patch's hash.
            RESTORE_HASH = 0x5A3C
            # What a hash takes in for an area that is the whole screen: no area's left edge.
            WHOLE_AREA = 0xA5A5

            module_function

            def reserve(memory)
              tiles = Paint::TILES
              { KEYS_NOW => tiles * 4, KEYS_COPY => tiles * 4, KEYS_SHOWN => tiles * 4, PAINTED_IN => tiles, REPAINT => tiles,
                UNSENT => tiles, READIED => Paint::ROWS * 4, MAP_DIRTY => Paint::ROWS * 4,
                MAP_RUNS => Paint::ROWS * 4, KEPT_PAGE => 0x100 }.each do |name, bytes|
                memory.reserve_far(name, bytes)
              end
              [MAP_RUNS_END, MAP_RUN_BYTES, LOG_END, OP_KIND, OP_BYTES, REPLAYING, LOGGING, SENDING, RESTORES, STAMP,
               DEFERRED_CLEAR, LAST_PASS_END, LOG_WHOLE].each do |name|
                memory.reserve(name, 2)
              end
              memory.reserve(OP_HASH, 4)
              memory.reserve(SEED, 4)
              ROWS_OF.each_value { |name| memory.reserve(name, 4) }
            end

            # At power-on (Paint's rt_paint_start, the area the whole screen): no tile painted in any
            # generation, no row covered, the key of a clear to black.
            def emit_start(asm, memory)
              Paint.emit_fill_work_ram(asm, memory[PAINTED_IN], Paint::TILES, "rt_paint_no_generation")
              asm.ldx(0)
              asm.label("rt_paint_log_start_row")
              [READIED, MAP_DIRTY].each do |name|
                asm.lda(Paint::NONE_LEFT)
                asm.sta(asm.long_x(memory[name]))
                asm.lda(0)
                asm.sta(asm.long_x(memory[name], 2))
              end
              4.times { asm.inx }
              asm.cpx(Paint::ROWS * 4)
              asm.bne("rt_paint_log_start_row")
              ROWS_OF.each_key { |name| emit_no_rows(asm, memory, name) }
              asm.stz(asm.abs(memory[DEFERRED_CLEAR]))
              asm.lda(NO_LAST_PASS)
              asm.sta(asm.abs(memory[LAST_PASS_END]))
              asm.lda(1)
              asm.sta(asm.abs(memory[STAMP]))
              asm.stz(asm.direct(Paint::R.call(0)))
              asm.stz(asm.direct(Paint::R.call(0) + 2))
              asm.jsr(asm.abs("rt_paint_seed"))
              # The copy and video RAM start all nought, which is every tile cleared to place 0:
              # each tile's key is that clear's.
              asm.ldx(0)
              asm.label("rt_paint_log_start_key")
              2.times do |half|
                asm.lda(asm.abs(memory[SEED] + (half * 2)))
                asm.sta(asm.long_x(memory[KEYS_COPY], half * 2))
                asm.sta(asm.long_x(memory[KEYS_SHOWN], half * 2))
              end
              4.times { asm.inx }
              asm.cpx(Paint::TILES * 4)
              asm.bne("rt_paint_log_start_key")
            end

            # As the whole screen is cleared, made now: what was written down is gone, and the log
            # is whole from here.
            def emit_clear(asm, memory)
              asm.stz(asm.abs(memory[LOG_END]))
              asm.lda(1)
              asm.sta(asm.abs(memory[LOGGING]))
              asm.sta(asm.abs(memory[LOG_WHOLE]))
            end

            # At the top of a clear of the whole screen to the place in R0: DEFERRED (see the top),
            # returning (RTL), when it is to the colour the screen is cleared to already and the
            # pass has painted nothing since the last pass's log, or since a clear deferred
            # already. A clear to another colour is made now, and with it any deferred.
            def emit_clear_deferred(asm, memory)
              asm.lda(asm.direct(Paint::R.call(0)))
              asm.cmp(asm.abs(memory[Paint::CLEAR_PLACE]))
              asm.bne("rt_paint_clear_not_deferred_colour")
              asm.lda(asm.abs(memory[DEFERRED_CLEAR]))
              asm.bne("rt_paint_clear_deferred")
              asm.lda(asm.abs(memory[LOGGING]))
              asm.bne("rt_paint_clear_not_deferred")
              asm.lda(asm.abs(memory[LAST_PASS_END]))
              asm.cmp(NO_LAST_PASS)
              asm.beq("rt_paint_clear_not_deferred")
              asm.label("rt_paint_clear_deferred")
              asm.lda(1)
              asm.sta(asm.abs(memory[DEFERRED_CLEAR]))
              emit_clear(asm, memory)
              asm.rtl
              asm.label("rt_paint_clear_not_deferred_colour")
              asm.stz(asm.abs(memory[DEFERRED_CLEAR]))
              asm.label("rt_paint_clear_not_deferred")
            end

            # In rt_paint_next_generation: the cells of the generation that ended are to be looked
            # at again. X is left.
            def emit_next_generation(asm, memory)
              emit_each_row(asm, memory, READIED, "rt_paint_log_clear_readied") do
                asm.lda(asm.long_x(memory[READIED]))
                asm.cmp(asm.long_x(memory[MAP_DIRTY]))
                asm.bcs("rt_paint_log_clear_left")
                asm.sta(asm.long_x(memory[MAP_DIRTY]))
                asm.label("rt_paint_log_clear_left")
                asm.lda(asm.long_x(memory[READIED], 2))
                asm.cmp(asm.long_x(memory[MAP_DIRTY], 2))
                asm.bcc("rt_paint_log_clear_right")
                asm.sta(asm.long_x(memory[MAP_DIRTY], 2))
                asm.label("rt_paint_log_clear_right")
                asm.lda(Paint::NONE_LEFT)
                asm.sta(asm.long_x(memory[READIED]))
                asm.lda(0)
                asm.sta(asm.long_x(memory[READIED], 2))
              end
              rows = memory[ROWS_OF.fetch(READIED)]
              map_rows = memory[ROWS_OF.fetch(MAP_DIRTY)]
              asm.lda(asm.abs(rows))
              asm.cmp(asm.abs(map_rows))
              asm.bcs("rt_paint_log_clear_first_kept")
              asm.sta(asm.abs(map_rows))
              asm.label("rt_paint_log_clear_first_kept")
              asm.lda(asm.abs(rows + 2))
              asm.cmp(asm.abs(map_rows + 2))
              asm.bcc("rt_paint_log_clear_end_kept")
              asm.sta(asm.abs(map_rows + 2))
              asm.label("rt_paint_log_clear_end_kept")
              emit_no_rows(asm, memory, READIED)
            end

            # Which rows of each table of rows may have a stretch: the first, and the one past the
            # last, as indexes into it (four bytes a row), so a pass that covers a few rows looks at
            # those alone.
            ROWS_OF = {
              Paint::DIRTY => "rt paint dirty rows",
              READIED => "rt paint readied rows",
              MAP_DIRTY => "rt paint map dirty rows"
            }.freeze

            def emit_no_rows(asm, memory, name)
              asm.lda(Paint::ROWS * 4)
              asm.sta(asm.abs(memory[ROWS_OF.fetch(name)]))
              asm.stz(asm.abs(memory[ROWS_OF.fetch(name)] + 2))
            end

            # Rows +mark_row+ to +temp+ (rt_paint_mark) taken into +name+'s rows.
            def emit_widen_rows(asm, memory, name, s, routine)
              rows = memory[ROWS_OF.fetch(name)]
              tag = "#{routine}_widen_#{name.tr(' ', '_')}"
              asm.lda(asm.direct(s.mark_row))
              asm.asl
              asm.asl
              asm.cmp(asm.abs(rows))
              asm.bcs("#{tag}_first")
              asm.sta(asm.abs(rows))
              asm.label("#{tag}_first")
              asm.lda(asm.direct(s.temp))
              asm.inc
              asm.asl
              asm.asl
              asm.cmp(asm.abs(rows + 2))
              asm.bcc("#{tag}_end")
              asm.sta(asm.abs(rows + 2))
              asm.label("#{tag}_end")
            end

            # The block for each row +name+'s rows say may have a stretch, X the row's index (four
            # bytes a row). The block keeps X.
            def emit_each_row(asm, memory, name, tag)
              rows = memory[ROWS_OF.fetch(name)]
              asm.ldx(asm.abs(rows))
              asm.cpx(asm.abs(rows + 2))
              asm.branch_long(:bcs, "#{tag}_done")
              asm.label("#{tag}_row")
              yield
              4.times { asm.inx }
              asm.cpx(asm.abs(rows + 2))
              asm.branch_long(:bcc, "#{tag}_row")
              asm.label("#{tag}_done")
            end

            def emit(asm, memory, s, bank)
              log_bytes = memory.reserve_far_up_to(LOG, least: LEAST_LOG_ENTRIES * ENTRY_BYTES,
                                                        most: MOST_LOG_ENTRIES * ENTRY_BYTES, step: ENTRY_BYTES)
              emit_hash(asm, memory)
              emit_op_begin(asm, memory, log_bytes)
              emit_apply_deferred_clear(asm, memory, s)
              emit_mark(asm, memory, s)
              emit_mark_now(asm, memory, s)
              emit_log_append(asm, memory, s)
              emit_flush(asm, memory, s)
              emit_blank_tile(asm, memory, s, bank)
              emit_replay(asm, memory, s)
              emit_map_runs(asm, memory, s)
              emit_slot_behind(asm, memory)
            end

            # rt_paint_hash (JSR): OP_HASH from the painting's kind, the area and the words of its
            # working numbers, the way OP_BYTES says (HASHED_NUMBERS). Each word is added in,
            # and then the two halves of the hash are turned and mixed into each other, so every bit
            # of a word reaches every bit of the hash within a few words; a word of nought ends it,
            # to carry the last word's bits through.
            # rt_paint_seed (JSR): SEED, the hash of a clear to the place in R0.
            def emit_hash(asm, memory)
              hash = memory[OP_HASH]
              asm.label("rt_paint_hash")
              asm.lda(asm.abs(memory[OP_KIND]))
              asm.eor(0x9E37)
              asm.sta(asm.abs(hash))
              asm.lda(0x79B9)
              asm.sta(asm.abs(hash + 2))
              # The area: one word for the whole screen, as it nearly always is, else its four.
              area = memory[Paint::AREA]
              asm.lda(asm.abs(area + Paint::AREA_PART))
              asm.bne("rt_paint_hash_area")
              asm.lda(WHOLE_AREA)
              emit_hash_word(asm, hash)
              asm.bra("rt_paint_hash_area_done")
              asm.label("rt_paint_hash_area")
              4.times do |i|
                asm.lda(asm.abs(area + (i * 2)))
                emit_hash_word(asm, hash)
              end
              asm.label("rt_paint_hash_area_done")
              # The working numbers, written out for each way a painting is known, as a loop
              # costs as much again as the hashing.
              HASHED_NUMBERS.each_with_index do |(bytes, step), way|
                asm.lda(asm.abs(memory[OP_BYTES]))
                asm.cmp(bytes)
                asm.branch_long(:bne, "rt_paint_hash_not_#{way}")
                (0...bytes).step(step) do |at|
                  asm.lda(asm.direct(at))
                  emit_hash_word(asm, hash)
                end
                asm.brl("rt_paint_hash_numbers_done")
                asm.label("rt_paint_hash_not_#{way}")
              end
              asm.label("rt_paint_hash_numbers_done")
              asm.lda(0)
              emit_hash_word(asm, hash)
              asm.lda(asm.abs(hash))
              asm.ora(1) # never nought, which is a routine that paints nothing (rt_paint_mark)
              asm.sta(asm.abs(hash))
              asm.rts

              asm.label("rt_paint_seed")
              asm.lda(KIND_CLEAR)
              asm.sta(asm.abs(memory[OP_KIND]))
              asm.lda(4)
              asm.sta(asm.abs(memory[OP_BYTES]))
              asm.jsr(asm.abs("rt_paint_hash"))
              2.times do |half|
                asm.lda(asm.abs(hash + (half * 2)))
                asm.sta(asm.abs(memory[SEED] + (half * 2)))
              end
              asm.rts
            end

            # The word in A taken into the hash at +hash+: added to the low half; the low half's two
            # bytes swapped (XBA) and mixed into the high half, which is turned left one; the high
            # half added to the low. ASL then ADC #0 turns a word left one: the bit shifted out
            # comes back in at the right.
            def emit_hash_word(asm, hash)
              asm.clc
              asm.adc(asm.abs(hash))
              asm.sta(asm.abs(hash))
              asm.xba
              asm.eor(asm.abs(hash + 2))
              asm.asl
              asm.adc(0)
              asm.sta(asm.abs(hash + 2))
              asm.clc
              asm.adc(asm.abs(hash))
              asm.sta(asm.abs(hash))
            end

            # rt_paint_op_begin (JSR, A the kind, X the bytes of working numbers it is known by,
            # HASHED_NUMBERS): while paintings are written down, the log painted first if it is
            # full (+log_bytes+), then the painting's hash.
            def emit_op_begin(asm, memory, log_bytes)
              asm.label("rt_paint_op_begin")
              asm.sta(asm.abs(memory[OP_KIND]))
              asm.stx(asm.abs(memory[OP_BYTES]))
              # Painted at once, it needs no hash, only one that is not nought (rt_paint_mark_now).
              asm.lda(asm.abs(memory[LOGGING]))
              asm.bne("rt_paint_op_begin_logged")
              asm.lda(1)
              asm.sta(asm.abs(memory[OP_HASH]))
              asm.rts
              asm.label("rt_paint_op_begin_logged")
              asm.lda(asm.abs(memory[LOG_END]))
              asm.cmp(log_bytes)
              asm.bcc("rt_paint_op_begin_room")
              asm.jsr(asm.abs("rt_paint_flush_keeping"))
              asm.label("rt_paint_op_begin_room")
              asm.jmp(asm.abs("rt_paint_hash"))
            end

            # At the start of a painting routine (JSL) of +kind+, known by +bytes+ of working
            # numbers, while a clear is deferred: the painting compared with the last pass's at
            # LOG_END, word by word — its kind and whether its area is the whole screen
            # (Paint::AREA_PART, with the kind in the entry), its working numbers (each 32 bits)
            # and, for an area less than the screen, the area's four. The same, it is passed over:
            # LOG_END moves past it, and the routine returns (RTL). Not the same, the clear is made
            # and it goes on, to be written down. Written out in each routine, as a call and the
            # setting up of one would cost a third as much again as comparing.
            def emit_same_as_last_pass(asm, memory, kind, bytes, prefix)
              log = memory[LOG]
              area = memory[Paint::AREA]
              differs = "#{prefix}_differs"
              asm.lda(asm.abs(memory[DEFERRED_CLEAR]))
              asm.branch_long(:beq, "#{prefix}_written")
              asm.ldx(asm.abs(memory[LOG_END]))
              asm.cpx(asm.abs(memory[LAST_PASS_END]))
              asm.branch_long(:bcs, differs)
              asm.lda(kind)
              asm.ora(asm.abs(area + Paint::AREA_PART))
              asm.cmp(asm.long_x(log))
              asm.branch_long(:bne, differs)
              (bytes / 2).times do |i|
                asm.lda(asm.direct(i * 2))
                asm.cmp(asm.long_x(log, ENTRY_NUMBERS + (i * 2)))
                asm.branch_long(:bne, differs)
              end
              asm.lda(asm.abs(area + Paint::AREA_PART))
              asm.beq("#{prefix}_same")
              4.times do |i|
                asm.lda(asm.abs(area + (i * 2)))
                asm.cmp(asm.long_x(log, ENTRY_AREA + (i * 2)))
                asm.branch_long(:bne, differs)
              end
              asm.label("#{prefix}_same")
              asm.txa
              asm.clc
              asm.adc(ENTRY_BYTES)
              asm.sta(asm.abs(memory[LOG_END]))
              asm.rtl
              asm.label(differs)
              asm.jsr(asm.abs("rt_paint_apply_deferred_clear"))
              asm.label("#{prefix}_written")
            end

            # rt_paint_apply_deferred_clear (JSR): the clear deferred made now (see the top): the
            # next generation, and each painting matched so far, LOG_END's worth of the log, taken
            # into its tiles' keys from its entry. Uses the direct page's scratch.
            # rt_paint_apply_deferred_clear_keeping (JSR): the same, if a clear is deferred, the
            # direct page and OP_HASH kept round it, for a routine that has its numbers there.
            def emit_apply_deferred_clear(asm, memory, s)
              log = memory[LOG]
              hash = memory[OP_HASH]
              kept = memory[KEPT_PAGE]
              asm.label("rt_paint_apply_deferred_clear_keeping")
              asm.lda(asm.abs(memory[DEFERRED_CLEAR]))
              asm.bne("rt_paint_apply_deferred_clear_kept")
              asm.rts
              asm.label("rt_paint_apply_deferred_clear_kept")
              2.times do |half|
                asm.lda(asm.abs(hash + (half * 2)))
                asm.pha
              end
              asm.phb
              asm.lda(0xFF)
              asm.ldx(0)
              asm.ldy(kept & 0xFFFF)
              asm.mvn(kept >> 16, 0x00)
              asm.plb
              asm.jsr(asm.abs("rt_paint_apply_deferred_clear"))
              asm.phb
              asm.lda(0xFF)
              asm.ldx(kept & 0xFFFF)
              asm.ldy(0)
              asm.mvn(0x00, kept >> 16)
              asm.plb
              1.downto(0) do |half|
                asm.pla
                asm.sta(asm.abs(hash + (half * 2)))
              end
              asm.rts

              asm.label("rt_paint_apply_deferred_clear")
              asm.stz(asm.abs(memory[DEFERRED_CLEAR]))
              asm.jsr(asm.abs("rt_paint_next_generation"))
              asm.ldx(0)
              asm.label("rt_paint_apply_deferred_clear_entry")
              asm.cpx(asm.abs(memory[LOG_END]))
              asm.bcs("rt_paint_apply_deferred_clear_done")
              asm.phx
              2.times do |half|
                asm.lda(asm.long_x(log, ENTRY_HASH + (half * 2)))
                asm.sta(asm.abs(hash + (half * 2)))
              end
              [[ENTRY_TOP, s.mark_row], [ENTRY_BOTTOM, s.temp], [ENTRY_FIRST, s.chunk], [ENTRY_LAST, s.last]].each do |at, to|
                asm.lda(asm.long_x(log, at))
                asm.sta(asm.direct(to))
              end
              asm.jsr(asm.abs("rt_paint_mark_rows"))
              asm.pla
              asm.clc
              asm.adc(ENTRY_BYTES)
              asm.tax
              asm.bra("rt_paint_apply_deferred_clear_entry")
              asm.label("rt_paint_apply_deferred_clear_done")
              asm.rts
            end

            # rt_paint_mark (JSR): rows of pixels +top+ up to +bottom+, tiles +chunk+ to +last+
            # across, covered: each row said changed (Paint::DIRTY), each tile of an older
            # generation put in this one with the clear colour's key, and OP_HASH taken into every
            # key (#emit_key_taking_in), so the same paintings in another order make another key.
            # An OP_HASH of nought is a routine that only reads the
            # tiles (rt_paint_save), which leaves the keys. A row with a tile new to this generation
            # has its cells looked at again as the pass ends.
            # (Y counts the tiles and X their keys, four bytes each; +right_planes+ points at
            # GENERATIONS, +left_planes+ is a new tile's key, +mark_count+ the row's last tile and one.)
            def emit_mark(asm, memory, s)
              dirty = memory[Paint::DIRTY]
              keys = memory[KEYS_NOW]
              hash = memory[OP_HASH]
              generations = s.right_planes
              fresh = s.left_planes
              asm.label("rt_paint_mark")
              asm.lda(asm.direct(s.bottom))
              asm.dec
              3.times { asm.lsr }
              asm.sta(asm.direct(s.temp))
              asm.lda(asm.direct(s.top))
              3.times { asm.lsr }
              asm.sta(asm.direct(s.mark_row))
              # rt_paint_mark_rows (JSR): the same, the rows of tiles known: +mark_row+ to +temp+.
              asm.label("rt_paint_mark_rows")
              emit_pointer(asm, generations, memory[Paint::GENERATIONS])
              # A tile new to the generation: the clear colour's key, with this painting taken in
              # unless it paints nothing (OP_HASH nought: +shift+ says which).
              asm.lda(asm.abs(hash))
              asm.ora(asm.abs(hash + 2))
              asm.sta(asm.direct(s.shift))
              asm.bne("rt_paint_mark_mixing")
              2.times do |half|
                asm.lda(asm.abs(memory[SEED] + (half * 2)))
                asm.sta(asm.direct(fresh + (half * 2)))
              end
              asm.bra("rt_paint_mark_fresh_known")
              asm.label("rt_paint_mark_mixing")
              emit_key_taking_in(asm, hash, asm.abs(memory[SEED]), asm.abs(memory[SEED] + 2),
                                 asm.direct(fresh), asm.direct(fresh + 2), s.left_planes + 4)
              asm.label("rt_paint_mark_fresh_known")
              [Paint::DIRTY, READIED, MAP_DIRTY].each { |name| emit_widen_rows(asm, memory, name, s, "rt_paint_mark") }
              asm.lda(asm.direct(s.mark_row))
              asm.label("rt_paint_mark_row")
              asm.asl
              asm.asl
              asm.tax
              emit_extend(asm, "rt_paint_mark_dirty", asm.abs_x(dirty), asm.abs_x(dirty + 2), s)
              asm.stz(asm.direct(s.column)) # no tile new to the generation yet
              asm.lda(asm.direct(s.mark_row))
              5.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.chunk))
              asm.tay
              asm.asl
              asm.asl
              asm.tax
              asm.tya
              asm.clc
              asm.adc(asm.direct(s.last))
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.inc
              asm.sta(asm.direct(s.mark_count))
              asm.label("rt_paint_mark_tile")
              asm.lda(asm.ind_long_y(generations))
              asm.and_a(0x00FF)
              asm.cmp(asm.abs(memory[Paint::GENERATION]))
              asm.beq("rt_paint_mark_known")
              asm.sep(0x20)
              asm.lda(asm.abs(memory[Paint::GENERATION]))
              asm.sta(asm.ind_long_y(generations))
              asm.rep(0x20)
              asm.lda(1)
              asm.sta(asm.direct(s.column)) # a tile new to the generation in this row
              asm.lda(asm.direct(fresh))
              asm.sta(asm.long_x(keys))
              asm.lda(asm.direct(fresh + 2))
              asm.sta(asm.long_x(keys, 2))
              asm.bra("rt_paint_mark_next")
              asm.label("rt_paint_mark_known")
              asm.lda(asm.direct(s.shift))
              asm.beq("rt_paint_mark_next")
              emit_key_taking_in(asm, hash, asm.long_x(keys), asm.long_x(keys, 2),
                                 asm.long_x(keys), asm.long_x(keys, 2), s.left_planes + 4)
              asm.label("rt_paint_mark_next")
              4.times { asm.inx }
              asm.iny
              asm.cpy(asm.direct(s.mark_count))
              asm.bcc("rt_paint_mark_tile")
              asm.lda(asm.direct(s.column))
              asm.beq("rt_paint_mark_row_done")
              asm.lda(asm.direct(s.mark_row))
              asm.asl
              asm.asl
              asm.tax
              emit_extend(asm, "rt_paint_mark_readied", asm.long_x(memory[READIED]), asm.long_x(memory[READIED], 2), s)
              emit_extend(asm, "rt_paint_mark_map", asm.long_x(memory[MAP_DIRTY]), asm.long_x(memory[MAP_DIRTY], 2), s)
              asm.label("rt_paint_mark_row_done")
              asm.lda(asm.direct(s.mark_row))
              asm.cmp(asm.direct(s.temp))
              asm.beq("rt_paint_mark_done")
              asm.inc
              asm.sta(asm.direct(s.mark_row))
              asm.brl("rt_paint_mark_row")
              asm.label("rt_paint_mark_done")
              asm.rts
            end

            # rt_paint_mark_now (JSR): the same tiles covered, as rt_paint_mark covers them, for a
            # painting done at once, before it paints: each tile not yet painted in this generation
            # made the clear colour, and the tile unsent if that or the painting changes it. Its key
            # is not worked out: no tile of this generation is compared before the next clear starts
            # another (LOGGING), so only the copy's key matters, and it is said to be none. It
            # reads and writes the tiles by their number (X), as the routines that call it keep their
            # own numbers in the rest of the direct page.
            # (+mask+ says whether OP_HASH is nought: a routine that only reads the tiles.)
            # rt_paint_mark_any (JSR): rt_paint_mark while paintings are written down, else this.
            # rt_paint_flush_logged (JSR): rt_paint_flush_keeping while they are written down.
            def emit_mark_now(asm, memory, s)
              dirty = memory[Paint::DIRTY]
              keys_copy = memory[KEYS_COPY]
              hash = memory[OP_HASH]
              generation = asm.abs(memory[Paint::GENERATION])
              # Both read the copy, so a clear deferred is made first.
              asm.label("rt_paint_mark_any")
              asm.lda(asm.abs(memory[LOGGING]))
              asm.beq("rt_paint_mark_now")
              asm.jsr(asm.abs("rt_paint_apply_deferred_clear_keeping"))
              asm.jmp(asm.abs("rt_paint_mark"))
              asm.label("rt_paint_flush_logged")
              asm.lda(asm.abs(memory[LOGGING]))
              asm.beq("rt_paint_flush_logged_none")
              asm.jsr(asm.abs("rt_paint_apply_deferred_clear_keeping"))
              asm.jmp(asm.abs("rt_paint_flush_keeping"))
              asm.label("rt_paint_flush_logged_none")
              asm.rts

              asm.label("rt_paint_mark_now")
              # Painted at once, the screen is no longer what the last pass's log says.
              asm.lda(NO_LAST_PASS)
              asm.sta(asm.abs(memory[LAST_PASS_END]))
              asm.lda(asm.abs(hash))
              asm.ora(asm.abs(hash + 2))
              asm.sta(asm.direct(s.mask))
              asm.lda(asm.direct(s.bottom))
              asm.dec
              3.times { asm.lsr }
              asm.sta(asm.direct(s.temp))
              asm.lda(asm.direct(s.top))
              3.times { asm.lsr }
              asm.sta(asm.direct(s.mark_row))
              [Paint::DIRTY, READIED, MAP_DIRTY].each { |name| emit_widen_rows(asm, memory, name, s, "rt_paint_mark_now") }
              asm.lda(asm.direct(s.mark_row))
              asm.label("rt_paint_mark_now_row")
              asm.asl
              asm.asl
              asm.tax
              emit_extend(asm, "rt_paint_mark_now_dirty", asm.abs_x(dirty), asm.abs_x(dirty + 2), s)
              asm.stz(asm.direct(s.column))
              asm.lda(asm.direct(s.mark_row))
              5.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.chunk))
              asm.sta(asm.direct(s.tile))
              asm.sec
              asm.adc(asm.direct(s.last))
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.sta(asm.direct(s.mark_count)) # the row's last tile and one
              asm.label("rt_paint_mark_now_tile")
              asm.ldx(asm.direct(s.tile))
              asm.lda(asm.long_x(memory[Paint::GENERATIONS]))
              asm.and_a(0x00FF)
              asm.cmp(generation)
              asm.beq("rt_paint_mark_now_ready")
              asm.sep(0x20)
              asm.lda(generation)
              asm.sta(asm.long_x(memory[Paint::GENERATIONS]))
              asm.rep(0x20)
              asm.lda(1)
              asm.sta(asm.direct(s.column))
              # The copy's tile is this generation's so far, or made so: the clear colour, whose
              # key is SEED.
              asm.label("rt_paint_mark_now_ready")
              asm.lda(asm.long_x(memory[PAINTED_IN]))
              asm.and_a(0x00FF)
              asm.cmp(generation)
              asm.beq("rt_paint_mark_now_painted")
              asm.sep(0x20)
              asm.lda(generation)
              asm.sta(asm.long_x(memory[PAINTED_IN]))
              asm.lda(1)
              asm.sta(asm.long_x(memory[UNSENT]))
              asm.rep(0x20)
              asm.txa
              asm.asl
              asm.asl
              asm.tax
              emit_unless_clear_already(asm, memory, "rt_paint_mark_now_blank")
              asm.jsr(asm.abs("rt_paint_blank_tile"))
              2.times do |half|
                asm.lda(asm.abs(memory[SEED] + (half * 2)))
                asm.sta(asm.long_x(keys_copy, half * 2))
              end
              asm.label("rt_paint_mark_now_blank")
              asm.lda(asm.direct(s.mask))
              asm.bne("rt_paint_mark_now_unknown")
              asm.bra("rt_paint_mark_now_next")
              asm.label("rt_paint_mark_now_painted")
              asm.lda(asm.direct(s.mask))
              asm.beq("rt_paint_mark_now_next") # read, not changed
              asm.sep(0x20)
              asm.lda(1)
              asm.sta(asm.long_x(memory[UNSENT]))
              asm.rep(0x20)
              asm.txa
              asm.asl
              asm.asl
              asm.tax
              # Painted at once, the copy's tile has no key worked out: nought, which no key of
              # paintings comes to (but by the chance any two keys have of meeting).
              asm.label("rt_paint_mark_now_unknown")
              asm.lda(0)
              asm.sta(asm.long_x(keys_copy))
              asm.sta(asm.long_x(keys_copy, 2))
              asm.label("rt_paint_mark_now_next")
              asm.inc(asm.direct(s.tile))
              asm.lda(asm.direct(s.tile))
              asm.cmp(asm.direct(s.mark_count))
              asm.branch_long(:bcc, "rt_paint_mark_now_tile")
              asm.lda(asm.direct(s.column))
              asm.beq("rt_paint_mark_now_row_done")
              asm.lda(asm.direct(s.mark_row))
              asm.asl
              asm.asl
              asm.tax
              emit_extend(asm, "rt_paint_mark_now_readied", asm.long_x(memory[READIED]), asm.long_x(memory[READIED], 2), s)
              emit_extend(asm, "rt_paint_mark_now_map", asm.long_x(memory[MAP_DIRTY]), asm.long_x(memory[MAP_DIRTY], 2), s)
              asm.label("rt_paint_mark_now_row_done")
              asm.lda(asm.direct(s.mark_row))
              asm.cmp(asm.direct(s.temp))
              asm.beq("rt_paint_mark_now_done")
              asm.inc
              asm.sta(asm.direct(s.mark_row))
              asm.brl("rt_paint_mark_now_row")
              asm.label("rt_paint_mark_now_done")
              asm.rts
            end

            # The key whose halves are +low+ and +high+, with the hash at +hash+ taken in, into
            # +low_out+ and +high_out+ (+spare+ a word of the direct page): the hash's low half added
            # to the key's; that sum's two bytes swapped (XBA), mixed with the key's high half and
            # the hash's, and turned left one, as the new high half; that added to the sum, as the
            # new low half. The additions carry from bit to bit, so no painting can cancel another
            # or trade places with it unseen, however many lie between them: a key worked out by
            # turning and mixing alone (XOR) would let two paintings 32 apart change places.
            def emit_key_taking_in(asm, hash, low, high, low_out, high_out, spare)
              asm.lda(low)
              asm.clc
              asm.adc(asm.abs(hash))
              asm.sta(asm.direct(spare))
              asm.xba
              asm.eor(high)
              asm.eor(asm.abs(hash + 2))
              asm.asl
              asm.adc(0)
              asm.sta(high_out)
              asm.clc
              asm.adc(asm.direct(spare))
              asm.sta(low_out)
            end

            # A row's leftmost and rightmost (+left+, +right+, at X) widened to take in +chunk+ to
            # +last+.
            def emit_extend(asm, tag, left, right, s)
              asm.lda(asm.direct(s.chunk))
              asm.cmp(left)
              asm.bcs("#{tag}_left_kept")
              asm.sta(left)
              asm.label("#{tag}_left_kept")
              asm.lda(asm.direct(s.last))
              asm.cmp(right)
              asm.bcc("#{tag}_right_kept")
              asm.sta(right)
              asm.label("#{tag}_right_kept")
            end

            # rt_paint_log_append (JSR, after rt_paint_mark): the painting at hand written down.
            def emit_log_append(asm, memory, s)
              log = memory[LOG]
              asm.label("rt_paint_log_append")
              asm.ldx(asm.abs(memory[LOG_END]))
              asm.lda(asm.abs(memory[OP_KIND]))
              asm.ora(asm.abs(memory[Paint::AREA] + Paint::AREA_PART)) # as the next pass compares it
              asm.sta(asm.long_x(log))
              4.times do |i|
                asm.lda(asm.abs(memory[Paint::AREA] + (i * 2)))
                asm.sta(asm.long_x(log, ENTRY_AREA + (i * 2)))
              end
              # The working numbers it is known by: three for a picture, five for a rectangle.
              (NUMBER_BYTES / 2).times do |i|
                if i == 6
                  asm.lda(asm.abs(memory[OP_BYTES]))
                  asm.cmp(13)
                  asm.bcc("rt_paint_log_append_numbers_done")
                end
                asm.lda(asm.direct(i * 2))
                asm.sta(asm.long_x(log, ENTRY_NUMBERS + (i * 2)))
              end
              asm.label("rt_paint_log_append_numbers_done")
              asm.lda(asm.direct(s.top))
              3.times { asm.lsr }
              asm.sta(asm.long_x(log, ENTRY_TOP))
              asm.lda(asm.direct(s.bottom))
              asm.dec
              3.times { asm.lsr }
              asm.sta(asm.long_x(log, ENTRY_BOTTOM))
              asm.lda(asm.direct(s.chunk))
              asm.sta(asm.long_x(log, ENTRY_FIRST))
              asm.lda(asm.direct(s.last))
              asm.sta(asm.long_x(log, ENTRY_LAST))
              2.times do |half|
                asm.lda(asm.abs(memory[OP_HASH] + (half * 2)))
                asm.sta(asm.long_x(log, ENTRY_HASH + (half * 2)))
              end
              asm.txa
              asm.clc
              asm.adc(ENTRY_BYTES)
              asm.sta(asm.abs(memory[LOG_END]))
              asm.rts
            end

            # rt_paint_flush (JSR, while paintings are written down): every tile covered in the pass
            # settled, as the top says; then the log painted, if any tile is to be painted, and
            # emptied.
            # rt_paint_flush_keeping (JSR): the same, the direct page kept round it, for a routine
            # that has its numbers there (the block move, MVN, leaves the data bank at the bank it
            # copied to, so it is kept on the stack round each).
            def emit_flush(asm, memory, s)
              keys_now = memory[KEYS_NOW]
              keys_copy = memory[KEYS_COPY]
              generation = asm.abs(memory[Paint::GENERATION])
              kept = memory[KEPT_PAGE]
              asm.label("rt_paint_flush_keeping")
              # With nothing written down nothing is painted, and the flush itself changes only
              # these of the direct page, which are kept on the stack instead: far quicker.
              own = [s.pointer, s.pointer + 2, s.tile, s.last, s.count, s.row] + Array.new(4) { |i| s.planes + (i * 2) }
              asm.stz(asm.abs(memory[LOG_WHOLE])) # painted mid-pass: the log is no longer the pass's
              asm.lda(asm.abs(memory[LOG_END]))
              asm.bne("rt_paint_flush_keeping_page")
              own.each { |at| asm.pei(asm.direct(at)) }
              asm.jsr(asm.abs("rt_paint_flush"))
              own.reverse_each do |at|
                asm.pla
                asm.sta(asm.direct(at))
              end
              asm.rts
              asm.label("rt_paint_flush_keeping_page")
              asm.phb
              asm.lda(0xFF)
              asm.ldx(0)
              asm.ldy(kept & 0xFFFF)
              asm.mvn(kept >> 16, 0x00)
              asm.plb
              asm.jsr(asm.abs("rt_paint_flush"))
              asm.phb
              asm.lda(0xFF)
              asm.ldx(kept & 0xFFFF)
              asm.ldy(0)
              asm.mvn(0x00, kept >> 16)
              asm.plb
              asm.rts

              asm.label("rt_paint_flush")
              asm.lda(asm.abs(memory[STAMP]))
              asm.inc
              asm.and_a(0x00FF) # a byte, as REPAINT keeps it
              asm.sta(asm.abs(memory[STAMP]))
              emit_pointer(asm, s.pointer, memory[PAINTED_IN])
              emit_pointer(asm, s.planes, memory[REPAINT])
              emit_pointer(asm, s.planes + 4, memory[UNSENT])
              asm.stz(asm.direct(s.count)) # tiles to paint
              dirty = memory[Paint::DIRTY]
              dirty_rows = memory[ROWS_OF.fetch(Paint::DIRTY)]
              # Every tile covered is looked at, so the rows are looked at with the data bank at
              # the first bank of work RAM, where the keys and the tiles' bytes are: a 16-bit
              # address reaches them, and the first 8K, where the rest is kept, is the same memory
              # there as in bank 0.
              far = [keys_now, keys_copy, memory[PAINTED_IN], memory[UNSENT]]
              raise ArgumentError, "a tile's keys and bytes share work RAM's first bank" unless far.all? { |at| at >> 16 == Paint::WORK_RAM >> 16 }

              asm.phb
              asm.sep(0x20)
              asm.lda(Paint::WORK_RAM >> 16)
              asm.pha
              asm.plb
              asm.rep(0x20)
              asm.ldx(asm.abs(dirty_rows))
              asm.txa
              3.times { asm.asl } # the row's first tile
              asm.sta(asm.direct(s.row))
              asm.cpx(asm.abs(dirty_rows + 2))
              asm.branch_long(:bcs, "rt_paint_flush_rows_done")
              asm.label("rt_paint_flush_row")
              asm.lda(asm.abs_x(dirty + 2))
              asm.cmp(asm.abs_x(dirty))
              asm.branch_long(:bcc, "rt_paint_flush_next_row")
              asm.sec # the row's last tile and one
              asm.adc(asm.direct(s.row))
              asm.sta(asm.direct(s.last))
              asm.lda(asm.abs_x(dirty))
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.sta(asm.direct(s.tile))
              asm.phx
              asm.lda(0xFFFF) # no run started (rt_paint_flush_sending)
              asm.sta(asm.direct(s.chunk))
              asm.ldy(asm.direct(s.tile))
              asm.lda(asm.direct(s.tile))
              asm.asl
              asm.asl
              asm.tax
              # Every tile covered since the pass's clear is of this generation: rt_paint_mark put it
              # there, and the clear forgot what was covered before it. A tile settled at an earlier
              # flush of the pass and not covered since has its two keys the same, and is passed
              # over. Y counts the tiles and X their keys; +pointer+ points at PAINTED_IN, +planes+
              # at REPAINT and UNSENT.
              asm.label("rt_paint_flush_tile")
              asm.lda(asm.abs_x(keys_now & 0xFFFF))
              asm.cmp(asm.abs_x(keys_copy & 0xFFFF))
              asm.bne("rt_paint_flush_changed")
              asm.lda(asm.abs_x((keys_now & 0xFFFF) + 2))
              asm.cmp(asm.abs_x((keys_copy & 0xFFFF) + 2))
              asm.bne("rt_paint_flush_changed")
              # The copy holds it already: nothing painted it since it was painted (in this
              # generation), or it is painted the way it was in an older one.
              asm.sep(0x20)
              asm.lda(generation)
              asm.sta(asm.abs_y(memory[PAINTED_IN] & 0xFFFF))
              asm.rep(0x20)
              asm.lda(asm.abs(memory[SENDING]))
              asm.beq("rt_paint_flush_tile_done")
              # It may be unsent from an earlier flush; one that is not, with no run started, is
              # nothing to send, and is passed over here rather than in a call.
              asm.lda(asm.abs_y(memory[UNSENT] & 0xFFFF))
              asm.and_a(0x00FF)
              asm.bne("rt_paint_flush_tile_send")
              asm.lda(asm.direct(s.chunk))
              asm.bmi("rt_paint_flush_tile_done")
              asm.label("rt_paint_flush_tile_send")
              asm.jsr(asm.abs("rt_paint_flush_send_tile"))
              asm.bra("rt_paint_flush_tile_done")
              asm.label("rt_paint_flush_changed")
              asm.lda(asm.ind_long_y(s.pointer))
              asm.and_a(0x00FF)
              asm.cmp(generation)
              asm.beq("rt_paint_flush_paint") # painted in this generation already: again, on top
              asm.sep(0x20)
              asm.lda(generation)
              asm.sta(asm.ind_long_y(s.pointer))
              asm.rep(0x20)
              emit_unless_clear_already(asm, memory, "rt_paint_flush_paint") # (X its key)
              asm.sty(asm.direct(s.tile))
              asm.jsr(asm.abs("rt_paint_blank_tile"))
              asm.label("rt_paint_flush_paint")
              2.times do |half|
                asm.lda(asm.long_x(keys_now, half * 2))
                asm.sta(asm.long_x(keys_copy, half * 2))
              end
              asm.sep(0x20)
              asm.lda(asm.abs(memory[STAMP]))
              asm.sta(asm.ind_long_y(s.planes))
              asm.rep(0x20)
              asm.inc(asm.direct(s.count))
              # Sending, it goes on a run now; else it is unsent until then.
              asm.lda(asm.abs(memory[SENDING]))
              asm.beq("rt_paint_flush_unsent")
              asm.jsr(asm.abs("rt_paint_flush_send_changed"))
              asm.bra("rt_paint_flush_tile_done")
              asm.label("rt_paint_flush_unsent")
              asm.sep(0x20)
              asm.lda(1)
              asm.sta(asm.ind_long_y(s.planes + 4))
              asm.rep(0x20)
              asm.label("rt_paint_flush_tile_done")
              4.times { asm.inx }
              asm.iny
              asm.cpy(asm.direct(s.last))
              asm.branch_long(:bcc, "rt_paint_flush_tile")
              asm.plx
              # Sending, the row's last run is ended and the row said unchanged.
              asm.lda(asm.abs(memory[SENDING]))
              asm.beq("rt_paint_flush_next_row")
              asm.sty(asm.direct(s.tile))
              asm.phx
              asm.jsr(asm.abs("rt_paint_run_end"))
              asm.plx
              asm.lda(Paint::NONE_LEFT)
              asm.sta(asm.abs_x(dirty))
              asm.stz(asm.abs_x(dirty + 2))
              asm.label("rt_paint_flush_next_row")
              asm.lda(asm.direct(s.row))
              asm.clc
              asm.adc(Paint::COLUMNS)
              asm.sta(asm.direct(s.row))
              4.times { asm.inx }
              asm.cpx(asm.abs(dirty_rows + 2))
              asm.branch_long(:bcc, "rt_paint_flush_row")
              asm.label("rt_paint_flush_rows_done")
              asm.plb
              asm.lda(asm.direct(s.count))
              asm.beq("rt_paint_flush_done")
              asm.jsr(asm.abs("rt_paint_replay"))
              asm.label("rt_paint_flush_done")
              asm.stz(asm.abs(memory[LOG_END]))
              asm.rts

              # rt_paint_flush_sending (JSR, as the pass ends): the flush, and each tile of the rows
              # it looks at put on Paint's runs to send as it goes, rather than looked at again
              # (Paint's rt_paint_prepare does that for a pass painted at once); the rows said
              # unchanged after.
              asm.label("rt_paint_flush_sending")
              # The log the next pass compares with: this one, if it is whole.
              asm.lda(NO_LAST_PASS)
              asm.ldx(asm.abs(memory[LOG_WHOLE]))
              asm.beq("rt_paint_flush_sending_last_pass")
              asm.lda(asm.abs(memory[LOG_END]))
              asm.label("rt_paint_flush_sending_last_pass")
              asm.sta(asm.abs(memory[LAST_PASS_END]))
              asm.lda(1)
              asm.sta(asm.abs(memory[SENDING]))
              asm.jsr(asm.abs("rt_paint_flush"))
              asm.stz(asm.abs(memory[SENDING]))
              emit_no_rows(asm, memory, Paint::DIRTY)
              asm.rts

              emit_send_tile(asm, memory, s)
            end

            # rt_paint_flush_send_tile (JSR, Y the tile): a tile whose slot of video RAM is behind the
            # copy (UNSENT) put on a run to send, one on the screen now (its cell of the map as video
            # RAM has it points at it) on a run of its own kind; any other ends the run. Keeps X
            # and Y. (+chunk+ is the run's first tile, or none, +mask+ its kind, +not_mask+ the
            # tile's, as Paint's rt_paint_prepare keeps them.)
            def emit_send_tile(asm, memory, s)
              asm.label("rt_paint_flush_send_tile")
              asm.lda(asm.ind_long_y(s.planes + 4))
              asm.and_a(0x00FF)
              asm.bne("rt_paint_flush_send_tile_unsent")
              asm.lda(asm.direct(s.chunk))
              asm.bmi("rt_paint_flush_send_tile_done")
              emit_run_end_keeping(asm, s)
              asm.label("rt_paint_flush_send_tile_done")
              asm.rts
              asm.label("rt_paint_flush_send_tile_unsent")
              asm.sep(0x20)
              asm.lda(0)
              asm.sta(asm.ind_long_y(s.planes + 4))
              asm.rep(0x20)
              # rt_paint_flush_send_changed (JSR): the same for a tile the flush has just painted,
              # never marked unsent.
              asm.label("rt_paint_flush_send_changed")
              asm.jsr(asm.abs("rt_paint_slot_behind")) # (X its key)
              asm.bne("rt_paint_flush_send_tile_sent")
              asm.lda(asm.direct(s.chunk)) # its slot holds it already: as a tile not sent
              asm.bmi("rt_paint_flush_send_tile_done")
              emit_run_end_keeping(asm, s)
              asm.rts
              asm.label("rt_paint_flush_send_tile_sent")
              asm.phx
              asm.tya
              asm.asl
              asm.tax
              asm.tya
              asm.cmp(asm.long_x(memory[Paint::MAP_COPY]))
              asm.beq("rt_paint_flush_send_tile_shown")
              asm.lda(0)
              asm.bra("rt_paint_flush_send_tile_kind")
              asm.label("rt_paint_flush_send_tile_shown")
              asm.lda(1)
              asm.label("rt_paint_flush_send_tile_kind")
              asm.sta(asm.direct(s.not_mask))
              asm.plx
              asm.lda(asm.direct(s.chunk))
              asm.bmi("rt_paint_flush_send_tile_start")
              asm.lda(asm.direct(s.not_mask))
              asm.cmp(asm.direct(s.mask))
              asm.beq("rt_paint_flush_send_tile_done")
              emit_run_end_keeping(asm, s)
              asm.label("rt_paint_flush_send_tile_start")
              asm.sty(asm.direct(s.chunk))
              asm.lda(asm.direct(s.not_mask))
              asm.sta(asm.direct(s.mask))
              asm.rts
            end

            # rt_paint_slot_behind (JSR, X a tile's key, four bytes a tile): A not nought, and the
            # slot's key said to be the copy's, if the tile's slot of video RAM is behind the copy;
            # nought if it holds what the copy holds already, as when a pass painted a tile on its
            # way (a flush with the log full) and ended where the last pass did. A key of nought is
            # a tile painted at once, which no key says: always sent. Keeps X and Y.
            def emit_slot_behind(asm, memory)
              copy = memory[KEYS_COPY]
              shown = memory[KEYS_SHOWN]
              asm.label("rt_paint_slot_behind")
              asm.lda(asm.long_x(copy))
              asm.ora(asm.long_x(copy, 2))
              asm.beq("rt_paint_slot_behind_yes")
              asm.lda(asm.long_x(copy))
              asm.cmp(asm.long_x(shown))
              asm.bne("rt_paint_slot_behind_yes")
              asm.lda(asm.long_x(copy, 2))
              asm.cmp(asm.long_x(shown, 2))
              asm.bne("rt_paint_slot_behind_yes")
              asm.lda(0)
              asm.rts
              asm.label("rt_paint_slot_behind_yes")
              2.times do |half|
                asm.lda(asm.long_x(copy, half * 2))
                asm.sta(asm.long_x(shown, half * 2))
              end
              asm.lda(1)
              asm.rts
            end

            # Paint's rt_paint_run_end at the tile in Y, X and Y kept.
            def emit_run_end_keeping(asm, s)
              asm.phx
              asm.phy
              asm.sty(asm.direct(s.tile))
              asm.jsr(asm.abs("rt_paint_run_end"))
              asm.ply
              asm.plx
            end

            # On to +past+ if the copy's tile, its key at X, is already the clear colour throughout:
            # its key SEED. Making it so is 32 stores.
            def emit_unless_clear_already(asm, memory, past)
              tag = "#{past}_unless_clear"
              asm.lda(asm.long_x(memory[KEYS_COPY]))
              asm.cmp(asm.abs(memory[SEED]))
              asm.bne(tag)
              asm.lda(asm.long_x(memory[KEYS_COPY], 2))
              asm.cmp(asm.abs(memory[SEED] + 2))
              asm.beq(past)
              asm.label(tag)
            end

            # rt_paint_blank_tile (JSR): tile +tile+ of the copy made the clear colour throughout:
            # eight rows of the clear colour's four words of planes. Keeps X.
            def emit_blank_tile(asm, memory, s, bank)
              asm.label("rt_paint_blank_tile")
              asm.phx
              asm.lda(asm.direct(s.tile))
              6.times { asm.asl }
              asm.tax
              4.times do |pair|
                asm.lda(asm.abs(memory[Paint::CLEAR_PLANES] + (pair * 2)))
                8.times { |row| asm.sta(asm.long_x((bank << 16) + (pair * 16) + (row * 2))) }
              end
              asm.plx
              asm.rts
            end

            # rt_paint_replay (JSR): the paintings of the log that cover a tile this flush paints (its
            # REPAINT the STAMP) painted again whole, each held to the area it was held to; the area
            # there was put back after. The routines' painting part is entered past where they write
            # themselves down (rt_paint_fill_now, rt_paint_blit_now), and REPLAYING tells them not to.
            #
            # A painting done again whole paints every tile it covers, so each of those tiles must
            # have every painting of the log that covers it done again too, in order: a tile left
            # alone keeps the last painting's colour where two overlap, and doing only the first again
            # would put its colour back on top. So first every tile of a painting that is done again
            # is to be painted as well, and that is repeated until no more tiles are taken in. A tile
            # taken in so is painted the way it already is, and its key and copy do not change.
            # (+pointer+ is REPAINT's place, +column+ whether a round took a tile in.)
            def emit_replay(asm, memory, s)
              log = memory[LOG]
              area = memory[Paint::AREA]
              asm.label("rt_paint_replay")
              emit_pointer(asm, s.pointer, memory[REPAINT])
              asm.label("rt_paint_replay_round")
              asm.stz(asm.direct(s.column))
              asm.ldx(0)
              asm.label("rt_paint_replay_look")
              asm.cpx(asm.abs(memory[LOG_END]))
              asm.bcs("rt_paint_replay_looked")
              asm.jsr(asm.abs("rt_paint_entry_repainted"))
              asm.sta(asm.long_x(log, ENTRY_AGAIN))
              asm.beq("rt_paint_replay_look_next")
              asm.jsr(asm.abs("rt_paint_entry_repaint"))
              asm.label("rt_paint_replay_look_next")
              asm.txa
              asm.clc
              asm.adc(ENTRY_BYTES)
              asm.tax
              asm.bra("rt_paint_replay_look")
              asm.label("rt_paint_replay_looked")
              asm.lda(asm.direct(s.column))
              asm.bne("rt_paint_replay_round")

              4.times do |i|
                asm.lda(asm.abs(area + (i * 2)))
                asm.pha
              end
              asm.lda(1)
              asm.sta(asm.abs(memory[REPLAYING]))
              asm.ldx(0)
              asm.label("rt_paint_replay_entry")
              asm.cpx(asm.abs(memory[LOG_END]))
              asm.branch_long(:bcs, "rt_paint_replay_done")
              asm.lda(asm.long_x(log, ENTRY_AGAIN))
              asm.branch_long(:beq, "rt_paint_replay_next")
              4.times do |i|
                asm.lda(asm.long_x(log, ENTRY_AREA + (i * 2)))
                asm.sta(asm.abs(area + (i * 2)))
              end
              (NUMBER_BYTES / 2).times do |i|
                asm.lda(asm.long_x(log, ENTRY_NUMBERS + (i * 2)))
                asm.sta(asm.direct(i * 2))
              end
              asm.phx
              asm.lda(asm.long_x(log))
              asm.and_a(0x00FF) # the kind, without whether its area was the screen's
              asm.cmp(KIND_FILL)
              asm.bne("rt_paint_replay_blit")
              asm.jsl(asm.long("rt_paint_fill_now"))
              asm.bra("rt_paint_replay_painted")
              asm.label("rt_paint_replay_blit")
              asm.jsl(asm.long("rt_paint_blit_now"))
              asm.label("rt_paint_replay_painted")
              asm.plx
              asm.label("rt_paint_replay_next")
              asm.txa
              asm.clc
              asm.adc(ENTRY_BYTES)
              asm.tax
              asm.brl("rt_paint_replay_entry")
              asm.label("rt_paint_replay_done")
              asm.stz(asm.abs(memory[REPLAYING]))
              3.downto(0) do |i|
                asm.pla
                asm.sta(asm.abs(area + (i * 2)))
              end
              asm.rts

              emit_entry_tiles(asm, memory, s, "rt_paint_entry_repainted") do
                # A = 1 if a tile is to be painted, at once; 0 after the last.
                asm.cmp(asm.abs(memory[STAMP]))
                asm.bne("rt_paint_entry_repainted_not")
                asm.lda(1)
                asm.rts
                asm.label("rt_paint_entry_repainted_not")
              end
              asm.lda(0)
              asm.rts

              emit_entry_tiles(asm, memory, s, "rt_paint_entry_repaint") do
                asm.cmp(asm.abs(memory[STAMP]))
                asm.beq("rt_paint_entry_repaint_already")
                asm.sep(0x20)
                asm.lda(asm.abs(memory[STAMP]))
                asm.sta(asm.ind_long_y(s.pointer))
                asm.rep(0x20)
                asm.lda(1)
                asm.sta(asm.direct(s.column)) # a tile taken in: another round
                asm.label("rt_paint_entry_repaint_already")
              end
              asm.rts
            end

            # A routine +label+ (JSR, X the log entry) that runs the block for each tile the entry's
            # painting covers, row by row, with A its REPAINT byte and Y its number; +pointer+ points
            # at REPAINT. Keeps X.
            def emit_entry_tiles(asm, memory, s, label)
              log = memory[LOG]
              asm.label(label)
              asm.lda(asm.long_x(log, ENTRY_TOP))
              asm.sta(asm.direct(s.mark_row))
              asm.label("#{label}_row")
              asm.lda(asm.direct(s.mark_row))
              5.times { asm.asl }
              asm.clc
              asm.adc(asm.long_x(log, ENTRY_FIRST))
              asm.tay
              asm.lda(asm.long_x(log, ENTRY_LAST))
              asm.sec
              asm.sbc(asm.long_x(log, ENTRY_FIRST))
              asm.inc
              asm.sta(asm.direct(s.mark_count))
              asm.label("#{label}_tile")
              asm.lda(asm.ind_long_y(s.pointer))
              asm.and_a(0x00FF)
              yield
              asm.iny
              asm.dec(asm.direct(s.mark_count))
              asm.bne("#{label}_tile")
              asm.lda(asm.direct(s.mark_row))
              asm.cmp(asm.long_x(log, ENTRY_BOTTOM))
              asm.beq("#{label}_done")
              asm.inc(asm.direct(s.mark_row))
              asm.bra("#{label}_row")
              asm.label("#{label}_done")
            end

            # The 24-bit pointer at +at+ on the direct page pointed at +address+.
            def emit_pointer(asm, at, address)
              asm.lda(address & 0xFFFF)
              asm.sta(asm.direct(at))
              asm.lda(address >> 16)
              asm.sta(asm.direct(at + 2))
            end

            # rt_paint_map_runs (JSR, as a pass ends, after the flush): each cell of MAP_DIRTY's rows
            # worked out again, its own tile for a tile of this generation and the clear tile for any
            # other, into Paint::MAP_COPY, which holds the map as video RAM has it; each row's cells
            # that changed, from the first to the last, a run to send.
            # (+chunk+ is the row's first cell changed, or none, +mark_count+ its last, +last+ the
            # row's last cell and one; Y counts the cells, X their words of the map, and +mask+ is
            # the generation.)
            #
            # Every cell of a changed row is looked at, which for half the screen changed is all
            # 896 of them, so the loop over a row's cells works with the data bank at the map's
            # (GENERATIONS is in the same bank): a 16-bit address reaches both, an instruction a
            # byte shorter and a cycle quicker than a long one, and the generation is on the
            # direct page, which the data bank does not move.
            def emit_map_runs(asm, memory, s)
              map = memory[Paint::MAP_COPY]
              generations = memory[Paint::GENERATIONS]
              raise ArgumentError, "the map and the generations share a bank" unless map >> 16 == generations >> 16

              runs = memory[MAP_RUNS]
              map_rows = memory[ROWS_OF.fetch(MAP_DIRTY)]
              asm.label("rt_paint_map_runs")
              asm.stz(asm.abs(memory[MAP_RUNS_END]))
              asm.stz(asm.abs(memory[MAP_RUN_BYTES]))
              asm.lda(asm.abs(memory[Paint::GENERATION]))
              asm.sta(asm.direct(s.mask))
              asm.ldx(asm.abs(map_rows))
              asm.txa
              3.times { asm.asl } # the row's first cell
              asm.sta(asm.direct(s.row))
              asm.cpx(asm.abs(map_rows + 2))
              asm.branch_long(:bcs, "rt_paint_map_runs_rows_done")
              asm.label("rt_paint_map_runs_row")
              asm.lda(asm.long_x(memory[MAP_DIRTY], 2))
              asm.cmp(asm.long_x(memory[MAP_DIRTY]))
              asm.branch_long(:bcc, "rt_paint_map_runs_next_row")
              asm.sec
              asm.adc(asm.direct(s.row))
              asm.sta(asm.direct(s.last))
              asm.lda(asm.long_x(memory[MAP_DIRTY]))
              asm.clc
              asm.adc(asm.direct(s.row))
              asm.tay
              asm.lda(Paint::NONE_LEFT)
              asm.sta(asm.long_x(memory[MAP_DIRTY]))
              asm.lda(0)
              asm.sta(asm.long_x(memory[MAP_DIRTY], 2))
              asm.phx
              asm.tya
              asm.asl
              asm.tax
              asm.lda(0xFFFF)
              asm.sta(asm.direct(s.chunk))
              asm.phb
              asm.sep(0x20)
              asm.lda(map >> 16)
              asm.pha
              asm.plb
              asm.rep(0x20)
              # The loop twice over: up to the row's first cell that changed, which starts the run,
              # and then from it, where a cell that changed only moves the run's end. Half the
              # screen changed is every cell changed, and the run's start asked once a row rather
              # than at each.
              emit_map_cells(asm, s, map, generations, "rt_paint_map_runs_cell") do
                asm.sty(asm.direct(s.chunk))
                asm.sty(asm.direct(s.mark_count))
                asm.bra("rt_paint_map_runs_run_next")
              end
              asm.bra("rt_paint_map_runs_row_looked")
              emit_map_cells(asm, s, map, generations, "rt_paint_map_runs_run") do
                asm.sty(asm.direct(s.mark_count))
              end
              asm.label("rt_paint_map_runs_row_looked")
              asm.plb
              asm.lda(asm.direct(s.chunk))
              asm.bmi("rt_paint_map_runs_none")
              asm.ldx(asm.abs(memory[MAP_RUNS_END]))
              asm.sta(asm.long_x(runs))
              asm.lda(asm.direct(s.mark_count))
              asm.sec
              asm.sbc(asm.direct(s.chunk))
              asm.inc
              asm.sta(asm.long_x(runs, 2))
              asm.asl
              asm.clc
              asm.adc(Paint::RUN_SETTING_UP)
              asm.clc
              asm.adc(asm.abs(memory[MAP_RUN_BYTES]))
              asm.sta(asm.abs(memory[MAP_RUN_BYTES]))
              asm.txa
              asm.clc
              asm.adc(4)
              asm.sta(asm.abs(memory[MAP_RUNS_END]))
              asm.label("rt_paint_map_runs_none")
              asm.plx
              asm.label("rt_paint_map_runs_next_row")
              asm.lda(asm.direct(s.row))
              asm.clc
              asm.adc(Paint::COLUMNS)
              asm.sta(asm.direct(s.row))
              4.times { asm.inx }
              asm.cpx(asm.abs(map_rows + 2))
              asm.branch_long(:bcc, "rt_paint_map_runs_row")
              asm.label("rt_paint_map_runs_rows_done")
              emit_no_rows(asm, memory, MAP_DIRTY)
              asm.rts
            end

            # In rt_paint_map_runs, the data bank the map's: the row's cells from Y (X its word of
            # the map) up to +last+, each worked out and compared with the map, and one that changed
            # written there and handed to the block. Out at the end when the row is done; the block
            # may leave the loop itself. +tag+ names the loop's top, and +tag+_next where the next
            # cell is taken.
            def emit_map_cells(asm, s, map, generations, tag)
              asm.bra(tag)
              asm.label("#{tag}_older")
              asm.lda(Paint::CLEAR_CELL)
              asm.cmp(asm.abs_x(map & 0xFFFF))
              asm.bne("#{tag}_changed")
              asm.bra("#{tag}_next")
              asm.label(tag)
              asm.lda(asm.abs_y(generations & 0xFFFF))
              asm.and_a(0x00FF)
              asm.cmp(asm.direct(s.mask))
              asm.bne("#{tag}_older")
              asm.tya # its own tile
              asm.cmp(asm.abs_x(map & 0xFFFF))
              asm.beq("#{tag}_next")
              asm.label("#{tag}_changed")
              asm.sta(asm.abs_x(map & 0xFFFF))
              yield
              asm.label("#{tag}_next")
              asm.inx
              asm.inx
              asm.iny
              asm.cpy(asm.direct(s.last))
              asm.bcc(tag)
            end

            # In the blank (Paint's rt_paint_upload, with the map's other copies): each run of cells
            # copied from MAP_COPY to the map in video RAM.
            def emit_map_runs_upload(asm, memory)
              h = Console::SNESHardware
              map = memory[Paint::MAP_COPY]
              runs = memory[MAP_RUNS]
              asm.ldx(0)
              asm.label("rt_paint_map_runs_send")
              asm.cpx(asm.abs(memory[MAP_RUNS_END]))
              asm.bcs("rt_paint_map_runs_sent")
              asm.lda(asm.long_x(runs))
              asm.clc
              asm.adc(Paint::MAP)
              asm.sta(asm.abs(h::VMADDL))
              asm.lda(asm.long_x(runs))
              asm.asl
              asm.clc
              asm.adc(map & 0xFFFF)
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              asm.lda(asm.long_x(runs, 2))
              asm.asl
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              asm.sep(0x20)
              asm.lda(map >> 16)
              Paint.emit_copy_to_video_ram(asm)
              4.times { asm.inx }
              asm.bra("rt_paint_map_runs_send")
              asm.label("rt_paint_map_runs_sent")
              asm.stz(asm.abs(memory[MAP_RUNS_END]))
              asm.stz(asm.abs(memory[MAP_RUN_BYTES]))
            end
          end
        end
      end
    end
  end
end
