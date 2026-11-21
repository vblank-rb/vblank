# frozen_string_literal: true

require "test_helper"

# A game in features: `VBlank.game ..., features: { hero: %i[lamp], lamp: [], bat: [] }` names the
# parts of the game a build can leave out and what each brings with it, the block asks
# `feature?(:bat)`, and `game.with_features(:hero)` is the game built with those alone. A test asks
# for the smallest game that answers its question this way, and every run plays it.
class TestFeatures < Minitest::Test
  # The cave: a hero who walks once the game is playing and brings his lamp, and a bat that flies a
  # path read from a table. The game shows its title for TITLE_PASSES passes, counting them, and
  # then plays, keeping each pass's count in a trail. Shared with the cartridge's test of a feature left
  # out (test/lowering/gba/vblank/testing/test_feature_builds.rb) and the test of chosen starts.
  module Cave
    FEATURES = Ractor.make_shareable({ hero: %i[lamp], lamp: [], bat: [] })
    BAT_PATH = [0x1357, 0x2468, 0x1001, 0x2002].freeze
    TITLE_PASSES = 2

    # How far the bat has flown after the passes counted +steps+.
    def self.flown(steps) = steps.sum { |step| BAT_PATH[step & 3] }

    def self.game
      VBlank.game("CAVE", consoles: %i[gba gbc snes genesis ps1], features: FEATURES) do
        screen :bitmap
        mode = var :mode, :title
        steps = var :steps, 0
        trail = list :trail, capacity: 8
        hero_x = var :hero_x, 20 if feature?(:hero)
        var :lamp, 7 if feature?(:lamp)
        if feature?(:bat)
          bat_x = var :bat_x, 0
          path = table :bat_path, BAT_PATH
          func(:bat_flies) { bat_x += path[steps & 3] }
        end
        game_loop do
          steps += 1
          if mode == :title
            mode = :playing if steps >= TITLE_PASSES
          else
            trail.push steps
            hero_x += 1 if feature?(:hero)
            call :bat_flies if feature?(:bat)
          end
        end
      end
    end
  end

  # +game+ played past its title and then for +frames+ passes of play, which are counted from one
  # past the title's.
  private def played(game, frames)
    game_player.run(game.program(console: game_console), frames: Cave::TITLE_PASSES + frames)
  end

  private def playing_steps(frames) = (Cave::TITLE_PASSES + 1..Cave::TITLE_PASSES + frames).to_a

  def test_a_build_of_two_features_plays_both_and_what_they_bring
    player = played(Cave.game.with_features(:hero, :bat), 3)

    assert_equal 23, player[:hero_x]
    assert_equal 7, player[:lamp], "the hero brings his lamp"
    assert_equal Cave.flown(playing_steps(3)), player[:bat_x]
  end

  def test_a_build_of_one_feature_plays_without_the_others
    player = played(Cave.game.with_features(:bat), 2)

    assert_equal playing_steps(2), player.list(:trail)
    assert_equal Cave.flown(playing_steps(2)), player[:bat_x]
  end

  def test_the_game_named_with_no_features_has_all_of_them
    player = played(Cave.game, 1)

    assert_equal 21, player[:hero_x]
    assert_equal Cave.flown(playing_steps(1)), player[:bat_x]
  end

  def test_a_feature_the_game_does_not_declare_is_refused
    error = assert_raises(ArgumentError) { Cave.game.with_features(:hero, :dragon) }

    assert_match(/no feature :dragon/, error.message)
    assert_match(/:hero, :lamp, :bat/, error.message)
  end

  def test_a_game_asking_about_a_feature_it_does_not_declare_is_refused
    game = VBlank.game("ASKS", consoles: %i[gba gbc snes genesis ps1], features: { hero: [] }) do
      screen :bitmap
      var :x, 1 if feature?(:heroo)
      halt
    end

    error = assert_raises(ArgumentError) { game.program(console: game_console) }
    assert_match(/feature\?\(:heroo\)/, error.message)
  end

  def test_a_feature_that_brings_one_not_declared_is_refused
    error = assert_raises(ArgumentError) do
      VBlank.game("BRINGS", consoles: %i[gba], features: { hero: %i[sword] }) { halt }
    end

    assert_match(/:hero brings :sword/, error.message)
  end
end
