# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # WHERE EVERYTHING THE GAME KEEPS LIVES WHILE IT RUNS.
        #
        # A PlayStation has 2 megabytes of main RAM, and the program itself is loaded into it (a PS-X
        # EXE, from 80010000h up). The rest is the game's: the runtime's own state, the game's
        # variables and lists, and the stack. They are kept apart from the program in a region of
        # their own at the top of RAM, so every place is known while the program is still being built:
        #
        #   80010000h-8017FFFFh  the program: code, tables (Linker)
        #   80180000h-...        the runtime's own state, then the game's variables and lists, upward
        #   ...-801F7FFFh        free
        #   801F8000h-801FFFEFh  the stack, 32K, growing down from the top
        #
        # THE GAME'S CODE REACHES ITS VARIABLES WITH ONE REGISTER. gp (the "global pointer") holds the
        # address 32K into the region, and a load or a store names a place as a signed 16-bit distance
        # from a register (`lw t0, -32760(gp)`), so the first 64K of the region is one instruction away.
        # A place past that takes one more instruction, to put the top half of its address in a
        # register first. gp is set at power-on and never changed.
        #
        # EVERY PLACE IS A WHOLE NUMBER OF WORDS, and starts at an address that is a multiple of four:
        # the R3000 stops with an address error when it reads a word from anywhere else.
        class Memory
          FIRST = Console::PS1Hardware::PROGRAM_END
          STACK_TOP = Console::PS1Hardware::STACK_TOP
          STACK_BYTES = 0x8000
          LAST = Console::PS1Hardware::RAM_END - STACK_BYTES

          # Where gp points: 32K into the region, so a signed 16-bit distance reaches its first 64K.
          BASE = FIRST + 0x8000

          # How many bytes the program itself may take from where it is loaded: up to the region.
          PROGRAM_ROOM = Console::PS1Hardware::PROGRAM_END - Console::PS1Hardware::EXE_AT

          # Raised when the game keeps more than there is room for. It is the game's to fix, so it is a
          # refusal like the lowering's others, said to the author in the same way.
          class Full < LoweringError; end

          def initialize
            @next = FIRST
            @places = {}
          end

          # +bytes+ of RAM for +name+, and its address, counted up from the region's start. The same
          # name asked again is the same place.
          def reserve(name, bytes)
            @places.fetch(name) do
              size = (bytes + 3) & ~3
              raise Full, full_message(name, size, LAST - @next) if @next + size > LAST

              @places[name] = @next.tap { @next += size }
            end
          end

          # The address +name+ was given.
          def [](name) = @places.fetch(name)

          def reserved?(name) = @places.key?(name)

          # Every name and where it went, for reading a running game back.
          def places = @places.dup

          # How many bytes of the region are in use, which the runtime clears at power-on.
          def used = @next - FIRST

          # The distance of +address+ from where gp points, or nil when it is too far for one instruction.
          def self.distance_from_base(address)
            distance = address - BASE
            distance.between?(-0x8000, 0x7FFF) ? distance : nil
          end

          private

          def full_message(name, bytes, left)
            "This game keeps more than the PlayStation build has room for. #{name.sub(/\A./, &:upcase)} needs " \
              "#{bytes} bytes, and #{[left, 0].max} are left. A list is the usual cause. To fix this, give the " \
              "game's lists smaller capacities, or use fewer variables."
          end
        end
      end
    end
  end
end
