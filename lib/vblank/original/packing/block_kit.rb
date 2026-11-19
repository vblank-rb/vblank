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
      #   block.variable(:flags)          # a variable of the routine's own, kept with store! (a local does the same)
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
      #
      # A ROUTINE'S COUNTERS ARE ITS LOCALS. A format's file is game code (VBlank.require_game_file),
      # so its routine is a method of a game file, and `block.repeat` is the game verb `repeat`
      # (DSL::PlainRuby::LocalNames::GAME_VERBS). The rewrite that reads every game file therefore
      # makes a local the routine changes inside a `block.repeat` into a variable of the unpacking,
      # with no word from the format: `at = block.from` then `at += 2`, `back = made - block.byte(at)`
      # on one side of an `if` then `back += 1` in a `block.repeat` below it. This is how a method's
      # locals work in the rest of a game, so a format needs nothing of its own for them: no
      # `game_variables` line in the module (a format has no object for an instance variable to
      # belong to) and no object the kit makes for the routine. `block.variable(:name)` stays for a
      # format written with `store!` and `increase!`, and builds what it built.
      class BlockKit
        def initialize(internals)
          @internals = internals
        end

        def from = @internals.routine_variable(:from)

        def setting(name) = @internals.routine_variable(:"setting_#{name}")

        def variable(name) = @internals.routine_variable(:"format_#{name}")

        def value_of(operand) = @internals.value_of(operand)

        # A list of the routine's own. Every format's lists are named in one space: two formats that
        # name a list alike share it. The Advance's song formats (Packing::M4A) each walk a song with
        # the same lists, kilobytes of them, and a routine that uses several holds them once. So a
        # list of one name at another capacity or width is refused
        # (BlockKitInternals#refuse_list_of_another_shape!).
        def list(name, capacity:, width: :word)
          @internals.refuse_list_of_another_shape!(name, capacity, width)
          @internals.builder.list(@internals.made_name(:"format_#{name}"), capacity: capacity, width: width, full_of: 0)
        end

        def repeat(count, stop_when: nil, &) = @internals.builder.repeat(count, stop_when: stop_when, &)

        # The copy's byte at +at+, with the check before it: a place outside what the block may read
        # (the whole copy, or the one file of it the block was given at) records a fault, which
        # halts the routine (Original::UnpackingFaults). A place worked out from another read
        # of the copy is held first (BlockKitInternals#emit_held_place). In a loop's test, the check
        # runs on every round (Builder#register_statements_for_value).
        def byte(at)
          @internals.builder.register_statements_for_value do
            at = @internals.emit_held_place(at)
            @internals.emit_read_outside_fault(at) if @internals.outside_block_reads(at)
            @internals.copy[at]
          end
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

        # A list a format's routine declared (BlockKit#list): the format and the list's shape.
        ListDeclaration = Data.define(:format_name, :capacity, :width)

        attr_reader :builder, :copy, :pack

        # +before_wait+ names a routine called before each wait for the next frame (a shell's
        # progress bar, Original::UnpackingProgress), or is nil for none.
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
          @held_place_count = 0
          @format_lists = {}
        end

        # +format_name+'s routine built in the block given: the format a list it declares is named
        # by (#refuse_list_of_another_shape!).
        def with_lists_declared_by(format_name)
          @format_building = format_name
          yield
          @format_building = nil
        end

        # A WORKING LIST DECLARED AT A SHAPE ANOTHER DECLARATION OF ITS NAME DID NOT GIVE. Formats
        # share a list of one name, and the build makes the list once, at the first declaration's
        # capacity and width, so a block of a format that declared it bigger would run off its end,
        # or would pass only while a format that declared it smaller runs second.
        def refuse_list_of_another_shape!(name, capacity, width)
          declared = ListDeclaration.new(format_name: @format_building, capacity: capacity, width: width)
          first = (@format_lists[name] ||= declared)
          return if first.capacity == capacity && first.width == width

          raise ArgumentError, list_of_another_shape_message(name, first, declared)
        end

        # +at+, or, where it is worked out from a read of the copy, a variable of its own set to it
        # here, where the read is written.
        #
        # A read is an expression, written out wherever its answer is used, and its check uses its
        # place twice and the read once more. So a read placed by another read's answer held that
        # read whole three times over, and a word read four times, and a routine whose reads place
        # reads (a frame's place read from a table of places, then its bytes) printed text that grew
        # with the square of its reads or worse: megabytes for a few hundred frames, taking seconds
        # to print and to start. Held, the place is a variable, which every printer writes as its
        # name, and the text grows with the routine, not with how deep its reads go.
        #
        # Only such a place is held. A place the routine keeps in a variable or works out from its
        # own numbers is read where the answer is used, as any expression is. A loop's test reads
        # a held place as the expression it holds (Builder#register_held_expression), since the
        # variable is set once, before the loop: so a test whose read is placed by another read
        # (`while copy.byte(copy.byte(at)) != 0`) reads the place afresh each time round, as one
        # placed by a variable does.
        def emit_held_place(at)
          return at unless reads_copy?(at)

          held = @builder.var(made_name(:"place_#{@held_place_count += 1}"), 0)
          held.store!(at)
          @builder.register_held_expression(held.name, value_of(at).node)
          held
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

        # The copy's byte at +at+, outside any block: a place outside the copy records a fault, which
        # halts the routine, as BlockKit#byte does; and the check runs on every round of a loop
        # whose test this is.
        def copy_byte(at)
          @builder.register_statements_for_value do
            at = emit_held_place(at)
            emit_fault(Unpacking::Fault::READ_PAST_END, at, 0) if at < 0 || at >= copy.length
            copy[at]
          end
        end

        # Byte +at+ of +file+ (a FileReader), counted from the file's start, outside any block: a
        # place outside the file records a fault naming the file, which halts the routine. Inside
        # the file is inside the copy, so the copy's own check is not made too.
        def file_byte(at, file)
          @builder.register_statements_for_value do
            at = emit_held_place(at)
            emit_fault(Unpacking::Fault::READ_OUTSIDE_FILE, at, file.number) if at < 0 || at >= file.size
            copy[at + file.start]
          end
        end

        # WHAT A BLOCK MAY READ: from the copy's first byte to its end, or, for a block given its
        # place in one file of a copy that is several (+file+, a FileReader), from that file's first
        # byte to its end. So a block read at a place worked out as it runs cannot read on into the
        # next file. The block's routine checks each read against the two ends (#outside_block_reads),
        # the same two tests whether the block reads the whole copy or one file.
        #
        # What a block is handed, set before its routine is called: each variable of the routine's
        # and what it is set to, in the order they are set (Original::StepTables stores them).
        def block_arguments(at:, slot:, start:, count:, format_number:, file: nil)
          [[routine_variable(:read_first), file ? file.start : 0],
           [routine_variable(:read_ends), file ? file.start + file.size : copy.length],
           # The file's number, 1 first, or 0 for the whole copy.
           [routine_variable(:read_file), file ? file.number + 1 : 0],
           [routine_variable(:from), at],
           [routine_variable(:to), slot.place(start)],
           [routine_variable(:ends), slot.place(slot.byte_size)],
           [routine_variable(:slot_first), slot.place(0)],
           [routine_variable(:slot_number), slot.number],
           [routine_variable(:count), count],
           [routine_variable(:format_number), format_number]]
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

        # Whether +operand+ (a number, a game value or a value node) reads the copy anywhere in it.
        # A node met twice is looked at once, since a value's parts are shared.
        def reads_copy?(operand)
          node = operand.is_a?(DSL::Value) ? operand.node : operand
          return false unless node.is_a?(IR::Node)

          seen = {}.compare_by_identity
          waiting = [node]
          until waiting.empty?
            looked_at = waiting.pop
            next if seen.key?(looked_at)

            seen[looked_at] = true
            return true if looked_at.is_a?(IR::Nodes::TableGet) && looked_at.name.to_sym == Unpacking::COPY

            waiting.concat(looked_at.operand_nodes)
          end
          false
        end

        # Whether the block may not read the copy at +at+ (#block_arguments): a test the routine
        # makes.
        def outside_block_reads(at) = at < routine_variable(:read_first) || at >= routine_variable(:read_ends)

        # The fault for a block's read at +at+ outside what it may read: past the copy, or outside
        # its file, named by the file's number and the place counted from the file's start.
        def emit_read_outside_fault(at)
          file = routine_variable(:read_file)
          if file == 0
            emit_fault(Unpacking::Fault::READ_PAST_END, at, 0)
          else
            emit_fault(Unpacking::Fault::READ_OUTSIDE_FILE, at - routine_variable(:read_first), file - 1)
          end
        end

        # The fault for a write that does not fit: the first byte past the slot's end, in the slot.
        def emit_outside_slot_fault
          emit_fault(Unpacking::Fault::WRITE_OUTSIDE_SLOT, routine_variable(:ends) - routine_variable(:slot_first),
                     routine_variable(:slot_number))
        end

        private

        def list_shape_words(declaration) = "capacity: #{declaration.capacity}, width: :#{declaration.width}"

        def list_of_another_shape_message(name, first, declared)
          if first.format_name == declared.format_name
            return "Format :#{first.format_name} makes the working list :#{name} two times, with " \
                   "#{list_shape_words(first)} and with #{list_shape_words(declared)}. A list has one size. To fix " \
                   "this, give one of the two lists a different name."
          end

          "Formats :#{first.format_name} and :#{declared.format_name} each make a working list :#{name}. " \
            ":#{first.format_name} makes it with #{list_shape_words(first)}. :#{declared.format_name} makes it with " \
            "#{list_shape_words(declared)}. Formats that use one list name share one list, and that list has one size. " \
            "To fix this, give the list a different name in one format, like " \
            "`block.list(:#{declared.format_name}_#{name}, ...)`."
        end
      end
    end
  end
end
