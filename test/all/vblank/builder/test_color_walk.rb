# frozen_string_literal: true

require "test_helper"

# A COLOUR WALK, the fade a console's own game does: each channel of each colour is one step from
# the last, so a bright channel starts first, a dim colour stays at the far end for most of the
# walk, and every channel arrives on the same step. A mix would show the dim colours sooner.
class TestColorWalk < Minitest::Test
  # Five-bit channels into a colour, red lowest.
  private def rgb5(red, green, blue) = red | (green << 5) | (blue << 10)

  private def built(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # The lists a walk of +own+ names, step by step, as the builder declared them; +walk+ is
  # color_walk's settings.
  private def walk_lists(own, **walk)
    b = Builder.new
    names = nil
    b.instance_eval do
      colors :city, own
      names = color_walk(:city, **walk)
    end
    names.map { |name| b.declared_colors(name) }
  end

  def test_a_walk_from_black_lifts_each_channel_a_step_at_a_time
    own = [:transparent, rgb5(20, 20, 20)]
    lists = walk_lists(own, from: :black, steps: 31)

    assert_equal 32, lists.length
    assert_equal 0, lists[11][1], "twenty steps from the end, a channel of 20 is still black"
    assert_equal rgb5(3, 3, 3), lists[14][1], "and it has come up by three three steps later"
    assert_equal rgb5(8, 8, 8), lists[19][1]
    assert_equal own[1], lists[31][1], "and the last step is the colour itself"
  end

  def test_a_bright_channel_starts_first_and_all_arrive_together
    lists = walk_lists([:transparent, rgb5(31, 10, 0)], from: :black, steps: 31)

    assert_equal rgb5(5, 0, 0), lists[5][1]
    assert_equal rgb5(25, 4, 0), lists[25][1]
    assert_equal rgb5(30, 9, 0), lists[30][1]
    assert_equal rgb5(31, 10, 0), lists[31][1]
  end

  def test_a_walk_from_white_falls_to_the_colour
    lists = walk_lists([:transparent, rgb5(31, 10, 0)], from: :white, steps: 31)

    assert_equal rgb5(31, 31, 31), lists[0][1]
    assert_equal rgb5(31, 11, 1), lists[30][1]
    assert_equal rgb5(31, 10, 0), lists[31][1]
  end

  def test_fewer_steps_start_nearer
    lists = walk_lists([:transparent, rgb5(20, 20, 20)], from: :black, steps: 4)

    assert_equal [rgb5(16, 16, 16), rgb5(17, 17, 17), rgb5(18, 18, 18), rgb5(19, 19, 19), rgb5(20, 20, 20)],
                 lists.map { |list| list[1] }
  end

  # The background walks while a sprite drawn in the same colour stays as it is.
  def test_a_background_walks_up_while_a_sprite_stays
    seen = game_player
    seen.run(walking_game, frames: 16)

    assert_equal VBlank::Testing.shown(rgb5(10, 10, 10)), seen.screen.pixel(4, 4), "the walked background, ten steps of twenty up"
    assert_equal VBlank::Testing.shown(rgb5(20, 20, 20)), seen.screen.pixel(4, 62), "the sprite is as drawn"
  end

  private def walking_game
    gray = rgb5(20, 20, 20)
    built do
      screen :tiled
      colors :city, [:transparent, gray]
      colors :sky, [:transparent, gray]
      image(:city_art, colors: :city, width: 8, height: 8, places: Array.new(64, 1))
      image(:sky_art, colors: :sky, width: 8, height: 8, places: Array.new(64, 1))
      tiles :city_tiles, "#" => :city_art
      city = background :city_layer, tiles: :city_tiles, map: Array.new(4) { "#" * 32 }
      sprite :sky_art, at: [0, 60]
      walk = color_walk(:city, from: :black, steps: 20)
      step = 0
      game_loop do
        city.draw_with walk, showing: step
        step += 1 if step < 10
      end
    end
  end

  # A long walk beside a short fade, as a title does: the walk runs while the screen fades out.
  # The walk is lists, so the fade keeps its own length, and each is checked against the
  # interpreter on every frame on the runs that build the game.
  def test_a_walk_and_a_short_fade_run_at_once
    gray = rgb5(20, 20, 20)
    game = built do
      screen :tiled
      colors :city, [:transparent, gray]
      image(:city_art, colors: :city, width: 8, height: 8, places: Array.new(64, 1))
      tiles :city_tiles, "#" => :city_art
      city = background :city_layer, tiles: :city_tiles, map: Array.new(4) { "#" * 32 }
      walk = color_walk(:city, from: :black, steps: 20)
      step = 0
      game_loop do
        city.draw_with walk, showing: step
        step += 1 if step < 20
        fade_out frames: 4 if step == 6
      end
    end
    seen = game_player
    seen.run(game, frames: 30)

    assert_equal 0, seen.screen.pixel(4, 4), "faded out, whatever the walk reached"
  end

  # A list of sprite colours walks by `recolor`, and only sprites drawn with it move.
  def test_a_sprite_list_walks
    gray = rgb5(20, 20, 20)
    game = built do
      screen :tiled
      colors :letters, [:transparent, gray]
      colors :others, [:transparent, gray]
      image(:letter, colors: :letters, width: 8, height: 8, places: Array.new(64, 1))
      image(:other, colors: :others, width: 8, height: 8, places: Array.new(64, 1))
      letter = sprite :letter, at: [8, 8]
      letter.draw_with :letters
      sprite :other, at: [24, 8]
      walk = color_walk(:letters, from: :white, steps: 8)
      step = 0
      game_loop do
        recolor :letters, walk, showing: step
        step += 1 if step < 4
      end
    end
    seen = game_player
    seen.run(game, frames: 12)

    assert_equal shown(rgb5(24, 24, 24)), seen.screen.pixel(10, 10), "four steps of eight on from white"
    assert_equal shown(gray), seen.screen.pixel(26, 10), "the other sprite is as drawn"
  end

  # A WALK WHOSE CHANNELS WAIT FOR A FALLING COUNT, the rule of a retail fade routine: a count
  # starts at 32 and falls by the step, 2, on each step; a channel waits until what it has to go is
  # at least the count, then moves by the step, and one that passes its height comes back on the
  # next step. Each channel's trail below is worked by hand from that rule, one number a step.
  COUNTED_TRAILS = {
    31 => [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 31, 31],
    30 => [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 30, 30],
    17 => [0, 0, 0, 0, 0, 0, 0, 0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 17],
    5 => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 4, 6, 5],
    2 => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2, 2],
    1 => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1],
    0 => Array.new(18, 0)
  }.freeze

  # The colour each step of a counted walk from black shows for +red+, +green+ and +blue+.
  private def counted_colors(red, green, blue)
    COUNTED_TRAILS.fetch(red).zip(COUNTED_TRAILS.fetch(green), COUNTED_TRAILS.fetch(blue)).map { |channels| rgb5(*channels) }
  end

  private def counted_walk_lists(own, from:) = walk_lists(own, from: from, step: 2, count: 32)

  def test_a_counted_walk_holds_every_step_to_the_rule_worked_by_hand
    lists = counted_walk_lists([:transparent, rgb5(31, 17, 0), rgb5(5, 30, 1), rgb5(2, 0, 17)], from: :black)

    assert_equal 18, lists.length, "black, then 17 steps"
    assert_equal counted_colors(31, 17, 0), lists.map { |list| list[1] }
    assert_equal counted_colors(5, 30, 1), lists.map { |list| list[2] }
    assert_equal counted_colors(2, 0, 17), lists.map { |list| list[3] }
  end

  # Down from white the rule is the same turned over: 20 is 11 below, so it waits until the count
  # is 10, falls by 2 to 19, and comes back to 20 on the last step.
  def test_a_counted_walk_from_white_comes_down_with_the_count
    lists = counted_walk_lists([:transparent, rgb5(20, 0, 31)], from: :white)

    reds = [31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 31, 29, 27, 25, 23, 21, 19, 20]
    greens = [31, 29, 27, 25, 23, 21, 19, 17, 15, 13, 11, 9, 7, 5, 3, 1, 0, 0]
    assert_equal reds.zip(greens).map { |red, green| rgb5(red, green, 31) }, lists.map { |list| list[1] }
  end

  def test_every_height_arrives_on_the_last_step_of_a_counted_walk
    (0..31).map { |level| rgb5(level, 31 - level, level) }.each_slice(15) do |colors|
      own = [:transparent, *colors]

      assert_equal colors, counted_walk_lists(own, from: :black).last.drop(1)
      assert_equal colors, counted_walk_lists(own, from: :white).last.drop(1)
    end
  end

  # The walk played: a background brought up from black by the counted rule, a step a pass, as far
  # as step +last+ and held there.
  private def counted_walking_game(last)
    color = rgb5(31, 17, 0)
    built do
      screen :tiled
      colors :bar, [:transparent, color]
      image(:bar_art, colors: :bar, width: 8, height: 8, places: Array.new(64, 1))
      tiles :bar_tiles, "#" => :bar_art
      bar = background :bar_layer, tiles: :bar_tiles, map: Array.new(4) { "#" * 32 }
      walk = color_walk(:bar, from: :black, step: 2, count: 32)
      step = 0
      game_loop do
        bar.draw_with walk, showing: step
        step += 1 if step < last
      end
    end
  end

  def test_a_background_walks_up_by_the_counted_rule
    trail = counted_colors(31, 17, 0)
    [9, 16, 17].each do |last|
      seen = game_player.run(counted_walking_game(last), frames: 24)

      assert_equal shown(trail.fetch(last)), seen.screen.pixel(4, 4), "step #{last}"
    end
  end

  def test_a_counted_walk_needs_a_positive_step_and_count
    %i[step count].each do |setting|
      error = assert_raises(ArgumentError) do
        Builder.new.instance_eval do
          colors :city, %i[transparent red]
          color_walk(:city, from: :black, step: 2, count: 32, setting => 0)
        end
      end

      assert_match(/#{setting}:/, error.message)
    end
  end

  def test_a_step_without_a_count_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        colors :city, %i[transparent red]
        color_walk(:city, from: :black, step: 2)
      end
    end

    assert_match(/count:/, error.message)
  end

  def test_a_colour_a_walk_does_not_know_is_a_friendly_error
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { color_walk(:nothing, from: :black) } }

    assert_match(/:nothing/, error.message)
    assert_match(/`colors :nothing/, error.message)
  end

  def test_a_walk_needs_a_positive_number_of_steps
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        colors :city, %i[transparent red]
        color_walk(:city, from: :black, steps: 0)
      end
    end

    assert_match(/steps:/, error.message)
  end
end
