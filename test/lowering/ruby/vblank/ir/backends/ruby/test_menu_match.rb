# frozen_string_literal: true

require "test_helper"
require "timeout"
require "tmpdir"
require "vblank/live"
require VBlank::IR::Backends::Ruby::RUNTIME_DIR.then { |dir| File.join(dir, "rg_script_main.rb") }

# A match started from the window's menu, as vblank run's window plays a game written out as Ruby
# (VBlankScript.play): the game ends when a match is chosen, the window's process is handed the choice
# to meet the match, and the game plays again. The window opens on SDL's dummy video driver, and the
# keys are pushed to SDL as a keyboard would push them.
class TestMenuMatch < Minitest::Test
  # SDL's driver is chosen from the process's settings, Fiddle calls into C from the main Ractor only, and
  # the play says what it does on standard output.
  runs_on_the_main_ractor!

  SDL = VBlank::Live::SDL
  MatchRequest = VBlank::Live::WindowMenu::MatchRequest
  PICTURES = 20

  def setup
    @drivers_before = ENV.to_h.slice("SDL_VIDEODRIVER", "SDL_AUDIODRIVER")
    ENV["SDL_VIDEODRIVER"] = "dummy"
    ENV["SDL_AUDIODRIVER"] = "dummy"
  end

  def teardown
    %w[SDL_VIDEODRIVER SDL_AUDIODRIVER].each { |name| ENV[name] = @drivers_before[name] }
  end

  private def written_game(dir, game)
    path = File.join(dir, "game.rb")
    VBlank::IR::Backends::Ruby.new.build_script(game, path, console: :gba, err: StringIO.new, match: true)
    VBlank::IR::Backends::Ruby::WrittenGame.read(path)
  end

  private def two_player_game = VBlank.game("MENUMATCH", consoles: %i[gba], players: 1..2) { game_loop { clear_screen :blue } }

  private def one_player_game = VBlank.game("MENUALONE", consoles: %i[gba]) { game_loop { clear_screen :blue } }

  # Longest a play here may take. It only catches a hang.
  HANG_SECONDS = 30

  # F1, then right to Match, then down to the line +down+ lines in, then Enter, then F1 to close the
  # menu where the choice left it open.
  private def push_menu_choice(down)
    [SDL::MENU, SDL::KEY_CODES[:right], *[SDL::KEY_CODES[:down]] * down, SDL::KEY_CODES[:enter], SDL::MENU].each do |key|
      [true, false].each do |going_down|
        event = "\0".b * SDL::EVENT_BYTES
        event[0, 4] = [going_down ? SDL::EVENT_KEY_DOWN : SDL::EVENT_KEY_UP].pack("L")
        event[SDL::KEY_SCANCODE_AT, 4] = [key].pack("L")
        event[SDL::KEY_DOWN_AT] = going_down ? "\1" : "\0"
        pointer = Fiddle::Pointer.malloc(SDL::EVENT_BYTES, Fiddle::RUBY_FREE)
        pointer[0, event.bytesize] = event
        SDL.binding_for(nil).SDL_PushEvent(pointer)
      end
    end
  end

  # Plays +written+ in a window with the keys pushed first, handing each match chosen to a stand-in that
  # meets none. Gives back the matches it was handed.
  private def play_choosing(written, dir, down)
    flunk "SDL3 is not installed: #{SDL::INSTALL_LINE}" unless SDL.available?
    asked = []
    stand_in = lambda do |request, _shown|
      asked << request
      nil
    end
    window = SDL.new(title: written.title, scale: 1, settings_file: File.join(dir, "settings.txt"))
    push_menu_choice(down)
    options = { pictures: PICTURES, uncapped: true, "settings-file": File.join(dir, "settings.txt") }
    capture_io { Timeout.timeout(HANG_SECONDS) { VBlankScript.play(written, options, window: window, match_from_menu: stand_in) } }
    asked
  end

  def test_host_chosen_in_the_menu_ends_the_game_and_hands_the_match_over
    Dir.mktmpdir do |dir|
      asked = play_choosing(written_game(dir, two_player_game), dir, 2)

      assert_equal [MatchRequest.new(does: :host, text: nil, players: 2)], asked
    end
  end

  # The window's process meets the match chosen (rg_window_main.rb's match_from_menu). One that cannot be
  # met, even an address the network refuses, is said in the window's box and gives the game back to
  # single play, never an error that closes the window.
  def test_a_match_that_cannot_be_met_is_said_in_a_box_and_play_goes_on
    require File.join(VBlank::IR::Backends::Ruby::RUNTIME_DIR, "rg_window_main.rb")
    Dir.mktmpdir do |dir|
      written = written_game(dir, two_player_game)
      menu_match = { game_file: "game.rb", parts: VBlank::Live::WindowProcess.match_part_paths,
                     console_titles: VBlank::Console.kits.to_h { |kit| [kit.name.to_s, kit.title] } }
      told = []
      window = Object.new
      window.define_singleton_method(:tell_in_box) { |words| told << words }
      %w[host: 127.0.0.1:1].each do |address|
        request = MatchRequest.new(does: :join_address, text: address, players: nil)
        met = capture_io { assert_nil VBlankWindow.match_from_menu(written, menu_match, request, window) }

        refute_nil met
      end

      assert_match(/HOST:PORT/, told.first)
      assert_match(/Nobody is hosting a match/, told.last)
    end
  end

  # A game for one player is offered no match: Match is not on the bar, so right goes to Window and its
  # first line is its size, where Enter does nothing.
  def test_a_game_for_one_player_offers_no_match
    Dir.mktmpdir do |dir|
      assert_empty play_choosing(written_game(dir, one_player_game), dir, 1)
    end
  end
end
