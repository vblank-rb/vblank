# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # The copy of a screen of big pixels to video RAM (PaintDoubled), and the second copy that
          # lets the game paint on while it goes.
          #
          # What a pass changed is sent in the blank with the screen on, as many bytes as the blank
          # has room for (see Blank): the rows changed of each column of tiles (PaintDoubled's
          # DIRTY_TOP and DIRTY_BOTTOM), a column's run joined to the one before where it carries
          # straight on from it. A whole picture is 14336 bytes, three blanks' worth.
          #
          # With one copy the game waits, at the end of its pass, until all of it has arrived, as it
          # must not paint over a picture still being sent: three frames of a whole repaint spent
          # waiting. The console's own 3D games kept two pictures in work RAM instead, and painted
          # the next while the last was sent. So does this, where nothing else has to arrive after
          # the picture (#behind?):
          #
          # - Two copies, one after the other in the last bank, PAINT_OFFSET saying which one the
          #   game paints (rt_paint_doubled_at adds it). As a pass ends the two swap
          #   (rt_paint_doubled_swap): the copy just painted is sent, and the other is painted next.
          # - Sent behind the game. What the pass's own blank cannot hold is sent by the blank's
          #   interrupt in the blanks after (rt_paint_doubled_behind), while the next pass is
          #   painted; with the last piece there, SHOWN is set to that pass. A pass ending while the last
          #   picture is still going sends the rest itself first, and then waits for a blank of its
          #   own, so every picture is on the screen whole for a frame at least.
          # - Stale rows. The copy about to be painted is behind the other where the last pass
          #   changed it (STALE_TOP and STALE_BOTTOM, for each column of tiles). Before a column of
          #   tiles is painted where that reaches its stale rows, they are copied across from the
          #   other copy (rt_paint_doubled_freshen, MVN); a fill that covers a column of tiles from
          #   side to side over some of them needs nothing copied there, so a view that paints its
          #   ceiling and floor and then its walls copies nothing at all. The rows the other copy
          #   is still behind in when the copies swap (RESTING_TOP and RESTING_BOTTOM) are copied
          #   across then.
          #
          # A copy at a time needs only the arrays of what is being sent.
          module PaintDoubledSend
            # The rows of each column of tiles still to send (a word each, as dirty), the column
            # looked at next (two bytes a column), and the run being sent: its first byte, which is
            # its word in video RAM too, and its bytes, nought for none.
            SEND_TOP = "rt paint doubled send top"
            SEND_BOTTOM = "rt paint doubled send bottom"
            SEND_COLUMN = "rt paint doubled send column"
            SEND_START = "rt paint doubled send start"
            SEND_BYTES = "rt paint doubled send bytes"
            SEND_PIECE = "rt paint doubled send piece"
            # With two copies: where the copy being sent is, from the first; 1 while a picture is
            # still being sent behind the game, and the pass it is; 1 while the game's own copy in
            # its blank is going, so the interrupt leaves video RAM alone; and the frame (FRAMES's
            # low word) the last picture finished arriving in.
            SEND_FROM = "rt paint doubled send from"
            SENDING = "rt paint doubled sending"
            SEND_PASS = "rt paint doubled send pass"
            UPLOADING = "rt paint doubled uploading"
            DONE_FRAME = "rt paint doubled done frame"
            # Where the copy painted is, from the first; the rows of each column of tiles it is
            # behind the other in, and the other's behind this one in.
            PAINT_OFFSET = "rt paint doubled paint offset"
            PAINT_STARTS = "rt paint doubled paint starts"
            STALE_TOP = "rt paint doubled stale top"
            STALE_BOTTOM = "rt paint doubled stale bottom"
            RESTING_TOP = "rt paint doubled resting top"
            RESTING_BOTTOM = "rt paint doubled resting bottom"
            # What rt_paint_doubled_copy_rows is handed: the rows of a column of tiles, and the two
            # copies' places from the first.
            ROWS_TOP = "rt paint doubled rows top"
            ROWS_BOTTOM = "rt paint doubled rows bottom"
            ROWS_FROM = "rt paint doubled rows from"
            ROWS_TO = "rt paint doubled rows to"
            # A frame no count of frames is at as the game starts.
            NO_FRAME = 0xFFFF

            # The copying engine's channel: with two copies, one nothing else uses, since the
            # interrupt can start it in the middle of the game setting up channel 0. Letterbox's
            # line table is channel 7 too, and a game with one keeps one copy.
            BEHIND_CHANNEL = 7

            COLUMNS = 16

            module_function

            # Whether the screen keeps two copies and sends behind the game: one whose rows are all
            # shown (+band+ nil) and with nothing that must arrive after the picture as it changes:
            # no fade of the brightness (+dims+) nor blocks (+mosaic+), which follow the picture.
            def behind_for?(band:, dims:, mosaic:) = band.nil? && !dims && !mosaic

            def reserve(memory, behind:)
              [SEND_TOP, SEND_BOTTOM].each { |name| memory.reserve(name, COLUMNS * 2) }
              [SEND_COLUMN, SEND_START, SEND_BYTES, SEND_PIECE].each { |name| memory.reserve(name, 2) }
              return unless behind

              [SEND_FROM, SENDING, UPLOADING, DONE_FRAME, PAINT_OFFSET, ROWS_TOP, ROWS_BOTTOM, ROWS_FROM, ROWS_TO].each do |name|
                memory.reserve(name, 2)
              end
              memory.reserve(SEND_PASS, 4)
              [STALE_TOP, STALE_BOTTOM, RESTING_TOP, RESTING_BOTTOM, PAINT_STARTS].each { |name| memory.reserve(name, COLUMNS * 2) }
            end

            def behind?(memory) = memory.reserved?(SENDING)

            # On to +target+ while a picture is still being sent behind the game (Frame's
            # rt_show_pass, which then leaves SHOWN to rt_paint_doubled_behind). Nothing with one copy.
            def emit_branch_if_sending(asm, memory, target)
              return unless behind?(memory)

              asm.lda(asm.abs(memory[SENDING]))
              asm.bne(target)
            end

            # At power-on (A 16 bits wide): nothing being sent, the first copy painted, neither
            # behind the other.
            def emit_start(asm, memory)
              return unless behind?(memory)

              asm.stz(asm.abs(memory[SENDING]))
              asm.stz(asm.abs(memory[UPLOADING]))
              asm.stz(asm.abs(memory[PAINT_OFFSET]))
              asm.lda(NO_FRAME)
              asm.sta(asm.abs(memory[DONE_FRAME]))
              asm.ldx(0)
              asm.label("rt_paint_doubled_start_none_stale")
              asm.lda(PaintDoubled::HEIGHT)
              asm.sta(asm.abs_x(memory[STALE_TOP]))
              asm.sta(asm.abs_x(memory[RESTING_TOP]))
              asm.stz(asm.abs_x(memory[STALE_BOTTOM]))
              asm.stz(asm.abs_x(memory[RESTING_BOTTOM]))
              asm.inx
              asm.inx
              asm.cpx(COLUMNS * 2)
              asm.bne("rt_paint_doubled_start_none_stale")
              emit_painted_starts(asm, memory, "rt_paint_doubled_start")
            end

            # A = A plus where the copy painted is (a fill's bytes).
            def emit_paint_offset_added(asm, memory)
              return unless behind?(memory)

              asm.clc
              asm.adc(asm.abs(memory[PAINT_OFFSET]))
            end

            # Where column of tiles X (two bytes a column) starts in the copy painted, a word: with
            # two copies, PaintDoubled's table with where the copy is added (PAINT_STARTS), kept
            # as the copies swap, so a column's byte is found without adding it each time.
            def painted_start(asm, memory)
              behind?(memory) ? asm.abs_x(memory[PAINT_STARTS]) : asm.long_x("rt paint doubled column starts")
            end

            # PAINT_STARTS made for the copy at PAINT_OFFSET. Uses X.
            def emit_painted_starts(asm, memory, prefix)
              asm.ldx(0)
              asm.label("#{prefix}_painted_starts")
              asm.lda(asm.long_x("rt paint doubled column starts"))
              asm.clc
              asm.adc(asm.abs(memory[PAINT_OFFSET]))
              asm.sta(asm.abs_x(memory[PAINT_STARTS]))
              asm.inx
              asm.inx
              asm.cpx(COLUMNS * 2)
              asm.bne("#{prefix}_painted_starts")
            end

            # --- the copy painted kept up with the other ---

            # Where rt_paint_doubled_mark looks at the column of tiles X (two bytes a column): for a
            # fill (+filled+, a word nought for none) covering the column from side to side, the
            # stale rows it covers are no longer stale, as long as what is left is one run of rows;
            # then if the rows changed with the mark's added reach the stale rows, they are copied
            # across first. +mark+ is PaintDoubled's Mark.
            def emit_stale_rows_copied_for_mark(asm, memory, mark, filled)
              return unless behind?(memory)

              at = ->(name) { asm.abs_x(memory[name]) }
              asm.lda(at.call(STALE_TOP))
              asm.cmp(at.call(STALE_BOTTOM))
              asm.bcs("rt_paint_doubled_mark_fresh")
              asm.lda(asm.abs(filled))
              asm.beq("rt_paint_doubled_mark_stale")
              # Covered from side to side: the column's left pixel is X × 4.
              asm.txa
              asm.asl
              asm.asl
              asm.cmp(asm.direct(mark.left))
              asm.bcc("rt_paint_doubled_mark_stale")
              asm.adc(7) # the carry is set: eight on
              asm.cmp(asm.direct(mark.right))
              asm.beq("rt_paint_doubled_mark_covered")
              asm.bcs("rt_paint_doubled_mark_stale")
              asm.label("rt_paint_doubled_mark_covered")
              asm.lda(asm.direct(mark.top))
              asm.cmp(at.call(STALE_TOP))
              asm.beq("rt_paint_doubled_mark_from_above")
              asm.bcc("rt_paint_doubled_mark_from_above")
              # From below the stale rows' top: the stale rows end where it starts, if it reaches
              # their bottom and starts above it.
              asm.cmp(at.call(STALE_BOTTOM))
              asm.bcs("rt_paint_doubled_mark_stale")
              asm.lda(asm.direct(mark.bottom))
              asm.cmp(at.call(STALE_BOTTOM))
              asm.bcc("rt_paint_doubled_mark_stale")
              asm.lda(asm.direct(mark.top))
              asm.sta(at.call(STALE_BOTTOM))
              asm.bra("rt_paint_doubled_mark_stale")
              # From their top or above: they start where it ends, or are gone if it reaches their
              # bottom.
              asm.label("rt_paint_doubled_mark_from_above")
              asm.lda(asm.direct(mark.bottom))
              asm.cmp(at.call(STALE_TOP))
              asm.beq("rt_paint_doubled_mark_stale")
              asm.bcc("rt_paint_doubled_mark_stale")
              asm.cmp(at.call(STALE_BOTTOM))
              asm.bcc("rt_paint_doubled_mark_stale_from")
              asm.lda(PaintDoubled::HEIGHT)
              asm.sta(at.call(STALE_TOP))
              asm.stz(at.call(STALE_BOTTOM))
              asm.bra("rt_paint_doubled_mark_stale")
              asm.label("rt_paint_doubled_mark_stale_from")
              asm.sta(at.call(STALE_TOP))

              # The rows changed so far with the mark's: from the higher top to the lower bottom.
              # Copied across first if that reaches the stale rows.
              asm.label("rt_paint_doubled_mark_stale")
              asm.lda(at.call(STALE_TOP))
              asm.cmp(at.call(STALE_BOTTOM))
              asm.bcs("rt_paint_doubled_mark_fresh")
              asm.lda(asm.direct(mark.top))
              asm.cmp(at.call(PaintDoubled::DIRTY_TOP))
              asm.bcc("rt_paint_doubled_mark_reach_top")
              asm.lda(at.call(PaintDoubled::DIRTY_TOP))
              asm.label("rt_paint_doubled_mark_reach_top")
              asm.cmp(at.call(STALE_BOTTOM))
              asm.bcs("rt_paint_doubled_mark_fresh")
              asm.lda(asm.direct(mark.bottom))
              asm.cmp(at.call(PaintDoubled::DIRTY_BOTTOM))
              asm.bcs("rt_paint_doubled_mark_reach_bottom")
              asm.lda(at.call(PaintDoubled::DIRTY_BOTTOM))
              asm.label("rt_paint_doubled_mark_reach_bottom")
              asm.cmp(at.call(STALE_TOP))
              asm.beq("rt_paint_doubled_mark_fresh")
              asm.bcc("rt_paint_doubled_mark_fresh")
              asm.jsr(asm.abs("rt_paint_doubled_freshen"))
              asm.label("rt_paint_doubled_mark_fresh")
            end

            # rt_paint_doubled_fresh (JSR): the stale rows copied across in every column of tiles
            # of +mark+'s pixels across whose stale rows its rows reach, before they are read
            # (rt_paint_save). Uses X. rt_paint_doubled_freshen (JSR): column of tiles X's stale
            # rows copied across, and none left. rt_paint_doubled_copy_rows (JSR): the rows
            # ROWS_TOP to before ROWS_BOTTOM of column of tiles X copied from the copy at ROWS_FROM
            # to the one at ROWS_TO, by MVN. Each keeps X.
            def emit_stale_row_copies(asm, memory, mark, shown, last)
              return unless behind?(memory)

              at = ->(name) { asm.abs_x(memory[name]) }
              asm.label("rt_paint_doubled_fresh")
              asm.lda(asm.direct(mark.right))
              asm.dec
              PaintDoubled.emit_column_of_tiles(asm)
              asm.stx(asm.abs(last))
              asm.lda(asm.direct(mark.left))
              PaintDoubled.emit_column_of_tiles(asm)
              asm.label("rt_paint_doubled_fresh_column")
              asm.lda(at.call(STALE_TOP))
              asm.cmp(at.call(STALE_BOTTOM))
              asm.bcs("rt_paint_doubled_fresh_next")
              asm.cmp(asm.direct(mark.bottom))
              asm.bcs("rt_paint_doubled_fresh_next")
              asm.lda(asm.direct(mark.top))
              asm.cmp(at.call(STALE_BOTTOM))
              asm.bcs("rt_paint_doubled_fresh_next")
              asm.jsr(asm.abs("rt_paint_doubled_freshen"))
              asm.label("rt_paint_doubled_fresh_next")
              asm.cpx(asm.abs(last))
              asm.beq("rt_paint_doubled_fresh_done")
              asm.inx
              asm.inx
              asm.bra("rt_paint_doubled_fresh_column")
              asm.label("rt_paint_doubled_fresh_done")
              asm.rts

              asm.label("rt_paint_doubled_freshen")
              asm.lda(at.call(STALE_TOP))
              asm.sta(asm.abs(memory[ROWS_TOP]))
              asm.lda(at.call(STALE_BOTTOM))
              asm.sta(asm.abs(memory[ROWS_BOTTOM]))
              asm.lda(asm.abs(memory[PAINT_OFFSET]))
              asm.sta(asm.abs(memory[ROWS_TO]))
              asm.lda(shown.copy_bytes)
              asm.sec
              asm.sbc(asm.abs(memory[PAINT_OFFSET]))
              asm.sta(asm.abs(memory[ROWS_FROM]))
              asm.jsr(asm.abs("rt_paint_doubled_copy_rows"))
              asm.lda(PaintDoubled::HEIGHT)
              asm.sta(at.call(STALE_TOP))
              asm.stz(at.call(STALE_BOTTOM))
              asm.rts

              copy = memory[PaintDoubled::COPY]
              asm.label("rt_paint_doubled_copy_rows")
              asm.phx
              asm.phb
              asm.lda(asm.abs(memory[ROWS_TOP]))
              3.times { asm.asl }
              asm.clc
              asm.adc(asm.long_x("rt paint doubled column starts"))
              asm.clc
              asm.adc(copy & 0xFFFF)
              asm.pha
              asm.clc
              asm.adc(asm.abs(memory[ROWS_TO]))
              asm.tay
              asm.lda(asm.stack(1))
              asm.clc
              asm.adc(asm.abs(memory[ROWS_FROM]))
              asm.tax
              asm.pla
              asm.lda(asm.abs(memory[ROWS_BOTTOM]))
              asm.sec
              asm.sbc(asm.abs(memory[ROWS_TOP]))
              3.times { asm.asl }
              asm.dec # MVN copies one more than A
              asm.mvn(copy >> 16, copy >> 16)
              asm.plb # MVN leaves the data bank at the copies'
              asm.plx
              asm.rts
            end

            # --- the copy to video RAM ---

            # rt_paint_upload (JSR, from Picture's rt_upload_copy): the rows the pass changed sent,
            # and then the colours if a fade or tint changed them, in a blank with room for all 512
            # bytes. With one copy, all of them now, a blank at a time. With two: what is still
            # being sent of the last picture first, then a blank of the picture's own; this pass's
            # rows as far as this blank has room, the rest left to the interrupt; and the copies
            # swapped. All of it now for a game that has stopped, or whose colours follow it.
            def emit_upload(asm, memory, shown)
              behind = behind?(memory)
              tint = memory[Tint::STATE]
              frame = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              asm.label("rt_paint_upload")
              if behind
                asm.lda(1)
                asm.sta(frame.call(UPLOADING))
                asm.lda(frame.call(SENDING))
                asm.beq("rt_paint_upload_none_behind")
                asm.jsr(asm.abs("rt_paint_doubled_send_all"))
                asm.stz(frame.call(SENDING))
                emit_pass_shown(asm, memory, SEND_PASS)
                asm.label("rt_paint_upload_none_behind")
              end
              asm.ldx(0)
              asm.label("rt_paint_upload_rows")
              [[PaintDoubled::DIRTY_TOP, SEND_TOP], [PaintDoubled::DIRTY_BOTTOM, SEND_BOTTOM]].each do |from, to|
                asm.lda(asm.abs_x(memory[from]))
                asm.sta(asm.abs_x(memory[to]))
              end
              unless behind
                asm.lda(PaintDoubled::HEIGHT)
                asm.sta(asm.abs_x(memory[PaintDoubled::DIRTY_TOP]))
                asm.stz(asm.abs_x(memory[PaintDoubled::DIRTY_BOTTOM]))
              end
              asm.inx
              asm.inx
              asm.cpx(COLUMNS * 2)
              asm.bne("rt_paint_upload_rows")
              asm.stz(frame.call(SEND_COLUMN))
              asm.stz(frame.call(SEND_BYTES))
              if behind
                asm.lda(frame.call(PAINT_OFFSET))
                asm.sta(frame.call(SEND_FROM))
                # The first run made up now, so a blank of the picture's own is all copying: one
                # whose start saw the last picture finish waits for the next.
                asm.jsr(asm.abs("rt_paint_doubled_send_run"))
                asm.lda(frame.call(Frame::FRAMES))
                asm.cmp(frame.call(DONE_FRAME))
                asm.bne("rt_paint_upload_own_blank")
                asm.jsr(asm.abs("rt_blank_next"))
                asm.label("rt_paint_upload_own_blank")
                asm.jsr(asm.abs("rt_paint_doubled_send_some"))
                asm.beq("rt_paint_upload_sent")
                # Left to the interrupt, unless the game stops here or its colours follow.
                asm.lda(frame.call(Frame::STATE))
                asm.ora(frame.call(Frame::HOLD))
                asm.ora(frame.call(Frame::HOLD, 2))
                asm.bne("rt_paint_upload_all")
                asm.lda(asm.abs(tint + Tint::CHANGED))
                asm.cmp(Tint::TO_SEND)
                asm.beq("rt_paint_upload_all")
                asm.lda(frame.call(Frame::PASSES))
                asm.sta(frame.call(SEND_PASS))
                asm.lda(frame.call(Frame::PASSES, 2))
                asm.sta(frame.call(SEND_PASS, 2))
                asm.lda(1)
                asm.sta(frame.call(SENDING))
                asm.bra("rt_paint_upload_swap")
                asm.label("rt_paint_upload_all")
                asm.jsr(asm.abs("rt_paint_doubled_send_all"))
                # All of it is there: Frame's rt_show_pass sets SHOWN, as for one copy.
                asm.label("rt_paint_upload_sent")
                asm.lda(frame.call(Frame::FRAMES))
                asm.sta(frame.call(DONE_FRAME))
                asm.label("rt_paint_upload_swap")
                asm.jsr(asm.abs("rt_paint_doubled_swap"))
              else
                asm.jsr(asm.abs("rt_paint_doubled_send_all"))
              end
              asm.lda(asm.abs(tint + Tint::CHANGED))
              asm.cmp(Tint::TO_SEND)
              asm.bne("rt_paint_upload_done")
              asm.lda(PaintDoubled::COLOR_BYTES)
              asm.jsr(asm.abs("rt_blank_room"))
              asm.jsr(asm.abs("rt_tint_upload"))
              asm.label("rt_paint_upload_done")
              asm.stz(frame.call(UPLOADING)) if behind
              asm.rts

              asm.label("rt_paint_doubled_send_all")
              asm.jsr(asm.abs("rt_paint_doubled_send_some"))
              asm.beq("rt_paint_doubled_send_all_done")
              asm.jsr(asm.abs("rt_blank_next"))
              asm.bra("rt_paint_doubled_send_all")
              asm.label("rt_paint_doubled_send_all_done")
              asm.rts

              emit_send_some(asm, memory, behind)
              emit_swap(asm, memory, shown) if behind
              emit_interrupt_send(asm, memory) if behind
            end

            # SHOWN = the pass at +pass+ (32 bits), and the frame the picture finished arriving in.
            def emit_pass_shown(asm, memory, pass)
              frame = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              asm.lda(frame.call(pass))
              asm.sta(frame.call(Frame::SHOWN))
              asm.lda(frame.call(pass, 2))
              asm.sta(frame.call(Frame::SHOWN, 2))
              asm.lda(frame.call(Frame::FRAMES))
              asm.sta(frame.call(DONE_FRAME))
            end

            # rt_paint_doubled_send_some (JSR): the rows still to send, as many bytes at a time as
            # this blank has room for, each run made up as the one before is done. A = nought, and
            # the flags with it, once all are sent; one if the blank had no more room. Every place
            # it keeps is in work RAM, not on the direct page, so the interrupt runs it as well.
            # rt_paint_doubled_send_run (JSR): the next run made up from the columns of tiles, if
            # there is none: A = nought, and the flags with it, when none is left. Both use X.
            def emit_send_some(asm, memory, behind)
              h = Console::SNESHardware
              copy = memory[PaintDoubled::COPY]
              channel = h::DMA_BASE + ((behind ? BEHIND_CHANNEL : 0) << 4)
              frame = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              rows = ->(name) { asm.abs_x(memory[name]) }
              starts = asm.long_x("rt paint doubled column starts")
              asm.label("rt_paint_doubled_send_some")
              asm.jsr(asm.abs("rt_paint_doubled_send_run"))
              asm.bne("rt_paint_doubled_send_piece")
              asm.rts

              asm.label("rt_paint_doubled_send_run")
              asm.lda(frame.call(SEND_BYTES))
              asm.bne("rt_paint_doubled_send_run_done")
              asm.ldx(frame.call(SEND_COLUMN))
              asm.label("rt_paint_doubled_send_look")
              asm.cpx(COLUMNS * 2)
              asm.branch_long(:bcs, "rt_paint_doubled_send_none_left")
              asm.lda(rows.call(SEND_TOP))
              asm.cmp(rows.call(SEND_BOTTOM))
              asm.bcc("rt_paint_doubled_send_found")
              asm.inx
              asm.inx
              asm.bra("rt_paint_doubled_send_look")
              asm.label("rt_paint_doubled_send_found")
              3.times { asm.asl }
              asm.clc
              asm.adc(starts)
              asm.sta(frame.call(SEND_START))
              asm.lda(rows.call(SEND_BOTTOM))
              asm.sec
              asm.sbc(rows.call(SEND_TOP))
              3.times { asm.asl }
              asm.sta(frame.call(SEND_BYTES))
              # The columns after it whose rows start where its run ends join it.
              asm.label("rt_paint_doubled_send_join")
              asm.inx
              asm.inx
              asm.cpx(COLUMNS * 2)
              asm.bcs("rt_paint_doubled_send_joined")
              asm.lda(rows.call(SEND_TOP))
              asm.cmp(rows.call(SEND_BOTTOM))
              asm.bcs("rt_paint_doubled_send_joined")
              3.times { asm.asl }
              asm.clc
              asm.adc(starts)
              asm.sec
              asm.sbc(frame.call(SEND_START))
              asm.cmp(frame.call(SEND_BYTES))
              asm.bne("rt_paint_doubled_send_joined")
              asm.lda(rows.call(SEND_BOTTOM))
              asm.sec
              asm.sbc(rows.call(SEND_TOP))
              3.times { asm.asl }
              asm.clc
              asm.adc(frame.call(SEND_BYTES))
              asm.sta(frame.call(SEND_BYTES))
              asm.bra("rt_paint_doubled_send_join")
              asm.label("rt_paint_doubled_send_joined")
              asm.stx(frame.call(SEND_COLUMN))
              asm.lda(frame.call(SEND_BYTES)) # never nought: a run has rows
              asm.label("rt_paint_doubled_send_run_done")
              asm.rts

              asm.label("rt_paint_doubled_send_piece")
              asm.jsr(asm.abs("rt_blank_left"))
              asm.sec
              asm.sbc(PaintDoubled::PIECE_SETTING_UP)
              asm.bcc("rt_paint_doubled_send_no_room")
              asm.cmp(PaintDoubled::FEWEST_PIECE_BYTES)
              asm.bcc("rt_paint_doubled_send_no_room")
              asm.cmp(frame.call(SEND_BYTES))
              asm.bcc("rt_paint_doubled_send_room")
              asm.lda(frame.call(SEND_BYTES))
              asm.label("rt_paint_doubled_send_room")
              asm.sta(frame.call(SEND_PIECE))
              asm.sta(asm.abs(channel + h::DASL))
              asm.lda(frame.call(SEND_START))
              asm.sta(asm.abs(h::VMADDL))
              asm.clc
              asm.adc(copy & 0xFFFF)
              if behind
                asm.clc
                asm.adc(frame.call(SEND_FROM))
              end
              asm.sta(asm.abs(channel + h::A1TL))
              # The rest of the channel set for each piece, since the colours' copies and the sound's
              # between blanks use channel 0.
              asm.sep(0x20)
              asm.lda(0x80)
              asm.sta(asm.abs(h::VMAIN))
              asm.lda(copy >> 16)
              asm.sta(asm.abs(channel + h::A1B))
              asm.lda(h::DMA_TO_ONE_PORT)
              asm.sta(asm.abs(channel + h::DMAP))
              asm.lda(h::VMDATAH & 0xFF)
              asm.sta(asm.abs(channel + h::BBAD))
              asm.lda(1 << (behind ? BEHIND_CHANNEL : 0))
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
              asm.lda(frame.call(SEND_START))
              asm.clc
              asm.adc(frame.call(SEND_PIECE))
              asm.sta(frame.call(SEND_START))
              asm.lda(frame.call(SEND_BYTES))
              asm.sec
              asm.sbc(frame.call(SEND_PIECE))
              asm.sta(frame.call(SEND_BYTES))
              asm.brl("rt_paint_doubled_send_some")
              asm.label("rt_paint_doubled_send_none_left")
              asm.stx(frame.call(SEND_COLUMN))
              asm.lda(0)
              asm.rts
              asm.label("rt_paint_doubled_send_no_room")
              asm.lda(1)
              asm.rts
            end

            # rt_paint_doubled_swap (JSR, as a pass's copy has begun): the copy painted next is the
            # other. It is first brought up to this one where it was still behind (resting); this
            # one is behind it where it was not brought up this pass (stale), and it is behind this
            # one where this pass changed it (dirty), which is nothing now.
            def emit_swap(asm, memory, shown)
              at = ->(name) { asm.abs_x(memory[name]) }
              frame = ->(name) { asm.abs(memory[name]) }
              asm.label("rt_paint_doubled_swap")
              asm.ldx(0)
              asm.label("rt_paint_doubled_swap_column")
              asm.lda(at.call(RESTING_TOP))
              asm.cmp(at.call(RESTING_BOTTOM))
              asm.bcs("rt_paint_doubled_swap_kept_up")
              asm.sta(frame.call(ROWS_TOP))
              asm.lda(at.call(RESTING_BOTTOM))
              asm.sta(frame.call(ROWS_BOTTOM))
              asm.lda(frame.call(PAINT_OFFSET))
              asm.sta(frame.call(ROWS_FROM))
              asm.lda(shown.copy_bytes)
              asm.sec
              asm.sbc(frame.call(PAINT_OFFSET))
              asm.sta(frame.call(ROWS_TO))
              asm.jsr(asm.abs("rt_paint_doubled_copy_rows"))
              asm.label("rt_paint_doubled_swap_kept_up")
              [[STALE_TOP, RESTING_TOP], [STALE_BOTTOM, RESTING_BOTTOM],
               [PaintDoubled::DIRTY_TOP, STALE_TOP], [PaintDoubled::DIRTY_BOTTOM, STALE_BOTTOM]].each do |from, to|
                asm.lda(at.call(from))
                asm.sta(at.call(to))
              end
              asm.lda(PaintDoubled::HEIGHT)
              asm.sta(at.call(PaintDoubled::DIRTY_TOP))
              asm.stz(at.call(PaintDoubled::DIRTY_BOTTOM))
              asm.inx
              asm.inx
              asm.cpx(COLUMNS * 2)
              asm.bne("rt_paint_doubled_swap_column")
              asm.lda(shown.copy_bytes)
              asm.sec
              asm.sbc(frame.call(PAINT_OFFSET))
              asm.sta(frame.call(PAINT_OFFSET))
              emit_painted_starts(asm, memory, "rt_paint_doubled_swap")
              asm.rts
            end

            # rt_paint_doubled_behind (JSR, from the blank's interrupt): more of the picture being
            # sent, and once all of it is there, SHOWN set to its pass. Not while the game is at the end of
            # a pass (WAITING), copying in its own blank (UPLOADING) or stopping: it reads the line
            # the picture is on then, a latch and two reads that the interrupt's own reading would
            # spoil, and it sends what is left itself. The interrupt counts the frame after this,
            # so the frame it finished in is FRAMES + 1.
            def emit_interrupt_send(asm, memory)
              frame = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              asm.label("rt_paint_doubled_behind")
              asm.lda(frame.call(SENDING))
              asm.beq("rt_paint_doubled_behind_done")
              asm.lda(frame.call(UPLOADING))
              asm.ora(frame.call(Frame::WAITING))
              asm.ora(frame.call(Frame::STATE))
              asm.bne("rt_paint_doubled_behind_done")
              asm.jsr(asm.abs("rt_paint_doubled_send_some"))
              asm.bne("rt_paint_doubled_behind_done")
              asm.stz(frame.call(SENDING))
              emit_pass_shown(asm, memory, SEND_PASS)
              asm.inc(frame.call(DONE_FRAME))
              asm.label("rt_paint_doubled_behind_done")
              asm.rts
            end
          end
        end
      end
    end
  end
end
