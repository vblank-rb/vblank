# frozen_string_literal: true

require "test_helper"

# Every cartridge lowering writes list_pack as the loop it stands for or is listed with its reason: it
# takes IR::ListPacking::Loops, or it is in Backends::ListPackBlocks::OWN_WAYS saying why its own way
# is cheaper there, never both.
class TestListPackBlocks < Minitest::Test
  Backends = VBlank::IR::Backends
  WRITERS = { "GBA" => Backends::GBA::Lists, "GBC" => Backends::GBC::Lowering, "SNES" => Backends::SNES::Lowering,
              "Genesis" => Backends::Genesis::Lowering, "PS1" => Backends::PS1::Lowering }.freeze

  def test_each_lowering_takes_the_loop_or_is_listed_with_its_reason
    WRITERS.each do |name, writer|
      own = writer.instance_method(:emit_list_pack).owner != VBlank::IR::ListPacking::Loops
      listed = Backends::ListPackBlocks::OWN_WAYS.key?(name)

      assert_equal listed, own, "#{name}: writes list_pack its own way exactly when it is listed in ListPackBlocks::OWN_WAYS"
    end
    assert_empty Backends::ListPackBlocks::OWN_WAYS.keys - WRITERS.keys, "only cartridge lowerings are listed"
    Backends::ListPackBlocks::OWN_WAYS.each_value { |why| refute_empty why }
  end
end
