# frozen_string_literal: true

require "test_helper"

# A LIST READ OR WRITTEN IN A BUSY LOOP. A game's blast, or any walk across a map held in a list,
# reads and writes a list many times a pass, so an item has to cost a few instructions rather than
# a trip through the runtime. Counted by how many fit a frame, read off the console.
class TestSNESListReads < Minitest::Test
  STEPS_A_FRAME = 200

  private def looping(&step)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      cells = list :cells, capacity: 16, width: :half, full_of: 1
      at = var :at, 3
      seen = var :seen, 0
      game_loop do
        repeat(STEPS_A_FRAME) { step.call(self, cells, at, seen) }
      end
    end
    b.finalize_program
    b.program
  end

  private def assert_keeps_a_frame_a_pass(program)
    run = VBlank::IR::Backends::SNES::HeadlessRun.new.run(program, frames: 20)

    assert_empty (8...18).select { |pass| run.frames_took(pass) > 1 }
  end

  def test_reading_an_item_takes_a_few_instructions
    assert_keeps_a_frame_a_pass(looping { |game, cells, at, _seen| game.send(:record, Build.set(:seen, cells[at].node)) })
  end

  def test_writing_an_item_takes_a_few_instructions
    assert_keeps_a_frame_a_pass(looping { |_game, cells, at, seen| cells[at] = seen })
  end

  Build = VBlank::IR::Build
end
