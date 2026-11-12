# frozen_string_literal: true

require "test_helper"
require "scene_color_games"

# EACH SCENE'S PALETTES, as the Genesis build lays them out (Art's +scene_colors+): what a scene whose
# own pictures need more than the palettes left is told, and the one way of writing the loop whose
# hand-over frame would show the leaving scene's sprites in the arriving scene's colours.
class TestGenesisSceneColors < Minitest::Test
  include SceneColorGames

  Genesis = VBlank::IR::Backends::Genesis

  private def genesis_program(program) = program.copy.tap { |copy| copy.console = :genesis }

  # SceneColorGames's game fits only with each scene's sprite colours taking turns as well as its
  # backgrounds': with the backgrounds' alone, the list and both scenes' sprites leave one palette for a
  # scene's two banks.
  def test_the_scene_colour_game_needs_its_sprite_colours_to_take_turns
    Dir.mktmpdir do |folder|
      program = genesis_program(scene_colors_game(folder))
      lowering = Genesis::Lowering.new(program, memory: Genesis::Memory.new, scene_colors: :backgrounds)

      assert_raises(Genesis::Art::TooManyColors) { lowering.sections }
      assert_equal :sprites, lowering.scene_colors_after(:backgrounds)
    end
  end

  def test_a_scene_whose_own_pictures_need_more_than_the_palettes_left_is_refused_naming_it
    Dir.mktmpdir do |folder|
      program = scene_colors_game(folder, more_in_two: proc {
        image :crowd, width: 8, height: 8, data: Array.new(64) { |i| SceneColorGames.widened([i % 5, (i / 8) % 3, 7]) }
        sprite :crowd, at: [80, 80]
      })
      error = assert_raises(Genesis::Art::TooMuch) { Genesis.new.build(genesis_program(program)) }

      assert_includes error.message, "The pictures of the scene :two use more colours"
      assert_includes error.message, "every scene shows use 1 of the sets"
    end
  end

  # Two scenes of sprites alone, two pictures of fifteen colours each, beside a sprite of fifteen more
  # every scene shows: five sets of fifteen in all, which fit the four palettes only with each scene's
  # two in turn. The scene is picked straight in the loop, or with +inside_test+ inside an `if`, in the
  # pass that changed the variable picking it.
  private def sprite_scenes(inside_test: false)
    switch = 4
    # Each picture's own blue level tells its colours from the others'.
    fifteen = ->(blue) { Array.new(64) { |i| SceneColorGames.widened([i % 5, (i / 8) % 3, blue]) } }
    b = Builder.new
    b.instance_eval do
      screen :tiled
      2.times do |scene|
        2.times { |which| image :"pose_#{scene}_#{which}", width: 8, height: 8, data: fifteen.(1 + (scene * 2) + which) }
      end
      image :every_scene, width: 8, height: 8, data: fifteen.(6)
      sprite :every_scene, at: [100, 100]
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) { 2.times { |which| sprite :"pose_0_#{which}", at: [16 + (which * 16), 16] } }
      scene(:two) { 2.times { |which| sprite :"pose_1_#{which}", at: [16 + (which * 16), 16] } }
      dispatch = lambda do
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
      game_loop do
        tick += 1
        state = 1 if tick == switch
        state = 0 if tick == switch * 3
        if inside_test
          dispatch.call if tick >= 0
        else
          dispatch.call
        end
      end
    end
    b.finalize_program
    genesis_program(b.program)
  end

  # Checked on every pass against the interpreter, each scene's sprites in their own colours.
  def test_scenes_whose_sprite_colours_do_not_fit_together_show_their_own
    Genesis::CheckedRun.new.run(sprite_scenes, frames: 20)
  end

  # The game's loop picks its scene inside an `if`, after changing the variable that picks it in the
  # same pass: that pass's frame shows the leaving scene's sprites (IR::Frames.loop_in_console_order),
  # which would be drawn in the palettes the arriving scene wrote.
  def test_sprite_colours_taking_turns_refuse_a_scene_picked_inside_a_test_after_a_change
    error = assert_raises(Genesis::LoweringError) { Genesis.new.build(sprite_scenes(inside_test: true)) }

    assert_includes error.message, "share the same sets of colours for their sprites"
    assert_includes error.message, "move `case_var(:state)` to the top"
  end
end
