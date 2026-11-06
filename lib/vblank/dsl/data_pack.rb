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
    class PackSlots
      def initialize
        @list = []
        @routine = nil
      end

      # The slots named so far, in order, and the unpacking routine (a block), or nil for none.
      attr_reader :list, :routine

      # +count+ colours, two bytes each.
      def colors(name, count:, at: nil) = add(Original::Slot.colors(name, at: at, count: count))

      # +count+ tiles of 8x8 pixels in sixteen colours, 32 bytes each.
      def tiles(name, count:, at: nil) = add(Original::Slot.tiles(name, at: at, count: count))

      # +count+ numbers, each +width+ (:byte, :half or :word) wide; +signed+ says whether they can be
      # below zero.
      def numbers(name, count:, width:, signed:, at: nil)
        add(Original::Slot.numbers(name, at: at, count: count, width: width, signed: signed))
      end

      # The game's unpacking routine: the block is game code, handed the copy's bytes (an
      # OriginalBytes) and the pack's slots to write (an UnpackingSlots).
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
    # The game never holds what a slot holds: a handle says the slot's shape and size, and the verb
    # given it reads the slot. So nothing the game does while it is built can depend on the
    # original's bytes, and a build that reads the pack only as the game starts takes the same game.
    class DataPack
      # +header+ is the Original::Pack the build read (only its copy's SHA-1 and build version are
      # asked of it here), +slots+ the Original::Slot list it was made with. +make_unpacking+ makes
      # the Original::Unpacking that fills such a pack, the first time something asks for it: a
      # pack whose every slot is copied as it is never needs its program built as the game is.
      def initialize(header, slots, make_unpacking:)
        @rom_sha1 = header.rom_sha1
        @build_version = header.build_version
        @slots = slots.to_h { |slot| [slot.name, slot] }
        @make_unpacking = make_unpacking
      end

      # The SHA-1 of the copy the pack was made from, and the build version it names.
      attr_reader :rom_sha1, :build_version

      # The pack's unpacking as a program of its own (an Original::Unpacking): what a shell runs on
      # the player's machine to make the pack, and what a test plays on each run.
      def unpacking = @unpacking ||= @make_unpacking.call

      # The handle of the slot named +name+.
      def [](name)
        slot = @slots.fetch(name.to_sym) do
          raise ArgumentError, "The data pack has no slot #{name.inspect}. It has #{@slots.keys.map(&:inspect).join(', ')}. " \
                               "Name the slot in the data_pack block first."
        end
        PackSlot.new(layout: slot, tile_index: nil)
      end
    end

    # A HANDLE ON ONE SLOT OF A DATA PACK, or on one tile of a slot of tiles: the slot's layout (an
    # Original::Slot: its name, shape, size and place in the copy) and, for one tile, which. It never
    # holds the bytes. `image` and `table` read them (Builder::DataPacks#pack_slot_values).
    PackSlot = Data.define(:layout, :tile_index) do
      def shape = layout.shape

      # How many the handle reads: the slot's count, or 1 for one tile.
      def count = tile_index ? 1 : layout.count

      # Whether the handle is on one tile.
      def one_tile? = !tile_index.nil?

      # A handle on tile +index+ (0 first) of a slot of tiles, for an image's `places:`.
      def tile(index)
        unless shape == :tiles && !one_tile?
          raise ArgumentError, "Slot :#{layout.name} holds #{shape}. `tile` picks one tile of a slot of tiles. " \
                               "To fix this, call `tile` on a slot of tiles."
        end
        unless index.is_a?(Integer) && index.between?(0, layout.count - 1)
          raise ArgumentError, "Slot :#{layout.name} holds #{layout.count} tiles, 0 to #{layout.count - 1}. There is no " \
                               "tile #{index.inspect}."
        end

        with(tile_index: index)
      end
    end
  end
end
