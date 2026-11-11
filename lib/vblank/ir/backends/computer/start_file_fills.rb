# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # THE FILE A PROGRAM IS HANDED AS IT STARTS (IR::StartFile), written as C: a game built
        # with its data pack left out, or its unpacking, which reads the player's copy. Mixed into
        # Lowering.
        #
        # The program's first statement asks the runtime to check the file it was handed
        # (rg_start_file_open, handed StartFile#rules: the numbers to check and the sentences to stop
        # with when there is no file or it is another), and then calls a routine of the game's own that fills every array
        # read from it: each table, written as its size alone (Statements::StartFileArray), from where its
        # first entry is; and each picture read from it, into the runtime's pixels: a background's
        # tile into the tile pixels, and the picture a sprite, a blit or a face draws, in the colours
        # it is drawn in, into the image pixels (a pose that is a frame of the original's is such a
        # picture, its pieces painted in, #start_file_pose_rules); and each background whose map is read from it, a
        # tile for every cell; and each colour that is no part of a picture, a screen's backdrop,
        # into an array of the game's own; and each number worked out from a recording's rate, the
        # sample it holds from or its envelope, where the file has those
        # (Sound#build_start_file_sound_fills), and the notes of each part of a song that keeps them
        # there, made into the room the music table holds for them
        # (Sound#build_start_file_note_fills). That routine is written last, once the art is laid out
        # and it is known where in the pixels each picture is.
        #
        # So the game as C, JavaScript or Ruby holds none of the original's bytes, and a game that
        # reads no file is written as it was before there was one. The art here lays out a picture
        # read from the file as zeros of its size and leaves the pixels to the routine: the colours
        # and places are the file's, a list of colours the picture is drawn in instead is the
        # game's (known), and a turned picture is read turned.
        module StartFileFills
          private

          def reads_start_file? = !@program.start_file.nil?

          # The statements a program that reads a file starts with: the check and the fills.
          def build_start_file_reads
            return [] unless reads_start_file?

            rules = @program.start_file.rules
            [eval_call("rg_start_file_open", drawing_array("start_file_rules", "int32_t", rules.numbers),
                       Statements::Text.new(rules.words.missing), Statements::Text.new(rules.words.wrong_size), Statements::Text.new(rules.words.wrong_check)),
             eval_call(start_file_routine.text)]
          end

          def start_file_routine = @names.own("read_start_file")

          # The routine's prototype, which goes above the game's routines, and the routine, which
          # goes after the art. Nothing for a program that reads no file.
          def build_start_file_prototypes = reads_start_file? ? [Statements::Prototype.new(name: start_file_routine)] : []

          def build_start_file_routines
            return [] unless reads_start_file?

            # The colours first: the pixels filled after them are put in those colours last.
            [Statements::Function.new(name: start_file_routine,
                                      body: build_start_file_color_fills + build_start_file_table_fills +
                                            build_start_file_picture_fills + build_start_file_background_fills +
                                            build_start_file_marked_pixel_fills + build_start_file_recording_fills +
                                            build_start_file_sound_fills)]
          end

          # COLOURS READ FROM THE FILE THAT ARE NO PART OF A PICTURE READ FROM IT: a screen's
          # backdrop (IR::StartFile::Color), and every colour of a list of colours the game
          # declared from the pack, with the colours each walk of one is made of
          # (IR::StartFile#colors). The game keeps one array of them, written as its size alone,
          # and the routine fills each entry from the file, or makes it from an entry before it
          # (a WalkedColor). A statement that takes a colour then reads its entry
          # (#start_file_color) where a game holding its data writes a number. An array and not a
          # read at each statement, so a colour is read from the file once however often a scene
          # arrives.
          #
          # A LIST'S COLOURS ARE IN THE PROGRAM AS MARKERS (IR::StartFile, "MARKERS"), each naming
          # its entry of this array: the program's colours are the first entries, in its order,
          # so a marker's entry is the array's. The art is worked out here as it is for any game,
          # so a pixel drawn in such a colour is written as its marker, and the routine's last
          # work on the pictures is to put the entry's colour where each marker is
          # (#build_start_file_marked_pixel_fills).
          #
          # Every colour the program names, each once: the program's own, then the backdrops.
          def start_file_colors
            @start_file_colors ||= [*@program.start_file&.colors,
                                    *@program.walk.filter_map { |node| node.backdrop_from_file if node.kind == :screen }].uniq
          end

          def start_file_colors_name = @names.own("start_file_colors")

          # The array's declaration, which goes with the tables; nothing for a program with no such colour.
          def start_file_color_arrays
            return [] if start_file_colors.empty?

            [Statements::StartFileArray.new(name: start_file_colors_name, type: "int32_t", count: start_file_colors.length)]
          end

          # The colour +where+ (an IR::StartFile::Color) as a statement reads it: its entry of the array.
          def start_file_color(where)
            Statements::Index.new(start_file_colors_name, Statements::Int.new(start_file_colors.index(where)))
          end

          # A colour as a statement or a table holds it: a marker's entry of the array, and any
          # other colour as the number it is.
          def color_or_start_file_entry(color)
            return Statements::Int.new(color) unless IR::StartFile.marker?(color)

            Statements::Index.new(start_file_colors_name, Statements::Int.new(IR::StartFile.entry_of(color)))
          end

          # One call for each run of entries: colours one after another in the file, kept one
          # way, or colours made from entries before them. The entries are filled in their order,
          # since a colour is made from one before it.
          def build_start_file_color_fills
            formats = {}
            runs = start_file_colors.each_with_index.chunk_while do |(before, _), (after, _)|
              next after.is_a?(IR::StartFile::WalkedColor) if before.is_a?(IR::StartFile::WalkedColor)

              after.is_a?(IR::StartFile::Color) && after.format == before.format && after.at == before.at + START_FILE_COLOR_BYTES
            end
            runs.map do |run|
              where, first = run.first
              if where.is_a?(IR::StartFile::WalkedColor)
                made = drawing_array("start_file_walked_colors", "int32_t", run.flat_map { |walked, _| [walked.of, walked.far, walked.steps] })
                next eval_call("rg_start_file_walk_colors", start_file_colors_name, Statements::Int.new(first), Statements::Int.new(run.length), made)
              end

              format = formats[where.format] ||= drawing_array("start_file_color_format", "int32_t", color_format_rules(where.format))
              eval_call("rg_start_file_fill_colors", start_file_colors_name, Statements::Int.new(first), Statements::Int.new(run.length),
                        Statements::Int.new(where.at), format)
            end
          end

          # How many bytes of the file a colour is.
          START_FILE_COLOR_BYTES = 2

          # PIXELS WRITTEN AS MARKERS, put in their colours as the game starts: +count+ pixels from
          # +start+ in the +kind+ of pixels (:tile or :image).
          MarkedPixels = Data.define(:kind, :start, :count)

          # Does this program hold markers at all? Only then is any pixel looked at for one.
          def marks_colors? = !(@program.start_file.nil? || @program.start_file.colors.empty?)

          # +colors+, the pixels about to be written at +start+ in the +kind+ of pixels, noted if
          # any is a marker.
          def record_marked_pixels(kind, start, colors)
            return unless marks_colors? && colors.any? { |color| IR::StartFile.marker?(color) }

            @start_file_marked_pixels << MarkedPixels.new(kind: kind, start: start, count: colors.length)
          end

          # One call for each run of pixels that holds a marker, runs side by side as one. It
          # comes after every picture read from the file is filled, since one drawn in a list of
          # markers is filled with them.
          def build_start_file_marked_pixel_fills
            @start_file_marked_pixels.group_by(&:kind).flat_map do |kind, noted|
              total = kind == :tile ? @tile_pixel_count : @image_pixel_count
              joined = noted.sort_by(&:start).each_with_object([]) do |pixels, runs|
                last = runs.last
                next runs << pixels unless last && last.start + last.count >= pixels.start

                runs[-1] = last.with(count: [last.count, pixels.start + pixels.count - last.start].max)
              end
              joined.map do |pixels|
                eval_call("rg_start_file_fill_marked_pixels", start_file_colors_name, Statements::Int.new(FILL_KINDS.fetch(kind)),
                          Statements::Int.new(total), Statements::Int.new(pixels.start), Statements::Int.new(pixels.count))
              end
            end
          end

          # A picture's pixels as sixteen signed bits keep them: a marker, whose sixteenth bit is
          # set, is the number below zero of the same bits.
          def image_pixel_kept(pixel) = IR::StartFile.marker?(pixel) ? pixel - 0x1_0000 : pixel

          # WHAT THE GAME PAINTS FROM A LIST AS IT RUNS IS NOT PUT IN COLOURS READ AS THE GAME STARTS
          # YET: the colour of each place of a painted picture is kept where the routine reading the
          # file does not write. +colors+ are those colours, handed back where none is a marker.
          def refuse_painted_in_marked_colors!(colors, name)
            return colors unless marks_colors? && colors.any? { |color| IR::StartFile.marker?(color) }

            raise LoweringError, "#{name.inspect} is painted from a list as the game runs, and it is drawn with colors " \
                                 "that are read from the #{@program.start_file.called} as the game starts. #{build_name} " \
                                 "does not make that yet. To fix this, draw it with a list of colors that the game " \
                                 "writes, or build the game all-in-one."
          end

          # A BACKGROUND WHOSE MAP, TILES AND COLOURS ARE READ FROM THE FILE (IR::StartFile::Background).
          # Which tiles its map names is known only once the file is read, so the art lays out a
          # tile of its own for every cell, see-through until the routine fills it, and a map that
          # names them in order. The tiles are written again for each step of other colours the
          # background can be told, as any background's are.
          #
          # +start+ is where its tiles' pixels start in the tile pixels, +from+ where it is in the
          # file, and +lists+ the colours of each bank at each step, the step it is drawn in its own
          # colours first: a BankFromFile for a bank drawn as the file has it, or the colours of
          # the list it is drawn with. Those are the game's, or markers where the list is read
          # from the file too (another bank, a walk of one), which the tiles are then filled with
          # and put in their colours with every other marker (#record_marked_pixels).
          StartFileBackgroundFill = Data.define(:start, :from, :lists)
          BankFromFile = Data.define(:bank)

          def record_start_file_background_fill(start, bg, steps)
            from = bg.from_file
            lists = [nil, *steps].map do |swaps|
              Array.new(from.bank_count) do |bank|
                # The list of a bank is found by its name: its colours here are markers.
                _, drawn_with = swaps&.find { |(name, _), _| name == from.bank_names[bank] }
                drawn_with || BankFromFile.new(bank: bank)
              end
            end
            @start_file_background_fills << StartFileBackgroundFill.new(start: start, from: from, lists: lists)
            return unless lists.flatten.any? { |color| IR::StartFile.marker?(color) }

            @start_file_marked_pixels << MarkedPixels.new(kind: :tile, start: start,
                                                          count: from.tiles_drawn * Picture::RUN_TILE_PIXELS * lists.length)
          end

          def build_start_file_background_fills
            @start_file_background_fills.map do |fill|
              eval_call("rg_start_file_fill_background",
                        drawing_array("start_file_background", "int32_t", start_file_background_rules(fill)))
            end
          end

          # The numbers rg_start_file_fill_background reads (rg_runtime.h has what each is).
          def start_file_background_rules(fill)
            from = fill.from
            words = from.map_words
            header = [@tile_pixel_count, fill.start, from.map_at, from.cells, from.across, from.cell_tiles,
                      from.number_format.high_byte_first ? 1 : 0, words.tile_bits, words.mirror_bit, words.flip_bit,
                      words.bank_at, words.bank_bits, words.row_tiles || 0, from.tiles_at, from.tile_count,
                      from.colors_at, from.bank_count, from.bank_size, fill.lists.length]
            unless header.length == StartFileNumbers::BACKGROUND_HEADER_NUMBERS
              raise ArgumentError, "A background fill's rules header has #{header.length} numbers, and StartFileNumbers::" \
                                   "BACKGROUND_HEADER_NUMBERS says #{StartFileNumbers::BACKGROUND_HEADER_NUMBERS}. Change both together."
            end

            [*header, *tile_format_rules(from.tile_format), *color_format_rules(from.color_format),
             *fill.lists.flat_map { |banks| banks.flat_map { |list| bank_list_rules(list, from.bank_size) } }]
          end

          # One bank's colours at one step, as rg_start_file_fill_background reads them: the bank of
          # the file they are, or -1 and then the colours the game holds, a colour for each place.
          def bank_list_rules(list, bank_size)
            return [list.bank, *Array.new(bank_size, 0)] if list.is_a?(BankFromFile)

            [-1, *Array.new(bank_size) { |place| list[place] || 0 }]
          end

          # Each table the game reads that is read from the file: as many entries as it holds, kept
          # the way the table is kept (TABLE_KEPT_AS), from where its first entry is.
          def build_start_file_table_fills
            tables_read.select(&:from_file).map do |table|
              eval_call("rg_start_file_fill_table", @names.of(:table, table.name),
                        Statements::Int.new(Lowering::TABLE_KEPT_AS.fetch(table_type(table))),
                        Statements::Int.new(table.entry_count), Statements::Int.new(table.from_file), Statements::Int.new(table.file_number_format.high_byte_first ? 1 : 0))
            end
          end

          # What the routine reading the start file writes into the pixels of one picture: the pixels
          # start at +start+ in the +kind+ of pixels (:tile or :image), the picture is +from+ the
          # file (IR::StartFile::Picture) of +width+ by +height+, +colors+ and +places+ are the lists
          # the game holds (the file has none of them), and +swapped+ the list of colours it is drawn
          # in instead, or nil.
          StartFileFill = Data.define(:kind, :start, :width, :height, :from, :colors, :places, :swapped)

          # rg_runtime.h's numbers for what is filled and how it is turned.
          FILL_KINDS = Ractor.make_shareable({ tile: 0, image: 1 })
          TURN_BITS = Ractor.make_shareable({ mirrored: 1, upside_down: 2 })

          # A picture that is read from the file at +start+ in the tile pixels or the image pixels,
          # drawn in the colours of +swapped+ where it is not drawn in its own: filled when the routine
          # runs. The runtime is told how many pixels there are in all, since the C keeps them where
          # they cannot be written and fills a copy of them (rg_screen_tile_pixels_to_fill,
          # rg_screen_image_pixels_to_fill).
          def record_start_file_fill(kind, start, node, swapped)
            @start_file_fills << StartFileFill.new(kind: kind, start: start, width: node.width, height: node.height,
                                                   from: node.from_file, colors: node.colors, places: node.places.bytes,
                                                   swapped: swapped)
            # Filled in a list of markers, its pixels hold them until they are put in their colours.
            return unless marks_colors? && [*node.colors, *swapped].any? { |color| IR::StartFile.marker?(color) }

            @start_file_marked_pixels << MarkedPixels.new(kind: kind, start: start, count: node.width * node.height)
          end

          def build_start_file_picture_fills
            @start_file_fills.map do |fill|
              total = fill.kind == :tile ? @tile_pixel_count : @image_pixel_count
              if fill.from.is_a?(IR::StartFile::Pose)
                next eval_call("rg_start_file_fill_pose", drawing_array("start_file_pose", "int32_t", start_file_pose_rules(fill, total)))
              end

              eval_call("rg_start_file_fill_picture", drawing_array("start_file_fill", "int32_t", start_file_fill_rules(fill, total)))
            end
          end

          # A POSE WHOSE PIECES ARE READ FROM THE FILE (IR::StartFile::Pose) is a picture like any
          # other read from it: zeros of the size the game gave, laid out wherever the picture is
          # drawn and in each list of colours it is drawn with, and filled by the routine. Only
          # what fills it differs, since its places are not tiles side by side but the pieces of
          # a frame, painted where each says.
          #
          # The numbers rg_start_file_fill_pose reads (rg_runtime.h has what each is).
          def start_file_pose_rules(fill, total)
            where = fill.from
            turn = TURN_BITS.sum { |way, bit| where.turns.count(way).odd? ? bit : 0 }
            swapped = fill.swapped || []
            header = [FILL_KINDS.fetch(fill.kind), total, fill.start, fill.width, fill.height, turn,
                      where.colors_at || -1, where.colors_count, swapped.length, where.frame_at, where.frame_end,
                      where.count || -1, where.origin_x, where.origin_y, where.tiles_at, where.tile_count]
            unless header.length == StartFileNumbers::POSE_HEADER_NUMBERS
              raise ArgumentError, "A pose fill's rules header has #{header.length} numbers, and StartFileNumbers::" \
                                   "POSE_HEADER_NUMBERS says #{StartFileNumbers::POSE_HEADER_NUMBERS}. Change both together."
            end

            [*header, *frame_layout_rules(where.layout), *tile_format_rules(where.tile_format),
             *color_format_rules(where.color_format), *(fill.colors unless where.colors_at), *swapped]
          end

          # The numbers of a frame's layout (Original::FrameLayout), in the order StartFileNumbers
          # names: -1 for a part the layout does not have, and 0 tile bits where the whole number
          # is the tile.
          def frame_layout_rules(layout)
            rules = [layout.piece_bytes, layout.count_bytes, layout.high_byte_first ? 1 : 0, layout.x_at, layout.y_at,
                     layout.position_bytes, layout.tile_at, layout.tile_bytes, layout.tile_bits || 0, layout.tile_row_at || -1,
                     layout.row_tiles, layout.flags_at, layout.flags_bytes, layout.mirrored_bit || -1,
                     layout.upside_down_bit || -1, layout.big_bit || -1, layout.size_at || -1, layout.columns_bit || 0,
                     layout.rows_bit || 0, layout.size_bits, StartFileNumbers::FRAME_TILE_ORDERS.fetch(layout.tile_order)]
            return rules if rules.length == StartFileNumbers::FRAME_LAYOUT_NUMBERS

            raise ArgumentError, "A frame layout's rules have #{rules.length} numbers, and StartFileNumbers::" \
                                 "FRAME_LAYOUT_NUMBERS says #{StartFileNumbers::FRAME_LAYOUT_NUMBERS}. Change both together."
          end

          # The numbers rg_start_file_fill_picture reads (rg_runtime.h has what each is).
          def start_file_fill_rules(fill, total)
            where = fill.from
            turn = TURN_BITS.sum { |way, bit| where.turns.count(way).odd? ? bit : 0 }
            swapped = fill.swapped || []
            header = [FILL_KINDS.fetch(fill.kind), total, fill.start, fill.width, fill.height, turn, where.across,
                      where.places_at || -1, where.colors_at || -1, where.colors_count, swapped.length,
                      where.places_by_byte ? 1 : 0, where.see_through || -1, where.row_bytes || fill.width]
            refuse_header_size_mismatch!(header)
            [*header, *tile_format_rules(where.tile_format), *color_format_rules(where.color_format),
             *(fill.places unless where.places_at), *(fill.colors unless where.colors_at), *swapped]
          end

          # The runtimes read the header by position and step past it by the count StartFileNumbers
          # writes into them, so a header that grew without the count would read every rule after
          # it from the wrong place.
          def refuse_header_size_mismatch!(header)
            return if header.length == StartFileNumbers::RULES_HEADER_NUMBERS

            raise ArgumentError, "A fill's rules header has #{header.length} numbers, and StartFileNumbers::" \
                                 "RULES_HEADER_NUMBERS says #{StartFileNumbers::RULES_HEADER_NUMBERS}. Change both together."
          end

          # The numbers of a layout of tiles (Console::TileFormat), as start_file_place reads them,
          # in the order StartFileNumbers names: a tile's bytes, its planes, where each plane's
          # first bit is (MOST_PLANES of them), the bits from one row to the next, and where each
          # column's bit is. Zeros for places the game holds itself.
          def tile_format_rules(format)
            return Array.new(StartFileNumbers::TILE_FORMAT_NUMBERS, 0) unless format

            unused_planes = StartFileNumbers::MOST_PLANES - format.plane_bits.length
            [format.tile_bytes, format.plane_bits.length, *format.plane_bits, *Array.new(unused_planes, 0),
             format.row_bits, *format.column_bits]
          end

          # The numbers of a layout of colours (Console::ColorFormat), as start_file_color reads
          # them: 1 for the high byte first, where red, green and blue are, and how many bits each
          # is. Zeros for colours the game holds itself.
          def color_format_rules(format)
            return Array.new(StartFileNumbers::COLOR_FORMAT_NUMBERS, 0) unless format

            [format.high_byte_first ? 1 : 0, format.red_at, format.green_at, format.blue_at, format.channel_bits]
          end

          # A picture read from the file the program is handed, by its name, or nil.
          def picture_from_start_file(name)
            node = @data[name]
            node if node&.kind == :bitmap && node.from_file
          end

          # The data a program reads a byte at a time is its bytes as they are built, which a picture
          # read from the file does not have: a plain error naming the picture.
          def refuse_picture_from_start_file!(name, as)
            return unless picture_from_start_file(name)

            raise LoweringError, "picture #{name.inspect} is read from the #{@program.start_file.called} as the game starts, " \
                                 "and #{build_name} cannot draw it as #{as}. Build the game all-in-one."
          end
        end
      end
    end
  end
end
