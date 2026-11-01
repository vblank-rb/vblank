# frozen_string_literal: true

require "test_helper"

# A scene's own backgrounds on a Genesis: they go up on the two planes as the scene takes over, in front of the
# ones every screen shows, and come down as the next scene takes over (IR::SceneHandover). Each test plays the
# game on the cartridge and the interpreter together (Genesis::CheckedRun), pass for pass.
class TestGenesisScenery < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  SOLID = ("########\n" * 8).freeze

  def test_two_scenes_each_with_a_background_of_their_own_take_turns_on_one_plane
    run = checked(frames: 14) do
      screen :tiled
      scene(:one) { background :one, tiles: :red_set, map: Array.new(20) { "#" * 30 } }
      scene(:two) { background :two, tiles: :blue_set, map: Array.new(20) { "#" * 30 } }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick += 1
        state = 1 if tick == 5
        state = 0 if tick == 10
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end

    assert_equal shown(:red), run.screen.pixel(100, 60)
  end

  def test_a_scene_without_scenery_of_its_own_takes_the_last_ones_down
    run = checked(frames: 12) do
      screen :tiled
      scene(:first) { background :first, tiles: :red_set, map: Array.new(20) { "#" * 30 } }
      scene(:bare) { nil }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick += 1
        state = 1 if tick == 5
        case_var(:state) do
          when_val 0, :first
          when_val 1, :bare
        end
      end
    end

    assert_equal 0, run.screen.pixel(100, 60), "the backdrop shows where the scene before had its own"
  end

  def test_scenery_every_screen_shows_stays_up_behind_a_scenes_own
    run = checked(frames: 12) do
      screen :tiled
      background :backdrop, tiles: :green_set, map: Array.new(20) { "#" * 30 }
      scene(:one) { background :one, tiles: :red_set, map: Array.new(20) { |row| (row.even? ? "#" : " ") * 30 } }
      scene(:two) { nil }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick += 1
        state = 1 if tick == 5
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end

    assert_equal shown(:green), run.screen.pixel(100, 60), "the backdrop's, once the scene with its own has gone"
  end

  def test_more_scenery_than_there_are_planes_is_refused_in_words
    error = assert_raises(Genesis::LoweringError) do
      Genesis.new.build(program_of do
        screen :tiled
        background :backdrop, tiles: :green_set, map: Array.new(20) { "#" * 30 }
        scene(:one) do
          background :near, tiles: :red_set, map: Array.new(20) { "#" * 30 }
          background :nearer, tiles: :blue_set, map: Array.new(20) { "#" * 30 }
        end
        state = var :state, 0
        game_loop { case_var(:state) { when_val 0, :one } }
      end)
    end

    assert_match(/The scene :one shows 3 backgrounds at one time/, error.message)
  end

  private

  def shown(color) = VBlank::Testing.shown(color)

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval do
      image(:red_art, "#" => :red) { SOLID }
      image(:blue_art, "#" => :blue) { SOLID }
      image(:green_art, "#" => :green) { SOLID }
      tiles :red_set, "#" => :red_art
      tiles :blue_set, "#" => :blue_art
      tiles :green_set, "#" => :green_art
      instance_eval(&game)
    end
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end

  def checked(frames:, &game) = Genesis::CheckedRun.new.run(program_of(&game), frames: frames)
end
