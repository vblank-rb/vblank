# frozen_string_literal: true

require "test_helper"

# A test or an example reads a running game by the names the game gave it (`player.sprite(:hero)`,
# `player.background(:sky)`, `player.music_volume`), never by a variable the framework made for
# itself, whose name starts with two underscores. Those names are how one build keeps its state, and
# they change when the build does; a reading by them is a reading of the build, not of the game. This
# finds a read of one in test/ or examples/ and names the file and line.
#
# What it looks for is a read of a running game's variables: `run[:__x]`, `game.var(:__x)`,
# `raw_var(:__x)`, and a recorded frame's `variables[:__x]`, `variables.fetch(:__x)` or
# `values_at(:__x`. A routine's name in a profile, a plan's list of routines and game code that
# declares a variable of its own are not reads of a running game, and are not matched.
class TestHiddenReads < Minitest::Test
  ROOT = VBlank.root.to_s

  # A read of a running game's hidden variable, on one line.
  HIDDEN_READ = /\[:"?__\w|\.var\(:"?__\w|raw_var\(:"?__\w|variables\.fetch\(:"?__\w|values_at\(:"?__\w/

  # The files that read a hidden variable on purpose, each with why. A test of how a lowering keeps
  # its own state is about the hidden variable itself.
  ALLOWED = {
    "test/lowering/gbc/vblank/ir/backends/gbc/test_gbc_clock.rb" =>
      "how the Color's lowering folds its clock's day count is the test",
    "test/all/vblank/test_hidden_reads.rb" => "this file names the pattern it looks for",
  }.freeze

  # Every hidden read under +folders+, as "file:line", leaving out the files ALLOWED.
  private def hidden_reads(folders)
    folders.flat_map { |folder| Dir.glob(File.join(ROOT, folder, "**", "*.rb")) }.sort.flat_map do |path|
      file = path.delete_prefix("#{ROOT}/")
      next [] if ALLOWED.key?(file)

      File.foreach(path).with_index(1).filter_map { |line, number| "#{file}:#{number}" if line.match?(HIDDEN_READ) }
    end
  end

  def test_no_test_or_example_reads_a_hidden_variable
    found = hidden_reads(%w[test examples])

    assert_empty found, "These read a variable the framework made for itself. Read the game by the names it " \
                        "gave instead (sprite, background, music_volume, var), or, for a test of the " \
                        "framework's own storage, add the file to ALLOWED with why:\n#{found.join("\n")}"
  end

  def test_a_hidden_read_is_found
    reads = ["run[:__music_level]", "game.var(:__obj1_x)", "moment.variables.fetch(:__bg_sky_sx)"]
    plain = ["var(:__f, 0)", "sizes.fetch(:__frame)", "run[:hearts]"]

    assert(reads.all? { |line| line.match?(HIDDEN_READ) }, "each is a hidden read")
    refute(plain.any? { |line| line.match?(HIDDEN_READ) }, "none of these reads a running game")
  end

  def test_every_allowed_file_is_there
    missing = ALLOWED.keys.reject { |file| File.exist?(File.join(ROOT, file)) }

    assert_empty missing, "ALLOWED names files that are gone: #{missing.join(', ')}"
  end
end
