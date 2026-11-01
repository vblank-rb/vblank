# frozen_string_literal: true

require "test_helper"

# Where the Genesis linker puts each section, and the holes it fills.
class TestGenesisLinker < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis
  M68000 = Genesis::M68000
  Linker = Genesis::Linker

  private def section(name, holds: nil)
    asm = M68000.new(name, holds: holds)
    yield asm
    asm.section
  end

  def test_sections_go_one_after_another_from_the_end_of_the_header
    first = section("first") { |asm| asm.label("first"); asm.nop; asm.nop }
    second = section("second") { |asm| asm.label("second"); asm.rts }
    linked = Linker.new([first, second]).link

    assert_equal 0x200, linked.address_of("first")
    assert_equal 0x204, linked.address_of("second")
    assert_equal "4e714e714e75", linked.image.unpack1("H*")
  end

  def test_a_call_to_a_label_in_another_section_is_its_whole_address
    caller = section("caller") { |asm| asm.jsr(asm.abs_l("far")) }
    target = section("target") { |asm| asm.label("far"); asm.rts }
    image = Linker.new([caller, target]).link.image

    assert_equal "4eb900000206" "4e75", image.unpack1("H*")
  end

  def test_a_branch_is_a_distance_from_the_word_it_is_in
    code = section("code") do |asm|
      asm.label("top")
      asm.nop
      asm.bra("top")
    end
    image = Linker.new([code]).link.image

    assert_equal "4e71" "6000" "fffc", image.unpack1("H*"), "the hole is at 4, the target at 0"
  end

  def test_a_table_of_addresses_names_labels
    code = section("code") do |asm|
      asm.label("here")
      asm.rts
      asm.label("table")
      asm.data_longs("here", "table")
    end

    assert_equal "4e75" "00000200" "00000202", Linker.new([code]).link.image.unpack1("H*")
  end

  def test_a_label_no_section_defines_is_refused
    code = section("code") { |asm| asm.jsr(asm.abs_l("nowhere")) }

    assert_raises(Linker::Error) { Linker.new([code]).link }
  end

  def test_a_label_defined_twice_is_refused
    one = section("one") { |asm| asm.label("same") }
    two = section("two") { |asm| asm.label("same") }

    assert_raises(Linker::Error) { Linker.new([one, two]).link }
  end

  def test_a_game_bigger_than_the_cartridge_says_which_of_its_parts_is_big
    holding = M68000::Holding.new(what: "the game's tables", fix: "make its tables shorter")
    big = section("tables", holds: holding) { |asm| asm.data_bytes([0] * 0x400000) }

    error = assert_raises(Linker::TooBig) { Linker.new([big]).link }

    assert_match(/does not fit in a Genesis cartridge/, error.message)
    assert_match(/make its tables shorter/, error.message)
  end
end
