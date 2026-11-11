# frozen_string_literal: true

require "test_helper"

# Original::DataGuard made and asked on a core of its own, as a game's own suite runs its test of
# what its guard refuses. TestDataGuard runs on the main core, since one of its tests starts git,
# so this is the test that holds the guard's tables shareable.
class TestDataGuardInARactor < Minitest::Test
  def test_the_guard_refuses_a_cartridge_and_lets_source_through
    guard = VBlank::Original::DataGuard.new(consoles: %i[gba genesis], folders: %w[rom/], suffixes: %w[wav])
    staged = %w[lib/game.rb Game.gba rom/level.bin sound.wav README.md].map do |path|
      VBlank::Original::StagedFile.new(path: path, size: 10, first_line: "# frozen_string_literal: true")
    end
    refusals = guard.refusals(staged).join("\n")

    %w[Game.gba rom/level.bin sound.wav].each { |path| assert_includes refusals, path }
    %w[lib/game.rb README.md].each { |path| refute_includes refusals, path }
  end
end
