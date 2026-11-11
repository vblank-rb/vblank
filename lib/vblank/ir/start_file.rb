# frozen_string_literal: true

module VBlank
  module IR
    # A FILE A PROGRAM IS HANDED AS IT STARTS, which some of its data is read from rather than
    # written into it. A port of a retail game must not ship the game's data, so a build for a
    # computer can leave the data pack out (Builder::DataPacks): the program is the game's code
    # alone, and the player's pack is handed to it when it starts. The program that makes the pack,
    # the game's unpacking (Original::Unpacking), is built the same way and handed the player's copy
    # of the original.
    #
    # What the program declares about the file, on Nodes::Program#start_file: what it is +called+ in
    # what a player is told ("data pack"), its +size+ in bytes, and the +checks+ (each a Check):
    # bytes the file must hold at a place, which tell a file for this build from any other. The
    # size and the checks are known when the program is built, since the file's layout follows
    # from the shapes and sizes the game wrote (Original::Slot), never from what it holds.
    #
    # WHAT IS READ FROM IT, each at a place in the file fixed when the program is built:
    #
    # - a table (Nodes::Table#from_file, where its first entry starts, and #entries_in_file): its
    #   entries one after another, each as wide as the table sets, in the
    #   layout of #file_number_format (a Console::NumberFormat), below zero only for a signed table (Build.elements_of);
    # - a picture given as places into a list of colours (Nodes::Bitmap#from_file, a Picture): the
    #   colours, two bytes each, and the places, in tiles of 8x8, each in the layout of the console
    #   the original is for (FormatReading), place 0 see-through, or one byte a pixel row by row in any
    #   layout with the place the picture names see-through. That is what `image colors:, places:` makes
    #   of the same numbers held in the game (Assets.placed_pixels, which both use). A picture can take only its
    #   colours or only its places from the file, and hold the other list itself; and it can be
    #   turned round or upside down, as `mirror` and `upside_down` turn one.
    # - a recording (Nodes::Sample#from_file): its samples, one byte each, 8-bit signed, as many as the
    #   zeros of its bytes; the program holds zeros until the file is read.
    # - a background (Nodes::Background#from_file, a Background): its map, one number of two bytes
    #   a cell in the layout the original's console keeps a map in (Console::MapWordFormat), and
    #   the tiles and the banks of colours those numbers pick from. Which tiles there are and what
    #   the map holds is known only once the file is read, so the program holds a tile for each
    #   bank and a map of the right size that names the first, and its lists of colours are
    #   BANK COLOURS (.bank_colors), which name a bank and hold none of its colours.
    #
    # A table read from the file holds no entries in the program, and a picture holds zeros; nothing
    # the build works out may depend on them. Each backend that plays such a program reads the file
    # before the program's first statement: the interpreter makes the program it plays with the
    # file's numbers in place (StartFile.filled), and the runtimes for a computer (C, JavaScript,
    # Ruby) fill the same arrays from the file at power-on. A cartridge is never handed a file, so
    # every cartridge lowering refuses such a program (Backends.refuse_start_file_on_cartridge!).
    StartFile = Data.define(:called, :size, :checks)

    class StartFile
      # Bytes the file must hold from +at+ on.
      Check = Data.define(:at, :bytes)

      # Where a picture's colours and places are in the file: +colors_at+, the first colour, of
      # +colors_count+, kept as +color_format+ (a Console::ColorFormat); and +places_at+, the first
      # byte of its places. Those are tiles kept as +tile_format+ (a Console::TileFormat) and
      # +across+ wide (Assets.picture_places_of_tiles), or, where +places_by_byte+, one byte a pixel
      # row by row, a picture of up to 256 colours as a computer game keeps its art. A list the
      # picture holds itself, the other one, has no place and no format: nil. +see_through+ is the
      # place not drawn: 0, as a picture of tiles has it, any place a picture of bytes names, or nil
      # for none. A place past the colours is drawn in colour 0. +turns+ are the ways the picture is
      # turned once it is read, in order, each :mirrored or :upside_down (Assets::Image).
      Picture = Data.define(:colors_at, :colors_count, :color_format, :places_at, :tile_format, :across, :places_by_byte,
                            :see_through, :turns) do
        def initialize(colors_at:, colors_count:, places_at:, color_format: nil, tile_format: nil, across: 1,
                       places_by_byte: false, see_through: 0, turns: [].freeze) = super

        # The same picture turned +way+ once it is read.
        def turned(way) = with(turns: [*turns, way].freeze)
      end

      # Where a background's map, tiles and colours are in the file, as the original keeps them.
      # The map is +cells+ numbers of two bytes from +map_at+ on, kept as +number_format+ (a
      # Console::NumberFormat), +across+ of them to a row, each a cell in the layout +map_words+ (a
      # Console::MapWordFormat) and +cell_tiles+ tiles square. A cell's tile is counted from the
      # tile at +tiles_at+, of +tile_count+ tiles kept as +tile_format+ (a Console::TileFormat). Its
      # bank is counted from the colour at +colors_at+, of +bank_count+ banks of +bank_size+ colours
      # kept as +color_format+ (a Console::ColorFormat); +bank_names+ are the names the game knows
      # the banks' lists by, bank 0 first.
      #
      # The file is the player's, so nothing in it stops the game: a cell naming a tile past
      # +tile_count+ draws nothing, and one naming a bank past +bank_count+ is drawn in colour 0.
      Background = Data.define(:map_at, :cells, :across, :cell_tiles, :number_format, :map_words, :tiles_at, :tile_count,
                               :tile_format, :colors_at, :bank_count, :bank_size, :color_format, :bank_names) do
        # How many tiles across and down the map is, and how many that makes: a tile of its own
        # for each, since two cells are known to show one tile only once the file is read.
        def columns = across * cell_tiles
        def rows = (cells / across) * cell_tiles
        def tiles_drawn = columns * rows
      end

      # The kinds of node that read from the file. Each has a branch in .fill_node: a new kind is one
      # name here and one branch there.
      READ_KINDS = %i[table bitmap sample background].freeze

      # BANK COLOURS: a list of colours that names a bank of the file's colours and holds none of
      # them. A program built with its pack left out knows that a background's tiles are drawn
      # from bank 2 and not what bank 2 holds, and its lists of colours are compared with each
      # other (Nodes::Background#list_swaps), so a bank's list must be unlike every list a game
      # can write. A colour is fifteen bits; each of these has the sixteenth set, then the bank
      # and the place. Place 0 is see-through as in any list. Nothing draws one: each backend
      # that plays such a program puts the file's colours in its place (.bank_of).
      BANK_COLOR = 0x8000
      BANK_SHIFT = 8

      def self.bank_colors(bank, size) = [0, *(1...size).map { |place| BANK_COLOR | (bank << BANK_SHIFT) | place }]

      # The bank +colors+ names, or nil for a list of colours.
      def self.bank_of(colors)
        named = colors && colors.length > 1 && colors[1].is_a?(Integer) && (colors[1] & BANK_COLOR) != 0
        named ? (colors[1] & ~BANK_COLOR) >> BANK_SHIFT : nil
      end

      # The most colours a picture's places can pick from: a place is four bits.
      PLACES = 16

      # THE CHECK OF A FILE, AS EVERY RUNTIME IS HANDED IT: +numbers+, the file's size, how many
      # checks, and each check as where it starts, how long it is and its bytes; and +words+, the
      # sentences for a file that fails it. Built once here, so the interpreter, the shell and the C,
      # JavaScript and Ruby runtimes (rg_start_file_refusal in each) all refuse a file alike.
      Rules = Data.define(:numbers, :words) do
        # Why +bytes+ (a binary String, or nil when no file was handed over) fails the check, or nil.
        def refusal(bytes)
          return words.missing if bytes.nil?
          return StartFile.fill_words(words.wrong_size, size: bytes.bytesize) if bytes.bytesize != numbers[0]

          check = 2
          numbers[1].times do
            at = numbers[check]
            length = numbers[check + 1]
            if bytes.byteslice(at, length).bytes != numbers[check + 2, length]
              return StartFile.fill_words(words.wrong_check, from: at, to: at + length - 1)
            end

            check += 2 + length
          end
          nil
        end
      end

      # The sentences of Rules: for no file (+missing+), for a file of another size (+wrong_size+,
      # with {size} for its size) and for a file without the bytes a check names (+wrong_check+, with
      # {from} and {to} for the first and the last of them).
      Words = Data.define(:missing, :wrong_size, :wrong_check)

      # +text+ with each {name} in it that +values+ has a value for replaced by that value, as
      # rg_words_fill does in each runtime. A {name} it has none for is left as it is.
      def self.fill_words(text, **values)
        text.gsub(/\{(\w+)\}/) do |whole|
          name = ::Regexp.last_match(1).to_sym
          values.key?(name) ? values[name].to_s : whole
        end
      end

      # The Rules of this file.
      def rules
        fix = "Hand it the #{called} this build was made for."
        Rules.new(
          numbers: [size, checks.length, *checks.flat_map { |check| [check.at, check.bytes.bytesize, *check.bytes.bytes] }],
          words: Words.new(
            missing: "This game reads its #{called} as it starts, and no #{called} was handed to it. Start the game with its #{called}.",
            wrong_size: "The #{called} handed to the game is {size} bytes. This build reads a #{called} of #{size} bytes. #{fix}",
            wrong_check: "This file is not the #{called} this build reads: bytes {from} to {to} are not what it holds there. #{fix}"
          )
        )
      end

      # The words a program stops with when +bytes+ (a binary String, or nil when no file was
      # handed over) is not the file it reads, or nil when it is.
      def refusal(bytes) = rules.refusal(bytes)

      # +program+ as it plays handed +bytes+: a copy, its tables and pictures from the file holding
      # the file's numbers, and no file left to read. ProgramError, in #refusal's words, when
      # +bytes+ is not the file +program+ reads. A program that reads no file is handed back as it is.
      def self.filled(program, bytes)
        file = program.start_file
        return program unless file

        refusal = file.refusal(bytes&.b)
        if refusal
          VBlank.logger.debug("start file") { "refused the #{file.called} handed over: #{refusal}" }
          raise ProgramError, refusal
        end

        filled = program.copy
        filled.start_file = nil
        read = filled.walk.select { |node| READ_KINDS.include?(node.kind) && node.from_file }
        read.each { |node| fill_node(filled, node, bytes.b) }
        VBlank.logger.debug("start file") do
          "read the #{file.called}, #{file.size} bytes, into #{read.map { |node| ":#{node.name}" }.join(', ')}"
        end
        filled
      end

      # What +node+ (a table, a picture, a recording or a background) of +program+ reads from the file.
      def self.fill_node(program, node, bytes)
        case node.kind
        when :table then fill_table(node, bytes)
        when :bitmap then fill_picture(node, bytes)
        when :sample then fill_recording(node, bytes)
        when :background then fill_background(program, node, bytes)
        else raise ArgumentError, "a #{node.kind} is not read from the file (READ_KINDS names the kinds that are)"
        end
      end

      # A recording's samples, read from the place it names: one byte each, as long as the zeros the
      # program holds for them.
      def self.fill_recording(node, bytes)
        node.bytes = bytes.byteslice(node.from_file, node.bytes.bytesize)
        node.from_file = nil
      end

      # A table's entries, read from the place it names.
      def self.fill_table(node, bytes)
        count = node.entries_in_file
        node.values = Build.elements_of(bytes.byteslice(node.from_file, count * Build::ELEMENT_BYTES.fetch(node.width)),
                                        width: node.width, signed: node.signed, high_byte_first: node.file_number_format.high_byte_first)
        node.from_file = nil
        node.entries_in_file = nil
        node.file_number_format = nil
      end

      # A picture's colours and places, read from the place it names or held by the picture, and its
      # pixels made from them as `image colors:, places:` makes them, then turned as it is told. A
      # place past the colours shows colour 0, as each runtime fills it.
      def self.fill_picture(node, bytes)
        where = node.from_file
        places = picture_places(node, where, bytes)
        colors = if where.colors_at
                   FormatReading.colors(bytes.byteslice(where.colors_at, where.colors_count * 2), where.color_format)
                 else
                   node.colors
                 end
        pixels, transparent = Assets.placed_pixels(places, colors, see_through: where.see_through)
        picture = Assets::Image.new(width: node.width, height: node.height, transparent: transparent, pixels: pixels,
                                    colors: colors, places: places.pack("C*"))
        picture = where.turns.reduce(picture) { |turned, way| turned.turned(way) }
        node.pixels = picture.pixels
        node.transparent = picture.transparent
        node.colors = colors
        node.places = picture.places
        node.from_file = nil
      end

      # A picture's places row by row: one byte a pixel, or the tiles they are kept in, read from the
      # file; or the places the picture holds itself.
      def self.picture_places(node, where, bytes)
        count = node.width * node.height
        return node.places.bytes unless where.places_at
        return bytes.byteslice(where.places_at, count).bytes if where.places_by_byte

        tiles = bytes.byteslice(where.places_at, (count / FormatReading::TILE_PIXELS) * where.tile_format.tile_bytes)
        Assets.picture_places_of_tiles(FormatReading.tiles(tiles, where.tile_format).flatten, across: where.across)
      end

      # A BACKGROUND'S TILES AND MAP, read from the places it names, as the build makes them of the
      # same numbers held in the game (Builder::PackBackgrounds): each different tile as drawn (a
      # tile, its bank and its turn) a picture of +program+, drawn from its bank's list, and the
      # map those pictures, a cell whose tile draws nothing left empty. Its lists of colours that
      # name a bank (.bank_colors) hold the bank's colours from here on.
      def self.fill_background(program, node, bytes)
        from = node.from_file
        banks = bank_lists(from, bytes)
        words = FormatReading.numbers(bytes.byteslice(from.map_at, from.cells * 2), from.number_format, width: :half, signed: false)
        pictures = {}
        side = from.cell_tiles
        drawn = words.each_slice(from.across).flat_map do |row|
          Array.new(side) do |down|
            row.flat_map do |word|
              Array.new(side) do |along|
                tile = from.map_words.cell_tile(word, along, down, side)
                pictures.fetch(tile) { pictures[tile] = declare_background_tile(program, node, tile, banks, bytes, pictures.length) }
              end
            end
          end
        end
        node.tiles = pictures.values.compact
        numbers = node.tiles.each_with_index.to_h
        node.map = drawn.map { |row| row.map { |picture| picture && numbers.fetch(picture) } }
        node.palettes = (node.palettes || []).map { |colors| colors_held(colors, banks) }
        node.recolors = (node.recolors || []).map { |step| step.map { |colors| colors_held(colors, banks) } }
        node.from_file = nil
      end

      # Each bank's colours as a list of colours keeps them, see-through first.
      def self.bank_lists(from, bytes)
        Array.new(from.bank_count) do |bank|
          kept = bytes.byteslice(from.colors_at + (bank * from.bank_size * 2), from.bank_size * 2)
          [0, *FormatReading.colors(kept, from.color_format).drop(1)]
        end
      end

      # +colors+ as a filled program holds them: the bank's colours for a list that names a bank,
      # and any other list as it is.
      def self.colors_held(colors, banks)
        bank = bank_of(colors)
        bank ? banks.fetch(bank) : colors
      end

      # The picture of +tile+ (a Console::CellTile) of the background +node+, declared in +program+,
      # by its name; nil for a tile that draws nothing, left empty in the map. A tile past the
      # file's tiles draws nothing, and a bank past its colours is every place colour 0.
      def self.declare_background_tile(program, node, tile, banks, bytes, number)
        from = node.from_file
        return nil unless tile.tile < from.tile_count

        tile_bytes = from.tile_format.tile_bytes
        places = FormatReading.tiles(bytes.byteslice(from.tiles_at + (tile.tile * tile_bytes), tile_bytes), from.tile_format).first
        return nil if places.all?(&:zero?)

        colors = banks.fetch(tile.bank) { Array.new(from.bank_size, 0) }
        pixels, transparent = Assets.placed_pixels(places, colors)
        side = FormatReading::TILE_SIDE
        picture = Assets::Image.new(width: side, height: side, transparent: transparent, pixels: pixels, colors: colors,
                                    places: places.pack("C*"), colors_name: from.bank_names[tile.bank])
        picture = tile.turns.reduce(picture) { |turned, way| turned.turned(way) }
        # A name in several scenes is a background of each, so the scene is in the picture's name.
        name = :"background :#{node.name}#{" of scene :#{node.scene}" if node.scene} tile #{number}"
        program.add_child(Build.bitmap(name, width: side, height: side, pixels: picture.pixels, transparent: picture.transparent,
                                             colors: colors, places: picture.places, colors_name: picture.colors_name))
        name
      end
      private_class_method :fill_node, :fill_recording, :fill_table, :fill_picture, :picture_places, :fill_background,
                           :bank_lists, :colors_held, :declare_background_tile
    end
  end
end
