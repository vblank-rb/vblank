# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A record of this test's own, whose DEFAULTS the test sets and changes.
PackCacheDefaultsKnob = Data.define(:turn)

# A KEPT PACK IS KEYED ON WHAT ITS PROGRAM MEANS, NOT ONLY ON HOW IT IS WRITTEN. The key holds the
# unpacking program as IR::Dump writes it, and the dump leaves out a record's fields still at their
# class's DEFAULTS. So a change to DEFAULTS can change what a program means and leave its dump as it
# was: a song part built when the default volume was 12 and one built when it is 13 both dump
# without a volume. The key holds the DEFAULTS of every record class the program uses as well.
class TestPackCacheDefaults < Minitest::Test
  # It sets and removes a constant of a class every Ractor shares.
  runs_on_the_main_ractor!

  PackCache = VBlank::Original::PackCache
  Pack = VBlank::Original::Pack

  # What the cache asks of an unpacking: its program and the copy it reads.
  UnpackingOfCopy = Data.define(:program, :copy_bytes)

  # A program holding one knob, turned to +turn+.
  private def program_with_knob(turn)
    knob = PackCacheDefaultsKnob.new(turn: turn)
    VBlank::IR::Nodes.build(:program, children: [VBlank::IR::Nodes.build(:song, name: :tune, voices: [knob])])
  end

  private def with_knob_defaults(turn)
    PackCacheDefaultsKnob.const_set(:DEFAULTS, { turn: turn }.freeze)
    yield
  ensure
    PackCacheDefaultsKnob.class_eval { remove_const(:DEFAULTS) }
  end

  # Whether the cache in +folder+ played the block to make the pack of +program+.
  private def played?(folder, program)
    library = VBlank::Original::PackLibrary.new(root: File.join(folder, "lib"))
    played = false
    PackCache.new(File.join(folder, "packs"), library: library).pack(UnpackingOfCopy.new(program: program, copy_bytes: "a copy"),
                                                                     sha1: "0" * 40, build_version: "1") do |path|
      played = true
      Pack.holding({ walls: "made".b }, sha1: "0" * 40, build_version: "1").write(path)
    end
    played
  end

  def test_a_program_whose_record_defaults_changed_makes_the_pack_again
    Dir.mktmpdir do |folder|
      first = with_knob_defaults(1) { [VBlank::IR::Dump.source(program_with_knob(1)), played?(folder, program_with_knob(1))] }
      second = with_knob_defaults(2) { [VBlank::IR::Dump.source(program_with_knob(2)), played?(folder, program_with_knob(2))] }

      assert_equal first.first, second.first, "the dump of the knob at its default is the same"
      assert second.last, "the pack is made again"
    end
  end
end
