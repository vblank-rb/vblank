# frozen_string_literal: true

require "test_helper"

# The first games a DOS program plays, in DOSBox, held to the interpreter pass for pass (DOS::CheckedRun):
# every variable and every pixel of every pass must agree, or the run stops at the first pass that does not.
# Games that only use what every console does are in test/all, where this run plays them too; these are the
# first ones the lowering makes, and the edges of IR::Int32 the processor does differently.
class TestDOSCheckedRun < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  def test_a_game_that_clears_the_screen_plots_pixels_and_counts
    checked(frames: 12) do
      screen :bitmap
      clear_screen :blue
      count = var :count, 0
      steps = var :steps, 0
      game_loop do
        pixel 10, 10, :white
        pixel 319, 199, :red
        pixel 0, 0, :green
        count += 3
        steps = (steps + 7) % 200
      end
    end
  end

  def test_the_screen_ends_the_colour_it_was_cleared_to_and_has_the_pixel_on_it
    played = checked(frames: 3) do
      screen :bitmap
      clear_screen :green
      pixel 5, 6, :white
      halt
    end

    assert_equal VBlank::Graphics::Color.resolve(:white), played.screen.pixel(5, 6)
    assert_equal VBlank::Graphics::Color.resolve(:green), played.screen.pixel(0, 0)
  end

  # Wrapping, division by nought, by -1, shifts of 32 or more and a negative count: the numbers the
  # processor does not give the way IR::Int32 does without help.
  EDGES = [0, 1, -1, 7, -7, 31, 32, 33, 255, 65_535, 2_147_483_647, -2_147_483_648, 123_456_789, -98_765].freeze

  def test_every_operator_agrees_with_the_interpreter_on_the_numbers_that_break_a_processor
    EDGES.each_slice(4) do |lefts|
      checked(frames: 4) do
        plus = var :plus, 0
        minus = var :minus, 0
        times = var :times, 0
        divided = var :divided, 0
        modded = var :modded, 0
        shifted_left = var :shifted_left, 0
        shifted_right = var :shifted_right, 0
        anded = var :anded, 0
        ored = var :ored, 0
        xored = var :xored, 0
        less = var :less, 0
        same = var :same, 0
        both = var :both, 0
        either = var :either, 0
        left = var :left, 0
        right = var :right, 0
        game_loop do
          lefts.each do |a|
            EDGES.each do |b|
              left = a
              right = b
              plus = left + right
              minus = left - right
              times = left * right
              divided = left / right
              modded = left % right
              shifted_left = left << right
              shifted_right = left >> right
              anded = left & right
              ored = left | right
              xored = left ^ right
              less = (left < right) ? 1 : 0
              same = (left == right) ? 1 : 0
              both = ((left > 0) & (right > 0)) ? 1 : 0
              either = ((left > 0) | (right > 0)) ? 1 : 0
            end
          end
        end
      end
    end
  end

  def test_repeat_and_if_and_else_agree
    checked(frames: 5) do
      total = var :total, 0
      game_loop do
        repeat(5) { |i| total += i * 3 }
        if total > 40
          total -= 25
        else
          total += 1
        end
      end
    end
  end

  def test_a_game_that_halts_ends_the_run
    played = checked(frames: 20) do
      count = var :count, 0
      game_loop do
        count += 1
        halt if count == 4
      end
    end

    assert_equal 4, played[:count]
  end

  def test_a_step_the_build_does_not_make_yet_is_refused_by_name
    error = assert_raises(DOS::Lowering::NotMadeYet) do
      checked(frames: 2) do
        things = list :things, capacity: 4
        things.push 3
        game_loop { wait_vblank }
      end
    end

    assert_match(/does not make that yet/, error.message)
  end

  private

  def program_of(&game)
    VBlank.game("DOSGAME", consoles: %i[dos], &game).program(console: :dos)
  end

  def checked(frames:, &game) = DOS::CheckedRun.new.run(program_of(&game), frames: frames)
end
