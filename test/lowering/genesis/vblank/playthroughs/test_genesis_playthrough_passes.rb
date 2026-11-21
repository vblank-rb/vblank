# frozen_string_literal: true

require "test_helper"
require "stringio"

# A playing counted in passes on a Genesis cartridge: the reader counts the game's passes from the
# runtime's own count, so a tape of passes recorded on the interpreter reads the same buttons on the
# same pass on the cartridge, though some of its passes take several frames.
class TestGenesisPlaythroughPasses < Minitest::Test
  runs_on_the_main_ractor! # a run in another process hangs inside a Ractor

  HEAVY = 3000

  # +heard+ sums what each pass read times the pass's number, so a button read one pass early or late
  # changes it.
  private def cartridge
    @cartridge ||= VBlank.build("PASSES", console: :genesis, out: StringIO.new, err: StringIO.new) do
      pass = var :pass, 0
      seen = var :seen, 0
      spent = var :spent, 0
      heard = var :heard, 0
      game_loop do
        pass += 1
        seen = 0
        seen = 1 if held(:right)
        seen += 2 if pressed(:a)
        heard += seen * pass
        repeat(HEAVY) { spent += 1 } if (pass & 3) == 0
      end
    end
  end

  private def script
    VBlank::Playthroughs::Playthrough.new("presses") do
      wait frames: 2
      hold :right, frames: 3
      press :a
      wait frames: 3
      hold :right, frames: 7
      press :a
      wait frames: 6
    end
  end

  def test_a_tape_of_passes_reads_the_same_buttons_on_the_cartridge
    recorded = script.play(cartridge, in_passes: true, on: "interpreter").tape
    on_the_cartridge = recorded.play(cartridge).game
    wanted = recorded.play(cartridge, on: "interpreter").game

    assert_operator recorded.in_frames_on(cartridge).frames, :>, recorded.frames, "some passes took several frames"
    assert_operator wanted.var(:heard), :>, 0
    assert_equal [wanted.var(:pass), wanted.var(:heard)], [on_the_cartridge.var(:pass), on_the_cartridge.var(:heard)]
  end
end
