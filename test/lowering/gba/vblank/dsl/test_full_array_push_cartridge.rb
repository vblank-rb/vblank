# frozen_string_literal: true

require "test_helper"

VBlank.require_game_file "../../../../struct_array_parts"

# A push onto a full Array on the Advance's cartridge, read in the emulator: the game stops, as the
# interpreter stops it, and the cartridge keeps what went wrong, which the reader gives back in the
# interpreter's words (Diagnostics::AdvanceReading#went_wrong). What every run does is in
# test/all/vblank/dsl/test_plain_ruby_arrays.rb and test_struct_array.rb.
class TestFullArrayPushCartridge < Minitest::Test
  # +checked+ false lets the block name a Struct this file loaded, as test_struct_array.rb's do.
  private def cartridge(frames:, checked: true, &block)
    require_emulator!
    builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block, checked: checked))
    builder.finalize_program
    rom = VBlank::Cartridge::AdvanceBuild.cartridge_for(builder.program, title: "FULLPUSH")
    VBlank::Diagnostics::Verifier.new(rom, frames: frames, vars: rom.var_addresses)
  end

  def test_a_push_onto_a_full_array_stops_the_game_naming_it
    v = cartridge(frames: 8) do
      screen :bitmap
      trail = Array.new(capacity: 4)
      x = 0
      game_loop do
        x += 1
        trail << x
      end
    end

    assert_match(/`trail` is full: it has room for 4/, v.went_wrong)
    assert_equal 5, v.var(:x), "the fifth pass stopped at its push"
    assert_equal [1, 2, 3, 4], v.list(:trail)
  end

  def test_a_push_onto_a_full_array_of_structs_stops_the_game_naming_it
    v = cartridge(frames: 4, checked: false) do
      screen :bitmap
      sparks = Array.new(capacity: 4)
      game_loop { 6.times { |n| sparks << Spark.new(n, 0, 0) } }
    end

    assert_match(/`sparks` is full: it has room for 4/, v.went_wrong)
  end

  def test_a_game_whose_pushes_fit_has_nothing_gone_wrong
    v = cartridge(frames: 6) do
      screen :bitmap
      trail = Array.new(capacity: 4)
      x = 0
      game_loop do
        x += 1
        trail.shift if trail.size == 4
        trail << x
      end
    end

    assert_nil v.went_wrong
    assert_equal [3, 4, 5, 6].map { |n| n + v.var(:x) - 6 }, v.list(:trail)
  end
end
