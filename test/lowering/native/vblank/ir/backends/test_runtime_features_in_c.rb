# frozen_string_literal: true

require "test_helper"
require "runtime_feature_games"

# A runtime feature (IR::Backends::RuntimeFeatures) is in a game's C only when its steps need it:
# game.c includes its header, and the file the C screen includes takes in its code and its hooks.
class TestRuntimeFeaturesInC < Minitest::Test
  runs_on_the_main_ractor! # the examples are read in, which declares games
  include VBlank::IR::Build
  include RuntimeFeatureGames

  Native = VBlank::IR::Backends::Native
  Features = VBlank::IR::Backends::RuntimeFeatures

  private def features_text(program) = Features.c_text(Native::Lowering.new(program).runtime_features)

  # The scroll of a background declared only where no run reaches compiles: the feature is taken in.
  def test_a_background_declared_in_an_uncalled_routine_still_takes_it_in
    assert_includes features_text(game_scrolling_a_background_declared_in_an_uncalled_routine),
                    %(#include "tiled/rg_tiled.c")
  end

  def test_a_game_with_a_sprite_takes_in_the_sprites_feature
    sprites = game_with_a_sprite

    assert_includes Native.new.lower(sprites), %(#include "sprites/rg_sprites.h")
    assert_includes features_text(sprites), %(#include "sprites/rg_sprites.c")
    assert_includes features_text(sprites), "rg_sprites_paint_level(level)"
  end

  def test_a_game_with_no_sprite_holds_none_of_the_sprites_feature
    plain = program(screen(:bitmap), clear_screen(:white), halt)

    refute_includes Native.new.lower(plain), "rg_sprites"
    refute_includes features_text(plain), "rg_sprites"
  end

  # Sprites are painted after the scenery of their level, so the feature is taken after tiled.
  def test_the_sprites_feature_comes_after_the_tiled_one
    text = features_text(game_with_a_background_and_a_sprite)

    assert_operator text.index("tiled/rg_tiled.c"), :<, text.index("sprites/rg_sprites.c")
    assert_operator text.index("rg_tiled_paint_level(level);"), :<, text.index("rg_sprites_paint_level(level);")
  end

  def test_a_game_that_pixelates_takes_in_pixelation
    pixelates = program(screen(:bitmap), pixelate(size: int(4)), halt)

    assert_includes Native.new.lower(pixelates), %(#include "pixelation/rg_pixelation.h")
    assert_includes features_text(pixelates), %(#include "pixelation/rg_pixelation.c")
    assert_includes features_text(pixelates), "rg_pixelation_block_size()"
  end

  def test_a_game_that_never_pixelates_holds_none_of_it
    plain = program(screen(:bitmap), clear_screen(:white), halt)

    refute_includes Native.new.lower(plain), "pixelation"
    refute_includes features_text(plain), "pixelation"
  end

  def test_a_game_with_a_background_takes_in_the_tiled_feature
    tiled = game_with_a_background

    assert_includes Native.new.lower(tiled), %(#include "tiled/rg_tiled.h")
    assert_includes features_text(tiled), %(#include "tiled/rg_tiled.c")
    assert_includes features_text(tiled), "rg_tiled_paint_level(level)"
  end

  def test_a_game_with_no_background_holds_none_of_the_tiled_feature
    plain = program(screen(:bitmap), clear_screen(:white), halt)

    refute_includes Native.new.lower(plain), "rg_tiled"
    refute_includes features_text(plain), "rg_tiled"
  end

  def test_a_game_that_fades_takes_in_the_fades_feature
    fades = game_that_fades

    assert_includes Native.new.lower(fades), %(#include "fades/rg_fades.h")
    assert_includes features_text(fades), %(#include "fades/rg_fades.c")
    assert_includes features_text(fades), "rg_fades_fade_filter()"
  end

  def test_a_game_that_never_fades_holds_none_of_the_fades_feature
    plain = program(screen(:bitmap), clear_screen(:white), halt)

    refute_includes Native.new.lower(plain), "rg_fades"
    refute_includes features_text(plain), "rg_fades"
  end

  def test_a_game_with_a_light_takes_in_the_light_feature
    lit = game_with_a_light

    assert_includes Native.new.lower(lit), %(#include "light/rg_light.h")
    assert_includes features_text(lit), %(#include "light/rg_light.c")
    assert_includes features_text(lit), "rg_light_dim_filter()"
  end

  def test_a_game_with_no_light_holds_none_of_the_light_feature
    plain = program(screen(:bitmap), clear_screen(:white), halt)

    refute_includes Native.new.lower(plain), "rg_light"
    refute_includes features_text(plain), "rg_light"
  end

  def test_a_game_with_a_column_takes_in_the_columns_feature
    assert_includes features_text(game_with_a_column), %(#include "columns/rg_columns.c")
  end

  def test_a_game_with_no_column_holds_none_of_the_columns_feature
    plain = program(screen(:bitmap), clear_screen(:white), halt)

    refute_includes features_text(plain), "rg_columns"
    refute_includes features_text(game_with_a_face), "rg_columns"
  end

  def test_a_game_with_a_face_takes_in_the_faces_feature
    assert_includes features_text(game_with_a_face), %(#include "faces/rg_faces.c")
  end

  def test_a_game_with_no_face_holds_none_of_the_faces_feature
    plain = program(screen(:bitmap), clear_screen(:white), halt)

    refute_includes features_text(plain), "rg_faces"
    refute_includes features_text(game_with_a_column), "rg_faces"
  end

  private def sound_features_text(program) = Features.c_text(Native::Lowering.new(program).runtime_features, joins: :sound)

  def test_a_game_with_a_tune_takes_in_the_music_feature_alone
    tune = game_with_a_tune

    assert_includes Native.new.lower(tune), %(#include "music/rg_music.h")
    assert_includes sound_features_text(tune), %(#include "music/rg_music.c")
    assert_includes sound_features_text(tune), "rg_music_sound_frame()"
    refute_includes sound_features_text(tune), "rg_mix"
    refute_includes Native.new.lower(tune), "rg_mix"
    refute_includes features_text(tune), "music"
  end

  def test_a_game_with_a_recording_takes_in_the_mix_feature_alone
    recorded = game_with_a_recording

    assert_includes Native.new.lower(recorded), %(#include "mix/rg_mix.h")
    assert_includes sound_features_text(recorded), %(#include "mix/rg_mix.c")
    assert_includes sound_features_text(recorded), "rg_mix_mixed_slice(samples)"
    refute_includes sound_features_text(recorded), "rg_music"
    refute_includes Native.new.lower(recorded), "rg_music"
  end

  # The mixer is joined before the player, so the frame's slice is made before the tune plays.
  def test_a_tune_on_a_recording_takes_in_both_with_the_mix_first
    text = sound_features_text(game_with_a_tune_on_a_recording)

    assert_operator text.index("mix/rg_mix.c"), :<, text.index("music/rg_music.c")
    assert_operator text.index("rg_mix_sound_frame();"), :<, text.index("rg_music_sound_frame();")
    assert_includes text, "#define RG_FEATURE_MIX"
  end

  def test_a_game_with_only_a_beep_holds_neither_sound_feature
    beep = game_with_only_a_beep

    refute_match(/music|mix/, sound_features_text(beep))
    # (The game's own tables are written whatever it plays; its calls and headers are what shows a feature.)
    refute_match(/rg_music|rg_effect_|rg_mix/, Native.new.lower(beep))
  end

  # Every example that mixes anything is built with the mix, and every one that plays a tune with the
  # music: a game whose runtime lacked either would not link, or would play nothing.
  def test_every_example_that_plays_a_tune_or_mixes_takes_in_what_it_needs
    Dir[VBlank.root.join("examples/*.rb").to_s].sort.each do |path|
      next unless File.read(path).match?(/VBlank\.game\b/)

      before = VBlank.registered_games.size
      require path
      VBlank.registered_games.drop(before).each do |game|
        next unless game.consoles.include?(:gba)

        program = game.program(console: :gba)
        taken = Native::Lowering.new(program).runtime_features.map(&:name)

        assert_includes taken, :mix, "#{File.basename(path)} mixes recordings" if VBlank::IR::Mixing.mixes?(program)
        assert_includes taken, :music, "#{File.basename(path)} plays a tune" if program.walk.any? { |node| node.kind == :play_song }
      end
    end
  end

  # The sound runtime's own files name no sound feature: they call their hooks, and a hook nobody
  # takes does what the sound does alone.
  def test_the_sound_files_name_no_feature
    shared = %w[rg_sound.c rg_sound.h rg_sound_hook_defaults.h rg_runtime.c rg_runtime.h rg_headless.c].map do |name|
      File.read(File.join(Native::Zig::RUNTIME_DIR, name))
    end.join

    refute_match(MUSIC_NAMES, shared)
    refute_match(MIX_NAMES, shared)
  end

  # The screen's own files name no feature: they call their hooks, and a hook nobody takes does
  # what the screen does alone.
  def test_the_screen_files_name_no_feature
    screen = File.read(File.join(Native::Zig::RUNTIME_DIR, "rg_screen.c"))
    header = File.read(File.join(Native::Zig::RUNTIME_DIR, "rg_screen.h"))

    refute_match(/pixelat|read_block/, screen)
    refute_match(TILED_NAMES, screen + header)
    refute_match(SPRITES_NAMES, screen + header)
    refute_match(FADES_NAMES, screen + header)
    refute_match(LIGHT_NAMES, screen + header)
    refute_match(COLUMNS_NAMES, screen + header)
    refute_match(FACES_NAMES, screen + header)
  end
end
