# frozen_string_literal: true

require "test_helper"
require "stringio"

# The hidden-variables report (Diagnostics::HiddenVariables) has a plain line for every reason the
# framework makes a variable the author never declared, so a game using any verb that makes one
# can be profiled.
class TestHiddenVariables < Minitest::Test
  REPORT = VBlank::Diagnostics::HiddenVariables
  # The methods a reason for a hidden variable is handed to, and the one a bare `hidden_copy` gives.
  MAKERS = /\b(?:hidden_variable|hidden_copy|hidden_copy_with_truth|step_copy|step_variable)\(:(\w+)/
  DEFAULT_REASON = :copy

  private def cell_block_rom
    VBlank.build("CELLS", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:wall, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:grass, "#" => :green) { Minitest::Test::SOLID_TILE }
      tiles :set, "#" => :wall, "g" => :grass
      room = background :room, tiles: :set, map: ["####", "####"]
      left = var :left, 0
      game_loop do
        room.fill_tiles left + 1, 0, 2, 1, "g"
        room.restore_cells 0, 0, 2, 2
      end
    end
  end

  def test_a_game_writing_blocks_of_cells_has_its_hidden_variables_told
    rom = cell_block_rom
    out = StringIO.new
    REPORT.render(rom, VBlank::IR::Printer.for(out, color: false))
    reasons = rom.hidden_variables.map(&:why)

    assert_includes reasons, :cell_block
    assert_includes reasons, :cell_block_place
    assert_includes out.string, "room.fill_tiles left + 1"
    assert_includes out.string, "room.restore_cells 0, 0, 2, 2"
    assert_includes out.string, REPORT::WORDS.fetch(:cell_block).first
    REPORT.as_json(rom).dig(:hidden_variables, :lines).each { |line| refute_empty line[:says] }
  end

  def test_every_reason_the_library_makes_a_hidden_variable_for_has_words
    reasons = Dir[VBlank.root.join("lib", "**", "*.rb").to_s].flat_map do |path|
      File.read(path).scan(MAKERS).map { |(why)| [why.to_sym, path] }
    end
    unworded = reasons.reject { |why, _| REPORT::WORDS.key?(why) }.map { |why, path| "#{why} (#{File.basename(path)})" }

    refute_empty reasons, "the makers were found in lib"
    assert REPORT::WORDS.key?(DEFAULT_REASON)
    assert_empty unworded.uniq, "Diagnostics::HiddenVariables::WORDS has no line for these reasons"
  end
end
