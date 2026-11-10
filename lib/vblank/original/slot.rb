# frozen_string_literal: true

module VBlank
  module Original
    # ONE SLOT OF A DATA PACK (Pack): a piece of the original's data with a name, a shape and a size,
    # and where in the player's copy its bytes are.
    #
    # The shape and the size are the game's, written in its code, and never worked out from the
    # bytes. That is what lets a game be built with no copy present and filled from one later: the
    # code that reads a slot of sixteen colours is the same code whatever the sixteen colours are.
    # So a slot of numbers names its width and whether they can be below zero, where a `table` given
    # plain numbers works that out from them.
    #
    # A SHAPE (colours, tiles or numbers) IS KEPT IN THE LAYOUT OF THE CONSOLE THE ORIGINAL IS FOR,
    # and the pack holds the bytes as the original has them (unpacked, where the original packs
    # them). The original names its platform (Game#platform), and a slot is in that console's
    # layout unless it names another with +layout+; each console's layouts are numbers in its
    # hardware file, named by its kit (Console::Kit#original_formats), and one reader reads any of
    # them (IR::FormatReading). +format+ is the layout the slot is read in: a Console::ColorFormat,
    # TileFormat or NumberFormat. An original from a computer (COMPUTER) keeps its data in no
    # console's layout: its numbers are low byte first unless a slot names its byte order, its
    # pictures are slots of pixels, and a slot of colours or tiles names the console layout its
    # port's unpacking routine writes.
    #
    # Where the bytes are (+at+) marks a slot as copied out of the copy as the bytes are there. A
    # slot whose bytes are packed in the copy, or spread over it, has no +at+ (nil): the game's
    # own unpacking routine fills it (`slots.fill_from_copy`, Builder::DataPacks), and it keeps its shape
    # and size all the same.
    #
    # +width+ and +signed+ are a slot of numbers' alone, and nil for any other shape. A slot of pixels
    # is a byte a pixel in any layout, so its +format+ is nil.
    Slot = Data.define(:name, :shape, :at, :count, :width, :signed, :format)

    class Slot
      TILE_SIDE = IR::FormatReading::TILE_SIDE
      TILE_PIXELS = IR::FormatReading::TILE_PIXELS
      # How many bytes a colour is kept in, in every layout.
      COLOR_BYTES = 2
      # The layout a slot is read in when it names none.
      DEFAULT_LAYOUT = Original::DEFAULT_PLATFORM

      # WHAT A SHAPE MEANS, once: how many bytes one item of a slot of that shape is kept in, and
      # how bytes are read as that shape (each is given the slot). A new shape is one entry here.
      Shape = Data.define(:item_bytes, :decode)
      SHAPES = Ractor.make_shareable({
        colors: Shape.new(item_bytes: ->(_slot) { COLOR_BYTES },
                          decode: ->(slot, bytes) { IR::FormatReading.colors(bytes, slot.format) }),
        tiles: Shape.new(item_bytes: ->(slot) { slot.format.tile_bytes },
                         decode: ->(slot, bytes) { IR::FormatReading.tiles(bytes, slot.format) }),
        numbers: Shape.new(item_bytes: ->(slot) { IR::Build::ELEMENT_BYTES.fetch(slot.width) },
                           decode: lambda { |slot, bytes|
                             IR::FormatReading.numbers(bytes, slot.format, width: slot.width, signed: slot.signed)
                           }),
        pixels: Shape.new(item_bytes: ->(_slot) { 1 }, decode: ->(_slot, bytes) { bytes.bytes }),
        samples: Shape.new(item_bytes: ->(_slot) { 1 }, decode: ->(_slot, bytes) { bytes.unpack("c*") })
      })

      # +count+ colours, in the colour layout of +layout+ (a console's name).
      def self.colors(name, count:, at: nil, layout: DEFAULT_LAYOUT)
        new(name: name.to_sym, shape: :colors, at: at, count: count, width: nil, signed: nil,
            format: formats_of(name, layout).colors)
      end

      # +count+ tiles of 8x8 pixels in +colors+ colours, in the tile layout of +layout+. +colors+ may
      # be left out where the console keeps one kind of tile.
      def self.tiles(name, count:, at: nil, layout: DEFAULT_LAYOUT, colors: nil)
        new(name: name.to_sym, shape: :tiles, at: at, count: count, width: nil, signed: nil,
            format: tile_format_of(name, layout, colors))
      end

      # +count+ pixels, each one byte, a place 0 to 255 in a list of colours the game gives: a picture
      # of up to 256 colours row by row, as a computer game keeps its art. A byte is a byte in every
      # layout, so the slot names none; how the original lays its art out is the game's to undo in
      # its unpacking routine, which writes the slot row by row.
      def self.pixels(name, count:, at: nil) = of_bytes(:pixels, name, count, at)

      # +count+ samples of a recorded sound, one byte each, 8-bit signed (-128 to 127), for a
      # recording's `pcm:` (`sample :bang, pcm: pack[:bang], rate: 7000`). The rate is the game's to
      # name, since a sound's speed is not part of its bytes. A byte is a byte in every layout.
      def self.samples(name, count:, at: nil) = of_bytes(:samples, name, count, at)

      # A slot of one-byte items that no layout changes: pixels or samples.
      def self.of_bytes(shape, name, count, at)
        new(name: name.to_sym, shape: shape, at: at, count: count, width: nil, signed: nil, format: nil)
      end
      private_class_method :of_bytes

      # Number layouts by byte order: :low_first, as DOS and Windows games keep them, or :high_first.
      BYTE_ORDERS = { low_first: Console::LOW_BYTE_FIRST_NUMBERS, high_first: Console::HIGH_BYTE_FIRST_NUMBERS }.freeze

      # +count+ numbers +width+ wide, in the number layout of +layout+ (a console's name), or in the
      # byte order +byte_order+ names; a computer game's (+layout+ COMPUTER) are low byte first
      # unless the slot names its byte order.
      def self.numbers(name, count:, width:, signed:, at: nil, layout: nil, byte_order: nil)
        unless IR::Build::ELEMENT_BYTES.key?(width)
          raise ArgumentError, "Slot :#{name} was given width: #{width.inspect}. A slot of numbers must be :byte, :half " \
                               "or :word wide."
        end
        unless [true, false].include?(signed)
          raise ArgumentError, "Slot :#{name} was given signed: #{signed.inspect}. A slot of numbers must say signed: true " \
                               "or signed: false. The numbers in it cannot decide this."
        end

        new(name: name.to_sym, shape: :numbers, at: at, count: count, width: width, signed: signed,
            format: number_format_of(name, layout, byte_order))
      end

      def self.number_format_of(name, layout, byte_order)
        if byte_order
          unless layout.nil? || layout == COMPUTER
            raise ArgumentError, "Slot :#{name} names layout: :#{layout} and byte_order:. A console's layout already says its " \
                                 "byte order. To fix this, give only one of them."
          end

          return BYTE_ORDERS.fetch(byte_order) do
            raise ArgumentError, "Slot :#{name} was given byte_order: #{byte_order.inspect}. A byte order is :low_first or " \
                                 ":high_first."
          end
        end
        return BYTE_ORDERS.fetch(:low_first) if layout == COMPUTER

        formats_of(name, layout || DEFAULT_LAYOUT).numbers
      end

      # The layouts of the console named +layout+ (Console::OriginalFormats).
      def self.formats_of(name, layout)
        if layout == COMPUTER
          raise ArgumentError, "Slot :#{name} is from a computer game's original, which keeps its colours and tiles in no " \
                               "console's layout. Keep its pictures as a slot of pixels, or name the console layout the " \
                               "unpacking routine writes, like `layout: :gba`."
        end

        kit = Console.for(layout)
        kit.original_formats or
          raise ArgumentError, "Slot :#{name} is in the #{kit.title}'s layout, and VBlank reads no data in that layout. " \
                               "Name another layout, like `layout: :gba`."
      end

      def self.tile_format_of(name, layout, colors)
        formats = formats_of(name, layout)
        kinds = formats.tiles
        return kinds.first if colors.nil? && kinds.one?

        found = formats.tiles_of(colors)
        return found if found

        options = kinds.map { |format| "colors: #{format.colors}" }.join(" or ")
        raise ArgumentError, "Slot :#{name} holds tiles in the #{Console.for(layout).title}'s layout, which keeps tiles " \
                             "of #{kinds.map(&:colors).join(' or ')} colors. Give the slot #{options}."
      end
      private_class_method :formats_of, :tile_format_of, :number_format_of

      def initialize(name:, shape:, at:, count:, width:, signed:, format:)
        unless (at.nil? || place?(at) || release_places?(at)) && count.is_a?(Integer) && count.positive?
          raise ArgumentError, "Slot :#{name} was given at: #{at.inspect} and count: #{count.inspect}. " \
                               "at: must be a place in the copy, 0 or more. " \
                               "It can also be a Hash of places by release name, like `at: { \"US\" => 0x10, \"EU\" => 0x30 }`. " \
                               "Leave at: out for a slot the unpacking routine fills. " \
                               "count: must be 1 or more."
        end

        super
      end

      # Whether the place is given release by release.
      def places_by_release? = at.is_a?(Hash)

      # The names of the releases the slot gives a place for, as the original lists them (none for a
      # slot with one place).
      def release_names = places_by_release? ? at.keys : []

      # The slot as it is in the release called +release+: the same name, shape and size, with the
      # one place that release has. A slot with one place is the same in every release.
      def in_release(release)
        return self unless places_by_release?

        with(at: at.fetch(release) { raise ArgumentError, "Slot :#{name} has no place for the #{release} release." })
      end

      private def place?(value) = value.is_a?(Integer) && !value.negative?

      private def release_places?(value)
        value.is_a?(Hash) && !value.empty? && value.all? { |release, place| release.is_a?(String) && place?(place) }
      end

      # A slot with a place for each release has no one place to read until a release is chosen.
      private def refuse_places_by_release!
        return unless places_by_release?

        raise ArgumentError, "Slot :#{name} has a place for each release. Ask for the slot in one release first, " \
                             "with `in_release`."
      end

      # How many bytes the slot holds.
      def byte_size = count * item_bytes

      # How many bytes one colour, tile or number of the slot is kept in.
      def item_bytes
        SHAPES.fetch(shape).item_bytes.call(self)
      end

      # Whether the game's unpacking routine fills the slot, rather than its bytes being copied
      # from a place in the copy.
      def filled_by_routine? = at.nil?

      # The slot's bytes in +copy+ (the copy's whole file as a binary String). WrongCopy when the
      # copy ends before the slot does. Only a slot with a place in the copy has bytes there.
      def cut_from(copy)
        refuse_past_end!(copy.bytesize)
        copy.byteslice(at, byte_size)
      end

      # WrongCopy when the slot ends after a copy of +copy_size+ bytes does; ArgumentError for a slot
      # with no place in the copy.
      def refuse_past_end!(copy_size)
        raise ArgumentError, "Slot :#{name} has no place in the copy. Its routine fills it." if filled_by_routine?

        refuse_places_by_release!
        return if at + byte_size <= copy_size

        raise WrongCopy, "Slot :#{name} is #{byte_size} bytes from #{at}, and the copy is #{copy_size} bytes. The slot " \
                         "ends after the copy ends. Correct at: or count: for this release."
      end

      # +bytes+ read in the slot's shape: a list of colours, a list of tiles each a list of its 64
      # places, or a list of numbers.
      def decode(bytes)
        SHAPES.fetch(shape).decode.call(self, bytes)
      end
    end
  end
end
