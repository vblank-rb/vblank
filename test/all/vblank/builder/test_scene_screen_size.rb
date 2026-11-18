# frozen_string_literal: true

require "test_helper"

# A SCENE'S OWN SCREEN SIZE: `screen :bitmap, size: [240, 160]` on a scene's screen line, in a game
# that asks for a bigger screen on its first. A computer's build shows that scene at its size, in the
# middle of the game's window, and the scenes that ask none at the game's; each console keeps its own
# screen for every scene. `screen_width` and `screen_height` answer the scene's size while its block is
# built, so a still laid out for 320x200 and play laid out for 240x160 share one file.
class TestSceneScreenSize < Minitest::Test
  include VBlank::Testing

  # Whether this run's player can play the tree a computer's build plays: a computer's own build,
  # or the interpreter, which is the answer key for every build. A cartridge plays its console's.
  private def plays_computer_builds? = computer_run? || !VBlank::Testing.checked?

  private def game(consoles = %i[gba], &block) = VBlank.game("SCENESIZE", consoles: consoles, &block)

  private def refusal(&block)
    assert_raises(ArgumentError) { game(&block).program(for_computer: true) }
  end

  # The sizes each scene read while it was built, by scene.
  private def sizes_read(for_computer:)
    read = {}
    game do
      screen :bitmap, size: [320, 200]
      mode = :still
      scene(:still) do
        screen :bitmap
        read[:still] = [screen_width, screen_height]
      end
      scene(:play) do
        screen :bitmap, size: [240, 160]
        read[:play] = [screen_width, screen_height]
      end
      game_loop do
        mode = :play if pressed(:a)
        call mode
      end
    end.program(for_computer: for_computer)
    read
  end

  def test_a_computer_build_lays_each_scene_out_on_its_own_size
    assert_equal({ still: [320, 200], play: [240, 160] }, sizes_read(for_computer: true))
  end

  def test_a_console_lays_every_scene_out_on_its_own_screen
    assert_equal({ still: [240, 160], play: [240, 160] }, sizes_read(for_computer: false))
  end

  # A routine written inside a sized scene's block (`once_a_frame`, `each_pass`, a `func`) is built
  # as a routine of its own, after the scene's: it is laid out on the scene's size all the same.
  def test_routines_written_inside_a_scene_take_its_size
    read = {}
    game do
      screen :bitmap, size: [320, 200]
      mode = :play
      scene(:play) do
        screen :bitmap, size: [240, 160]
        read[:scene] = screen_width
        once_a_frame { read[:once_a_frame] = screen_width }
        each_pass { read[:each_pass] = screen_width }
        func(:inner) { read[:func] = screen_width }
        call :inner
      end
      scene(:still) { screen :bitmap }
      game_loop do
        mode = :still if pressed(:a)
        call mode
      end
    end.program(for_computer: true)

    assert_equal({ scene: 240, once_a_frame: 240, each_pass: 240, func: 240 }, read)
  end

  # Centred text in a sized scene's `once_a_frame` is centred on the scene's screen.
  def test_centred_text_in_a_sized_scenes_routine_is_centred_on_its_screen
    made = game([game_console]) do
      screen :bitmap, size: [320, 200]
      mode = :play
      scene(:play) do
        screen :bitmap, size: [240, 160]
        once_a_frame do
          clear_screen :black
          draw_text "HI", :center, 10, :white
        end
      end
      scene(:still) { screen :bitmap }
      game_loop do
        mode = :still if pressed(:a)
        call mode
      end
    end
    played = game_player.run(made.program(console: game_console, for_computer: plays_computer_builds?), frames: 3)
    width = played.shown_screen_size[0]
    columns = (0...320).select { |x| (10...20).any? { |y| played.screen.pixel(x, y) == shown(:white) } }

    assert_equal(plays_computer_builds? ? 240 : VBlank::Console.described(game_console).screen_width, width)
    refute_empty columns
    assert_in_delta width / 2, (columns.first + columns.last) / 2.0, 2, "centred on the scene's #{width} columns"
  end

  def test_a_scene_size_needs_a_size_for_the_game
    error = refusal do
      screen :bitmap
      mode = :play
      scene(:play) { screen :bitmap, size: [240, 160] }
      game_loop { call mode }
    end

    assert_match(/first `screen` line/, error.message)
  end

  def test_a_scene_size_bigger_than_the_game_size_is_refused
    error = refusal do
      screen :bitmap, size: [320, 200]
      mode = :play
      scene(:play) { screen :bitmap, size: [400, 160] }
      game_loop { call mode }
    end

    assert_match(/320/, error.message)
  end

  def test_a_scene_size_after_the_scene_reads_the_screen_size_is_refused
    error = refusal do
      screen :bitmap, size: [320, 200]
      mode = :play
      scene(:play) do
        screen_width
        screen :bitmap, size: [240, 160]
      end
      game_loop { call mode }
    end

    assert_match(/screen_width/, error.message)
  end

  def test_a_scene_size_on_a_later_screen_line_of_the_scene_is_refused
    error = refusal do
      screen :bitmap, size: [320, 200]
      mode = :play
      scene(:play) do
        screen :bitmap
        screen :bitmap, size: [240, 160]
      end
      game_loop { call mode }
    end

    assert_match(/scene's first `screen` line/, error.message)
  end

  # A scene with no screen line shows the screen the scene before it left, so in a game whose
  # scenes are different sizes it could not know its own.
  def test_a_scene_with_no_screen_line_is_refused_where_scenes_have_sizes
    error = refusal do
      screen :bitmap, size: [320, 200]
      mode = :play
      scene(:play) { screen :bitmap, size: [240, 160] }
      scene(:quiet) { clear_screen :black }
      game_loop { call mode }
    end

    assert_match(/:quiet/, error.message)
  end

  # PLAYED: two passes of a still at the game's size, then play at its own. Each fills the screen it
  # is laid out on and marks its far corner; the size shown follows the scene, frame by frame, held to
  # the interpreter on every run that builds the game for a computer.
  def test_the_size_shown_follows_the_scene
    made = game([game_console]) do
      screen :bitmap, size: [320, 200]
      mode = :still
      passes = 0
      scene(:still) do
        screen :bitmap
        fill_rect 0, 0, screen_width, screen_height, :blue
        pixel screen_width - 1, screen_height - 1, :green
      end
      scene(:play) do
        screen :bitmap, size: [240, 160]
        fill_rect 0, 0, screen_width, screen_height, :green
        pixel screen_width - 1, screen_height - 1, :blue
      end
      game_loop do
        passes += 1
        mode = :play if passes == 3
        call mode
      end
    end
    program = made.program(console: game_console, for_computer: plays_computer_builds?)
    console = VBlank::Console.described(game_console).screen_size
    still, play = plays_computer_builds? ? [[320, 200], [240, 160]] : [console, console]
    player = game_player
    seen = []
    player.each_vblank do
      size = player.shown_screen_size
      seen << [size, player.screen.pixel(size[0] - 1, size[1] - 1)]
    end
    player.run(program, frames: 6)

    assert_equal [still, shown(:green)], seen[1]
    assert_equal [play, shown(:blue)], seen.last
  end
end
