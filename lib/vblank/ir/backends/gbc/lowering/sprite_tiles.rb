# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        class Lowering
          # SPRITE TILES THE GAME LOADS, AND POSES DRAWN FROM THEM (`sprite_tiles`, Nodes::SpriteTiles,
          # Nodes::TilePose, Nodes::LoadSpriteTiles), lowered for a Game Boy Color. Mixed into Lowering.
          #
          # The Color draws a sprite as pieces, and each piece names its tile in sprite memory. So a
          # set is a stretch of tiles of its own there (GBC::Art#sprite_tile_set), and a pose is
          # nothing but pieces naming tiles of that stretch (GBC::Art#tile_pose_picture): it keeps
          # no tiles of its own, and showing another pose is choosing other pieces, as `face` does
          # for any sprite. However many kinds of ball a game's cartridge holds, the poses take the
          # same room in the part of the cartridge always in view.
          #
          # A load names a table of tiles kept in a bank in the Color's own form, sixteen bytes a
          # tile, and starting on a multiple of 16, which is the only place the console's copy reads
          # from (TileRuns#sprite_tiles_source_section), apart from the table itself, which the game can
          # still read by index as it wrote it. The game only notes the load where it says it (a few
          # stores), and the blank after the pass copies the tiles straight from the cartridge
          # (Runtime::SpriteTileLoads).
          module SpriteTiles
            STATEMENTS = Ractor.make_shareable({ load_sprite_tiles: :emit_load_sprite_tiles })

            # Does the game load sprite tiles?
            def loads_sprite_tiles? = @reachable.any? { |node| node.kind == :load_sprite_tiles }

            private

            def sprite_tile_sets = @sprite_tile_sets ||= by_name(@program.walk, :sprite_tiles)
            def tile_poses = @tile_poses ||= by_name(@program.walk, :tile_pose)

            # The pose drawn from a set that +name+ is, or nil.
            def tile_pose_named(name) = tile_poses[name]

            # The number of the first of +set+'s tiles in sprite memory.
            def sprite_tile_set_first(set) = @art.sprite_tile_set(set.name, set.count)

            # The pose +pose+ as the console draws it (Art::SpritePicture).
            def tile_pose_picture(pose)
              @art.tile_pose_picture(pose, sprite_tile_set_first(sprite_tile_sets.fetch(pose.tiles)))
            end

            # The set a pose is drawn from, as a painted run is, by its colours.
            def tile_pose_colors(pose) = sprite_tile_sets.fetch(pose.tiles).colors

            # The tables loads read their tiles from, each once.
            def sprite_tiles_sources
              names = @reachable.filter_map { |node| node.table if node.kind == :load_sprite_tiles }.uniq
              names.map { |name| @tables.fetch(name) }
            end

            # Where a table's tiles are kept in the Color's own form (TileRuns#sprite_tiles_source_section),
            # apart from the table itself, which a read by index finds as the game wrote it.
            def sprite_tiles_label(name) = "sprite tiles from #{name}"

            # Reference#exec_load_sprite_tiles: each number worked out once, the load checked against
            # the ends of the table and the set (LoweringPlan.sprite_tile_load_bounds) and noted here,
            # and copied in the blank after the pass.
            def emit_load_sprite_tiles(node)
              set = sprite_tile_sets.fetch(node.name)
              bounds = LoweringPlan.sprite_tile_load_bounds(node, table_bytes: @tables.fetch(node.table).values.length,
                                                                  set_count: set.count)
              return unless bounds

              numbers = bounds.map { |number, most| [number_kept_once(number), most] }
              fits = numbers.map do |number, most|
                Build.binop(:and, Build.binop(:>=, number, Build.int(0)), Build.binop(:<=, number, Build.int(most)))
              end.reduce { |both, each| Build.binop(:and, both, each) }
              known = folded(fits)
              return if known&.zero?

              past = fresh("past_the_load")
              jump_unless(fits, past) unless known
              emit_tile_load_noted(node, set, *numbers.map(&:first))
              @asm.label(past)
            end

            # +number+ as a value read again for nothing: itself, where it is written in the program,
            # or a number of the routine's own it is worked out into once.
            def number_kept_once(number)
              known = folded(number)
              return Build.int(known) if known

              kept = keep_local(:load_tile)
              value(number)
              store(kept)
              Build.var_ref(kept)
            end

            # The load's bank, side, source, place and length, into the next entry of the queue.
            def emit_tile_load_noted(node, set, from, to)
              first = sprite_tile_set_first(set)
              # Measured before the runtime has its places (Lowering#keep_local says the same).
              queue = @measuring ? Memory::FIRST : @memory[Runtime::SpriteTileLoads::QUEUE]
              label = sprite_tiles_label(node.table)
              [[from, label], [to, 0x8000 + ((first % 128) * TileRuns::TILE_BYTES)]].each do |tile, base|
                value(tile)
                4.times do # sixteen bytes a tile
                  @asm.sla(:e)
                  @asm.rl(:d)
                end
                @asm.load(:hl, base)
                @asm.add_hl(:de)
                @asm.push(:hl)
              end
              @asm.load(:hl, queue)
              @asm.load(:a, [:hl])
              @asm.cp_a(Runtime::SpriteTileLoads::MOST_LOADS)
              @asm.jump(:nc, "rt_sprite_tile_loads_full")
              @asm.inc(:a)
              @asm.load([:hl], :a)
              @asm.dec(:a)
              @asm.load(:c, :a) # the entry's place: seven bytes an entry
              @asm.add_a(:a)
              @asm.add_a(:a)
              @asm.add_a(:a)
              @asm.sub_a(:c)
              @asm.load(:e, :a)
              @asm.load(:d, 0)
              @asm.load(:hl, queue + 1)
              @asm.add_hl(:de)
              @asm.load_bank_of(:a, label)
              @asm.load([:hli], :a)
              @asm.load(:a, first / 128)
              @asm.load([:hli], :a)
              @asm.pop(:de) # where the tiles go
              @asm.pop(:bc) # where they are
              %i[c b e d].each do |register|
                @asm.load(:a, register)
                @asm.load([:hli], :a)
              end
              @asm.load(:a, node.count - 1)
              @asm.load([:hl], :a)
            end
          end
        end
      end
    end
  end
end
