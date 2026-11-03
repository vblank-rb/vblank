# frozen_string_literal: true

require "test_helper"
require "screen_backdrop_games"

# A BACKDROP THAT FADES WITH THE PICTURE: `screen :tiled, backdrop: :screen_colors` names a list of
# colours, and the colour shown wherever nothing is drawn is the list's first colour, whatever the
# game tells the list to hold with `recolor`. It changes on the frame the list's other users do.
# The fixed backdrop is test_screen_backdrop.rb.
class TestScreenBackdropList < Minitest::Test
  include VBlank::Testing::Pictures

  DARK = VBlank::Graphics::Color.rgb(0, 0, 10)
  DEEP = VBlank::Graphics::Color.rgb(0, 0, 20)
  BLUE = VBlank::Graphics::Color.rgb(0, 0, 31)
  RUST = VBlank::Graphics::Color.rgb(12, 4, 0)

  # What the list holds after each pass, the first pass first: black, two blues, then blue in full.
  STEPS = [%i[black black], [DARK, :red], [DEEP, :green], [BLUE, :white]].freeze

  # A tiled game that draws nothing and steps :screen_colors one set a pass, from black to blue,
  # with the backdrop following the list. A sprite drawn with the list stands at (40, 40) if
  # +with_sprite+, its pixels the list's second colour. The backdrop is the list's colour at +place+.
  private def stepping_game(with_sprite: false, place: 0)
    b = Builder.new
    b.instance_eval do
      colors :screen_colors, %i[black black]
      STEPS.each_with_index { |set, n| colors :"step#{n}", set }
      screen :tiled, backdrop: :screen_colors, backdrop_place: place
      if with_sprite
        image :square, width: 8, height: 8, data: Array.new(64, :white), colors: %i[black white]
        square = sprite :square, at: [40, 40]
        square.draw_with :screen_colors
      end
      step = var :step, 0
      game_loop do
        step += 1 if step < STEPS.length - 1
        recolor :screen_colors, STEPS.each_index.map { |n| :"step#{n}" }, showing: step
      end
    end
    b.finalize_program
    b.program
  end

  # Pass +pass+ (from 1) said set +pass+, and its picture is as far behind as the framework draws
  # (Testing#framework_drawing_lag): the backdrop is not drawn by the game.
  private def after_pass(program, pass) = game_player.run(program, frames: pass + framework_drawing_lag).screen

  def test_the_backdrop_shows_the_first_color_the_list_holds_on_the_frame_the_list_says
    (1..3).each do |pass|
      assert_equal shown(STEPS[pass].first), after_pass(stepping_game, pass).pixel(100, 100), "pass #{pass}"
    end
  end

  def test_the_screen_is_blue_once_the_list_holds_blue
    assert_equal shown(BLUE), after_pass(stepping_game, 3).pixel(100, 100)
  end

  # THE SAME FRAME AS A SPRITE DRAWN WITH THE LIST: the sprite's pixel and the backdrop come from
  # one set on every frame, never a frame apart.
  def test_the_backdrop_and_a_sprite_drawn_with_the_list_change_on_the_same_frame
    (1..3).each do |pass|
      screen = after_pass(stepping_game(with_sprite: true), pass)

      assert_equal [shown(STEPS[pass].first), shown(STEPS[pass].last)],
                   [screen.pixel(100, 100), screen.pixel(43, 43)], "pass #{pass}"
    end
  end

  # ...AND AT A PLACE THE SPRITE DRAWS, where a console can show the backdrop from the list's own
  # colours rather than a copy of one.
  def test_a_backdrop_at_a_place_a_sprite_draws_changes_with_the_sprite
    (1..3).each do |pass|
      screen = after_pass(stepping_game(with_sprite: true, place: 1), pass)

      assert_equal [shown(STEPS[pass].last)] * 2, [screen.pixel(100, 100), screen.pixel(43, 43)], "pass #{pass}"
    end
  end

  # THE CONSOLE SHOWS IT TOO, pixel for pixel, as the list steps.
  def test_the_console_shows_the_backdrop_as_the_interpreter_does
    assert_backends_agree(stepping_game(with_sprite: true), frames: [1, 2, 3, 5], name: "BDLIST")
    assert_backends_agree(stepping_game(with_sprite: true, place: 1), frames: [1, 2, 3, 5], name: "BDPLACE")
  end

  # A title whose list steps to blue by the third pass, then a board from the fifth: each scene has a
  # background of its own, the corner tile in its top left cell.
  private def title_then_board
    b = Builder.new
    b.instance_eval do
      colors :screen_colors, %i[black black]
      STEPS.each_with_index { |set, n| colors :"step#{n}", set }
      screen :tiled, backdrop: :screen_colors
      ScreenBackdropGames.declare_corner_tile(self)
      state = var :state, 0
      step = var :step, 0
      tick = 0
      scene(:title) { background :title, tiles: :corner_set, map: ["c"] }
      scene(:board) { background :board, tiles: :corner_set, map: ["c"] }
      game_loop do
        tick += 1
        step += 1 if step < STEPS.length - 1
        state = 1 if tick == 5
        recolor :screen_colors, STEPS.each_index.map { |n| :"step#{n}" }, showing: step
        case_var(:state) do
          when_val 0, :title
          when_val 1, :board
        end
      end
    end
    b.finalize_program
    b.program
  end

  # A SCENE ARRIVING LEAVES THE BACKDROP AS THE LIST HAS IT, rather than putting back the colour the
  # list was declared with: a game that faded its screen to blue keeps it blue across the hand-over.
  def test_a_scene_arriving_keeps_the_backdrop_the_list_holds
    screen = after_pass(title_then_board, 7)

    assert_equal shown(BLUE), screen.pixel(100, 100), "an empty cell"
    assert_equal shown(BLUE), screen.pixel(1, 1), "a see-through pixel"
    assert_backends_agree(title_then_board, frames: [3, 5, 6, 7], name: "BDSCENE")
  end

  # ANOTHER PLACE OF THE LIST, by backdrop_place:.
  def test_backdrop_place_picks_another_color_of_the_list
    b = Builder.new
    b.instance_eval do
      colors :screen_colors, [:black, RUST]
      colors :lit, %i[black blue]
      screen :tiled, backdrop: :screen_colors, backdrop_place: 1
      game_loop { recolor :screen_colors, :lit }
    end
    b.finalize_program

    assert_equal shown(:blue), after_pass(b.program, 2).pixel(100, 100)
  end

  # A LIST NOTHING RECOLOURS is one colour for good, which the backdrop shows from power-on.
  def test_a_list_nothing_recolors_is_the_backdrop_it_was_declared_with
    b = Builder.new
    b.instance_eval do
      colors :screen_colors, [RUST, :black]
      screen :tiled, backdrop: :screen_colors
      tick = 0
      game_loop { tick += 1 }
    end
    b.finalize_program

    assert_equal shown(RUST), game_player.run(b.program, frames: 2).screen.pixel(100, 100)
  end

  private def refusal(&game)
    b = Builder.new
    assert_raises(ArgumentError) do
      b.instance_eval(&game)
      b.finalize_program
    end
  end

  def test_a_name_that_is_no_color_and_no_list_is_refused
    error = refusal { screen :tiled, backdrop: :screen_colours }

    assert_match(/names no color and no list/, error.message)
  end

  def test_a_place_past_the_list_is_refused
    error = refusal do
      colors :screen_colors, %i[black blue]
      screen :tiled, backdrop: :screen_colors, backdrop_place: 2
    end

    assert_match(/places 0 to 1/, error.message)
  end

  def test_backdrop_place_without_a_list_is_refused
    error = refusal { screen :tiled, backdrop: :white, backdrop_place: 1 }

    assert_match(/names no list/, error.message)
  end

  def test_a_scene_that_says_its_own_backdrop_beside_the_list_is_refused
    error = refusal do
      colors :screen_colors, %i[black blue]
      screen :tiled, backdrop: :screen_colors
      var :state, 0
      scene(:title) { screen :tiled, backdrop: :white }
      game_loop { case_var(:state) { when_val 0, :title } }
    end

    assert_match(/backdrop of its own/, error.message)
  end

  def test_a_bitmap_screen_beside_the_list_is_refused
    error = refusal do
      colors :screen_colors, %i[black blue]
      screen :tiled, backdrop: :screen_colors
      var :state, 0
      scene(:title) { screen :bitmap }
      game_loop { case_var(:state) { when_val 0, :title } }
    end

    assert_match(/bitmap screen has no backdrop/, error.message)
  end
end
