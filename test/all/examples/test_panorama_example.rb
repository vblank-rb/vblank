# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/panorama").to_s

# The picture wider than the Advance's screen (examples/panorama.rb): shown whole where the build
# gives a screen it fits, a computer's, and panned across where it does not, a console's. One file,
# the choice made by reading the screen's size while the game is built.
class TestPanoramaExample < Minitest::Test
  # Whether this run's player can play the tree a computer's build plays: a computer's own build,
  # or the interpreter, which is the answer key for every build. A cartridge plays its console's.
  private def plays_computer_builds? = computer_run? || !VBlank::Testing.checked?

  private def console_program
    skip_unless_written_for Panorama::GAME
    Panorama.program(console: game_console)
  end

  private def middle_row(program) = program.described_console.screen_height / 2

  def test_a_computer_shows_the_whole_picture
    skip_unless_written_for Panorama::GAME
    program = Panorama.program(console: game_console, for_computer: plays_computer_builds?)
    width = program.described_console.screen_width
    screen = game_player.run(program, frames: 3).screen
    row = middle_row(program)

    if plays_computer_builds?
      assert_equal 320, width
      assert_equal shown(:red), screen.pixel(0, row), "the left post"
      assert_equal shown(:blue), screen.pixel(319, row), "the right post"
    else
      assert_operator width, :<, 320
    end
  end

  # The console's screen starts at the left edge of the picture and pans until its right edge shows.
  def test_a_console_pans_across_the_picture
    program = console_program
    width = program.described_console.screen_width
    row = middle_row(program)
    player = game_player
    left_seen = right_seen = false
    player.each_vblank do
      left_seen ||= player.screen.pixel(0, row) == shown(:red)
      right_seen ||= player.screen.pixel(width - 1, row) == shown(:blue)
    end
    player.run(program, frames: Panorama::WIDTH - width + 4)

    assert left_seen, "the left post shows at the start"
    assert right_seen, "the right post shows once the screen has panned"
  end
end
