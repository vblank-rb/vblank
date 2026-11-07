# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # THE FILE A PROGRAM IS HANDED AS IT STARTS (IR::StartFile), written as C: a game built
        # with its data pack left out, or its unpacking, which reads the player's copy. Mixed into
        # Lowering.
        #
        # The program's first statement asks the runtime to check the file it was handed
        # (rg_start_file_open, handed StartFile#rules: the numbers to check and the sentences to stop
        # with when there is no file or it is another), and then calls a routine of the game's own that fills every array
        # read from it: each table, written as its size alone (C::StartFileArray), from where its
        # first entry is; and each picture read from it, into the runtime's pixels: a background's
        # tile into the tile pixels, and the picture a sprite, a blit or a face draws, in the colours
        # it is drawn in, into the image pixels. That routine is written last, once the art is laid
        # out and it is known where in the pixels each picture is.
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
                       C::Text.new(rules.words.missing), C::Text.new(rules.words.wrong_size), C::Text.new(rules.words.wrong_check)),
             eval_call(start_file_routine.text)]
          end

          def start_file_routine = @names.own("read_start_file")

          # The routine's prototype, which goes above the game's routines, and the routine, which
          # goes after the art. Nothing for a program that reads no file.
          def build_start_file_prototypes = reads_start_file? ? [C::Prototype.new(name: start_file_routine)] : []

          def build_start_file_routines
            return [] unless reads_start_file?

            [C::Function.new(name: start_file_routine, body: build_start_file_table_fills + build_start_file_picture_fills)]
          end

          # Each table the game reads that is read from the file: as many entries as it holds, kept
          # the way the table is kept (TABLE_KEPT_AS), from where its first entry is.
          def build_start_file_table_fills
            tables_read.select(&:from_file).map do |table|
              eval_call("rg_start_file_fill_table", @names.of(:table, table.name),
                        C::Int.new(Lowering::TABLE_KEPT_AS.fetch(table_type(table))),
                        C::Int.new(table.entry_count), C::Int.new(table.from_file))
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
          end

          def build_start_file_picture_fills
            @start_file_fills.map do |fill|
              total = fill.kind == :tile ? @tile_pixel_count : @image_pixel_count
              eval_call("rg_start_file_fill_picture", drawing_array("start_file_fill", "int32_t", start_file_fill_rules(fill, total)))
            end
          end

          # The numbers rg_start_file_fill_picture reads (rg_runtime.h has what each is).
          def start_file_fill_rules(fill, total)
            where = fill.from
            turn = TURN_BITS.sum { |way, bit| where.turns.count(way).odd? ? bit : 0 }
            swapped = fill.swapped || []
            [FILL_KINDS.fetch(fill.kind), total, fill.start, fill.width, fill.height, turn, where.across,
             where.places_at || -1, where.colors_at || -1, where.colors_count, swapped.length,
             *(fill.places unless where.places_at), *(fill.colors unless where.colors_at), *swapped]
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
