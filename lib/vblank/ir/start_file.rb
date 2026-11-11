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
    # - a pose that is one of the original's frames (Nodes::Bitmap#from_file, a Pose): the frame's
    #   pieces, each a few bytes kept as the port's Original::FrameLayout says, and the tiles they
    #   name. How many pieces there are and what each is is known only once the file is read, so
    #   the program holds a picture of the size the game gave, and each piece is painted into it.
    # - a recording (Nodes::Sample#from_file): its samples, one byte each, 8-bit signed, as many as the
    #   zeros of its bytes; the program holds zeros until the file is read.
    # - a recording's settings (Nodes::Sample#settings_from_file, a RecordingSettings): the rate it
    #   was recorded at, the sample a held note reads back to and its envelope, each a number or
    #   four bytes of the file. The program holds a stand-in for each (.recording_stand_ins).
    # - a part of a song (Audio::Music::Part#from_file, a Notes): its notes, records of VBlank's own
    #   that a port's unpacking writes. The program holds no event for it.
    # - a background (Nodes::Background#from_file, a Background): its map, one number of two bytes
    #   a cell in the layout the original's console keeps a map in (Console::MapWordFormat), or
    #   one byte a cell that is a tile's number (Console::BYTE_MAP_CELLS), and
    #   the tiles and the banks of colours those numbers pick from. Which tiles there are and what
    #   the map holds is known only once the file is read, so the program holds a tile for each
    #   bank and a map of the right size that names the first, and its lists of colours hold a
    #   marker for each colour of a bank (below). The tiles of the cells it was told it may be
    #   written later are known but for their pixels, so the program holds each after the banks'
    #   as a picture of its own read from the file, and the map's tiles follow them.
    # - a screen's backdrop (Nodes::Screen#backdrop_from_file, a Color): the one colour the screen
    #   shows wherever nothing is drawn. The program holds no colour for it.
    # - a list of colours (`colors :name, pack[:slot]`, a bank of a background from the pack, a
    #   walk of either): +colors+ names each colour of it once (a Color in the file, or a
    #   WalkedColor made from one), and wherever the program would hold the colour it holds a
    #   MARKER naming that entry (.marker_of). See "MARKERS" below.
    #
    # A table read from the file holds no entries in the program, and a picture holds zeros; nothing
    # the build works out may depend on them. Each backend that plays such a program reads the file
    # before the program's first statement: the interpreter makes the program it plays with the
    # file's numbers in place (StartFile.filled), and the runtimes for a computer (C, JavaScript,
    # Ruby) fill the same arrays from the file at power-on. A cartridge is never handed a file, so
    # every cartridge lowering refuses such a program (Backends.refuse_start_file_on_cartridge!).
    StartFile = Data.define(:called, :size, :checks, :colors)

    class StartFile
      def initialize(called:, size:, checks:, colors: [].freeze) = super

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
      #
      # A picture of bytes can be a PIECE OF A WIDER ONE, as a letter is of a strip of them: its rows
      # are then not one run of the file. +row_bytes+ is how many bytes of the file are from one of
      # its rows to the next, the wider picture's width; nil for a picture whose rows follow each
      # other, which is its own width.
      Picture = Data.define(:colors_at, :colors_count, :color_format, :places_at, :tile_format, :across, :places_by_byte,
                            :see_through, :turns, :row_bytes) do
        def initialize(colors_at:, colors_count:, places_at:, color_format: nil, tile_format: nil, across: 1,
                       places_by_byte: false, see_through: 0, turns: [].freeze, row_bytes: nil) = super

        # The same picture turned +way+ once it is read.
        def turned(way) = with(turns: [*turns, way].freeze)

        # A piece of this picture of bytes that starts +left+ pixels along each of its rows:
        # the same rows, read from further along. +whole_width+ is how wide this picture is.
        def piece_from(left, whole_width:) = with(places_at: places_at + left, row_bytes: row_bytes || whole_width)
      end

      # Where a pose's frame and the tiles its pieces name are in the file, as the original keeps
      # them. The frame starts at +frame_at+, in a slot that ends before +frame_end+, and is kept
      # as +layout+ (an Original::FrameLayout); +count+ is how many pieces it has, or nil for a
      # layout whose frames start with their count. A piece sits from the object's place, which
      # is +origin_x+ and +origin_y+ in the picture. Its tiles are counted from the tile at
      # +tiles_at+, of +tile_count+ tiles kept as +tile_format+ (a Console::TileFormat). The
      # colours are as a Picture's: +colors_count+ of them from +colors_at+ kept as
      # +color_format+, or held by the picture where +colors_at+ is nil. Place 0 is see-through.
      # +turns+ are the ways the whole picture is turned once it is painted, as a Picture's.
      #
      # The file is the player's, so nothing in it stops the game. Pieces are read while they
      # end inside the slot, however many the frame says it has. A piece, or the part of one,
      # outside the picture is not painted, and a tile past +tile_count+ paints nothing. Where
      # two pieces overlap the earlier one is in front, as a console draws its sprites.
      Pose = Data.define(:frame_at, :frame_end, :count, :layout, :origin_x, :origin_y, :tiles_at, :tile_count, :tile_format,
                         :colors_at, :colors_count, :color_format, :turns) do
        def initialize(frame_at:, frame_end:, layout:, origin_x:, origin_y:, tiles_at:, tile_count:, tile_format:, colors_count:,
                       count: nil, colors_at: nil, color_format: nil, turns: [].freeze) = super

        # The same pose turned +way+ once it is painted.
        def turned(way) = with(turns: [*turns, way].freeze)
      end

      # Where a background's map, tiles and colours are in the file, as the original keeps them.
      # The map is +cells+ numbers from +map_at+ on, kept as +number_format+ (a
      # Console::NumberFormat), +across+ of them to a row, each a cell in the layout +map_words+ (a
      # Console::MapWordFormat, which sets how many bytes a cell is: two, or one for a map of
      # tile numbers alone, as a layer that turns keeps it) and +cell_tiles+ tiles square. A cell's tile is counted from the
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

      # ONE COLOUR IN THE FILE: the two bytes from +at+ on, kept as +format+ (a Console::ColorFormat).
      # It stands where a program built holding its data keeps a colour of fifteen bits, for a
      # colour that is no part of a picture: a screen's backdrop today. A list of colours read
      # from the file is one of these for each of its places, two bytes apart.
      Color = Data.define(:at, :format)

      # The fifteen bits of the colour +where+ (a Color) names in +bytes+, the file.
      def self.color_in(bytes, where) = FormatReading.colors(bytes.byteslice(where.at, 2), where.format).first & 0x7FFF

      # ONE NUMBER IN THE FILE: +width+ (:byte, :half or :word) from +at+ on, below zero only where
      # +signed+, kept as +format+ (a Console::NumberFormat).
      Number = Data.define(:at, :width, :signed, :format)

      # The number +where+ (a Number) names in +bytes+, the file.
      def self.number_in(bytes, where)
        kept = bytes.byteslice(where.at, Build::ELEMENT_BYTES.fetch(where.width))
        FormatReading.numbers(kept, where.format, width: where.width, signed: where.signed).first
      end

      # AN ENVELOPE IN THE FILE: the bytes from +at+ on, kept as +kept_as+ names. :envelope is the
      # four bytes an Audio::Envelope keeps, in its order (attack, decay, sustain, release); another
      # way of keeping one is another name here and a branch in .envelope_in and in each runtime's
      # rg_mix_fill_shapes.
      EnvelopeBytes = Data.define(:at, :kept_as)

      # The Audio::Envelope +where+ (an EnvelopeBytes) names in +bytes+, the file.
      def self.envelope_in(bytes, where)
        raise ArgumentError, "an envelope kept as #{where.kept_as.inspect} is not read from the file" unless where.kept_as == :envelope

        attack, decay, sustain, release = bytes.byteslice(where.at, 4).bytes
        Audio::Envelope.new(attack: attack, decay: decay, sustain: sustain, release: release)
      end

      # WHAT OF A RECORDING'S SETTINGS IS IN THE FILE, each nil where the game wrote it: +rate+ and
      # +holds_from+ a Number, +envelope+ an EnvelopeBytes.
      #
      # The file is the player's, so nothing in it stops the game, where the build that holds the
      # same numbers refuses them (.rate_held, .hold_held): a rate below 1 plays as 1, so the
      # recording all but stands still, and a held note that would read back to a sample outside
      # the recording reads back to its first sample or its last.
      RecordingSettings = Data.define(:rate, :holds_from, :envelope) do
        def initialize(rate: nil, holds_from: nil, envelope: nil) = super
      end

      def self.rate_held(rate) = [rate, 1].max
      def self.hold_held(holds_from, length) = holds_from.clamp(0, length - 1)

      # WHAT A RECORDING HOLDS FOR A SETTING IT READS FROM THE FILE, until the file is read:
      # numbers a build can lay a recording out with and must work nothing out from. The envelope
      # is one with a shape, so a build makes room for a shape.
      RECORDING_STAND_IN_RATE = 1
      RECORDING_STAND_IN_HOLD = 0
      def self.recording_stand_in_envelope = Audio::Envelope.new(attack: 0, decay: 0, sustain: 0, release: 0)

      # A PART'S NOTES IN THE FILE (Audio::Music::Part#from_file): +count+ records of eight bytes
      # from +at+ on, each an Original::PackNote, ended early by a note that ends its part.
      # +instruments+ are the recordings a note's instrument number picks from, in order. The
      # rest is what turns the records into the events a part plays, which is the Score's work:
      # +part+, the Audio::Score::Part with no notes in it, +tempo+ and +ticks_per_beat+, the
      # Score's, and +who+, how a message names the part.
      #
      # WHAT IS KNOWN AS THE GAME IS BUILT is how many records there can be, the song's length in
      # frames (the Score gives its `length:`), the frame every tick falls on, and what each key,
      # each instrument and each volume a record can name comes to on the part's voice (#key_events).
      # Only which of them each record names, and when, is the file's. So a backend that plays
      # the program without the file holds room for the most events the records can make
      # (#most_events) and makes them as it starts, by the rule .notes_in and Audio::Score::Events
      # are: the records in the order of their ticks, a rest where a note's length runs out
      # before the next begins, the later of two on one frame, none past the song's end, and each
      # part put right for coming round (IR::Tunes.loop_passes).
      #
      # The file is the player's, so nothing in it stops the game, where the build that holds the
      # same records refuses them: a key past 127 is a rest, and an instrument the part does not
      # name or a volume past 15 is the part's own.
      Notes = Data.define(:at, :count, :instruments, :part, :tempo, :ticks_per_beat, :who) do
        # The frame each tick falls on (an Audio::Score::Timing).
        def timing = Audio::Score::Timing.new(self)

        # The most events the records can make: a note and the rest it ends in, for each.
        def most_events = count * 2

        # The part as it plays +notes+ (Audio::Score::Note each) in a song +total+ frames long.
        def voice_playing(notes, total) = part.with(notes: notes).to_voice(timing, total, who)

        # WHAT EACH KEY COMES TO ON THE PART'S VOICE: the event a note of each key from 0 to
        # MOST_KEY makes, in the keys' order, worked out as the part works any note out (its
        # voice, its transpose). An event's frame is its key.
        def key_events
          notes = (0..MOST_KEY).map { |key| Audio::Score::Note.new(at: key, key: key) }
          part.with(notes: notes).to_voice(TicksAsFrames, MOST_KEY + 1, who).events
        end
      end

      # The highest key and the loudest volume a record names.
      MOST_KEY = 127
      MOST_VOLUME = 15

      # A timing that puts each tick on the frame of its own number (Notes#key_events).
      module TicksAsFrames
        def self.at(tick) = tick
      end

      # The notes +where+ (a Notes) names in +bytes+, the file, in the records' order, with what
      # no part can play held as Notes says.
      def self.notes_in(bytes, where)
        records = Original::PackNote.list_in(bytes.byteslice(where.at, where.count * Original::PackNote::BYTES))
        records.map do |note|
          Audio::Score::Note.new(at: note.at, length: (note.length unless note.length.zero?),
                                 key: (note.key if note.key <= MOST_KEY), volume: (note.volume if note.volume <= MOST_VOLUME),
                                 instrument: where.instruments[note.instrument])
        end
      end

      # The kinds of node that read from the file. Each has a branch in .fill_node: a new kind is one
      # name here and one branch there. A screen reads only its backdrop, and most screens read
      # nothing (.place_in_file); a song reads the notes of the parts that keep theirs there.
      READ_KINDS = %i[table bitmap sample background screen song].freeze

      # Where in the file +node+ reads from, or nil for a node that reads nothing from it.
      def self.place_in_file(node)
        return nil unless READ_KINDS.include?(node.kind)

        case node.kind
        when :screen then node.backdrop_from_file
        when :sample then node.from_file || node.settings_from_file
        when :song then node.voices.filter_map(&:from_file).first
        else node.from_file
        end
      end

      # A COLOUR MADE FROM ANOTHER AS THE GAME STARTS: entry +of+ of the file's colours
      # (StartFile#colors), each of its three channels moved +steps+ toward those of +far+ (a
      # colour of fifteen bits) and no further (Graphics::Color.walked_toward). It is one step of
      # a walk of a list read from the file (Builder#color_walk), whose colours the build cannot
      # work out. +of+ always names an entry before this one, so the entries are made in order.
      WalkedColor = Data.define(:of, :far, :steps)

      # MARKERS: A COLOUR KNOWN ONLY AS THE GAME STARTS, WHEREVER THE PROGRAM WOULD HOLD IT. A
      # program built with its pack left out names lists of colours it does not hold: it knows a
      # sprite is recoloured with bank 2 and not what bank 2 holds. Its lists are still compared
      # with each other, kept in pictures' pixels and handed from verb to verb as colours are, so
      # each such colour is a number where a colour would be. A colour is fifteen bits; a marker
      # has the sixteenth set, and its other bits name an entry of StartFile#colors, counting
      # from 1 (the sixteenth bit alone marks a see-through pixel, Assets::SEE_THROUGH_MARKER,
      # and all sixteen a see-through pixel of a tile). So two markers are equal exactly when
      # they name one colour of the file.
      #
      # Nothing draws a marker. The interpreter plays the program with each replaced by its
      # colour (.hold_marked_colors), and the builds for a computer fill an array of the entries
      # as they start and put each where a marker is (Computer::StartFileFills). Whatever does
      # arithmetic on a colour while the game is built must ask .marker? first: a marker masked
      # to fifteen bits is a wrong colour, in silence.
      MARKER = 0x8000
      MOST_MARKED_COLORS = 0x7FFE

      def self.marker_of(entry) = MARKER + 1 + entry
      def self.entry_of(marker) = marker - MARKER - 1
      def self.marker?(color) = color.is_a?(Integer) && color > MARKER && color <= MARKER + MOST_MARKED_COLORS

      # Each of the file's colours (StartFile#colors) as +bytes+, the file, has it: fifteen bits each.
      def colors_in(bytes)
        colors.each_with_object([]) do |source, held|
          held << case source
                  when Color then StartFile.color_in(bytes, source)
                  when WalkedColor then Graphics::Color.walked_toward(held.fetch(source.of), source.far, source.steps)
                  else raise ArgumentError, "#{source.inspect} is not a colour read from the file"
                  end
        end
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
        # First, so whatever is read below is made of colours and of no marker.
        hold_marked_colors(filled, file.colors_in(bytes.b)) unless file.colors.empty?
        read = filled.walk.select { |node| place_in_file(node) }
        read.each { |node| fill_node(filled, node, bytes.b) }
        VBlank.logger.debug("start file") do
          into = read.map { |node| node.kind == :screen ? "a screen's backdrop" : ":#{node.name}" }
          "read the #{file.called}, #{file.size} bytes, into #{into.join(', ')}"
        end
        filled
      end

      # EVERY MARKER +program+ HOLDS REPLACED BY ITS COLOUR, +colors+ being the file's colours by
      # entry (#colors_in): in each list of colours a picture, a sprite, a list the game changes, a
      # background, a run of painted tiles and a set of sprite tiles keeps, in a picture's pixels,
      # and in a screen's backdrop. Those are every place a list of colours the game declared
      # can reach, so the program is from here on the one a build holding its data makes.
      def self.hold_marked_colors(program, colors)
        held = ->(value) { colors_held(value, colors) }
        program.walk.each do |node|
          case node.kind
          when :bitmap
            node.colors = held.(node.colors) if node.colors
            node.pixels = held.(node.pixels.unpack("v*")).pack("v*")
          when :object then node.recolors = held.(node.recolors) if node.recolors
          when :color_list
            node.colors = held.(node.colors)
            node.recolors = held.(node.recolors) if node.recolors
          when :background
            node.palettes = held.(node.palettes) if node.palettes
            node.recolors = held.(node.recolors) if node.recolors
          when :tile_run, :sprite_tiles then node.colors = held.(node.colors) if node.colors
          when :screen then node.backdrop = held.(node.backdrop) if node.backdrop
          end
        end
      end

      # +value+ with each marker in it replaced by its colour of +colors+: a colour, a list of
      # them, or lists of lists. Anything else (a list's name, nil) is as it was.
      def self.colors_held(value, colors)
        return value.map { |inner| colors_held(inner, colors) } if value.is_a?(Array)

        marker?(value) ? colors.fetch(entry_of(value)) : value
      end

      # What +node+ (a table, a picture, a recording, a background or a screen) of +program+ reads
      # from the file.
      def self.fill_node(program, node, bytes)
        case node.kind
        when :table then fill_table(node, bytes)
        when :bitmap then node.from_file.is_a?(Pose) ? fill_pose(node, bytes) : fill_picture(node, bytes)
        when :sample then fill_recording(node, bytes)
        when :background then fill_background(program, node, bytes)
        when :screen then fill_backdrop(node, bytes)
        when :song then fill_song(node, bytes)
        else raise ArgumentError, "a #{node.kind} is not read from the file (READ_KINDS names the kinds that are)"
        end
      end

      # A song's parts that keep their notes in the file, each the part a Score makes of those
      # notes when the game is built holding them.
      def self.fill_song(node, bytes)
        node.voices = node.voices.map do |part|
          where = part.from_file
          where ? where.voice_playing(notes_in(bytes, where), node.total_frames) : part
        end
      end

      # A screen's backdrop, read from the place it names: the colour a `screen` keeps when the game
      # is built holding its data, so everything that plays the filled program finds a colour there.
      def self.fill_backdrop(node, bytes)
        node.backdrop = color_in(bytes, node.backdrop_from_file)
        node.backdrop_from_file = nil
      end

      # A recording's samples, read from the place it names: one byte each, as long as the zeros the
      # program holds for them.
      #
      # Then its settings, each read from the place it names and held as RecordingSettings says:
      # the numbers a `sample` keeps when the game is built holding its data.
      def self.fill_recording(node, bytes)
        if node.from_file
          node.bytes = bytes.byteslice(node.from_file, node.bytes.bytesize)
          node.from_file = nil
        end
        settings = node.settings_from_file or return

        node.rate = rate_held(number_in(bytes, settings.rate)) if settings.rate
        node.holds_from = hold_held(number_in(bytes, settings.holds_from), node.bytes.bytesize) if settings.holds_from
        node.envelope = envelope_in(bytes, settings.envelope) if settings.envelope
        node.settings_from_file = nil
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
        hold_read_picture(node, places, colors, see_through: where.see_through)
      end

      # +node+ as a picture of +places+ in +colors+, turned as its place in the file says, with
      # nothing left to read.
      def self.hold_read_picture(node, places, colors, see_through:)
        pixels, transparent = Assets.placed_pixels(places, colors, see_through: see_through)
        picture = Assets::Image.new(width: node.width, height: node.height, transparent: transparent, pixels: pixels,
                                    colors: colors, places: places.pack("C*"))
        picture = node.from_file.turns.reduce(picture) { |turned, way| turned.turned(way) }
        node.pixels = picture.pixels
        node.transparent = picture.transparent
        node.colors = colors
        node.places = picture.places
        node.from_file = nil
      end

      # A POSE'S PIECES, read from the frame it names and painted into a picture of the size the
      # game gave, as the build paints them when it holds the frame (Builder::PackPoses). The
      # picture stays one of that size and of no pieces, since the build laid it out so.
      def self.fill_pose(node, bytes)
        where = node.from_file
        colors = if where.colors_at
                   FormatReading.colors(bytes.byteslice(where.colors_at, where.colors_count * 2), where.color_format)
                 else
                   node.colors
                 end
        hold_read_picture(node, pose_places(where, node.width, node.height, bytes), colors, see_through: 0)
      end

      # The places of a picture +width+ by +height+ with the pieces of the frame at +where+ (a
      # Pose) painted into it, row by row. What the file asks for past what the build holds is
      # left out (Pose says what).
      def self.pose_places(where, width, height, bytes)
        layout = where.layout
        first = where.frame_at + layout.count_bytes_before_pieces
        count = where.count || layout.count_of(bytes.byteslice(where.frame_at, layout.count_bytes).bytes)
        count = [count, (where.frame_end - first) / layout.piece_bytes].min
        places = Array.new(width * height, 0)
        tiles = {}
        count.times do |at|
          piece = layout.piece_of(bytes.byteslice(first + (at * layout.piece_bytes), layout.piece_bytes).bytes)
          paint_pose_piece(places, width, height, piece, where, bytes, tiles)
        end
        places
      end

      # One piece painted into +places+, behind what is there already: each of its pixels from
      # the tile its layout names there, the whole piece turned as it says. +tiles+ keeps each
      # tile read, by its number.
      def self.paint_pose_piece(places, width, height, piece, where, bytes, tiles)
        side = FormatReading::TILE_SIDE
        across = piece.columns * side
        tall = piece.rows * side
        tile_bytes = where.tile_format.tile_bytes
        tall.times do |y|
          down = where.origin_y + piece.y + y
          next unless down.between?(0, height - 1)

          across.times do |x|
            along = where.origin_x + piece.x + x
            next unless along.between?(0, width - 1) && places[(down * width) + along].zero?

            from_x = piece.mirrored ? across - 1 - x : x
            from_y = piece.upside_down ? tall - 1 - y : y
            tile = where.layout.piece_tile(piece, from_x / side, from_y / side)
            next unless tile < where.tile_count

            tiles[tile] ||= FormatReading.tiles(bytes.byteslice(where.tiles_at + (tile * tile_bytes), tile_bytes), where.tile_format).first
            places[(down * width) + along] = tiles[tile][((from_y % side) * side) + (from_x % side)]
          end
        end
      end

      # A picture's places row by row: one byte a pixel, or the tiles they are kept in, read from the
      # file; or the places the picture holds itself.
      def self.picture_places(node, where, bytes)
        count = node.width * node.height
        return node.places.bytes unless where.places_at
        if where.places_by_byte
          row_bytes = where.row_bytes || node.width
          return Array.new(node.height) { |row| bytes.byteslice(where.places_at + (row * row_bytes), node.width).bytes }.flatten
        end

        tiles = bytes.byteslice(where.places_at, (count / FormatReading::TILE_PIXELS) * where.tile_format.tile_bytes)
        Assets.picture_places_of_tiles(FormatReading.tiles(tiles, where.tile_format).flatten, across: where.across)
      end

      # A BACKGROUND'S TILES AND MAP, read from the places it names, as the build makes them of the
      # same numbers held in the game (Builder::PackBackgrounds): each different tile as drawn (a
      # tile, its bank and its turn) a picture of +program+, drawn from its bank's list, and the
      # map those pictures, a cell whose tile draws nothing left empty. Its lists of colours held
      # markers for a bank's colours, and hold the colours by now (.hold_marked_colors).
      def self.fill_background(program, node, bytes)
        from = node.from_file
        banks = bank_lists(from, bytes)
        cells = from.map_words
        words = FormatReading.numbers(bytes.byteslice(from.map_at, from.cells * cells.cell_bytes), from.number_format,
                                      width: cells.cell_width, signed: false)
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
        # The tiles the program held come first and keep their numbers, since a `set_tile` of the
        # program names one by its number: a stand-in for each bank, which nothing draws, and
        # the tiles of the cells the background was told it may be written, each a picture read
        # from the file itself (.fill_picture).
        held = node.tiles
        node.tiles = [*held, *pictures.values.compact]
        numbers = pictures.values.compact.each_with_index.to_h { |picture, at| [picture, held.length + at] }
        node.map = drawn.map { |row| row.map { |picture| picture && numbers.fetch(picture) } }
        node.from_file = nil
      end

      # Each bank's colours as a list of colours keeps them, see-through first.
      def self.bank_lists(from, bytes)
        Array.new(from.bank_count) do |bank|
          kept = bytes.byteslice(from.colors_at + (bank * from.bank_size * 2), from.bank_size * 2)
          [0, *FormatReading.colors(kept, from.color_format).drop(1)]
        end
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
      private_class_method :fill_node, :fill_recording, :fill_song, :fill_table, :fill_picture, :picture_places, :fill_background, :fill_backdrop,
                           :bank_lists, :colors_held, :hold_marked_colors, :declare_background_tile, :hold_read_picture, :fill_pose, :pose_places,
                           :paint_pose_piece
    end
  end
end
