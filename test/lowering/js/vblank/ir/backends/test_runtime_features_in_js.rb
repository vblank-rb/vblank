# frozen_string_literal: true

require "test_helper"
require "runtime_feature_games"

# A runtime feature (IR::Backends::RuntimeFeatures) is in a game's JavaScript only when its steps
# need it.
class TestRuntimeFeaturesInJS < Minitest::Test
  runs_on_the_main_ractor! # the examples are read in, which declares games
  include VBlank::IR::Build
  include RuntimeFeatureGames

  JS = VBlank::IR::Backends::JS

  def test_a_game_that_pixelates_takes_in_pixelation
    text = JS.new.factory(program(screen(:bitmap), pixelate(size: int(4)), halt))

    assert_includes text, "function rg_pixelation_block_size("
    assert_includes text, "return rg_pixelation_block_size();"
  end

  def test_a_game_that_never_pixelates_holds_none_of_it
    text = JS.new.factory(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_pixelation"
    refute_includes text, "function rg_screen_pixelate("
  end

  def test_a_game_with_a_background_takes_in_the_tiled_feature
    text = JS.new.factory(game_with_a_background)

    assert_includes text, "function rg_tiled_paint_level("
    assert_includes text, "rg_tiled_paint_level(level);"
  end

  def test_a_background_declared_in_an_uncalled_routine_still_takes_it_in
    assert_includes JS.new.factory(game_scrolling_a_background_declared_in_an_uncalled_routine),
                    "function rg_background_scroll("
  end

  def test_a_game_with_no_background_holds_none_of_the_tiled_feature
    text = JS.new.factory(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_tiled"
    refute_includes text, "function rg_background_stamp("
  end

  def test_a_game_with_a_sprite_takes_in_the_sprites_feature
    text = JS.new.factory(game_with_a_sprite)

    assert_includes text, "function rg_sprites_paint_level("
    assert_includes text, "rg_sprites_paint_level(level);"
  end

  def test_a_game_with_no_sprite_holds_none_of_the_sprites_feature
    text = JS.new.factory(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_sprites"
    refute_includes text, "function rg_objects_begin("
  end

  # Sprites are painted after the scenery of their level, so the feature is taken after tiled.
  def test_the_sprites_feature_comes_after_the_tiled_one
    text = JS.new.factory(game_with_a_background_and_a_sprite)

    assert_operator text.index("function rg_tiled_paint_level("), :<, text.index("function rg_sprites_paint_level(")
    assert_operator text.index("rg_tiled_paint_level(level);"), :<, text.index("rg_sprites_paint_level(level);")
  end

  def test_a_game_that_fades_takes_in_the_fades_feature
    text = JS.new.factory(game_that_fades)

    assert_includes text, "function rg_fades_fade_filter("
    assert_includes text, "return rg_fades_fade_filter();"
  end

  def test_a_game_that_never_fades_holds_none_of_the_fades_feature
    text = JS.new.factory(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_fades"
    refute_includes text, "function rg_screen_fade("
  end

  def test_a_game_with_a_light_takes_in_the_light_feature
    text = JS.new.factory(game_with_a_light)

    assert_includes text, "function rg_light_dim_filter("
    assert_includes text, "return rg_light_dim_filter();"
  end

  def test_a_game_with_no_light_holds_none_of_the_light_feature
    text = JS.new.factory(program(screen(:bitmap), clear_screen(:white), halt))

    refute_includes text, "rg_light"
    refute_includes text, "function rg_screen_work_out_shade("
  end

  def test_a_game_with_a_column_takes_in_the_columns_feature
    assert_includes JS.new.factory(game_with_a_column), "function rg_screen_column("
  end

  def test_a_game_with_no_column_holds_none_of_the_columns_feature
    refute_includes JS.new.factory(program(screen(:bitmap), clear_screen(:white), halt)), "function rg_screen_column("
    refute_includes JS.new.factory(game_with_a_face), "function rg_screen_column("
  end

  def test_a_game_with_a_face_takes_in_the_faces_feature
    assert_includes JS.new.factory(game_with_a_face), "function rg_screen_face("
  end

  def test_a_game_with_no_face_holds_none_of_the_faces_feature
    refute_includes JS.new.factory(program(screen(:bitmap), clear_screen(:white), halt)), "function rg_screen_face("
    refute_includes JS.new.factory(game_with_a_column), "function rg_screen_face("
  end

  def test_a_game_with_a_tune_takes_in_the_music_feature_alone
    text = JS.new.factory(game_with_a_tune)

    assert_includes text, "function rg_music_sound_frame("
    assert_includes text, "rg_music_sound_frame();"
    assert_includes text, "rg_music_voice_taken_by_game(voice);"
    refute_includes text, "function rg_mix_"
    refute_includes text, "rg_mix_sound_frame"
  end

  def test_a_game_with_a_recording_takes_in_the_mix_feature_alone
    text = JS.new.factory(game_with_a_recording)

    assert_includes text, "function rg_mix_sound_frame("
    assert_includes text, "return rg_mix_mixed_slice(samples);"
    refute_includes text, "function rg_music_"
    refute_includes text, "rg_music_sound_frame"
  end

  # The mixer is joined before the player, so the frame's slice is made before the tune plays.
  def test_a_tune_on_a_recording_takes_in_both_with_the_mix_first
    text = JS.new.factory(game_with_a_tune_on_a_recording)

    assert_operator text.index("function rg_mix_sound_frame("), :<, text.index("function rg_music_sound_frame(")
    assert_operator text.index("rg_mix_sound_frame();"), :<, text.index("rg_music_sound_frame();")
  end

  def test_a_game_with_only_a_beep_holds_neither_sound_feature
    text = JS.new.factory(game_with_only_a_beep)

    refute_includes text, "function rg_music_sound_frame("
    refute_includes text, "function rg_mix_sound_frame("
    refute_includes text, "rg_music_sound_frame();"
    refute_includes text, "rg_mix_sound_frame();"
  end

  def test_every_example_that_plays_a_tune_or_mixes_takes_in_what_it_needs
    Dir[VBlank.root.join("examples/*.rb").to_s].sort.each do |path|
      next unless File.read(path).match?(/VBlank\.game\b/)

      before = VBlank.registered_games.size
      require path
      VBlank.registered_games.drop(before).each do |game|
        next unless game.consoles.include?(:gba)

        program = game.program(console: :gba)
        taken = JS::Lowering.new(program).runtime_features.map(&:name)

        assert_includes taken, :mix, "#{File.basename(path)} mixes recordings" if VBlank::IR::Mixing.mixes?(program)
        assert_includes taken, :music, "#{File.basename(path)} plays a tune" if program.walk.any? { |node| node.kind == :play_song }
      end
    end
  end

  # The sound runtime's own files and the windowless run call hooks; they name no music or mix
  # function.
  def test_the_sound_files_name_no_feature
    shared = %w[rg_sound.js rg_runtime.js rg_headless.js].map { |name| File.read(File.join(JS::RUNTIME_DIR, name)) }.join

    refute_match(MUSIC_NAMES, shared)
    refute_match(MIX_NAMES, shared)
  end

  def test_the_screen_file_names_no_feature
    screen = File.read(File.join(JS::RUNTIME_DIR, "rg_screen.js"))

    refute_match(/pixelat|read_block/, screen)
    refute_match(TILED_NAMES, screen)
    refute_match(SPRITES_NAMES, screen)
    refute_match(FADES_NAMES, screen)
    refute_match(LIGHT_NAMES, screen)
    refute_match(COLUMNS_NAMES, screen)
    refute_match(FACES_NAMES, screen)
  end
end
