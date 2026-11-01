# frozen_string_literal: true

require "test_helper"
require "stringio"

# A SCRIPT THAT CHOOSES ITS PRESSES FROM THE GAME. The prize here jumps about by itself, so what to
# press depends on where it is on that frame, and no list of presses written down beforehand could
# catch it. A steering script catches it three times, and the tape it wrote does it again with no
# block at all.
class TestPlaythroughSteering < Minitest::Test
  private def prize_game(console = :gba)
    VBlank.build("PRIZE", console: console, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :white) { (["#" * 8] * 8).join("\n") }
      hero = sprite :dot, at: [0, 8]
      ticks = var :ticks, 0
      me = var :me, 0
      prize = var :prize, 7
      caught = var :caught, 0
      game_loop do
        ticks += 1
        me += 1 if held(:right)
        me -= 1 if held(:left)
        if me == prize
          caught += 1
          prize = ((prize * 7) + ticks) % 31
        end
        hero.move_to me, 8
      end
    end
  end

  private def catching
    VBlank.playthrough "catch three" do
      steer "catch the prize three times", within: 500 do |game|
        next :done if game.var(:caught) >= 3

        if game.var(:me) < game.var(:prize) then [:right]
        elsif game.var(:me) > game.var(:prize) then [:left]
        else []
        end
      end
      moment :caught
    end
  end

  def test_a_steered_script_plays_a_game_that_moves_by_itself_to_its_end
    played = catching.play(prize_game)

    assert_equal 3, played.game.var(:caught)
    assert_equal played.moments[:caught], played.frames
  end

  # The point of a tape: it needs no block and no reader, and ends where the script ended.
  def test_the_tape_of_a_steered_script_plays_back_the_same
    rom = prize_game
    played = catching.play(rom)
    again = VBlank::Playthroughs::Tape.parse(played.tape.to_s).play(rom)

    assert_equal played.frames, again.frames
    assert_equal played.moments, again.moments
    assert_equal played.pictures, again.pictures
    %i[me prize caught ticks].each { |name| assert_equal played.game.var(name), again.game.var(name), name }
  end

  def test_it_works_on_the_color
    assert_equal 3, catching.play(prize_game(:gbc)).game.var(:caught)
  end

  # Buttons answered are held for one frame: a frame is not a trip round the game's loop.
  def test_the_buttons_are_held_for_one_frame
    played = VBlank.playthrough("one frame") do
      steps = 0
      steer "move four frames" do
        steps += 1
        steps > 4 ? :done : [:right]
      end
    end.play(prize_game)

    assert_equal 4, played.frames
    assert_equal [[1..4, [:right]]], played.tape.presses_within(1..4).map { |stretch| [stretch.frames, stretch.buttons] }
  end

  def test_a_step_that_never_ends_gives_up_with_its_words_and_a_picture
    never = VBlank.playthrough("no end") { steer("reach the moon", within: 5) { [] } }
    error = assert_raises(VBlank::Playthroughs::GaveUp) { never.play(prize_game) }

    assert_match(/tried to reach the moon/, error.message)
    assert_equal 5, error.frame
    assert_path_exists error.picture
  end

  def test_a_button_the_console_does_not_have_names_the_step
    wrong = VBlank.playthrough("wrong") { steer("jump") { [:x] } }
    error = assert_raises(ArgumentError) { wrong.play(prize_game) }

    assert_match(/steer "jump"/, error.message)
    assert_match(/does not have/, error.message)
  end

  def test_an_answer_that_is_neither_buttons_nor_done_names_the_step
    wrong = VBlank.playthrough("wrong") { steer("jump") { :up } }
    error = assert_raises(ArgumentError) { wrong.play(prize_game) }

    assert_match(/steer "jump"/, error.message)
    assert_match(/list of the buttons/, error.message)
  end

  def test_a_step_with_no_block_is_refused_where_it_is_declared
    error = assert_raises(ArgumentError) { VBlank.playthrough("none") { steer "jump" } }

    assert_match(/has no block/, error.message)
  end
end
