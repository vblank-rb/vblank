# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # Raised when a program cannot be made into a Genesis cartridge: it reaches something the
        # Genesis cannot do, or something its build does not make yet, or it is too big for the
        # cartridge or its memory. Said to the author in plain words.
        class LoweringError < VBlank::BuildError; end
      end
    end
  end
end

require_relative "genesis/m68000"
require_relative "genesis/linker"
require_relative "genesis/memory"
require_relative "genesis/art"
require_relative "genesis/painted_art"
require_relative "genesis/runtime"
require_relative "genesis/lowering/picture"
require_relative "genesis/lowering/paint"
require_relative "genesis/lowering/collision"
require_relative "genesis/lowering"
require_relative "genesis/headless_run"
require_relative "genesis/checked_run"

module VBlank
  module IR
    module Backends
      # The game as a SEGA GENESIS cartridge: the same program every other backend runs, lowered to
      # the 68000, the console's processor, and laid out flat in a cartridge of up to four megabytes.
      #
      # HOW IT IS MADE. Genesis::Lowering walks the IR and emits 68000 machine code through the Ruby
      # assembler (Genesis::M68000), as the Super Nintendo's lowering emits 65816, and shares with
      # that lowering what both work out before writing an instruction (LoweringPlan, RoutineCuts,
      # Sections). The runtime the code calls is written in 68000 here, in Ruby. The cartridge is
      # checked in Genesis Plus GX through ruby-genesis-emulator, which `rake compile_genesis_core`
      # builds.
      class Genesis
        # WHERE A RUNNING CARTRIDGE KEEPS WHAT A READER WANTS, which nothing in its bytes says: every
        # variable by the game's name (its address in work RAM), every list ([its address, its
        # capacity, the bytes a slot, its name]), where the runtime keeps how the run stands
        # (Runtime::Frame's names), where every label of the code went, the program it was built from,
        # and each sprite picture's number as SpriteNames numbers the picture it shows.
        # +bytes+ says what the cartridge's sections come to, as :code (what the processor runs) and :data
        # (what it only reads), for the cost recorded in tools/emitted_baseline.json.
        Places = Data.define(:variables, :lists, :runtime, :source_program, :code, :sprite_picture_names, :bytes) do
          # Where the runtime counts the times the game has waited for the screen (32 bits).
          def waits_counted_at = runtime.fetch(Runtime::Frame::PASSES)
        end

        # What the build found to say about what it decided (Cartridge::LoweredBuild).
        def findings = (@findings ||= [])

        # +program+ as a cartridge (Cartridge::GenesisROM), carrying its Places.
        def build(program, title: "VBLANK")
          memory = Memory.new
          picture = Lowering.picture_of(program)
          colors = Lowering.changing_colors?(program)
          Runtime.reserve(memory, picture: picture, colors: colors)
          lowering = Lowering.new(program, memory: memory)
          game = lowering.sections
          runtime = Runtime.sections(memory, main: Lowering::MAIN, registers: lowering.register_count,
                                             frame_begins: lowering.frame_begins, picture: picture,
                                             columns: lowering.plane_size.first, collision: lowering.collides?, fractions: lowering.fractions?,
                                             camera: lowering.camera?, colors: colors)
          linked = Linker.new(runtime + game).link
          built = Places.new(variables: lowering.variables, lists: lowering.lists,
                             runtime: memory.places.select { |name, _| name.start_with?("rt ") },
                             source_program: program, code: linked.places, sprite_picture_names: picture == :tiled ? lowering.sprite_picture_names : {},
                             bytes: byte_counts(linked))
          Cartridge::GenesisROM.new(linked.image, title: title, vectors: vectors(linked), built: built)
        end

        private

        # How many bytes of the cartridge are code and how many are data: the sections that hold the
        # game's tables and pictures (Lowering::DATA and Lowering::ART) are data, and the rest code.
        def byte_counts(linked)
          data, code = linked.sections.values.partition { |placed| [Lowering::DATA, Lowering::ART].include?(placed.section.holds) }
          { code: code.sum { |placed| placed.section.size }, data: data.sum { |placed| placed.section.size } }
        end

        # Where each vector points: reset starts the game, the vertical blank counts the frame and
        # reads the pad, the horizontal blank does nothing, and every way the processor can fault
        # stops the game saying so. A vector not named points where reset does.
        def vectors(linked)
          faults = %i[bus_error address_error illegal zero_divide chk trapv privilege trace line_a line_f]
          { reset: linked.address_of("rt_reset"), vertical_interrupt: linked.address_of("rt_vblank_interrupt"),
            horizontal_interrupt: linked.address_of("rt_unused_interrupt") }
            .merge(faults.to_h { |fault| [fault, linked.address_of("rt_exception")] })
        end
      end
    end
  end
end
