# frozen_string_literal: true

require "test_helper"
require "differential"

# WORDS NOBODY KNEW WHEN THE CARTRIDGE WAS BUILT: a name kept in a list and drawn with `draw_text`,
# a letter at a time, each at its own width.
class TestDrawTextFromAList < Minitest::Test
  include Differential

  WHITE = 0x7FFF
  BLACK = 0

  # A font whose letters are told apart by their widths: I a line, W as wide as three.
  private def name_game(&draw)
    test = self
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      font :thin do
        glyph "I", "#\n#"
        glyph "W", "###\n# #"
      end
      name = list :name, capacity: 8, width: :byte
      "IWI".each_byte { |code| name.push code }
      game_loop do
        clear_screen :black
        test.instance_exec(self, name, &draw)
      end
    end
    b.finalize_program
    b.program
  end

  private def lit(program, x, y) = game_player.run(program, frames: 3).screen.pixel(x, y) == WHITE

  def test_a_name_in_a_list_is_drawn_at_each_letters_own_width
    program = name_game { |b, name| b.draw_text name, 10, 20, :white, font: :thin }

    assert lit(program, 10, 20), "I"
    refute lit(program, 11, 20), "the gap after it"
    assert lit(program, 12, 20), "W's first column"
    assert lit(program, 14, 20), "W's last column"
    refute lit(program, 13, 21), "the hole in W"
    refute lit(program, 15, 20), "the gap after it"
    assert lit(program, 16, 21), "the last I, at its own place and not a fixed width's"
  end

  def test_the_console_draws_the_name_as_the_interpreter_does
    program = name_game { |b, name| b.draw_text name, 10, 20, :white, font: :thin }

    assert_backends_agree(program, frames: 3, name: "NAMES")
  end

  def test_from_and_length_pick_a_run_of_the_list
    program = name_game { |b, name| b.draw_text name, 10, 20, :white, font: :thin, from: 1, length: 1 }

    assert lit(program, 10, 20), "W's first column, where the run starts"
    assert lit(program, 12, 20), "W's last column"
    refute lit(program, 14, 20), "nothing of the I after it"
  end

  def test_the_place_can_be_worked_out_as_the_game_runs
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      name = list :name, capacity: 4, width: :byte
      across = var :across, 30
      name.push 65
      game_loop do
        clear_screen :black
        across += 1
        draw_text name, across, 20, :white
      end
    end
    b.finalize_program

    assert_equal WHITE, game_player.run(b.program, frames: 2).screen.pixel(32 + 2, 20)
  end

  def test_a_tiled_screen_is_pointed_at_a_canvas
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :tiled
        name = list :name, capacity: 4, width: :byte
        draw_text name, 10, 20, :white
      end
    end

    assert_match(/canvas/, error.message)
  end

  def test_a_place_only_known_from_the_words_is_refused
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        name = list :name, capacity: 4, width: :byte
        draw_text name, :center, 20, :white
      end
    end

    assert_match(/not known until the game runs/, error.message)
  end

  def test_from_is_refused_with_words_written_in_the_program
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        draw_text "HI", 10, 20, :white, from: 1
      end
    end

    assert_match(/list of character codes/, error.message)
  end
end
