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
      big = list :big, capacity: 1000
      game_loop { wait_vblank if big.length == 0 }
    end
  end

  private def bytes_left_over(built)
    reader = VBlank::Diagnostics::Verifier.new(built, frames: 4, vars: built.var_addresses)
    (0xD800...0xE000).reject { |address| reader.mem8(address).zero? }
  end

  # A game's own variables that spill past the low half read nought from its first frame, as the
  # interpreter's do: the check against the interpreter from power-on finds them nowhere else.
  def test_variables_in_the_banked_half_agree_with_the_interpreter_from_power_on
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      many = Array.new(900) { |n| var :"many_#{n}", 0 }
      spilled = 0
      game_loop do
        many.each_slice(50) { |some| spilled += 1 if some.reduce(:+) == 0 }
      end
    end
    b.finalize_program

    assert_equal 18 * 3, game_player.run(b.program, frames: 3)[:spilled]
  end

  def test_the_banked_half_starts_at_nought_on_a_tiled_screen
    assert_empty bytes_left_over(rom(:tiled))
  end

  def test_the_banked_half_starts_at_nought_on_a_painted_screen
    assert_empty bytes_left_over(rom(:bitmap))
  end
end
