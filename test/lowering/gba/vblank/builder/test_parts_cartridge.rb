# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_parts"

# `start_over` on the Advance's cartridge: the game of test/all/vblank/builder/test_parts.rb,
# played in the emulator and held to the interpreter (which is game_player on the gba run).
class TestPartsCartridge < Minitest::Test
  include PartGames
  include VBlank::Console::Hardware

  def test_the_console_starts_the_play_over_the_way_the_interpreter_does
    buttons = %i[a b a]
    oracle = played(game_that_starts_again, *buttons)
    keys = { a: KEY_A, b: KEY_B }
    schedule = presses(*buttons).transform_values { |button| keys.fetch(button) }
    rom = assemble_rom(game_that_starts_again, name: "AGAIN")
    v = assert_emulator_loads_rom(rom, frames: (buttons.length * 2) + 6, keys: ->(f) { schedule.fetch(f, 0) },
                                       vars: rom.var_addresses)

    (PLAY_VARIABLES + %i[best games shape first_roll next_roll]).each do |name|
      assert_equal oracle[name], v.var(name), name.to_s
    end
  end
end
