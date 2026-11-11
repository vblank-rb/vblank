# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_recolor_several_lists"

# A background drawn with several lists the game changes, on the Advance's cartridge. Its build
# does not copy a list's colours into the group those tiles read yet, so it refuses the game in
# plain words where the cartridge would show the tiles' declared colours for good.
class TestRecolorSeveralListsCartridge < Minitest::Test
  include RecolorSeveralListsGames

  def test_the_build_says_it_does_not_make_a_background_that_follows_several_lists
    program = several_lists_game.copy.tap { |copy| copy.console = :gba }
    message = assert_raises(GBA::LoweringError) { GBA.new.lower(program) }.message

    assert_match(/background :title draws with 3 lists/, message)
    assert_match(/does not make that yet/, message)
  end
end
