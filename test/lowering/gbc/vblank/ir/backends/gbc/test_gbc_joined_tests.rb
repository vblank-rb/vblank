# frozen_string_literal: true

require "test_helper"

# TWO TESTS JOINED BY `||` OR `&&` are a compare and a jump each, as on the console's own games, so
# a game can ask them many times a frame. What they mean does not change: the right side is left
# unasked only where the interpreter could not tell.
class TestGBCJoinedTests < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  private def game_of(&game)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:dot, "#" => :white) { "##\n##" }
      sprite :dot, at: [8, 8]
      instance_eval(&game)
    end
    b.finalize_program
    b.program
  end

  # A pass of two hundred joined tests, on narrow variables, keeps a frame a pass.
  def test_many_joined_tests_keep_a_frame_a_pass
    program = game_of do
      frames = var :frames, 0, width: :byte
      seconds = var :seconds, 3, width: :byte
      hits = var :hits, 0
      shown = var :shown, 0
      game_loop do
        200.times { hits += 1 if frames != 0 || seconds != 0 }
        frames += 1 unless frames == 100 || seconds < 0
        shown = frames_since_power_on
      end
    end
    frames = [20, 80].map { |passes| GBC::HeadlessRun.new.run(program, frames: passes)[:shown] }

    assert_equal 60, frames.last - frames.first
  end

  def test_every_shape_of_join_agrees_with_the_interpreter
    GBC::CheckedRun.new.run(shapes_game, frames: 40)
    pass
  end

  private def shapes_game
    game_of do
      a = var :a, 0, width: :byte
      b = var :b, 0, width: :half
      c = var :c, 0
      hits = Array.new(8) { |n| var :"hit#{n}", 0 }
      game_loop do
        a += 1
        b += 3
        c += 7
        hits[0] += 1 if a == 3 || b > 30
        hits[1] += 1 if a < 5 && b != 9
        hits[2] += 1 unless a == 3 || c > 70
        hits[3] += 1 unless a < 5 && c != 14
        hits[4] += 1 if (a == 1 || a == 2) && (b < 12 || c > 100)
        hits[5] += 1 if (a == 1 && b == 3) || (a == 9 && c == 63)
        hits[6] += 1 if a != 2 || b != 6 || c != 14
        hits[7] = 0
        hits[7] += 1 while (hits[7] < 3 || hits[7] == 3) && hits[7] < 4
      end
    end
  end

  # A number drawn at random on the right is drawn whether or not it is asked, as the interpreter's.
  def test_a_chance_on_the_right_agrees_with_the_interpreter
    program = game_of do
      a = var :a, 0, width: :byte
      hits = var :hits, 0
      other = var :other, 0
      seed 7
      game_loop do
        a += 1
        hits += 1 if ((a & 1) == 1) | chance(50)
        other += rand(1..6)
      end
    end
    GBC::CheckedRun.new.run(program, frames: 30)
    pass
  end

  # A list read past its end stops the game even where the left side has decided already.
  def test_a_list_read_on_the_right_still_stops_the_game
    [:or, :and].each do |join|
      error = assert_raises(VBlank::IR::ProgramError) do
        GBC::HeadlessRun.new.run(stopped_game(join), frames: 5)
      end
      assert_match(/out of range/, error.message)
    end
  end

  private def stopped_game(join)
    game_of do
      xs = list :xs, capacity: 4, width: :byte
      xs.push 1
      n = var :n, 3
      a = var :a, 1
      hits = var :hits, 0
      game_loop do
        if join == :or
          hits += 1 if (a == 1) | (xs[n] == 0)
        else
          hits += 1 if (a == 2) & (xs[n] == 0)
        end
      end
    end
  end
end
