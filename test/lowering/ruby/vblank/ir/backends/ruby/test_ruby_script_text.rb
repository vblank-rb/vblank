# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"

# A script is one file, and Ruby reads the magic comment only at its top.
class TestRubyScriptText < Minitest::Test
  def test_a_script_says_frozen_string_literal_once_on_its_second_line
    game = VBlank.game("MAGICSCRIPT", consoles: %i[gba], menu: false) { game_loop { clear_screen :blue } }

    Dir.mktmpdir do |dir|
      path = VBlank::IR::Backends::Ruby.new.build_script(game, File.join(dir, "game-ruby.rb"), console: :gba, err: StringIO.new)
      lines = File.readlines(path)

      assert lines[0].start_with?("#!")
      assert_equal "# frozen_string_literal: true\n", lines[1]
      assert_equal 1, lines.count("# frozen_string_literal: true\n")
    end
  end
end
