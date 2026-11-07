# frozen_string_literal: true

# Small games for the tests that a runtime feature (IR::Backends::RuntimeFeatures) is in a game's
# C, JavaScript or Ruby only when the game uses it.
module RuntimeFeatureGames
  # What a shared screen file must not name once the tiled feature holds it.
  TILED_NAMES = /rg_background_|status_bar|shown_backgrounds|RG_BG_FIELDS|rg_bend_/

  # What a shared screen file must not name once the sprites feature holds it. (The game's own
  # rg_game_sprites_over_picture is not one: the screen still calls it.)
  SPRITES_NAMES = /placed_object|sprite_layer|last_drawn|rg_objects_|rg_object_take|\bover_picture|NOTHING_OVER|left_out|turned_box|mix_as_sprite|rg_pixels_overlap|rg_pose_image|rg_place_in_ordered_run/

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
end
