# frozen_string_literal: true

require "test_helper"

# The original Mode's traces (test/lowering/flash/fixtures/mode) are the answer key a remake of it will be held to, so they must be
# whole: every update from 1 to the last, one picture hash each, the sounds in between, and an end.
class TestModeOriginalTraces < Minitest::Test
  FIXTURES = File.expand_path("../fixtures/mode", __dir__)
  UPDATES = 1100

  %w[attract1 attract2].each do |replay|
    define_method(:"test_#{replay}_has_every_update_in_order") do
      numbers = lines_of(replay).filter_map { |line| line[/\Aupdate (\d+) /, 1]&.to_i }

      assert_equal (1..UPDATES).to_a, numbers
    end

    define_method(:"test_#{replay}_gives_each_update_a_picture_hash") do
      hashes = lines_of(replay).filter_map { |line| line[/\Aupdate \d+ (\S+)\z/, 1] }

      assert_equal UPDATES, hashes.size
      assert(hashes.all? { |hash| hash.match?(/\A\h{8}\z/) })
    end

    # The replay ends in the update that is the last, before that update's picture is drawn and traced.
    define_method(:"test_#{replay}_ends_in_the_last_update") do
      assert_equal ["end #{UPDATES}", "update #{UPDATES} #{lines_of(replay).last.split.last}"], lines_of(replay).last(2)
    end

    define_method(:"test_#{replay}_names_each_sound_with_its_volume_and_pan") do
      sounds = lines_of(replay).grep(/\Asound /)

      refute_empty sounds
      assert(sounds.all? { |line| line.match?(/\Asound \w+ [\d.]+ -?[\d.]+\z/) })
    end
  end

  def test_the_two_replays_differ
    refute_equal lines_of("attract1"), lines_of("attract2")
  end

  def test_the_patch_names_the_sources_it_is_for
    patch = File.read(File.join(FIXTURES, "instrument.patch"))

    assert_includes patch, "cb6bdaeaf8d5"
    assert_includes patch, "4d6f5e8a1986"
  end

  private

  def lines_of(replay) = File.readlines(File.join(FIXTURES, "#{replay}.trace"), chomp: true)
end
