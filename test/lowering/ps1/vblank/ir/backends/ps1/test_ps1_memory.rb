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

  # Three lists of 240K each, a third of main RAM between them: the program is small, so the rest of
  # the 2 megabytes is the game's. The first slot of the
  # first and the last slot of the last are written and read back.
  BIG_LIST_SLOTS = 60_000
  BIG_LISTS = VBlank.game("BIG LISTS", consoles: %i[ps1]) do
    lists = Array.new(3) { |which| list :"big#{which}", capacity: BIG_LIST_SLOTS }
    first = var :first, 0
    last = var :last, 0
    filled = var :filled, 0
    game_loop do
      if filled.zero?
        lists.each { |big| repeat(BIG_LIST_SLOTS) { |at| big.push at + 7 } }
        filled = 1
      end
      first = lists.first[0]
      last = lists.last[BIG_LIST_SLOTS - 1]
    end
  end
  BIG_LISTS_BYTES = 3 * BIG_LIST_SLOTS * 4

  # Lists that fit the console's memory alone and not beside the program that reads them.
  TOO_BIG = VBlank.game("TOO BIG", consoles: %i[ps1]) do
    lists = Array.new(8) { |which| list :"big#{which}", capacity: 62_200 }
    game_loop { lists.each { |big| big.push 1 } }
  end

  def test_a_small_program_leaves_the_rest_of_memory_to_what_the_game_keeps
    played = PS1::CheckedRun.new.run(BIG_LISTS.program, frames: 3)

    assert_equal [7, BIG_LIST_SLOTS + 6], [played[:first], played[:last]]
  end

  def test_the_program_is_loaded_straight_after_what_the_game_keeps
    rom = BIG_LISTS.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    load_at = rom.bytes.byteslice(VBlank::Cartridge::PS1EXE::LOAD_AT, 4).unpack1("V")

    assert_operator load_at, :>, PS1::Memory::FIRST + BIG_LISTS_BYTES
    assert_operator load_at, :<, PS1::Memory::FIRST + BIG_LISTS_BYTES + 0x4000
  end

  def test_a_game_too_big_for_memory_is_refused_saying_by_how_much
    error = assert_raises(VBlank::BuildError) do
      TOO_BIG.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    end

    assert_match(/does not fit in the PlayStation's memory/, error.message)
    assert_match(/\d[\d,]* bytes too many/, error.message)
    assert_match(/smaller capacities/, error.message)
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
