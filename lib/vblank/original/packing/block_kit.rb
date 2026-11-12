# frozen_string_literal: true

module VBlank
  module Original
    module Packing
      # WHAT A FORMAT'S ROUTINE WRITES WITH, the same for every format, the library's and a port's:
      # the copy read with its fault past the end, the slot written with its fault past the end,
      # variables of the routine's own, and the bytes written counted toward the progress bar, with
      # a wait for the next frame every PROGRESS_BYTES so a shell can show how far it has got.
      # These methods are the whole surface a format may call; the rest of a block's workings are
      # BlockKitInternals', which only CopyReader holds.
      #
      #   block.from                      # where the block starts in the copy
      #   block.setting(:base)            # a setting the copy's verb was given
      #   block.byte(at)                  # a byte of the copy, 0 to 255
      #   block.variable(:flags)          # a variable of the routine's own
      #   block.value_of(1)               # a number as a game value, for `block.value_of(1) << count`
      #   block.list(:codes, capacity: 256, width: :half)   # a list of its own, all 0 each block
      #   block.repeat(n, stop_when: block.finished) { ... }
      #   block.expect_size(size)         # the block unpacks to +size+ bytes: checked against the slot
      #   block.write(value)              # the next byte of the slot, the low 8 bits of +value+
      #   block.written_byte(back)        # a byte written +back+ bytes before the next one
      #   block.written                   # how many bytes the block has written so far
      #   block.rewrite(at, value)        # byte +at+ of those, 0 first, written again
      #   block.room                      # bytes the slot has left
      #   block.finished                  # true once the size is written, the block ends, or a write failed
      #   block.finish!                   # the block ends here (a format with an end mark)
      #   block.emit_wrong_format_fault   # the bytes at from are not this format
      #
      # Each write is checked against the slot: one that does not fit is not made, it is the fault
      # the build stops on (the first byte that does not fit, whether +expect_size+ or +write+ finds
      # it), and it finishes the block. This file is read as game code.
      class BlockKit
        def initialize(internals)
          @internals = internals
        end

        def from = @internals.routine_variable(:from)

        def setting(name) = @internals.routine_variable(:"setting_#{name}")

        def variable(name) = @internals.routine_variable(:"format_#{name}")

        def value_of(operand) = @internals.value_of(operand)

        def list(name, capacity:, width: :word)
          @internals.builder.list(@internals.made_name(:"format_#{name}"), capacity: capacity, width: width, full_of: 0)
        end

        def repeat(count, stop_when: nil, &) = @internals.builder.repeat(count, stop_when: stop_when, &)

        # The copy's byte at +at+, with the check before it: a place outside the copy records a fault
        # and reads a byte of the copy instead, as any table read does.
        def byte(at)
          copy = @internals.copy
          @internals.emit_fault(Unpacking::Fault::READ_PAST_END, at, 0) if at < 0 || at >= copy.length
          copy[at]
        end

        def expect_size(size)
          out = @internals.routine_variable(:out)
          if @internals.fits_in_slot(out, size)
            @internals.routine_variable(:goal).store!(out + size)
            finish! if value_of(size) <= 0
          else
            @internals.emit_outside_slot_fault
            finish!
          end
        end

        def write(value)
          out = @internals.routine_variable(:out)
          if @internals.fits_in_slot(out, 1)
            @internals.pack[out] = value
            out.increase!(1)
            finish! if out == @internals.routine_variable(:goal)
            @internals.emit_progress_step
          else
            @internals.emit_outside_slot_fault
            finish!
          end
        end

        def written_byte(back) = @internals.pack[@internals.routine_variable(:out) - back]

        # How many bytes this block has written so far: where the next is, from the block's first.
        def written = @internals.routine_variable(:out) - @internals.routine_variable(:to)

        # Byte +at+ of this block (0 its first) written again as the low 8 bits of +value+, for a
        # format that knows a field only once the bytes after it are written: a note's length, a
        # count. One that is no byte the block has written is not made: it is the fault the build
        # stops on, and it finishes the block. It moves nothing on and counts nothing.
        def rewrite(at, value)
          if at >= 0 && at < written
            @internals.pack[@internals.routine_variable(:to) + at] = value
          else
            @internals.emit_outside_slot_fault
            finish!
          end
        end

        # How many bytes the slot has left from the next one written: a bound for the loop of a
        # format whose size is known only at its end mark.
        def room = @internals.routine_variable(:ends) - @internals.routine_variable(:out)

        def finished = @internals.routine_variable(:block_finished) == 1

        def finish! = @internals.routine_variable(:block_finished).store!(1)

        def emit_wrong_format_fault
          @internals.emit_fault(Unpacking::Fault::WRONG_FORMAT, from, @internals.routine_variable(:format_number))
          finish!
        end
      end

      # THE WORKINGS BEHIND A BlockKit, which only CopyReader holds: the variables a block is handed,
      # the start and end of its routine, the progress count and the waits. A format never sees this.
      class BlockKitInternals
        # How many bytes a block writes between one wait for the next frame and the next.
        PROGRESS_BYTES = 256

        attr_reader :builder, :copy, :pack

        # +before_wait+ names a routine called before each wait for the next frame (a shell's
        # progress bar, Builder::DataPacks#define_unpacking_progress), or is nil for none.
        # +slot_bytes_done+ is a list of the bytes written to each slot, by the slot's number, for a
        # pack whose slots name their costs, or nil for one that names none.
        def initialize(builder, copy:, pack:, faults:, before_wait: nil, slot_bytes_done: nil)
          @builder = builder
          @copy = copy
          @pack = pack
          @faults = faults
          @before_wait = before_wait
          @done = builder.var(Unpacking::BYTES_DONE, 0)
          @slot_bytes_done = slot_bytes_done
          @variables = {}
        end

        # How many bytes have been written so far, a variable of the routine's.
        def bytes_done = @done

        # Whether the bytes written are counted slot by slot too.
        def counts_each_slot? = !@slot_bytes_done.nil?

        # +count+ more bytes written, to the slot numbered +slot_number+ (a number, or a variable the
        # routine set).
        def add_done(count, slot_number)
          @done.increase!(count)
          @slot_bytes_done[slot_number] += count if @slot_bytes_done
        end

        # A variable the blocks share, made the first time it is asked for.
        def routine_variable(what)
          @variables[what] ||= @builder.var(made_name(what), 0)
        end

        def made_name(what) = Messages::MadeNames.make(:unpacking_part, part: what)

        def value_of(operand) = operand.is_a?(DSL::Value) ? operand : DSL::Value.new(@builder, DSL::Value.node_for(operand))

        def emit_fault(kind, at, detail) = @faults.emit_fault(kind, at, detail)

        # +count+ more bytes written to the slot numbered +slot_number+ by a decoder of the game's own
        # (CopyReader#count_written).
        def count_written(count, slot_number)
          unwaited = routine_variable(:unwaited)
          add_done(count, slot_number)
          unwaited.increase!(count)
          if unwaited >= PROGRESS_BYTES
            unwaited.store!(0)
            emit_wait
          end
        end

        # What a block is handed, set before its routine is called.
        def emit_block_arguments(at:, slot:, start:, count:, format_number:)
          routine_variable(:from).store!(at)
          routine_variable(:to).store!(slot.place(start))
          routine_variable(:ends).store!(slot.place(slot.byte_size))
          routine_variable(:slot_first).store!(slot.place(0))
          routine_variable(:slot_number).store!(slot.number)
          routine_variable(:count).store!(count)
          routine_variable(:format_number).store!(format_number)
        end

        # The start of a block's routine: the cursor at its first byte, no size expected yet.
        def emit_block_start
          to = routine_variable(:to)
          routine_variable(:out).store!(to)
          routine_variable(:mark).store!(to)
          routine_variable(:goal).store!(-1)
          routine_variable(:block_finished).store!(0)
        end

        # The end of a block's routine: what is left counted as done.
        def emit_block_end
          add_done(routine_variable(:out) - routine_variable(:mark), routine_variable(:slot_number))
        end

        # A wait for the next frame, with the routine to call before it.
        def emit_wait
          @builder.call(@before_wait) if @before_wait
          @builder.wait_vblank
        end

        # Every PROGRESS_BYTES written since the mark, the count of bytes done moves on and the
        # routine waits for the next frame.
        def emit_progress_step
          out = routine_variable(:out)
          mark = routine_variable(:mark)
          if out - mark >= PROGRESS_BYTES
            add_done(out - mark, routine_variable(:slot_number))
            mark.store!(out)
            emit_wait
          end
        end

        # Whether a write of +size+ bytes from +to+ fits between the slot's first byte and its end:
        # a test the routine makes, new each time it is asked for.
        def fits_in_slot(to, size) = to >= routine_variable(:slot_first) && size <= routine_variable(:ends) - to

        # The fault for a write that does not fit: the first byte past the slot's end, in the slot.
        def emit_outside_slot_fault
          emit_fault(Unpacking::Fault::WRITE_OUTSIDE_SLOT, routine_variable(:ends) - routine_variable(:slot_first),
                     routine_variable(:slot_number))
        end
      end
    end
  end
end
