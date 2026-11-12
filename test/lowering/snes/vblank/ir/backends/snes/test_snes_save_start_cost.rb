# frozen_string_literal: true

require "test_helper"

# A GAME THAT KEEPS A SMALL SAVE RECORD, as a high-score table is: a list of 61 bytes, loaded at
# power-on. Setting the record up fills the table of places and the record's own lists, and writes
# and sums the table, before the game's first pass. On the Super Nintendo that work must cost no
# more than one frame beyond what the same game with no record takes, as on the Color
# (test_gbc_power_on.rb). Counted by the frames the console spent before its first pass ended.
class TestSNESSaveStartCost < Minitest::Test
  private def saving_game(record: true)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :bitmap
      if record
        scores = list :scores, capacity: 61, width: :byte
        high = save_data(:high, copies: 1) { keep scores }
        high[0].load
      end
      passes = 0
      game_loop { passes += 1 }
    end
    b.finalize_program
    b.program
  end

  # The frames the first pass of +program+ took, setting up included.
  private def first_pass_frames(program, save: SaveImage.new)
    VBlank::IR::Backends::SNES::HeadlessRun.new(save: save).run(program, frames: 2).frames_took(1)
  end

  def test_a_small_save_record_on_an_empty_chip_starts_a_frame_after_a_game_with_none
    without = first_pass_frames(saving_game(record: false))

    assert_operator first_pass_frames(saving_game), :<=, without + 1, "the first pass, on an empty chip"
  end

  def test_a_small_save_record_with_a_good_save_starts_a_frame_after_a_game_with_none
    program = saving_game
    good = Reference.save_into(SaveImage.new, program, :high, 0, scores: (1..61).to_a)
    without = first_pass_frames(saving_game(record: false))

    assert_operator first_pass_frames(program, save: good), :<=, without + 1, "the first pass, with a good save"
  end
end
