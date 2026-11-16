# frozen_string_literal: true

require "test_helper"
require "many_tiles"

# EACH SCREEN'S TILES ARE ITS OWN TO COUNT. Video memory holds 1471 tiles at once on a Genesis, and the
# console's own games load a screen's art as the screen starts, so two screens of 800 each never meet.
# The tiles every screen shows stay in video memory throughout; each scene's own go in as it takes over.
class TestSceneTilesOnTheGenesis < Minitest::Test
  SWITCH_AT = 4

  # The tiles of each scene's own background, more than half of what video memory holds.
  EACH_SCENE = 800

  # Where a scene's second tile is drawn: its first pixel is its number's lowest bit, which is set in
  # the second tile of each scene, red in the first scene's and green in the second's.
  SECOND_TILE = [8, 0].freeze

  # Where each scene's own sprite stands.
  MARK_AT = [160, 120].freeze

  # The ways sprite_heavy_scenes can change the variable that picks the scene and wait for the screen
  # (+changed_by+): in the loop before the pick (:loop), at the end of each scene's own routine
  # (:scenes), in a timer's `on_tick` (:timer), or in that timer with a routine of the game's own that
  # waits for the screen called before the pick (:timer_and_wait), built with `frame_sync: :manual`.
  # And with the loop's own wait written partway down, the pick after it (:pick_after_wait).
  CHANGED_BY = %i[loop scenes timer timer_and_wait pick_after_wait].freeze

  # +loads_first+ gives each scene's hand-over a pass of its own (`scene ..., loads_first: true`).
  # +handed_over_by_scene+ sets the variable at the end of each scene's own routine rather than in
  # the loop before the dispatch, so the next scene arrives on the pass after.
  # +dispatched_inside_test+ writes the dispatch inside an `if` of the loop rather than straight in it.
  private def two_scenes(loads_first: false, handed_over_by_scene: false, dispatched_inside_test: false)
    switch = SWITCH_AT
    count = EACH_SCENE
    mark = MARK_AT
    b = Builder.new
    b.instance_eval do
      screen :tiled
      first = ManyTiles.declare(self, :one_set, count, :red)
      second = ManyTiles.declare(self, :two_set, count, :green, from: count)
      image(:dot, "#" => :white) { "########\n" * 8 }
      image(:one_mark, "#" => :yellow, "." => :red) { "####....\n" * 8 }
      image(:two_mark, "#" => :blue, "." => :green) { "....####\n" * 8 }
      sprite :dot, at: [300, 200]
      state = var :state, 0
      tick = var :tick, 0
      scene(:one, loads_first: loads_first) do
        background :one, tiles: :one_set, map: first
        sprite :one_mark, at: mark
        state = 1 if tick == switch if handed_over_by_scene
      end
      scene(:two, loads_first: loads_first) do
        background :two, tiles: :two_set, map: second
        sprite :two_mark, at: mark
        state = 0 if tick == switch * 3 if handed_over_by_scene
      end
      dispatch = lambda do
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
      game_loop do
        tick += 1
        unless handed_over_by_scene
          state = 1 if tick == switch
          state = 0 if tick == switch * 3
        end
        if dispatched_inside_test
          dispatch.call if tick >= 0
        else
          dispatch.call
        end
      end
    end
    b.finalize_program
    b.program
  end

  # Pictures each scene's own sprite steps through, a hundred tiles each (ManyTiles#declare_sprite_pictures):
  # 800 tiles a scene, so the sprite pictures alone are more than video memory holds together.
  HEAVY_PICTURES = 8

  # Two scenes whose own SPRITE pictures do not fit together, and fit one scene at a time, so each
  # scene's sprite pictures come in as it takes over. +dispatched_inside_test+ is #two_scenes's, and
  # +changed_by+ one of CHANGED_BY. Built by the Genesis lowering's own tests too, for the ways of
  # writing the loop it refuses.
  def self.sprite_heavy_scenes(dispatched_inside_test: false, changed_by: :loop)
    raise ArgumentError, "changed_by: is one of #{CHANGED_BY}" unless CHANGED_BY.include?(changed_by)

    switch = SWITCH_AT
    pictures = HEAVY_PICTURES
    manual = %i[timer_and_wait pick_after_wait].include?(changed_by)
    b = Builder.new(options: VBlank::Cartridge::Options.new(frame_sync: manual ? :manual : :auto))
    b.instance_eval do
      screen :tiled
      first = ManyTiles.declare_sprite_pictures(self, :one_pose, pictures, :red)
      second = ManyTiles.declare_sprite_pictures(self, :two_pose, pictures, :green, from: pictures * 100)
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) do
        sprite :one_walker, at: [16, 16], frames: first, rate: 1
        state = 1 if tick == switch if changed_by == :scenes
      end
      scene(:two) do
        sprite :two_walker, at: [16, 16], frames: second, rate: 1
        state = 0 if tick == switch * 3 if changed_by == :scenes
      end
      if %i[timer timer_and_wait].include?(changed_by)
        # A tick a frame, so every frame of the pass that counts +switch+ sets the same number.
        clock = timer :clock, per_second: 60
        clock.on_tick do
          state = 1 if tick == switch
          state = 0 if tick == switch * 3
        end
      end
      func(:pause) { wait_vblank } if changed_by == :timer_and_wait
      dispatch = lambda do
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
      game_loop do
        wait_vblank if changed_by == :timer_and_wait
        tick += 1
        if %i[loop pick_after_wait].include?(changed_by)
          state = 1 if tick == switch
          state = 0 if tick == switch * 3
        end
        call :pause if changed_by == :timer_and_wait
        wait_vblank if changed_by == :pick_after_wait
        if dispatched_inside_test
          dispatch.call if tick >= 0
        else
          dispatch.call
        end
      end
    end
    b.finalize_program
    b.program
  end

  private def shown(color) = VBlank::Testing.shown(color)

  # The checked run holds every pass to the interpreter's picture, so a wrong tile in either scene
  # fails at the pass it shows.
  def test_two_scenes_of_eight_hundred_tiles_each_show_their_own
    game_player.run(two_scenes, frames: SWITCH_AT * 5)
    pass
  end

  # A scene that loads first takes its tiles in on the pass of its own it is given.
  def test_scenes_that_load_first_show_their_own
    game_player.run(two_scenes(loads_first: true), frames: SWITCH_AT * 5)
    pass
  end

  # THE PASS A SCENE TAKES OVER ON shows the new scene's map drawn from its own tiles, never from the
  # tiles of the scene before at the same places in video memory.
  def test_the_pass_of_the_hand_over_shows_the_new_scenes_own_tiles
    program = two_scenes

    assert_equal shown(:red), game_player.run(program, frames: SWITCH_AT - 1).screen.pixel(*SECOND_TILE), "the first scene"
    assert_equal shown(:green), game_player.run(program, frames: SWITCH_AT).screen.pixel(*SECOND_TILE), "the hand-over"
    assert_equal shown(:red), game_player.run(program, frames: SWITCH_AT * 3).screen.pixel(*SECOND_TILE), "and back"
  end

  # A SCENE THAT HANDS OVER AT THE END OF ITS OWN ROUTINE: the variable names the next scene for the
  # rest of that pass, and the next scene arrives on the pass after. Checked on every pass, neither
  # scene's sprite is drawn from the other's tiles.
  def test_a_scene_handing_over_at_its_end_shows_each_sprite_in_its_own_tiles
    game_player.run(two_scenes(handed_over_by_scene: true), frames: SWITCH_AT * 5)
    pass
  end

  def test_a_scene_loading_first_after_a_hand_over_at_the_end_shows_each_sprite_in_its_own_tiles
    game_player.run(two_scenes(loads_first: true, handed_over_by_scene: true), frames: SWITCH_AT * 5)
    pass
  end

  # A DISPATCH INSIDE AN `if` notes the scene for the frame's sprites as the pass starts
  # (IR::Frames.loop_in_console_order), so the pass a scene takes over on shows the arriving scene's
  # map with the leaving scene's sprite. Both scenes' tiles are wanted in that frame, and the
  # leaving scene's sprite is never drawn from the arriving scene's tiles.
  def test_the_hand_over_frame_of_a_dispatch_inside_a_test_shows_the_leaving_sprite_in_its_own_tiles
    program = two_scenes(dispatched_inside_test: true)
    x, y = MARK_AT

    assert_equal shown(:yellow), game_player.run(program, frames: SWITCH_AT).screen.pixel(x, y), "the leaving scene's sprite"
    game_player.run(program, frames: SWITCH_AT * 5)
  end

  # SPRITE PICTURES THAT DO NOT FIT TOGETHER take turns as the scenes do, picked at the top of the
  # loop: checked on every pass, each scene's sprite is drawn from its own pictures.
  def test_scenes_whose_sprite_pictures_do_not_fit_together_show_their_own
    game_player.run(self.class.sprite_heavy_scenes, frames: SWITCH_AT * 5)
    pass
  end

  # Picked inside an `if`, with the variable changed only by the scenes themselves: the scene up as
  # each pass starts is the one the pass shows.
  def test_sprite_pictures_taking_turns_with_a_dispatch_inside_a_test_changed_by_its_scenes
    game_player.run(self.class.sprite_heavy_scenes(dispatched_inside_test: true, changed_by: :scenes), frames: SWITCH_AT * 5)
    pass
  end

  # Picked inside an `if`, with the variable changed by a timer: a timer moves on as the game waits
  # for the screen, before the pass that picks the scene starts, so the scene up as each pass starts
  # is the one the pass shows. Checked on every pass, both hand-overs included.
  def test_sprite_pictures_taking_turns_with_a_dispatch_inside_a_test_changed_by_a_timer
    run = game_player.run(self.class.sprite_heavy_scenes(dispatched_inside_test: true, changed_by: :timer), frames: SWITCH_AT * 5)

    assert_equal 0, run[:state], "handed over to the second scene and back"
  end

  def test_each_scenes_sprite_is_drawn_from_its_own_tiles
    program = two_scenes
    x, y = MARK_AT

    assert_equal shown(:yellow), game_player.run(program, frames: 2).screen.pixel(x, y), "the first scene's"
    assert_equal shown(:green), game_player.run(program, frames: SWITCH_AT + 2).screen.pixel(x, y), "the second's"
    assert_equal shown(:white), game_player.run(program, frames: SWITCH_AT + 2).screen.pixel(300, 200), "every screen's"
  end
end
