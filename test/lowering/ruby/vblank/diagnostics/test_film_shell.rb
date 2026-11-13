# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require "shell_tests"

# A PORT'S SHELL FILMED FROM ITS FIRST START (Diagnostics::FilmShell), with the made-up port
# (shell_tests.rb's). On the Ruby run alone: the shell plays as Ruby whatever run it is in.
#
# The answer key is the shell played by Live::Shell on a Headless device, as the shell tests play
# it, and the same game built all-in-one, played live the same way.
class TestFilmShell < Minitest::Test
  include ShellTests

  FilmShell = VBlank::Diagnostics::FilmShell
  Headless = VBlank::Live::Headless
  Session = VBlank::Live::Session

  # How many frames of the game each test watches, and more film frames than the menu and the
  # made-up unpacking take together.
  GAME_PASSES = 6
  MOST_FRAMES = 400

  # The menu's line LOAD ROM (Original::Shell.menu_program), and the colour it is drawn in under the
  # cursor.
  LOAD_ROM_ROWS = (80...88)
  WHITE = Color.resolve(:white)

  # The pictures the all-in-one build of the port shows over its first GAME_PASSES passes.
  private def all_in_one_pictures(game)
    device = Headless.new(frames: GAME_PASSES)
    Session.new(game.checked_program(err: nil, for_computer: true)).play(device)
    device.pictures.map(&:pixels)
  end

  # +side+ stepped until its game shows (+shell+ says when) and GAME_PASSES frames more, each frame's
  # pixels kept, the film frame the game began on first.
  private def film_frames(shell, side)
    frames = []
    until shell.game_began_on && frames.size >= shell.game_began_on - 1 + GAME_PASSES
      flunk "the shell's game never began in #{MOST_FRAMES} frames" if frames.size >= MOST_FRAMES
      frames << side.step(1).pixels
    end
    frames
  end

  private def colors_on(pixels, rows) = rows.flat_map { |row| pixels[row * 240, 240] }.uniq - [Color.resolve(:black)]

  # The film opens on the shell's menu, shows the bar while the copy unpacks, and then the game, whose
  # pictures are the all-in-one build's.
  def test_a_shell_is_filmed_from_the_menu_through_the_unpacking_to_the_game
    Dir.mktmpdir do |folder|
      game = port(original(folder))
      shell = FilmShell.new(game)
      side = shell.open
      frames = film_frames(shell, side)
      side.close
      began = shell.game_began_on
      bar = frames[began - 2]

      assert_equal [WHITE], colors_on(frames.first, LOAD_ROM_ROWS), "the film does not open on the shell's menu"
      assert_equal WHITE, bar[(80 * 240) + 120], "the frame before the game is not the unpacking's full bar"
      assert_equal all_in_one_pictures(game), frames.last(GAME_PASSES)
    end
  end

  # The all-in-one side is a display switched off until the frame the shell's game began on, and
  # from there the same pictures as the shell's game.
  def test_the_all_in_one_build_starts_on_the_frame_the_shells_game_began_on
    Dir.mktmpdir do |folder|
      shell = FilmShell.new(port(original(folder)))
      shell_side = shell.open
      shell_frames = film_frames(shell, shell_side)
      shell_side.close
      side = shell.all_in_one
      frames = Array.new(shell_frames.size) { side.step(1).pixels }
      side.close
      began = shell.game_began_on

      assert_equal [VBlank::IR::Backends::Reference::Framebuffer::HELD_OFF], frames[began - 2].uniq
      assert_equal shell_frames.last(GAME_PASSES), frames.last(GAME_PASSES)
    end
  end

  # The film's buttons reach the game, as they reach a cartridge's side, and the menu's own press
  # does not: the game's first frames show no square until the film holds A.
  def test_the_films_buttons_reach_the_shells_game
    Dir.mktmpdir do |folder|
      shell = FilmShell.new(buttons_port(original(folder)))
      side = shell.open
      MOST_FRAMES.times { side.step(1) unless shell.game_began_on }
      first = side.pixels
      held = side.step(1, keys: VBlank::IR::Buttons.mask(:a)).pixels
      side.close

      refute_equal WHITE, first[(40 * 240) + 10], "the game showed A held before the film held it"
      assert_equal WHITE, held[(40 * 240) + 10], "A held on the film did not reach the game"
    end
  end

  # The made-up port, drawing a white square while A is held.
  private def buttons_port(from)
    VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      pack = data_pack(from: from, version: "1") do |slots|
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.fill_from_copy { |copy, into| copy.unpack_rle at: RLE_AT, into: into[:heights] }
      end
      heights = table :heights, pack[:heights]
      game_loop do
        clear_screen :black
        draw_rect_at heights[0], 40, 4, 4, :red
        draw_rect_at 10, 40, 4, 4, :white if held(:a)
      end
    end
  end

  # A machine that names no copy cannot film the shell's first start, and says how to name one.
  def test_a_machine_naming_no_copy_is_told_so
    Dir.mktmpdir do |folder|
      assert_raises(VBlank::Original::NotSet) { FilmShell.new(port_without_copy(folder)) }
    end
  end

  # The all-in-one side needs the frame the shell's game began on, so it comes after the shell's.
  def test_the_all_in_one_side_before_the_shells_is_refused
    Dir.mktmpdir do |folder|
      refused = assert_raises(ArgumentError) { FilmShell.new(port(original(folder))).all_in_one }

      assert_match "put the shell's side first", refused.message
    end
  end

  # Closing the side takes away the folder the copy was handed in and the pack kept, even part way
  # through the unpacking.
  def test_closing_the_side_leaves_nothing_of_the_copy
    Dir.mktmpdir do |folder|
      shell = FilmShell.new(port(original(folder)))
      side = shell.open
      3.times { side.step(1) }
      during = side_folders
      side.close

      refute_empty during, "the side kept no folder of its own"
      assert_empty side_folders
    end
  end

  # The folders sides opened in this process keep the copy and the pack in (Dir.mktmpdir names them
  # with the process's number; the tests run in several processes at once).
  private def side_folders = Dir.children(Dir.tmpdir).grep(/\Afilm-shell\d+-#{Process.pid}-/)

  # The film itself, made by Film from the two sides: an MP4, and nothing else, in its folder.
  def test_film_makes_a_film_of_the_shell_beside_the_all_in_one_build
    Dir.mktmpdir do |folder|
      shell = FilmShell.new(port(original(folder)))
      out = File.join(folder, "films")
      path = VBlank::Diagnostics::Film.make(File.join(out, "shell.mp4"),
                                            sides: { "shell" => -> { shell.open }, "all-in-one" => -> { shell.all_in_one } },
                                            parts: [1..40])

      assert_operator File.size(path), :>, 0
      assert_equal ["shell.mp4"], Dir.children(out)
    end
  end
end
