# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # WHAT THIS CARTRIDGE'S RUNTIME CARRIES, worked out once for a build from the program and from
          # what the build chose to do. Both steps read this one value: Runtime.reserve, which has to
          # keep the runtime's places before the game's, so before the lowering exists, and
          # Runtime.sections, which writes the routines those places serve. Every fact is a field with
          # no default, so a new one is a line here and cannot be forgotten by one step and not the
          # other. A routine a game has no use for is left out, so a game that does not use a feature
          # builds the same bytes.
          #
          # +board+ is the cartridge's (Cartridge::SNESROM::BOARDS). +painted+ is a screen painted
          # rather than drawn from tiles (Paint). +saves+ reaches save memory. +sound+ makes sound,
          # +songs+ has songs, whose player (Music) follows the music volume with +follows_level+ and
          # shares the voices with +effects+ sound effects; +samples+ plays its own recordings, on
          # +recording_voices+. +holds_music+, +wobbles+, +steps_shapes+, +swells+, +slides+ and +sides+
          # are the parts of the player its songs use. +status_bar+ has a status bar (Picture's
          # rt_bar_place), and +row_held+ a background held above a row, which takes the same line table.
          # +bends+ bends a background row by row, a scene's own with +scene_bends+. +tile_runs+ is the
          # bytes of each run of tiles painted from lists, staged for the blank, +straight_tile_runs+ that
          # one of them keeps the console's own form, and +held_runs+ those with pictures held in the
          # cartridge. +changing_colors+ changes colours as it runs (Tint's rt_colors_hold), each scene's
          # backdrop with +scene_backdrops+, a backdrop that follows a list with +backdrop_follows+
          # (Tint's rt_backdrop_from), and +dims+ fades to black. +math_turns+ turns a see-through
          # layer solid. +bar_covers+ tells a bar to cover sprites. +tile_sizes+ has layers of two tile
          # sizes. +scene_tiles+ and +scene_background_tiles+ bring a scene's tiles in as it arrives.
          # +extra_buttons+ can ask about X and Y, and +second_controller+ reads it. +glides+ has a
          # recorded note that carries on the one sounding at a new pitch (Recordings). +text_layer+
          # shows text at places known when it is built on a layer over the painted one (TextLayer).
          Carries = Data.define(:board, :painted, :saves, :sound, :songs, :follows_level, :effects, :samples, :recording_voices,
                                :holds_music, :wobbles, :steps_shapes, :swells, :slides, :sides, :status_bar, :row_held,
                                :bends, :scene_bends, :tile_runs, :straight_tile_runs, :held_runs, :changing_colors,
                                :scene_backdrops, :backdrop_follows, :dims, :math_turns, :bar_covers, :tile_sizes, :scene_tiles,
                                :scene_background_tiles, :extra_buttons, :second_controller, :glides, :text_layer) do
            # What +program+ needs on +board+. The rest are what the build chose: +screen_colors+ and
            # +sprite_colors+ bring colours in by scene, +sprite_tiles+ and +background_tiles+ tiles.
            def self.of(program, board:, screen_colors:, sprite_colors:, sprite_tiles:, background_tiles:)
              picture = Lowering::Picture
              songs = Lowering::Sound.songs?(program)
              backdrops = picture.scene_backdrops?(program)
              new(board: board, painted: Lowering::Paint.painted?(program), saves: SaveLayout.named_by?(program),
                  sound: Lowering::Sound.sounds?(program), songs: songs, follows_level: songs && SNES::Music.follows_level?(program),
                  effects: IR::Tunes.effects(program).uniq.size, samples: Lowering::Sound.samples?(program),
                  recording_voices: SNES::Music.recording_voices(program), holds_music: Lowering::Sound.holds_music?(program),
                  wobbles: SNES::Music.wobbles?(program), steps_shapes: SNES::Music.steps_shapes?(program),
                  swells: SNES::Music.swells_under_level?(program), slides: SNES::Music.slides?(program),
                  sides: SNES::Music.sides_under_level?(program), status_bar: picture.status_bar?(program),
                  row_held: picture.background_rows_held?(program), bends: picture.bends?(program),
                  scene_bends: picture.scene_bends?(program), tile_runs: picture.tile_run_bytes(program),
                  straight_tile_runs: picture.tile_runs(program).any?(&:console_format), held_runs: picture.held_runs(program),
                  changing_colors: screen_colors || sprite_colors || backdrops || picture.changing_colors?(program) ||
                                   Lowering::Paint.inks?(program),
                  scene_backdrops: backdrops, backdrop_follows: picture.backdrop_follows_list?(program),
                  dims: picture.fades_to_black?(program),
                  math_turns: picture.see_through_turns_solid?(program), bar_covers: picture.bar_covers_sprites?(program),
                  tile_sizes: picture.two_tile_sizes?(program), scene_tiles: sprite_tiles,
                  scene_background_tiles: background_tiles, extra_buttons: Frame.reads_extra_buttons?(program),
                  second_controller: Frame.reads_second_controller?(program), glides: SNES::Music.glides?(program),
                  text_layer: board.name != :super_fx && Lowering::Paint.text_layer?(program))
            end

            # A Super FX on the board (Chip).
            def chip? = board.name == :super_fx

            # A line table for TM to carry: a status bar's, or the same for a background held above a row.
            def bar? = status_bar || row_held
          end
        end
      end
    end
  end
end
