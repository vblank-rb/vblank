# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "vblank/live"

# A game written out as one Ruby file (Ruby#build_script), played by a Ruby that cannot load the
# vblank gem, in SDL's dummy window, which shows nothing: everything it needs is in the file.
class TestRubyScript < Minitest::Test
  Ruby = VBlank::IR::Backends::Ruby

  # A Ruby with none of the settings that would let it find this library or its gems.
  ALONE = { "SDL_VIDEODRIVER" => "dummy", "SDL_AUDIODRIVER" => "dummy", "RUBYOPT" => nil, "RUBYLIB" => nil,
            "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil, "RUBY_YJIT_ENABLE" => nil }.freeze

  private def play_alone(game, console, *arguments)
    flunk "SDL3 is not installed: #{VBlank::Live::SDL::INSTALL_LINE}" unless VBlank::Live::SDL.available?

    Dir.mktmpdir do |dir|
      path = Ruby.new.build_script(game, File.join(dir, "game-ruby.rb"), console: console, err: StringIO.new)
      # A settings file of its own, so it plays the same whatever the person running it has chosen.
      played = Open3.capture2e(ALONE, RbConfig.ruby, path, *arguments, "--settings-file", File.join(dir, "settings.txt"), chdir: dir)
      yield dir if block_given? && played.last.success? # what the play left in its folder, read before it goes
      played
    end
  end

  private def color_game
    VBlank.game("COLORSCRIPT", consoles: %i[gbc], menu: false) do
      game_loop { clear_screen :green }
    end
  end

  # A game for the Color, with no menu, plays as the Color in a window the size of its screen.
  def test_a_color_game_with_no_menu_plays_alone
    played, status = play_alone(color_game, :gbc, "--pictures", "3")

    assert status.success?, played
    assert_match(/Playing COLORSCRIPT for the Game Boy Color in Ruby [\d.]+ with \w+( JIT)?\. Press P to pause/, played,
                 "a game with no menu says nothing of F1")
    assert_match(/2 frames in/, played)
  end

  # A game with a menu carries it, and the menu's letters, and says how to open it.
  def test_a_game_with_a_menu_plays_alone
    game = VBlank.game("MENUSCRIPT", consoles: %i[gba]) { game_loop { clear_screen :blue } }
    played, status = play_alone(game, :gba, "--pictures", "3")

    assert status.success?, played
    assert_match(/Press F1 or ` for the menu/, played)
  end

  # --record-sound keeps what the game handed the speaker, as vblank run's does: the script carries
  # the recording and the .wav writer.
  def test_a_script_records_the_sound_to_a_wav
    game = VBlank.game("BEEPSCRIPT", consoles: %i[gba]) do
      enable_sound
      define_sound :tone, frequency: 880, duty: :quarter, decay: :fast, volume: 12
      game_loop { beep :tone }
    end
    played, status = play_alone(game, :gba, "--pictures", "6", "--record-sound", "heard.wav") do |dir|
      assert_equal "RIFF", File.binread(File.join(dir, "heard.wav"), 4)
    end

    assert status.success?, played
    assert_match(/The sound the game made is in heard\.wav\./, played)
  end

  # A number of pictures that could never be reached is refused in words, rather than played forever.
  def test_a_script_refuses_no_pictures
    played, status = play_alone(color_game, :gbc, "--pictures", "0")

    refute status.success?, played
    assert_match(/--pictures must be a whole number above 0/, played)
  end
end
