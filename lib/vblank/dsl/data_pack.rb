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
    # original's Original::Game#platform), unless it names another with +layout+. An original of a
    # platform whose layout VBlank does not read (a PlayStation's, a computer's, any other) is in
    # VBlank's own layout (Console::VBLANK_FORMATS), which its routine writes; a computer game's
    # numbers may name their +byte_order+ instead:
    #
    #   slots.tiles :walls, at: 0x4000, count: 64, colors: 4    # a Super Nintendo's tiles of four colours
    #   slots.numbers :sizes, count: 9, width: :half, signed: false   # a computer game's, low byte first
    #   slots.numbers :sizes, count: 9, width: :half, signed: false, byte_order: :high_first
    #   slots.colors :palette, count: 16                        # a computer game's, as its routine writes them
    #   slots.colors :palette, count: 16, layout: :gba          # the same, a console's layout as a shortcut
    class PackSlots
      def initialize(platform:)
        @layout = Original.layout_for(platform)
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
        add(Original::Slot.colors(name, at: at, count: count, layout: layout || @layout, cost: cost))
      end

      # +count+ tiles of 8x8 pixels, of +colors+ colours where the layout keeps more than one kind.
      # `colors: 256` is a tile kept a byte a pixel, 64 bytes, in any layout: the pictures of a
      # background that turns and resizes.
      def tiles(name, count:, at: nil, colors: nil, layout: nil, cost: 1)
        add(Original::Slot.tiles(name, at: at, count: count, colors: colors, layout: layout || @layout, cost: cost))
      end

      # +count+ numbers, each +width+ (:byte, :half or :word) wide; +signed+ sets whether they can be
      # below zero. +byte_order+ (:low_first or :high_first) names how they are kept in place of a
      # console's layout.
      def numbers(name, count:, width:, signed:, at: nil, layout: nil, byte_order: nil, cost: 1)
        add(Original::Slot.numbers(name, at: at, count: count, width: width, signed: signed,
                                         layout: layout || (@layout unless byte_order), byte_order: byte_order, cost: cost))
      end

      # +count+ pixels, one byte each: a picture of up to 256 colours, row by row, for an image's
      # `places:` (`image ..., colors: [...], places: pack[:art], see_through: 255`).
      def pixels(name, count:, at: nil, cost: 1) = add(Original::Slot.pixels(name, at: at, count: count, cost: cost))

      # +count+ samples of recorded sound, one byte each, 8-bit signed, for a recording's `pcm:`
      # (`sample :bang, pcm: pack[:bang], rate: 7000`, or `pack[:sounds].samples(first, count)`).
      def samples(name, count:, at: nil, cost: 1) = add(Original::Slot.samples(name, at: at, count: count, cost: cost))

      # +count+ notes of music, each an Original::PackNote, which the unpacking routine writes from
      # the original's songs, for a Score's part (`notes: pack[:theme].notes(instruments: %i[horn])`).
      def notes(name, count:, at: nil, cost: 1) = add(Original::Slot.notes(name, at: at, count: count, cost: cost))

      # +count+ notes of music each with its voice's settings (a voiced Original::PackNote): a
      # note's pitch number, fade, duty, vibrato, slide and shade between the speakers, which the
      # unpacking routine writes as the original's sound driver sets them, for a Score's part.
      def voiced_notes(name, count:, at: nil, cost: 1) = add(Original::Slot.voiced_notes(name, at: at, count: count, cost: cost))

      # +count+ cells of a background's map, each an Original::MapCell, which the unpacking routine
      # writes from the original's maps (`pack[:title_map].write_cell(at, tile:, bank:, ...)`), for a
      # background's `map:`.
      def map_cells(name, count:, at: nil, cost: 1) = add(Original::Slot.map_cells(name, at: at, count: count, cost: cost))

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
      # handed the release, when something asks for it, and keeps what it made: a pack whose every
      # slot is copied as it is never needs its program built as the game is. +original+ is what `from:`
      # named (an Original::Game, or an Original::Copy), which a shell reads the releases of.
      # +platform+ is the console the original is for, whose layout a view of a slot is read in
      # where it names none (PackSlot#as_tiles).
      def initialize(rom_sha1:, build_version:, slots:, make_unpacking:, original: nil, platform: Original::DEFAULT_PLATFORM)
        @rom_sha1 = rom_sha1
        @build_version = build_version
        @slots = slots.to_h { |slot| [slot.name, slot] }
        @make_unpacking = make_unpacking
        @original = original
        @platform = platform
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
      #
      # The program writes a record of each frame of a sprite the game has named by the time it is
      # asked for (Original::FrameRewrite), so ask once the game is declared: asked again after
      # the game names another frame, it is made again.
      def unpacking(release: nil) = @make_unpacking.call(release)

      # The handle of the slot named +name+.
      def [](name)
        slot = @slots.fetch(name.to_sym) do
          raise ArgumentError, "The data pack has no slot #{name.inspect}. It has #{@slots.keys.map(&:inspect).join(', ')}. " \
                               "Name the slot in the data_pack block first."
        end
        PackSlot.new(layout: slot, tile_index: nil, platform: @platform)
      end
    end

    # ONE FRAME OF A SPRITE IN A SLOT OF BYTES: the slot's handle (+slot+), the byte the frame
    # starts at, how many pieces it has where its layout does not say (+count+), and how it is kept
    # (+piece_layout+, an Original::FrameLayout), and the values the pose gives that layout's
    # reader (+pose+, by name). An image reads it (Builder::PackPoses).
    PackFrame = Data.define(:slot, :at, :count, :piece_layout, :pose)

    # A PART'S NOTES IN A SLOT OF NOTES, and the instruments a note's number names (PackSlot#notes).
    PackNotes = Data.define(:slot, :instruments)

    # ONE NUMBER OF A SLOT OF NUMBERS (PackSlot#number), and ONE ENVELOPE OF A SLOT OF BYTES
    # (PackSlot#envelope), each read as the game is built; and ONE ENVELOPE AS A SUPER NINTENDO'S
    # SOUND CHIP KEEPS IT (PackSlot#snes_envelope).
    PackNumber = Data.define(:slot, :index)
    PackEnvelope = Data.define(:slot, :index)
    PackSNESEnvelope = Data.define(:slot, :index)

    # ONE WAVE OF THE WAVE VOICE IN A SLOT OF BYTES (PackSlot#wave), for a Score part's `plays:`:
    # sixteen bytes from wave +index+ on, two steps of the wave a byte, the earlier in the high four
    # bits, as the Game Boy's wave memory keeps them (Audio::Sound.wave_steps_of_bytes).
    PackWave = Data.define(:slot, :index)

    class PackWave
      BYTES = Audio::Sound::WAVE_BYTES

      # The 32 steps, 0 to 15 each, of the wave's +bytes+ (a list of sixteen numbers).
      def self.steps_of(bytes) = Audio::Sound.wave_steps_of_bytes(bytes)

      # Where the wave's first byte is in its slot.
      def first_byte = index * BYTES
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
    #
    # A VIEW is a handle on some of a slot's bytes read in a shape of their own (#as_tiles and its
    # siblings): its +layout+ is the view's (Original::Slot#viewed), so every verb takes it as it
    # takes a slot of that shape. +platform+ is the console the original is for, whose layout a
    # view is read in where it names none.
    PackSlot = Data.define(:layout, :tile_index, :across, :down, :first_color, :color_count, :first_pixel, :pixel_count,
                           :platform) do
      def initialize(layout:, tile_index: nil, across: 1, down: 1, first_color: nil, color_count: nil, first_pixel: 0,
                     pixel_count: nil, platform: Original::DEFAULT_PLATFORM) = super

      def shape = layout.shape

      # THE VIEWS: `count` items of another shape, read from byte `at` of this slot on (0 first).
      # A console keeps its tiles of both kinds and its maps in one block of video memory, and a
      # port that keeps the block as one slot reads each part of it so:
      #
      #   video = pack[:video]                                   # slots.tiles :video, count: 2048
      #   pictures = video.as_tiles(at: 0x8000, count: 256, colors: 256)
      #   cells    = video.as_numbers(at: 0xC000, count: 1024, width: :byte, signed: false)
      #
      # Each takes what the `slots.` line of its shape takes, and hands back a handle every verb
      # takes as it takes a slot of that shape, which narrows as one does (`.tile(4)`,
      # `.numbers(first, count)`). `count:` left out reads to the end of the slot. A view that
      # ends after the slot ends is refused.

      # A view as tiles of 8x8 pixels, of +colors+ colours where the layout keeps more than one kind.
      def as_tiles(at:, count: nil, colors: nil, layout: nil)
        console = layout || Original.layout_for(platform)
        view("as_tiles", at, count) { |name, held| Original::Slot.tiles(name, count: held, colors: colors, layout: console) }
      end

      # A view as numbers, each +width+ wide and +signed+ or not.
      def as_numbers(at:, width:, signed:, count: nil, layout: nil, byte_order: nil)
        console = layout || (Original.layout_for(platform) unless byte_order)
        view("as_numbers", at, count) do |name, held|
          Original::Slot.numbers(name, count: held, width: width, signed: signed, layout: console, byte_order: byte_order)
        end
      end

      # A view as colours, two bytes each.
      def as_colors(at:, count: nil, layout: nil)
        console = layout || Original.layout_for(platform)
        view("as_colors", at, count) { |name, held| Original::Slot.colors(name, count: held, layout: console) }
      end

      # A view as pixels, one byte each.
      def as_pixels(at:, count: nil) = view("as_pixels", at, count) { |name, held| Original::Slot.pixels(name, count: held) }

      # A view as samples of recorded sound, one byte each.
      def as_samples(at:, count: nil) = view("as_samples", at, count) { |name, held| Original::Slot.samples(name, count: held) }

      # Whether the handle is on a whole slot or a whole view: no tiles, bank or run picked from it.
      def whole? = tile_index.nil? && first_color.nil? && pixel_count.nil?

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

      # A handle on +count+ numbers from number +first+ (0 first) of a slot of numbers, for a
      # background's `map:` kept among other things in a bigger slot, as a console keeps a
      # map in a block of its video memory. It shares the first and the count of a handle on pixels.
      def numbers(first, count) = bytes_run(:numbers, first, count)

      # Whether the handle is on a run of a slot of numbers, and not on the whole slot.
      def run_of_numbers? = shape == :numbers && !pixel_count.nil?

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

      # A handle on a slot of notes as a part of a Score plays them (`Score::Part.new(notes: ...)`):
      # +instruments+ names the recordings a note's instrument number counts through, 0 first.
      def notes(instruments: [])
        unless Original::Slot::NOTE_SHAPES.include?(shape)
          raise ArgumentError, "Slot :#{layout.name} holds #{shape}. `notes` reads a slot of notes. To fix this, call " \
                               "it on a slot like `slots.notes :theme, count: 400`."
        end

        DSL::PackNotes.new(slot: self, instruments: instruments)
      end

      # A handle on wave +index+ (0 first) of a slot of bytes, sixteen bytes each, for the wave a
      # Score part plays (`plays: pack[:waves].wave(0)`, DSL::PackWave says how it is kept).
      def wave(index)
        refuse_run_counted_from_slot_start!("wave")
        unless shape == :numbers && layout.width == :byte && index.is_a?(Integer) && !index.negative? &&
               (index + 1) * PackWave::BYTES <= layout.count
          raise ArgumentError, "Slot :#{layout.name} holds #{layout.count} #{shape}. `wave` picks #{PackWave::BYTES} " \
                               "bytes of a slot of bytes, two steps of the wave a byte. Got #{index.inspect}."
        end

        DSL::PackWave.new(slot: self, index: index)
      end

      # A handle on number +index+ (0 first) of a slot of numbers, for a setting read as the game is
      # built: an instrument's `rate:` or `holds_from:`.
      def number(index)
        refuse_run_counted_from_slot_start!("number")
        unless shape == :numbers && index.is_a?(Integer) && index.between?(0, layout.count - 1)
          raise ArgumentError, "Slot :#{layout.name} holds #{layout.count} #{shape}. `number` picks one number of a slot " \
                               "of numbers, 0 to #{layout.count - 1}. Got #{index.inspect}."
        end

        DSL::PackNumber.new(slot: self, index: index)
      end

      # A handle on envelope +index+ (0 first) of a slot of bytes, four bytes each in the order an
      # Audio::Envelope keeps them (attack, decay, sustain, release), for an instrument's `envelope:`.
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

      # A handle on envelope +index+ (0 first) of a slot of bytes, three bytes each as a Super
      # Nintendo's sound chip keeps them (ADSR1, ADSR2, GAIN: an Audio::SNESEnvelope), for an
      # instrument's `envelope:`.
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

      # A handle on the frame of a sprite from byte +at+ (0 first) of a slot of bytes, kept as
      # +layout+ (an Original::FrameLayout) says, for an image's `frame:`. +count+ is how many pieces
      # it has, for a layout whose frames do not say. +with+ is the values the pose gives the
      # layout's own reader by name (`with: { block: 5 }`), checked here against those it reads.
      def frame(at, layout:, count: nil, with: {})
        # +layout+ here is the frame's; the slot's own is self.layout.
        refuse_run_counted_from_slot_start!("frame")
        refuse_frame_of_view!
        unless shape == :numbers && self.layout.width == :byte
          raise ArgumentError, "Slot :#{self.layout.name} holds #{shape}. `frame` reads a frame from a slot of numbers one " \
                               "byte wide. To fix this, call it on a slot like `slots.numbers :frames, width: :byte, ...`."
        end

        unless layout.is_a?(Original::FrameLayout)
          raise ArgumentError, "`frame` was given layout: #{layout.inspect}. To fix this, give it a " \
                               "VBlank::Original::FrameLayout, which says how the original keeps a frame."
        end

        DSL::PackFrame.new(slot: self, at: at, count: count, piece_layout: layout, pose: layout.pose_values_for(with))
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

      # A frame is written again by the pack's unpacking, which finds it by the slot the pack
      # names (Original::FrameRewrite), so it is read from such a slot.
      def refuse_frame_of_view!
        return unless layout.view?

        raise ArgumentError, "`frame` was called on a view of slot :#{layout.declared.name}. A frame is read from a " \
                             "slot that the data pack names. To fix this, name the bytes of the frames as a slot of " \
                             "numbers one byte wide in `data_pack`."
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
