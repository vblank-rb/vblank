# frozen_string_literal: true

require "test_helper"
require "many_tiles"
require "console/genesis/vblank/builder/test_scene_tiles_on_the_genesis"

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

  def test_a_scene_with_a_backdrop_of_its_own_is_refused_in_words
    error = assert_raises(Genesis::Lowering::NotMadeYet) do
      Genesis.new.build(program_of do
        screen :tiled
        background :field, tiles: :red_set, map: Array.new(20) { "#" * 30 }
        scene(:one) { screen :tiled, backdrop: :blue }
        state = var :state, 0
        game_loop { case_var(:state) { when_val 0, :one } }
      end)
    end

    assert_match(/a backdrop of its own/, error.message)
  end

  # Each scene's own tiles are counted with those every screen shows, and one scene with more than
  # video memory holds is refused naming it, though the other scene is small.
  def test_one_scene_with_more_tiles_than_video_memory_holds_is_refused_naming_it
    error = assert_raises(Genesis::Art::TooManyTiles) do
      Genesis.new.build(program_of do
        screen :tiled
        # Two backgrounds of half each, since one map of them all is taller than a plane.
        half = (Genesis::Art::MOST_TILES / 2) + 6
        near = ManyTiles.declare(self, :near_set, half, :red)
        far = ManyTiles.declare(self, :far_set, half, :blue, from: half)
        small = ManyTiles.declare(self, :small_set, 10, :green, from: half * 2)
        small += Array.new(near.length - small.length) { [nil] * ManyTiles::ACROSS } # every map one size
        scene(:huge) do
          background :far, tiles: :far_set, map: far
          background :near, tiles: :near_set, map: near
        end
        scene(:tiny) { background :tiny, tiles: :small_set, map: small }
        state = var :state, 0
        game_loop do
          case_var(:state) do
            when_val 0, :huge
            when_val 1, :tiny
          end
        end
      end)
    end

    assert_match(/The scene :huge and the pictures that every scene shows/, error.message)
  end

  # Each scene's sprite pictures take turns, and the game changes the variable that picks the scene
  # and then picks it inside an `if`: that pass would show the last scene's sprite in the new scene's
  # pictures, so the build is refused saying where, and how to write it.
  def test_sprite_pictures_taking_turns_refuse_a_scene_picked_inside_a_test_after_a_change
    program = TestSceneTilesOnTheGenesis.sprite_heavy_scenes(dispatched_inside_test: true)
    error = assert_raises(Genesis::LoweringError) { Genesis.new.build(program) }

    assert_match(/changes `state`/, error.message)
    assert_match(/inside an `if`/, error.message)
    assert_match(/move `case_var\(:state\)` to the top of the game loop/, error.message)
  end

  # A timer moves on each time the game waits for the screen. A routine that waits, called before the
  # pick inside an `if`, lets the timer change the variable in the same pass, after the scene was
  # noted for the frame's sprites: refused, naming the timer, the wait and the pick.
  def test_sprite_pictures_taking_turns_refuse_a_timer_changing_the_scene_across_a_wait_before_the_pick
    program = TestSceneTilesOnTheGenesis.sprite_heavy_scenes(dispatched_inside_test: true, changed_by: :timer_and_wait)
    error = assert_raises(Genesis::LoweringError) { Genesis.new.build(program) }

    assert_match(/timer `clock` changes `state` at \S*test_scene_tiles_on_the_genesis\.rb:\d+/, error.message)
    assert_match(/waits for the screen at \S+:\d+/, error.message)
    assert_match(/inside an `if` at \S+:\d+/, error.message)
  end

  # The loop's own wait written partway down, and the scene picked after it: the end of each pass
  # places the sprites before that pass picks its scene, so the first frame shows the first scene's
  # sprite before its pictures are in. Refused, naming the wait and the pick, whether the pick is
  # inside an `if` or not.
  def test_sprite_pictures_taking_turns_refuse_a_scene_picked_after_a_wait_partway_down_the_loop
    [true, false].each do |inside|
      program = TestSceneTilesOnTheGenesis.sprite_heavy_scenes(dispatched_inside_test: inside, changed_by: :pick_after_wait)
      error = assert_raises(Genesis::LoweringError) { Genesis.new.build(program) }

      assert_match(/after `wait_vblank` at \S+:\d+/, error.message)
      assert_match(/move `case_var\(:state\)` above `wait_vblank`/, error.message)
    end
  end

  # Picked at the top of the loop, the same scenes build.
  def test_sprite_pictures_taking_turns_build_with_a_scene_picked_at_the_top_of_the_loop
    assert Genesis.new.build(TestSceneTilesOnTheGenesis.sprite_heavy_scenes)
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
