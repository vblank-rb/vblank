# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A movie is compiled once for what it holds, by the compiler that made it, and Haxe refusing a game leaves nothing behind.
class TestFlashCompileCache < Minitest::Test
  Flash = VBlank::IR::Backends::Flash

  def test_a_game_haxe_refuses_leaves_no_build_folder_behind
    source = "class Main { static function main() { this_is_not_haxe } }\n#{SecureRandom.hex(8)}"
    error = assert_raises(Flash::Haxe::Error) { Flash.new.compile(source, width: 16, height: 16) }

    assert_includes error.message, "refused"
    folders = Dir.glob(File.join(Dir.tmpdir, "vblank-flash", "*", "build-*")).select { |path| File.mtime(path) > Time.now - 60 }
    assert_empty folders
  end

  def test_the_compilers_version_is_part_of_what_a_movie_is_named_for
    assert_match(/\A\d+\.\d+/, Flash::Haxe.version)
  end
end
