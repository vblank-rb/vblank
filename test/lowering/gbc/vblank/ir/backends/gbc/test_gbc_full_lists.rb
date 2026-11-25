# frozen_string_literal: true

require "test_helper"

# A list of bytes declared full, on the Color. A game keeps its score and its queues this way, and
# declares them before its first frame, so whatever the fill costs is a late start for the whole
# game. It has to cost a store and a count for each byte, not the walk one item takes alone.
class TestGBCFullLists < Minitest::Test
  # A game that declares a list of +slots+ bytes, full if +full+ says so, and notes its first pass.
  private def counting_game(slots, full:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      board = full ? list(:board, capacity: slots, width: :byte, full_of: 0) : list(:board, capacity: slots, width: :byte)
      board.push 1 unless full
      passes = 0
      kept = 0
      game_loop do
        kept = board[0]
        passes += 1
      end
    end
    b.finalize_program
    b.program
  end

  # The frame the game's first pass is first seen on.
  private def first_pass_frame(program)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "FULL")
    v = VBlank::Diagnostics::Verifier.new(rom, frames: 1, vars: rom.built.variables)
    frame = 1
    until v.var(:passes).positive?
      flunk "no pass ran in 200 frames" if frame == 200
      v.step
      frame += 1
    end
    frame
  end

  def test_a_few_hundred_bytes_declared_full_cost_no_frame
    assert_equal first_pass_frame(counting_game(216, full: false)), first_pass_frame(counting_game(216, full: true))
  end

  def test_two_thousand_bytes_declared_full_cost_a_frame_at_most
    assert_operator first_pass_frame(counting_game(2000, full: true)), :<=, first_pass_frame(counting_game(2000, full: false)) + 1
  end

  # Runs of bytes past the first 256, a run at the end of the list and a value below nought, read
  # back as the interpreter reads them.
  def test_a_run_of_bytes_is_filled_as_the_interpreter_fills_it
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :bitmap
      board = list :board, capacity: 600, width: :byte, full_of: 7
      board.fill(-2, from: 250, count: 300)
      board.fill 200, from: 590, count: 10
      total = 0
      repeat(600) { |i| total += board[i] }
      game_loop { wait_vblank }
    end
    b.finalize_program

    assert_equal (7 * 290) - (2 * 300) - (56 * 10), game_player.run(b.program, frames: 2)[:total]
  end
end
