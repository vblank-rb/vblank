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
    # console's layout, so each of its slots names the layout its port's unpacking routine writes.
    #
    # Where the bytes are (+at+) marks a slot as copied out of the copy as the bytes are there. A
    # slot whose bytes are packed in the copy, or spread over it, has no +at+ (nil): the game's
    # own unpacking routine fills it (`slots.fill_from_copy`, Builder::DataPacks), and it keeps its shape
    # and size all the same.
    #
    # +width+ and +signed+ are a slot of numbers' alone, and nil for any other shape.
    Slot = Data.define(:name, :shape, :at, :count, :width, :signed, :format)

    class Slot
      TILE_SIDE = IR::FormatReading::TILE_SIDE
      TILE_PIXELS = IR::FormatReading::TILE_PIXELS
      # How many bytes a colour is kept in, in every layout.
      COLOR_BYTES = 2
      # The layout a slot is read in when it names none.
      DEFAULT_LAYOUT = Original::DEFAULT_PLATFORM

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

      def self.numbers(name, count:, width:, signed:, at: nil, layout: DEFAULT_LAYOUT)
        unless IR::Build::ELEMENT_BYTES.key?(width)
          raise ArgumentError, "Slot :#{name} was given width: #{width.inspect}. A slot of numbers must be :byte, :half " \
                               "or :word wide."
        end
        unless [true, false].include?(signed)
          raise ArgumentError, "Slot :#{name} was given signed: #{signed.inspect}. A slot of numbers must say signed: true " \
                               "or signed: false. The numbers in it cannot decide this."
        end

        new(name: name.to_sym, shape: :numbers, at: at, count: count, width: width, signed: signed,
            format: formats_of(name, layout).numbers)
      end

      # The layouts of the console named +layout+ (Console::OriginalFormats).
      def self.formats_of(name, layout)
        if layout == COMPUTER
          raise ArgumentError, "Slot :#{name} is from a computer game's original, which keeps its data in no console's " \
                               "layout. Name the layout the slot holds, like `layout: :gba`."
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
      private_class_method :formats_of, :tile_format_of

      def initialize(name:, shape:, at:, count:, width:, signed:, format:)
        at = at.to_h { |release, place| [release.to_s, place] } if at.is_a?(Hash)
        unless (at.nil? || place?(at) || release_places?(at)) && count.is_a?(Integer) && count.positive?
          raise ArgumentError, "Slot :#{name} was given at: #{at.inspect} and count: #{count.inspect}. at: must be a " \
                               "place in the copy, 0 or more, a place for each release by its name " \
                               "(`at: { \"US\" => 0x10, \"EU\" => 0x30 }`), or left out for a slot the unpacking " \
                               "routine fills. count: must be 1 or more."
        end

        super
      end

      # Whether the place is given release by release.
      def places_by_release? = at.is_a?(Hash)

      # The names of the releases the slot gives a place for (none for a slot with one place).
      def release_names = places_by_release? ? at.keys : []

      # The slot as it is in the release called +release+: the same name, shape and size, with the
      # one place that release has. A slot with one place is the same in every release.
      def in_release(release)
        return self unless places_by_release?

        with(at: at.fetch(release.to_s) { raise ArgumentError, "Slot :#{name} has no place for the #{release} release." })
      end

      private def place?(value) = value.is_a?(Integer) && !value.negative?

      private def release_places?(value) = value.is_a?(Hash) && !value.empty? && value.values.all? { |place| place?(place) }

      # How many bytes the slot holds.
      def byte_size = count * item_bytes

      # How many bytes one colour, tile or number of the slot is kept in.
      def item_bytes
        case shape
        when :colors then COLOR_BYTES
        when :tiles then format.tile_bytes
        else IR::Build::ELEMENT_BYTES.fetch(width)
        end
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
        return if at + byte_size <= copy_size

        raise WrongCopy, "Slot :#{name} is #{byte_size} bytes from #{at}, and the copy is #{copy_size} bytes. The slot " \
                         "ends after the copy ends. Correct at: or count: for this release."
      end

      # +bytes+ read in the slot's shape: a list of colours, a list of tiles each a list of its 64
      # places, or a list of numbers.
      def decode(bytes)
        case shape
        when :colors then IR::FormatReading.colors(bytes, format)
        when :tiles then IR::FormatReading.tiles(bytes, format)
        else IR::FormatReading.numbers(bytes, format, width: width, signed: signed)
        end
      end
    end
  end
end
