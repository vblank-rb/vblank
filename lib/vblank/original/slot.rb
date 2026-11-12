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
    # where VBlank reads that console's layout, and the pack holds the bytes as the original has
    # them (unpacked, where the original packs them). The original names its platform
    # (Game#platform), and a slot is in that console's layout unless it names another with
    # +layout+; each console's layouts are numbers in its hardware file, named by its kit
    # (Console::Kit#original_formats), and one reader reads any of them (IR::FormatReading).
    # +format+ is the layout the slot is read in: a Console::ColorFormat, TileFormat or
    # NumberFormat.
    #
    # Every other platform (the PlayStation, a computer, an arcade board, any name) keeps its slots
    # in VBlank's own layout (VBLANK_LAYOUT, Console::VBLANK_FORMATS), which the port's unpacking
    # routine writes from however its original keeps them; a console's layout is then a shortcut a
    # slot names. A computer game's numbers may name their byte order instead.
    #
    # Where the bytes are (+at+) marks a slot as copied out of the copy as the bytes are there. A
    # slot whose bytes are packed in the copy, or spread over it, has no +at+ (nil): the game's
    # own unpacking routine fills it (`slots.fill_from_copy`, Builder::DataPacks), and it keeps its shape
    # and size all the same.
    #
    # +width+ and +signed+ are a slot of numbers' alone, and nil for any other shape. A slot of pixels
    # is a byte a pixel in any layout, so its +format+ is nil.
    #
    # +cost+ is how much work one of the slot's bytes takes to unpack, against a plain copy's 1: a
    # slot the routine renders or decompresses slowly names more, so a shell's bar gives it its
    # share of the time rather than of the bytes (Builder::DataPacks#define_unpacking_progress). It
    # changes nothing in the pack.
    #
    # A VIEW OF A SLOT is some of a slot's bytes read in a shape of their own: +count+ items of that
    # shape from a byte of the slot on (#viewed). A console keeps tiles of two kinds and a map in
    # one block of video memory, and a port that keeps the block as one slot reads each part
    # through a view, so its unpacking writes the bytes once. A view is a Slot too, with its own
    # shape, size and layout, and no slot of the pack: its +name+ is a SlotView, which says whose
    # bytes it reads and from where, and the two things that find a slot's bytes by its name find
    # a view's by that (Pack#bytes_of, SlotStarts#fetch).
    Slot = Data.define(:name, :shape, :at, :count, :width, :signed, :format, :cost)

    # THE NAME OF A VIEW (see Slot): +size+ bytes of +slot+, a slot the pack names, from its byte
    # +at+ on. It reads as text where a slot's name does, in a build's messages and in the names
    # of the lists of a view of colours (`:video_at_64_0`).
    SlotView = Data.define(:slot, :at, :size) do
      def to_s = "#{slot.name}_at_#{at}"

      # The view's bytes, cut from +slot_bytes+, all that its slot holds.
      def cut_from(slot_bytes) = slot_bytes.byteslice(at, size)
    end

    # WHERE EACH SLOT'S BYTES START IN THE PACK'S FILE, by the slot's name (+by_name+,
    # Pack::Layout#slot_starts), and so where a view's start: so far into its slot.
    SlotStarts = Data.define(:by_name) do
      def fetch(name) = name.is_a?(SlotView) ? by_name.fetch(name.slot.name) + name.at : by_name.fetch(name)
    end

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
        notes: Shape.new(item_bytes: ->(_slot) { PackNote::BYTES }, decode: ->(_slot, bytes) { PackNote.list_in(bytes) }),
        # Each cell read as one number, as a map of any console's cells is (MapCell::FORMAT).
        map_cells: Shape.new(item_bytes: ->(_slot) { MapCell::BYTES },
                             decode: ->(slot, bytes) { IR::FormatReading.numbers(bytes, slot.format, width: :word, signed: false) }),
        samples: Shape.new(item_bytes: ->(_slot) { 1 }, decode: ->(_slot, bytes) { bytes.unpack("c*") })
      })

      # +count+ colours, in the colour layout of +layout+ (a console's name).
      def self.colors(name, count:, at: nil, layout: DEFAULT_LAYOUT, cost: 1)
        new(name: name.to_sym, shape: :colors, at: at, count: count, width: nil, signed: nil,
            format: formats_of(name, layout).colors, cost: cost)
      end

      # +count+ tiles of 8x8 pixels in +colors+ colours, in the tile layout of +layout+. +colors+ may
      # be left out where the console keeps one kind of tile. Tiles of 256 colours are a byte a
      # pixel in every layout (Console::BYTE_A_PIXEL_TILES), as a layer that turns keeps them.
      def self.tiles(name, count:, at: nil, layout: DEFAULT_LAYOUT, colors: nil, cost: 1)
        new(name: name.to_sym, shape: :tiles, at: at, count: count, width: nil, signed: nil,
            format: tile_format_of(name, layout, colors), cost: cost)
      end

      # +count+ pixels, each one byte, a place 0 to 255 in a list of colours the game gives: a picture
      # of up to 256 colours row by row, as a computer game keeps its art. A byte is a byte in every
      # layout, so the slot names none; how the original lays its art out is the game's to undo in
      # its unpacking routine, which writes the slot row by row.
      def self.pixels(name, count:, at: nil, cost: 1) = of_bytes(:pixels, name, count, at, cost)

      # +count+ samples of a recorded sound, one byte each, 8-bit signed (-128 to 127), for a
      # recording's `pcm:` (`sample :bang, pcm: pack[:bang], rate: 7000`). The rate is the game's to
      # name, since a sound's speed is not part of its bytes. A byte is a byte in every layout.
      def self.samples(name, count:, at: nil, cost: 1) = of_bytes(:samples, name, count, at, cost)

      # +count+ notes of music, each a PackNote record, for a part of a Score (`notes: pack[:theme]`).
      # The record is VBlank's own, the same whatever the original, so the port's unpacking routine
      # writes the notes its original's sound driver plays into it.
      def self.notes(name, count:, at: nil, cost: 1)
        new(name: name.to_sym, shape: :notes, at: at, count: count, width: nil, signed: nil, format: nil, cost: cost)
      end

      # +count+ cells of a background's map, each a MapCell record, for a background's `map:`
      # (`background :title, tiles: pack[:video], map: pack[:title_map], ...`). The record is
      # VBlank's own, the same whatever the original, so the port's unpacking routine writes the
      # cells of its original's maps into it.
      def self.map_cells(name, count:, at: nil, cost: 1)
        new(name: name.to_sym, shape: :map_cells, at: at, count: count, width: nil, signed: nil, format: MapCell::NUMBER_FORMAT,
            cost: cost)
      end

      # A slot of one-byte items that no layout changes: pixels or samples.
      def self.of_bytes(shape, name, count, at, cost)
        new(name: name.to_sym, shape: shape, at: at, count: count, width: nil, signed: nil, format: nil, cost: cost)
      end
      private_class_method :of_bytes

      # Number layouts by byte order: :low_first, as DOS and Windows games keep them, or :high_first.
      BYTE_ORDERS = { low_first: Console::LOW_BYTE_FIRST_NUMBERS, high_first: Console::HIGH_BYTE_FIRST_NUMBERS }.freeze

      # +count+ numbers +width+ wide, in the number layout of +layout+ (a console's name), or in the
      # byte order +byte_order+ names; a computer game's (+layout+ COMPUTER) are low byte first
      # unless the slot names its byte order.
      def self.numbers(name, count:, width:, signed:, at: nil, layout: nil, byte_order: nil, cost: 1)
        unless IR::Build::ELEMENT_BYTES.key?(width)
          raise ArgumentError, "Slot :#{name} was given width: #{width.inspect}. A slot of numbers must be :byte, :half " \
                               "or :word wide."
        end
        unless [true, false].include?(signed)
          raise ArgumentError, "Slot :#{name} was given signed: #{signed.inspect}. A slot of numbers must say signed: true " \
                               "or signed: false. The numbers in it cannot decide this."
        end

        new(name: name.to_sym, shape: :numbers, at: at, count: count, width: width, signed: signed,
            format: number_format_of(name, layout, byte_order, width), cost: cost)
      end

      def self.number_format_of(name, layout, byte_order, width)
        if byte_order
          unless layout.nil? || layout == COMPUTER
            raise ArgumentError, "Slot :#{name} names layout: :#{layout} and byte_order:. A layout already says its " \
                                 "byte order. To fix this, give only one of them."
          end

          return BYTE_ORDERS.fetch(byte_order) do
            raise ArgumentError, "Slot :#{name} was given byte_order: #{byte_order.inspect}. A byte order is :low_first or " \
                                 ":high_first."
          end
        end
        # A number of one byte has no byte order, so any console's layout keeps it alike.
        return Console::LOW_BYTE_FIRST_NUMBERS if width == :byte && Console::KITS.key?(layout)

        formats_of(name, layout || DEFAULT_LAYOUT).numbers
      end

      # The layouts +layout+ names (Console::OriginalFormats): a console's own, or VBlank's
      # (VBLANK_LAYOUT, and COMPUTER, whose numbers are low byte first as VBlank's are).
      def self.formats_of(name, layout)
        return Console::VBLANK_FORMATS if [VBLANK_LAYOUT, COMPUTER].include?(layout)

        found = Console.original_formats_of(layout)
        return found if found

        if Console::KITS.key?(layout)
          raise ArgumentError, "Slot :#{name} names the #{Console.for(layout).title}'s layout, and VBlank reads no data in " \
                               "that layout. To fix this, leave layout: out. Then the slot is in VBlank's own layout, and " \
                               "the unpacking writes the data in that layout."
        end

        raise ArgumentError, "Slot :#{name} was given layout: #{layout.inspect}. VBlank reads the layouts " \
                             "#{readable_layouts.map(&:inspect).join(', ')}. To fix this, name one of them, or leave " \
                             "layout: out."
      end

      # The layouts a slot can name: each console's that VBlank reads, and VBlank's own.
      def self.readable_layouts = [*Console::KITS.keys.select { |name| Console.original_formats_of(name) }, VBLANK_LAYOUT]

      # What a slot's +layout+ is called in a message.
      def self.layout_title(layout)
        Console::KITS.key?(layout) ? "the #{Console.for(layout).title}'s layout" : "VBlank's own layout"
      end

      # How many colours a tile kept a byte a pixel has (Console::BYTE_A_PIXEL_TILES).
      BYTE_A_PIXEL_COLORS = 256

      def self.tile_format_of(name, layout, colors)
        # A byte is a byte in every layout, a computer game's too, so no console is asked.
        return Console::BYTE_A_PIXEL_TILES if colors == BYTE_A_PIXEL_COLORS

        formats = formats_of(name, layout)
        kinds = formats.tiles
        return kinds.first if colors.nil? && kinds.one?

        found = formats.tiles_of(colors)
        return found if found

        options = kinds.map { |format| "colors: #{format.colors}" }.join(" or ")
        raise ArgumentError, "Slot :#{name} holds tiles in #{layout_title(layout)}, which keeps tiles " \
                             "of #{kinds.map(&:colors).join(' or ')} colors. Give the slot #{options}, or " \
                             "colors: #{BYTE_A_PIXEL_COLORS} for tiles kept a byte a pixel."
      end
      private_class_method :formats_of, :tile_format_of, :number_format_of, :readable_layouts, :layout_title

      def initialize(name:, shape:, at:, count:, width:, signed:, format:, cost: 1)
        unless (at.nil? || place?(at) || release_places?(at)) && count.is_a?(Integer) && count.positive?
          raise ArgumentError, "Slot :#{name} was given at: #{at.inspect} and count: #{count.inspect}. " \
                               "at: must be a place in the copy, 0 or more. " \
                               "It can also be a Hash of places by release name, like `at: { \"US\" => 0x10, \"EU\" => 0x30 }`. " \
                               "Leave at: out for a slot the unpacking routine fills. " \
                               "count: must be 1 or more."
        end
        unless cost.is_a?(Integer) && cost.positive?
          raise ArgumentError, "Slot :#{name} was given cost: #{cost.inspect}. cost: must be a whole number, 1 or more. " \
                               "It tells how much work one byte of the slot is, and a plain copy is 1."
        end

        super
      end

      # Whether this is a view of a slot, and not a slot the pack names.
      def view? = name.is_a?(SlotView)

      # The slot of the pack the bytes are in: this one, or the one a view reads.
      def declared = view? ? name.slot : self

      # A VIEW OF THIS SLOT'S BYTES from byte +at+ on, in the shape the block makes: the block is
      # handed a name and a count and gives back a Slot of them (`Slot.tiles(name, count: count,
      # colors: 256)`). +count+ is how many items the view holds, or nil for as many as reach the
      # slot's end. +verb+ names the game's line for the errors (`as_tiles`). A view of a view
      # reads the same slot, further in.
      def viewed(verb, at:, count:)
        unless at.is_a?(Integer) && at.between?(0, byte_size - 1) && (count.nil? || (count.is_a?(Integer) && count.positive?))
          raise ArgumentError, "`#{verb}` on slot :#{name} was given at: #{at.inspect} and count: #{count.inspect}. " \
                               "at: must be a byte of the slot, 0 to #{byte_size - 1}. count: must be 1 or more. " \
                               "Leave count: out to read to the end of the slot."
        end

        from = at + (view? ? name.at : 0)
        label = :"#{declared.name}_at_#{from}"
        count ||= count_to_end(verb, at, yield(label, 1))
        made = yield(label, count)
        unless at + made.byte_size <= byte_size
          raise ArgumentError, "`#{verb}` reads #{made.byte_size} bytes from byte #{at} of slot :#{name}. The slot holds " \
                               "#{byte_size} bytes, so the view ends after the slot ends. To fix this, correct at: or count:."
        end

        made.with(name: SlotView.new(slot: declared, at: from, size: made.byte_size))
      end

      # How many items like +one+ (a Slot of one) the bytes from +at+ to the slot's end are.
      private def count_to_end(verb, at, one)
        left = byte_size - at
        return left / one.item_bytes if (left % one.item_bytes).zero?

        raise ArgumentError, "`#{verb}` reads slot :#{name} from byte #{at} to its end, which is #{left} bytes. One of " \
                             "these #{one.shape} is #{one.item_bytes} bytes, so the bytes do not make a whole number of " \
                             "them. To fix this, give count:, or correct at:."
      end

      # Whether the slot names a cost other than a plain copy's.
      def costly? = cost != 1

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
