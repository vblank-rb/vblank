# frozen_string_literal: true

require "test_helper"
require "differential"

# A bitmap sprite remembers the pixels it covers and puts them back as it moves. CLEARING THE
# SCREEN UNDER IT — a new round, a change of scene — replaces those pixels, so what the sprite
# remembers is a square of a picture that is gone, and it must not be put back.
#
# Each test starts on a white field, clears it to blue part way through, and counts what is
# left once both backends have been seen to draw the same picture: any white is a square of
# the old field that came back.
class TestSpriteClearedField < Minitest::Test
  include Differential

  SIDE = 8
  BLOCK = ("########\n" * SIDE).freeze
  START = [40, 40].freeze
  ONE = SIDE * SIDE
  # The whole screen, in pixels, of the console this run plays the game on.
  private def field = described_game_console.screen_size.reduce(:*)

  # A white field with a red block sprite declared above the loop. The block is the game
  # loop's body, handed the sprite and a counter of the passes so far.
  private def field_program(&body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:block, "#" => :red) { BLOCK }
      clear_screen :white
      hero = sprite :block, at: START
      step = 0
      game_loop do
        instance_exec(hero, step, &body)
        step += 1
      end
    end
    b.finalize_program
    b.program
  end

  # How many pixels of each colour the picture holds after +frames+ passes, once both
  # backends have been seen to draw the same picture.
  private def colors_after(prog, frames)
    oracle, console, = backend_pictures(prog, frames: frames, name: "SPRCLR")
    bad = mismatched_pixels(oracle, console)
    assert_empty bad.first(5), "the console drew a different picture at #{bad.length} pixels"
    %i[red white blue green].to_h { |color| [color, oracle.count(Color.resolve(color))] }
  end

  def test_a_sprite_moved_after_a_clear_leaves_none_of_the_old_field
    prog = field_program do |hero, step|
      clear_screen :blue if step == 3
      hero.move :right, by: 8 if step > 3
    end

    seen = colors_after(prog, 8)

    assert_equal 0, seen[:white], "a square of the old field came back where the sprite stood"
    assert_equal ONE, seen[:red], "and the sprite is on the new field, one copy of it"
    assert_equal field - ONE, seen[:blue]
  end

  def test_a_sprite_hidden_after_a_clear_leaves_none_of_the_old_field
    prog = field_program do |hero, step|
      clear_screen :blue if step == 3
      hero.hide if step == 5
    end

    seen = colors_after(prog, 8)

    assert_equal field, seen[:blue]
  end

  # A clear inside an area clears that area and leaves the rest of the picture, so a sprite
  # outside it is still on the picture and still has to be rubbed out as it moves.
  def test_a_clear_inside_an_area_leaves_a_sprite_outside_it_alone
    width, height = described_game_console.screen_size
    prog = field_program do |hero, step|
      inside(120, 0, width - 120, height) { clear_screen :blue } if step == 3
      hero.move :down, by: 8 if step > 3
    end

    seen = colors_after(prog, 8)

    assert_equal ONE, seen[:red], "more than one block of red is a trail"
    assert_equal (120 * height) - ONE, seen[:white]
  end

  # A fill as big as the screen, from its top left corner, replaces the picture just as a clear
  # does, so the sprite has nothing of the old field to put back.
  #
  # The fill is the block fill: a `fill_rect` this big takes the Advance longer than a frame,
  # and on a screen of one page the cartridge is then caught half way through it, which no
  # picture of the interpreter's matches. The two verbs are one rule (IR::WholeScreen). Its size
  # is the screen the game is laid out on, which the run's console may show less of.
  def test_a_sprite_moved_after_a_whole_screen_fill_leaves_none_of_the_old_field
    prog = field_program do |hero, step|
      dma_fill_rect 0, 0, screen_width, screen_height, :blue if step == 3
      hero.move :right, by: 8 if step > 3
    end

    seen = colors_after(prog, 8)

    assert_equal 0, seen[:white], "a square of the old field came back where the sprite stood"
    assert_equal ONE, seen[:red]
    assert_equal field - ONE, seen[:blue]
  end

  def test_a_sprite_hidden_after_a_whole_screen_fill_leaves_none_of_the_old_field
    prog = field_program do |hero, step|
      dma_fill_rect 0, 0, screen_width, screen_height, :blue if step == 3
      hero.hide if step == 5
    end

    seen = colors_after(prog, 8)

    assert_equal field, seen[:blue]
  end

  # A fill that leaves part of the screen is not a clear: the sprite outside it is still on
  # the picture, and has to rub itself out as it moves.
  def test_a_fill_short_of_the_whole_screen_leaves_a_sprite_outside_it_alone
    width, height = VBlank::Console.described(game_console).screen_size
    prog = field_program do |hero, step|
      dma_fill_rect 120, 0, width - 120, height, :blue if step == 3
      hero.move :down, by: 8 if step > 3
    end

    seen = colors_after(prog, 8)

    assert_equal ONE, seen[:red], "more than one block of red is a trail"
    assert_equal (120 * height) - ONE, seen[:white]
  end

  # A sprite declared before its field was painted: it was drawn on the black screen the
  # console starts with, and the clear that follows is its real field.
  def test_a_sprite_declared_before_its_field_leaves_none_of_the_screen_before
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:block, "#" => :red) { BLOCK }
      hero = sprite :block, at: START
      clear_screen :blue
      game_loop { hero.move :right, by: 8 }
    end
    b.finalize_program

    seen = colors_after(b.program, 6)

    assert_equal ONE, seen[:red]
    assert_equal field - ONE, seen[:blue]
  end

  PLAY = 0
  REST = 1

  # A game of two scenes, the first with the sprite. The block is the first scene's body,
  # handed the sprite, the state and the pass counter.
  private def scenes_program(&play)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:block, "#" => :red) { BLOCK }
      clear_screen :white
      state = var :state, PLAY
      step = 0
      scene(:play) { instance_exec(sprite(:block, at: START), state, step, &play) }
      scene(:rest) {}
      game_loop do
        case_var(:state) do
          when_val PLAY, :play
          when_val REST, :rest
        end
        step += 1
      end
    end
    b.finalize_program
    b.program
  end

  # The natural way to change scene on a painted screen: clear it for the next scene, then
  # hand over, with the leaving scene's sprite still on the picture.
  def test_a_scene_that_clears_as_it_hands_over_leaves_a_whole_field
    prog = scenes_program do |_hero, state, step|
      if step == 3
        clear_screen :blue
        state.store! REST
      end
    end

    seen = colors_after(prog, 8)

    assert_equal field, seen[:blue], "nothing the leaving scene's sprite remembered was put back"
  end

  def test_a_scenes_sprite_moved_after_its_scene_clears_leaves_none_of_the_old_field
    prog = scenes_program do |hero, _state, step|
      clear_screen :blue if step == 3
      hero.move :right, by: 8 if step > 3
    end

    seen = colors_after(prog, 8)

    assert_equal 0, seen[:white]
    assert_equal ONE, seen[:red]
    assert_equal field - ONE, seen[:blue]
  end
end
