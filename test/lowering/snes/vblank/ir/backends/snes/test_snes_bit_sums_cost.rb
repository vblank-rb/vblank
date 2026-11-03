# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT A STEP ALONG A MAP OF PACKED CELLS COSTS, read off the running cartridge. The answers are
# test_bit_operations's and test_list's; these are about the time.
class TestSNESBitSumsCost < Minitest::Test
  # A blast walking out along four arms of a map held in a list of halves, sixteen times a pass: a
  # step along the arm, the cell read and kept to 16 bits, its kind compared under a mask, and
  # fields taken out of it by shifts. Shifting a bit at a time in the runtime, a pass of this took
  # two frames.
  ARMS = VBlank.game("ARMS", consoles: %i[snes]) do
    grid = list :grid, capacity: 256, width: :half, full_of: 0
    steps = table :steps, [1, -1, 16, -16]
    hits = 0
    kinds = 0
    cell = 0
    item = 0
    look = 0x0300
    repeat(256) { |i| grid[i] = (i * 37) & 0x0FFF }
    func(:blast_arms) do
      repeat(4) do |way|
        cell = 120
        repeat(6) do
          cell += steps[way]
          item = grid[cell] & 0xFFFF
          if (item & 0x0F00) == (look & 0x0F00)
            hits += 1
            grid[cell] = item | 0x8000
          end
          kinds = (item >> 8) & 15
          kinds += (item << 2) >> 6
        end
      end
    end
    game_loop { repeat(2) { call :blast_arms } }
  end

  private def profile(game) = rom_of(game).profile(out: StringIO.new, settle: 10, frames: 20)
  private def rom_of(game) = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)

  # What the passes measured do is the interpreter's, every variable and list on every pass.
  def test_the_measured_game_plays_as_the_interpreter_does
    run = VBlank::IR::Backends::SNES::CheckedRun.new.run(ARMS.program(console: :snes), frames: 4)

    assert_operator run[:hits], :>, 0
  end

  def test_a_heavy_pass_of_masks_and_shifts_fits_a_frame
    assert_equal({ 1 => 20 }, profile(ARMS).passes_by_frames)
  end

  def test_a_shift_by_a_written_count_calls_no_runtime_routine
    routines = profile(ARMS).runtime.map { |spent| spent.routine.to_s }

    assert_empty routines.grep(/\Art_sh[lr]32/)
  end
end
