# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/wanderers").to_s

# THE FINGERPRINT OF A GAME tells two machines whether they run the same program for the same
# console, which a match must know before it plays a pass.
class TestFingerprint < Minitest::Test
  Fingerprint = VBlank::Network::Fingerprint

  private def of(console) = Fingerprint.of(Wanderers::GAME.checked_program(err: nil, console: console), title: "WANDERERS")

  def test_one_game_built_twice_has_one_fingerprint
    assert of(:gba).same_as?(of(:gba))
    assert_equal of(:gba).digest, of(:gba).digest
  end

  def test_the_same_game_for_another_console_is_another_fingerprint
    refute of(:gba).same_as?(of(:gbc))
    assert_equal "gbc", of(:gbc).console
  end

  def test_another_game_is_another_fingerprint
    other = VBlank.game("OTHER", consoles: %i[gba], players: 4) { game_loop { pixel 2, 2, :red } }
    theirs = Fingerprint.of(other.checked_program(err: nil, console: :gba), title: "OTHER")

    refute of(:gba).same_as?(theirs)
  end

  def test_the_title_is_for_people_and_is_not_compared
    named = Fingerprint.of(Wanderers::GAME.checked_program(err: nil, console: :gba), title: "ANOTHER NAME")

    assert of(:gba).same_as?(named)
  end

  def test_the_short_form_is_eight_digits_and_the_checksum_is_the_same_digits_as_a_number
    assert_match(/\A\h{8}\z/, of(:gba).short)
    assert_equal of(:gba).short.to_i(16), of(:gba).checksum
  end
end
