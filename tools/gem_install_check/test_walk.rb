# frozen_string_literal: true

require "vblank/testing"
require_relative "walk"

# Played once per lowering (VBLANK_LOWERING): on the Color and the Super Nintendo the cartridge runs
# in its emulator, checked against the interpreter. The Advance's player is the interpreter, so its
# cartridge is played here too, by the reader.
class TestWalk < Minitest::Test
  include VBlank::Testing

  def test_holding_right_walks
    played = game_player.hold(:right).run(Walk.program(console: game_console), frames: 6)

    assert_equal 46, played[:x]
  end

  if VBlank::Testing.console == :gba
    def test_the_cartridge_draws_in_the_emulator
      reader = VBlank::Diagnostics::Verifier.new(Walk.build_rom(out: StringIO.new, err: StringIO.new, console: :gba))
      reader.step(10)

      assert_nil reader.only_color, "the screen should hold more than one colour"
    end
  end
end
