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
    #   end
    class PackSlots
      def initialize = @list = []

      # The slots named so far, in order.
      attr_reader :list

      # +count+ colours, two bytes each.
      def colors(name, at:, count:) = add(Original::Slot.colors(name, at: at, count: count))

      # +count+ tiles of 8x8 pixels in sixteen colours, 32 bytes each.
      def tiles(name, at:, count:) = add(Original::Slot.tiles(name, at: at, count: count))

      # +count+ numbers, each +width+ (:byte, :half or :word) wide; +signed+ says whether they can be
      # below zero.
      def numbers(name, at:, count:, width:, signed:)
        add(Original::Slot.numbers(name, at: at, count: count, width: width, signed: signed))
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
      # asked of it here), +slots+ the Original::Slot list it was made with.
      def initialize(header, slots)
        @rom_sha1 = header.rom_sha1
        @build_version = header.build_version
        @slots = slots.to_h { |slot| [slot.name, slot] }
      end

      # The SHA-1 of the copy the pack was made from, and the build version it names.
      attr_reader :rom_sha1, :build_version

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
