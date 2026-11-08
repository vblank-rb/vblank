# frozen_string_literal: true

require "test_helper"

# A viewer the game moves and turns as it runs: its spot and its three arrows, read back as the
# game's numbers, fractions where they hold one. What a moving viewer draws is in
# test/console/gba/examples/test_cube3d_example.rb.
class TestViewer < Minitest::Test
  ONE = 1

  # The smallest step a fraction keeps: a sixty-five-thousand-five-hundred-and-thirty-sixth.
  STEP = Rational(1, 1 << 16)

  private def part(name) = VBlank::Messages::MadeNames.make(:viewer_part, viewer: :eye, part: name)

  # A game whose viewer the block changes on every pass, handed the viewer and how many passes
  # went before this one.
  private def game(&block)
    builder = VBlank::Builder.new
    builder.instance_eval do
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      passes = var :passes, 0
      game_loop do
        instance_exec(eye, passes, &block)
        passes += 1
      end
    end
    builder.finalize_program
    builder.program
  end

  private def numbers(played, *names) = names.map { |name| played[part(name)] }

  def test_moving_ahead_moves_the_spot_along_the_way_it_faces
    played = game_player.run(game { |eye| eye.move :ahead, by: 0.5 }, frames: 4)

    assert_equal 0, played[part(:x)]
    assert_operator played[part(:z)], :>=, ONE, "at least two passes of half a whole"
    assert_equal 0, played[part(:z)] % Rational(1, 2)
  end

  def test_turning_left_a_quarter_turn_faces_where_left_was
    played = game_player.run(game { |eye, passes| eye.turn :left, by: 90 if passes == 0 }, frames: 4)

    assert_equal [-ONE, 0, 0], numbers(played, :ahead_x, :ahead_y, :ahead_z)
    assert_equal [0, 0, ONE], numbers(played, :right_x, :right_y, :right_z)
  end

  def test_tipping_up_and_rolling_keep_the_arrows_square
    played = game_player.run(game { |eye, passes| eye.turn :up, by: 90 if passes == 0 }, frames: 4)

    assert_equal [0, ONE, 0], numbers(played, :ahead_x, :ahead_y, :ahead_z)
    assert_equal [0, 0, -ONE], numbers(played, :up_x, :up_y, :up_z)

    rolled = game_player.run(game { |eye, passes| eye.roll :left, by: 90 if passes == 0 }, frames: 4)

    assert_equal [-ONE, 0, 0], numbers(rolled, :up_x, :up_y, :up_z)
    assert_equal [0, ONE, 0], numbers(rolled, :right_x, :right_y, :right_z)
  end

  # Every turn rounds, so without squaring up the arrows would drift. Turned a degree at a time
  # all the way round, they come back to where they started, of length one and square.
  def test_many_small_turns_come_back_round_square_and_of_length_one
    played = game_player.run(game do |eye|
      eye.turn :right, by: 1
      eye.roll :left, by: 1
    end, frames: 362)

    ahead = numbers(played, :ahead_x, :ahead_y, :ahead_z)
    up = numbers(played, :up_x, :up_y, :up_z)
    right = numbers(played, :right_x, :right_y, :right_z)
    [ahead, up, right].each do |arrow|
      assert_in_delta 1, arrow.sum { |n| n * n }, Rational(1, 100), "length one"
    end
    assert_in_delta 0, ahead.zip(up).sum { |a, b| a * b }, Rational(1, 100), "ahead square to up"
    assert_in_delta 0, ahead.zip(right).sum { |a, b| a * b }, Rational(1, 100), "ahead square to right"
  end

  def test_at_and_face_set_the_viewer_from_numbers_the_game_works_out
    played = game_player.run(game do |eye|
      eye.at eye.spot[0] + 1.5, 2.0, -3
      eye.face right: [0.0, 0.0, 1.0], up: [0.0, 1.0, 0.0], ahead: [-1.0, 0.0, 0.0]
    end, frames: 3)

    assert_operator played[part(:x)], :>=, 3 * ONE
    assert_equal [2 * ONE, -3 * ONE], numbers(played, :y, :z)
    assert_equal [-ONE, 0, 0], numbers(played, :ahead_x, :ahead_y, :ahead_z)
  end

  ARROWS = %i[right_x right_y right_z up_x up_y up_z ahead_x ahead_y ahead_z].freeze

  # A game that makes one turn of +turns+ ([kind, direction, degrees] each) on each of its first
  # passes: by the number written in the game, or (+worked_out+) by a variable the game sets to
  # it on that pass, a whole one or (+fraction+) one that holds a fraction.
  private def turning_game(turns, worked_out:, fraction: false)
    builder = VBlank::Builder.new
    builder.instance_eval do
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      passes = var :passes, 0
      spin = var :spin, fraction ? 0.0 : 0
      game_loop do
        turns.each_with_index do |(kind, direction, degrees), k|
          if_eq(:passes, k) do
            spin.store!(degrees)
            by = worked_out ? spin : degrees
            kind == :turn ? eye.turn(direction, by: by) : eye.roll(direction, by: by)
          end
        end
        passes += 1
      end
    end
    builder.finalize_program
    builder.program
  end

  # The sines a turn by a worked-out angle reads are the ones a written whole number of degrees
  # is turned by, so the two come out the same to the last bit: the wrong way round, past a whole
  # turn, below nought, for a roll, and past the most degrees a fraction can hold.
  def test_a_turn_by_a_whole_number_the_game_works_out_matches_the_same_number_written
    turns = [[:turn, :left, 7], [:turn, :right, -13], [:turn, :up, 370], [:roll, :right, -400], [:turn, :down, 90],
             [:roll, :left, 725], [:turn, :right, 40_000]]
    worked_out = game_player.run(turning_game(turns, worked_out: true), frames: turns.length + 2)
    written = game_player.run(turning_game(turns, worked_out: false), frames: turns.length + 2)

    ARROWS.each { |name| assert_equal written[part(name)], worked_out[part(name)], name }
    refute_equal ONE, worked_out[part(:ahead_z)], "the viewer did turn"
  end

  # A fraction of a degree is stepped to between the sines of the whole degrees either side.
  def test_a_turn_by_a_fraction_of_a_degree_the_game_works_out_turns_that_far
    played = game_player.run(turning_game([[:turn, :right, 2.5]], worked_out: true, fraction: true), frames: 3)
    radians = 2.5 * Math::PI / 180

    assert_in_delta Math.sin(radians), played[part(:ahead_x)], 8 * STEP
    assert_in_delta Math.cos(radians), played[part(:ahead_z)], 8 * STEP
    assert_equal 0, played[part(:ahead_y)]
  end

  # Turning left by minus 362 and a half degrees is turning right by two and a half.
  def test_a_negative_fraction_past_a_whole_turn_is_the_same_turn_the_other_way
    left = game_player.run(turning_game([[:turn, :left, -362.5]], worked_out: true, fraction: true), frames: 3)
    right = game_player.run(turning_game([[:turn, :right, 2.5]], worked_out: true, fraction: true), frames: 3)

    ARROWS.each { |name| assert_equal right[part(name)], left[part(name)], name }
  end

  def test_a_turn_by_something_that_is_not_a_number_is_refused
    error = assert_raises(ArgumentError) { game { |eye| eye.turn :left, by: "two" } }

    assert_match(/degrees/, error.message)
  end

  def test_a_direction_that_is_not_one_is_refused
    error = assert_raises(ArgumentError) { game { |eye| eye.move :sideways, by: 1.0 } }

    assert_match(/:ahead, :back/, error.message)
  end
end
