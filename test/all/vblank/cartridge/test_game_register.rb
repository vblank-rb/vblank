# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A game file names the build its commands take (`vblank build`, `vblank run`, a port's shell check)
# by registering a handle: `GAME.with_features(:rooms).with_settings(rooms: 3).register`, or
# `HANDLE.write_if_main` as its last line. A file that names none is built whole.
module RoomsGameFile
  # A game whose feature :rooms refuses to build until a setting gives it a number of rooms, as a
  # port's part does when it is on and has not been told what it needs. Its whole game, with every
  # feature on and no settings, does not build; :rooms_told shows the rooms a build was given.
  DECLARATION = <<~RUBY
    require "vblank"
    game = VBlank.game "ROOMS", consoles: %i[gba gbc snes genesis ps1], features: { rooms: [] } do
      screen :bitmap
      rooms = 0
      if feature?(:rooms)
        rooms = setting(:rooms, 0)
        raise VBlank::BuildError, "The rooms feature needs the setting :rooms." if rooms.zero?
      end
      var :rooms_told, rooms + 4320
      game_loop { wait_vblank }
    end
  RUBY

  # The phrase the whole game stops with.
  REFUSAL = "needs the setting :rooms"

  # The file, in +folder+, ending with +last_line+, which uses the local `game`.
  private def rooms_file(folder, last_line)
    File.join(folder, "rooms.rb").tap { |path| File.write(path, "#{DECLARATION}#{last_line}\n") }
  end
end

class TestGameRegister < Minitest::Test
  # A game whose start is a setting, built for every console a run plays as.
  private def counter
    VBlank.game("COUNTER", consoles: %i[gba gbc snes genesis ps1]) do
      screen :bitmap
      var :start, setting(:start, 1)
      game_loop { wait_vblank }
    end
  end

  def test_register_makes_the_handle_the_last_registered_game
    handle = counter.with_settings(start: 7)

    assert_same handle, handle.register
    assert_same handle, VBlank.registered_games.last
    assert_equal 7, game_player.run(VBlank.registered_games.last.program(console: game_console), frames: 1)[:start]
  end

  # Called from this file, which is not the script Ruby was run with, so it builds nothing, and the
  # handle it was called on is what a command loading the file builds. Its settings are left out:
  # they are the line's own edge, and the command takes settings of its own.
  def test_write_if_main_off_the_main_script_registers_the_handle_without_its_settings
    handle = counter.with_settings(start: 7)

    assert_same handle, handle.write_if_main(settings: { start: 9 })
    assert_same handle, VBlank.registered_games.last
    assert_equal 7, game_player.run(VBlank.registered_games.last.program(console: game_console), frames: 1)[:start]
  end

  def test_write_if_main_on_the_declared_game_registers_nothing_new
    handle = counter
    before = VBlank.registered_games.length

    handle.write_if_main

    assert_equal before, VBlank.registered_games.length
    assert_same handle, VBlank.registered_games.last
  end
end
