# frozen_string_literal: true

module VBlank
  module Original
    module Packing
      # A PACKED FORMAT AN UNPACKING ROUTINE CAN READ: a module that extends this, names the
      # format, and writes its routine with a BlockKit. The library's own formats
      # (Packing::GBA, Packing::Genesis) are written this way and no other, so a port writes a
      # format the library lacks the same way, and names it in `data_pack formats: [...]`:
      #
      #   module Sorcery
      #     extend VBlank::Original::Packing::Format
      #     unpacks :sorcery                 # gives the copy `unpack_sorcery at:, into:, start:`
      #
      #     def self.routine(block)          # game code, written into the unpacking once
      #       at = block.variable(:at)
      #       at.store!(block.from)
      #       ...
      #       block.write(block.byte(at))
      #     end
      #   end
      #
      # A format with settings names each with its default (`unpacks :enigma, base: 0`), and the
      # copy's verb takes them (`copy.unpack_enigma at:, into:, base: 0x2000`); the routine reads
      # each with `block.setting(:base)`. A routine's file is game code, as any part of a game is
      # (VBlank.require_game_file), so an `if` on a test the routine makes is a branch in it.
      module Format
        # Names the format: +name+ gives the copy `unpack_<name>`, and +settings+ are the settings
        # that verb takes besides at:, into: and start:, each with its default.
        def unpacks(name, **settings)
          refuse_settings_named_as_places!(name, settings)
          @format_name = name.to_sym
          # Shareable, since a test may unpack in a Ractor and these are a module's.
          @format_settings = Ractor.make_shareable(settings)
        end

        # What a person calls the format, in an error that names it: +words+, or the name.
        def called(words) = @format_words = Ractor.make_shareable(words.to_s.dup)

        def format_name = @format_name

        def format_settings = @format_settings || {}

        def format_words = @format_words || @format_name.to_s

        private

        def refuse_settings_named_as_places!(name, settings)
          taken = settings.keys & %i[at into start]
          return if taken.empty?

          raise ArgumentError, "Format :#{name} names the setting #{taken.map(&:inspect).join(', ')}. at:, into: and " \
                               "start: are every format's. Give the setting another name."
        end
      end

      # WHAT A FORMAT'S ROUTINE WRITES WITH, the same for every format, the library's and a port's:
      # the copy read with its fault past the end, the slot written with its fault past the end,
      # variables of the routine's own, and the bytes written counted toward the progress bar, with
      # a wait for the next frame every PROGRESS_BYTES so a shell can show how far it has got.
      #
      #   block.from                      # where the block starts in the copy
      #   block.setting(:base)            # a setting the copy's verb was given
      #   block.byte(at)                  # a byte of the copy, 0 to 255
      #   block.variable(:flags)          # a variable of the routine's own
      #   block.list(:codes, capacity: 256, width: :half)   # a list of its own, all 0 each block
      #   block.repeat(n, stop_when: block.finished) { ... }
      #   block.expect_size(size)         # the block unpacks to +size+ bytes: checked against the slot
      #   block.write(value)              # the next byte of the slot, the low 8 bits of +value+
      #   block.written_byte(back)        # a byte written +back+ bytes before the next one
      #   block.room                      # bytes the slot has left
      #   block.finished                  # true once the size is written, the block ends, or a write failed
      #   block.finish!                   # the block ends here (a format with an end mark)
      #   block.emit_wrong_format_fault   # the bytes at from are not this format
      #
      # Each write is checked against the slot: one that does not fit is not made, it is the fault
      # the build stops on, and it finishes the block. This file is read as game code.
      class BlockKit
        # How many bytes a block writes between one wait for the next frame and the next.
        PROGRESS_BYTES = 256

        # +before_wait+ names a routine called before each wait for the next frame (a shell's
        # progress bar, Builder::DataPacks#define_unpacking_progress), or is nil for none.
        def initialize(builder, copy:, pack:, faults:, before_wait: nil)
          @builder = builder
          @copy = copy
          @pack = pack
          @faults = faults
          @before_wait = before_wait
          @done = builder.var(Unpacking::BYTES_DONE, 0)
          @variables = {}
        end

        # How many bytes have been written so far, a variable of the routine's.
        def bytes_done = @done

        def from = routine_variable(:from)

        def setting(name) = routine_variable(:"setting_#{name}")

        def variable(name) = routine_variable(:"format_#{name}")

        def list(name, capacity:, width: :word)
          @builder.list(made_name(:"format_#{name}"), capacity: capacity, width: width, full_of: 0)
        end

        def repeat(count, stop_when: nil, &) = @builder.repeat(count, stop_when: stop_when, &)

        # The copy's byte at +at+, with the check before it: a place outside the copy records a fault
        # and reads a byte of the copy instead, as any table read does.
        def byte(at)
          if at.is_a?(Integer)
            @faults.emit_fault(Unpacking::Fault::READ_PAST_END, at, 0) unless at.between?(0, @copy.length - 1)
            return @copy[at]
          end

          @faults.emit_fault(Unpacking::Fault::READ_PAST_END, at, 0) if at < 0 || at >= @copy.length
          @copy[at]
        end

        def expect_size(size)
          out = routine_variable(:out)
          if fits_in_slot(out, size)
            routine_variable(:goal).store!(out + size)
            finish! if value_of(size) <= 0
          else
            emit_outside_slot_fault(out, size)
            finish!
          end
        end

        def write(value)
          out = routine_variable(:out)
          if fits_in_slot(out, 1)
            @pack[out] = value
            out.increase!(1)
            finish! if out == routine_variable(:goal)
            emit_progress_step
          else
            emit_outside_slot_fault(out, 1)
            finish!
          end
        end

        def written_byte(back) = @pack[routine_variable(:out) - back]

        # How many bytes the slot has left from the next one written: a bound for the loop of a
        # format whose size is known only at its end mark.
        def room = routine_variable(:ends) - routine_variable(:out)

        def finished = routine_variable(:finished) == 1

        def finish! = routine_variable(:finished).store!(1)

        def emit_wrong_format_fault
          @faults.emit_fault(Unpacking::Fault::WRONG_FORMAT, from, routine_variable(:format_number))
          finish!
        end

        # +count+ more bytes written by a decoder of the game's own (CopyReader#count_written).
        def count_written(count)
          unwaited = routine_variable(:unwaited)
          @done.increase!(count)
          unwaited.increase!(count)
          if unwaited >= PROGRESS_BYTES
            unwaited.store!(0)
            emit_wait
          end
        end

        # For CopyReader: what a block is handed, set before its routine is called.
        def emit_block_arguments(at:, slot:, start:, count:, format_number:)
          routine_variable(:from).store!(at)
          routine_variable(:to).store!(slot.place(start))
          routine_variable(:ends).store!(slot.place(slot.byte_size))
          routine_variable(:slot_first).store!(slot.place(0))
          routine_variable(:slot_number).store!(slot.number)
          routine_variable(:count).store!(count)
          routine_variable(:format_number).store!(format_number)
        end

        # For CopyReader: the start of a block's routine (the cursor at its first byte, no size
        # expected yet) and its end (what is left counted as done).
        def emit_block_start
          to = routine_variable(:to)
          routine_variable(:out).store!(to)
          routine_variable(:mark).store!(to)
          routine_variable(:goal).store!(-1)
          routine_variable(:finished).store!(0)
        end

        def emit_block_end
          @done.increase!(routine_variable(:out) - routine_variable(:mark))
        end

        # A wait for the next frame, with the routine to call before it.
        def emit_wait
          @builder.call(@before_wait) if @before_wait
          @builder.wait_vblank
        end

        # A variable the blocks share, made the first time it is asked for.
        def routine_variable(what)
          @variables[what] ||= @builder.var(made_name(what), 0)
        end

        def made_name(what) = Messages::MadeNames.make(:unpacking_part, part: what)

        def value_of(operand) = operand.is_a?(DSL::Value) ? operand : DSL::Value.new(@builder, DSL::Value.node_for(operand))

        private

        # Every PROGRESS_BYTES written since the mark, the count of bytes done moves on and the
        # routine waits for the next frame.
        def emit_progress_step
          out = routine_variable(:out)
          mark = routine_variable(:mark)
          if out - mark >= PROGRESS_BYTES
            @done.increase!(out - mark)
            mark.store!(out)
            emit_wait
          end
        end

        # Whether a write of +size+ bytes from +to+ fits between the slot's first byte and its end:
        # a test the routine makes, new each time it is asked for.
        def fits_in_slot(to, size) = to >= routine_variable(:slot_first) && size <= routine_variable(:ends) - to

        # The fault for a write of +size+ bytes from +to+ that does not fit: its last byte, in the slot.
        def emit_outside_slot_fault(to, size)
          @faults.emit_fault(Unpacking::Fault::WRITE_OUTSIDE_SLOT, to - routine_variable(:slot_first) + size - 1,
                             routine_variable(:slot_number))
        end
      end
    end
  end
end
