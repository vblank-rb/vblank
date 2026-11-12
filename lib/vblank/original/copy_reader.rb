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
    #   copy.count_written 64                     # what a decoder of the game's own wrote
    #   copy.unpack_lz77 at: 0x300, into: pack[:sprites]   # a packed format the copy offers
    #   copy.file("MAPHEAD.WL6").word(2)          # one file of a copy that is several (FileReader)
    #
    # THE PACKED FORMATS the copy offers are those of the platform its original is for
    # (Packing.formats_for: an Advance original's are LZ77, RLE and the songs of its common sound
    # driver, MusicPlayer2000 (Packing::M4A), a Genesis original's Nemesis and
    # Enigma), and any the port names in
    # `data_pack formats: [...]` (a Packing::Format). Each gives the copy `unpack_<name>`; asking for
    # one the copy does not offer is refused in plain words, naming the ones it does.
    #
    # A one-off layout no format fits, the routine reads and writes itself with `byte` and
    # `pack[slot][i] =`, and says what it wrote with `count_written`, which counts and waits as the
    # formats do.
    #
    # A format writes into a slot from +start+ (a byte in it, 0 first), and never past its end: a
    # write that would go past is not made, and the build stops saying so (Unpacking::Fault). A read
    # past the end of the copy is the same. Each format is a routine written once in the program
    # however often it is used, with the BlockKit every format shares.
    #
    # This file is read as game code (VBlank.require_game_file), so each `if` on a test the routine
    # makes is a branch in the routine.
    class CopyReader
      # The settings every format's verb takes.
      PLACE_SETTINGS = %i[at into start].freeze

      # +formats+ are the formats the copy offers, in the order a fault numbers them; +platform+ is
      # the original's, which a refusal names; +release+ (a Release) is the one unpacked, whose files
      # #file finds. +before_wait+ and +slot_bytes_done+ are BlockKitInternals'.
      def initialize(builder, copy:, pack:, faults:, formats:, platform:, release: nil, before_wait: nil, slot_bytes_done: nil)
        @builder = builder
        @release = release
        @internals = Packing::BlockKitInternals.new(builder, copy: copy, pack: pack, faults: faults, before_wait: before_wait,
                                                             slot_bytes_done: slot_bytes_done)
        @kit = Packing::BlockKit.new(@internals)
        @formats = formats
        @platform = platform
        @block_routines = {}
      end

      # How many bytes have been written so far, a variable of the routine's.
      def bytes_done = @internals.bytes_done

      # The byte at +at+ in the copy, 0 to 255. +at+ may be worked out as the game runs. A place
      # outside the copy is a fault the build stops on.
      def byte(at) = @kit.byte(at)

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
        emit_block_call(:copy, at: at, slot: into, start: start, count: count, format_number: 0) do
          emit_copy_routine
        end
      end

      # For a decoder the game writes itself: +count+ more bytes written, to the slot +into+ (a slot
      # of `pack`). They are added to the count of bytes done, and every PROGRESS_BYTES counted the
      # routine waits for the next frame, as the formats do. +count+ may be worked out as the routine
      # runs. +into+ may be left out unless a slot of the pack names its cost, when a shell's bar
      # needs to know whose work it was.
      def count_written(count, into: nil)
        refuse_count_without_slot! if into.nil? && @internals.counts_each_slot?
        refuse_unless_slot!(into, "count_written") if into
        @internals.count_written(count, into ? into.number : 0)
        nil
      end

      # ONE FILE OF A COPY THAT IS SEVERAL FILES (Release#files), as a FileReader: the same verbs,
      # each place counted from the start of that file. +name+ is the file's name in the release, in
      # any case. The release is known as the routine is built (each release's unpacking is built for
      # it), so where each file starts is a number in the program.
      #
      #   maphead = copy.file("MAPHEAD.#{release}")
      #   copy.file("GAMEMAPS.#{release}").copy_bytes at: maphead.word(2), count: 42, into: pack[:level]
      def file(name)
        unless @release&.several_files?
          raise ArgumentError, "`copy.file(#{name.inspect})` is for a copy that is a folder of files. " \
                               "This copy is one file. Read it with `copy.byte` and the rest."
        end

        start, release_file = @release.file_place(name)
        unless release_file
          raise ArgumentError, "The #{@release.name} release holds no file #{name}. It holds " \
                               "#{@release.files.map(&:name).join(', ')}."
        end

        FileReader.new(self, start: start, file: release_file)
      end

      # +at+ moved on by +by+ bytes: a number, or a value worked out as the routine runs.
      def place_after(at, by) = sum_of(at, by)

      # What a person calls each format the copy offers, in the order a fault numbers them.
      def format_words = @formats.map(&:format_words)

      # The block at +settings+' at: unpacked by the format called +format_name+, which the copy must
      # offer: what `copy.unpack_<name>` does.
      def unpack(format_name, **settings)
        format = @formats.find { |offered| offered.format_name == format_name }
        refuse_format_not_offered!(format_name) unless format
        unpack_with(format, **settings)
      end

      # `unpack_<name>` for each format the copy offers. A verb of the game's for each format, named
      # by the formats it is handed, so it is answered here and not written out; each one is #unpack.
      def method_missing(name, *given, **settings, &)
        asked = format_asked(name)
        return super unless asked

        refuse_positional_arguments!(name, given)
        unpack(asked, **settings)
      end

      def respond_to_missing?(name, include_private = false)
        asked = format_asked(name)
        (asked && @formats.any? { |offered| offered.format_name == asked }) || super
      end

      # A format's verb takes its places by name; one given +given+ in order is refused (FileReader asks too).
      def refuse_positional_arguments!(name, given)
        return if given.empty?

        raise ArgumentError, "`copy.#{name}` takes at:, into: and start:, like `copy.#{name} at: 0x400, into: pack[:walls]`."
      end

      private

      def format_asked(name) = name.to_s.start_with?("unpack_") ? name.to_s.delete_prefix("unpack_").to_sym : nil

      # A block of +format+, given +settings+: checked, its settings stored for its routine, then called.
      def unpack_with(format, **settings)
        verb = "unpack_#{format.format_name}"
        refuse_unknown_settings!(verb, format, settings)
        refuse_missing_places!(verb, settings)
        into = settings.fetch(:into)
        start = settings.fetch(:start, 0)
        refuse_unless_slot!(into, verb)
        refuse_outside_slot!(into, start, 0)
        format.format_settings.each { |name, default| @kit.setting(name).store!(settings.fetch(name, default)) }
        emit_block_call(:"unpack_#{format.format_name}", at: settings.fetch(:at), slot: into, start: start, count: 0,
                                                         format_number: @formats.index(format)) do
          format.routine(@kit)
        end
      end

      # One block: what it is handed set in the kit's variables, its routine called (made the first
      # time, from the block given), and a wait for the next frame.
      def emit_block_call(routine_name, at:, slot:, start:, count:, format_number:, &routine)
        @internals.emit_block_arguments(at: at, slot: slot, start: start, count: count, format_number: format_number)
        @builder.call(define_block_routine(routine_name, &routine))
        @internals.emit_wait
        nil
      end

      def define_block_routine(routine_name, &routine)
        @block_routines[routine_name] ||= begin
          name = @internals.made_name(routine_name)
          internals = @internals
          @builder.func(name) do
            internals.emit_block_start
            routine.call
            internals.emit_block_end
          end
          name
        end
      end

      def emit_copy_routine
        from = @kit.from
        @kit.expect_size(@internals.routine_variable(:count))
        @kit.repeat(@internals.routine_variable(:count), stop_when: @kit.finished) { |i| @kit.write(@kit.byte(from + i)) }
      end

      def sum_of(a, b) = a.is_a?(Integer) && b.is_a?(Integer) ? a + b : @internals.value_of(a) + b

      def refuse_format_not_offered!(asked)
        offered = @formats.empty? ? "no packed formats" : "the formats #{@formats.map(&:format_name).join(', ')}"
        home = Packing.platform_with(asked)
        whose = home ? "#{asked} is a format of #{platform_title(home)} games. " : "No format is called #{asked}. "
        raise ArgumentError, "`copy.unpack_#{asked}` is not a format this copy offers. The copy is of an original for " \
                             "the #{platform_title(@platform)}, and it offers #{offered}. #{whose}" \
                             "To use another format, name its module in `data_pack formats: [...]`."
      end

      def platform_title(platform) = platform == COMPUTER ? "computer" : Console.for(platform).title

      def refuse_missing_places!(verb, settings)
        missing = %i[at into] - settings.keys
        return if missing.empty?

        raise ArgumentError, "`copy.#{verb}` needs #{missing.map { |name| "#{name}:" }.join(' and ')}, like " \
                             "`copy.#{verb} at: 0x400, into: pack[:walls]`."
      end

      def refuse_unknown_settings!(verb, format, settings)
        unknown = settings.keys - PLACE_SETTINGS - format.format_settings.keys
        return if unknown.empty?

        takes = (PLACE_SETTINGS + format.format_settings.keys).map { |name| "#{name}:" }.join(", ")
        raise ArgumentError, "`copy.#{verb}` was given #{unknown.map { |name| "#{name}:" }.join(', ')}. It takes #{takes}."
      end

      def refuse_count_without_slot!
        raise ArgumentError, "`copy.count_written` names no slot. A slot of this data pack has a cost:, so the " \
                             "progress bar counts the bytes of each slot. Add the slot: `copy.count_written 256, into: pack[:music]`."
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

    # ONE FILE OF A COPY THAT IS SEVERAL FILES, as an unpacking routine reads it (CopyReader#file):
    # each verb of the copy's, with its places counted from the start of the file. A place written in
    # the program that is outside the file is refused; one worked out as the routine runs is held to
    # the whole copy, as every read is.
    class FileReader
      # The ReleaseFile read, and where it starts in the copy.
      attr_reader :file, :start

      def initialize(reader, start:, file:)
        @reader = reader
        @start = start
        @file = file
      end

      # How many bytes the file holds.
      def size = @file.size

      def byte(at) = @reader.byte(place(at))

      def half(at, big_endian: false) = @reader.half(place(at, 2), big_endian: big_endian)

      def word(at, big_endian: false) = @reader.word(place(at, 4), big_endian: big_endian)

      def copy_bytes(at:, count:, into:, start: 0) = @reader.copy_bytes(at: place(at, count.is_a?(Integer) ? count : 1), count: count, into: into, start: start)

      # The block at +settings+' at:, counted from the start of this file, unpacked by +format_name+.
      def unpack(format_name, **settings)
        settings[:at] = place(settings[:at]) if settings.key?(:at)
        @reader.unpack(format_name, **settings)
      end

      # `unpack_<name>` for each format the copy offers, from a place in this file (CopyReader#method_missing).
      def method_missing(name, *given, **settings, &)
        return super unless name.to_s.start_with?("unpack_") && @reader.respond_to?(name)

        @reader.refuse_positional_arguments!(name, given)
        unpack(name.to_s.delete_prefix("unpack_").to_sym, **settings)
      end

      def respond_to_missing?(name, include_private = false) = (name.to_s.start_with?("unpack_") && @reader.respond_to?(name)) || super

      private

      # Where +at+ in the file is in the copy; a fixed +at+ whose +bytes+ run past the file is refused.
      def place(at, bytes = 1)
        if at.is_a?(Integer) && !(at >= 0 && at + bytes <= size)
          raise ArgumentError, "#{@file.name} holds bytes 0 to #{size - 1}. A read of #{bytes} byte#{'s' if bytes > 1} " \
                               "from byte #{at} is outside it. Correct the place read."
        end

        @reader.place_after(at, @start)
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
    #   pack[:homes][wall] = cell                 # on a slot of halves or words, one whole number
    #   pack[:walls].byte_size                    # how many bytes it holds
    #
    # A write outside the slot is not made: a place written in the program is refused, and one
    # worked out as the routine runs is a fault the build stops on. A read at a place written in
    # the program is refused the same way.
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

      # Item +index+ of the slot. A slot of numbers wider than a byte reads number +index+, put
      # together from its bytes in the slot's layout and below zero where a slot of halves is
      # signed; any other slot reads byte +index+, 0 to 255. A word is four bytes, the whole of a
      # game's number, so it reads as one whether the slot is signed or not: above 2147483647 it
      # reads below zero, as any game number does.
      def [](index)
        refuse_item_outside_slot!(index) if index.is_a?(Integer)
        return @list[place(index)] & 0xFF unless wide_numbers?

        number = slot_bytes_lowest_first.each_with_index.map do |offset, step|
          (@list[place(number_byte(index, offset))] & 0xFF) << (8 * step)
        end.reduce(:|)
        @slot.signed && @slot.item_bytes == 2 ? (number ^ 0x8000) - 0x8000 : number
      end

      # Item +index+ of the slot set to +value+. A slot of numbers wider than a byte takes number
      # +index+, written over its bytes in the slot's layout; any other slot takes the low 8 bits
      # into byte +index+. A copy's formats write bytes, from #place, whatever the slot holds.
      def []=(index, value)
        return write_number(index, value) if wide_numbers?
        return write_fixed_place(index, value) if index.is_a?(Integer)

        write_or_emit_fault(index, byte_size, index) { @list[place(index)] = value }
      end

      # CELL +index+ OF A SLOT OF MAP CELLS written as a MapCell record: its +tile+, counted from the
      # first tile of the background's `tiles:`, its +bank+ of colours, and whether it is +mirrored+
      # and +upside_down+ (true or false, or a number whose lowest bit says). Each may be a number or
      # a value the routine works out, as +index+ may:
      #
      #   pack[:title_map].write_cell(at, tile: number, bank: attributes & 7, mirrored: attributes >> 5,
      #                                   upside_down: attributes >> 6)
      def write_cell(index, tile:, bank: 0, mirrored: false, upside_down: false)
        refuse_cell_of_another_shape!
        bytes = MapCell.bytes(tile: tile, bank: bank, mirrored: mirrored, upside_down: upside_down)
        if index.is_a?(Integer)
          refuse_item_outside_slot!(index, [@slot.count, "cell"])
          return bytes.each_with_index { |byte, at| @list[@start + (index * MapCell::BYTES) + at] = byte }
        end

        write_or_emit_fault(index, @slot.count, index * MapCell::BYTES) do
          bytes.each_with_index { |byte, at| @list[place((index * MapCell::BYTES) + at)] = byte }
        end
      end

      # Where byte +index+ of the slot is in the pack's list.
      def place(index) = index.is_a?(Integer) ? @start + index : DSL::Value.new(@builder, DSL::Value.node_for(index)) + @start

      private

      # A numbers slot of halves or words: the routine writes and reads a number at a time.
      def wide_numbers? = @slot.shape == :numbers && @slot.item_bytes > 1

      # Where in a number its bytes are kept, as offsets from the number's first byte, the offset
      # of its lowest byte first: on a layout that keeps the high byte first (the Genesis's), the
      # lowest is the last of the number's bytes.
      def slot_bytes_lowest_first
        offsets = (0...@slot.item_bytes).to_a
        @slot.format.high_byte_first ? offsets.reverse : offsets
      end

      # Byte +offset+ of number +index+, counted from the slot's first byte.
      def number_byte(index, offset) = (index * @slot.item_bytes) + offset

      def write_number(index, value)
        if index.is_a?(Integer)
          refuse_item_outside_slot!(index)
          return write_number_bytes(index, value)
        end

        write_or_emit_fault(index, @slot.count, index * @slot.item_bytes) { write_number_bytes(index, value) }
      end

      def write_number_bytes(index, value)
        slot_bytes_lowest_first.each_with_index do |offset, step|
          @list[place(number_byte(index, offset))] = step.zero? ? value : value >> (8 * step)
        end
      end

      # The write the block makes, when +index+ is 0 or more and below +items+ (the slot's bytes, or
      # its numbers) as the routine runs; otherwise the fault that stops the build, naming +byte+,
      # the first byte the write reached.
      def write_or_emit_fault(index, items, byte)
        if index >= 0 && index < items
          yield
        else
          @faults.emit_fault(Unpacking::Fault::WRITE_OUTSIDE_SLOT, byte, @number)
        end
      end

      # A place written in the program, past the slot: a number on a slot of halves or words, a byte
      # on any other.
      # +counted+ is how many items the slot holds and what one is called, where it is not its numbers
      # or its bytes (a slot of map cells' cells).
      def refuse_item_outside_slot!(index, counted = nil)
        items, kind = counted || (wide_numbers? ? [@slot.count, "number"] : [byte_size, "byte"])
        return if index.between?(0, items - 1)

        raise ArgumentError, "Slot :#{@slot.name} holds #{kind}s 0 to #{items - 1}. There is no #{kind} #{index}. " \
                             "To fix this, use a #{kind} from 0 to #{items - 1}, or make the slot's count: bigger."
      end

      def refuse_cell_of_another_shape!
        return if @slot.shape == :map_cells

        raise ArgumentError, "The unpacking calls `write_cell` on slot :#{@slot.name}, which holds #{@slot.shape}. " \
                             "`write_cell` writes a cell of a slot of map cells. To fix this, make the slot like " \
                             "`slots.map_cells :#{@slot.name}, count: 1024`."
      end

      def write_fixed_place(index, value)
        refuse_item_outside_slot!(index)
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
