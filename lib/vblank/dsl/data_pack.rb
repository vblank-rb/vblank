# frozen_string_literal: true

module VBlank
  module DSL
    # The slots of a data pack
    #
    # The `data_pack` block is handed this, and each line of the block names one slot of the pack:
    # its name, its shape, how many it holds, and where in the player's copy of the original it is.
    #
    # ```ruby
    # data_pack from: original, version: "1.0" do |slots|
    #   slots.colors  :palette, at: 0x1000, count: 16
    #   slots.tiles   :walls,   at: 0x1020, count: 40
    #   slots.numbers :speeds,  at: 0x2000, count: 8, width: :byte, signed: false
    #   slots.tiles   :sprites, count: 64                    # no at: the routine below fills it
    #   slots.fill_from_copy do |copy, pack|
    #     copy.unpack_lz77 at: 0x3000, into: pack[:sprites]
    #   end
    # end
    # ```
    #
    # A slot with no `at:` is filled by the game's own unpacking routine, the block given to
    # #fill_from_copy.
    #
    # Each slot is kept in the layout of the console the original is for, unless it names another
    # with `layout:`. An original for a machine whose layout VBlank does not read (a PlayStation, a
    # computer, any other) is kept in VBlank's own layout, which its routine writes. A computer
    # game's numbers can name their `byte_order:` instead.
    #
    # ```ruby
    # slots.tiles :walls, at: 0x4000, count: 64, colors: 4    # a Super Nintendo's tiles of four colours
    # slots.numbers :sizes, count: 9, width: :half, signed: false   # a computer game's, low byte first
    # slots.numbers :sizes, count: 9, width: :half, signed: false, byte_order: :high_first
    # slots.colors :palette, count: 16                        # a computer game's, as its routine writes them
    # slots.colors :palette, count: 16, layout: :gba          # the same, a console's layout as a shortcut
    # ```
    #
    # ### What every slot takes
    #
    # * `at:` - the byte of the copy the slot starts at. Left out, the unpacking routine fills it.
    # * `cost:` - how many times the work of a plain copy one of its bytes takes to unpack: 1 unless
    #   the routine works hard for it (`cost: 40` for a slot it renders sound into). A shell's bar
    #   then moves by the work done rather than the bytes written.
    # * `pieces:` - for a slot with no `at:`, written a piece at a time by a part of the routine
    #   given as many pieces (#fill_from_copy): a number of equal pieces, or the items of each piece
    #   in order (`pieces: [4410, 8820, 2205]`).
    #--
    # How and where the routine runs: Builder::DataPacks. The platform is the original's
    # Original::Game#platform, and VBlank's own layout is Console::VBLANK_FORMATS. Why pieces:
    # Original::PiecedUnpacking. The cost: Original::Slot#cost.
    #++
    class PackSlots
      def initialize(platform:)
        @layout = Original.layout_for(platform)
        @list = []
        @routines = []
      end

      # One part of the unpacking routine: its +part+ name (nil for a routine of one part), its block,
      # and how many +pieces+ it writes, a piece each time its block is built (nil for a part that
      # is not in pieces).
      Routine = Data.define(:part, :block, :pieces) do # :nodoc:
        def initialize(part:, block:, pieces: nil) = super

        def pieced? = !pieces.nil?
      end

      # The slots named so far, in order, and the parts of the unpacking routine (each a Routine),
      # in the order they run; none for a pack with no routine.
      attr_reader :list, :routines # :nodoc:

      # Names a slot of colours, two bytes each, for an image's `colors:`.
      #
      # ```ruby
      # slots.colors :palette, at: 0x1000, count: 16
      # ```
      #
      # * `count:` - how many colours.
      # * `layout:` - the console whose layout the colours are kept in, such as `:gba`.
      def colors(name, count:, at: nil, layout: nil, cost: 1, pieces: nil)
        add(pieces, Original::Slot.colors(name, at: at, count: count, layout: layout || @layout, cost: cost))
      end

      # Names a slot of tiles of 8x8 pixels, for an image's `places:`.
      #
      # ```ruby
      # slots.tiles :walls, at: 0x1020, count: 40
      # ```
      #
      # * `count:` - how many tiles.
      # * `colors:` - how many colours a tile has, where the layout keeps more than one kind.
      #   `colors: 256` is a tile kept a byte a pixel, 64 bytes, in any layout: the pictures of a
      #   background that turns and resizes.
      # * `layout:` - the console whose layout the tiles are kept in.
      def tiles(name, count:, at: nil, colors: nil, layout: nil, cost: 1, pieces: nil)
        add(pieces, Original::Slot.tiles(name, at: at, count: count, colors: colors, layout: layout || @layout, cost: cost))
      end

      # Names a slot of numbers, for a `table` or a setting read from the pack.
      #
      # ```ruby
      # slots.numbers :speeds, at: 0x2000, count: 8, width: :byte, signed: false
      # ```
      #
      # * `count:` - how many numbers.
      # * `width:` - how wide each is: `:byte`, `:half` or `:word`.
      # * `signed:` - true when they can be below 0.
      # * `layout:` - the console whose layout the numbers are kept in.
      # * `byte_order:` - `:low_first` or `:high_first`, in place of a console's layout.
      def numbers(name, count:, width:, signed:, at: nil, layout: nil, byte_order: nil, cost: 1, pieces: nil)
        add(pieces, Original::Slot.numbers(name, at: at, count: count, width: width, signed: signed,
                                         layout: layout || (@layout unless byte_order), byte_order: byte_order, cost: cost))
      end

      # Names a slot of pixels, one byte each: a picture of up to 256 colours, row by row.
      #
      # It is for an image's `places:`.
      #
      # ```ruby
      # slots.pixels :art, at: 0x8000, count: 64 * 64
      # image :art, width: 64, height: 64, colors: shades, places: pack[:art], see_through: 255
      # ```
      #
      # * `count:` - how many pixels.
      def pixels(name, count:, at: nil, cost: 1, pieces: nil) = add(pieces, Original::Slot.pixels(name, at: at, count: count, cost: cost))

      # Names a slot of recorded sound, one signed byte a sample, for a recording's `pcm:`.
      #
      # ```ruby
      # slots.samples :bang, at: 0x9000, count: 2000
      # sample :bang, pcm: pack[:bang], rate: 7000
      # ```
      #
      # * `count:` - how many samples.
      def samples(name, count:, at: nil, cost: 1, pieces: nil) = add(pieces, Original::Slot.samples(name, at: at, count: count, cost: cost))

      # Names a slot of notes of music, which the unpacking routine writes from the original's
      # songs, for a part of a song.
      #
      # ```ruby
      # slots.notes :theme, count: 400
      # # a part of a song plays them with notes: pack[:theme].notes(instruments: %i[horn])
      # ```
      #
      # * `count:` - how many notes.
      #--
      # Each note is an Original::PackNote record.
      #++
      def notes(name, count:, at: nil, cost: 1, pieces: nil) = add(pieces, Original::Slot.notes(name, at: at, count: count, cost: cost))

      # Names a slot of notes of music, each with its voice's settings, for a part of a song.
      #
      # Each note keeps its pitch number, fade, duty, vibrato, slide and shade between the speakers,
      # which the unpacking routine writes as the original's sound driver sets them.
      #
      # * `count:` - how many notes.
      #--
      # Each note is a voiced Original::PackNote record.
      #++
      def voiced_notes(name, count:, at: nil, cost: 1, pieces: nil) = add(pieces, Original::Slot.voiced_notes(name, at: at, count: count, cost: cost))

      # Names a slot of the cells of a background's map, which the unpacking routine writes from
      # the original's maps, for a background's `map:`.
      #
      # ```ruby
      # slots.map_cells :title_map, count: 32 * 32
      # # the routine writes each: pack[:title_map].write_cell(at, tile: tile, bank: bank)
      # ```
      #
      # * `count:` - how many cells.
      #--
      # Each cell is an Original::MapCell.
      #++
      def map_cells(name, count:, at: nil, cost: 1, pieces: nil) = add(pieces, Original::Slot.map_cells(name, at: at, count: count, cost: cost))

      # Gives the game's unpacking routine, which fills the slots with no `at:` from the player's
      # copy.
      #
      # The block is game code. It is handed the copy's bytes, the pack's slots to write and, if it
      # takes a third argument, the name of the release it unpacks: a plain String as the game is
      # built, so Ruby can choose the places release by release.
      #
      # ```ruby
      # slots.fill_from_copy do |copy, pack, release|
      #   copy.unpack_lz77 at: (release == "EU" ? 0x3040 : 0x3000), into: pack[:sprites]
      # end
      # ```
      #
      # ### A routine in parts
      #
      # A routine can be given as several named parts, which run one after another in the order
      # given, as one routine would.
      #
      # ```ruby
      # slots.fill_from_copy(:floors) { |copy, pack| ... }
      # slots.fill_from_copy(:music) { |copy, pack| ... }
      # ```
      #
      # The pack is the same either way. What the parts change is the pack cache: it keeps each
      # part's slots apart, so a change to one part plays that part again, and what reads from it,
      # and takes every other part's slots from the cache.
      #
      # ### A part in pieces
      #
      # A part in pieces writes slots named with `pieces:` a piece at a time. Its block is built
      # once, and handed the piece's number after the release, 0 first, as a number the routine
      # reads as it runs, the way a `repeat`'s index is.
      #
      # ```ruby
      # slots.fill_from_copy(:music, pieces: 27) do |copy, pack, release, song|
      #   pack[:music].piece(song)[i] = sample      # i counts from the piece's first item
      # end
      # ```
      #
      # The pack is the same as a part that writes every piece in turn. What the pieces change is
      # how fast a player's machine can make it: each piece reads nothing another part writes, so a
      # shell can unpack the pieces side by side.
      #
      # * `part` - the part's name, as a symbol. Each part of a routine of several parts has one.
      # * `pieces:` - how many pieces the part writes, 1 or more.
      #--
      # The copy is an Original::CopyReader and the slots an Original::UnpackingSlots. The cache is
      # Original::PackCache, and the pieces are Original::PiecedUnpacking.
      #++
      def fill_from_copy(part = nil, pieces: nil, &block)
        unless block
          raise ArgumentError, "`slots.fill_from_copy` needs a block: `slots.fill_from_copy do |copy, pack| ... end`."
        end

        refuse_part_name_not_symbol!(part)
        refuse_unnamed_part!(part)
        refuse_part_named_twice!(part)
        refuse_pieces_not_whole_number!(part, pieces)
        @routines << Routine.new(part: part, block: block, pieces: pieces)
        nil
      end

      private

      def refuse_pieces_not_whole_number!(part, pieces)
        return if pieces.nil? || (pieces.is_a?(Integer) && pieces.positive?)

        raise ArgumentError, "`slots.fill_from_copy#{" :#{part}" if part}` was given pieces: #{pieces.inspect}. pieces: is how " \
                             "many pieces the part writes, 1 or more: `slots.fill_from_copy :music, pieces: 27 do ... end`."
      end

      def refuse_part_name_not_symbol!(part)
        return if part.nil? || part.is_a?(Symbol)

        raise ArgumentError, "`slots.fill_from_copy` was given #{part.inspect}. It takes the name of a part of the " \
                             "routine as a symbol: `slots.fill_from_copy :music do |copy, pack| ... end`."
      end

      # A routine of several parts names each one, so the cache and its errors can tell them apart.
      def refuse_unnamed_part!(part)
        return if @routines.empty? || (part && @routines.all?(&:part))

        raise ArgumentError, "The data pack calls `slots.fill_from_copy` more than once, and one call has no name. When the " \
                             "routine has more than one part, each part must have a name: " \
                             "`slots.fill_from_copy :music do |copy, pack| ... end`."
      end

      def refuse_part_named_twice!(part)
        return unless part && @routines.any? { |routine| routine.part == part }

        raise ArgumentError, "The data pack names the part :#{part} of its routine twice. Give each part a name of its own."
      end

      def add(pieces, slot)
        if @list.any? { |named| named.name == slot.name }
          raise ArgumentError, "The data pack names slot :#{slot.name} twice. Give each slot a name of its own."
        end

        @list << (pieces.nil? ? slot : slot.in_pieces(pieces))
        nil
      end
    end

    # A data pack
    #
    # A data pack is the original's data, read from the player's own copy. `data_pack` hands one
    # back, and the game takes a handle on each slot by its name.
    #
    # ```ruby
    # image :wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
    # table :speeds, pack[:speeds]
    # ```
    #
    # The game never holds what a slot holds. A handle gives the slot's shape and size, and the
    # verb given it reads the slot. So nothing the game does while it is built can depend on the
    # original's bytes, and a build that reads the pack only as the game starts makes the same game.
    class DataPack
      # +rom_sha1+ is the SHA-1 of the copy the build made the pack from (nil for a build that
      # leaves the pack out, which reads no copy), +build_version+ the build it names, +slots+ the
      # Original::Slot list. +make_unpacking+ makes the Original::Unpacking that fills such a pack,
      # handed the release, when something asks for it, and keeps what it made: a pack whose every
      # slot is copied as it is never needs its program built as the game is. +original+ is what `from:`
      # named (an Original::Game, or an Original::Copy), which a shell reads the releases of.
      # +platform+ is the console the original is for, whose layout a view of a slot is read in
      # where it names none (PackSlot#as_tiles).
      # +make_unpacking_parts+ makes the Original::UnpackingParts of an all-in-one build's routine in
      # parts (nil for any other).
      # +make_pieced_unpacking+ makes the Original::PiecedUnpacking of the routine, handed the
      # release as +make_unpacking+ is, or nil where no part of it is in pieces.
      def initialize(rom_sha1:, build_version:, slots:, make_unpacking:, original: nil, platform: Original::DEFAULT_PLATFORM,
                     make_unpacking_parts: nil, make_pieced_unpacking: ->(_release) {})
        @rom_sha1 = rom_sha1
        @build_version = build_version
        @slots = slots.to_h { |slot| [slot.name, slot] }
        @make_unpacking = make_unpacking
        @make_pieced_unpacking = make_pieced_unpacking
        @make_unpacking_parts = make_unpacking_parts
        @original = original
        @platform = platform
      end

      # The pack's header and where it came from.
      #
      # `rom_sha1` is the SHA-1 of the player's copy the pack was made from, or nil for a build that
      # leaves the pack out, which reads no copy. `build_version` is the version given to
      # `data_pack version:`. `original` is what `data_pack from:` named.
      attr_reader :rom_sha1, :build_version, :original

      # Every slot (Original::Slot), in the pack's order.
      def slots = @slots.values # :nodoc:

      # The pack's unpacking as a program of its own: what a shell runs on the player's machine to
      # make the pack, and what a game's test plays.
      #
      # Each release has a program of its own, since the slots' places or the routine can differ
      # by release. A build that leaves the pack out reads no copy, so its unpacking is built for a
      # copy the size of the release given. An all-in-one build's holds the copy it read, and needs
      # no release.
      #
      # The program writes a record of each frame of a sprite the game has named by then. So ask
      # for it once the game is declared: a frame named after that is refused, since the program
      # made already would not write it.
      #
      # ```ruby
      # run = pack.unpacking(release: RELEASE).run_fastest
      # ```
      #
      # * `release:` - the release of the original to unpack, for a build that leaves the pack out.
      #--
      # An Original::Unpacking; the release is an Original::Release. The frame records are
      # Original::FrameRewrite, and the refusal is Builder::PackPoses#pack_frame_number.
      #++
      def unpacking(release: nil) = @make_unpacking.call(release)

      # The same unpacking split for several workers, or nil where no part of the routine is in
      # pieces.
      #
      # It is what a shell plays on a player's machine with more than one worker, and what a
      # game's test holds to the pack #unpacking makes.
      #
      # * `release:` - as #unpacking takes it.
      #--
      # An Original::PiecedUnpacking.
      #++
      def pieced_unpacking(release: nil) = @make_pieced_unpacking.call(release)

      # The parts of an all-in-one build's routine, which the pack cache keeps apart, for a game's
      # test of its own cache beside #unpacking.
      #
      # It is nil for a routine of one part, for a build that leaves the pack out, and where a part
      # cannot be built as a program of its own.
      #--
      # An Original::UnpackingParts.
      #++
      def unpacking_parts = @make_unpacking_parts&.call

      # A handle on the slot of that name, for the verbs that read a slot.
      #
      # A name the pack has no slot for is a friendly error.
      #
      # ```ruby
      # table :speeds, pack[:speeds]
      # ```
      def [](name)
        slot = @slots.fetch(name.to_sym) do
          raise ArgumentError, "The data pack has no slot #{name.inspect}. It has #{@slots.keys.map(&:inspect).join(', ')}. " \
                               "Name the slot in the data_pack block first."
        end
        PackSlot.new(layout: slot, tile_index: nil, platform: @platform)
      end
    end

    # A frame of a sprite in the pack
    #
    # PackSlot#frame hands one back: the frame of a sprite kept from a byte of a slot of bytes, in
    # the way the original keeps its frames. An image's `frame:` takes it.
    #
    # ```ruby
    # image :hero, frame: pack[:frames].frame(0x40, layout: FRAMES)
    # ```
    #--
    # +slot+ is the slot's handle, +at+ the byte the frame starts at, +count+ how many pieces it has
    # where its layout does not say, +piece_layout+ how it is kept (an Original::FrameLayout), and
    # +pose+ the values the pose gives that layout's reader, by name. Builder::PackPoses reads it.
    #++
    PackFrame = Data.define(:slot, :at, :count, :piece_layout, :pose)

    # A part's notes in the pack
    #
    # PackSlot#notes hands one back: a slot of notes, with the instruments a note's number names
    # and the waves a voiced note's wave number names. A part of a song takes it as its `notes:`.
    #
    # ```ruby
    # notes: pack[:theme].notes(instruments: %i[horn])
    # ```
    PackNotes = Data.define(:slot, :instruments, :waves) do
      def initialize(waves: [], **) = super
    end

    # A number of the pack
    #
    # PackSlot#number hands one back: one number of a slot of numbers, for a setting read as the
    # game is built, such as an instrument's `rate:` or `holds_from:`.
    PackNumber = Data.define(:slot, :index)

    # An envelope of the pack
    #
    # PackSlot#envelope hands one back: four bytes of a slot of bytes (attack, decay, sustain and
    # release), read as the game is built, for an instrument's `envelope:`.
    PackEnvelope = Data.define(:slot, :index)

    # A Super Nintendo envelope of the pack
    #
    # PackSlot#snes_envelope hands one back: three bytes of a slot of bytes, as the Super
    # Nintendo's sound chip keeps an envelope, for an instrument's `envelope:`.
    PackSNESEnvelope = Data.define(:slot, :index)

    # A map of the pack that knows its size
    #
    # PackSlot#as_map hands one back: a map's slot, a whole slot or a run of one, with how many
    # cells a row of it holds. A background given it needs no `across:`, and a background walking
    # between areas of different sizes is handed one for each area.
    #
    # ```ruby
    # background :title, map: pack[:title_map].as_map(across: 32)
    # ```
    #--
    # Builder::PackBackgrounds#pack_map_slot_and_across! reads it.
    #++
    PackMap = Data.define(:slot, :across) do
      # How many rows the map's cells make.
      def down = slot.count / across
    end

    # A wave of the pack
    #
    # PackSlot#wave hands one back: one wave for the wave voice, sixteen bytes of a slot of bytes,
    # for a part of a song's `plays:`. Each byte holds two steps of the wave, the earlier in the
    # high four bits, as the Game Boy's wave memory keeps them (Pan Docs, "Audio Registers", wave
    # pattern RAM).
    #
    # ```ruby
    # plays: pack[:waves].wave(0)
    # ```
    #--
    # Audio::Sound.wave_steps_of_bytes reads the bytes as steps.
    #++
    PackWave = Data.define(:slot, :index)

    class PackWave
      BYTES = Audio::Sound::WAVE_BYTES # :nodoc:

      # The 32 steps, 0 to 15 each, of the wave's +bytes+ (a list of sixteen numbers).
      def self.steps_of(bytes) = Audio::Sound.wave_steps_of_bytes(bytes) # :nodoc:

      # Where the wave's first byte is in its slot.
      def first_byte = index * BYTES # :nodoc:
    end

    # A table's entries in the start file
    #
    # A game built with its pack left out is handed a file as it starts, and a `table` can read its
    # entries from any place in that file: `count` entries from byte `at` on, given to `table` in
    # place of its numbers. The game must read such a file, which `data_pack` with the pack left out
    # declares it does.
    #
    # ```ruby
    # table :speeds, DSL::StartFileEntries.new(at: 0x40, count: 8), width: :byte, signed: false
    # ```
    #
    # Each entry is kept low byte first unless `format:` says otherwise.
    #--
    # The file is IR::StartFile. Its unpacking reads the copy this way too. +format+ is a
    # Console::NumberFormat.
    #++
    StartFileEntries = Data.define(:at, :count, :format) do
      def initialize(at:, count:, format: Console::LOW_BYTE_FIRST_NUMBERS) = super
    end

    # A slot of a data pack
    #
    # `pack[:name]` hands one back: a handle on one slot of the pack, or on some of it, such as
    # tiles of a slot of tiles or pixels of a slot of pixels. It never holds the bytes: the verbs
    # given it, such as `image` and `table`, read them.
    #
    # ```ruby
    # image :wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
    # table :speeds, pack[:speeds]
    # ```
    #
    # A handle on tiles counts them left to right and then top to bottom, as a sprite keeps its
    # tiles: a picture of 16x16 pixels is 2 tiles across and 2 down. A handle on a bank is some of
    # a slot of colours, as a console's palette keeps them in banks of 16. A handle on pixels is the
    # places of one picture among several kept in one slot: `pack[:walls].pixels(64 * 64 * 3, 64 * 64)`
    # is the fourth picture of 64x64.
    #
    # ### Views
    #
    # A view is some of a slot's bytes read in a shape of their own. A console keeps its tiles of
    # both kinds and its maps in one block of video memory, and a port that keeps the block as one
    # slot reads each part of it through a view.
    #
    # ```ruby
    # video = pack[:video]                                   # slots.tiles :video, count: 2048
    # pictures = video.as_tiles(at: 0x8000, count: 256, colors: 256)
    # cells    = video.as_numbers(at: 0xC000, count: 1024, width: :byte, signed: false)
    # ```
    #
    # Each view takes what the `slots.` line of its shape takes, and every verb takes it as it
    # takes a slot of that shape. A view narrows as a slot does (`.tile(4)`, `.numbers(first, count)`).
    # Each view counts `at:` in bytes from the start of the slot, 0 first. With `count:` left out, it
    # reads to the end of the slot, and a view that ends after the slot ends is refused. Where a
    # view names no `layout:`, it is read in the layout of the console the original is for.
    #--
    # +layout+ is an Original::Slot: its name, shape, size and place in the copy; a view's is
    # Original::Slot#viewed. Builder::DataPacks#pack_slot_values reads the bytes. A handle on tiles
    # is +across+ by +down+ tiles from +tile_index+; a bank is +color_count+ colours from
    # +first_color+; a run of pixels is +pixel_count+ from +first_pixel+. +platform+ is the console
    # the original is for.
    #++
    PackSlot = Data.define(:layout, :tile_index, :across, :down, :first_color, :color_count, :first_pixel, :pixel_count,
                           :platform) do
      def initialize(layout:, tile_index: nil, across: 1, down: 1, first_color: nil, color_count: nil, first_pixel: 0,
                     pixel_count: nil, platform: Original::DEFAULT_PLATFORM) = super

      # What the slot holds: `:colors`, `:tiles`, `:numbers`, `:pixels`, `:samples`, `:notes`,
      # `:voiced_notes` or `:map_cells`.
      def shape = layout.shape

      # A view of the slot as tiles of 8x8 pixels.
      #
      # ```ruby
      # pictures = pack[:video].as_tiles(at: 0x8000, count: 256, colors: 256)
      # ```
      #
      # * `at:` - the byte of the slot the view starts at.
      # * `count:` - how many tiles. Left out, to the end of the slot.
      # * `colors:` - how many colours a tile has, where the layout keeps more than one kind.
      # * `layout:` - the console whose layout the tiles are kept in.
      def as_tiles(at:, count: nil, colors: nil, layout: nil)
        console = layout || Original.layout_for(platform)
        view("as_tiles", at, count) { |name, held| Original::Slot.tiles(name, count: held, colors: colors, layout: console) }
      end

      # A view of the slot as numbers.
      #
      # ```ruby
      # cells = pack[:video].as_numbers(at: 0xC000, count: 1024, width: :byte, signed: false)
      # ```
      #
      # * `at:` - the byte of the slot the view starts at.
      # * `width:` - how wide each number is: `:byte`, `:half` or `:word`.
      # * `signed:` - true when they can be below 0.
      # * `count:` - how many numbers. Left out, to the end of the slot.
      # * `layout:` - the console whose layout the numbers are kept in.
      # * `byte_order:` - `:low_first` or `:high_first`, in place of a console's layout.
      def as_numbers(at:, width:, signed:, count: nil, layout: nil, byte_order: nil)
        console = layout || (Original.layout_for(platform) unless byte_order)
        view("as_numbers", at, count) do |name, held|
          Original::Slot.numbers(name, count: held, width: width, signed: signed, layout: console, byte_order: byte_order)
        end
      end

      # A view of the slot as colours, two bytes each.
      #
      # * `at:` - the byte of the slot the view starts at.
      # * `count:` - how many colours. Left out, to the end of the slot.
      # * `layout:` - the console whose layout the colours are kept in.
      def as_colors(at:, count: nil, layout: nil)
        console = layout || Original.layout_for(platform)
        view("as_colors", at, count) { |name, held| Original::Slot.colors(name, count: held, layout: console) }
      end

      # A view of the slot as pixels, one byte each.
      #
      # * `at:` - the byte of the slot the view starts at.
      # * `count:` - how many pixels. Left out, to the end of the slot.
      def as_pixels(at:, count: nil) = view("as_pixels", at, count) { |name, held| Original::Slot.pixels(name, count: held) }

      # A view of the slot as recorded sound, one byte a sample.
      #
      # * `at:` - the byte of the slot the view starts at.
      # * `count:` - how many samples. Left out, to the end of the slot.
      def as_samples(at:, count: nil) = view("as_samples", at, count) { |name, held| Original::Slot.samples(name, count: held) }

      # A view of the slot as notes of music.
      #
      # The notes of several parts can be kept in one slot, and each part's read through a view
      # of its own.
      #
      # * `at:` - the byte of the slot the view starts at.
      # * `count:` - how many notes. Left out, to the end of the slot.
      # * `voiced:` - true for notes with their voice's settings, as `slots.voiced_notes` keeps them.
      #--
      # Each note is an Original::PackNote record.
      #++
      def as_notes(at:, count: nil, voiced: false)
        view("as_notes", at, count) do |name, held|
          voiced ? Original::Slot.voiced_notes(name, count: held) : Original::Slot.notes(name, count: held)
        end
      end

      # Whether the handle is on a whole slot or a whole view: no tiles, bank or run picked from it.
      def whole? = tile_index.nil? && first_color.nil? && pixel_count.nil? # :nodoc:

      # How many things the handle reads.
      #
      # That is the slot's count, the tiles of a handle on tiles, the colours of a bank, or the
      # pixels of a handle on pixels.
      def count
        return across * down if tile_index
        return color_count if first_color

        pixel_count || layout.count
      end

      # A handle on some of the pixels of a slot of pixels, for an image's `places:`.
      #
      # ```ruby
      # places: pack[:walls].pixels(64 * 64 * 3, 64 * 64)   # the fourth picture of 64x64
      # ```
      #
      # * `first` - the first pixel, 0 first.
      # * `count` - how many pixels.
      def pixels(first, count) = bytes_run(:pixels, first, count)

      # A handle on some of the samples of a slot of recorded sound, for a recording's `pcm:`.
      #
      # ```ruby
      # sample :bang, pcm: pack[:sounds].samples(first, count), rate: 7000
      # ```
      #
      # * `first` - the first sample, 0 first.
      # * `count` - how many samples.
      def samples(first, count) = bytes_run(:samples, first, count)

      # A handle on some of the numbers of a slot of numbers.
      #
      # It is for a background's `map:` kept among other things in a bigger slot, as a console
      # keeps a map in a block of its video memory.
      #
      # * `first` - the first number, 0 first.
      # * `count` - how many numbers.
      def numbers(first, count) = bytes_run(:numbers, first, count)

      # Whether the handle is on a run of a slot of numbers, and not on the whole slot.
      def run_of_numbers? = shape == :numbers && !pixel_count.nil? # :nodoc:

      # Whether the handle is on a bank of colours.
      def bank? = !first_color.nil? # :nodoc:

      # Whether the handle is on tiles, one or more.
      def one_tile? = !tile_index.nil? # :nodoc:

      # A handle on one bank of a slot of colours, for an image's `colors:`.
      #
      # ```ruby
      # image :hero, width: 16, height: 16, colors: pack[:palette].bank(1), places: pack[:sprites].tiles(0, across: 2, down: 2)
      # ```
      #
      # * `index` - which bank, 0 first.
      # * `size:` - how many colours a bank holds.
      def bank(index, size: 16)
        unless shape == :colors && !bank?
          raise ArgumentError, "Slot :#{layout.name} holds #{shape}. `bank` picks a bank of a slot of colours. " \
                               "To fix this, call it on a slot of colours."
        end
        unless [index, size].all?(Integer) && size.positive? && index >= 0 && (index + 1) * size <= layout.count
          raise ArgumentError, "Slot :#{layout.name} holds #{layout.count} colors. There is no bank #{index.inspect} of " \
                               "#{size.inspect} colors in it."
        end

        with(first_color: index * size, color_count: size)
      end

      # A handle on a slot of notes as a part of a song plays them, for the part's `notes:`.
      #
      # ```ruby
      # notes: pack[:theme].notes(instruments: %i[horn])
      # ```
      #
      # * `instruments:` - the recordings a note's instrument number counts through, 0 first.
      # * `waves:` - for a part on the wave voice, the waves a voiced note's wave number counts
      #   through, 0 first: each a shape, 32 steps, or a wave of the pack (`pack[:waves].wave(2)`),
      #   as a part's `plays:` takes them.
      #--
      # The wave number is Original::PackNote's byte 26.
      #++
      def notes(instruments: [], waves: [])
        unless Original::Slot::NOTE_SHAPES.include?(shape)
          raise ArgumentError, "Slot :#{layout.name} holds #{shape}. `notes` reads a slot of notes. To fix this, call " \
                               "it on a slot like `slots.notes :theme, count: 400`."
        end

        DSL::PackNotes.new(slot: self, instruments: instruments, waves: waves)
      end

      # A handle on one wave of a slot of bytes, sixteen bytes a wave, for the wave a part of a
      # song plays.
      #
      # ```ruby
      # plays: pack[:waves].wave(0)
      # ```
      #
      # PackWave says how a wave is kept.
      #
      # * `index` - which wave, 0 first.
      def wave(index)
        refuse_run_counted_from_slot_start!("wave")
        unless shape == :numbers && layout.width == :byte && index.is_a?(Integer) && !index.negative? &&
               (index + 1) * PackWave::BYTES <= layout.count
          raise ArgumentError, "Slot :#{layout.name} holds #{layout.count} #{shape}. `wave` picks #{PackWave::BYTES} " \
                               "bytes of a slot of bytes, two steps of the wave a byte. Got #{Messages::PlainWords.words_for_given(index)}."
        end

        DSL::PackWave.new(slot: self, index: index)
      end

      # A handle on one number of a slot of numbers, for a setting read as the game is built: an
      # instrument's `rate:` or `holds_from:`.
      #
      # ```ruby
      # rate: pack[:rates].number(3)
      # ```
      #
      # * `index` - which number, 0 first.
      def number(index)
        refuse_run_counted_from_slot_start!("number")
        unless shape == :numbers && index.is_a?(Integer) && index.between?(0, layout.count - 1)
          raise ArgumentError, "Slot :#{layout.name} holds #{layout.count} #{shape}. `number` picks one number of a slot " \
                               "of numbers, 0 to #{layout.count - 1}. Got #{Messages::PlainWords.words_for_given(index)}."
        end

        DSL::PackNumber.new(slot: self, index: index)
      end

      # A handle on one envelope of a slot of bytes, for an instrument's `envelope:`.
      #
      # Each envelope is four bytes: attack, decay, sustain and release.
      #
      # ```ruby
      # envelope: pack[:envelopes].envelope(2)
      # ```
      #
      # * `index` - which envelope, 0 first.
      #--
      # The order is Audio::Envelope's.
      #++
      def envelope(index)
        refuse_run_counted_from_slot_start!("envelope")
        unless shape == :numbers && layout.width == :byte && index.is_a?(Integer) && !index.negative? &&
               (index + 1) * 4 <= layout.count
          raise ArgumentError, "Slot :#{layout.name} holds #{layout.count} #{shape}. `envelope` picks four bytes of a " \
                               "slot of numbers one byte wide, envelope 0 from byte 0. There is no envelope " \
                               "#{index.inspect} in it."
        end

        DSL::PackEnvelope.new(slot: self, index: index)
      end

      # A handle on one envelope of a slot of bytes as the Super Nintendo's sound chip keeps it,
      # for an instrument's `envelope:`.
      #
      # Each envelope is three bytes: the chip's ADSR1, ADSR2 and GAIN (fullsnes, "SNES APU DSP
      # ADSR/Gain Envelope").
      #
      # * `index` - which envelope, 0 first.
      #--
      # Read as an Audio::SNESEnvelope.
      #++
      def snes_envelope(index)
        refuse_run_counted_from_slot_start!("snes_envelope")
        unless shape == :numbers && layout.width == :byte && index.is_a?(Integer) && !index.negative? &&
               (index + 1) * 3 <= layout.count
          raise ArgumentError, "Slot :#{layout.name} holds #{layout.count} #{shape}. `snes_envelope` picks three bytes " \
                               "of a slot of numbers one byte wide, envelope 0 from byte 0. There is no envelope " \
                               "#{index.inspect} in it."
        end

        DSL::PackSNESEnvelope.new(slot: self, index: index)
      end

      # A handle on the frame of a sprite kept in a slot of bytes, for an image's `frame:`.
      #
      # ```ruby
      # image :hero, frame: pack[:frames].frame(0x40, layout: FRAMES, with: { block: 5 })
      # ```
      #
      # * `at` - the byte the frame starts at, 0 first. On a view of numbers (#as_numbers) it counts
      #   from the view's first byte.
      # * `layout:` - how the original keeps a frame: a VBlank::Original::FrameLayout.
      # * `count:` - how many pieces the frame has, for a layout whose frames do not say.
      # * `with:` - the values the pose gives the layout's own reader, by name. Each is checked
      #   against those the reader reads.
      #--
      # The pack's unpacking finds a view's frame in the slot the view reads
      # (Builder::PackPoses#frame_source).
      #++
      def frame(at, layout:, count: nil, with: {})
        # +layout+ here is the frame's; the slot's own is self.layout.
        refuse_run_counted_from_slot_start!("frame")
        unless shape == :numbers && self.layout.width == :byte
          raise ArgumentError, "Slot :#{self.layout.name} holds #{shape}. `frame` reads a frame from a slot of numbers one " \
                               "byte wide. To fix this, call it on a slot like `slots.numbers :frames, width: :byte, ...`, " \
                               "or on a view like `pack[:#{self.layout.declared.name}].as_numbers(at: ..., width: :byte, ...)`."
        end

        unless layout.is_a?(Original::FrameLayout)
          raise ArgumentError, "`frame` was given layout: #{layout.inspect}. To fix this, give it a " \
                               "VBlank::Original::FrameLayout, which says how the original keeps a frame."
        end

        DSL::PackFrame.new(slot: self, at: at, count: count, piece_layout: layout, pose: layout.pose_values_for(with))
      end

      # The slot as a map that knows its size, for a background's `map:`, which then needs no
      # `across:`.
      #
      # ```ruby
      # background :title, map: pack[:title_map].as_map(across: 32)
      # ```
      #
      # * `across:` - how many cells a row of the map holds. The slot's cells must divide by it.
      # * `down:` - how many rows, checked against the rows the cells make.
      def as_map(across:, down: nil)
        unless %i[map_cells numbers].include?(shape)
          raise ArgumentError, "Slot :#{layout.name} holds #{shape}. `as_map` reads a slot of map cells or of numbers " \
                               "as a map. To fix this, call it on the map's slot."
        end
        unless across.is_a?(Integer) && across.positive? && (count % across).zero?
          raise ArgumentError, "`as_map` on slot :#{layout.name} was given across: " \
                               "#{Messages::PlainWords.words_for_given(across)}. across: is how many cells a row of " \
                               "the map holds. It must be a whole number that the map's #{count} cells divide by."
        end
        unless down.nil? || down == count / across
          raise ArgumentError, "`as_map` on slot :#{layout.name} was given down: #{down.inspect}. Its #{count} cells, " \
                               "#{across} across, make #{count / across} rows. To fix this, give down: " \
                               "#{count / across}, or leave it out."
        end

        DSL::PackMap.new(slot: self, across: across)
      end

      # A handle on one tile of a slot of tiles, for an image's `places:`.
      #
      # ```ruby
      # image :wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
      # ```
      #
      # * `index` - which tile, 0 first.
      def tile(index) = tiles(index, across: 1, down: 1)

      # A handle on tiles side by side in a slot of tiles, for the `places:` of a picture 8 pixels
      # wider for each tile across and 8 taller for each tile down.
      #
      # ```ruby
      # places: pack[:sprites].tiles(0, across: 2, down: 2)   # a picture of 16x16 pixels
      # ```
      #
      # * `first` - the first tile, 0 first.
      # * `across:` - how many tiles across.
      # * `down:` - how many tiles down.
      def tiles(first, across:, down: 1)
        unless shape == :tiles && !one_tile?
          raise ArgumentError, "Slot :#{layout.name} holds #{shape}. `tile` and `tiles` pick tiles of a slot of tiles. " \
                               "To fix this, call them on a slot of tiles."
        end
        unless [first, across, down].all?(Integer) && across.positive? && down.positive? && first.between?(0, layout.count - 1) &&
               first + (across * down) <= layout.count
          raise ArgumentError, "Slot :#{layout.name} holds #{layout.count} tiles, 0 to #{layout.count - 1}. There are no " \
                               "#{across.inspect} by #{down.inspect} tiles from tile #{first.inspect}."
        end

        with(tile_index: first, across: across, down: down)
      end

      private

      # The view the block makes (Original::Slot#viewed), for +verb+. A handle on tiles, a bank or
      # a run of a slot counts from its own first item, and a view counts bytes from the slot's
      # first, so a view is made from the whole slot.
      def view(verb, at, count, &)
        unless whole?
          raise ArgumentError, "`#{verb}` was called on some of slot :#{layout.name}. at: counts bytes from the start " \
                               "of the slot. To fix this, call it on the slot itself: `pack[:#{layout.name}].#{verb}(...)`."
        end

        with(layout: layout.viewed(verb, at: at, count: count, &))
      end

      # `number`, `envelope` and `frame` count from the slot's first number, which a run does not
      # start at: a handle that read from there would read other numbers than the run's.
      def refuse_run_counted_from_slot_start!(verb)
        return unless run_of_numbers?

        raise ArgumentError, "`#{verb}` was called on some of the numbers of slot :#{layout.name}, made with " \
                             "`numbers(first, count)`. `#{verb}` counts from the first number of the slot. To fix " \
                             "this, call it on the slot itself: `pack[:#{layout.name}].#{verb}(...)`."
      end

      # A handle on +count+ of the +kind+ (:pixels, :samples or :numbers) of a slot of that kind,
      # from number +first+: the one check they share.
      def bytes_run(kind, first, count)
        unless shape == kind && pixel_count.nil?
          raise ArgumentError, "Slot :#{layout.name} holds #{shape}. `#{kind}` picks #{kind} of a slot of #{kind}. " \
                               "To fix this, call it on a slot of #{kind}."
        end
        unless [first, count].all?(Integer) && first >= 0 && count.positive? && first + count <= layout.count
          raise ArgumentError, "You asked for #{count.inspect} #{kind} from #{kind.to_s.chomp('s')} #{first.inspect}. " \
                               "Slot :#{layout.name} holds #{layout.count} #{kind}, numbered 0 to #{layout.count - 1}. " \
                               "To fix this, give a first #{kind.to_s.chomp('s')} and a count that end inside the slot."
        end

        with(first_pixel: first, pixel_count: count)
      end
    end
  end
end
