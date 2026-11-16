# frozen_string_literal: true

require "test_helper"
require "power_on_frame_games"

# HOW LONG A COLOR CARTRIDGE TAKES FROM POWER-ON TO THE GAME'S FIRST PASS. Every Color game clears
# work memory and both banks of video memory before its first line, which a console's own games do
# in a frame or so with the fastest loop and the console's own copy (Runtime::Boot). What a game
# declares is set up after that, and takes what it takes. frames_since_power_on, read on the first
# pass, counts every frame setting up took, whatever the game's size.
class TestGBCSettingUp < Minitest::Test
  include PowerOnFrameGames

  # A game of +vars+ variables and +lists+ lists of 16 slots, each started at a number of its own.
  private def declaring_game(vars, lists)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled, backdrop: :black
      many = Array.new(vars) { |n| var :"v_#{n}", n + 1 }
      held = Array.new(lists) { |n| list :"l_#{n}", capacity: 16, full_of: n + 1 }
      passes = 0
      first = -1
      sum = 0
      game_loop do
        first = frames_since_power_on if passes == 0
        passes += 1
        sum = many.first(2).sum + held.first(2).sum { |list| list[0] }
      end
    end
    b.finalize_program
    b.program
  end

  # The memories cleared within the first frame: the first pass is seen on the second.
  def test_a_small_game_passes_first_on_the_second_frame
    frame, reading = first_pass_frame_and_reading(:gbc, declaring_game(2, 2))

    assert_equal [2, 1], [frame, reading]
  end

  # Seven hundred variables and forty lists, which keep both halves of work memory: two frames of
  # setting up more, and the first pass reads them all.
  def test_a_game_of_many_declarations_passes_first_by_the_fourth_frame
    frame, reading = first_pass_frame_and_reading(:gbc, declaring_game(700, 40))

    assert_operator frame, :<=, 4
    assert_equal frame - 1, reading
  end
end
