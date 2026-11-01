# frozen_string_literal: true

require "test_helper"
require "stringio"

# WORK MEMORY STARTS AT NOUGHT, ALL OF IT. A console's memory holds no such thing at power-on (the
# emulator fills it with stripes of ones and noughts), and what the framework keeps for itself is
# never told a first value, so a game that fills the low half and spills into the banked one reads
# its own counters as -1 unless power-on has cleared that half too.
class TestGBCWorkMemory < Minitest::Test
  private def rom(kind)
    VBlank.build("WORKMEM", console: :gbc, out: StringIO.new, err: StringIO.new) do
      screen kind
      if kind == :tiled
        image(:dot, "#" => :white) { (["#" * 8] * 8).join("\n") }
        sprite :dot, at: [8, 8]
      end
      game_loop { wait_vblank }
    end
  end

  private def bytes_left_over(built)
    reader = VBlank::Diagnostics::Verifier.new(built, frames: 4, vars: built.var_addresses)
    (0xDE00...0xE000).reject { |address| reader.mem8(address).zero? }
  end

  def test_the_banked_half_starts_at_nought_on_a_tiled_screen
    assert_empty bytes_left_over(rom(:tiled))
  end

  def test_the_banked_half_starts_at_nought_on_a_painted_screen
    assert_empty bytes_left_over(rom(:bitmap))
  end
end
