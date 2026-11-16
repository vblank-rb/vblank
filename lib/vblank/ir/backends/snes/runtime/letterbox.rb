# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE SCREEN SWITCHED OFF ABOVE AND BELOW THE PICTURE, so that a painted screen on a Super
          # FX cartridge has longer to send what a pass painted.
          #
          # Video RAM takes writes only while the console is not drawing: in the vertical blank, 37
          # lines after the picture's 224, or on any line with the screen switched off (INIDISP's
          # top bit, "forced blank"). A line with the screen off is shown black. So where the top
          # and the bottom of a picture are black anyway, the screen can be off there, nobody sees
          # a difference, and those lines are the copying engine's as well. A first-person view 120
          # lines high in the middle of the screen leaves about a hundred such lines, nearly three
          # times the blank. The console's own Super FX games did exactly this: DOOM switches the
          # screen off 24 lines from the top and from the bottom and copies its view in the time
          # (docs/snes/super-fx-picture-to-screen.md has the sources).
          #
          # WHICH LINES. A row of tiles whose every cell shows the clear tile is the clear colour
          # throughout (Paint), and when that colour is black the row looks the same with the screen
          # off. The rows painted since the last clear are the rows a pass marked changed (Paint's
          # DIRTY), so as a pass ends the BAND is worked out from those: the picture's first row of
          # tiles with anything painted to its last. A pass that did not clear adds its rows to the
          # band it had. There is no band, and the whole screen stays on, unless the clear colour is
          # black, no fade or tint is in force and the camera is where it started: a tint would
          # colour the black, and a camera moves the rows.
          #
          # THE SCREEN SHOWS THE LAST PASS UNTIL THIS ONE HAS ARRIVED, so the lines kept on are the
          # last pass's band and this one's together. They change only in the vertical blank
          # (rt_letterbox_apply waits for it), because that is when the line table below may change.
          # A pass that changes them therefore starts its copy at the blank's interrupt and not
          # below the band, so a view whose top and bottom rows move every pass gains less than
          # one that paints the same rows each pass (a ceiling and a floor, or walls of one height).
          #
          # HOW THE SCREEN GOES OFF AND ON. The console can write a register by itself at the end of
          # chosen lines, from a table of how many lines to wait and what to write (HDMA, the copying
          # engine's line-by-line mode; fullsnes, "SNES DMA Transfers"). Channel 7 writes INIDISP:
          # off for the lines above the band, on for the band, off again below it. It needs no
          # interrupt and none of the processor's time, so it goes on while the Super FX owns the
          # cartridge. Each entry of the table takes effect on the line after the one it is written
          # at the end of, the first on line 1, which is the screen's first row.
          #
          # THE WINDOW is the lines with the screen off, from the line after the band's last round
          # through the blank to the line before its first. Blank's routines count the room left in
          # it (FIRST and LAST, read by Blank when a cartridge carries this). A pass's copy starts
          # as soon as a window is open whose interrupt is still to come (rt_letterbox_wait), which
          # is below the band, before the blank, and the pass's wait ends after that interrupt
          # (rt_letterbox_shown), so every pass still answers for a whole frame at least and the
          # frames a pass took are counted as on any cartridge.
          #
          #   rt_letterbox_rows     as a pass ends, before its rows are marked unchanged (JSR): the band wanted
          #   rt_letterbox_wait     before a pass's copy (JSR): the band put in force if it changed, or a window waited for
          #   rt_letterbox_apply    (JSR) the band wanted put in force, in the next blank
          #   rt_letterbox_shown    after the copy (JSR): the window's interrupt waited for
          #   rt_letterbox_now      (JSR) where the picture is: NOW_LINE, NOW_IN and NOW_WINDOW
          #   rt_letterbox_next     (JSR) the next window waited for; keeps X and Y
          module Letterbox
            # The band in force, as the console's lines: the first line shown and the last. The
            # screen's row y is the console's line y + 1 (Picture's scroll), so the whole screen is 1 to 224.
            FIRST = "rt letterbox first"
            LAST = "rt letterbox last"
            WHOLE_FIRST = 1
            WHOLE_LAST = Paint::HEIGHT
            # The band wanted once the pass at hand is prepared, the same way.
            WANT_FIRST = "rt letterbox want first"
            WANT_LAST = "rt letterbox want last"
            # The last pass's own rows of tiles, its first and one past its last (none: ROWS and 0),
            # whether its bars were black (VALID), and the same of the pass before it (OLD).
            OWN_FIRST = "rt letterbox own first"
            OWN_END = "rt letterbox own end"
            VALID = "rt letterbox valid"
            OLD_FIRST = "rt letterbox old first"
            OLD_END = "rt letterbox old end"
            # 1 once the pass at hand has cleared the whole screen.
            CLEARED = "rt letterbox cleared"
            # The line table HDMA reads: at most two entries above the band, two for it, one below
            # and the end, two bytes each.
            TABLE = "rt letterbox table"
            TABLE_BYTES = 12
            # Where the picture is (rt_letterbox_now): the line, 1 if the screen is off there, and
            # the number of the window that line is in or was last in, which is the count of frames
            # as its blank's interrupt leaves it.
            NOW_LINE = "rt letterbox now line"
            NOW_IN = "rt letterbox now in"
            NOW_WINDOW = "rt letterbox now window"
            # The count of frames as this pass's wait began, and the window its copy ended in.
            ENTRY_WINDOW = "rt letterbox entry window"
            END_WINDOW = "rt letterbox end window"

            # An entry of the line table holds for 127 lines at most (its top bit means another thing).
            MOST_LINES_AN_ENTRY = 127
            # The copying engine's channel for the line table. Paint's copies use channel 0.
            CHANNEL = 7
            # The lines left alone after the screen goes off below the band, before video RAM is
            # written. fullsnes says of INIDISP that forced blank "doesn't apply immediately", and
            # asks whether a scanline has to pass before video RAM takes writes; nothing read settles
            # it for a real console, so the first line is not used.
            SETTLING_LINES = 1
            # How many lines into a window a piece too big for what is left still goes at once,
            # as no window has more (Blank's rt_blank_room).
            WINDOW_JUST_OPEN_LINES = 4

            WORDS = [FIRST, LAST, WANT_FIRST, WANT_LAST, OWN_FIRST, OWN_END, VALID, OLD_FIRST, OLD_END, CLEARED,
                     NOW_LINE, NOW_IN, NOW_WINDOW, ENTRY_WINDOW, END_WINDOW].freeze
            # The words a band the game named keeps (#emit_named_band): where it is and where the
            # picture is, and none of the rows painted.
            NAMED_BAND_WORDS = [FIRST, LAST, NOW_LINE, NOW_IN, NOW_WINDOW, ENTRY_WINDOW, END_WINDOW].freeze

            module_function

            # +band+ is the console's first and last line of a band the game named, or nil for one
            # worked out from the rows painted.
            def reserve(memory, band: nil)
              (band ? NAMED_BAND_WORDS : WORDS).each { |name| memory.reserve(name, 2) }
              memory.reserve(TABLE, TABLE_BYTES)
            end

            def kept?(memory) = memory.reserved?(FIRST)

            # Whether the band is worked out from the rows each pass paints, rather than named by the game.
            def follows_rows?(memory) = memory.reserved?(OWN_FIRST)

            # Whether the band is the one the game named (`screen :bitmap, shown_rows:`).
            def named_band?(memory) = kept?(memory) && !follows_rows?(memory)

            # The console's first and last line of the band +program+ names (Program#shown_rows), or
            # nil for one that names none. The screen's row y is the console's line y + 1. A game of
            # big pixels names rows of its small picture, each that many of the console's lines.
            def band_of(program)
              first, past = program.shown_rows
              size = program.pixel_size || 1
              first && [(first * size) + 1, past * size]
            end

            # At power-on (in rt_paint_start, A 16 bits wide): the whole screen on, and no rows painted.
            def emit_start(asm, memory)
              asm.lda(WHOLE_FIRST)
              asm.sta(asm.abs(memory[FIRST]))
              asm.lda(WHOLE_LAST)
              asm.sta(asm.abs(memory[LAST]))
              return unless follows_rows?(memory)

              asm.lda(Paint::ROWS)
              asm.sta(asm.abs(memory[OWN_FIRST]))
            end

            # A BAND THE GAME NAMED (`screen :bitmap, shown_rows:`): the same switching off and the
            # same window as above, on lines that never change, so the line table is known when the
            # game is built and nothing is worked out from the rows painted. +band+ is the console's
            # first and last line shown. It goes in force as the first pass is shown
            # (rt_letterbox_show_band, from Frame's rt_show_pass), and stays.
            #
            # A FADE TO BLACK IS THE DISPLAY'S BRIGHTNESS, the low bits of INIDISP, the register the
            # table writes: the band's entries write the brightness in force, so the fade reaches the
            # lines shown. With +dims+ it is Tint's (rt_letterbox_brightness, from Tint.emit_brightness),
            # which never writes INIDISP itself here: the screen would come on below the band, where
            # the copy is writing video RAM.
            #
            #   rt_letterbox_show_band   in the blank, as the first pass is shown (JSR): the band in force
            #   rt_letterbox_brightness  (JSR) A's low byte the brightness the band is shown at
            def emit_named_band(asm, memory, band, dims:)
              emit_show_band(asm, memory, band, dims)
              emit_band_brightness(asm, memory, band)
              emit_now(asm, memory)
              emit_waits(asm, memory, named: true)
            end

            # The line table for +band+, as [lines, value] entries: off above it, on for it (:band,
            # the brightness in force), off for a line below it, which holds to the end of the frame.
            def named_table(band)
              h = Console::SNESHardware
              first, last = band
              entries = lines_in_entries(first - 1, h::FORCED_BLANK) + lines_in_entries(last - first + 1, :band)
              entries + [[1, h::FORCED_BLANK]]
            end

            # +lines+ (none or more) of +value+ as entries of the table, MOST_LINES_AN_ENTRY at most each.
            def lines_in_entries(lines, value)
              Array.new((lines + MOST_LINES_AN_ENTRY - 1) / MOST_LINES_AN_ENTRY) do |at|
                [[lines - (at * MOST_LINES_AN_ENTRY), MOST_LINES_AN_ENTRY].min, value]
              end
            end

            def emit_show_band(asm, memory, band, dims)
              h = Console::SNESHardware
              table = memory[TABLE]
              channel = h::DMA_BASE + (CHANNEL << 4)
              asm.label("rt_letterbox_show_band")
              asm.lda(band[0])
              asm.sta(asm.abs(memory[FIRST]))
              asm.lda(band[1])
              asm.sta(asm.abs(memory[LAST]))
              entries = named_table(band)
              entries.each_with_index do |(lines, value), at|
                asm.lda(lines | ((value == :band ? h::FULL_BRIGHTNESS : value) << 8))
                asm.sta(asm.abs(table + (at * 2)))
              end
              asm.stz(asm.abs(table + (entries.length * 2)))
              asm.lda(h::FULL_BRIGHTNESS)
              if dims
                asm.sec
                asm.sbc(asm.abs(memory[Tint::DIMMED]))
              end
              asm.jsr(asm.abs("rt_letterbox_brightness"))
              # The channel: one byte a line to INIDISP, from the table. The screen goes off now, in
              # the blank, and the table puts it on for the band from the frame's first line.
              asm.lda(table)
              asm.sta(asm.abs(channel + h::A1TL))
              asm.sep(0x20)
              asm.stz(asm.abs(channel + h::DMAP))
              asm.lda(h::INIDISP & 0xFF)
              asm.sta(asm.abs(channel + h::BBAD))
              asm.stz(asm.abs(channel + h::A1B))
              asm.lda(h::FORCED_BLANK)
              asm.sta(asm.abs(h::INIDISP))
              asm.lda(1 << CHANNEL)
              asm.sta(asm.abs(h::HDMAEN))
              asm.rep(0x20)
              asm.rts
            end

            # rt_letterbox_brightness: A's low byte into each entry of the band, which the table
            # writes to INIDISP from the next frame on. A is kept.
            def emit_band_brightness(asm, memory, band)
              table = memory[TABLE]
              asm.label("rt_letterbox_brightness")
              asm.sep(0x20)
              named_table(band).each_with_index do |(_, value), at|
                asm.sta(asm.abs(table + (at * 2) + 1)) if value == :band
              end
              asm.rep(0x20)
              asm.rts
            end

            # Where a pass clears the whole screen (A 16 bits wide; A is not kept).
            def emit_cleared(asm, memory)
              asm.lda(1)
              asm.sta(asm.abs(memory[CLEARED]))
            end

            # +black_places+ is the places of the colour memory that hold black.
            def emit(asm, memory, black_places:)
              emit_rows(asm, memory, black_places)
              emit_apply(asm, memory)
              emit_now(asm, memory)
              emit_waits(asm, memory)
            end

            # rt_letterbox_rows: the pass's rows from DIRTY, its own band, whether its bars are
            # black, and the band wanted: the last pass's and this one's together, or the whole screen.
            def emit_rows(asm, memory, black_places)
              at = ->(name) { asm.abs(memory[name]) }
              dirty = memory[Paint::DIRTY]
              asm.label("rt_letterbox_rows")
              asm.lda(at.call(OWN_FIRST))
              asm.sta(at.call(OLD_FIRST))
              asm.lda(at.call(OWN_END))
              asm.sta(at.call(OLD_END))
              asm.lda(at.call(CLEARED))
              asm.beq("rt_letterbox_rows_added")
              asm.stz(at.call(CLEARED))
              asm.lda(Paint::ROWS)
              asm.sta(at.call(OWN_FIRST))
              asm.stz(at.call(OWN_END))
              asm.label("rt_letterbox_rows_added")
              asm.ldx(0)
              asm.ldy(0)
              asm.label("rt_letterbox_row")
              asm.lda(asm.abs_x(dirty + 2))
              asm.cmp(asm.abs_x(dirty))
              asm.bcc("rt_letterbox_row_none")
              asm.tya
              asm.cmp(at.call(OWN_FIRST))
              asm.bcs("rt_letterbox_row_first_kept")
              asm.sta(at.call(OWN_FIRST))
              asm.label("rt_letterbox_row_first_kept")
              asm.inc
              asm.cmp(at.call(OWN_END))
              asm.bcc("rt_letterbox_row_none")
              asm.sta(at.call(OWN_END))
              asm.label("rt_letterbox_row_none")
              4.times { asm.inx }
              asm.iny
              asm.cpy(Paint::ROWS)
              asm.bne("rt_letterbox_row")

              # Whether this pass's bars are black, in Y, and the last pass's in X.
              asm.ldx(at.call(VALID))
              asm.ldy(0)
              asm.lda(at.call(Frame::DISPLAY_ON))
              asm.beq("rt_letterbox_valid_known")
              asm.lda(asm.abs(memory[Tint::STATE] + Tint::STEPS_AT))
              asm.bne("rt_letterbox_valid_known")
              camera = memory[Paint::CAMERA]
              asm.lda(asm.abs(camera + Paint::CAMERA_X))
              asm.ora(asm.abs(camera + Paint::CAMERA_X + 2))
              asm.ora(asm.abs(camera + Paint::CAMERA_Y))
              asm.ora(asm.abs(camera + Paint::CAMERA_Y + 2))
              asm.bne("rt_letterbox_valid_known")
              asm.lda(at.call(Paint::CLEAR_PLACE))
              black_places.each do |place|
                asm.cmp(place)
                asm.beq("rt_letterbox_black")
              end
              asm.bra("rt_letterbox_valid_known")
              asm.label("rt_letterbox_black")
              asm.iny
              asm.label("rt_letterbox_valid_known")
              asm.sty(at.call(VALID))

              # The band wanted: the whole screen unless both passes' bars are black and the two
              # bands together have a row.
              asm.tya
              asm.beq("rt_letterbox_want_whole")
              asm.txa
              asm.beq("rt_letterbox_want_whole")
              asm.lda(at.call(OWN_FIRST))
              asm.cmp(at.call(OLD_FIRST))
              asm.bcc("rt_letterbox_want_first")
              asm.lda(at.call(OLD_FIRST))
              asm.label("rt_letterbox_want_first")
              asm.tax
              asm.lda(at.call(OWN_END))
              asm.cmp(at.call(OLD_END))
              asm.bcs("rt_letterbox_want_end")
              asm.lda(at.call(OLD_END))
              asm.label("rt_letterbox_want_end")
              asm.tay
              asm.stx(at.call(WANT_FIRST))
              asm.cmp(at.call(WANT_FIRST)) # the end against the first
              asm.bcc("rt_letterbox_want_whole")
              asm.beq("rt_letterbox_want_whole")
              # Rows of tiles to the console's lines: a row's first line is its number times 8 and 1.
              asm.txa
              3.times { asm.asl }
              asm.inc
              asm.sta(at.call(WANT_FIRST))
              asm.tya
              3.times { asm.asl }
              asm.sta(at.call(WANT_LAST))
              asm.rts
              asm.label("rt_letterbox_want_whole")
              asm.lda(WHOLE_FIRST)
              asm.sta(at.call(WANT_FIRST))
              asm.lda(WHOLE_LAST)
              asm.sta(at.call(WANT_LAST))
              asm.rts
            end

            # rt_letterbox_apply: the band wanted put in force if it is not the one in force. The
            # next blank is waited for first. The whole screen needs no table: the line-by-line copy
            # is switched off and the screen left on.
            def emit_apply(asm, memory)
              h = Console::SNESHardware
              at = ->(name) { asm.abs(memory[name]) }
              channel = h::DMA_BASE + (CHANNEL << 4)
              table = memory[TABLE]
              asm.label("rt_letterbox_apply")
              asm.jsr(asm.abs("rt_sleep_until_vblank"))
              asm.lda(at.call(WANT_FIRST))
              asm.sta(at.call(FIRST))
              asm.lda(at.call(WANT_LAST))
              asm.sta(at.call(LAST))
              asm.sep(0x20)
              asm.stz(asm.abs(h::HDMAEN))
              asm.rep(0x20)
              asm.lda(at.call(FIRST))
              asm.cmp(WHOLE_FIRST)
              asm.bne("rt_letterbox_apply_bars")
              asm.lda(at.call(LAST))
              asm.cmp(WHOLE_LAST)
              asm.bne("rt_letterbox_apply_bars")
              asm.sep(0x20)
              asm.lda(h::FULL_BRIGHTNESS)
              asm.sta(asm.abs(h::INIDISP))
              asm.rep(0x20)
              asm.rts

              # The table: off for the lines above the band, on for the band's, off after.
              asm.label("rt_letterbox_apply_bars")
              asm.ldx(0)
              asm.lda(at.call(FIRST))
              asm.dec
              asm.beq("rt_letterbox_apply_band")
              emit_entries(asm, table, h::FORCED_BLANK, "rt_letterbox_apply_above")
              asm.label("rt_letterbox_apply_band")
              asm.lda(at.call(LAST))
              asm.sec
              asm.sbc(at.call(FIRST))
              asm.inc
              emit_entries(asm, table, h::FULL_BRIGHTNESS, "rt_letterbox_apply_shown")
              asm.lda(1 | (h::FORCED_BLANK << 8))
              asm.sta(asm.abs_x(table))
              asm.stz(asm.abs_x(table + 2))
              # The channel: one byte a line to INIDISP, from the table. The screen goes off now,
              # in the blank, so the lines before the table's first write are the window's too.
              asm.lda(table)
              asm.sta(asm.abs(channel + h::A1TL))
              asm.sep(0x20)
              asm.stz(asm.abs(channel + h::DMAP))
              asm.lda(h::INIDISP & 0xFF)
              asm.sta(asm.abs(channel + h::BBAD))
              asm.stz(asm.abs(channel + h::A1B))
              asm.lda(h::FORCED_BLANK)
              asm.sta(asm.abs(h::INIDISP))
              asm.lda(1 << CHANNEL)
              asm.sta(asm.abs(h::HDMAEN))
              asm.rep(0x20)
              asm.rts
            end

            # Entries of the table from X on that write +value+ for the A lines (one or more), as
            # many entries as that takes; X on past them.
            def emit_entries(asm, table, value, prefix)
              asm.label("#{prefix}_entry")
              asm.cmp(MOST_LINES_AN_ENTRY + 1)
              asm.bcc("#{prefix}_last")
              asm.pha
              asm.lda(MOST_LINES_AN_ENTRY | (value << 8))
              asm.sta(asm.abs_x(table))
              asm.inx
              asm.inx
              asm.pla
              asm.sec
              asm.sbc(MOST_LINES_AN_ENTRY)
              asm.bra("#{prefix}_entry")
              asm.label("#{prefix}_last")
              asm.ora(value << 8)
              asm.sta(asm.abs_x(table))
              asm.inx
              asm.inx
            end

            # rt_letterbox_now: the line the picture is on, whether the screen is off there, and
            # the window's number. The frames are read before the line and again after, so the
            # blank's interrupt cannot come between the two unseen. The line before the band's
            # first is not counted as the window's: the screen comes on at its end.
            def emit_now(asm, memory)
              at = ->(name) { asm.abs(memory[name]) }
              asm.label("rt_letterbox_now")
              asm.lda(at.call(Frame::FRAMES))
              asm.sta(at.call(NOW_WINDOW))
              Blank.emit_line_now(asm)
              asm.sta(at.call(NOW_LINE))
              asm.lda(at.call(Frame::FRAMES))
              asm.cmp(at.call(NOW_WINDOW))
              asm.bne("rt_letterbox_now")
              asm.stz(at.call(NOW_IN))
              asm.lda(at.call(NOW_LINE))
              asm.inc
              asm.cmp(at.call(FIRST))
              asm.bcc("rt_letterbox_now_in") # above the band
              asm.dec
              asm.beq("rt_letterbox_now_known") # line 0 with the whole screen on
              asm.sec
              asm.sbc(SETTLING_LINES)
              asm.cmp(at.call(LAST))
              asm.bcc("rt_letterbox_now_known")
              asm.beq("rt_letterbox_now_known")
              asm.lda(at.call(NOW_LINE))
              asm.cmp(Blank::FIRST_BLANK_LINE)
              asm.bcs("rt_letterbox_now_in")
              asm.inc(at.call(NOW_WINDOW)) # below the band, before the blank's interrupt has counted it
              asm.label("rt_letterbox_now_in")
              asm.inc(at.call(NOW_IN))
              asm.label("rt_letterbox_now_known")
              asm.rts
            end

            # +named+ for a band the game named, which never changes, so nothing is put in force here.
            def emit_waits(asm, memory, named: false)
              at = ->(name) { asm.abs(memory[name]) }
              return emit_window_waits(asm, memory, at) if named
              # A band that is not the one in force is put in force first, in the next blank, and
              # the copy starts there. Otherwise the copy starts in a window whose interrupt had
              # not come as the wait began: the one opening below the band, or the next one if the
              # pass ended in a window after its interrupt. So a pass's wait always has a blank's
              # interrupt in it, as it has on any other cartridge, no pass is shorter than a frame,
              # and whatever reads a run frame by frame finds every pass waiting. The numbers
              # come round, so they are compared by their difference.
              asm.label("rt_letterbox_wait")
              asm.lda(at.call(WANT_FIRST))
              asm.cmp(at.call(FIRST))
              asm.bne("rt_letterbox_wait_changed")
              asm.lda(at.call(WANT_LAST))
              asm.cmp(at.call(LAST))
              asm.beq("rt_letterbox_wait_same")
              asm.label("rt_letterbox_wait_changed")
              asm.jmp(asm.abs("rt_letterbox_apply"))
              asm.label("rt_letterbox_wait_same")
              emit_window_waits(asm, memory, at)
            end

            # rt_letterbox_wait's wait for a window, then rt_letterbox_shown and rt_letterbox_next.
            def emit_window_waits(asm, memory, at)
              asm.label("rt_letterbox_wait") unless follows_rows?(memory)
              asm.lda(at.call(Frame::FRAMES))
              asm.sta(at.call(ENTRY_WINDOW))
              asm.label("rt_letterbox_wait_window")
              emit_idle(asm, memory)
              asm.jsr(asm.abs("rt_letterbox_now"))
              asm.lda(at.call(NOW_IN))
              asm.beq("rt_letterbox_wait_window")
              asm.lda(at.call(NOW_WINDOW))
              asm.sec
              asm.sbc(at.call(ENTRY_WINDOW))
              asm.beq("rt_letterbox_wait_window")
              asm.bmi("rt_letterbox_wait_window")
              asm.rts

              # The interrupt of the window the copy ended in waited for, if it has not come: a copy
              # that ends below the band has changed nothing the frame being drawn shows, and the
              # pass is on the screen from the frame after.
              asm.label("rt_letterbox_shown")
              asm.jsr(asm.abs("rt_letterbox_now"))
              asm.lda(at.call(NOW_WINDOW))
              asm.sta(at.call(END_WINDOW))
              asm.label("rt_letterbox_shown_wait")
              asm.lda(at.call(Frame::FRAMES))
              asm.sec
              asm.sbc(at.call(END_WINDOW))
              asm.bpl("rt_letterbox_shown_counted")
              asm.jsr(asm.abs("rt_sleep_until_vblank"))
              asm.bra("rt_letterbox_shown_wait")
              # A pass is never marked shown in the blank's first lines, where a copy that waits
              # for the interrupt on any other cartridge has not started yet: whatever reads a run
              # frame by frame reads it there, and finds each pass shown a whole frame.
              asm.label("rt_letterbox_shown_counted")
              asm.jsr(asm.abs("rt_letterbox_now"))
              asm.lda(at.call(NOW_LINE))
              asm.cmp(Blank::FIRST_BLANK_LINE)
              asm.bcc("rt_letterbox_shown_late")
              asm.cmp(Blank::COPY_START_LINE + 1)
              asm.bcc("rt_letterbox_shown_counted")
              asm.label("rt_letterbox_shown_late")
              asm.rts

              asm.label("rt_letterbox_next")
              asm.phx
              asm.phy
              asm.label("rt_letterbox_next_leave")
              emit_idle(asm, memory)
              asm.jsr(asm.abs("rt_letterbox_now"))
              asm.lda(at.call(NOW_IN))
              asm.bne("rt_letterbox_next_leave")
              asm.label("rt_letterbox_next_open")
              emit_idle(asm, memory)
              asm.jsr(asm.abs("rt_letterbox_now"))
              asm.lda(at.call(NOW_IN))
              asm.beq("rt_letterbox_next_open")
              asm.ply
              asm.plx
              asm.rts
            end

            # What a wait does between two looks at the line: a game with a queue of sound sends
            # some of it. A game without one only looks again, since sleeping until an interrupt
            # would sleep through the window's first lines.
            def emit_idle(asm, memory)
              Sound.emit_idle_step(asm, memory) if memory.reserved?(Sound::QUEUE)
            end
          end
        end
      end
    end
  end
end
