# frozen_string_literal: true

require "test_helper"

# A viewer the game moves and turns as it runs: its spot and its three arrows, read back as the
# numbers they are. What a moving viewer draws is in test/console/gba/examples/test_cube3d_example.rb.
class TestViewer < Minitest::Test
  ONE = 1 << 16

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
    assert_equal 0, played[part(:z)] % (ONE / 2)
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
      assert_in_delta ONE * ONE, arrow.sum { |n| n * n }, ONE * ONE / 100, "length one"
    end
    assert_in_delta 0, ahead.zip(up).sum { |a, b| a * b }, ONE * ONE / 100, "ahead square to up"
    assert_in_delta 0, ahead.zip(right).sum { |a, b| a * b }, ONE * ONE / 100, "ahead square to right"
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

  def test_a_turn_by_a_number_the_game_works_out_is_refused
    error = assert_raises(ArgumentError) do
      game do |eye|
        speed = var :speed, 2
        eye.turn :left, by: speed
      end
    end

    assert_match(/does not turn by a number the game works out/, error.message)
  end

  def test_a_direction_that_is_not_one_is_refused
    error = assert_raises(ArgumentError) { game { |eye| eye.move :sideways, by: 1.0 } }

    assert_match(/:ahead, :back/, error.message)
  end
end
