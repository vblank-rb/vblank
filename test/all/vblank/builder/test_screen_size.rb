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

  # A verb that lays itself out by the screen's size reads it as surely as `screen_width` does, so
  # it too must come after the line that can change it.
  def test_a_size_is_refused_after_a_verb_lays_itself_out_by_the_screen
    {
      draw_text: -> { draw_text "HI", :center, 0, :white },
      fade: -> { fade :black, 50, inside: [0, 0, 300, 10] },
      pixel: -> { pixel 0, 0, :white }
    }.each do |verb, line|
      error = refusal do
        instance_exec(&line)
        screen :bitmap, size: [320, 200]
      end

      assert_match(/`#{verb}`/, error.message)
    end
  end

  # Rows given up are counted on the screen the game asks for, the same on every build, and each
  # build keeps those of its own screen: a console's shorter screen shows every row the range holds.
  def test_shown_rows_are_counted_on_the_size_asked_and_kept_to_the_screen_given
    made = game { screen :bitmap, size: [320, 200], shown_rows: 20...180 }

    assert_equal [20, 180], made.program(for_computer: true).described_console.shown_row_bounds
    assert_equal [20, 160], made.program.described_console.shown_row_bounds
  end

  def test_shown_rows_of_every_asked_row_are_every_row_on_each_build
    made = game { screen :bitmap, size: [320, 200], shown_rows: 0...200 }

    assert_nil made.program(for_computer: true).shown_rows
    assert_nil made.program.shown_rows
  end

  def test_shown_rows_past_the_size_asked_are_refused_on_every_build
    made = game { screen :bitmap, size: [320, 200], shown_rows: 0...201 }

    assert_raises(ArgumentError) { made.program(for_computer: true) }
    assert_raises(ArgumentError) { made.program }
  end

  # Rows below a console's screen are none of its rows, which that console's build says plainly.
  def test_shown_rows_below_a_console_screen_are_refused_on_that_console
    made = game { screen :bitmap, size: [320, 200], shown_rows: 170...200 }

    assert_equal [170, 200], made.program(for_computer: true).described_console.shown_row_bounds
    error = assert_raises(ArgumentError) { made.program }
    assert_match(/160/, error.message)
  end

  # Big pixels show each of the game's pixels as a square, so a size they cannot fill whole is
  # refused, on every build.
  def test_a_size_that_big_pixels_cannot_fill_is_refused
    [[321, 200], [1, 1]].each do |size|
      error = refusal { screen :bitmap, size: size, pixel_size: 2 }

      assert_match(/pixel_size: 2/, error.message)
      assert_raises(ArgumentError) { game { screen :bitmap, size: size, pixel_size: 2 }.program }
    end
  end

  def test_big_pixels_draw_half_the_size_asked
    made = game { screen :bitmap, size: [320, 200], pixel_size: 2 }

    assert_equal [160, 100], made.program(for_computer: true).described_console.screen_size
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
