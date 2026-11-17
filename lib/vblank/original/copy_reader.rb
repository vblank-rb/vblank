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
      # #file finds. +before_wait+ and +slot_bytes_done+ are BlockKitInternals'. +building+ is the
      # UnpackingPartBuilding the routine's parts are built in (nil for none), which #bytes_done asks.
      def initialize(builder, copy:, pack:, faults:, formats:, platform:, release: nil, before_wait: nil, slot_bytes_done: nil,
                     building: nil)
        @builder = builder
        @building = building
        @release = release
        @internals = Packing::BlockKitInternals.new(builder, copy: copy, pack: pack, faults: faults, before_wait: before_wait,
                                                             slot_bytes_done: slot_bytes_done)
        @kit = Packing::BlockKit.new(@internals)
        @formats = formats
        @platform = platform
        @block_routines = {}
      end

      # How many bytes have been written so far, a variable of the routine's. The count runs on
      # from one part of the routine to the next, so only the first part may read it
      # (UnpackingPartBuilding#refuse_bytes_done_in_later_part!).
      def bytes_done
        @building&.refuse_bytes_done_in_later_part!
        @internals.bytes_done
      end

      # The byte at +at+ in the copy, 0 to 255. +at+ may be worked out as the game runs. A place
      # outside the copy is a fault the build stops on.
      def byte(at) = @internals.copy_byte(at)

      # The two bytes from +at+, low byte first unless +big_endian+. A place worked out from another
      # read is held once for all its bytes (BlockKitInternals#emit_held_place).
      def half(at, big_endian: false) = join_half(hold_place(at), big_endian) { |place| byte(place) }

      # The four bytes from +at+, low byte first unless +big_endian+.
      def word(at, big_endian: false) = join_word(hold_place(at), big_endian) { |place| half(place, big_endian: big_endian) }

      # The half at +at+ (a held place) made of the bytes the block reads at +at+ and the place
      # after, low byte first unless +big_endian+; and the word made of the halves it reads. What
      # CopyReader and FileReader read with, each giving its own reads.
      def join_half(at, big_endian)
        low = yield at
        high = yield sum_of(at, 1)
        big_endian ? (low << 8) | high : low | (high << 8)
      end

      def join_word(at, big_endian)
        first = yield at
        second = yield sum_of(at, 2)
        big_endian ? (first << 16) | second : first | (second << 16)
      end

      # +at+, or a variable holding it where it is worked out from a read of the copy
      # (BlockKitInternals#emit_held_place). FileReader asks, holding its places too.
      def hold_place(at) = @internals.emit_held_place(at)

      # Byte +at+ of +file+ (a FileReader), at a place the routine works out as it runs, checked
      # against the file (BlockKitInternals#file_byte). FileReader asks.
      def file_byte(at, file) = @internals.file_byte(at, file)

      # +count+ bytes from +at+ in the copy, as they are, into +into+ (a slot of `pack`) from its
      # byte +start+.
      def copy_bytes(at:, count:, into:, start: 0) = copy_bytes_within(nil, at: at, count: count, into: into, start: start)

      # #copy_bytes, its reads held to +file+ (a FileReader, +at+ a place in the copy), or to the
      # whole copy for nil. FileReader asks.
      def copy_bytes_within(file, at:, count:, into:, start: 0)
        refuse_unless_slot!(into, "copy_bytes")
        refuse_outside_slot!(into, start, count)
        emit_block_call(:copy, at: at, slot: into, start: start, count: count, format_number: 0, file: file) do
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

        FileReader.new(self, start: start, file: release_file, number: @release.files.index(release_file))
      end

      # +at+ moved on by +by+ bytes: a number, or a value worked out as the routine runs.
      def place_after(at, by) = sum_of(at, by)

      # What a person calls each format the copy offers, in the order a fault numbers them.
      def format_words = @formats.map(&:format_words)

      # The block at +settings+' at: unpacked by the format called +format_name+, which the copy must
      # offer: what `copy.unpack_<name>` does.
      def unpack(format_name, **settings) = unpack_within(nil, format_name, **settings)

      # #unpack, its reads held to +file+ (a FileReader, at: a place in the copy), or to the whole
      # copy for nil. FileReader asks.
      def unpack_within(file, format_name, **settings)
        format = @formats.find { |offered| offered.format_name == format_name }
        refuse_format_not_offered!(format_name) unless format
        unpack_with(format, file, **settings)
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
      def unpack_with(format, file, **settings)
        verb = "unpack_#{format.format_name}"
        refuse_unknown_settings!(verb, format, settings)
        refuse_missing_places!(verb, settings)
        into = settings.fetch(:into)
        start = settings.fetch(:start, 0)
        refuse_unless_slot!(into, verb)
        refuse_outside_slot!(into, start, 0)
        format.format_settings.each { |name, default| @kit.setting(name).store!(settings.fetch(name, default)) }
        emit_block_call(:"unpack_#{format.format_name}", at: settings.fetch(:at), slot: into, start: start, count: 0,
                                                         format_number: @formats.index(format), file: file) do
          @internals.with_lists_declared_by(format.format_name) { format.routine(@kit) }
        end
      end

      # One block: what it is handed set in the kit's variables, its routine called (made the first
      # time, from the block given), and a wait for the next frame. Its reads are held to +file+ (a
      # FileReader), or to the whole copy for nil.
      #
      # Every block writes +slot+, so the write is recorded here, where each one is built: a verb
      # added later cannot leave it out (SlotUses, which the pack cache's parts read).
      def emit_block_call(routine_name, at:, slot:, start:, count:, format_number:, file: nil, &routine)
        slot.record_write
        @internals.emit_block_arguments(at: at, slot: slot, start: start, count: count, format_number: format_number,
                                        file: file)
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

      def platform_title(platform)
        return "computer" if platform == COMPUTER

        Console::KITS.key?(platform) ? Console.for(platform).title : platform.to_s
      end

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
        # A piece's size is known only as the routine runs (PieceBytes), which checks it then.
        return unless start.is_a?(Integer) && count.is_a?(Integer) && into.byte_size.is_a?(Integer)
        return if start.between?(0, into.byte_size - 1) && start + count <= into.byte_size

        raise ArgumentError, "Slot :#{into.slot.name} holds #{into.byte_size} bytes. A write of #{count} bytes from " \
                             "byte #{start} does not fit in it. Correct start: or count:."
      end
    end

    # ONE FILE OF A COPY THAT IS SEVERAL FILES, as an unpacking routine reads it (CopyReader#file):
    # each verb of the copy's, with its places counted from the start of the file. A place written in
    # the program that is outside the file is refused as the routine is built. One worked out as the
    # routine runs is held to the file as it runs: a read outside it is the fault
    # Unpacking::Fault::READ_OUTSIDE_FILE, which names the file and the first byte read outside it,
    # and never a read of the next file. A fixed place costs no test as the routine runs beyond the
    # one every read of the copy makes.
    class FileReader
      # The ReleaseFile read, where it starts in the copy, and its number in the release's list of
      # files, 0 first, which a fault names it by.
      attr_reader :file, :start, :number

      def initialize(reader, start:, file:, number:)
        @reader = reader
        @start = start
        @file = file
        @number = number
      end

      # How many bytes the file holds.
      def size = @file.size

      def byte(at) = at.is_a?(Integer) ? @reader.byte(place(at)) : @reader.file_byte(at, self)

      def half(at, big_endian: false)
        return @reader.half(place(at, 2), big_endian: big_endian) if at.is_a?(Integer)

        @reader.join_half(@reader.hold_place(at), big_endian) { |held| byte(held) }
      end

      def word(at, big_endian: false)
        return @reader.word(place(at, 4), big_endian: big_endian) if at.is_a?(Integer)

        @reader.join_word(@reader.hold_place(at), big_endian) { |held| half(held, big_endian: big_endian) }
      end

      def copy_bytes(at:, count:, into:, start: 0)
        @reader.copy_bytes_within(self, at: place(at, count.is_a?(Integer) ? count : 1), count: count, into: into, start: start)
      end

      # The block at +settings+' at:, counted from the start of this file, unpacked by +format_name+.
      def unpack(format_name, **settings)
        settings[:at] = place(settings[:at]) if settings.key?(:at)
        @reader.unpack_within(self, format_name, **settings)
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

    # WHAT WENT WRONG IN AN UNPACKING ROUTINE: the first fault (Unpacking::Fault), kept in the
    # program's FAULT_ variables, and the routine halted there. Nothing after a fault is worth
    # running, since the build stops on it (Builder::DataPacks#refuse_faulted_or_unfinished_unpacking!),
    # and running on is what lets a loop whose only way out was the byte it could not read go
    # round for ever: a `while` reading the copy up to a 0 the copy does not hold reads on past its
    # end on every round, and without the halt would never wait or end.
    class UnpackingFaults
      def initialize(builder)
        @builder = builder
        @kind = builder.var(Unpacking::FAULT_KIND, 0)
        @at = builder.var(Unpacking::FAULT_AT, 0)
        @detail = builder.var(Unpacking::FAULT_DETAIL, 0)
      end

      def emit_fault(kind, at, detail)
        @kind.store!(kind)
        @at.store!(at)
        @detail.store!(detail)
        @builder.halt
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
      # +building+ is the UnpackingPartBuilding the routine's parts are built in, which a pieced
      # part's refusals ask (nil for none).
      def initialize(builder, list, slot, start, number:, faults:, building: nil)
        @builder = builder
        @list = list
        @slot = slot
        @start = start
        @number = number
        @faults = faults
        @building = building
      end

      # The Slot this writes, and its place in the pack's order.
      attr_reader :slot, :number

      # The SlotUses this slot's reads and writes are recorded in as the routine is built, or nil
      # for none (UnpackingSlots#record_uses_in).
      attr_writer :uses

      # Record that the routine reads this slot, or writes it (a copy's verb given it as into:
      # writes it too). A part in pieces reads and writes its own piece alone, so a whole slot used
      # there is refused (UnpackingPartBuilding#refuse_slot_in_pieced_part!).
      def record_read
        @building&.refuse_slot_in_pieced_part!(@slot.name, "reads")
        @uses&.record_read(@slot.name)
      end

      def record_write
        @building&.refuse_slot_in_pieced_part!(@slot.name, "writes")
        @uses&.record_write(@slot.name)
      end

      def byte_size = @slot.byte_size

      # Item +index+ of the slot. A slot of numbers wider than a byte reads number +index+, put
      # together from its bytes in the slot's layout and below zero where a slot of halves is
      # signed; any other slot reads byte +index+, 0 to 255. A word is four bytes, the whole of a
      # game's number, so it reads as one whether the slot is signed or not: above 2147483647 it
      # reads below zero, as any game number does.
      def [](index)
        refuse_item_outside_slot!(index) if index.is_a?(Integer)
        return load_byte(index) & 0xFF unless wide_numbers?

        number = slot_bytes_lowest_first.each_with_index.map do |offset, step|
          (load_byte(number_byte(index, offset)) & 0xFF) << (8 * step)
        end.reduce(:|)
        @slot.signed && @slot.item_bytes == 2 ? (number ^ 0x8000) - 0x8000 : number
      end

      # Item +index+ of the slot set to +value+. A slot of numbers wider than a byte takes number
      # +index+, written over its bytes in the slot's layout; any other slot takes the low 8 bits
      # into byte +index+. A copy's formats write bytes, from #place, whatever the slot holds.
      def []=(index, value)
        return write_number(index, value) if wide_numbers?
        return write_fixed_place(index, value) if index.is_a?(Integer)

        write_or_emit_fault(index, byte_size, index) { store_byte(index, value) }
      end

      # CELL +index+ OF A SLOT OF MAP CELLS written as a MapCell record: its +tile+, counted from the
      # first tile of the background's `tiles:`, its +bank+ of colours, whether it is +mirrored+ and
      # +upside_down+, and whether it is +in_front+ of the sprites (each true or false, or a number
      # whose lowest bit says; the last read only by a background that asks, `cells_in_front: true`).
      # Each may be a number or a value the routine works out, as +index+ may:
      #
      #   pack[:title_map].write_cell(at, tile: number, bank: attributes & 7, mirrored: attributes >> 5,
      #                                   upside_down: attributes >> 6, in_front: attributes >> 7)
      #
      # A tile past 65535 or a bank past 255 written as a number is refused, since the record would
      # keep only its low bits. One the routine works out keeps them.
      def write_cell(index, tile:, bank: 0, mirrored: false, upside_down: false, in_front: false)
        refuse_cell_of_another_shape!
        cell = index.is_a?(Integer) ? "cell #{index}" : "a cell"
        MapCell.refuse_oversized_part!("The unpacking writes #{cell} of slot :#{@slot.name} with", tile: tile, bank: bank)
        bytes = MapCell.bytes(tile: tile, bank: bank, mirrored: mirrored, upside_down: upside_down, in_front: in_front)
        if index.is_a?(Integer)
          refuse_item_outside_slot!(index, [@slot.count, "cell"])
          return bytes.each_with_index { |byte, at| store_byte((index * MapCell::BYTES) + at, byte) }
        end

        write_or_emit_fault(index, item_count, index * MapCell::BYTES) do
          bytes.each_with_index { |byte, at| store_byte((index * MapCell::BYTES) + at, byte) }
        end
      end

      # COLOUR +index+ OF A SLOT OF COLOURS, written in the slot's layout from its +red+, +green+
      # and +blue+, each +bits+ bits deep as the original keeps them (8 for a byte a channel, 6 for a
      # computer's video card, 5 for the PlayStation's). A channel deeper than the layout's keeps its
      # top bits; one shallower is widened, its bits repeated, so its brightest is the layout's.
      # Each may be a number or a value the routine works out, as +index+ may:
      #
      #   pack[:palette].write_color(at, red: copy.byte(at * 3), green: copy.byte((at * 3) + 1),
      #                                  blue: copy.byte((at * 3) + 2), bits: 6)
      #
      # A channel written as a number past +bits+ is refused. One the routine works out keeps its
      # low +bits+ bits.
      def write_color(index, red:, green:, blue:, bits: 8)
        refuse_color_of_another_shape!
        refuse_channel_bits_out_of_range!(bits)
        refuse_channels_past_bits!(index, bits, red: red, green: green, blue: blue)
        format = @slot.format
        number = combine_bits([[red, format.red_at], [green, format.green_at], [blue, format.blue_at]]
                                .map { |channel, at| scale_channel(channel, bits, format.channel_bits) << at })
        low_high = [number, number >> 8]
        bytes = format.high_byte_first ? low_high.reverse : low_high
        if index.is_a?(Integer)
          refuse_item_outside_slot!(index, [@slot.count, "color"])
          return bytes.each_with_index { |byte, at| store_byte((index * Slot::COLOR_BYTES) + at, byte) }
        end

        write_or_emit_fault(index, item_count, index * Slot::COLOR_BYTES) do
          bytes.each_with_index { |byte, at| store_byte((index * Slot::COLOR_BYTES) + at, byte) }
        end
      end

      # Where byte +index+ of the slot is in the pack's list.
      def place(index) = index.is_a?(Integer) ? @start + index : DSL::Value.new(@builder, DSL::Value.node_for(index)) + @start

      private

      # How many items the slot holds: its colours, cells or numbers (a piece's, as the routine runs).
      def item_count = @slot.count

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

        write_or_emit_fault(index, item_count, index * @slot.item_bytes) { write_number_bytes(index, value) }
      end

      def write_number_bytes(index, value)
        slot_bytes_lowest_first.each_with_index do |offset, step|
          store_byte(number_byte(index, offset), step.zero? ? value : value >> (8 * step))
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

      # The most bits a channel of a colour is written with: a byte's.
      MOST_CHANNEL_BITS = 8

      # +channel+, +bits+ deep, scaled to a channel +depth+ bits deep: its top bits where it is deeper, and
      # its bits repeated where it is shallower, as a console widens a colour it shows (Console::ColorFormat).
      # The value of a sum the routine works out keeps its low +bits+ bits first.
      def scale_channel(channel, bits, depth)
        channel &= (1 << bits) - 1 unless channel.is_a?(Integer)
        return channel if bits == depth
        return channel >> (bits - depth) if bits > depth

        shifts = (depth - bits).step(-bits + 1, -bits).to_a
        combine_bits(shifts.map { |shift| shift.zero? ? channel : shift.positive? ? channel << shift : channel >> -shift })
      end

      # +parts+ joined by a bitwise or. A value the routine works out goes first, so the or is the
      # value's (DSL::Value#|) and not a number's.
      def combine_bits(parts) = parts.sort_by { |part| part.is_a?(Integer) ? 1 : 0 }.reduce(:|)

      def refuse_channel_bits_out_of_range!(bits)
        return if bits.is_a?(Integer) && bits.between?(1, MOST_CHANNEL_BITS)

        raise ArgumentError, "The unpacking writes a color of slot :#{@slot.name} with bits: #{bits.inspect}. bits: is " \
                             "how many bits a channel of the original's color has. To fix this, give a number from 1 " \
                             "to #{MOST_CHANNEL_BITS}."
      end

      def refuse_channels_past_bits!(index, bits, **channels)
        most = (1 << bits) - 1
        channels.each do |part, given|
          next unless given.is_a?(Integer) && !given.between?(0, most)

          color = index.is_a?(Integer) ? "color #{index}" : "a color"
          raise ArgumentError, "The unpacking writes #{color} of slot :#{@slot.name} with #{part} #{given}. A channel of " \
                               "#{bits} bits holds 0 to #{most}. To fix this, give a #{part} from 0 to #{most}, or set " \
                               "bits: to the number of bits a channel of the original's colors has."
        end
      end

      def refuse_color_of_another_shape!
        return if @slot.shape == :colors

        raise ArgumentError, "The unpacking calls `write_color` on slot :#{@slot.name}, which holds #{@slot.shape}. " \
                             "`write_color` writes a color of a slot of colors. To fix this, make the slot like " \
                             "`slots.colors :#{@slot.name}, count: 16`."
      end

      def refuse_cell_of_another_shape!
        return if @slot.shape == :map_cells

        raise ArgumentError, "The unpacking calls `write_cell` on slot :#{@slot.name}, which holds #{@slot.shape}. " \
                             "`write_cell` writes a cell of a slot of map cells. To fix this, make the slot like " \
                             "`slots.map_cells :#{@slot.name}, count: 1024`."
      end

      def write_fixed_place(index, value)
        refuse_item_outside_slot!(index)
        store_byte(index, value)
      end

      # EVERY BYTE OF THE SLOT IS READ AND WRITTEN HERE, so the read or the write is recorded where
      # it is built (#record_read, #record_write, which the pack cache's parts read), and a way of
      # writing added later cannot leave it out. A copy's formats write through the routine their
      # block calls, which records its slot (CopyReader#emit_block_call). +at+ is a byte of the
      # slot, 0 first, a number or a value the routine works out; the place in the pack's list is
      # worked out once the use is recorded, so a slot in pieces refuses first (PiecedSlotBytes).
      def load_byte(at)
        record_read
        @list[place(at)]
      end

      def store_byte(at, value)
        record_write
        @list[place(at)] = value
      end
    end

    # A SLOT IN PIECES, AS AN UNPACKING ROUTINE WRITES IT: `pack[:music]` inside
    # `slots.fill_from_copy :music, pieces: 27 do ... end`, which is written a piece at a time,
    # `pack[:music].piece(song)[i] = sample`, the piece a SlotBytes of its own (PieceBytes) whose
    # items count from the piece's first. The slot itself is never read or written whole: a part in
    # pieces writes the pieces, and no other part reads them (PiecedUnpacking says why).
    #
    # THE PIECE IS ONE THE ROUTINE WORKS OUT AS IT RUNS: the part's block is built once, handed the
    # piece's number as a game value, so its code is in the program once however many pieces it
    # has. Where each piece starts in the program's list, and how many items it holds, are two
    # tables the piece's number reads (+piece_places+, a place for every piece, by its number; a
    # number where every piece starts at the same place). The whole routine holds every piece; a
    # program of a part's pieces holds one at a time, from its list's first byte
    # (Builder::DataPacks#unpacking_program).
    class PiecedSlotBytes < SlotBytes
      def initialize(builder, list, slot, piece_places, number:, faults:, building:)
        super(builder, list, slot, nil, number: number, faults: faults, building: building)
        @piece_places = piece_places
        @pieces = {}.compare_by_identity
      end

      # THE PIECE the part's block is handed (+number+, the game value it is given), a PieceBytes.
      def piece(number)
        @building.refuse_piece_not_its_own!(@slot, number)
        @pieces[number] ||= PieceBytes.new(@builder, @list, @slot.piece_shape, read_by(:at, @piece_places, number),
                                           read_by(:items, @slot.pieces, number), number: @number, faults: @faults,
                                           whole: self)
      end

      # The piece writes its own slot's name: a part writes the slot it writes a piece of.
      def record_piece_read = @uses&.record_read(@slot.name)
      def record_piece_write = @uses&.record_write(@slot.name)

      def record_read = @building.refuse_whole_pieced_slot!(@slot, "reads")
      def record_write = @building.refuse_whole_pieced_slot!(@slot, "writes")

      private

      # The entry of +entries+ (one for each piece) for piece +number+: a number where every piece's
      # is the same, else a read of a table of them, which the build makes once.
      def read_by(what, entries, number)
        return entries.first if entries.uniq.one?

        table = @builder.table(Messages::MadeNames.make(:unpacking_part, part: :"piece_#{what}_#{@number}"), entries,
                               width: :word, signed: false)
        table[number]
      end
    end

    # ONE PIECE OF A SLOT IN PIECES (PiecedSlotBytes#piece): a SlotBytes over the piece's bytes,
    # numbered as its slot, so a fault or a count of bytes done names the slot. +slot+ is the
    # piece's shape (Slot#piece_shape), +start+ where it starts in the list and +items+ how many
    # it holds, each a number or a value the routine works out. +whole+ is the PiecedSlotBytes whose
    # piece it is, which records its reads and writes.
    #
    # Pieces differ in size, so a place written as a number cannot be checked as the routine is
    # built: every place is checked as it runs, and one outside the piece is the fault the build
    # stops on, as a place worked out as the routine runs always is.
    class PieceBytes < SlotBytes
      def initialize(builder, list, slot, start, items, number:, faults:, whole:)
        super(builder, list, slot, start, number: number, faults: faults)
        @items = items
        @whole = whole
      end

      def record_read = @whole.record_piece_read
      def record_write = @whole.record_piece_write

      # How many bytes the piece holds, as the routine runs.
      def byte_size = @items * @slot.item_bytes

      def [](index) = super(as_value(index))
      def []=(index, value)
        super(as_value(index), value)
      end

      def write_cell(index, **) = super(as_value(index), **)
      def write_color(index, **) = super(as_value(index), **)

      private

      def item_count = @items

      # +index+ as a game value, so it is checked as the routine runs.
      def as_value(index) = index.is_a?(Integer) ? DSL::Value.new(@builder, DSL::Value.node_for(index)) : index
    end

    # WHICH PART OF THE ROUTINE IS BEING BUILT, and for a part in pieces which piece: what a slot's
    # writer asks before it is read or written, so a part in pieces that reaches past its own
    # piece is refused as the routine is built, in plain words (PiecedUnpacking says why each is).
    class UnpackingPartBuilding
      # The part being built (a DSL::PackSlots::Routine, or nil between parts) and the piece of it,
      # the game value the part's block is handed.
      Entered = Data.define(:routine, :piece)

      # +routines+ are the parts of the routine this build makes, in the order they run.
      def initialize(routines)
        @routines = routines
      end

      # Must keep the piece inside a record: this file is read as game code, where a game variable
      # (a loop's index, the piece's) put in an instance variable is a write of the game's own. A
      # value worked out from one (PieceBytes' start, a read of a table) is not.
      def enter(routine, piece = nil)
        @entered = Entered.new(routine: routine, piece: piece)
      end

      private def routine_entered = @entered&.routine

      # THE COUNT OF BYTES DONE (CopyReader#bytes_done) READ IN A PART AFTER THE FIRST, or in a part
      # in pieces. The count runs on from one part to the next, and from one piece to the next, so
      # there it holds what the parts or pieces before wrote. The pack cache plays a part with only
      # the parts it reads slots from (UnpackingParts), and a piece is made on its own, so the
      # count would differ there and nothing in the program would show it.
      def refuse_bytes_done_in_later_part!
        routine = routine_entered
        return unless routine && (routine.pieced? || @routines.index(routine)&.positive?)

        raise ArgumentError, "#{part_words} reads `copy.bytes_done`. That count goes on from the parts and pieces " \
                             "before it, and the cache can make this part on its own, so the count would be " \
                             "different. To fix this, count the bytes this part writes in a variable of its own."
      end

      # A slot used whole (+verb+ "reads" or "writes") in a part in pieces.
      def refuse_slot_in_pieced_part!(slot_name, verb)
        return unless routine_entered&.pieced?

        raise ArgumentError, "#{part_words} has pieces:, and it #{verb} slot :#{slot_name}. A part with pieces makes each " \
                             "piece on its own, so a piece can read the copy and write its own piece, and nothing else. " \
                             "To fix this, read the slot in a part without pieces, or write the piece: " \
                             "`pack[:name].piece(piece)[i] = value`."
      end

      # A slot in pieces (+slot+) used whole.
      def refuse_whole_pieced_slot!(slot, verb)
        raise ArgumentError, "#{part_words || 'The unpacking'} #{verb} slot :#{slot.name}, and that slot is in pieces. " \
                             "Only a part with pieces: writes it, one piece at a time: " \
                             "`pack[:#{slot.name}].piece(number)[i] = value`. No other part can read it."
      end

      # Piece +number+ of +slot+ asked for where that is not the piece being built.
      def refuse_piece_not_its_own!(slot, number)
        unless routine_entered&.pieced?
          raise ArgumentError, "#{part_words || 'The unpacking'} asks for a piece of slot :#{slot.name}. Only a part with " \
                               "pieces: writes a piece. To fix this, give the part pieces: #{slot.piece_count}."
        end
        unless routine_entered.pieces == slot.piece_count
          raise ArgumentError, "#{part_words} has pieces: #{routine_entered.pieces}, and slot :#{slot.name} is in " \
                               "#{slot.piece_count} pieces. A part writes slots of as many pieces as it has. To fix this, " \
                               "give them the same number of pieces."
        end
        return if number.equal?(@entered.piece)

        given = number.is_a?(Integer) ? "piece #{number}" : "a piece"
        raise ArgumentError, "#{part_words} writes #{given} of slot :#{slot.name}, and that is not the piece the block is " \
                             "given. Each piece is made on its own, so it can write only its own piece. To fix this, " \
                             "use the piece number the block is given: `pack[:#{slot.name}].piece(piece)`."
      end

      private

      def part_words
        return nil unless routine_entered

        routine_entered.part ? "Part :#{routine_entered.part} of the unpacking" : "The unpacking"
      end
    end

    # THE PACK'S SLOTS, AS AN UNPACKING ROUTINE WRITES THEM: `pack` inside `slots.fill_from_copy`,
    # a SlotBytes for each slot, by name.
    class UnpackingSlots
      def initialize(writers) = @writers = writers

      # Record every slot's reads and writes from here on in +uses+ (a SlotUses, or nil for none).
      def record_uses_in(uses) = @writers.each_value { |writer| writer.uses = uses }

      def [](name)
        @writers.fetch(name.to_sym) do
          raise ArgumentError, "The data pack has no slot #{name.inspect}. It has #{@writers.keys.map(&:inspect).join(', ')}."
        end
      end
    end
  end
end
