# frozen_string_literal: true

require "digest"
require "tmpdir"
require "all/vblank/builder/test_pack_backdrops"
require "pack_at_start_tests"

# A SCREEN'S BACKDROP FROM THE PACK, ITS PACK LEFT OUT: what the games of PackBackdropGames
# (test/all/vblank/builder/test_pack_backdrops.rb) built with `pack_at_start: true` refuse as the
# all-in-one build does, and what they hold when written out. That each plays as its all-in-one
# build is the registry's (PackGames::Backdrops, test/pack_games.rb).
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more). A scene's
# own backdrop is test/console/gba/vblank/builder/test_pack_backdrops_at_start_on_the_advance.rb's.
module PackBackdropAtStartTests
  include PackBackdropGames
  include WrittenOutSearch

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The slot's size is the game's own word, so a place past it is refused as the game is built,
  # whichever way it is built.
  def test_a_place_the_slot_does_not_have_is_refused_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_with_backdrop(backdrop_original(folder), options: LEFT_OUT) { |pack| { backdrop: pack[:palette].bank(1), backdrop_place: 16 } }
      end

      assert_includes error.message, "backdrop_place: 16"
      assert_includes error.message, "0 to 15"
    end
  end

  def test_a_slot_that_does_not_hold_colors_is_refused_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_with_backdrop(backdrop_original(folder), options: LEFT_OUT) { |pack| { backdrop: pack[:map] } }
      end

      assert_includes error.message, "a slot of colors"
    end
  end

  # The game as the block writes it out (as C, JavaScript or Ruby) holds the backdrop's colour
  # when built all-in-one, and does not built with its pack left out. A lowering's test file calls this.
  private def assert_backdrop_written_without_the_originals_color
    Dir.mktmpdir do |folder|
      from = backdrop_original(folder)
      whole = game_with_backdrop(from) { |pack| { backdrop: pack[:palette] } }
      left_out = game_with_backdrop(from, options: LEFT_OUT) { |pack| { backdrop: pack[:palette] } }

      assert_includes number_runs_in(yield(whole)).fetch(:numbers).first, BANKS[0][0], "the all-in-one build holds the colour"
      refute_includes number_runs_in(yield(left_out)).fetch(:numbers).first, BANKS[0][0], "the build with its pack left out holds it"
    end
  end
end
