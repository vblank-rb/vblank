# frozen_string_literal: true

require "place_games"

# Small games for the tests that a runtime feature (IR::Backends::RuntimeFeatures) is in a game's
# C, JavaScript or Ruby only when the game uses it.
module RuntimeFeatureGames
  # What a shared screen file must not name once the tiled feature holds it.
  TILED_NAMES = /rg_background_|status_bar|shown_backgrounds|RG_BG_FIELDS|rg_bend_/

  # What a shared screen file must not name once the sprites feature holds it. (The game's own
  # rg_game_sprites_over_picture is not one: the screen still calls it.)
  SPRITES_NAMES = /placed_object|sprite_layer|last_drawn|rg_objects_|rg_object_take|\bover_picture|NOTHING_OVER|left_out|turned_box|mix_as_sprite|rg_pixels_overlap|rg_pose_image|rg_place_in_ordered_run/

  # What a shared screen file must not name once the fades feature holds it. (rg_game_sprite_fade_places and
  # RG_BG_FADE_PLACE are not names of it: the screen still calls both.)
  FADES_NAMES = /rg_screen_fade|rg_screen_tint|rg_fade_steps|\bplaced_fade\b|tint_mode|tint_by_display|walked_toward|fade_reaches|RG_FADE_(WHOLE|INSIDE|OUTSIDE)/

  # What a shared screen file must not name once the light feature holds it. (The game's own
  # rg_game_shade_span and rg_game_shade_amount are not: the lowering always writes them.)
  LIGHT_NAMES = /rg_shade_|rg_screen_work_out_shade|shade_spans|shade_steps|shade_off/

  # What a shared screen file must not name once the columns feature holds it.
  COLUMNS_NAMES = /rg_screen_column/

  # What a shared screen file must not name once the faces feature holds it. (C's screen header still
  # declares rg_screen_face and rg_screen_column, which the lowering always calls, so the C test reads
  # rg_screen.c alone for these two.)
  FACES_NAMES = /rg_screen_face|face_edge|FaceEdge|face_crossing|face_reciprocals|FACE_RECIPROCALS|face_distance|face_place_in_perspective|face_row|FACE_MOST_CORNERS|shading_place|SHADING_PLACES|shaded_(place|color)/

  # What a shared sound file must not name once the music feature holds it.
  MUSIC_NAMES = /rg_music_|rg_effect_|rg_game_music|rg_game_effects|rg_game_note_sounds|step_wobbles|step_swells|step_shapes|play_song_frame|part_walk|fill_notes|NOTE_RECORD/

  # What a shared sound file must not name once the mix feature holds it. (rg_game_mix_seed is the
  # game's random seed for a match, not the mixer's.)
  MIX_NAMES = /rg_mix_|rg_game_mix(?!_seed)|rg_game_recording|mix_voice|fill_(steps|holds|shapes)/

  # A tiled screen with one background of one tile, put up as declared and never touched.
  private def game_with_a_background
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :tiled
      image(:brick, "#" => :red) { "########\n" * 8 }
      tiles :wall, "#" => :brick
      background :room, tiles: :wall, map: ["#"]
      halt
    end
    builder.finalize_program
    builder.program
  end

  # The same background, declared only in a routine nothing calls, and scrolled where the game
  # runs: the build still has it, so the scroll still needs the feature.
  private def game_scrolling_a_background_declared_in_an_uncalled_routine
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :tiled
      image(:brick, "#" => :red) { "########\n" * 8 }
      tiles :wall, "#" => :brick
      func(:never_called) { background :room, tiles: :wall, map: ["#"] }
      record(VBlank::IR::Build.scroll_background(:room, x: VBlank::IR::Build.int(4), y: VBlank::IR::Build.int(0)))
      halt
    end
    builder.finalize_program
    builder.program
  end

  # A tiled screen with one sprite of one picture, put where it is declared and never moved.
  private def game_with_a_sprite
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :tiled
      image(:ship, "#" => :red) { "########\n" * 8 }
      sprite :ship, at: [8, 8]
      halt
    end
    builder.finalize_program
    builder.program
  end

  # The same sprite over a background: both features, to see which is taken in first.
  private def game_with_a_background_and_a_sprite
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :tiled
      image(:brick, "#" => :red) { "########\n" * 8 }
      tiles :wall, "#" => :brick
      background :room, tiles: :wall, map: ["#"]
      sprite :brick, at: [8, 8]
      halt
    end
    builder.finalize_program
    builder.program
  end
  # A bitmap screen faded half way to black and tinted red, and nothing else.
  private def game_that_fades
    program(screen(:bitmap), fade(toward: :black, amount: int(50)), tint(color: :red, amount: int(50)), halt)
  end

  # A bitmap screen with one stretched column and no place.
  private def game_with_a_column
    builder = VBlank::Builder.new
    builder.instance_eval do
      image :bars, width: 2, height: 4, data: [0x001F, 0x03E0, 0x7C00, 0x7FFF, 0x001F, 0x03E0, 0x7C00, 0x7FFF]
      game_loop { draw_column_at :bars, slice: 0, x: 10, top: 0, height: 8 }
    end
    builder.finalize_program
    builder.program
  end

  # A bitmap screen with one face of a place and no stretched column.
  private def game_with_a_face = PlaceGames.square

  # A tiled room lit by a spotlight, and nothing else that fades.
  private def game_with_a_light
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      spotlight at: [120, 80], radius: 40, dark: 75
      game_loop {}
    end
    builder.finalize_program
    builder.program
  end
  # A tune and a beep, and no recording.
  private def game_with_a_tune
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap
      enable_sound
      song :tune do
        tempo 150
        voice(:lead) { note :C4, :quarter }
      end
      play_song :tune
      halt
    end
    builder.finalize_program
    builder.program
  end

  # A recording played by the game itself, and no tune.
  private def game_with_a_recording
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap
      enable_sound
      clip = sample :clip, pcm: [50, -50] * 8, rate: 8000
      clip.play
      halt
    end
    builder.finalize_program
    builder.program
  end

  # A tune whose part plays a recorded instrument: both features.
  private def game_with_a_tune_on_a_recording
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song :tune do
        tempo 150
        voice(:lead, plays: :piano) { note :C4, :quarter }
      end
      play_song :tune
      halt
    end
    builder.finalize_program
    builder.program
  end

  # Only the game's own beep: the voices and neither feature.
  private def game_with_only_a_beep
    program(enable_sound, halt)
  end
end
