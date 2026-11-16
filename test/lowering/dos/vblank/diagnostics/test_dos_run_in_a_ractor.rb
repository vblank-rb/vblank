# frozen_string_literal: true

require "test_helper"
require "ractor_workers"

# A DOS program played inside a Ractor worker, as a game's suite under minitest-ractor plays one, gets
# what the same program played on the main Ractor gets. The DOS run plays its tests on the main Ractor,
# so the worker is started here by hand.
class TestDOSRunInARactor < Minitest::Test
  include RactorWorkers

  # What one play of the program found: the picture, a number read by name, and the date the pinned
  # clock gave.
  Reading = Data.define(:picture, :steps, :x, :year)

  # A box moved by the right button over a blue field, and a number counted up each pass: something in
  # the picture, in memory and from the keyboard at once. In a module, because a Ractor's block cannot
  # reach a test's methods.
  module BoxOnAField
    module_function

    def reading
      program = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :dos)).tap do |b|
        b.instance_eval(&game)
        b.finalize_program
      end.program
      run = VBlank::IR::Backends::DOS::HeadlessRun.new.hold(:right).run(program, frames: 30)
      Reading.new(picture: run.screen.shown, steps: run.raw_var(:steps), x: run.raw_var(:x), year: run.raw_var(:year))
    end

    def game
      proc do
        screen :bitmap
        steps = var :steps, 7
        x = var :x, 30
        year = var :year, 0
        now = clock
        game_loop do
          steps += 1
          x += 1 if held(:right)
          year = now.year
          clear_screen :blue
          fill_rect x, 40, 8, 8, :white
        end
      end
    end
  end

  def test_a_worker_reads_the_picture_and_memory_the_main_ractor_reads
    on_main = BoxOnAField.reading
    in_worker = value_raising_its_cause(without_the_experimental_warning { Ractor.new { BoxOnAField.reading } })

    assert_operator on_main.steps, :>, 7, "the count went up"
    assert_operator on_main.x, :>, 30, "the box moved right"
    assert_equal on_main, in_worker
  end

  # Two machines in two workers at once each keep to their own program: each has a copy of the core of
  # its own, and nothing of one is the other's.
  def test_two_workers_at_once_each_read_what_one_alone_reads
    alone = BoxOnAField.reading
    together = without_the_experimental_warning { Array.new(2) { Ractor.new { BoxOnAField.reading } } }
                 .map { |ractor| value_raising_its_cause(ractor) }

    together.each { |reading| assert_equal alone, reading }
  end
end
