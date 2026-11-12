# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        class Lowering
          # TILES THE GAME PAINTS FROM A LIST (`tiles :box, from: list, count: n`, and every group of
          # `tile_pictures`), lowered for a Genesis. Mixed into Lowering.
          #
          # The list holds each tile as the Advance's picture memory does: 32 bytes, two pixels a byte,
          # the left one in the low four bits. A Genesis keeps a tile in 32 bytes too, with the left
          # pixel in the HIGH four bits. So a copy turns each byte's halves round (a rotate by four)
          # as it takes the list into a stretch of work memory kept for the run, while the pass runs;
          # and the blank at the end of the pass writes that into video memory (#tile_runs_section,
          # which Runtime::Tiles#emit_upload calls), the gap between frames the interpreter copies in
          # (Reference#exec_copy_owed_tiles). Copied into work memory first, the tiles shown are the
          # list as it was when the game asked, whatever the pass writes into it after.
          #
          # Each painted tile is a tile of its own in video memory (Art#run_cell), never shared with
          # another however alike they look, drawn from the palette whose places are the run's list's;
          # or, for a group of `tile_pictures` whose pictures are known as the game is built, from the
          # palette holding the colours they draw (#run_places_drawn). A list in the Genesis's own form
          # (`console_format: true`) is copied as it stands.
          module TileRuns
            STATEMENT_KINDS = %i[copy_tiles copy_owed_tiles].freeze

            def emit_tile_runs_statement(node)
              case node.kind
              when :copy_tiles then emit_copy_tiles(node)
              when :copy_owed_tiles then emit_copy_owed_tiles(node)
              else raise LoweringError, "no writer here for #{node.kind.inspect}"
              end
            end

            # Whether the game paints tiles, which is when the blank calls "art runs uploaded".
            public def paints_tiles? = !tile_runs.empty?

            # The routine the blank calls (Runtime::Tiles#emit_upload): each run waiting, its tiles
            # written from its stretch of work memory into each place video memory keeps them, and its
            # flag cleared. A long at a time, eight to a tile.
            def tile_runs_section
              return [] unless paints_tiles?

              h = Console::GenesisHardware
              asm = M68000.new(RUNS_UPLOADED, holds: Picture::ART)
              asm.label(RUNS_UPLOADED)
              tile_runs.each_value do |run|
                owed, staging = @run_places.fetch(run.name)
                past = "art runs uploaded past #{run.name}"
                asm.tst(:w, asm.abs_l(owed))
                asm.branch(:eq, past)
                asm.clr(:w, asm.abs_l(owed))
                run.tiles.each_with_index do |tile, at|
                  @art.run_tile_numbers(tile).each do |number|
                    asm.move(:l, asm.imm(number * Art::TILE_BYTES), asm.d(0))
                    asm.jsr(asm.abs_l("rt_vram_write_at"))
                    asm.lea(asm.abs_l(staging + (at * Art::TILE_BYTES)), asm.a(0))
                    asm.moveq(LONGS_A_TILE - 1, asm.d(2))
                    asm.label("#{past} #{at} #{number}")
                    asm.move(:l, asm.post(0), asm.abs_l(h::VDP_DATA))
                    asm.dbra(asm.d(2), "#{past} #{at} #{number}")
                  end
                end
                asm.label(past)
              end
              asm.rts
              write_run_place_tables(asm)
              [asm.section]
            end

            RUNS_UPLOADED = "art runs uploaded"
            LONGS_A_TILE = Art::TILE_BYTES / 4
            # The side of the one size of painted tile made here.
            TILE_SIDE = 8

            private

            def tile_runs = @tile_runs_by_name ||= by_kind(:tile_run)

            # The run a painted tile is one of, or nil for a tile drawn when the game was built.
            def run_painting(name) = tile_runs.each_value.find { |run| run.tiles.include?(name) }

            # A picture a sprite shows painted from a list, and a run of tiles bigger than 8x8, are not
            # made here yet.
            def refuse_unmade_tile_runs!
              run = tile_runs.each_value.find { |each| each.picture || each.tile_side != TILE_SIDE } or return

              what = run.picture ? "The sprite picture #{run.name.inspect} is" : "The tiles of 16x16 #{run.name.inspect} are"
              raise NotMadeYet.new("#{what} painted from a list. The Genesis build does not make that yet. To fix this, " \
                                   "build the game for the Game Boy Advance alone for now (`consoles: %i[gba]`).",
                                   part: "pictures painted from a list")
            end

            # The cell showing painted tile +name+ of +bg+, run +run+: [tile number, palette]. On a
            # background drawn with other colours, or following a list the game changes, the run's
            # list is a palette the background writes over, as a drawn tile of that list is
            # (Picture#recolored_palette): the places the game paints are that palette's.
            def run_cell_of(bg, name, run)
              @art.with_tiles_of(tiles_scene_of(bg)) do
                @art.with_colors_of(colors_scene_of(bg)) do
                  # A run answers list_drawn_from as a picture does (Nodes::TileRun).
                  if !drawn_in_own_colors?(bg, run)
                    @art.run_cell(name, run.colors, palette: recolored_palette(bg, run))
                  elsif (drawn = run_places_drawn(run))
                    known_run_cell_of(name, run, drawn)
                  else
                    @art.run_cell(name, run.colors)
                  end
                end
              end
            end

            # Whether +bg+ draws +run+'s tiles in the run's own colours: not drawn with other lists,
            # nor following a list the game changes.
            def drawn_in_own_colors?(bg, run) = bg.recolors.empty? && bg.list_followed_by(run.list_drawn_from).nil?

            # A RUN OF `tile_pictures` WHOSE PICTURES ARE ALL KNOWN AS THE GAME IS BUILT draws only the
            # places of its list those pictures draw, since its list is only ever copied from them
            # (Nodes::TileRun#held_in). A run of a data pack's tiles (Builder::PackTilePictures) is
            # drawn from a bank of sixteen colours of which its pictures draw a few, and the still
            # tiles of the same bank beside it are drawn from whichever palette holds their colours
            # (Art#background_cell). Drawn from a palette of the whole bank in its order, the run
            # would take a palette of its own for every bank, which a scene's backgrounds rarely have
            # to spare. So it is drawn from the palette that holds the colours its pictures draw, as
            # a drawn tile is, and the copy puts each place where its colour is in that palette
            # (#emit_run_copy).
            #
            # These are the places, in order, or nil for a run drawn from its whole list: a list the
            # game paints itself, pictures read from the file as the game starts, or a run some
            # background draws in other colours or that backgrounds of two scenes' colours draw.
            def run_places_drawn(run)
              (@run_places_drawn ||= {}).fetch(run.name) do
                @run_places_drawn[run.name] = places_drawn_by_held_pictures(run)
              end
            end

            # The places +run+'s held pictures draw, or nil where it is drawn from its whole list: its
            # list painted by the game, pictures read from the file, a background drawing it in other
            # colours, or backgrounds in two scenes' colours (each would give it other palette places).
            def places_drawn_by_held_pictures(run)
              return nil if run.held_in.nil? || run.console_format

              table = @tables.fetch(run.held_in) { raise LoweringError, "the table #{run.held_in.inspect} is painted from and never declared" }
              return nil if table.read_from_file?

              showing = backgrounds_showing(run)
              return nil unless showing.map { |bg| colors_scene_of(bg) }.uniq.length == 1
              return nil unless showing.all? { |bg| drawn_in_own_colors?(bg, run) }

              table.values.flat_map { |byte| [byte & 0xF, (byte >> 4) & 0xF] }.uniq.reject(&:zero?).sort
            end

            def backgrounds_showing(run) = @backgrounds.select { |bg| bg.tiles.any? { |tile| run.tiles.include?(tile) } }

            # The cell of painted tile +name+ of +run+, whose pictures draw the places +drawn+, and for
            # each of those places its place in the cell's palette, kept for the run's copy. Every tile
            # of a run shares one copy, so each must be drawn from the same palette places.
            def known_run_cell_of(name, run, drawn)
              known = @art.known_run_cell(name, drawn.map { |place| run.colors.fetch(place) & 0x7FFF })
              palette_place_of = drawn.zip(known.places).to_h
              @run_palette_places ||= {}
              if @run_palette_places.fetch(run.name, palette_place_of) != palette_place_of
                raise LoweringError, "the tiles of the run #{run.name.inspect} were drawn from different places of their palettes"
              end

              @run_palette_places[run.name] = palette_place_of
              known.cell
            end

            # For a run drawn from known places (#run_places_drawn), each place's place in its palette:
            # made with the run's first cell if no map of the game has made one yet, so the copy reads
            # the table whenever the run's cells are drawn from it, whatever is lowered first.
            def run_palette_places(run)
              return @run_palette_places[run.name] if @run_palette_places&.key?(run.name)

              bg = backgrounds_showing(run).first
              cell_of(bg, bg.tiles.index { |tile| run.tiles.include?(tile) })
              @run_palette_places.fetch(run.name) { raise LoweringError, "the run #{run.name.inspect} was given no palette places" }
            end

            def run_place_table_label(run) = "art run places #{run.name}"

            # THE TABLE A COPY OF A RUN DRAWN FROM KNOWN PLACES READS (#run_places_drawn), one for each
            # such run. Entry N is what the list's byte N becomes in the Genesis's tile: its two halves
            # swapped, since the list keeps the left pixel in the low four bits and the Genesis in the
            # high four, and each half's place changed to that colour's place in the palette. One read
            # of it does what turning the byte's halves round does for any other run, in no more time.
            def write_run_place_tables(asm)
              (@run_palette_places || {}).each do |name, palette_place_of|
                asm.label(run_place_table_label(tile_runs.fetch(name)))
                asm.data_bytes((0...256).map { |byte| (palette_place_of.fetch(byte & 0xF, 0) << 4) | palette_place_of.fetch(byte >> 4, 0) })
              end
            end

            # Each run's flag (a word, not nought while it waits for the blank) and its stretch of work
            # memory, a tile's 32 bytes for each of its tiles.
            def keep_tile_runs
              @run_places = tile_runs.values.to_h do |run|
                owed = @memory.reserve("the painted tiles #{run.name.inspect}, waiting", 2)
                [run.name, [owed, @memory.reserve("the painted tiles #{run.name.inspect}", run.tiles.length * Art::TILE_BYTES)]]
              end
            end

            # Reference#exec_copy_tiles: the run's list taken now, and put in at the next blank.
            def emit_copy_tiles(node) = emit_run_copy(tile_runs.fetch(node.name))

            # Reference#exec_copy_owed_tiles: every run whose bit is set in the game's own flags, in the
            # order they were declared.
            def emit_copy_owed_tiles(node)
              per = Nodes::CopyOwedTiles::RUNS_PER_MASK
              node.runs.each_with_index do |name, i|
                past = fresh("past_the_run")
                @asm.move(:l, @asm.abs_l(@variables.fetch(node.masks.fetch(i / per))), @asm.d(0))
                @asm.btst(i % per, @asm.d(0))
                @asm.branch(:eq, past)
                emit_run_copy(tile_runs.fetch(name))
                @asm.label(past)
              end
            end

            # The run's list, its bytes' halves turned round, into its stretch of work memory, and the
            # run marked as waiting for the blank.
            # A run drawn from known places (#run_places_drawn) reads each byte's Genesis form from
            # its table (#write_run_place_tables), A2 pointing at it and D0's high bits nought.
            def emit_run_copy(run)
              owed, staging = @run_places.fetch(run.name)
              list, = @lists.fetch(run.list) { raise LoweringError, "the list #{run.list.inspect} is painted from and never declared" }
              moved = !run_places_drawn(run).nil?
              run_palette_places(run) if moved # its table is written with the other runs' (#write_run_place_tables)
              byte = fresh("run_byte")
              @asm.lea(@asm.abs_l(list, Runtime::Lists::HEADER), @asm.a(0))
              @asm.lea(@asm.abs_l(staging), @asm.a(1))
              if moved
                @asm.lea(@asm.abs_l(run_place_table_label(run)), @asm.a(2))
                @asm.moveq(0, @asm.d(0))
              end
              @asm.move(:w, @asm.imm((run.tiles.length * Art::TILE_BYTES) - 1), @asm.d(1))
              @asm.label(byte)
              @asm.move(:b, @asm.post(0), @asm.d(0))
              if moved
                @asm.move(:b, @asm.idx(2, 0, 0, :w), @asm.post(1))
              else
                @asm.rol(:b, 4, @asm.d(0)) unless run.console_format
                @asm.move(:b, @asm.d(0), @asm.post(1))
              end
              @asm.dbra(@asm.d(1), byte)
              @asm.move(:w, @asm.imm(1), @asm.abs_l(owed))
            end
          end
        end
      end
    end
  end
end
