# frozen_string_literal: true

module VBlank
  module Original
    # THE PLAYER'S COPY OF THE ORIGINAL, AS AN UNPACKING ROUTINE READS IT: the `copy` a
    # `slots.fill_from_copy do |copy, pack| ... end` block is handed (Unpacking says where that
    # block runs, and why). Everything here is game code, so it plays the same on every backend.
    #
    #   copy.byte(0x100)                          # one byte, 0 to 255
    #   copy.half(0x100)  copy.word(0x100)        # two and four bytes, low byte first...
    #   copy.half(0x100, big_endian: true)        # ...or high byte first, as a Genesis keeps them
    #   copy.copy_bytes at: 0x200, count: 64, into: pack[:walls]
    #
    # THE PACKED FORMATS are building blocks of their own, a module for each console whose games
    # keep their data in them, in packing/ and mixed in here: the Game Boy Advance's
    # (Packing::GBA), `copy.unpack_lz77` and `copy.unpack_rle`, the BIOS's.
    #
    # The building blocks write into a slot from +start+ (a byte in it, 0 first), and never past its
    # end: a write that would go past is not made, and the build stops saying so (Unpacking::Fault).
    # A read past the end of the copy is the same. Each block is a routine written once in the
    # program however often it is used. It adds what it writes to the count of bytes done as it
    # goes, waiting for the next frame every PROGRESS_BYTES, so a shell can show how far the
    # unpacking has got however big one block is.
    #
    # This file is read as game code (VBlank.require_game_file), so each `if` on a test the routine
    # makes is a branch in the routine. Every variable here is written with `store!` and
    # `increase!`, so what is a variable of the routine's is plain to see.
    class CopyReader
      include Packing::GBA

      # How many bytes a building block writes between one wait for the next frame and the next.
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
        @block_variables = {}
        @block_routines = {}
      end

      # How many bytes the building blocks have written so far, a variable of the routine's.
      def bytes_done = @done

      # The byte at +at+ in the copy, 0 to 255. +at+ may be worked out as the game runs. A place
      # outside the copy is a fault the build stops on.
      def byte(at) = read_byte(at)

      # The two bytes from +at+, low byte first unless +big_endian+.
      def half(at, big_endian: false)
        low = byte(at)
        high = byte(sum_of(at, 1))
        big_endian ? (low << 8) | high : low | (high << 8)
      end

      # The four bytes from +at+, low byte first unless +big_endian+.
      def word(at, big_endian: false)
        first = half(at, big_endian: big_endian)
        second = half(sum_of(at, 2), big_endian: big_endian)
        big_endian ? (first << 16) | second : first | (second << 16)
      end

      # +count+ bytes from +at+ in the copy, as they are, into +into+ (a slot of `pack`) from its
      # byte +start+.
      def copy_bytes(at:, count:, into:, start: 0)
        refuse_unless_slot!(into, "copy_bytes")
        refuse_outside_slot!(into, start, count)
        emit_block_call(:copy, at, into, start, count)
      end

      private

      # A building block for a packed format, which says its own size: checked, then called.
      def unpack_packed_block(kind, at, into, start)
        refuse_unless_slot!(into, "unpack_#{kind}")
        refuse_outside_slot!(into, start, 0)
        emit_block_call(kind, at, into, start, 0)
      end

      def made_name(what) = Messages::MadeNames.make(:unpacking_part, part: what)

      # A variable the building blocks share, made the first time it is asked for: what a block's
      # routine is handed (where to read, where to write, where to stop) and what it works with.
      def block_variable(what)
        @block_variables[what] ||= @builder.var(made_name(what), 0)
      end

      def sum_of(a, b) = a.is_a?(Integer) && b.is_a?(Integer) ? a + b : value_of(a) + b

      def value_of(operand) = operand.is_a?(DSL::Value) ? operand : DSL::Value.new(@builder, DSL::Value.node_for(operand))

      # The copy's byte at +at+, with the check before it: a place outside the copy records a fault
      # and reads a byte of the copy instead, as any table read does.
      def read_byte(at)
        if at.is_a?(Integer)
          @faults.emit_fault(Unpacking::Fault::READ_PAST_END, at, 0) unless at.between?(0, @copy.length - 1)
          return @copy[at]
        end

        @faults.emit_fault(Unpacking::Fault::READ_PAST_END, at, 0) if at < 0 || at >= @copy.length
        @copy[at]
      end

      # One building block: what it is handed set in the blocks' own variables, its routine
      # called, and a wait for the next frame.
      def emit_block_call(kind, at, slot, start, count)
        block_variable(:from).store!(at)
        block_variable(:to).store!(slot.place(start))
        block_variable(:ends).store!(slot.place(slot.byte_size))
        block_variable(:slot_first).store!(slot.place(0))
        block_variable(:slot_number).store!(slot.number)
        block_variable(:count).store!(count)
        @builder.call(define_block_routine(kind))
        emit_wait
        nil
      end

      # A wait for the next frame, with the routine to call before it.
      def emit_wait
        @builder.call(@before_wait) if @before_wait
        @builder.wait_vblank
      end

      def define_block_routine(kind)
        @block_routines[kind] ||= begin
          name = made_name(kind)
          reader = self
          @builder.func(name) { reader.send(:"emit_#{kind}_routine") }
          name
        end
      end

      # Every PROGRESS_BYTES written since +mark+, the count of bytes done moves on and the routine
      # waits for the next frame.
      def emit_progress_step(out, mark)
        if out - mark >= PROGRESS_BYTES
          @done.increase!(out - mark)
          mark.store!(out)
          emit_wait
        end
      end

      # Whether a write of +size+ bytes from +to+ fits between the slot's first byte and +ends+: a
      # test the routine makes, new each time it is asked for.
      def fits_in_slot(to, size, ends) = to >= block_variable(:slot_first) && size <= ends - to

      # The fault for a write of +size+ bytes from +to+ that does not fit: its last byte, in the slot.
      def emit_outside_slot_fault(to, size)
        @faults.emit_fault(Unpacking::Fault::WRITE_OUTSIDE_SLOT, to - block_variable(:slot_first) + size - 1,
                           block_variable(:slot_number))
      end

      def emit_copy_routine
        from = block_variable(:from)
        to = block_variable(:to)
        many = block_variable(:count)
        out = block_variable(:out)
        mark = block_variable(:mark)
        pack = @pack
        if fits_in_slot(to, many, block_variable(:ends))
          out.store!(to)
          mark.store!(to)
          @builder.repeat(many) do |i|
            pack[out] = read_byte(from + i)
            out.increase!(1)
            emit_progress_step(out, mark)
          end
          @done.increase!(out - mark)
        else
          emit_outside_slot_fault(to, many)
        end
      end

      # A block of a format that says how big it unpacks to, +size+ bytes, before it is unpacked,
      # its packed bytes from +first+ in the copy: the room in the slot checked, the reading and
      # writing places set, the format's own loop (the block, handed where it reads and writes and
      # where it stops), and what is left over counted as done.
      def emit_sized_block(size, first)
        to = block_variable(:to)
        ends = block_variable(:ends)
        src = block_variable(:src)
        out = block_variable(:out)
        mark = block_variable(:mark)
        if fits_in_slot(to, size, ends)
          ends.store!(to + size)
          out.store!(to)
          mark.store!(to)
          src.store!(first)
          yield src, out, ends, mark
          @done.increase!(out - mark)
        else
          emit_outside_slot_fault(to, size)
        end
      end

      def refuse_unless_slot!(into, verb)
        return if into.is_a?(SlotBytes)

        raise ArgumentError, "`copy.#{verb}` was given into: #{into.inspect}. It must be given a slot of the pack, " \
                             "like `into: pack[:walls]`."
      end

      def refuse_outside_slot!(into, start, count)
        return unless start.is_a?(Integer) && count.is_a?(Integer)
        return if start.between?(0, into.byte_size - 1) && start + count <= into.byte_size

        raise ArgumentError, "Slot :#{into.slot.name} holds #{into.byte_size} bytes. A write of #{count} bytes from " \
                             "byte #{start} does not fit in it. Correct start: or count:."
      end
    end

    # WHAT WENT WRONG IN AN UNPACKING ROUTINE, kept as it runs: the first fault (Unpacking::Fault)
    # in the program's FAULT_ variables. One that came after is not kept, since it is most often
    # what the first one led to.
    class UnpackingFaults
      def initialize(builder)
        @kind = builder.var(Unpacking::FAULT_KIND, 0)
        @at = builder.var(Unpacking::FAULT_AT, 0)
        @detail = builder.var(Unpacking::FAULT_DETAIL, 0)
      end

      def emit_fault(kind, at, detail)
        if @kind == 0
          @kind.store!(kind)
          @at.store!(at)
          @detail.store!(detail)
        end
      end
    end

    # ONE SLOT OF THE PACK, AS AN UNPACKING ROUTINE WRITES IT: `pack[:walls]` inside
    # `slots.fill_from_copy`. Its bytes are a run of the pack's one list of bytes
    # (Unpacking).
    #
    #   pack[:walls][i] = copy.byte(0x400 + i)   # one byte, the low 8 bits of what is given
    #   pack[:walls][i]                           # one byte back, 0 to 255
    #   pack[:walls].byte_size                    # how many bytes it holds
    #
    # A write outside the slot is not made: a place written in the program is refused, and one
    # worked out as the routine runs is a fault the build stops on.
    class SlotBytes
      # +number+ is the slot's place in the pack's order, 0 first, which a fault names it by.
      def initialize(builder, list, slot, start, number:, faults:)
        @builder = builder
        @list = list
        @slot = slot
        @start = start
        @number = number
        @faults = faults
      end

      # The Slot this writes, and its place in the pack's order.
      attr_reader :slot, :number

      def byte_size = @slot.byte_size

      # Byte +index+ of the slot, 0 to 255.
      def [](index) = @list[place(index)] & 0xFF

      # Byte +index+ of the slot set to the low 8 bits of +value+.
      def []=(index, value)
        return write_fixed_place(index, value) if index.is_a?(Integer)

        if index >= 0 && index < byte_size
          @list[place(index)] = value
        else
          @faults.emit_fault(Unpacking::Fault::WRITE_OUTSIDE_SLOT, index, @number)
        end
      end

      # Where byte +index+ of the slot is in the pack's list.
      def place(index) = index.is_a?(Integer) ? @start + index : DSL::Value.new(@builder, DSL::Value.node_for(index)) + @start

      private

      def write_fixed_place(index, value)
        unless index.between?(0, byte_size - 1)
          raise ArgumentError, "Slot :#{@slot.name} holds bytes 0 to #{byte_size - 1}. There is no byte #{index}."
        end

        @list[@start + index] = value
      end
    end

    # THE PACK'S SLOTS, AS AN UNPACKING ROUTINE WRITES THEM: `pack` inside `slots.fill_from_copy`,
    # a SlotBytes for each slot, by name.
    class UnpackingSlots
      def initialize(writers) = @writers = writers

      def [](name)
        @writers.fetch(name.to_sym) do
          raise ArgumentError, "The data pack has no slot #{name.inspect}. It has #{@writers.keys.map(&:inspect).join(', ')}."
        end
      end
    end
  end
end
