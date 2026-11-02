# frozen_string_literal: true

require "test_helper"

# A GAME'S RULES AS FAST AS THE MACHINE CAN PLAY THEM. Every pass ends with the numbers the whole game
# ends it with on the interpreter, read a question at a time from a program that says nothing else.
class TestRulesRun < Minitest::Test
  RulesRun = VBlank::IR::Backends::Native::RulesRun
  Reference = VBlank::IR::Backends::Reference

  # Variables, a list, a pool and random numbers, all moved by a button, with drawing among them.
  private def game
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      seed 11
      trail = list :trail, capacity: 8, width: :half, full_of: 0
      dots = pool :dot, x: 0, capacity: 4
      dots.spawn x: 3
      score = var :score, 0
      luck = var :luck, 0
      game_loop do
        clear_screen :black
        score += 1 if held(:a)
        luck += rand(1..6)
        trail[score % 8] = luck
        dots.each { |dot| dot.x += 2 }
        draw_number score, 8, 8, :white
      end
    end
    b.finalize_program
    b.program
  end

  private def presses(frame) = frame.odd? ? [:a] : []

  private def numbers_of_each_pass(run, frames)
    seen = []
    run.input_each_frame do |frame|
      seen << [run[:score], run[:luck], run.list(:trail).to_a, run.pool(:dot, :x).to_a]
      presses(frame)
    end
    run.run(game, frames: frames)
    seen
  end

  def test_every_pass_ends_with_the_numbers_the_interpreter_plays_the_whole_game_to
    assert_equal numbers_of_each_pass(Reference.new, 30), numbers_of_each_pass(RulesRun.new, 30)
  end

  def test_the_numbers_are_there_when_the_run_has_ended
    run = RulesRun.new
    run.hold(:a)
    run.run(game, frames: 5)

    assert_equal 5, run[:score]
  end

  def test_a_game_that_stops_itself_ends_the_run
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      done = var :done, 0
      done += 1
      halt
    end
    b.finalize_program

    assert_equal 1, RulesRun.new.run(b.program, frames: 5)[:done]
  end

  def test_a_run_of_nothing_to_see_says_so_when_asked_for_a_picture
    run = RulesRun.new.run(game, frames: 2)

    assert_raises(VBlank::IR::Backends::Native::HeadlessRun::CannotAnswer) { run.screen }
  end
end
