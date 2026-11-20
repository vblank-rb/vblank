# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"

# THE GAME WRITTEN OUT AS ONE RUBY FILE, READ BACK (Ruby::WrittenGame): the window vblank run opens
# plays a game a helper process wrote, so what it reads from the file must play as the game built
# here does. The answer key is the same game built in this process and played on the same device.
class TestWrittenGame < Minitest::Test
  Ruby = VBlank::IR::Backends::Ruby
  Headless = VBlank::Live::Headless
  Session = VBlank::Live::Session

  PASSES = 8

  # A box that moves right a pixel a pass while A is held, over stripes of four colours.
  private def mover
    VBlank.game("MOVER", consoles: %i[gba gbc]) do
      screen :bitmap
      x = 10
      game_loop do
        clear_screen :black
        fill_rect 0, 0, 4, 4, :red
        fill_rect 4, 0, 4, 4, :green
        fill_rect 8, 0, 4, 4, :blue
        x += 1 if held(:a)
        fill_rect x, 40, 6, 6, :white
      end
    end
  end

  private def pictures_of(session_game)
    device = Headless.new(frames: PASSES, buttons: { 2 => [:a], 3 => [:a], 5 => [:a] })
    session_game.play(device)
    device.pictures.map(&:pixels)
  end

  def test_a_written_game_read_back_plays_as_the_game_built_here
    Dir.mktmpdir do |dir|
      path = Ruby.new.build_script(mover, File.join(dir, "mover-ruby.rb"), console: :gbc, err: StringIO.new)
      written = Ruby::WrittenGame.read(path)
      here = pictures_of(Session.new(mover.checked_program(console: :gbc, err: StringIO.new)))

      assert_equal here, pictures_of(Session.new(game: written.live_game))
      assert_equal "MOVER", written.title
      assert_equal "Game Boy Color", written.console_title
      assert written.menu
      assert_nil written.shell
    end
  end

  # SAVE STATES AND THE SAVE FILE: a written game says where its window keeps them, the folder
  # vblank run's window keeps them in (StateSlots.folder_name, from the title and the game's code),
  # so a state saved in one is in the menu of the other.
  def test_a_written_game_keeps_its_states_where_vblank_run_keeps_them
    Dir.mktmpdir do |dir|
      path = Ruby.new.build_script(mover, File.join(dir, "mover-ruby.rb"), console: :gba, err: StringIO.new)
      written = Ruby::WrittenGame.read(path)

      assert_equal VBlank::Live::StateSlots.folder_name(title: "MOVER", code: mover.identifying_code), written.state_folder
      assert_includes File.read(path), "class StateSlots", "the script carries what keeps the states"
    end
  end
end
