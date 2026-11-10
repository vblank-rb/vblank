# frozen_string_literal: true

module VBlank
  module DSL
    # THE SLOTS A GAME'S DATA PACK HOLDS, as the `data_pack` block names them (Builder::DataPacks).
    # Each line is one slot: its name, its shape, how many it holds, and where in the copy it is.
    #
    #   data_pack from: ORIGINAL, version: "1.0" do |slots|
    #     slots.colors  :palette, at: 0x1000, count: 16
    #     slots.tiles   :walls,   at: 0x1020, count: 40
    #     slots.numbers :speeds,  at: 0x2000, count: 8, width: :byte, signed: false
    #     slots.tiles   :sprites, count: 64                    # no at: the routine below fills it
    #     slots.fill_from_copy do |copy, pack|
    #       copy.unpack_lz77 at: 0x3000, into: pack[:sprites]
    #     end
    #   end
    #
    # A slot with no +at+ is filled by the game's own unpacking routine, the block given to
    # #fill_from_copy (see Builder::DataPacks for how and where it runs).
    #
    # Each slot is kept in the layout of the console the original is for (+platform+, the
    # original's Original::Game#platform), unless it names another with +layout+. An original from a
    # computer has no console's layout: its numbers are low byte first unless a slot names its
    # +byte_order+, and a slot of colours or tiles names the layout its routine writes:
    #
    #   slots.tiles :walls, at: 0x4000, count: 64, colors: 4    # a Super Nintendo's tiles of four colours
    #   slots.numbers :sizes, count: 9, width: :half, signed: false   # a computer game's, low byte first
    #   slots.numbers :sizes, count: 9, width: :half, signed: false, byte_order: :high_first
    #   slots.colors :palette, count: 16, layout: :gba          # a computer game's, as its routine writes them
    class PackSlots
      def initialize(platform:)
        @platform = platform
        @list = []
        @routine = nil
      end

      # The slots named so far, in order, and the unpacking routine (a block), or nil for none.
      attr_reader :list, :routine

      # +count+ colours, two bytes each.
      #
      # Every slot below takes +cost+: how many times the work of a plain copy one of its bytes takes
      # to unpack, 1 unless the routine works hard for it (`cost: 40` for a slot it renders sound
      # into). A shell's bar then moves by the work done rather than the bytes written
      # (Original::Slot#cost).
      def colors(name, count:, at: nil, layout: nil, cost: 1)
        add(Original::Slot.colors(name, at: at, count: count, layout: layout || @platform, cost: cost))
      end

      # +count+ tiles of 8x8 pixels, of +colors+ colours where the layout keeps more than one kind.
      def tiles(name, count:, at: nil, colors: nil, layout: nil, cost: 1)
        add(Original::Slot.tiles(name, at: at, count: count, colors: colors, layout: layout || @platform, cost: cost))
      end

      # +count+ numbers, each +width+ (:byte, :half or :word) wide; +signed+ sets whether they can be
      # below zero. +byte_order+ (:low_first or :high_first) names how they are kept in place of a
      # console's layout.
      def numbers(name, count:, width:, signed:, at: nil, layout: nil, byte_order: nil, cost: 1)
        add(Original::Slot.numbers(name, at: at, count: count, width: width, signed: signed,
                                         layout: layout || (@platform unless byte_order), byte_order: byte_order, cost: cost))
      end

      # +count+ pixels, one byte each: a picture of up to 256 colours, row by row, for an image's
      # `places:` (`image ..., colors: [...], places: pack[:art], see_through: 255`).
      def pixels(name, count:, at: nil, cost: 1) = add(Original::Slot.pixels(name, at: at, count: count, cost: cost))

      # +count+ samples of recorded sound, one byte each, 8-bit signed, for a recording's `pcm:`
      # (`sample :bang, pcm: pack[:bang], rate: 7000`, or `pack[:sounds].samples(first, count)`).
      def samples(name, count:, at: nil, cost: 1) = add(Original::Slot.samples(name, at: at, count: count, cost: cost))

      # The game's unpacking routine: the block is game code, handed the copy's bytes (an
      # Original::CopyReader), the pack's slots to write (an Original::UnpackingSlots) and, if it
      # takes a third argument, the name of the release it unpacks, a plain String as the game is
      # built, so Ruby can choose the places release by release:
      #
      #   slots.fill_from_copy do |copy, pack, release|
      #     copy.unpack_lz77 at: (release == "EU" ? 0x3040 : 0x3000), into: pack[:sprites]
      #   end
      def fill_from_copy(&block)
        unless block
          raise ArgumentError, "`slots.fill_from_copy` needs a block: `slots.fill_from_copy do |copy, pack| ... end`."
        end
        unless @routine.nil?
          raise ArgumentError, "The data pack says `slots.fill_from_copy` twice. A data pack has one unpacking routine. " \
                               "Put all of the unpacking in one block."
        end

        @routine = block
        nil
      end

      private

      def add(slot)
        if @list.any? { |named| named.name == slot.name }
          raise ArgumentError, "The data pack names slot :#{slot.name} twice. Give each slot a name of its own."
        end

        @list << slot
        nil
      end
    end

    # A GAME'S DATA PACK, as `data_pack` hands it back: a handle for each slot, by its name.
    #
    #   image :wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
    #   table :speeds, pack[:speeds]
    #
    # The game never holds what a slot holds: a handle gives the slot's shape and size, and the verb
    # given it reads the slot. So nothing the game does while it is built can depend on the
    # original's bytes, and a build that reads the pack only as the game starts takes the same game.
    class DataPack
      # +rom_sha1+ is the SHA-1 of the copy the build made the pack from (nil for a build that
      # leaves the pack out, which reads no copy), +build_version+ the build it names, +slots+ the
      # Original::Slot list. +make_unpacking+ makes the Original::Unpacking that fills such a pack,
      # handed the copy's size, the first time something asks for it: a pack whose every slot is
      # copied as it is never needs its program built as the game is. +original+ is what `from:`
      # named (an Original::Game, or an Original::Copy), which a shell reads the releases of.
      def initialize(rom_sha1:, build_version:, slots:, make_unpacking:, original: nil)
        @rom_sha1 = rom_sha1
        @build_version = build_version
        @slots = slots.to_h { |slot| [slot.name, slot] }
        @make_unpacking = make_unpacking
        @unpackings = {}
        @original = original
      end

      # The SHA-1 of the copy the pack was made from, the build version it names, and the original
      # it is made from.
      attr_reader :rom_sha1, :build_version, :original

      # Every slot (Original::Slot), in the pack's order.
      def slots = @slots.values

      # The pack's unpacking as a program of its own (an Original::Unpacking): what a shell runs on
      # the player's machine to make the pack, and what a test plays on each run. A build that
      # leaves the pack out reads no copy, so its unpacking is built for a copy of the size of
      # +release+ (an Original::Release), which it is handed as it starts; an all-in-one build's
      # holds the copy it read, and needs no release. Each release has a program of its own, since
      # the slots' places or the routine can differ by release.
      def unpacking(release: nil) = @unpackings[release] ||= @make_unpacking.call(release)

      # The handle of the slot named +name+.
      def [](name)
        slot = @slots.fetch(name.to_sym) do
          raise ArgumentError, "The data pack has no slot #{name.inspect}. It has #{@slots.keys.map(&:inspect).join(', ')}. " \
                               "Name the slot in the data_pack block first."
        end
        PackSlot.new(layout: slot, tile_index: nil)
      end
    end

    # A TABLE'S ENTRIES IN THE FILE THE GAME IS HANDED AS IT STARTS (IR::StartFile), given to
    # `table` in place of its numbers: +count+ entries from byte +at+ on. A game built with its pack
    # left out reads each table from a slot this way, and its unpacking reads the copy this way;
    # the game must read such a file (`data_pack` with the pack left out declares it does). Each
    # entry is kept in +format+ (a Console::NumberFormat), low byte first unless it says otherwise.
    StartFileEntries = Data.define(:at, :count, :format) do
      def initialize(at:, count:, format: Console::LOW_BYTE_FIRST_NUMBERS) = super
    end

    # A HANDLE ON ONE SLOT OF A DATA PACK, or on tiles of a slot of tiles, or pixels of a slot of
    # pixels: the slot's layout (an Original::Slot: its name, shape, size and place in the copy)
    # and, for tiles or pixels, which. It never
    # holds the bytes. `image` and `table` read them (Builder::DataPacks#pack_slot_values).
    #
    # A handle on tiles is +across+ tiles wide and +down+ tiles tall, starting at +tile_index+ and
    # counting left to right and then top to bottom, as a sprite keeps its tiles: a picture of
    # 16x16 pixels is 2 across and 2 down. A handle on a bank is +color_count+ colours of a slot of
    # colours from colour +first_color+, as a console's palette keeps them in banks of 16.
    #
    # A handle on pixels is +pixel_count+ pixels of a slot of pixels from pixel +first_pixel+, or
    # the whole slot where neither is given: the places of one picture among several kept in one
    # slot, as `pack[:walls].pixels(64 * 64 * 3, 64 * 64)` is the fourth picture of 64x64.
    PackSlot = Data.define(:layout, :tile_index, :across, :down, :first_color, :color_count, :first_pixel, :pixel_count) do
      def initialize(layout:, tile_index: nil, across: 1, down: 1, first_color: nil, color_count: nil, first_pixel: 0,
                     pixel_count: nil) = super

      def shape = layout.shape

      # How many the handle reads: the slot's count, or the tiles of a handle on tiles, or the
      # colours of a bank, or the pixels of a handle on pixels.
      def count
        return across * down if tile_index
        return color_count if first_color

        pixel_count || layout.count
      end

      # A handle on +count+ pixels from pixel +first+ (0 first) of a slot of pixels, for an image's
      # `places:`.
      def pixels(first, count) = bytes_run(:pixels, first, count)

      # A handle on +count+ samples from sample +first+ (0 first) of a slot of samples, for a
      # recording's `pcm:`. It shares the first and the count of a handle on pixels, since a
      # sample is a byte as a pixel is.
      def samples(first, count) = bytes_run(:samples, first, count)

      # Whether the handle is on a bank of colours.
      def bank? = !first_color.nil?

      # Whether the handle is on tiles, one or more.
      def one_tile? = !tile_index.nil?

      # A handle on bank +index+ (0 first) of a slot of colours, +size+ colours to a bank, for an
      # image's `colors:`.
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

      # A handle on tile +index+ (0 first) of a slot of tiles, for an image's `places:`.
      def tile(index) = tiles(index, across: 1, down: 1)

      # A handle on the +across+ by +down+ tiles from tile +first+ of a slot of tiles, for the
      # `places:` of a picture 8 pixels wider and taller for each.
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

      # A handle on +count+ of the +kind+ (:pixels or :samples) of a slot of that kind, from number
      # +first+: the one check both share.
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
