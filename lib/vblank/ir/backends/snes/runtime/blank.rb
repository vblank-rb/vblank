# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE ROOM IN A BLANK, for copying to video RAM with the screen on.
          #
          # Video RAM, the colour memory and the sprite table can only be written in the vertical
          # blank or with the screen switched off; written while the picture is being drawn, the
          # writes are lost (fullsnes, "SNES PPU Video Memory"). Switching the screen off for a big
          # change shows a black frame. So what a pass changed is copied with the screen on, a piece
          # at a time, each piece only when the line the picture is on shows it can be sent before the
          # blank ends, and only while the blank has room for it: a change bigger than one blank
          # holds arrives over several, and the pass counts as shown once it is all there.
          #
          # A blank is 37 of the console's lines, 225 to 261, each 1364 of its master clock's
          # cycles, and the copying engine takes 8 of those cycles a byte and stops for 40 of them a
          # line while the console refreshes its work RAM (fullsnes, "SNES Timing" and "SNES DMA"):
          # BYTES_A_LINE. Video RAM takes writes until close to the end of line 261, so a copy
          # started on line L has the rest of that line and every line after it up to 261. The room
          # is counted as the whole lines after L alone, less EDGE_BYTES for the end of 261 and the
          # few cycles of setting the copy going: the part of line L left is never counted, so a
          # copy that starts at the very end of its line still ends inside the blank.
          #
          # What decides whether a piece goes is the line the picture is on, read as it is asked, so
          # the interrupt's time and the setting up so far are already counted. BLANK_BYTES is what a
          # blank holds counted from where its copying starts, a few lines in, once the interrupt has
          # read the controller: the whole lines from there, the rest of that line standing for the
          # edge. A piece that big goes in a blank of its own: rt_blank_room sends a piece it finds
          # no room for at once if the blank's copying has only just started, as no blank has more,
          # and else waits for the next. With the screen still off, before the first pass is shown,
          # there is always room.
          #
          #   rt_blank_room   before a piece (JSR): A is its bytes; returns once there is room for
          #                   it and AFTER_PIECE_LINES more, for the writes that follow it
          #   rt_blank_room_with_registers (JSR): the same, AFTER_LUMP_LINES more
          #   rt_blank_time   before a write that is not a copy (JSR): returns once the blank has a
          #                   line left for it
          #   rt_blank_time_for_cells (JSR): the same, for CELLS_A_LOOK cells of a map
          #   rt_blank_left   (JSR) A = the bytes this blank still has time for, 0 for none, so a
          #                   run of pieces can be sent together
          #   rt_blank_next   (JSR): the next blank waited for
          module Blank
            # What the copying engine moves in one of the console's lines, measured in bsnes with
            # the screen on: 1364 cycles, less 40 of refresh, at 8 a byte.
            BYTES_A_LINE = 165
            # What a blank is short of its whole lines at its end, and the setting going of a copy,
            # counted as bytes: a copy started on line 225 lands a little under 37 lines' worth, and
            # on a Super FX cartridge a run of pieces needs a line more than that to stay inside.
            EDGE_BYTES = 200
            # The lines of a North American frame, 0 to 261; the blank is 225 to 261.
            LINES = 262
            FIRST_BLANK_LINE = 225
            LAST_BLANK_LINE = LINES - 1
            # The line a blank's copying starts on: the interrupt has read the controller and the
            # pass's wait has ended.
            COPY_START_LINE = 228
            # How many cells of a map go on one look at the line, and the lines left that asks for:
            # a cell is about fifty of the processor's cycles and a line about 190, so eight take
            # about two lines, and one more is kept for the look itself.
            CELLS_A_LOOK = 8
            LINES_FOR_CELLS = 4
            # The lines rt_blank_room keeps after a piece for the few writes that follow it without
            # asking, and rt_blank_room_with_registers for a tiled screen's lump of the sprite table
            # and the colours, which each layer's registers, its scroll, and a bar's and a bend's
            # tables follow.
            AFTER_PIECE_LINES = 1
            AFTER_LUMP_LINES = 3
            BLANK_BYTES = (LAST_BLANK_LINE - COPY_START_LINE) * BYTES_A_LINE

            # The direct page it works on: the piece's bytes, the room the blank has left, and the
            # lines it has left.
            Scratch = Data.define(:wanted, :room, :line)

            module_function

            def scratch(memory) = Scratch.new(wanted: memory.scratch(2), room: memory.scratch(2), line: memory.scratch(2))

            # Each routine keeps X and Y; A is not kept. A cartridge that switches the screen off
            # above and below its picture (Letterbox) has the same routines counting those lines too.
            def emit(asm, memory, s)
              return emit_for_window(asm, memory, s) if Letterbox.kept?(memory)

              asm.label("rt_blank_room_with_registers")
              asm.clc
              asm.adc((AFTER_LUMP_LINES - AFTER_PIECE_LINES) * BYTES_A_LINE)
              asm.label("rt_blank_room")
              asm.sta(asm.direct(s.wanted))
              asm.lda(asm.abs(memory[Frame::DISPLAY_ON]))
              asm.beq("rt_blank_room_there")
              asm.jsr(asm.abs("rt_blank_left_on"))
              asm.sta(asm.direct(s.room))
              asm.lda(asm.direct(s.wanted))
              asm.clc
              asm.adc(AFTER_PIECE_LINES * BYTES_A_LINE)
              asm.cmp(asm.direct(s.room))
              asm.bcc("rt_blank_room_there")
              asm.beq("rt_blank_room_there")
              # Short of room as the blank's copying starts, no blank has more: it goes now.
              emit_line_now(asm)
              asm.cmp(FIRST_BLANK_LINE)
              asm.bcc("rt_blank_room_wait")
              asm.cmp(COPY_START_LINE + 1)
              asm.bcc("rt_blank_room_there")
              asm.label("rt_blank_room_wait")
              emit_next_blank(asm)
              asm.label("rt_blank_room_there")
              asm.rts

              # A single write takes far less than a line, so a line left before the blank ends is
              # time enough for it.
              asm.label("rt_blank_time")
              asm.lda(asm.abs(memory[Frame::DISPLAY_ON]))
              asm.beq("rt_blank_time_there")
              emit_line_now(asm)
              asm.cmp(FIRST_BLANK_LINE)
              asm.bcc("rt_blank_time_wait")
              asm.cmp(LINES - 1)
              asm.bcc("rt_blank_time_there")
              asm.label("rt_blank_time_wait")
              emit_next_blank(asm)
              asm.label("rt_blank_time_there")
              asm.rts

              # The same, for CELLS_A_LOOK cells of a map, written one after another.
              asm.label("rt_blank_time_for_cells")
              asm.lda(asm.abs(memory[Frame::DISPLAY_ON]))
              asm.beq("rt_blank_cells_there")
              emit_line_now(asm)
              asm.cmp(FIRST_BLANK_LINE)
              asm.bcc("rt_blank_cells_wait")
              asm.cmp(LINES - LINES_FOR_CELLS)
              asm.bcc("rt_blank_cells_there")
              asm.label("rt_blank_cells_wait")
              emit_next_blank(asm)
              asm.label("rt_blank_cells_there")
              asm.rts

              # The whole lines after this one up to the blank's last, BYTES_A_LINE each, less
              # EDGE_BYTES. With the screen off there is no blank to fit in, and a blank's worth is
              # what a piece is cut to.
              asm.label("rt_blank_left")
              asm.lda(asm.abs(memory[Frame::DISPLAY_ON]))
              asm.bne("rt_blank_left_on")
              asm.lda(BLANK_BYTES)
              asm.rts
              asm.label("rt_blank_left_on")
              emit_line_now(asm)
              asm.cmp(FIRST_BLANK_LINE)
              asm.bcc("rt_blank_left_none")
              asm.eor(0xFFFF)
              asm.sec
              asm.adc(LAST_BLANK_LINE) # the whole lines left
              asm.bmi("rt_blank_left_none")
              asm.beq("rt_blank_left_none")
              asm.sta(asm.direct(s.line))
              # × 165: × 128, + × 32, + × 4, + × 1. Fewer than 37 lines, so it never carries.
              7.times { asm.asl }
              asm.sta(asm.direct(s.room))
              asm.lda(asm.direct(s.line))
              5.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.room))
              asm.sta(asm.direct(s.room))
              asm.lda(asm.direct(s.line))
              2.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.line))
              asm.clc
              asm.adc(asm.direct(s.room))
              asm.sec
              asm.sbc(EDGE_BYTES)
              asm.bcc("rt_blank_left_none")
              asm.rts
              asm.label("rt_blank_left_none")
              asm.lda(0)
              asm.rts

              asm.label("rt_blank_next")
              emit_next_blank(asm)
              asm.rts
            end

            # THE SAME ROUTINES WHERE THE SCREEN IS OFF ABOVE AND BELOW THE PICTURE (Letterbox). The
            # time for copying is then the WINDOW: from the line after the last one shown (LAST),
            # round through the blank, to the line before the first one shown (FIRST). With the
            # whole screen on, FIRST is 1 and LAST 224, and every count here comes to what the
            # routines above count. The line just before FIRST is never counted: the screen comes
            # back on at its end.
            def emit_for_window(asm, memory, s)
              first = asm.abs(memory[Letterbox::FIRST])
              last = asm.abs(memory[Letterbox::LAST])
              display_on = asm.abs(memory[Frame::DISPLAY_ON])

              asm.label("rt_blank_room_with_registers")
              asm.clc
              asm.adc((AFTER_LUMP_LINES - AFTER_PIECE_LINES) * BYTES_A_LINE)
              asm.label("rt_blank_room")
              asm.sta(asm.direct(s.wanted))
              asm.lda(display_on)
              asm.beq("rt_blank_room_there")
              asm.jsr(asm.abs("rt_blank_left_on"))
              asm.sta(asm.direct(s.room))
              asm.lda(asm.direct(s.wanted))
              asm.clc
              asm.adc(AFTER_PIECE_LINES * BYTES_A_LINE)
              asm.cmp(asm.direct(s.room))
              asm.bcc("rt_blank_room_there")
              asm.beq("rt_blank_room_there")
              # Short of room as the window opens, no window has more: it goes now.
              emit_line_now(asm)
              asm.cmp(last)
              asm.bcc("rt_blank_room_wait")
              asm.beq("rt_blank_room_wait")
              asm.sbc(last) # the carry is set: the lines since the window opened
              asm.cmp(Letterbox::WINDOW_JUST_OPEN_LINES + 1)
              asm.bcc("rt_blank_room_there")
              asm.label("rt_blank_room_wait")
              asm.jsr(asm.abs("rt_letterbox_next"))
              asm.label("rt_blank_room_there")
              asm.rts

              [["rt_blank_time", 1], ["rt_blank_time_for_cells", LINES_FOR_CELLS]].each do |routine, lines|
                asm.label(routine)
                asm.lda(display_on)
                asm.beq("#{routine}_there")
                asm.jsr(asm.abs("rt_blank_lines"))
                asm.bmi("#{routine}_wait")
                asm.cmp(lines)
                asm.bcs("#{routine}_there")
                asm.label("#{routine}_wait")
                asm.jsr(asm.abs("rt_letterbox_next"))
                asm.label("#{routine}_there")
                asm.rts
              end

              # rt_blank_lines (JSR): A = the whole lines of the window after the line the picture is
              # on, nought or less when there are none. Below the band they are the rest of the frame
              # and the lines above the band; above it, the lines to the one before FIRST.
              asm.label("rt_blank_lines")
              emit_line_now(asm)
              asm.cmp(last)
              asm.bcc("rt_blank_lines_above")
              asm.beq("rt_blank_lines_above")
              # Before the blank, its interrupt is still to come and takes its lines out of the
              # window while a copy waits: they are counted as gone already. It reads a controller
              # by hand, which is most of its time, and a game that reads two reads two.
              asm.cmp(FIRST_BLANK_LINE)
              asm.bcs("rt_blank_lines_interrupt_counted")
              interrupt_lines = COPY_START_LINE - FIRST_BLANK_LINE + 1
              asm.adc(memory.reserved?(Frame::SECOND_HELD) ? interrupt_lines * 2 : interrupt_lines) # the carry is clear
              asm.label("rt_blank_lines_interrupt_counted")
              asm.eor(0xFFFF)
              asm.sec
              asm.adc(LAST_BLANK_LINE - 1)
              asm.clc
              asm.adc(first)
              asm.rts
              asm.label("rt_blank_lines_above")
              asm.eor(0xFFFF)
              asm.sec
              asm.adc(first)
              asm.sec
              asm.sbc(2)
              asm.rts

              asm.label("rt_blank_left")
              asm.lda(display_on)
              asm.bne("rt_blank_left_on")
              asm.lda(BLANK_BYTES)
              asm.rts
              asm.label("rt_blank_left_on")
              asm.jsr(asm.abs("rt_blank_lines"))
              asm.bmi("rt_blank_left_none")
              asm.beq("rt_blank_left_none")
              asm.cmp(MOST_LINES_COUNTED + 1)
              asm.bcc("rt_blank_left_lines")
              asm.lda(MOST_LINES_COUNTED)
              asm.label("rt_blank_left_lines")
              asm.sta(asm.direct(s.line))
              emit_lines_as_bytes(asm, s)
              asm.sec
              asm.sbc(EDGE_BYTES)
              asm.bcc("rt_blank_left_none")
              asm.rts
              asm.label("rt_blank_left_none")
              asm.lda(0)
              asm.rts

              asm.label("rt_blank_next")
              asm.jsr(asm.abs("rt_letterbox_next"))
              asm.rts
            end

            # The most lines of a window counted as room at once, so the bytes they hold stay a
            # number that reads the same signed or not.
            MOST_LINES_COUNTED = 190

            # A = the lines at +line+ × BYTES_A_LINE: × 128, + × 32, + × 4, + × 1.
            def emit_lines_as_bytes(asm, s)
              7.times { asm.asl }
              asm.sta(asm.direct(s.room))
              asm.lda(asm.direct(s.line))
              5.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.room))
              asm.sta(asm.direct(s.room))
              asm.lda(asm.direct(s.line))
              2.times { asm.asl }
              asm.clc
              asm.adc(asm.direct(s.line))
              asm.clc
              asm.adc(asm.direct(s.room))
            end

            # The next blank waited for; X and Y kept.
            def emit_next_blank(asm)
              asm.phx
              asm.phy
              asm.jsr(asm.abs("rt_sleep_until_vblank"))
              asm.ply
              asm.plx
            end

            # A = the line the picture is on now (OPVCT, nine bits), latched by reading SLHV, which
            # latches only while WRIO's top bit is set (rt_picture_start sets it). STAT78 is read
            # first so OPVCT gives its low byte, then its ninth bit. (fullsnes, "SNES PPU Timers and
            # Status".) Leaves A 16 bits wide.
            def emit_line_now(asm)
              h = Console::SNESHardware
              asm.sep(0x20)
              asm.lda(asm.abs(h::STAT78))
              asm.lda(asm.abs(h::SLHV))
              asm.lda(asm.abs(h::OPVCT))
              asm.xba
              asm.lda(asm.abs(h::OPVCT))
              asm.and_a(0x01)
              asm.xba
              asm.rep(0x20)
            end
          end
        end
      end
    end
  end
end
