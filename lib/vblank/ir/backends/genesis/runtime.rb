# frozen_string_literal: true

require_relative "runtime/boot"
require_relative "runtime/int32"
require_relative "runtime/frame"
require_relative "runtime/lists"
require_relative "runtime/paint"
require_relative "runtime/tiles"
require_relative "runtime/picture"

module VBlank
  module IR
    module Backends
      class Genesis
        # THE RUNTIME every Genesis cartridge carries: from power-on to the game's first line (Boot),
        # the arithmetic (Int32), the frame and the buttons (Frame), the lists (Lists), and the
        # picture (Picture).
        #
        # HOW ITS ROUTINES ARE CALLED. With JSR (and they return with RTS), from anywhere in the
        # cartridge, with A5 at the middle of work RAM (Memory::BASE, which Boot sets and nothing
        # changes); with their numbers in D0, D1, D2... and their answer in D0. A routine may use every
        # data register, A0 to A4 and A6 as it likes, but never A5.
        module Runtime
          module_function

          # The runtime's own places in work RAM, asked for before the game's.
          def reserve(memory, picture: :none)
            Frame.reserve(memory)
            Picture.reserve(memory, picture: picture)
          end

          # The runtime's sections: the vectors' entry points first, then everything else in one.
          # +main+ is the label of the game's main routine; +frame_begins+ the label of the game's
          # routine run at each frame boundary (its timers moving on), or nil for none.
          # +picture+ is how the game draws (Picture), :painted, :tiled or :none, which carries what it
          # draws with, and +columns+ how many cells across the planes of a tiled one are.
          # +registers+ is how many words of the video chip's register table the game writes
          # ("rt_vdp_registers", which the lowering makes).
          def sections(memory, main:, registers:, frame_begins: nil, picture: :none, columns: 32)
            entry = M68000.new("runtime entry")
            Boot.emit_vectors(entry)
            asm = M68000.new("runtime")
            Boot.emit(asm, main: main, registers: registers, held_at: memory.displacement(Frame::HELD))
            Int32.emit(asm)
            Frame.emit(asm, memory)
            Lists.emit(asm, memory)
            Picture.emit(asm, memory, picture: picture, columns: columns)
            emit_start(asm)
            emit_frame_begins(asm, frame_begins)
            [entry.section, asm.section]
          end

          # What a game needs before its first line: its variables that do not start at nought (the
          # table "game_starts": each place as a long, then its number as a long, and a place of
          # nought after the last), its lists' headers, the picture's start, the screen's interrupt
          # switched on.
          def emit_start(asm)
            asm.label("rt_start")
            asm.lea(asm.abs_l("game_starts"), asm.a(0))
            asm.label("rt_start_next")
            asm.move(:l, asm.post(0), asm.d(0))
            asm.branch(:eq, "rt_start_lists")
            asm.movea(:l, asm.d(0), asm.a(1))
            asm.move(:l, asm.post(0), asm.ind(1))
            asm.bra("rt_start_next")
            asm.label("rt_start_lists")
            asm.jsr(asm.abs_l("rt_lists_start"))
            asm.jsr(asm.abs_l("rt_picture_start"))
            emit_interrupt_on(asm)
            asm.rts
          end

          # The screen's interrupt switched on, once, as setting up ends: the chip told to raise it, and
          # the processor to take it. The screen itself stays off until the first pass is shown.
          def emit_interrupt_on(asm)
            h = Console::GenesisHardware
            asm.move(:w, asm.imm(h::VDP_REGISTER | (h::REG_MODE2 << 8) | h::MODE2_SCREEN_OFF | h::MODE2_VBLANK_INTERRUPT),
                     asm.abs_l(h::VDP_CONTROL))
            asm.move_to_sr(asm.imm(Frame::INTERRUPTS_ON))
          end

          # What moves on at each frame boundary, once the buttons are read (Reference#advance_frame's
          # middle): the game's timers, through its routine +routine+, or nothing for a game with none.
          def emit_frame_begins(asm, routine)
            asm.label("rt_frame_begins")
            asm.jmp(asm.abs_l(routine)) if routine
            asm.rts unless routine
          end
        end
      end
    end
  end
end
