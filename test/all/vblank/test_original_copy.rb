# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"

# A game's test that needs the player's copy of the original asks for it with `original_copy`: a
# machine with none set skips the test, saying what to set, and a copy that is set and wrong fails
# it, since that is a mistake to fix and not a machine without the game.
class TestOriginalCopy < Minitest::Test
  include VBlank::Testing

  private def game(folder, env)
    VBlank::Original::Game.new(title: "Space Pinball", setting: "PINBALL_ROM", env: env,
                               settings_file: File.join(folder, "space_pinball.yml"),
                               releases: { "US" => { "sha1" => Digest::SHA1.hexdigest("right") } })
  end

  def test_a_machine_with_no_copy_skips_saying_what_to_set
    Dir.mktmpdir do |folder|
      skipped = assert_raises(Minitest::Skip) { original_copy(game(folder, {})) }

      assert VBlank::Testing::NotOnThisMachine === skipped # rubocop:disable Style/CaseEquality
      assert_match "PINBALL_ROM", skipped.message
    end
  end

  def test_a_wrong_copy_fails_the_test
    Dir.mktmpdir do |folder|
      path = File.join(folder, "wrong.gb")
      File.binwrite(path, "wrong")

      assert_raises(VBlank::Original::WrongCopy) { original_copy(game(folder, { "PINBALL_ROM" => path })) }
    end
  end

  def test_the_right_copy_is_handed_back
    Dir.mktmpdir do |folder|
      path = File.join(folder, "right.gb")
      File.binwrite(path, "right")

      assert_equal path, original_copy(game(folder, { "PINBALL_ROM" => path })).path
    end
  end
end
