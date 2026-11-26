# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # What the runtime keeps in work memory only for a game that uses a feature, read off the
        # program before anything is lowered, for the build check to count against the room a game
        # has (Console::ColorKit#work_memory_reserved, Guardrails::Checks::IwramBudget). The least
        # game's own needs are already in Console::Description#work_memory_kept_bytes.
        #
        # Each item is sized by the runtime's own reserve call on a work memory of its own, so the
        # count and the runtime cannot drift apart, and test_gbc_memory.rb holds each to what a build
        # reserves. A feature is found by the node the lowering asks of, read over the whole program
        # where the lowering reads only what a run can reach, so a feature in a routine nothing calls
        # is counted here and not there: the check says less is free, never more.
        #--
        # Not counted, since only laying the game out can size them: what the art keeps (its lent
        # colours, sprite groups and rooms, the painted screen's cells, the groups held up together),
        # the songs and sound effects moved into banks when the cartridge's view is full, and a grid
        # kept beside a put-up. A game near the end of its memory that uses them can still pass the
        # check and be refused by the lowering (Memory::Full).
        #++
        module WorkReservations
          module_function

          def reserved_for(program)
            kinds = Set.new
            plays = []
            program.walk do |node|
              kinds << node.kind
              plays << node if node.kind == :play_sample
            end
            [walk_tables(kinds), tile_loads(kinds), recordings(plays), rumble(kinds), dark_frames(program),
             bar(program), bar_covers(program), cells_shown_now(program), music(program, kinds, plays)].compact
          end

          # The tables a fade or tint looks its colours up in (Lowering#walks_colors?).
          def walk_tables(kinds)
            return unless kinds.intersect?(%i[fade tint])

            item("the color tables for fades and tints") { |memory| Runtime::Picture.reserve_walk_tables(memory) }
          end

          # The queue of sprite tiles a pass loads (Lowering#loads_sprite_tiles?).
          def tile_loads(kinds)
            return unless kinds.include?(:load_sprite_tiles)

            item("the queue of sprite tiles to load") { |memory| Runtime::SpriteTileLoads.reserve(memory) }
          end

          # The recordings' player (Clips#any?), and what the music player keeps beside it to put a
          # wave note back once a recording has borrowed the wave voice. Runtime::Music.reserve asks
          # whether there is a recording, so it reserves after the player here, as the build does.
          def recordings(plays)
            return if plays.empty?

            difference("the player for recordings", proc { |memory| Runtime::Music.reserve(memory) }) do |memory|
              Runtime::Clips.reserve(memory, laps: plays.any?(&:loop))
              Runtime::Music.reserve(memory)
            end
          end

          # The motor's count (Lowering#rumbles?).
          def rumble(kinds)
            return unless kinds.include?(:rumble)

            item("the rumble motor's count") { |memory| Runtime::Rumble.reserve(memory) }
          end

          # The count of frames the screen is off for, in a game that reads it (Lowering#counts_dark_frames?).
          def dark_frames(program)
            return unless Frames.counts_from_power_on?(program)

            difference("the count of frames the screen is off", proc { |memory| Runtime::Frame.reserve(memory) }) do |memory|
              Runtime::Frame.reserve(memory, dark: true)
            end
          end

          # A status bar's place and the job that puts it up (Lowering::Picture#bar_rows).
          def bar(program)
            return unless program.walk.any? { |node| node.kind == :background && node.bar? }

            difference("the status bar's place", proc { |memory| Runtime::Picture.reserve(memory) }) do |memory|
              Runtime::Picture.reserve(memory, bar_rows: 1)
            end
          end

          # A status bar told to cover the sprites (Lowering::Picture#bar_covers_sprites?).
          def bar_covers(program)
            return unless program.walk.any? { |node| node.kind == :place_bar && node.covers }

            difference("the status bar's cover", proc { |memory| Runtime::Picture.reserve(memory) }) do |memory|
              Runtime::Picture.reserve(memory, bar_covers: true)
            end
          end

          # A cell shown on the frame being drawn (Lowering::Picture#cells_shown_now?).
          def cells_shown_now(program)
            return unless program.walk.any? { |node| node.kind == :set_tile && node.now }

            difference("the cell shown now", proc { |memory| Runtime::Picture.reserve(memory) }) do |memory|
              Runtime::Picture.reserve(memory, cells_shown_now: true)
            end
          end

          # What the music player keeps past the least game's for the songs and sound effects as
          # they are written: their effects' table, a note's slide, speaker, vibrato, shape and wave,
          # a song that plays once, a held tune, a swell the game holds, and the effects' timer.
          # Read through the lowering's own Music, as the build reads it with its songs in view. A
          # game whose songs the lowering refuses counts nothing here; the lowering says why.
          def music(program, kinds, plays)
            songs = Music.new(program)
            swells = kinds.include?(:set) && program.walk.any? { |node| node.kind == :set && node.var == Tunes::LEVEL } ? Tunes.swelling_voice_kinds(program) : []
            settings = { effects: songs.effects, slides: songs.slides?, pans: songs.pans?, wobbles: songs.wobbles?,
                         shapes: songs.shapes?, waves: songs.waves?, swells: swells.any?, noise_swells: swells.include?(:noise),
                         holds: kinds.include?(:hold_music), tune_plays_once: songs.tune_plays_once?,
                         effect_clock_step: songs.effect_clock_step, effect_tempo_step: songs.effect_tempo_step }
            reserved = difference("the music player's extras", proc { |memory| Runtime::Music.reserve(memory) }) do |memory|
              Runtime::Music.reserve(memory, **settings)
              if songs.effect_clock_step && !songs.effects.empty?
                Runtime::Strikes.reserve(memory, line: !plays.empty?, bar: kinds.include?(:place_bar))
              end
            end
            reserved if reserved.bytes.positive?
          rescue LoweringError
            nil
          end

          # An item named +label+, as many bytes as the block reserves in a work memory of its own.
          def item(label, &reserve) = Console::Kit::WorkReservation.new(label: label, bytes: bytes_reserved(&reserve))

          # An item named +label+, as many bytes as the block reserves past what +least+ reserves.
          def difference(label, least, &reserve)
            Console::Kit::WorkReservation.new(label: label, bytes: bytes_reserved(&reserve) - bytes_reserved(&least))
          end

          def bytes_reserved
            memory = Memory.new
            yield memory
            memory.used
          end
        end
      end
    end
  end
end
