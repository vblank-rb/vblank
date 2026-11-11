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
    # or tiles of a slot of tiles, or both (#define_picture_from_start_file), and a screen's backdrop
    # given a slot of colours (#pack_backdrop_in_start_file), and a list of colours declared from a
    # slot holds a marker for each colour (#pack_colors_read_at_start). The program holds none
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
    # here, built as Ruby (#play_unpacking), and the pack is made from what it wrote; every backend
    # plays the same program and is held to the interpreter's pack byte for byte. Either way the
    # game holds handles and reads the pack, as above.
    #
    # A game with no `data_pack` has no pack, and builds the same bytes as it did before there was one.
    module DataPacks
      # Make the game's data pack from the player's copy: +from+ is the Original::Game the port
      # names (or an Original::Copy already accepted), the block names the slots (DSL::PackSlots),
      # and +version+ names this build of the game in the pack's header, so a pack a player keeps is
      # made again when the game changes. Hands back a DSL::DataPack. A machine with no copy stops
      # here with Original::NotSet, saying what to set, unless the build leaves the pack out.
      # +formats+ are packed formats of the port's own (Original::Packing::Format) its unpacking
      # routine reads, besides those of the original's platform. +cache+ names a folder, which git
      # must ignore, to keep what the unpacking routine writes in, so a later build with the same
      # copy and routine reads it back instead of running the routine again (Original::PackCache).
      def data_pack(from:, version: nil, formats: [], cache: nil, &)
        refuse_second_data_pack!
        refuse_missing_pack_version!(version)
        @data_pack_platform = from.platform
        reading = copy_reading_for(from.platform, formats)
        return declare_pack_read_at_start(from, version, reading, &) if @build_options.pack_at_start

        copy = from.is_a?(Original::Copy) ? from : from.copy
        refuse_copy_without_hash!(copy)
        slots = DSL::PackSlots.new(platform: from.platform)
        yield slots
        refuse_unfilled_slots!(slots)
        refuse_places_not_matching_releases!(slots, from, copy)
        bytes = copy.read_bytes
        copy_release = copy.release_record
        copy_release_slots = slots_in_release(slots, copy_release.name)
        # Every slot copied as it is must lie inside the copy, whichever way the pack is made.
        copied = copy_release_slots.reject(&:filled_by_routine?).to_h { |slot| [slot.name, slot.cut_from(bytes)] }
        unpacking = (unpacking_program(bytes, copy_release_slots, slots.routine, reading, release: copy_release) if slots.routine)
        slot_bytes = unpacking ? unpacked_slot_bytes(unpacking, cache) : copied
        @data_pack_contents = Original::Pack.from_bytes(Original::Pack.holding(slot_bytes, sha1: copy.sha1, build_version: version).to_bytes)
        @data_pack_slots = slots.list.to_h { |slot| [slot.name, slot] }
        made = { Original::FrameRecord::Section.new(sources: []) => unpacking }
        @data_pack = DSL::DataPack.new(rom_sha1: @data_pack_contents.rom_sha1, build_version: @data_pack_contents.build_version,
                                       slots: slots.list, platform: from.platform,
                                       make_unpacking: lambda { |_release|
                                         frames = pack_frame_section
                                         made[frames] ||= unpacking_program(bytes, copy_release_slots, slots.routine, reading,
                                                                            release: copy_release, frames: frames)
                                       })
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
        refuse_places_not_matching_releases!(slots, from, nil)
        layout = Original::Pack.layout(slots.list, build_version: version)
        @program.start_file = IR::StartFile.new(called: PACK_FILE_TITLE, size: layout.size, checks: layout.checks)
        @pack_slot_starts = Original::SlotStarts.new(by_name: layout.slot_starts)
        # The records of the frames the game goes on to name follow the last slot (PackPoses).
        @pack_frames_at = layout.size
        @data_pack_slots = slots.list.to_h { |slot| [slot.name, slot] }
        made = {}
        @data_pack = DSL::DataPack.new(rom_sha1: nil, build_version: version.to_s, slots: slots.list, original: from,
                                       platform: from.platform,
                                       make_unpacking: lambda { |release|
                                         release = refuse_unsized_unpacking!(release)
                                         frames = pack_frame_section
                                         made[[release, frames]] ||= unpacking_program(nil, slots_in_release(slots, release.name), slots.routine,
                                                                                       reading, release: release, frames: frames)
                                       })
      end

      public

      # The game's data pack (DSL::DataPack), or nil for a game with none: what a shell is built
      # around (Original::Shell).
      def declared_data_pack = @data_pack

      # The data pack file this build made from the copy, its bytes, or nil for a build that made
      # none (a game with no data pack, or a build that leaves its pack out): its slots, and the
      # record of each frame the game has named by now (PackPoses#pack_frame_section), so it is the
      # whole file once the game is declared. The same game built with its pack left out reads this file.
      def made_data_pack_file
        return nil unless @data_pack_contents

        frames = pack_frame_section
        (@made_data_pack_files ||= {})[frames] ||= Original::Pack.holding(
          @data_pack_contents.slots, sha1: @data_pack_contents.rom_sha1, build_version: @data_pack_contents.build_version,
          frame_records: frames.bytes(@data_pack_contents.slots)
        ).to_bytes.freeze
      end

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
        node.file_number_format = entries.format
        record(node)
        DSL::Table.new(self, name, entries.count, fraction_bits: nil, width: width)
      end

      # `table :name, pack[:slot]` with the pack left out: the slot read from the file.
      def table_from_pack_slot(name, handle)
        refuse_slot_from_elsewhere!(handle, "table :#{name}")
        refuse_slot_read_wrongly!(handle, :numbers, "table :#{name}")
        slot = handle.layout
        entries = DSL::StartFileEntries.new(at: @pack_slot_starts.fetch(slot.name), count: slot.count, format: slot.format)
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

      # `image :walls, width: 64, height: 64, colors: [...], places: pack[:walls], see_through: 255`:
      # A PICTURE OF UP TO 256 COLOURS, its places one byte a pixel from a slot of pixels, row by
      # row, and its colours the game's own list (or a slot of colours). Unlike a picture of up to
      # sixteen colours, place 0 is a colour like any other, and the place +see_through+ names, if
      # any, is not drawn. Built all-in-one it is a picture of colours, as one given `data:` is, so
      # every verb draws it so; with the pack left out its pixels are filled from the file as the
      # game starts (#define_pixels_picture_from_start_file).
      PIXELS_PICTURE_OPTIONS = %i[width height colors places see_through].freeze
      MOST_PIXEL_PLACES = 256

      def define_picture_of_pack_pixels(name, opts)
        refuse_pixels_picture_options!(name, opts)
        places = opts[:places]
        width = opts[:width]
        height = opts[:height]
        see_through = opts[:see_through]
        positive_dims!(name, width, height)
        refuse_slot_from_elsewhere!(places, "image :#{name}'s places:")
        refuse_pixels_not_its_size!(name, width, height, places)
        refuse_bad_see_through!(name, see_through)
        colors = pixels_picture_colors(name, opts[:colors])
        return define_pixels_picture_from_start_file(name, width, height, places, colors, see_through) if pack_left_out?

        bytes = @data_pack_contents.bytes_of(places.layout.name).byteslice(places.first_pixel, places.count).bytes
        data = bytes.map do |place|
          next :transparent if place == see_through

          colors.fetch(place) { refuse_pixel_place_without_color!(name, place, colors.length) }
        end
        define_pixel_image(name, width: width, height: height, data: data, transparent: see_through ? true : nil)
      end

      # The same picture with the pack left out: its colours held in the program (the game's own,
      # or a marker for each colour of a slot, IR::StartFile "MARKERS"), its pixels zeros until
      # they are filled from the file as the game starts (IR::StartFile::Picture, its places one
      # byte each). Its places are held as all 1, so the build treats it as a solid box, as a
      # picture of tiles from the file.
      def define_pixels_picture_from_start_file(name, width, height, places, colors, see_through)
        table = colors.map { |color| list_color(color) }
        count = width * height
        node = Build.bitmap(name, width: width, height: height, pixels: Array.new(count, 0).pack("v*"),
                                  transparent: nil, colors: table, places: Array.new(count, 1).pack("C*"))
        node.from_file = IR::StartFile::Picture.new(
          colors_at: nil, colors_count: table.length, places_by_byte: true, see_through: see_through,
          places_at: @pack_slot_starts.fetch(places.layout.name) + places.first_pixel
        )
        record_picture(node)
        (@pictures_from_start_file ||= {})[name] = node.from_file
        record_visible_bounds(name: name, width: width, height: height, cells: [], transparent: nil)
      end

      # The colours of a picture of pixels: a list the game gives (names or numbers), or a slot of
      # colours of the pack, up to 256 of them taken whole. The slot is read here; a build that
      # leaves its pack out holds a marker for each of its colours instead, as a list declared
      # from the pack does (#pack_colors_read_at_start), so the picture's pixels are filled as
      # markers as the game starts and put in the file's colours with every other marker.
      def pixels_picture_colors(name, colors)
        list = colors.is_a?(DSL::PackSlot) ? pixels_picture_pack_colors(name, colors) : colors
        return list.to_a if list.is_a?(Array) && list.length.between?(1, MOST_PIXEL_PLACES)

        raise ArgumentError, "image :#{name} takes its pixels from a slot of pixels. It needs colors: with 1 to " \
                             "#{MOST_PIXEL_PLACES} colors, place 0 first. To fix this, give the game's own list, like " \
                             "`colors: [:black, :white, ...]`."
      end

      def pixels_picture_pack_colors(name, slot)
        where = "image :#{name}'s colors:"
        return pack_slot_values(slot, :colors, where) unless pack_left_out?

        refuse_slot_from_elsewhere!(slot, where)
        refuse_slot_read_wrongly!(slot, :colors, where)
        pack_colors_read_at_start(slot)
      end

      def refuse_pixels_picture_options!(name, opts)
        others = opts.keys - PIXELS_PICTURE_OPTIONS
        return if others.empty?

        raise ArgumentError, "image :#{name} takes its pixels from a slot of pixels. It was given " \
                             "#{others.map(&:inspect).join(', ')}, which such a picture does not take. It takes width:, " \
                             "height:, colors:, places: and see_through:. To fix this, leave the others out."
      end

      def refuse_pixels_not_its_size!(name, width, height, places)
        return if width * height == places.count

        raise ArgumentError, "image :#{name} is #{width}x#{height}, which is #{width * height} pixels. Its places: are " \
                             "#{places.count} pixels of slot :#{places.layout.name}. To fix this, make the picture that " \
                             "size, or give it that many pixels with `pack[:#{places.layout.name}].pixels(first, count)`."
      end

      def refuse_bad_see_through!(name, see_through)
        return if see_through.nil? || (see_through.is_a?(Integer) && see_through.between?(0, MOST_PIXEL_PLACES - 1))

        raise ArgumentError, "image :#{name} was given see_through: #{see_through.inspect}. It names the place that is not " \
                             "drawn, 0 to #{MOST_PIXEL_PLACES - 1}. To fix this, give a place, or leave see_through: out " \
                             "so every place is drawn."
      end

      def refuse_pixel_place_without_color!(name, place, count)
        raise ArgumentError, "image :#{name} has a pixel of place #{place}, and its colors: list holds #{count} colors, " \
                             "places 0 to #{count - 1}. To fix this, give a color for every place its pixels use, or name " \
                             "the place see_through:."
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
      # game holds are turned here already, in +node+, and are not turned again. A pose's pieces
      # are always in the file (IR::StartFile::Pose).
      def read_turned_picture_from_start_file(node, source, way)
        return unless picture_from_start_file?(source)

        from = @pictures_from_start_file.fetch(source)
        places_in_file = from.is_a?(IR::StartFile::Pose) || from.places_at
        node.from_file = places_in_file ? from.turned(way) : from
        @pictures_from_start_file[node.name] = node.from_file
      end

      # Whether the picture +name+ is read from the file the program is handed as it starts.
      def picture_from_start_file?(name) = @pictures_from_start_file&.key?(name) || false

      # A PIECE OF A PICTURE READ FROM THE FILE, a picture of its own: +piece+ is +width+ pixels of
      # every row of +source+ from +left+ on, as a font cut from a strip of pictures cuts each
      # letter (PictureFonts#declare_strip_piece). The build holds none of the source's pixels, so
      # nothing is cut here: the piece reads the file as the source does, from its own part of it.
      #
      # A source whose places are a slot's pixels, one byte each, gives a piece that reads the same
      # rows from further along (IR::StartFile::Picture#piece_from). A source that holds its places
      # and reads only its colours gives a piece of those places, reading the same colours.
      # Hands back +piece+, or nil for a source that cannot be cut this way: one turned as it is
      # read, one of tiles, or a pose painted from an original's frame.
      def define_piece_read_from_start_file(piece, source, left:, width:)
        from = @pictures_from_start_file.fetch(source)
        return nil unless from.is_a?(IR::StartFile::Picture) && from.turns.empty? && (from.places_by_byte || from.places_at.nil?)

        whole = @program.walk.find { |found| found.kind == :bitmap && found.name == source }
        cut = ->(cells) { (0...whole.height).flat_map { |row| cells[(row * whole.width) + left, width] } }
        node = Build.bitmap(piece, width: width, height: whole.height, pixels: cut.call(whole.pixels.unpack("v*")).pack("v*"),
                                   transparent: whole.transparent, colors: whole.colors,
                                   places: cut.call(whole.places.bytes).pack("C*"), colors_name: whole.colors_name)
        node.from_file = from.places_at ? from.piece_from(left, whole_width: whole.width) : from
        record_picture(node)
        @pictures_from_start_file[piece] = node.from_file
        record_visible_bounds(name: piece, width: width, height: whole.height, cells: [], transparent: nil)
        piece
      end

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

      # THE UNPACKING PROGRAM (Original::Unpacking says why it is a program of its own): the copy
      # read from the file the program is handed as it starts, the pack's bytes as one list, each of
      # +slots+ copied as it is or filled by +routine+, the game's `slots.fill_from_copy` block, run
      # as game code on a builder of its own. A pack with no routine has one too, which only copies:
      # it is what a shell runs for any pack. The program holds none of the copy however it is built.
      #
      # Built all-in-one, +bytes+ is the copy the build read: the program is built for a copy of
      # its size, and the build hands it that copy when it plays it (Original::Unpacking#run_on).
      # With the pack left out there are no +bytes+: the program is built for a copy of the size of
      # +release+ (an Original::Release), the one it unpacks. That program is what a shell plays on
      # the player's machine, so it shows how far it has got (#define_unpacking_progress). Both are
      # built for the game's console. +reading+ (a CopyReading) says which packed formats the copy
      # offers the routine.
      #
      # +frames+ (an Original::FrameRecord::Section) are the frames of sprites the game names, each
      # written last as a record of VBlank's own, after the pack's slots (Original::FrameRewrite).
      def unpacking_program(bytes, slots, routine, reading, release:, frames: Original::FrameRecord::Section.new(sources: []))
        Builder.keeping_builder_in_use do
          maker = Builder.new(options: unpacking_options)
          copy_size = bytes ? bytes.bytesize : release.size
          copy_table = declare_copy_table_from_start_file(maker, slots, copy_size)
          slots_size = slots.sum(&:byte_size)
          list = maker.list(Original::Unpacking::BYTES, capacity: slots_size + frames.size, width: :byte, full_of: 0)
          finished = maker.var(Original::Unpacking::FINISHED, 0)
          faults = Original::UnpackingFaults.new(maker)
          progress = (Original::Unpacking::PROGRESS unless bytes)
          slot_bytes_done = (maker.list(Original::Unpacking::SLOT_BYTES_DONE, capacity: slots.length, full_of: 0) if slots.any?(&:costly?))
          reader = Original::CopyReader.new(maker, copy: copy_table, pack: list, faults: faults, formats: reading.formats,
                                                   platform: reading.platform, release: release, before_wait: progress,
                                                   slot_bytes_done: slot_bytes_done)
          if progress
            done = slot_bytes_done ? UnpackingWork.new(slots, slot_bytes_done) : UnpackingBytes.new(slots, reader.bytes_done)
            define_unpacking_progress(maker, done, finished)
          end
          places = Original::Unpacking.places_of(slots)
          writers = slots.each_with_index.to_h do |slot, number|
            [slot.name, Original::SlotBytes.new(maker, list, slot, places[slot.name], number: number, faults: faults)]
          end
          pack = Original::UnpackingSlots.new(writers)
          slots.reject(&:filled_by_routine?).each do |slot|
            reader.copy_bytes(at: slot.at, count: slot.byte_size, into: pack[slot.name])
          end
          maker.instance_exec(reader, pack, release.name, &routine) if routine
          wait = lambda do
            maker.call(progress) if progress
            maker.wait_vblank
          end
          Original::FrameRewrite.new(maker, pack: list, section: frames, section_at: slots_size, slot_places: places, wait: wait).emit
          finished.store!(1)
          if progress
            maker.call(progress)
            maker.wait_vblank
          end
          maker.halt
          maker.finalize_program
          Original::Unpacking.new(program: maker.program, slots: slots, copy_size: copy_size,
                                  format_words: reader.format_words, copy_bytes: bytes&.b, frames: frames)
        end
      end

      # How an unpacking is built: for a computer, and for the console the game is built for. A
      # shell's shows in the same window as the game, and an all-in-one build's is played here and
      # by every backend, which lays a program out for the console it names and refuses one naming none.
      def unpacking_options
        Cartridge::Options.new(console: @build_options.console, variant: @build_options.variant, for_computer: true)
      end

      # Where a shell's progress bar is, in pixels from the screen's edges, and how tall it is.
      PROGRESS_BAR_SIDE = 16
      PROGRESS_BAR_HEIGHT = 8

      # THE PROGRESS BAR a shell shows while it unpacks: a routine on +maker+, called before every
      # wait for the next frame (Original::CopyReader), drawing a bar as far along as +done+ (an
      # UnpackingBytes or UnpackingWork) says, and the whole bar once +finished+ is 1. Game code, so
      # every runtime draws it, and the interpreter is its answer key.
      def define_unpacking_progress(maker, done, finished)
        across = maker.screen_width - (2 * PROGRESS_BAR_SIDE)
        top = (maker.screen_height - PROGRESS_BAR_HEIGHT) / 2
        maker.screen :bitmap
        maker.func(Original::Unpacking::PROGRESS) do
          maker.clear_screen :black
          maker.draw_text "UNPACKING", :center, top - 16, :white
          maker.fill_rect PROGRESS_BAR_SIDE, top, across, PROGRESS_BAR_HEIGHT, :gray
          shown = (done.pixels_shown(across) + (finished * across)).clamp(0, across)
          maker.draw_rect_at PROGRESS_BAR_SIDE, top, shown, PROGRESS_BAR_HEIGHT, :white
        end
      end

      # HOW FAR THE BAR IS, BY BYTES: the bytes written so far (+done+, the routine's count) of all
      # the +slots+ hold, for a pack whose slots name no cost. Both are shifted down before the count
      # is multiplied by the bar's width, by as little as keeps the product inside 32 bits, so a
      # pack of many megabytes works the same way and a small one is exact to the pixel.
      UnpackingBytes = Data.define(:slots, :done) do
        def pixels_shown(across)
          total = slots.sum(&:byte_size)
          shift = (0..31).find { |bits| (total >> bits) * across <= IR::Int32::MAX }
          whole = [total >> shift, 1].max
          written = (shift.zero? ? done : done >> shift).clamp(0, whole)
          (written * across) / whole
        end
      end

      # HOW FAR THE BAR IS, BY WORK: each slot holds a share of the bar as its bytes times its cost
      # are of the whole pack's (Original::Slot#cost), and fills its share as its own bytes are
      # written (+slot_bytes_done+, the routine's list of them by slot). So a slot a routine renders
      # slowly moves the bar slowly and a quick copy quickly, and the bar keeps one pace. A slot's
      # bytes are shifted down before they are multiplied, by as little as keeps the product inside
      # 32 bits, so a slot of many megabytes works the same way.
      UnpackingWork = Data.define(:slots, :slot_bytes_done) do
        def pixels_shown(across)
          work = slots.sum { |slot| slot.byte_size * slot.cost }
          slots.each_with_index.filter_map do |slot, number|
            share = across * slot.byte_size * slot.cost / work
            next if share.zero?

            shift = (0..31).find { |bits| (slot.byte_size >> bits) * share <= IR::Int32::MAX }
            # Held to the slot's size before it is multiplied, so a routine that counts more than
            # the slot holds fills its share and never wraps the product below zero.
            whole = slot.byte_size >> shift
            written = (shift.zero? ? slot_bytes_done[number] : slot_bytes_done[number] >> shift).clamp(0, whole)
            (written * share) / whole
          # Must fold with +, not Array#sum: sum starts from Ruby's 0, and the parts are game values.
          end.inject { |total, part| total + part } || 0
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

      def refuse_unsized_unpacking!(release)
        return release if release.is_a?(Original::Release) && release.size.is_a?(Integer) && release.size.positive?

        raise ArgumentError, "This build reads its data pack as the game starts, so its unpacking reads no copy as it " \
                             "is built. It is built for a copy of one size. Name the release it unpacks, with its size: " \
                             "`pack.unpacking(release: release)`."
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

      # The routine's slots, read back from +cache+ (a folder, or nil for none) where they are kept.
      def unpacked_slot_bytes(unpacking, cache)
        return play_unpacking(unpacking) if cache.nil?

        Original::PackCache.new(cache).slot_bytes(unpacking) { play_unpacking(unpacking) }
      end

      # Each slot's bytes as +unpacking+ writes them. It is played built as Ruby, as a shell plays it
      # on a player's machine (Original::Unpacking#run_as_ruby): the interpreter is plain and slow on
      # purpose, many times slower on a port's loops. The interpreter stays the answer key:
      # every run of the tests holds the Ruby lowering to it frame by frame, unpackings among them
      # (test/copy_reader_tests.rb, the packing tests), and it plays a routine the Ruby runtime
      # cannot play yet. The first fault the routine met (a block not packed the way it declares, a
      # read past the copy's end, a write past a slot) stops the build here, as a slot past the
      # copy's end does.
      def play_unpacking(unpacking)
        most_frames = most_unpacking_frames(unpacking)
        ran = begin
          unpacking.run_as_ruby(frames: most_frames)
        rescue IR::Backends::Ruby::RuntimeGap
          unpacking.run_on(IR::Backends::Reference.new, frames: most_frames, max_steps: most_unpacking_steps_a_frame(unpacking))
        end
        refuse_faulted_or_unfinished_unpacking!(unpacking, ran, most_frames)
        unpacking.slot_bytes_in(ran)
      rescue IR::ProgramError => e
        raise ArgumentError, "The data pack's unpacking routine went wrong as it ran. #{e.message}"
      end

      def refuse_faulted_or_unfinished_unpacking!(unpacking, ran, most_frames)
        fault = unpacking.fault_in(ran)
        raise fault.error(unpacking.slots, unpacking.copy_size, unpacking.format_words) if fault
        unless unpacking.finished_in?(ran)
          raise ArgumentError, "The data pack's unpacking routine did not get to its end in #{most_frames} frames. " \
                               "A routine must end. Look for a loop in `slots.fill_from_copy` that never stops."
        end
      end

      # A slot's at: given by release must name every release the build can unpack, and no name
      # that is no release. +copy+ is the copy the build reads (nil with the pack left out).
      def refuse_places_not_matching_releases!(slots, from, copy)
        by_release = slots.list.select(&:places_by_release?)
        return if by_release.empty?

        known = from.release_names
        needed = from.readable_release_names
        # A game that accepts its copy by a probe lists no releases, so the copy's own is the only one.
        known = needed = [copy.release] if known.empty? && copy
        by_release.each do |slot|
          missing = needed - slot.release_names
          unknown = slot.release_names - known
          next if missing.empty? && unknown.empty?

          problems = []
          problems << "It names no place for the #{missing.join(', ')} release#{'s' if missing.size > 1}." unless missing.empty?
          problems << "#{unknown.join(', ')} #{unknown.size > 1 ? 'are' : 'is'} no release of the original." unless unknown.empty?
          raise BuildError, "Slot :#{slot.name} has an at: with a place for each release. #{problems.join(' ')} " \
                            "The releases are #{known.join(', ')}. Give at: a place for each release the game reads. " \
                            "Do not give any other name."
        end
      end

      # The slots as they are in the release called +release_name+: one place each.
      def slots_in_release(slots, release_name) = slots.list.map { |slot| slot.in_release(release_name) }

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
      #
      # Must be called only in a build that holds its pack. A build that leaves its pack out holds
      # none to read, and every verb that takes a handle is made for that build, or refuses it in
      # words of its own, before it gets here. A verb added later that is not is found by its game
      # in test/pack_games.rb, which the coverage check asks for, failing here in that build.
      def pack_slot_values(handle, wanted, where)
        refuse_slot_from_elsewhere!(handle, where)
        refuse_slot_read_wrongly!(handle, wanted, where)
        values = handle.layout.decode(@data_pack_contents.bytes_of(handle.layout.name))
        return values.slice(handle.first_color, handle.color_count) if handle.bank?
        return values unless handle.one_tile?

        IR::Assets.picture_places_of_tiles(values.slice(handle.tile_index, handle.count).flatten, across: handle.across)
      end

      # THE TILES OF A SLOT OF TILES, from the tile +tiles+ (a DSL::PackSlot) starts at on, each a
      # list of its 64 places row by row, for a verb that draws the original's own tiles by number
      # (PackBackgrounds, PackPoses). +subject+ names the line for the error.
      def pack_tile_places(tiles, subject)
        refuse_tiles_not_from_slot!(tiles, subject)
        refuse_slot_from_elsewhere!(tiles, "#{subject}'s tiles:")
        tiles.layout.decode(@data_pack_contents.bytes_of(tiles.layout.name)).drop(tiles.tile_index || 0)
      end

      # tiles: is a slot of tiles, or the tiles of one from a tile on.
      def refuse_tiles_not_from_slot!(tiles, subject)
        return if tiles.is_a?(DSL::PackSlot) && tiles.shape == :tiles && tiles.across == 1 && tiles.down == 1

        raise ArgumentError, "#{subject} needs tiles:, a slot of tiles like `pack[:video]`, or the tiles from one tile " \
                             "on, like `pack[:video].tile(256)`."
      end

      # Tile +at+ of +tile_places+ (#pack_tile_places), which +subject+ draws, or a friendly error.
      def pack_tile_at(tile_places, at, subject)
        tile_places.fetch(at) do
          raise ArgumentError, "#{subject} draws tile #{at}, and its tiles: slot holds #{tile_places.length} tiles from " \
                               "there. To fix this, give it a slot that holds every tile it draws."
        end
      end

      # +rows+ of a picture turned as the original's flags say: each row reversed for +mirrored+,
      # the rows reversed for +upside_down+.
      def turned_rows(rows, mirrored:, upside_down:)
        rows = rows.map(&:reverse) if mirrored
        upside_down ? rows.reverse : rows
      end

      # +opts+ for `image`, each handle in colors: or places: replaced by what its slot holds.
      #
      # With the pack left out a slot of colours is a marker for each colour, as a list declared
      # from the pack is (#pack_colors_read_at_start): what a picture drawn in characters takes,
      # whose pixels are the game's own colours.
      def opts_with_pack_slots_read(name, opts)
        read = opts.dup
        if opts[:colors].is_a?(DSL::PackSlot)
          where = "image :#{name}'s colors:"
          read[:colors] = pack_left_out? ? picture_colors_read_at_start(name, opts[:colors], where) : pack_slot_values(opts[:colors], :colors, where)
        end
        read[:places] = pack_slot_values(opts[:places], :tile, "image :#{name}'s places:") if opts[:places].is_a?(DSL::PackSlot)
        read
      end

      # The colours of the picture +name+ given the slot +slot+ of colours, in a build that leaves
      # its pack out: a marker for each, sixteen at most, as a picture's own list is.
      def picture_colors_read_at_start(name, slot, where)
        refuse_slot_from_elsewhere!(slot, where)
        refuse_slot_read_wrongly!(slot, :colors, where)
        refuse_too_many_pack_colors!(name, slot)
        pack_colors_read_at_start(slot)
      end

      # THE COLOURS OF A LIST DECLARED FROM THE PACK (`colors :name, pack[:palette].bank(2)`): what
      # +slot+ (a DSL::PackSlot on a slot of colours, or on one bank of it) holds, in the slot's
      # order, for `colors` to keep as it keeps colours written in the game.
      #
      # Every colour is kept as the slot has it, the first too. A console's palette keeps a real
      # colour in its first place, which a picture never draws (place 0 is see-through to one) and
      # which a backdrop following the list shows, so the list is the one a game would get by
      # writing the slot's colours out, and builds the same bytes.
      def pack_color_list(name, slot)
        where = "colors :#{name}"
        refuse_slot_from_elsewhere!(slot, where)
        refuse_slot_read_wrongly!(slot, :colors, where)
        refuse_pack_color_list_too_long!(name, slot)
        return pack_colors_read_at_start(slot) if pack_left_out?

        pack_slot_values(slot, :colors, where)
      end

      # THE SAME LIST WITH THE PACK LEFT OUT: the build holds none of the original's colours, so
      # the list holds a marker for each (IR::StartFile, "MARKERS"), which names where the colour
      # is in the file the program is handed as it starts. Everything that takes a list's name
      # takes this one, since a marker goes wherever a colour goes: into a picture drawn in the
      # list, a sprite's other colours, a list told to hold it, a backdrop that follows it. Each
      # backend that plays the program puts the file's colour where a marker is, as it starts.
      # The first place keeps the slot's own colour here too.
      def pack_colors_read_at_start(slot)
        first = colors_in_pack(slot)
        Array.new(slot.count) do |place|
          start_file_color_marker(IR::StartFile::Color.new(at: first + (place * slot.layout.item_bytes), format: slot.layout.format))
        end
      end

      # The marker of +source+ (an IR::StartFile::Color, or a WalkedColor made from one), which is
      # one of the file's colours (IR::StartFile#colors) from here on. The same source asked for
      # again has the same marker, so two lists of one bank hold equal colours, as they do when the
      # build holds what the bank holds.
      def start_file_color_marker(source)
        @start_file_colors ||= []
        entry = (@start_file_color_entries ||= {})[source] ||= begin
          refuse_too_many_start_file_colors!
          @start_file_colors << source
          @start_file_colors.length - 1
        end
        IR::StartFile.marker_of(entry)
      end

      # A colour a list holds, as the build keeps it: its fifteen bits, or the marker it is.
      def list_color(color) = IR::StartFile.marker?(color) ? color : Graphics::Color.resolve(color)

      # ONCE THE WHOLE PROGRAM IS DECLARED: tell the program every colour it reads from the file as
      # it starts, in the order the markers count them.
      def finalize_start_file_colors
        return unless @start_file_colors

        @program.start_file = @program.start_file.with(colors: @start_file_colors.dup.freeze)
      end

      # A marker fits in the sixteen bits a picture keeps a pixel in, so there are so many of them.
      def refuse_too_many_start_file_colors!
        return if @start_file_colors.length < IR::StartFile::MOST_MARKED_COLORS

        raise ArgumentError, "This build reads its pack as the game starts, and it reads more than " \
                             "#{IR::StartFile::MOST_MARKED_COLORS} colors of lists from it, with the steps of each " \
                             "`color_walk`. To fix this, walk fewer lists or use fewer steps, or build the game all-in-one."
      end

      # A list holds as many colours as one picture can be drawn from (Images::PICTURE_COLORS), and
      # a slot often holds a whole palette of several banks.
      def refuse_pack_color_list_too_long!(name, slot)
        return if slot.count <= Images::PICTURE_COLORS

        most = Images::PICTURE_COLORS
        raise ArgumentError, "colors :#{name} was given #{slot.count} colors of slot :#{slot.layout.name}. A list of " \
                             "colors can have #{most} of them, the first meaning see-through. To fix this, give it " \
                             "one bank of the slot, like `pack[:#{slot.layout.name}].bank(0, size: #{most})`."
      end

      # THE COLOUR OF A BACKDROP TAKEN FROM THE PACK (`screen :tiled, backdrop: pack[:palette]`): the
      # colour at +place+ of +slot+ (a DSL::PackSlot on a slot of colours, or on one bank of it),
      # the first when +place+ is nil, as a `screen` keeps a backdrop's colour.
      #
      # A console shows the first colour of its background colours wherever no tile draws, so a
      # retail game's screen shows there whatever its colours hold first: a white field behind a
      # logo, a sky. That colour is data of the player's copy like the rest, and no picture can
      # show it, since the first place of a bank is see-through to one. Read here, it is the
      # backdrop a game would get by writing the colour out, on its own `screen` line or a
      # scene's, and builds the same bytes.
      def pack_backdrop_color(slot, place)
        place = pack_backdrop_place(slot, place)
        Graphics::Color.resolve(pack_slot_values(slot, :colors, PACK_BACKDROP_LINE).fetch(place)) & 0x7FFF
      end

      # THE SAME BACKDROP WITH THE PACK LEFT OUT: where the colour is in the file the program is
      # handed as it starts (an IR::StartFile::Color), which a `screen` keeps in place of the
      # colour. The build holds none of the original's colours, and each backend that plays such a
      # program reads this one as it starts. The slot's size is the game's own word, so a place
      # the slot does not have is refused here as it is all-in-one.
      def pack_backdrop_in_start_file(slot, place)
        place = pack_backdrop_place(slot, place)
        IR::StartFile::Color.new(at: colors_in_pack(slot) + (place * slot.layout.item_bytes), format: slot.layout.format)
      end

      # How the errors of a backdrop from the pack name the line.
      PACK_BACKDROP_LINE = "`screen ... backdrop:`"

      # The place of +slot+ (a DSL::PackSlot on colours) that a backdrop shows: +place+, or the
      # first where it is nil. Refuses a slot that is not this pack's or holds no colours, and a
      # place past the colours the handle is on.
      def pack_backdrop_place(slot, place)
        refuse_slot_from_elsewhere!(slot, PACK_BACKDROP_LINE)
        refuse_slot_read_wrongly!(slot, :colors, PACK_BACKDROP_LINE)
        place = 0 if place.nil?
        return place if place.is_a?(Integer) && place.between?(0, slot.count - 1)

        raise ArgumentError, "`screen ... backdrop_place: #{place.inspect}` asks for a place that the backdrop's colors " \
                             "do not have. backdrop: was given #{slot.count} colors of slot :#{slot.layout.name}, at " \
                             "places 0 to #{slot.count - 1}. To fix this, use a place in that range."
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
        refuse_slot_on_first_screen!(handle)
        # A view of a slot (Original::Slot#viewed) is this pack's where the slot it reads is.
        declared = handle.layout.declared
        return if @data_pack_slots&.fetch(declared.name, nil) == declared

        raise ArgumentError, "#{where} was given slot :#{handle.layout.name}, and this game's data pack has no such slot. " \
                             "Use a slot from this game's `data_pack`."
      end

      # What each way of reading a slot needs, in words, for the error.
      SLOT_READING_WORDS = { colors: "a slot of colors", tile: "one tile, like `pack[:walls].tile(0)`",
                             numbers: "a slot of numbers", samples: "a slot of samples" }.freeze

      def refuse_slot_read_wrongly!(handle, wanted, where)
        # A run of a slot of numbers is a background's map alone (PackBackgrounds#pack_map_cells).
        fits = wanted == :tile ? handle.one_tile? : handle.shape == wanted && !handle.one_tile? && !handle.run_of_numbers?
        return if fits

        given = if handle.one_tile? then "one tile of slot :#{handle.layout.name}"
                elsif handle.run_of_numbers? then "some of the numbers of slot :#{handle.layout.name}"
                else "slot :#{handle.layout.name}, which holds #{handle.shape}"
                end
        raise ArgumentError, "#{where} was given #{given}. It must be given #{SLOT_READING_WORDS.fetch(wanted)}."
      end
    end
  end
end
