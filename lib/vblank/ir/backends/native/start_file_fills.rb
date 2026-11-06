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
        # (rg_start_file_open, which stops in plain words when there is none or it is another, as
        # StartFile#refusal says), and then calls a routine of the game's own that fills every array
        # read from it: each table, written as its size alone (C::StartFileArray), from where its
        # first entry is; and each tile of a background that is a picture read from it, into the
        # runtime's tile pixels. That routine is written last, once the art is laid out and it is
        # known where in the tile pixels each tile is.
        #
        # So the game as C, JavaScript or Ruby holds none of the original's bytes, and a game that
        # reads no file is written as it was before there was one. A picture read from the file can
        # only be a background's tile so far: as a sprite or a blit, a recoloured tile or a face's
        # picture, the art here works it out from its pixels, which are not known, so such a game
        # is refused naming the picture (#refuse_picture_from_start_file!).
        module StartFileFills
          private

          def reads_start_file? = !@program.start_file.nil?

          # The statements a program that reads a file starts with: the check and the fills.
          def build_start_file_reads
            return [] unless reads_start_file?

            file = @program.start_file
            rules = [file.size, file.checks.length, *file.checks.flat_map { |check| [check.at, check.bytes.bytesize, *check.bytes.bytes] }]
            [eval_call("rg_start_file_open", C::Text.new(file.called), drawing_array("start_file_rules", "int32_t", rules)),
             eval_call(start_file_routine.text)]
          end

          def start_file_routine = @names.own("read_start_file")

          # The routine's prototype, which goes above the game's routines, and the routine, which
          # goes after the art. Nothing for a program that reads no file.
          def build_start_file_prototypes = reads_start_file? ? [C::Prototype.new(name: start_file_routine)] : []

          def build_start_file_routines
            return [] unless reads_start_file?

            [C::Function.new(name: start_file_routine, body: build_start_file_table_fills + build_start_file_tile_fills)]
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

          # A background's tile that is a picture read from the file, at +start+ in the tile pixels:
          # its colours and places, made into the tile's colours as Picture#colors_as_tile makes them
          # (see-through where its place is 0), when the routine runs. The runtime is told how many
          # tile pixels there are, since the C keeps them where they cannot be written and fills a
          # copy of them (rg_screen_tile_pixels_to_fill).
          def record_start_file_tile_fill(start, picture)
            where = picture.from_file
            @start_file_tile_fills << [start, picture.width * picture.height, where]
          end

          def build_start_file_tile_fills
            @start_file_tile_fills.map do |start, count, where|
              eval_call("rg_start_file_fill_tile", C::Int.new(@tile_pixel_count), C::Int.new(start), C::Int.new(count),
                        C::Int.new(where.colors_at), C::Int.new(where.colors_count), C::Int.new(where.places_at))
            end
          end

          # A picture read from the file the program is handed, by its name, or nil.
          def picture_from_start_file(name)
            node = @data[name]
            node if node&.kind == :bitmap && node.from_file
          end

          # Where the art would be worked out from the pixels of a picture that is read from the
          # file, which are not known when the game is built: a plain error naming the picture.
          def refuse_picture_from_start_file!(name, as)
            return unless picture_from_start_file(name)

            raise LoweringError, "picture #{name.inspect} is read from the #{@program.start_file.called} as the game starts, " \
                                 "and #{build_name} can draw such a picture only as a background's tile, not as #{as}. " \
                                 "Build the game all-in-one, or draw the picture as a tile."
          end
        end
      end
    end
  end
end
