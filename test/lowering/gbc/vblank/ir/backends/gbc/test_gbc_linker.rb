# frozen_string_literal: true

require "test_helper"

# A game too big for a Game Boy Color cartridge is refused in words about the game: which of its
# parts is too big, and what to do about it. A part that is the framework's own is the
# framework's fault, and stays an internal error with the linker's words.
class TestGBCLinker < Minitest::Test
  GBC = VBlank::IR::Backends::GBC
  Linker = GBC::Linker
  SM83 = GBC::SM83

  TABLES = SM83::Holding.new(what: "the game's tables", fix: "make its tables shorter")
  PICTURES = SM83::Holding.new(what: "the game's pictures", fix: "use fewer pictures")

  private def section(name, bytes, home:, holds: nil)
    asm = SM83.new(name, home: home, holds: holds)
    asm.label(name.tr(" ", "_"))
    asm.data_bytes(Array.new(bytes, 0))
    asm.section
  end

  private def link(*sections) = Linker.new(sections).link

  def test_a_game_part_too_big_for_the_part_always_in_view_is_named_with_its_fix
    error = assert_raises(Linker::TooBig) do
      link(section("runtime", 4000, home: :fixed), section("data", 14_000, home: :fixed, holds: TABLES))
    end

    assert_kind_of GBC::LoweringError, error
    assert_match(/does not fit in a Game Boy Color cartridge/, error.message)
    assert_match(/the game's tables take 14000 bytes/, error.message)
    assert_match(/To fix this, make its tables shorter\./, error.message)
  end

  def test_the_frameworks_own_code_too_big_for_the_part_always_in_view_is_an_internal_error
    error = assert_raises(Linker::Error) do
      link(section("runtime", 17_000, home: :fixed), section("data", 10, home: :fixed, holds: TABLES))
    end

    refute_kind_of GBC::LoweringError, error
  end

  def test_a_game_part_bigger_than_a_bank_is_named_with_its_fix
    error = assert_raises(Linker::TooBig) { link(section("tiles", 17_000, home: :banked, holds: PICTURES)) }

    assert_match(/the game's pictures needs 17000 bytes in one bank/, error.message)
    assert_match(/To fix this, use fewer pictures\./, error.message)
  end

  def test_a_section_of_the_frameworks_bigger_than_a_bank_is_an_internal_error
    assert_raises(Linker::Error) { link(section("runtime part", 17_000, home: :banked)) }
  end

  # The runtime switches banks by the eight bits of the bank number, so the cartridge has 256
  # banks at most. A game that needs more is refused rather than built with its bank numbers
  # wrapping round onto the wrong code.
  def test_a_game_that_needs_more_banks_than_the_cartridge_has_is_refused
    pictures = Array.new(Linker::MOST_BANKS) { |i| section("pictures #{i}", 10_000, home: :banked, holds: PICTURES) }
    error = assert_raises(Linker::TooBig) { link(*pictures) }

    assert_match(/does not fit in a Game Boy Color cartridge/, error.message)
    assert_match(/the game's pictures take #{256 * 10_000} bytes/, error.message)
    assert_match(/To fix this, use fewer pictures\./, error.message)
  end

  # A cartridge with a clock chip has an MBC3, which switches 128 banks: the game that fits in 128
  # is built, and the one a bank past them is refused, saying why it has fewer.
  def test_a_cartridge_with_a_clock_has_half_the_banks
    pictures = ->(count) { Array.new(count) { |i| section("pictures #{i}", 10_000, home: :banked, holds: PICTURES) } }
    linked = Linker.new(pictures.call(Linker::MOST_CLOCK_BANKS - 1), clock: true).link
    error = assert_raises(Linker::TooBig) { Linker.new(pictures.call(Linker::MOST_CLOCK_BANKS), clock: true).link }

    assert_equal Linker::MOST_CLOCK_BANKS, linked.banks.length
    assert_match(/A cartridge with a clock chip holds 128 banks/, error.message)
  end

  # A TABLE OF ADDRESSES THE CODE JUMPS THROUGH (a draw order's placings, GBC::Lowering::Picture#emit_ordered_dispatch)
  # reaches what a jump reaches: the part always in view and its own bank. One naming code in another
  # bank is refused as the cartridge is built, where it would have jumped into whatever that bank holds.
  # Each section is over half a bank, so two banked ones are never put in one bank by chance.
  private def jump_table(name, target, home:)
    asm = SM83.new(name, home: home)
    asm.label(name)
    asm.data_jump_targets([target])
    asm.data_bytes(Array.new(Linker::BANK_SIZE / 2, 0)) unless home == :fixed
    asm.section
  end

  private def routine(name, home:)
    asm = SM83.new(name, home: home)
    asm.label(name)
    asm.ret
    asm.data_bytes(Array.new(Linker::BANK_SIZE / 2, 0)) unless home.is_a?(String) || home == :fixed
    asm.section
  end

  def test_a_jump_table_into_another_bank_is_refused
    error = assert_raises(Linker::Error) do
      link(jump_table("table", "far_routine", home: :banked), routine("far_routine", home: :banked))
    end

    assert_match(/table \(bank \d+\) jumps to far_routine in bank \d+/, error.message)
  end

  def test_a_jump_table_into_its_own_bank_or_the_part_in_view_is_built
    link(jump_table("table", "fixed_routine", home: :fixed), routine("fixed_routine", home: :fixed))
    link(jump_table("table", "near_routine", home: :banked), routine("near_routine", home: "table"))
  end
end
