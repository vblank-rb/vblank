# frozen_string_literal: true

require "test_helper"
require "differential"

# Sprites declared in a scene, on a tiled screen: several to a scene, side by side in the frame's
# placing, one of them hidden partway. A lowering may ask "is this scene up" once for a scene's run
# of sprites rather than once for each, so each sprite must still show exactly while its scene is
# up and its own flag holds.
class TestSceneOwnedSprites < Minitest::Test
  include Differential

  # A title of three sprites and a playing scene of three, the game walking between them by itself:
  # the title until pass 5, play until pass 10, then the title again. The title's middle sprite
  # hides on pass 3, and play's last one from pass 7.
  private def two_scenes
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:dot, "#" => :yellow) { "########\n" * 8 }
      image(:box, "#" => :red) { "########\n" * 8 }
      t = var :t, 0
      where = var :where, 0
      scene :title do
        marks = Array.new(3) { |n| sprite :"mark_#{n}", at: [20 + (n * 30), 20], facing: { down: :dot } }
        marks[1].hide if t == 3
      end
      scene :playing do
        boxes = Array.new(3) { |n| sprite :"box_#{n}", at: [20 + (n * 30), 60], facing: { down: :box } }
        boxes.each { |box| box.x += 1 }
        boxes[2].hide if t == 7
      end
      game_loop do
        t += 1
        where = 1 if t == 5
        where = 0 if t == 10
        call({ 0 => :title, 1 => :playing }, number: :where)
      end
    end
    builder.finalize_program
    builder.program
  end

  NAMES = %i[mark_0 mark_1 mark_2 box_0 box_1 box_2].freeze

  def test_each_sprite_shows_only_while_its_scene_is_up_and_it_is_shown
    seen = {}
    i = game_player
    i.each_vblank { |frame| seen[frame] = NAMES.select { |name| i.sprites(name).any? } }
    i.run(two_scenes, frames: 14)

    assert_equal %i[mark_0 mark_1 mark_2], seen.fetch(2), seen.inspect
    assert(seen.values.none? { |names| names.any? { |name| name.start_with?("mark") } && names.any? { |name| name.start_with?("box") } },
           "the two scenes' sprites never show together: #{seen.inspect}")
    assert_includes seen.values, %i[box_0 box_1 box_2]
    assert_includes seen.values, %i[box_0 box_1]
    assert_includes seen.values, %i[mark_0 mark_2]
  end

  def test_the_picture_is_the_interpreters_across_both_scenes
    [2, 4, 6, 8, 11, 13].each { |frames| assert_backends_agree(two_scenes, frames: frames) }
  end
end
