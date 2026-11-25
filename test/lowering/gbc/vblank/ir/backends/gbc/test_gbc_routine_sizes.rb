# frozen_string_literal: true

require "test_helper"
require "stringio"
require "json"

# How many bytes each of the game's routines takes in a Color cartridge, for a profile to print and
# for a tool to read in place of a linker's map. The parts a big routine is cut into
# (Backends::RoutineCuts) are one routine to its author, so they are one entry.
class TestGBCRoutineSizes < Minitest::Test
  GBC = VBlank::IR::Backends::GBC
  Build = VBlank::IR::Build

  # Adding a number to a variable is three instructions a byte of its four, so 4000 of them are
  # past where a routine is cut (Lowering::MOST_ROUTINE_BYTES).
  MANY = 4000

  private def additions(name, count) = Array.new(count) { Build.add(name, 1) }

  private def cartridge(*body)
    program = Build.program(*body, Build.loop_(Build.wait_vblank))
    program.console = :gbc
    VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "SIZES")
  end

  private def big_and_small = cartridge(Build.func(:big, *additions(:x, 200)), Build.func(:small, Build.add(:y, 1)),
                                        Build.call(:big), Build.call(:small))

  def test_each_routine_is_named_with_its_size_and_the_big_one_is_bigger
    sizes = big_and_small.routine_sizes.to_h { |entry| [entry.routine, entry.bytes] }

    assert_includes sizes.keys, "big"
    assert_includes sizes.keys, "small"
    assert_operator sizes["big"], :>, sizes["small"]
  end

  def test_the_biggest_comes_first
    bytes = big_and_small.routine_sizes.map(&:bytes)

    assert_equal bytes.sort.reverse, bytes
  end

  def test_the_sizes_add_up_to_the_ranges_the_build_placed
    rom = big_and_small

    assert_equal rom.built.routines.sum { |held| held.addresses.size }, rom.routine_sizes.sum(&:bytes)
  end

  def test_a_routine_cut_into_parts_is_one_entry
    rom = cartridge(Build.func(:huge, *additions(:x, MANY)), Build.call(:huge))
    parts = rom.built.routines.select { |held| held.routine == "huge" }

    assert_operator parts.length, :>, 1, "the routine was cut into parts"
    assert_equal 1, rom.routine_sizes.count { |entry| entry.routine == "huge" }
    assert_equal parts.sum { |held| held.addresses.size }, rom.routine_sizes.find { |entry| entry.routine == "huge" }.bytes
  end

  def test_the_cartridge_says_how_many_banks_it_is
    rom = big_and_small

    assert_equal rom.size / 0x4000, rom.bank_count
  end

  def test_a_cartridge_with_no_record_has_no_sizes
    bare = VBlank::Cartridge::GBCROM.new(["\0".b * 0x4000], title: "BARE")

    assert_equal [], bare.routine_sizes
  end

  def test_the_profile_in_json_carries_the_sizes
    rom = big_and_small
    out = StringIO.new
    rom.profile(format: :json, out: out, frames: 10)
    report = JSON.parse(out.string)

    assert_equal rom.bank_count, report["bank_count"]
    assert_equal rom.routine_sizes.map { |entry| [entry.routine, entry.bytes] },
                 report["routine_sizes"].map { |entry| [entry["routine"], entry["bytes"]] }
  end

  def test_the_human_profile_lists_the_routines_by_size
    out = StringIO.new
    big_and_small.profile(out: out, frames: 10)

    assert_match(/Your routines by size:\n\s+\d+ bytes  big\n/, out.string)
    assert_match(/In all: \d+ bytes of routines, in a cartridge of \d+ banks\./, out.string)
  end
end
