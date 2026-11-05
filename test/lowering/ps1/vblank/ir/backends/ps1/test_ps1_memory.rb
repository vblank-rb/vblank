# frozen_string_literal: true

require "test_helper"
require "stringio"

# Where a PlayStation program keeps its numbers (PS1::Memory): the ones read most in the scratchpad,
# the 1K inside the processor, as far as it goes, and the rest in main RAM.
class TestPS1Memory < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  MANY = 400

  # More variables than the scratchpad holds, each set to its own number and summed every pass: the
  # ones past the scratchpad are in main RAM, and every one is read and written where it is.
  MORE_THAN_FITS = VBlank.game("MANY NUMBERS", consoles: %i[ps1]) do
    numbers = Array.new(MANY) { |i| var :"number#{i}", i }
    total = var :total, 0
    game_loop do
      total = 0
      numbers.each { |number| total += number }
      numbers.first.store!(numbers.first + 1)
    end
  end

  def test_the_scratchpad_is_given_out_first_and_main_ram_once_it_is_full
    memory = PS1::Memory.new
    fast = PS1::Memory::SCRATCHPAD_FIRST
    room = VBlank::Console::PS1Hardware::SCRATCHPAD_SIZE

    assert_equal fast, memory.reserve_scratchpad("a", room - 4)
    assert_equal fast + room - 4, memory.reserve_scratchpad("b", 4)
    assert_equal PS1::Memory::FIRST, memory.reserve_scratchpad("c", 4)
    assert_equal room, memory.scratchpad_used
  end

  def test_a_game_with_more_variables_than_the_scratchpad_holds_keeps_every_one
    rom = MORE_THAN_FITS.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    places = rom.built.variables.values

    assert(places.any? { |address| PS1::Memory.scratchpad?(address) }, "some are in the scratchpad")
    assert(places.any? { |address| !PS1::Memory.scratchpad?(address) }, "some are in main RAM")

    played = PS1::CheckedRun.new.run(MORE_THAN_FITS.program, frames: 3)

    assert_equal (0...MANY).sum + 2, played[:total]
  end
end
