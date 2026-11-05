# frozen_string_literal: true

require_relative "runtime/boot"
require_relative "runtime/int32"
require_relative "runtime/frame"
require_relative "runtime/pads"
require_relative "runtime/lists"
require_relative "runtime/paint"
require_relative "runtime/faces"

module VBlank
  module IR
    module Backends
      class PS1
        # THE RUNTIME every PlayStation program carries: from power-on to the game's first line (Boot),
        # the arithmetic too long to write in place (Int32), the frame, the interrupt and the pads
        # (Frame, Pads), the lists (Lists), the painted screen (Paint), and the faces of a place (Faces).
        #
        # HOW ITS ROUTINES ARE CALLED. With JAL, from anywhere in the program, and they return with
        # `jr ra`. Their numbers are in ARGUMENTS (a0, a1, a2, a3, then t4 to t7) and their answer in v0.
        # A routine may change at, v0, v1, the argument registers and t0 to t9, and keeps s0 to s7, gp
        # and sp as it found them; one that calls another keeps its own return address on the stack.
        # gp points into the region the game keeps its numbers in (Memory::BASE), fp at the scratchpad
        # (Memory::SCRATCHPAD_FIRST), and nothing changes either; k0 and k1 are the interrupt's.
        module Runtime
          ARGUMENTS = %i[a0 a1 a2 a3 t4 t5 t6 t7].freeze

          module_function

          # The runtime's own places in RAM, asked for before the game's; Faces's only for a game that
          # fills faces (+faces+).
          def reserve(memory, faces:)
            Faces.reserve(memory) if faces
            Frame.reserve(memory)
            Paint.reserve(memory)
          end

          # The runtime's sections: the entry point, then everything else. +main+ is the label of the
          # game's main routine; +frame_begins+ the label of the game's routine run at each frame
          # boundary (its timers moving on), or nil for none. +faces+ is whether the game fills the
          # faces of a place, so carries Faces and its table.
          def sections(memory, main:, frame_begins: nil, faces: false)
            asm = R3000.new("runtime")
            Faces.reserve_pieces(memory) if faces
            Boot.emit(asm, memory, main: main)
            Int32.emit(asm)
            Frame.emit(asm, memory)
            Pads.emit(asm, memory)
            Lists.emit(asm, memory)
            Paint.emit(asm, memory)
            Faces.emit(asm, memory) if faces
            emit_start(asm)
            emit_frame_begins(asm, frame_begins)
            [asm.section, *(Faces.reciprocals_section(Lowering::TABLES_HOLDING) if faces)]
          end

          # The runtime place +name+, as the distance from gp an instruction names. The runtime's places
          # are reserved first, so every one is within reach of gp.
          def at(memory, name) = Memory.distance_from_base(memory[name]) || raise(LoweringError, "#{name} is out of gp's reach")

          # What a game needs before its first line: its variables that do not start at nought (the
          # table "game_starts": each place, then its number, a word each, and a place of nought after
          # the last), its lists' headers, its pictures in video RAM, and the whole screen to draw on.
          def emit_start(asm)
            asm.label("rt_start")
            asm.addiu(:sp, :sp, -4)
            asm.sw(:ra, 0, :sp)
            asm.la(:t0, "game_starts")
            asm.label("rt_start_next")
            asm.lw(:t1, 0, :t0)
            asm.beq(:t1, :zero, "rt_start_lists")
            asm.lw(:t2, 4, :t0)
            asm.sw(:t2, 0, :t1)
            asm.b("rt_start_next") { asm.addiu(:t0, :t0, 8) }
            asm.label("rt_start_lists")
            asm.jal("rt_lists_start")
            asm.jal("rt_paint_upload")
            asm.jal("rt_paint_start")
            asm.lw(:ra, 0, :sp)
            asm.jr(:ra) { asm.addiu(:sp, :sp, 4) }
          end

          # What moves on at each frame boundary, once the buttons are read (Reference#advance_frame's
          # middle): the game's timers, through its routine +routine+, or nothing for a game with none.
          def emit_frame_begins(asm, routine)
            asm.label("rt_frame_begins")
            routine ? asm.j(routine) : asm.jr(:ra)
          end
        end
      end
    end
  end
end
