# frozen_string_literal: true

module VBlank
  module Original
    # ONE SLOT OF A DATA PACK (Pack): a piece of the original's data with a name, a shape and a size,
    # and where in the player's copy its bytes are.
    #
    # The shape and the size are the game's, written in its code, and never worked out from the
    # bytes. That is what lets a game be built with no copy present and filled from one later: the
    # code that reads a slot of sixteen colours is the same code whatever the sixteen colours are.
    # So a slot of numbers says its width and whether they can be below zero, where a `table` given
    # plain numbers works that out from them.
    #
    # A SHAPE NAMES THE LAYOUT THE ORIGINAL KEEPS THAT DATA IN, and the pack holds the bytes as the
    # original has them (unpacked, where the original packs them). VBlank reads each layout itself,
    # in one place, for every build and every console the game is built for. Each shape's rules are
    # a module below (SHAPES), and nothing else knows them.
    #
    # Today every shape is a Game Boy Advance layout, since an Advance original is where ports
    # start: `colors` and `tiles` are the Advance's colours and 16-colour tiles. The layouts of the
    # other consoles VBlank knows (the Color's 4-colour tiles, the Super Nintendo's tiles, the
    # Genesis's tiles and colours) are shapes still to add, for the ports that need them. An
    # original whose data is in no console's layout, a computer game's, has its port's unpacking
    # routine turn the data into one of the shapes.
    #
    # Where the bytes are (+at+) says a slot is copied out of the copy as the bytes are there. A
    # slot whose bytes are packed in the copy, or spread over it, has no +at+ (nil): the game's
    # own unpacking routine fills it (`slots.fill_from_copy`, Builder::DataPacks), and it keeps its shape
    # and size all the same.
    #
    # +width+ and +signed+ are a slot of numbers' alone, and nil for any other shape.
    Slot = Data.define(:name, :shape, :at, :count, :width, :signed)

    class Slot
      # COLOURS, the Advance's: two bytes each, five bits each of red, green and blue (red lowest),
      # low byte first.
      module Colors
        def self.item_bytes(_slot) = 2

        def self.decode(_slot, bytes) = bytes.unpack("v*")
      end

      # TILES, the Advance's: 8x8 pixels of sixteen colours, 32 bytes each, two pixels a byte with the left one in
      # the low half, row by row from the top. Each reads as its 64 places.
      module Tiles
        PIXELS = 64

        def self.item_bytes(_slot) = PIXELS / 2

        def self.decode(_slot, bytes) = bytes.unpack("C*").flat_map { |both| [both & 0x0F, both >> 4] }.each_slice(PIXELS).to_a
      end

      # NUMBERS: one, two or four bytes each, as +width+ says, low byte first; below zero only when
      # +signed+ says so. A width is the size a table's element of that width is
      # (IR::Build::ELEMENT_BYTES), so a slot and a table never disagree about one.
      module Numbers
        UNSIGNED_READS = { byte: "C*", half: "v*", word: "V*" }.freeze
        SIGNED_READS = { byte: "c*", half: "s<*", word: "l<*" }.freeze

        def self.item_bytes(slot) = IR::Build::ELEMENT_BYTES.fetch(slot.width)

        def self.decode(slot, bytes) = bytes.unpack((slot.signed ? SIGNED_READS : UNSIGNED_READS).fetch(slot.width))
      end

      SHAPES = { colors: Colors, tiles: Tiles, numbers: Numbers }.freeze

      def self.colors(name, count:, at: nil) = new(name: name.to_sym, shape: :colors, at: at, count: count, width: nil, signed: nil)

      def self.tiles(name, count:, at: nil) = new(name: name.to_sym, shape: :tiles, at: at, count: count, width: nil, signed: nil)

      def self.numbers(name, count:, width:, signed:, at: nil)
        unless IR::Build::ELEMENT_BYTES.key?(width)
          raise ArgumentError, "Slot :#{name} was given width: #{width.inspect}. A slot of numbers must be :byte, :half " \
                               "or :word wide."
        end
        unless [true, false].include?(signed)
          raise ArgumentError, "Slot :#{name} was given signed: #{signed.inspect}. A slot of numbers must say signed: true " \
                               "or signed: false. The numbers in it cannot decide this."
        end

        new(name: name.to_sym, shape: :numbers, at: at, count: count, width: width, signed: signed)
      end

      def initialize(name:, shape:, at:, count:, width:, signed:)
        unless (at.nil? || (at.is_a?(Integer) && !at.negative?)) && count.is_a?(Integer) && count.positive?
          raise ArgumentError, "Slot :#{name} was given at: #{at.inspect} and count: #{count.inspect}. at: must be a " \
                               "place in the copy, 0 or more, or left out for a slot the unpacking routine fills. " \
                               "count: must be 1 or more."
        end

        super
      end

      # How many bytes the slot holds.
      def byte_size = count * shape_rules.item_bytes(self)

      # Whether the game's unpacking routine fills the slot, rather than its bytes being copied
      # from a place in the copy.
      def filled_by_routine? = at.nil?

      # The slot's bytes in +copy+ (the copy's whole file as a binary String). WrongCopy when the
      # copy ends before the slot does. Only a slot with a place in the copy has bytes there.
      def cut_from(copy)
        raise ArgumentError, "Slot :#{name} has no place in the copy. Its routine fills it." if filled_by_routine?
        return copy.byteslice(at, byte_size) if at + byte_size <= copy.bytesize

        raise WrongCopy, "Slot :#{name} is #{byte_size} bytes from #{at}, and the copy is #{copy.bytesize} bytes. The slot " \
                         "ends after the copy ends. Correct at: or count: for this release."
      end

      # +bytes+ read in the slot's shape: a list of colours, a list of tiles each a list of its 64
      # places, or a list of numbers.
      def decode(bytes) = shape_rules.decode(self, bytes)

      private

      def shape_rules = SHAPES.fetch(shape)
    end
  end
end
