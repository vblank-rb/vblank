# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        class Lowering
          # TILES THE GAME PAINTS FROM A LIST (`tiles :box, from: list, count: n`), lowered for a Game
          # Boy Color. Mixed into Lowering.
          #
          # The list holds each tile as the Advance's picture memory does: 32 bytes, two pixels a
          # byte, the left one in the low four bits. The Color keeps a tile in 16 bytes, two to a
          # row, the low bit of every pixel of the row in the first and the high bit in the second.
          # So a copy is a repacking, done by the processor (Runtime::Picture's rt_repack_tiles) into
          # a stretch of work memory kept for the run, while the screen is being drawn; and the
          # console's own copying puts that into picture memory in the next blank, which is the gap
          # between frames the interpreter copies in (Reference#exec_copy_owed_tiles). Each painted
          # tile has a tile of its own in picture memory (GBC::Art#run_tile), and so does every piece
          # of a sprite's picture painted from a list (GBC::Art#painted_sprite_picture), whose list
          # keeps its tiles in the order a sprite's pieces are kept.
          #
          # A GROUP OF `tile_pictures` needs none of that. Its pictures are all known when the
          # cartridge is built, so its table is written in the Color's own form, and its list is never
          # made here: where a list stood, two bytes say which picture. The console's copy takes the
          # picture straight from the cartridge in the blank, with its bank put in view, so a show
          # costs a pass a few instructions and no stretch of work memory at all. Everything above
          # the lowering still sees the list and the Advance's form, so the interpreter and the
          # computer builds play a group as any other painted run.
          module TileRuns
            STATEMENTS = Ractor.make_shareable({ copy_tiles: :emit_copy_tiles, copy_owed_tiles: :emit_copy_owed_tiles })

            # Where a run's repacked tiles wait for the blank, and its flag saying they are waiting,
            # with where in picture memory each of its tiles goes — its bank and its address — for the
            # runtime's copy (Runtime::Picture). In a game with a group of `tile_pictures`,
            # +source_now+ is where that copy keeps what a run's places are counted from; nil in any
            # other.
            RunUpload = Data.define(:owed, :staging, :tiles, :source_now)

            # Bytes a tile takes in the Color's picture memory.
            TILE_BYTES = 16

            # Bytes of the cartridge a bank holds.
            BANK_BYTES = 0x4000

            # Every painted run's copy, for the runtime, once #keep_tile_runs has placed them.
            def run_uploads
              (@run_places || {}).filter_map do |name, (owed, staging)|
                RunUpload.new(owed: owed, staging: staging, tiles: run_tile_places(tile_runs.fetch(name)), source_now: @source_now)
              end
            end

            private

            def tile_runs = @tile_runs ||= by_name(@program.walk, :tile_run)

            # The group of `tile_pictures` the list +name+ stands for, or nil.
            def held_run_on_list(name) = tile_runs.each_value.find { |run| run.held_in && run.list == name }

            # Whether +run+'s list is see-through first and four colours after, which only a group
            # whose pictures are turned at build time can be: each place moves one down, so the
            # four fill the palette (GBC::Art#run_tile).
            def solid_run?(run) = !run.held_in.nil? && run.colors.length == Art::PLACES + 1

            def painted_tile(name, run, room = nil)
              @art.run_tile(name, run.colors, solid: solid_run?(run), swaps: painted_tile_swaps(name), room: room)
            end

            # What painted tile +name+'s palette shows with the lists its background is drawn with.
            def painted_tile_swaps(name)
              bg = tiled_scenery.find { |each| each.tiles.include?(name) }
              bg && recolor_steps_of(name, bg)
            end

            # A table of tiles the console's copy reads straight from the cartridge: a group's
            # pictures, or the tiles a set of sprite tiles loads (Lowering::SpriteTiles).
            def held_picture_table?(table)
              tile_runs.each_value.any? { |run| run.held_in == table.name } || sprite_tiles_table?(table)
            end

            # A group's pictures in a bank, all of them in one piece, since one show copies across it,
            # and starting on a multiple of 16, which is the only place the console's copy reads
            # from. Nothing reads them but that copy, so they ask nothing of the part always in view.
            def held_pictures_section(table)
              bytes = held_pictures_as_tiles(table)
              if bytes.length > BANK_BYTES
                if sprite_tiles_table?(table)
                  raise LoweringError, "A picture that sprite tiles are loaded from holds #{bytes.length} bytes of " \
                                       "tiles, and one bank of a Game Boy Color cartridge holds #{BANK_BYTES}. To fix " \
                                       "this, load from smaller pictures."
                end
                raise LoweringError, "A group of `tile_pictures` holds #{bytes.length} bytes of pictures, and one bank of " \
                                     "a Game Boy Color cartridge holds #{BANK_BYTES}. To fix this, use fewer pictures, or " \
                                     "put the tiles in two groups."
              end

              asm = SM83.new(table_label(table.name), home: :aligned16, holds: DATA)
              asm.label(table_label(table.name))
              asm.data_bytes(bytes)
              asm.section
            end

            # +table+'s bytes in the Color's own form, if it holds a group's pictures, or nil. The
            # table is written as painted tiles are: 4 bytes a row, two places a byte, the left one in
            # the low four bits. The Color's row is two bytes: the low bit of each place, then the
            # high bit, the leftmost place in the top bit.
            def held_pictures_as_tiles(table)
              run = tile_runs.each_value.find { |each| each.held_in == table.name }
              return unless run || sprite_tiles_table?(table)

              table.values.each_slice(4).flat_map do |row|
                places = row.flat_map { |byte| [byte & 0xF, (byte >> 4) & 0xF] }.map { |place| run ? color_place(place, run) : place }
                (0...2).map { |plane| places.reduce(0) { |byte, place| (byte << 1) | place[plane] } }
              end
            end

            def color_place(place, run)
              return place unless solid_run?(run)
              return place - 1 if place.positive?

              raise LoweringError, "tile_pictures :#{run.name} has a list of #{run.colors.length} colours, and one of its " \
                                   "pictures draws see-through. A Game Boy Color tile holds #{Art::PLACES} colours with " \
                                   "no see-through, or #{Art::OWN_COLORS} and the backdrop. To fix this, draw every " \
                                   "picture from the #{Art::PLACES} colours, or give `colors:` #{Art::PLACES} colours."
            end

            # The run a painted tile is one of, or nil for a tile drawn when the game was built.
            def run_painting(name) = tile_runs.each_value.find { |run| run.tiles.include?(name) }

            # The run a sprite's picture is painted from, or nil for one drawn when the game was built.
            def picture_painting(name) = tile_runs.each_value.find { |run| run.picture == name }

            # The colours a painted picture shows, by place: its run's, or +colors+ in their place
            # where it is drawn with another list (Assets::Recolor's rule, by place).
            def painted_colors(run, colors)
              return run.colors unless colors

              Array.new([[run.colors.length, colors.length].max, Art::PLACES].min) { |place| colors[place] || run.colors.fetch(place, 0) }
            end

            # Where each of a run's tiles goes in picture memory, as [bank, address]: a background
            # tile's 256 to a bank, the first 128 from 0x9000 and the rest from 0x8800; a sprite's
            # pieces 128 to a bank from 0x8000. The list keeps a sprite's tiles 8×8, left to right and
            # then down; where the console draws its pieces 8×16, a tile in an odd row of them is the
            # lower half of the piece over it.
            def run_tile_places(run)
              if run.picture
                pieces = @art.painted_sprite_picture(run.picture, run.width, run.height).pieces
                columns = run.width / 8
                Array.new(run_tile_count(run)) do |i|
                  x = (i % columns) * 8
                  y = (i / columns) * 8
                  piece = pieces.find { |each| each.dx == x && y.between?(each.dy, each.dy + @art.piece_height - 8) }
                  tile = piece.tile + ((y - piece.dy) / 8)
                  [tile / 128, 0x8000 + ((tile % 128) * TILE_BYTES)]
                end
              else
                run.tiles.map do |tile|
                  number = @art.run_tile_number(tile)
                  m = number % 256
                  [number / 256, (m < 128 ? 0x9000 : 0x8000) + (m * TILE_BYTES)]
                end
              end
            end

            # How many tiles a run's list holds.
            def run_tile_count(run) = run.picture ? (run.width / 8) * (run.height / 8) : run.tiles.length

            # The tile number and palette number background +bg+'s tile +name+ is drawn with, as +room+
            # numbers it (GBC::Art#background_tile; nil for the tiles every screen keeps): a painted
            # tile's own (GBC::Art#run_tile), or a drawn one's (GBC::Art#background_tile), in the
            # palette +bg+ draws it in. Two backgrounds that change the tile's colours differently —
            # one drawn with other lists and one not, or each with lists of its own — draw it from
            # two palettes.
            def background_tile_named(name, bg, room = nil)
              run = run_painting(name)
              return painted_tile(name, run, room) if run

              @art.background_tile(name, Assets::Image.of(@pictures.fetch(name)), room: room, recolor_steps: recolor_steps_of(name, bg),
                                                                                  empty_cells_shown: empty_cells_shown_with?(room))
            end

            # Each run's flag and its repacked tiles' stretch of work memory, which the console's copy
            # reads from an address that is a multiple of 16. A group has no such stretch: its tiles'
            # places are counted from nought, and from the picture it shows when it is copied.
            #
            # In a game with a group, a run's flag says which bank to put in view for its copy, and
            # the two bytes after it where its places are counted from. A list's run sets the flag
            # alone, and those two stay nought, as boot left them.
            def keep_tile_runs
              held = tile_runs.values.select(&:held_in)
              @held_pictures = held.to_h { |run| [run.name, @memory.reserve("the picture #{run.name.inspect} shows", 2)] }
              @source_now = @memory.reserve("where a painted run's copy reads from", 2) if held.any?
              @run_places = tile_runs.values.to_h do |run|
                owed = @memory.reserve("the painted tiles #{run.name.inspect}, waiting", held.any? ? 3 : 1)
                next [run.name, [owed, 0]] if run.held_in

                room = @memory.reserve("the painted tiles #{run.name.inspect}", (run_tile_count(run) * TILE_BYTES) + 15)
                [run.name, [owed, (room + 15) & ~15]]
              end
            end

            # Reference#exec_copy_tiles: the run's list repacked now, and put in at the next blank.
            def emit_copy_tiles(node) = emit_run_copy(tile_runs.fetch(node.name))

            # Reference#exec_copy_owed_tiles: every run whose bit is set in the game's own flags, in
            # the order they were declared.
            def emit_copy_owed_tiles(node)
              per = Nodes::CopyOwedTiles::RUNS_PER_MASK
              node.runs.each_with_index do |name, i|
                mask = @variables.fetch(node.masks.fetch(i / per))
                bit = i % per
                past = fresh("past_the_run")
                @asm.load(:a, [mask + (bit / 8)])
                @asm.bit(bit % 8, :a)
                @asm.jump(:z, past)
                emit_run_copy(tile_runs.fetch(name))
                @asm.label(past)
              end
            end

            def emit_run_copy(run)
              owed, staging = @run_places.fetch(run.name)
              return emit_held_picture_source(run, owed) if run.held_in

              emit_list_to_staging(run, staging)
              @asm.load(:a, 1)
              @asm.load([owed], :a)
            end

            def emit_list_to_staging(run, staging)
              list, = @lists.fetch(run.list) { raise LoweringError, "the list #{run.list.inspect} is painted from and never declared" }
              @asm.load(:hl, list + Runtime::Lists::HEADER)
              @asm.load(:de, staging)
              # A list in the Color's own form (`console_format: true`) is copied as it stands.
              @asm.load(:bc, run.console_format ? run_tile_count(run) * TILE_BYTES : run_tile_count(run))
              @asm.call(run.console_format ? "rt_copy_bc" : "rt_repack_tiles")
            end

            # A group's `show`: the game asked for the picture at +node.at+ in the Advance's form, whose
            # tiles are twice the Color's, so the place in the table is half that. Only the place is
            # kept here, which is what the group's list stands for: the picture is copied when the
            # run is, as a list's would be, so a screen coming up on this pass shows the picture it
            # had and the new one on the next.
            def emit_held_picture_copy(run, node)
              picture = @held_pictures.fetch(run.name)
              value(node.at)
              @asm.srl(:d)
              @asm.rr(:e)
              @asm.load(:a, :e)
              @asm.load([picture], :a)
              @asm.load(:a, :d)
              @asm.load([picture + 1], :a)
            end

            # Where in the cartridge the picture shown is, for the blank's copy, and its bank, which is
            # never nought, as the flag that says the run is waiting.
            def emit_held_picture_source(run, owed)
              picture = @held_pictures.fetch(run.name)
              @asm.load(:a, [picture])
              @asm.load(:e, :a)
              @asm.load(:a, [picture + 1])
              @asm.load(:d, :a)
              @asm.load(:hl, table_label(run.held_in))
              @asm.add_hl(:de)
              @asm.load(:a, :l)
              @asm.load([owed + 1], :a)
              @asm.load(:a, :h)
              @asm.load([owed + 2], :a)
              @asm.load_bank_of(:a, table_label(run.held_in))
              @asm.load([owed], :a)
            end
          end
        end
      end
    end
  end
end
