# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        # WHERE THE GAME'S NUMBERS LIVE: one data segment of 64K, addressed by an offset from DS. The stack is
        # in the same segment, at the top and growing down (SS = DS, SP = FFFEh), so the numbers start at the
        # bottom and the build keeps the room the description names for the stack (work_memory_kept_bytes).
        #
        # Everything a program keeps there is reserved by name while the program is built, so the runtime and
        # the game can say where a place is by what it is, and a reader of the running program (HeadlessRun)
        # finds it by the same name. A place of four bytes or more starts on a multiple of four: the 386 reads
        # such a number in one go at any address, but an aligned one is read faster.
        class Memory
          CONSOLE = Console::DOS
          LIMIT = CONSOLE.work_memory_bytes - CONSOLE.work_memory_kept_bytes

          # The screen the program is built for, which everything that lays the program out or draws asks
          # (Screen).
          attr_reader :screen

          def initialize(screen)
            @screen = screen
            @top = 0
            @places = {}
          end

          # +bytes+ bytes for +name+, as an offset in the data segment. +what+ says what it is for, in the
          # words of the refusal when it does not fit.
          def reserve(name, bytes, what: name.to_s)
            @top += (-@top) % 4 if bytes >= 4
            raise LoweringError, too_full_message(what, bytes) if @top + bytes > LIMIT

            @places[name] = @top
            @top += bytes
            @places[name]
          end

          def [](name) = @places.fetch(name) { raise LoweringError, "#{name.inspect} has no place in the data segment" }

          # Every place reserved, by name.
          def places = @places.dup

          # How many bytes the boot code clears: everything reserved, to a whole number of 32-bit words.
          def cleared_bytes = @top + ((-@top) % 4)

          private

          def too_full_message(what, bytes)
            "The numbers of this game need more room than DOS keeps in one segment. #{what} needs #{bytes} " \
              "bytes, and #{LIMIT - @top} of the #{LIMIT} are left. To fix this, use fewer variables or shorter lists."
          end
        end
      end
    end
  end
end
