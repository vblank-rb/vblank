# frozen_string_literal: true

require "test_helper"
require "long_list_tests"

# A list of more than 65,535 slots of a byte on the Advance's own cartridge, read off the running
# console's variables in the emulator, holding the readings the interpreter holds (LongListGames in
# test/long_list_tests.rb). The list goes in the roomy memory, and its length and its first item's
# place are variables of a word each.
class TestLongListOnTheAdvanceCartridge < Minitest::Test
  def test_a_list_of_more_than_65535_slots_plays_as_the_interpreter_plays_it
    rom = VBlank.build("LONG LIST", console: :gba, out: StringIO.new, err: StringIO.new, profile: false,
                                    &LongListGames.game(:byte))
    v = assert_emulator_loads_rom(rom, frames: 200, vars: rom.var_addresses)

    assert_equal LongListGames.expected(:byte), LongListGames::READINGS.map { |name| v.var(name) }, "on the Advance's cartridge"
  end
end
