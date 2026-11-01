# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # WHERE EVERYTHING THE GAME KEEPS LIVES WHILE IT RUNS.
        #
        # A Genesis has 64K of work RAM, at $FF0000 to $FFFFFF, and nothing else the 68000 can keep a
        # number in. Everything is there: the runtime's own state, the game's variables and lists, a
        # painted screen's copy of the picture, the sprite table's copy, and the stack, which starts
        # at the very top and grows down.
        #
        #   $FF0000-...   the runtime's own state, then the game's variables and lists, upward
        #   ...-$FFF7FF   what wants a big place of its own (a painted screen's picture), downward
        #   $FFFC00-$FFFFFF  the stack, 1K of it
        #
        # THE GAME'S CODE REACHES ALL OF IT WITH ONE REGISTER. A5 holds $FF8000, the middle of work
        # RAM, and an instruction names a place as a distance from A5 that is held in 16 bits and
        # signed (`8(A5)`): the whole 64K is within ±32K of the middle. That is two words long
        # where a long address is three, and a cycle or two quicker, which is why every
        # variable is read and written this way. A5 is never changed after power-on.
        #
        # EVERY PLACE IS AT AN EVEN ADDRESS, since the 68000 stops with an address error when it
        # reads a word or a long word from an odd one. A place a byte long still takes two.
        #
        # Nothing here is placed by the linker: work RAM is the same addresses on every console, so
        # every place is known as soon as it is asked for.
        class Memory
          FIRST = Console::GenesisHardware::WRAM
          END_OF_RAM = Console::GenesisHardware::WRAM + Console::GenesisHardware::WRAM_SIZE
          STACK_BYTES = 0x400
          STACK_START = END_OF_RAM - STACK_BYTES

          # Where A5 points: the middle of work RAM, so a signed 16-bit distance reaches all of it.
          BASE = Console::GenesisHardware::WRAM + 0x8000

          # Raised when the game keeps more than there is room for. It is the game's to fix, so it
          # is a refusal like the lowering's others, said to the author in the same way.
          class Full < LoweringError; end

          def initialize
            @next = FIRST
            @last = STACK_START
            @places = {}
          end

          # The distance of +address+ from where A5 points, which is what an instruction names.
          def self.displacement(address) = address - BASE

          # +bytes+ of work RAM for +name+, and its address, counted up from the runtime's start. The
          # same name asked again is the same place.
          def reserve(name, bytes)
            @places.fetch(name) do
              size = even(bytes)
              raise Full, full_message(name, size, @last - @next) if @next + size > @last

              @places[name] = @next.tap { @next += size }
            end
          end

          # +bytes+ of work RAM for +name+ from the top, below the stack, counted down: a place too big
          # to want to sit among the small ones, like a painted screen's copy of its picture.
          def reserve_last(name, bytes)
            @places.fetch(name) do
              size = even(bytes)
              raise Full, full_message(name, size, @last - @next) if @last - size < @next

              @last -= size
              @places[name] = @last
            end
          end

          # The address +name+ was given.
          def [](name) = @places.fetch(name)

          # The distance from A5 of the place +name+ was given.
          def displacement(name) = self.class.displacement(self[name])

          def reserved?(name) = @places.key?(name)

          # Every name and where it went, for reading a running game back.
          def places = @places.dup

          # How many bytes of the first part are in use.
          def used = @next - FIRST

          private

          def even(bytes) = (bytes + 1) & ~1

          def full_message(name, bytes, left)
            "This game keeps more than a Genesis's work RAM holds. #{name.sub(/\A./, &:upcase)} needs " \
              "#{bytes} bytes, and #{[left, 0].max} are left. A list or a painted screen is the usual cause. " \
              "To fix this, give the game's lists smaller capacities, or use fewer variables."
          end
        end
      end
    end
  end
end
