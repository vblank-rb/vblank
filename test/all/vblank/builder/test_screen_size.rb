# frozen_string_literal: true

require "test_helper"

# `screen :bitmap, size: [320, 200]` — the size a game would like its screen to be. A build for a
# computer (the desktop program, the web page, the Ruby file) gives it; a console gives its own
# fixed screen and refuses nothing. The game reads which it got from `screen_width` and
# `screen_height`, numbers known while it is built, so one file lays itself out for each.
class TestScreenSize < Minitest::Test
  include VBlank::Testing

  private def game(consoles = %i[gba], &block) = VBlank.game("SIZED", consoles: consoles, &block)

  private def refusal(&block)
    assert_raises(ArgumentError) { game(&block).program(for_computer: true) }
  end

  # What the game read for its screen while it was built, for each console and for a computer.
  private def sizes_read(console: :gba, for_computer: false)
    read = []
    game(%i[gba gbc]) do
      screen :bitmap, size: [320, 200]
      read << screen_width << screen_height
    end.program(console: console, for_computer: for_computer)
    read
  end

  def test_a_computer_build_gives_the_size_asked_for
    assert_equal [320, 200], sizes_read(for_computer: true)
  end

  def test_each_console_gives_its_own_screen
    assert_equal [240, 160], sizes_read(console: :gba)
    assert_equal [160, 144], sizes_read(console: :gbc)
  end

  # The program carries the size, so the interpreter, the checks and each runtime read one screen.
  def test_the_program_is_laid_out_on_the_size_given
    made = game { screen :bitmap, size: [320, 200] }

    assert_equal [320, 200], made.program(for_computer: true).described_console.screen_size
    assert_equal [240, 160], made.program.described_console.screen_size
  end

  # A computer has no BIOS logo drawn for a screen of another size, and no border round it.
  def test_a_computer_screen_of_its_own_plays_no_start_up_and_has_no_border
    described = game { screen :bitmap, size: [320, 200] }.program(for_computer: true).described_console

    refute described.plays_bios_start_up
    refute described.bordered?
  end

  def test_a_game_that_asks_no_size_keeps_the_console_screen_on_a_computer
    assert_equal [240, 160], game { screen :bitmap }.program(for_computer: true).described_console.screen_size
  end

  def test_a_size_that_is_not_two_whole_numbers_is_refused
    error = refusal { screen :bitmap, size: 320 }

    assert_match(/size: 320/, error.message)
  end

  def test_a_size_of_no_pixels_is_refused
    error = refusal { screen :bitmap, size: [0, 200] }

    assert_match(/size: \[0, 200\]/, error.message)
  end

  def test_a_size_is_refused_on_a_tiled_screen
    error = refusal { screen :tiled, size: [320, 200] }

    assert_match(/screen :bitmap/, error.message)
  end

  def test_a_size_is_refused_on_a_later_screen_line
    error = refusal do
      screen :bitmap
      screen :bitmap, size: [320, 200]
    end

    assert_match(/first `screen`/, error.message)
  end

  def test_a_size_is_refused_after_the_game_reads_the_screen_size
    error = refusal do
      screen_width
      screen :bitmap, size: [320, 200]
    end

    assert_match(/screen_width/, error.message)
  end

  def test_a_tiled_screen_is_refused_in_a_game_that_asks_a_size
    error = refusal do
      screen :bitmap, size: [320, 200]
      scene(:map) { screen :tiled }
    end

    assert_match(/size:/, error.message)
  end

  # The refusals are the same on a console's build, so a game hears of a wrong size wherever it is
  # built.
  def test_a_console_build_refuses_a_wrong_size_too
    assert_raises(ArgumentError) { game { screen :bitmap, size: [0, 200] }.program }
  end

  # PLAYED: the whole screen filled and its far corner marked. Each build fills the screen it gives,
  # checked against the interpreter on every run that builds the game for a computer.
  def test_each_build_draws_on_the_screen_it_gives
    made = game([game_console]) do
      screen :bitmap, size: [320, 200]
      game_loop do
        fill_rect 0, 0, screen_width, screen_height, :blue
        pixel screen_width - 1, screen_height - 1, :green
      end
    end
    program = made.program(console: game_console, for_computer: computer_run?)
    width, height = program.described_console.screen_size

    played = game_player.run(program, frames: 2)

    assert_equal(computer_run? ? [320, 200] : VBlank::Console.described(game_console).screen_size, [width, height])
    assert_equal shown(:green), played.screen.pixel(width - 1, height - 1)
    assert_equal shown(:blue), played.screen.pixel(width - 2, height - 1)
  end
end
