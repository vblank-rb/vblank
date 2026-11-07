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
    #   the original is for (FormatReading), place 0 see-through. That is what `image colors:, places:` makes
    #   of the same numbers held in the game (Assets.placed_pixels). A picture can take only its
    #   colours or only its places from the file, and hold the other list itself; and it can be
    #   turned round or upside down, as `mirror` and `upside_down` turn one.
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
      # byte of its first tile, its tiles kept as +tile_format+ (a Console::TileFormat) and +across+
      # wide (Assets.picture_places_of_tiles). A list the picture holds itself, the other one, has
      # no place and no format: nil. +turns+ are the ways the picture is turned once it is read, in
      # order, each :mirrored or :upside_down (Assets::Image).
      Picture = Data.define(:colors_at, :colors_count, :color_format, :places_at, :tile_format, :across, :turns) do
        def initialize(colors_at:, colors_count:, places_at:, color_format: nil, tile_format: nil, across: 1, turns: [].freeze) = super

        # The same picture turned +way+ once it is read.
        def turned(way) = with(turns: [*turns, way].freeze)
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
        read = filled.walk.select { |node| %i[table bitmap].include?(node.kind) && node.from_file }
        read.each { |node| node.kind == :table ? fill_table(node, bytes.b) : fill_picture(node, bytes.b) }
        VBlank.logger.debug("start file") do
          "read the #{file.called}, #{file.size} bytes, into #{read.map { |node| ":#{node.name}" }.join(', ')}"
        end
        filled
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
        count = node.width * node.height
        places = if where.places_at
                   tiles = bytes.byteslice(where.places_at, (count / FormatReading::TILE_PIXELS) * where.tile_format.tile_bytes)
                   Assets.picture_places_of_tiles(FormatReading.tiles(tiles, where.tile_format).flatten, across: where.across)
                 else
                   node.places.bytes
                 end
        colors = if where.colors_at
                   FormatReading.colors(bytes.byteslice(where.colors_at, where.colors_count * 2), where.color_format)
                 else
                   node.colors
                 end
        pixels, transparent = Assets.placed_pixels(places, colors + ([0] * [PLACES - colors.length, 0].max))
        picture = Assets::Image.new(width: node.width, height: node.height, transparent: transparent, pixels: pixels, colors: colors,
                                    places: places.pack("C*"))
        picture = where.turns.reduce(picture) { |turned, way| turned.public_send(way) }
        node.pixels = picture.pixels
        node.transparent = picture.transparent
        node.colors = colors
        node.places = picture.places
        node.from_file = nil
      end
      private_class_method :fill_table, :fill_picture
    end
  end
end
