# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"

# `vblank build --format=flash` writes the game as a Flash movie beside the game file.
class TestCLIFlash < Minitest::Test
  RUBY = RbConfig.ruby.freeze
  BIN = VBlank.root.join("bin/vblank").to_s

  private def cli(*args, dir:)
    Open3.capture2e(RUBY, BIN, *args, chdir: dir)
  end

  def test_build_format_flash_writes_a_movie_beside_the_game
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "tiny.rb"), <<~GAME)
        VBlank.game("TINY", consoles: %i[gba]) do
          game_loop do
            clear_screen :blue
          end
        end
      GAME
      out, status = cli("build", "tiny.rb", "--format=flash", dir: dir)

      assert status.success?, out
      assert_match(/Built .*tiny\.swf/, out)
      assert_includes %w[FWS CWS], File.binread(File.join(dir, "tiny.swf"), 3)
    end
  end

  def test_the_help_lists_the_flash_format
    out, status = cli("build", "--help", dir: Dir.pwd)

    assert status.success?, out
    assert_includes out, "--format=flash"
    assert_includes out, "Haxe"
  end

  def test_a_game_the_flash_build_cannot_make_yet_is_refused_by_name
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "beepy.rb"), <<~GAME)
        VBlank.game("BEEPY", consoles: %i[gba]) do
          game_loop do
            enable_sound
            beep :blip
          end
        end
      GAME
      out, status = cli("build", "beepy.rb", "--format=flash", dir: dir)

      refute status.success?, out
      assert_match(/Flash build does not have rg_sound/, out)
      refute_path_exists File.join(dir, "beepy.swf")
    end
  end

  def test_a_misspelled_flash_flag_says_how_to_write_it
    out, status = cli("build", "game.rb", "--flash", dir: Dir.pwd)

    refute status.success?
    assert_includes out, "--format=flash"
  end
end
