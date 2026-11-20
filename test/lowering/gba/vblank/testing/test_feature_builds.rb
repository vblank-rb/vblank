# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "vblank/testing/cartridge_cache"
require "all/vblank/builder/test_features"

# A game's test builds the smallest cartridge that answers its question, `game.with_features(...)`
# (Cartridge::Features), and shares it: a feature left out is not in the cartridge at all, and the
# run's CartridgeCache builds the cartridge once, keeps it apart from the whole game's, and hands it
# to a later run. The game is the cave of test/all/vblank/builder/test_features.rb.
class TestFeatureBuilds < Minitest::Test
  Cave = TestFeatures::Cave

  # The bat's path as the cartridge keeps its table, a half a number.
  BAT_PATH_BYTES = Cave::BAT_PATH.pack("v*")

  private def cartridge(game) = game.build_rom(out: nil, err: nil, profile: false)

  # How +cache+ answered one ask for +game+, :hit or :miss, from the report, which the ask empties.
  private def ask(cache, game)
    cache.cartridge(game, console: :gba)
    said = StringIO.new
    cache.report(said)
    said.string.include?("1 hits, 0 misses") ? :hit : :miss
  end

  def test_a_feature_left_out_has_no_routine_and_no_data_in_the_cartridge
    whole = cartridge(Cave.game)
    small = cartridge(Cave.game.with_features(:hero))

    assert_includes whole.built.routines.keys, :bat_flies
    assert_includes whole.buffer, BAT_PATH_BYTES
    refute_includes small.built.routines.keys, :bat_flies
    refute_includes small.buffer, BAT_PATH_BYTES
  end

  def test_a_build_of_features_is_built_once_a_run_and_read_by_a_later_run
    Dir.mktmpdir do |folder|
      first = VBlank::Testing::CartridgeCache.new(folder)
      small = Cave.game.with_features(:hero, :bat)

      assert_equal :miss, ask(first, small)
      assert_same first.cartridge(small, console: :gba), first.cartridge(small, console: :gba),
                  "asked twice in a run, it is built once"
      assert_equal :miss, ask(first, Cave.game), "the whole game is another cartridge"
      assert_equal :hit, ask(VBlank::Testing::CartridgeCache.new(folder), Cave.game.with_features(:hero, :bat))
    end
  end
end
