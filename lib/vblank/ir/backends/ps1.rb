# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # Raised when a program cannot be made into a PlayStation program: it reaches something the
        # PlayStation cannot do, or something its build does not make yet, or it is too big for the
        # console's memory. Said to the author in plain words.
        class LoweringError < VBlank::BuildError; end
      end
    end
  end
end

require_relative "ps1/r3000"
require_relative "ps1/linker"
require_relative "ps1/memory"
require_relative "ps1/runtime"
require_relative "ps1/painted_art"
require_relative "ps1/lowering/paint"
require_relative "ps1/lowering"
require_relative "ps1/headless_run"
require_relative "ps1/checked_run"

module VBlank
  module IR
    module Backends
      # The game as a PLAYSTATION program: the same program every other backend runs, lowered to the
      # R3000A, the console's processor, and written as a PS-X EXE, the file a PlayStation's BIOS loads
      # from a disc and an emulator or a loader on a real console takes as it is.
      #
      # HOW IT IS MADE. PS1::Lowering walks the IR and emits MIPS machine code through the Ruby assembler
      # (PS1::R3000), as the Genesis's lowering emits 68000, and shares with the other cartridge lowerings
      # what they all work out before writing an instruction (LoweringPlan, Sections). The runtime the code
      # calls is written in MIPS here, in Ruby, and calls nothing in the BIOS. The program is checked in
      # Beetle PSX through ruby-ps1-emulator, which `rake compile_ps1_core` builds.
      #
      # WHAT IT MAKES SO FAR: a game's numbers, lists, tables, routines, scenes, timers and pad, and a
      # painted screen of one page or two, with its rectangles, pictures and text (Runtime::Paint).
      # Everything else a game draws or plays is refused by name until it is made
      # (Lowering::NOT_LOWERED_YET).
      class PS1
        # WHERE A RUNNING PROGRAM KEEPS WHAT A READER WANTS, which nothing in its bytes says: every variable
        # by the game's name (its address in RAM), every list ([its address, its capacity, the bytes a
        # slot, its name]), where the runtime keeps how the run stands (Runtime::Frame's names), where
        # every label of the code went, and the program it was built from. +bytes+ says what the program's
        # sections come to (ByteCounts).
        Places = Data.define(:variables, :lists, :runtime, :source_program, :code, :bytes) do
          # Where the runtime counts the times the game has waited for the screen.
          def waits_counted_at = runtime.fetch(Runtime::Frame::PASSES)
        end

        # What the program's sections come to: +code+, the bytes the processor runs, and +data+, the bytes
        # it only reads (the game's tables).
        ByteCounts = Data.define(:code, :data)

        # What the build found to say about what it decided (Cartridge::LoweredBuild): nothing yet.
        def findings = (@findings ||= [])

        # +program+ as a PS-X EXE (Cartridge::PS1EXE), carrying its Places.
        def build(program, title: "VBLANK", cache: BuildCache.for(PS1, program))
          memory = Memory.new
          Runtime.reserve(memory)
          lowering = Lowering.new(program, memory: memory, cache: cache)
          game = lowering.sections
          runtime = Runtime.sections(memory, main: Lowering::MAIN, frame_begins: lowering.frame_begins,
                                             direct_slot_sizes: lowering.direct_slot_sizes)
          linked = Linker.new(runtime + game, room: Memory::PROGRAM_ROOM).link
          built = Places.new(variables: lowering.variables, lists: lowering.lists.transform_values(&:to_a),
                             runtime: memory.places.select { |name, _| name.start_with?("rt ") },
                             source_program: program, code: linked.places, bytes: byte_counts(linked))
          Cartridge::PS1EXE.new(linked.image, title: title, entry: linked.address_of("rt_boot"), built: built)
        end

        private

        # How many bytes of the program are code and how many are data: the sections that hold the game's
        # tables (Lowering::TABLES_HOLDING) are data, and the rest code.
        def byte_counts(linked)
          data, code = linked.sections.values.partition { |placed| placed.section.holds == Lowering::TABLES_HOLDING }
          ByteCounts.new(code: code.sum { |placed| placed.section.size }, data: data.sum { |placed| placed.section.size })
        end
      end
    end
  end
end
