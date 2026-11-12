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
          # another however alike they look, drawn from the palette whose places are the run's list's.
          # A list in the Genesis's own form (`console_format: true`) is copied as it stands.
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
                  if bg.recolors.empty? && bg.list_followed_by(run.list_drawn_from).nil?
                    @art.run_cell(name, run.colors)
                  else
                    @art.run_cell(name, run.colors, palette: recolored_palette(bg, run))
                  end
                end
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
            def emit_run_copy(run)
              owed, staging = @run_places.fetch(run.name)
              list, = @lists.fetch(run.list) { raise LoweringError, "the list #{run.list.inspect} is painted from and never declared" }
              byte = fresh("run_byte")
              @asm.lea(@asm.abs_l(list, Runtime::Lists::HEADER), @asm.a(0))
              @asm.lea(@asm.abs_l(staging), @asm.a(1))
              @asm.move(:w, @asm.imm((run.tiles.length * Art::TILE_BYTES) - 1), @asm.d(1))
              @asm.label(byte)
              @asm.move(:b, @asm.post(0), @asm.d(0))
              @asm.rol(:b, 4, @asm.d(0)) unless run.console_format
              @asm.move(:b, @asm.d(0), @asm.post(1))
              @asm.dbra(@asm.d(1), byte)
              @asm.move(:w, @asm.imm(1), @asm.abs_l(owed))
            end
          end
        end
      end
    end
  end
end
