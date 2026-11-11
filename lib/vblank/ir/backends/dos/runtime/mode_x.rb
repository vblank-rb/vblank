# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # MODE X: 320 x 240 in 256 colours, the screen Michael Abrash described in 1991 and most DOS action
          # games after it used. It is what a console's game wants of a PC: its pixels are square (the plain
          # mode's 200 rows are stretched over the same glass, so its pixels are taller than wide), and it is
          # drawn sixty times a second, where the plain mode is seventy.
          #
          # NO BIOS CALL SETS IT. It is the plain mode with the card's own registers changed after
          # (#emit_mode_registers): the card told to stop "chaining" its four planes of memory, and its timing set to
          # 480 lines, each drawn twice. Abrash's list of register values is used as he gave it.
          #
          # THE CARD'S MEMORY IS IN FOUR PLANES. A VGA card has 256K, more than the 64K the processor sees at
          # A000h, and it shows through that window whichever of four planes are switched on. In the plain
          # mode the card hides this (pixel n is in plane n mod 4, and it switches as you go). Unchained, the
          # program picks the planes itself, with a mask written to the sequencer: pixel column c of a row is
          # in plane (c mod 4), at byte (row x 80 + c / 4) of the window. So the picture is sent a plane at a
          # time (#emit_show_picture): the mask set once, then every fourth pixel of each changed row, starting at
          # the plane's own column, written to consecutive bytes of the window. Four passes of a quarter of
          # the pixels each.
          #
          # The game still draws into its own picture in ordinary memory, a byte a pixel, a row after a row
          # (Rows), and only this copy knows about planes.
          module ModeX
            SEQUENCER = Console::DOSHardware::SEQUENCER_INDEX
            MISC_OUTPUT = 0x3C2
            CRTC = 0x3D4
            MEMORY_MODE = 4
            UNCHAINED = 0x06
            RESET = 0
            WRITE_PROTECT = 0x11 # the CRTC register whose top bit locks the timing registers
            # The 480-line dot clock and sync, and the CRTC's registers for 240 rows each drawn twice, each as
            # (value << 8) | register, in Abrash's order.
            TIMING_480_LINES = 0xE3
            CRTC_VALUES = [0x0D06, 0x3E07, 0x4109, 0xEA10, 0xAC11, 0xDF12, 0x0014, 0xE715, 0x0616, 0xE317].freeze
            PLANES = 4

            # What the copy keeps while DS is at a row of the picture: rows left, the first row's paragraphs
            # into the picture, and where it goes in the window.
            ROWS = "rt mode x rows"
            FROM = "rt mode x from"
            TO = "rt mode x to"
            WORDS = [ROWS, FROM, TO].freeze

            module_function

            def reserve(memory) = WORDS.each { |name| memory.reserve(name, 4) }

            # The card set to Mode X, after the BIOS has set the plain mode, and its four planes cleared.
            # Changes AX, CX, DX, DI and ES.
            def emit_mode_registers(asm)
              word_to = lambda do |port, word|
                asm.mov(:dx, port)
                asm.mov(:ax, word)
                asm.out_to_dx(:ax)
              end
              word_to.call(SEQUENCER, (UNCHAINED << 8) | MEMORY_MODE)
              word_to.call(SEQUENCER, 0x0100 | RESET) # hold the sequencer still while the dot clock changes
              asm.mov(:dx, MISC_OUTPUT)
              asm.mov(:al, TIMING_480_LINES)
              asm.out_to_dx(:al)
              word_to.call(SEQUENCER, 0x0300 | RESET)
              asm.mov(:dx, CRTC)
              asm.mov(:al, WRITE_PROTECT)
              asm.out_to_dx(:al)
              asm.inc(:dx)
              asm.in_from_dx(:al)
              asm.and(:al, 0x7F)
              asm.out_to_dx(:al)
              CRTC_VALUES.each { |word| word_to.call(CRTC, word) }
              word_to.call(SEQUENCER, 0x0F00 | Console::DOSHardware::MAP_MASK) # all four planes, to clear them at once
              asm.mov(:ax, VIDEO)
              asm.mov(:es, :ax)
              asm.xor(:di, :di)
              asm.xor(:ax, :ax)
              asm.mov(:cx, 0x8000)
              asm.stos(16, rep: true)
            end

            # rt_show_picture for Mode X: the rows that changed, sent to the card a plane at a time from the
            # picture +shown+ (a segment's name), and none marked as changed after. Changes AX, CX and DX.
            def emit_show_picture(asm, memory, shown)
              screen = memory.screen
              top = X86.mem(nil, memory[Frame::CHANGED_TOP], size: 16)
              bottom = X86.mem(nil, memory[Frame::CHANGED_BOTTOM], size: 16)
              kept = ->(name, seg) { X86.mem(nil, memory[name], seg: seg, size: 16) }
              asm.label("rt_show_picture")
              asm.mov(:ax, bottom)
              asm.sub(:ax, top)
              asm.jbe("rt_show_picture_done")
              asm.mov(kept.call(ROWS, nil), :ax)
              asm.mov(:ax, top)
              asm.mov(:cx, Rows.row_paragraphs(screen))
              asm.mul(:cx)
              asm.mov(kept.call(FROM, nil), :ax)
              asm.mov(:ax, top)
              asm.mov(:cx, screen.width / PLANES)
              asm.mul(:cx)
              asm.mov(kept.call(TO, nil), :ax)
              asm.mov(top, screen.height)
              asm.mov(bottom, 0)
              asm.push(:ds)
              asm.push(:es)
              asm.push(:si)
              asm.push(:di)
              asm.push(:bx)
              asm.mov(:ax, VIDEO)
              asm.mov(:es, :ax)
              PLANES.times { |plane| emit_show_plane(asm, memory, shown, plane, kept) }
              asm.pop(:bx)
              asm.pop(:di)
              asm.pop(:si)
              asm.pop(:es)
              asm.pop(:ds)
              asm.label("rt_show_picture_done")
              asm.ret
            end

            # One plane of the rows: BX the row's paragraphs into the picture, DI where it goes in the window,
            # DX the rows left. Two pixels of the plane are read and written at a time, and the row is written
            # out, an instruction for each read and each write with its column in it: a loop would count and
            # add for every pair, twice the work, and this is the slowest thing a pass does. What was kept is
            # read through SS, since DS is at the row.
            def emit_show_plane(asm, memory, shown, plane, kept)
              screen = memory.screen
              asm.mov(:dx, SEQUENCER)
              asm.mov(:ax, ((1 << plane) << 8) | Console::DOSHardware::MAP_MASK)
              asm.out_to_dx(:ax)
              asm.mov(:bx, kept.call(FROM, :ss))
              asm.mov(:di, kept.call(TO, :ss))
              asm.mov(:dx, kept.call(ROWS, :ss))
              asm.label("rt_show_plane_#{plane}_row")
              asm.mov_segment(:ax, shown)
              asm.add(:ax, :bx)
              asm.mov(:ds, :ax)
              plane.step(screen.width - 1, PLANES * 2) do |column|
                asm.mov(:al, X86.mem(nil, column))
                asm.mov(:ah, X86.mem(nil, column + PLANES))
                asm.stos(16)
              end
              asm.add(:bx, Rows.row_paragraphs(screen))
              asm.dec(:dx)
              asm.jne("rt_show_plane_#{plane}_row")
            end
          end
        end
      end
    end
  end
end
