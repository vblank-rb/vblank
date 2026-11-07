# frozen_string_literal: true

module VBlank
  class Builder
    # THE ORIGINAL'S DATA, READ THROUGH A DATA PACK. A port of a retail game may not ship that
    # game's data, so it reads the player's own copy (Original::Game). It does not read the copy
    # directly: it names which pieces of the copy it needs, each a slot of a known shape and size,
    # and reads them from a data pack made from the copy (Original::Pack).
    #
    #   pack = data_pack from: ORIGINAL, version: "1.0" do |slots|
    #     slots.colors  :palette, at: 0x1000, count: 16
    #     slots.tiles   :walls,   at: 0x1020, count: 2
    #     slots.numbers :speeds,  at: 0x2000, count: 8, width: :byte, signed: false
    #   end
    #   image :wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
    #   speeds = table :speeds, pack[:speeds]
    #
    # Why a pack rather than the copy: the same port is built two ways. Built all-in-one, the pack
    # is made here as the game is built, and the game is built holding what it read from it. Built
    # as a shell, the player's machine makes the same pack from the player's copy and the game
    # reads it there. A slot's shape and size are the game's own words in either build, never
    # worked out from the bytes, so nothing the game's code does depends on what the copy holds.
    #
    # THE GAME HOLDS HANDLES, NEVER BYTES. `pack[:palette]` is a DSL::PackSlot, which gives the slot's
    # shape and size and nothing it holds; `image` and `table` take the handle and read the slot
    # themselves (#pack_slot_values). So a game cannot branch on the original's bytes while it is
    # built, and a build that leaves the bytes out changes only what those verbs do with a handle.
    #
    # TWO WAYS TO BUILD WITH THE PACK.
    #
    # ALL-IN-ONE, the way every build goes unless told otherwise: the pack is made from the copy
    # here, written as its file would be and read back from those bytes, so the game reads exactly
    # what a pack file holds; each verb given a handle then takes what the slot holds as if the game
    # had written it. So the interpreter, the cartridges and the builds for computers all play the
    # game as one that holds the data itself, and nothing below the builder knows a pack was there.
    # A cartridge is always built this way: a console's cartridge holds its data, and nothing hands
    # a cartridge a file as it starts.
    #
    # WITH THE PACK LEFT OUT, for a build for a computer told `pack_at_start: true`
    # (Cartridge::Options): no copy is read, so the game builds on a machine that has none, and the
    # program holds none of the original's bytes. It reads its pack from a file it is handed as it
    # starts (IR::StartFile). The pack's layout follows from the slots' shapes and sizes alone
    # (Original::Pack.layout), so the build knows where each slot will be in the file: a table given
    # a slot is read from there (#table_from_start_file), and so is a picture given a slot of colours
    # or tiles of a slot of tiles, or both (#define_picture_from_start_file). The program holds none
    # of a table's entries and zeros for a picture's pixels, and nothing the build works out may depend
    # on what a slot holds: a table read from the file is not one whose entries a build looks at (a
    # pose stepped through by a table's entries), and a picture read from the file is a whole box of
    # its size to the build, so its default hitbox and its cut into blocks follow the box, not the
    # see-through pixels in it (a game that wants a tighter box gives `hitbox:`). What a game cannot do
    # with a slot this way yet is refused in plain words, naming the line.
    #
    # A SLOT THE ORIGINAL KEEPS PACKED has no `at:`, and the game's own unpacking routine fills it:
    #
    #   pack = data_pack from: ORIGINAL, version: "1.0" do |slots|
    #     slots.colors :palette, at: 0x1000, count: 16
    #     slots.tiles  :walls, count: 40
    #     slots.fill_from_copy do |copy, pack|
    #       copy.unpack_lz77 at: 0x1020, into: pack[:walls]
    #     end
    #   end
    #
    # The routine is game code, not Ruby the build runs, so the same routine can make the pack on
    # a player's machine, where nothing but the shipped game runs. It is built into a program of
    # its own (#unpacking_program; Original::Unpacking says why one of its own, and what a shell
    # build must still add to play it there). Built all-in-one, that program is played to its end
    # here on the interpreter (#unpack_on_interpreter), and the pack is made from what it wrote;
    # every other backend plays the same program and is held to the interpreter's pack byte for
    # byte. Either way the game holds handles and reads the pack, as above.
    #
    # A game with no `data_pack` has no pack, and builds the same bytes as it did before there was one.
    module DataPacks
      # Make the game's data pack from the player's copy: +from+ is the Original::Game the port
      # names (or an Original::Copy already accepted), the block names the slots (DSL::PackSlots),
      # and +version+ names this build of the game in the pack's header, so a pack a player keeps is
      # made again when the game changes. Hands back a DSL::DataPack. A machine with no copy stops
      # here with Original::NotSet, saying what to set, unless the build leaves the pack out.
      # +formats+ are packed formats of the port's own (Original::Packing::Format) its unpacking
      # routine reads, besides those of the original's platform.
      def data_pack(from:, version: nil, formats: [], &)
        refuse_second_data_pack!
        refuse_missing_pack_version!(version)
        reading = copy_reading_for(from.platform, formats)
        return declare_pack_read_at_start(from, version, reading, &) if @build_options.pack_at_start

        copy = from.is_a?(Original::Copy) ? from : from.copy
        refuse_copy_without_hash!(copy)
        slots = DSL::PackSlots.new(platform: from.platform)
        yield slots
        refuse_unfilled_slots!(slots)
        bytes = File.binread(copy.path)
        # Every slot copied as it is must lie inside the copy, whichever way the pack is made.
        copied = slots.list.reject(&:filled_by_routine?).to_h { |slot| [slot.name, slot.cut_from(bytes)] }
        unpacking = (unpacking_program(bytes, slots.list, slots.routine, reading) if slots.routine)
        slot_bytes = unpacking ? unpack_on_interpreter(unpacking) : copied
        @data_pack_file = Original::Pack.holding(slot_bytes, sha1: copy.sha1, build_version: version).to_bytes.freeze
        @data_pack_contents = Original::Pack.from_bytes(@data_pack_file)
        @data_pack_slots = slots.list.to_h { |slot| [slot.name, slot] }
        @data_pack = DSL::DataPack.new(rom_sha1: @data_pack_contents.rom_sha1, build_version: @data_pack_contents.build_version,
                                       slots: slots.list,
                                       make_unpacking: ->(_) { unpacking || unpacking_program(bytes, slots.list, nil, reading) })
      end

      private

      # HOW THE COPY IS READ: the original's platform, and the packed formats its copy offers, the
      # platform's (Original::Packing.formats_for) and then the port's own.
      CopyReading = Data.define(:platform, :formats)

      def copy_reading_for(platform, formats)
        refuse_formats_not_formats!(formats)
        offered = Original::Packing.formats_for(platform) + formats
        refuse_formats_of_one_name!(offered)
        CopyReading.new(platform: platform, formats: offered)
      end

      def refuse_formats_not_formats!(formats)
        wrong = Array(formats).reject { |format| format.is_a?(Module) && format.singleton_class.include?(Original::Packing::Format) && format.format_name }
        return if formats.is_a?(Array) && wrong.empty?

        raise ArgumentError, "data_pack was given formats: #{formats.inspect}. formats: takes a list of format modules, " \
                             "each one that does `extend VBlank::Original::Packing::Format` and `unpacks :name`."
      end

      def refuse_formats_of_one_name!(offered)
        twice = offered.group_by(&:format_name).select { |_, formats| formats.size > 1 }.keys
        return if twice.empty?

        raise ArgumentError, "Two formats the copy offers are called #{twice.map(&:inspect).join(', ')}. Each format " \
                             "needs a name of its own. Give the port's format another name in `unpacks`."
      end

      # THE PACK LEFT OUT (see the top of this file): the slots named, the copy never read, and the
      # program told the file it is handed as it starts, a pack of these slots for +version+.
      def declare_pack_read_at_start(from, version, reading)
        refuse_pack_left_out_of_cartridge!
        slots = DSL::PackSlots.new(platform: from.platform)
        yield slots
        refuse_unfilled_slots!(slots)
        layout = Original::Pack.layout(slots.list, build_version: version)
        @program.start_file = IR::StartFile.new(called: PACK_FILE_TITLE, size: layout.size, checks: layout.checks)
        @pack_slot_starts = layout.slot_starts
        @data_pack_slots = slots.list.to_h { |slot| [slot.name, slot] }
        @data_pack = DSL::DataPack.new(rom_sha1: nil, build_version: version.to_s, slots: slots.list, original: from,
                                       make_unpacking: lambda { |copy_size|
                                         unpacking_program(nil, slots.list, slots.routine, reading, copy_size: copy_size)
                                       })
      end

      public

      # The game's data pack (DSL::DataPack), or nil for a game with none: what a shell is built
      # around (Original::Shell).
      def declared_data_pack = @data_pack

      # The data pack file this build made from the copy, its bytes, or nil for a build that made
      # none (a game with no data pack, or a build that leaves its pack out).
      def made_data_pack_file = @data_pack_file

      private

      # What a player is told the file is (IR::StartFile#called): the one a game is handed, and the
      # one its unpacking is handed.
      PACK_FILE_TITLE = "data pack"
      COPY_FILE_TITLE = "copy of the original"

      # Whether this build leaves its pack out, so a slot is read from the file handed at start.
      def pack_left_out? = !@pack_slot_starts.nil?

      def refuse_pack_left_out_of_cartridge!
        return if @for_computer

        raise ArgumentError, "This build is a cartridge, and a cartridge holds its own data. Nothing hands a cartridge " \
                             "a data pack as it starts. Build the cartridge all-in-one (no pack_at_start:), or build " \
                             "the game for a computer to read its pack as it starts."
      end

      # `table :name, DSL::StartFileEntries.new(at:, count:)`: a table of +count+ entries, each
      # +width+ wide and +signed+ or not, read from the file the program is handed as it starts, from
      # byte +at+ on. The program holds none of them (Nodes::Table#entries_in_file), and they are
      # not kept for the build to look at (Builder#always_within? reads those), since nothing known
      # while building may depend on them. Hands back its DSL::Table.
      def table_from_start_file(name, entries, width:, signed:)
        unless @program.start_file
          raise ArgumentError, "table :#{name} reads its entries from a file the game is handed as it starts, and this " \
                               "game reads no such file. Read the table from a data pack, or give it its numbers."
        end

        node = Build.table(name, [], width: width, signed: signed)
        node.from_file = entries.at
        node.entries_in_file = entries.count
        node.file_high_byte_first = true if entries.high_byte_first
        record(node)
        DSL::Table.new(self, name, entries.count, fraction_bits: nil, width: width)
      end

      # `table :name, pack[:slot]` with the pack left out: the slot read from the file.
      def table_from_pack_slot(name, handle)
        refuse_slot_from_elsewhere!(handle, "table :#{name}")
        refuse_slot_read_wrongly!(handle, :numbers, "table :#{name}")
        slot = handle.layout
        entries = DSL::StartFileEntries.new(at: @pack_slot_starts.fetch(slot.name), count: slot.count,
                                            high_byte_first: slot.format.high_byte_first)
        table_from_start_file(name, entries, width: slot.width, signed: slot.signed)
      end

      # `image :name, colors: pack[:palette], places: pack[:walls].tile(0)` with the pack left out:
      # a picture whose colours or places or both are read from the file (IR::StartFile::Picture).
      # A list the game gives itself (`colors: [...]`, `places: [...]`) stays in the program. In the
      # program the pixels are zeros, and the places of a list read from the file are all 1, so the
      # build treats the picture as a solid box. Its list of colours, when read from the file, is
      # named for the slot it comes from (#pack_colors_name), so two pictures from one slot are
      # drawn from one list and two from different slots from two, as they are when the lists hold
      # what the slots hold.
      def define_picture_from_start_file(name, opts)
        refuse_picture_with_other_options!(name, opts)
        colors = opts[:colors]
        places = opts[:places]
        width = opts[:width]
        height = opts[:height]
        positive_dims!(name, width, height)
        colors_from_file = colors.is_a?(DSL::PackSlot)
        places_from_file = places.is_a?(DSL::PackSlot)
        if colors_from_file
          refuse_slot_from_elsewhere!(colors, "image :#{name}'s colors:")
          refuse_slot_read_wrongly!(colors, :colors, "image :#{name}'s colors:")
          refuse_too_many_pack_colors!(name, colors)
        end
        if places_from_file
          refuse_slot_from_elsewhere!(places, "image :#{name}'s places:")
          refuse_slot_read_wrongly!(places, :tile, "image :#{name}'s places:")
          refuse_picture_not_of_its_tiles!(name, width, height, places)
        end

        colors_name = colors_from_file ? pack_colors_name(colors) : (colors if colors.is_a?(Symbol))
        table = if colors_from_file
                  Array.new(colors.count, 0)
                else
                  color_table(name, colors_name ? declared_colors_for_image!(name, colors_name) : (colors || []))
                end
        if places_from_file
          refuse_pack_places_without_colors!(name) if table.empty?
          held_places = Array.new(width * height, 1)
          pixels = Array.new(width * height, 0).pack("v*")
          marker = nil
        else
          refuse_bad_places!(name, places: places, width: width, height: height, table: table)
          held_places = places
          pixels, marker = IR::Assets.placed_pixels(places, table.map { |value| value || 0 })
        end
        node = Build.bitmap(name, width: width, height: height, pixels: pixels, transparent: marker,
                                  colors: table.map { |value| value || 0x0000 }, places: held_places.pack("C*"),
                                  colors_name: colors_name)
        node.from_file = IR::StartFile::Picture.new(
          colors_at: (colors_in_pack(colors) if colors_from_file), colors_count: table.length,
          places_at: (places_in_pack(places) if places_from_file), across: places_from_file ? places.across : 1,
          color_format: (colors.layout.format if colors_from_file), tile_format: (places.layout.format if places_from_file)
        )
        record_picture(node)
        (@pictures_from_start_file ||= {})[name] = node.from_file
        record_visible_bounds(name: name, width: width, height: height, cells: [], transparent: nil)
      end

      def refuse_pack_places_without_colors!(name)
        raise ArgumentError, "image :#{name} was given places: from the data pack and no colors:. A place is a place in a " \
                             "list of colors, so give the list too: `colors: pack[:palette]`, or `colors: [:transparent, ...]`."
      end

      # Where in the file the first colour that +colors+ (a DSL::PackSlot on colours) reads is.
      def colors_in_pack(colors)
        @pack_slot_starts.fetch(colors.layout.name) + ((colors.first_color || 0) * colors.layout.item_bytes)
      end

      # Where in the file the first tile that +places+ (a DSL::PackSlot on tiles) reads is.
      def places_in_pack(places)
        @pack_slot_starts.fetch(places.layout.name) + (places.tile_index * places.layout.item_bytes)
      end

      # A picture turned +way+ (:mirrored, :upside_down) from +source+, which is read from the file
      # the program is handed: it is read from the same place and turned as it is read. Places the
      # game holds are turned here already, in +node+, and are not turned again.
      def read_turned_picture_from_start_file(node, source, way)
        return unless picture_from_start_file?(source)

        from = @pictures_from_start_file.fetch(source)
        node.from_file = from.places_at ? from.turned(way) : from
        @pictures_from_start_file[node.name] = node.from_file
      end

      # Whether the picture +name+ is read from the file the program is handed as it starts.
      def picture_from_start_file?(name) = @pictures_from_start_file&.key?(name) || false

      # With the pack left out, a picture reads from the pack only as a slot of colours or tiles of
      # places, or both, and nothing else: the build knows nothing else of it that does not depend on
      # the bytes.
      def refuse_picture_with_other_options!(name, opts)
        others = opts.keys - %i[colors places width height]
        return if others.empty?

        raise ArgumentError, "image :#{name} reads a slot of the data pack, and this build reads its pack as the game " \
                             "starts. Such a picture takes colors:, places:, width: and height:, and nothing else, " \
                             "but it was given #{others.map(&:inspect).join(', ')}: " \
                             "`image :#{name}, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)`. " \
                             "Or build the game all-in-one."
      end
      # The name of the list of colours a picture read from the pack is drawn from: the colour
      # slot's, written so no list a game declares (`colors :sea`) can have it.
      def pack_colors_name(handle) = :"data pack slot :#{handle.layout.name}#{" bank from #{handle.first_color}" if handle.bank?}"

      def refuse_too_many_pack_colors!(name, handle)
        return if handle.count <= IR::StartFile::PLACES

        raise ArgumentError, "image :#{name} takes its colors from slot :#{handle.layout.name}, which holds " \
                             "#{handle.count} colors. A picture given places picks from #{IR::StartFile::PLACES} colors " \
                             "at most. Give it a slot of #{IR::StartFile::PLACES} colors or fewer."
      end

      def refuse_picture_not_of_its_tiles!(name, width, height, places)
        side = Original::Slot::TILE_SIDE
        return if width == places.across * side && height == places.down * side

        raise ArgumentError, "image :#{name} is #{width}x#{height}, and its places are #{places.across} by #{places.down} " \
                             "tiles of #{side}x#{side} pixels. Make the picture #{places.across * side}x#{places.down * side}."
      end

      # THE UNPACKING PROGRAM (Original::Unpacking says why it is a program of its own): the copy's
      # +bytes+ as a table, the pack's bytes as one list, each of +slots+ copied as it is or filled
      # by +routine+, the game's `slots.fill_from_copy` block, run as game code on a builder of its
      # own. A pack with no routine has one too, which only copies: it is what a shell runs for any pack.
      #
      # With the pack left out there are no +bytes+: the program is built for a copy of +copy_size+
      # bytes, the size of the release it unpacks, and reads the copy from the file it is handed as
      # it starts, so it holds none of the copy either. That program is what a shell plays on the
      # player's machine, so it is built for the game's console, and shows how far it has got
      # (#define_unpacking_progress). +reading+ (a CopyReading) says which packed formats the copy
      # offers the routine.
      def unpacking_program(bytes, slots, routine, reading, copy_size: nil)
        copy_size = refuse_unsized_unpacking!(copy_size) unless bytes
        Builder.keeping_builder_in_use do
          maker = bytes ? Builder.new : Builder.new(options: unpacking_options)
          copy = if bytes
                   maker.table(Original::Unpacking::COPY, bytes.bytes, width: :byte, signed: false)
                 else
                   declare_copy_table_from_start_file(maker, slots, copy_size)
                 end
          list = maker.list(Original::Unpacking::BYTES, capacity: slots.sum(&:byte_size), width: :byte, full_of: 0)
          finished = maker.var(Original::Unpacking::FINISHED, 0)
          faults = Original::UnpackingFaults.new(maker)
          progress = (Original::Unpacking::PROGRESS unless bytes)
          reader = Original::CopyReader.new(maker, copy: copy, pack: list, faults: faults, formats: reading.formats,
                                                   platform: reading.platform, before_wait: progress)
          define_unpacking_progress(maker, reader.bytes_done, finished, slots.sum(&:byte_size)) if progress
          places = Original::Unpacking.places_of(slots)
          writers = slots.each_with_index.to_h do |slot, number|
            [slot.name, Original::SlotBytes.new(maker, list, slot, places[slot.name], number: number, faults: faults)]
          end
          pack = Original::UnpackingSlots.new(writers)
          slots.reject(&:filled_by_routine?).each do |slot|
            reader.copy_bytes(at: slot.at, count: slot.byte_size, into: pack[slot.name])
          end
          maker.instance_exec(reader, pack, &routine) if routine
          finished.store!(1)
          if progress
            maker.call(progress)
            maker.wait_vblank
          end
          maker.halt
          maker.finalize_program
          Original::Unpacking.new(program: maker.program, slots: slots, copy_size: bytes ? bytes.bytesize : copy_size,
                                  format_words: reader.format_words)
        end
      end

      # How a shell's unpacking is built: for a computer, and for the console the game is built for,
      # so it shows in the same window as the game.
      def unpacking_options
        Cartridge::Options.new(console: @build_options.console, variant: @build_options.variant, for_computer: true)
      end

      # Where a shell's progress bar is, in pixels from the screen's edges, and how tall it is.
      PROGRESS_BAR_SIDE = 16
      PROGRESS_BAR_HEIGHT = 8

      # THE PROGRESS BAR a shell shows while it unpacks: a routine on +maker+, called before every
      # wait for the next frame (Original::CopyReader), drawing a bar as far along as +done+ is of
      # +total+ bytes, and the whole bar once +finished+ is 1. Game code, so every runtime draws it,
      # and the interpreter is its answer key. The division is by a number worked out here, so a
      # pack of many megabytes never makes a number too big for 32 bits.
      def define_unpacking_progress(maker, done, finished, total)
        across = maker.screen_width - (2 * PROGRESS_BAR_SIDE)
        top = (maker.screen_height - PROGRESS_BAR_HEIGHT) / 2
        bytes_a_pixel = [total / across, 1].max
        maker.screen :bitmap
        maker.func(Original::Unpacking::PROGRESS) do
          maker.clear_screen :black
          maker.draw_text "UNPACKING", :center, top - 16, :white
          maker.fill_rect PROGRESS_BAR_SIDE, top, across, PROGRESS_BAR_HEIGHT, :gray
          shown = ((done / bytes_a_pixel) + (finished * across)).clamp(0, across)
          maker.draw_rect_at PROGRESS_BAR_SIDE, top, shown, PROGRESS_BAR_HEIGHT, :white
        end
      end

      # The unpacking's copy, declared on +maker+ as a table read from the file the unpacking is
      # handed as it starts, and handed back: a copy of +copy_size+ bytes, which every slot copied
      # as it is must lie inside, as it must inside a copy that is there.
      def declare_copy_table_from_start_file(maker, slots, copy_size)
        slots.reject(&:filled_by_routine?).each { |slot| slot.refuse_past_end!(copy_size) }
        maker.program.start_file = IR::StartFile.new(called: COPY_FILE_TITLE, size: copy_size, checks: [])
        maker.table(Original::Unpacking::COPY, DSL::StartFileEntries.new(at: 0, count: copy_size), width: :byte, signed: false)
      end

      def refuse_unsized_unpacking!(copy_size)
        return copy_size if copy_size.is_a?(Integer) && copy_size.positive?

        raise ArgumentError, "This build reads its data pack as the game starts, so its unpacking reads no copy as it " \
                             "is built. It is built for a copy of one size. Say the size of the release it unpacks: " \
                             "`pack.unpacking(copy_size: 1_048_576)`."
      end

      # How far a routine may go on the interpreter before it is taken to be stuck. A routine reads
      # each byte of the copy and writes each byte of the pack a few times at most, and waits for
      # the next frame at most once a byte; so the frames it can need, and the steps one frame can
      # take, follow from the two sizes. A routine past either is in a loop that does not end.
      UNPACKING_STEPS_A_BYTE = 64
      UNPACKING_SPARE_FRAMES = 100
      UNPACKING_SPARE_STEPS = 100_000

      def most_unpacking_frames(unpacking) = unpacking.copy_size + unpacking.byte_size + UNPACKING_SPARE_FRAMES

      def most_unpacking_steps_a_frame(unpacking)
        ((unpacking.copy_size + unpacking.byte_size) * UNPACKING_STEPS_A_BYTE) + UNPACKING_SPARE_STEPS
      end

      # Each slot's bytes as +unpacking+ writes them on the interpreter, the answer key every other
      # backend is held to. The first fault the routine met (a block not packed the way it declares, a
      # read past the copy's end, a write past a slot) stops the build here, as a slot past the
      # copy's end does.
      def unpack_on_interpreter(unpacking)
        most_frames = most_unpacking_frames(unpacking)
        ran = begin
          IR::Backends::Reference.new.run(unpacking.program, frames: most_frames,
                                                             max_steps: most_unpacking_steps_a_frame(unpacking))
        rescue IR::ProgramError => e
          raise ArgumentError, "The data pack's unpacking routine went wrong as it ran. #{e.message}"
        end
        fault = unpacking.fault_in(ran)
        raise fault.error(unpacking.slots, unpacking.copy_size, unpacking.format_words) if fault
        unless unpacking.finished_in?(ran)
          raise ArgumentError, "The data pack's unpacking routine did not get to its end in #{most_frames} frames. " \
                               "A routine must end. Look for a loop in `slots.fill_from_copy` that never stops."
        end

        unpacking.slot_bytes_in(ran)
      end

      def refuse_unfilled_slots!(slots)
        return if slots.routine

        unfilled = slots.list.select(&:filled_by_routine?).map { |slot| ":#{slot.name}" }
        return if unfilled.empty?

        raise ArgumentError, "Slot #{unfilled.join(', ')} has no at:, and the data pack has no `slots.fill_from_copy` " \
                             "routine. Nothing fills it. Give the slot its place in the copy with at:, or fill it in " \
                             "`slots.fill_from_copy do |copy, pack| ... end`."
      end

      # What the slot +handle+ (a DSL::PackSlot) holds, read as +wanted+ asks: :colors and :numbers
      # take a whole slot of that shape, :tile one tile of a slot of tiles. +where+ names the line
      # for the error ("image :wall's colors:").
      def pack_slot_values(handle, wanted, where)
        refuse_slot_from_elsewhere!(handle, where)
        refuse_slot_read_wrongly!(handle, wanted, where)
        refuse_slot_read_while_left_out!(handle, where)
        values = handle.layout.decode(@data_pack_contents.bytes_of(handle.layout.name))
        return values.slice(handle.first_color, handle.color_count) if handle.bank?
        return values unless handle.one_tile?

        IR::Assets.picture_places_of_tiles(values.slice(handle.tile_index, handle.count).flatten, across: handle.across)
      end

      # +opts+ for `image`, each handle in colors: or places: replaced by what its slot holds.
      def opts_with_pack_slots_read(name, opts)
        read = opts.dup
        read[:colors] = pack_slot_values(opts[:colors], :colors, "image :#{name}'s colors:") if opts[:colors].is_a?(DSL::PackSlot)
        read[:places] = pack_slot_values(opts[:places], :tile, "image :#{name}'s places:") if opts[:places].is_a?(DSL::PackSlot)
        read
      end

      # A verb that reads what a slot holds as the game is built, in a build that leaves its pack out.
      def refuse_slot_read_while_left_out!(handle, where)
        return unless pack_left_out?

        raise ArgumentError, "#{where} reads what slot :#{handle.layout.name} holds as the game is built, and this " \
                             "build reads its data pack as the game starts. Read the slot with `table` or with " \
                             "`image colors:, places:`, or build the game all-in-one."
      end

      def refuse_second_data_pack!
        return if @data_pack.nil?

        raise ArgumentError, "The game says `data_pack` twice. A game has one data pack. Name every slot in one " \
                             "`data_pack` block."
      end

      def refuse_missing_pack_version!(version)
        return unless version.nil?

        raise ArgumentError, "`data_pack` needs version:. It names this build of the game in the pack. A player's " \
                             "pack is made again when the version changes. Write `data_pack from: ..., " \
                             "version: \"1.0\"`, and change the version when the game's data changes."
      end

      def refuse_copy_without_hash!(copy)
        return if copy.sha1

        raise ArgumentError, "#{copy.path} is a folder, so it has no one SHA-1. A data pack is made from a copy that " \
                             "is one file. Name the file of your copy."
      end

      def refuse_slot_from_elsewhere!(handle, where)
        return if @data_pack_slots&.fetch(handle.layout.name, nil) == handle.layout

        raise ArgumentError, "#{where} was given slot :#{handle.layout.name}, and this game's data pack has no such slot. " \
                             "Use a slot from this game's `data_pack`."
      end

      # What each way of reading a slot needs, in words, for the error.
      SLOT_READING_WORDS = { colors: "a slot of colors", tile: "one tile, like `pack[:walls].tile(0)`",
                             numbers: "a slot of numbers" }.freeze

      def refuse_slot_read_wrongly!(handle, wanted, where)
        fits = wanted == :tile ? handle.one_tile? : handle.shape == wanted && !handle.one_tile?
        return if fits

        given = handle.one_tile? ? "one tile of slot :#{handle.layout.name}" : "slot :#{handle.layout.name}, which holds #{handle.shape}"
        raise ArgumentError, "#{where} was given #{given}. It must be given #{SLOT_READING_WORDS.fetch(wanted)}."
      end
    end
  end
end
