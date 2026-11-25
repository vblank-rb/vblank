# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require "vblank/diagnostics/film_tasks"
require "shell_tests"
require "heard_film"

# A port's shell filmed from its first start (Diagnostics::FilmShell), with the made-up port
# (shell_tests.rb's). On the Ruby run alone: the shell plays as Ruby whatever run it is in.
#
# The answer key is the shell played by Live::Shell on a Headless device, as the shell tests play
# it, and the same game built all-in-one, played live the same way.
class TestFilmShell < Minitest::Test
  include ShellTests
  include HeardFilm

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

  # Rounds of work the busy port's unpacking does before it writes (ShellTests#busy_port's): enough
  # that its game, filmed from the menu, begins some tens of frames later than with one round.
  BUSY_STEPS = 3_000_000

  # Counted from the game's start, the shell's side shows the same frames of the game however many
  # frames the unpacking took, and the all-in-one side beside it starts on its first.
  def test_a_side_counted_from_the_game_shows_the_same_frames_however_long_the_unpacking_took
    films = [1, BUSY_STEPS].map do |steps|
      Dir.mktmpdir do |folder|
        shell = FilmShell.new(moving_busy_port(original(folder), steps: steps))
        side = shell.open(from: :game)
        frames = Array.new(GAME_PASSES) { side.step(1).pixels }
        side.close
        beside = shell.all_in_one
        frames_beside = Array.new(GAME_PASSES) { beside.step(1).pixels }
        beside.close

        assert_equal frames, frames_beside, "the all-in-one side does not start on the shell's game's first frame"
        frames
      end
    end
    expected = Dir.mktmpdir { |folder| all_in_one_pictures(moving_busy_port(original(folder), steps: 1)) }

    assert_equal expected, films.first
    assert_equal expected, films.last
  end

  # A film file with `start_from :game` opens the shell its Rakefile names (FilmTasks#shell) as two
  # sides, the shell's and the all-in-one build's, each on the game's first frame.
  def test_a_film_file_started_from_the_game_opens_the_rakefiles_shell_on_the_games_first_frame
    Dir.mktmpdir do |folder|
      game = moving_busy_port(original(folder), steps: 1)
      path = File.join(folder, "start.rb")
      File.write(path, "start_from :game\nparts 1..#{GAME_PASSES}\n")
      openers = VBlank::Diagnostics::FilmScript.read(path, shell: -> { game }).side_openers
      films = openers.transform_values do |opener|
        side = opener.call
        frames = Array.new(GAME_PASSES) { side.step(1).pixels }
        side.close
        frames
      end
      expected = all_in_one_pictures(game)

      assert_equal %w[shell all-in-one], films.keys
      assert_equal expected, films["shell"]
      assert_equal expected, films["all-in-one"]
    end
  end

  # `rake film` with a shell in the Rakefile writes the film under its name, the sides being the ones
  # the test above opens.
  def test_rake_film_films_the_rakefiles_shell_beside_its_all_in_one_build
    rake_before = Rake.application
    Rake.application = Rake::Application.new
    Dir.mktmpdir do |folder|
      game = port(original(folder))
      FileUtils.mkdir_p(File.join(folder, "films"))
      File.write(File.join(folder, "films", "start.rb"), "start_from :game\nparts 1..3\n")
      tasks = VBlank::Diagnostics::FilmTasks.new do |t|
        t.films = File.join(folder, "films")
        t.out = File.join(folder, "out")
        t.shell = -> { game }
      end

      film = tasks.make_film("start")

      assert_equal File.join(folder, "out", "start.mp4"), film
      assert_operator File.size(film), :>, 0
    end
  ensure
    Rake.application = rake_before
  end

  # Starting from the game counts from a shell's game, so a film with no shell is told to name one.
  def test_a_film_started_from_the_game_with_no_shell_is_told_to_name_one
    Dir.mktmpdir do |folder|
      path = File.join(folder, "start.rb")
      File.write(path, "start_from :game\nparts 1..3\nside \"ours\", \"ours.gba\"\n")
      refused = assert_raises(ArgumentError) { VBlank::Diagnostics::FilmScript.read(path) }

      assert_match "t.shell", refused.message
    end
  end

  def test_a_shell_side_from_an_unknown_place_is_refused
    Dir.mktmpdir do |folder|
      refused = assert_raises(ArgumentError) { FilmShell.new(port(original(folder))).open(from: :title) }

      assert_match "from: :game", refused.message
    end
  end

  # A port whose unpacking works +steps+ rounds before it writes (ShellTests#busy_port), and whose
  # game moves a square a pixel each pass, so two frames of the game apart never look alike.
  private def moving_busy_port(from, steps:)
    VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      pack = data_pack(from: from, version: "1") do |slots|
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.fill_from_copy do |copy, into|
          busy = 0
          mixed = 0
          while busy < steps
            mixed = ((mixed * 31) + copy.byte(mixed & 255)) & 0xFFFF
            busy += 1
          end
          copy.unpack_rle at: RLE_AT, into: into[:heights]
        end
      end
      heights = table :heights, pack[:heights]
      step = var :step, 0
      game_loop do
        clear_screen :black
        draw_rect_at step, 40 + heights[0], 4, 4, :white
        step = (step + 1) & 127
      end
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

  # A film whose parts end before the shell's game begins has no frame to start the all-in-one side
  # on. The two sides play at the same time, so the all-in-one side learns it as the shell's side ends,
  # and the film stops saying so, rather than waiting for a frame that never comes.
  def test_a_film_ending_before_the_shells_game_begins_is_refused
    Dir.mktmpdir do |folder|
      shell = FilmShell.new(port(original(folder)))
      refused = assert_raises(ArgumentError) do
        VBlank::Diagnostics::Film.make(File.join(folder, "never.mp4"),
                                       sides: { "shell" => -> { shell.open }, "all-in-one" => -> { shell.all_in_one } },
                                       parts: [1..2])
      end

      assert_match "has not shown the game yet", refused.message
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

  # The game's pass a beeping port starts its tone on.
  BEEP_PASS = 10

  # Both sides heard, one on each speaker: the shell's game and the all-in-one build start their tone on
  # the same frame of the film, the pass the game sounds it on.
  def test_the_shell_and_the_all_in_one_build_are_heard_on_the_same_frames
    Dir.mktmpdir do |folder|
      shell = FilmShell.new(beeping_port(original(folder)))
      path = VBlank::Diagnostics::Film.make(File.join(folder, "heard.mp4"),
                                            sides: { "shell" => -> { shell.open(from: :game, sound: true) },
                                                     "all-in-one" => -> { shell.all_in_one(sound: true) } },
                                            parts: [1..30], sound: :side_by_side)
      left, right = film_sound(path)

      assert_in_delta BEEP_PASS - 1, onset(left), 1
      assert_in_delta onset(left), onset(right), 1
    end
  end

  # A shell's side opened without sound is refused when heard, saying how to open it.
  def test_a_shell_side_opened_without_sound_cannot_be_heard
    Dir.mktmpdir do |folder|
      shell = FilmShell.new(beeping_port(original(folder)))
      refused = assert_raises(ArgumentError) do
        VBlank::Diagnostics::Film.make(File.join(folder, "never.mp4"), sides: { "shell" => -> { shell.open(from: :game) } },
                                                                       parts: [1..2], sound: "shell")
      end

      assert_match "sound: true", refused.message
    end
  end

  # The made-up port, sounding a tone that does not fade from its game's pass BEEP_PASS.
  private def beeping_port(from)
    VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      enable_sound
      pack = data_pack(from: from, version: "1") do |slots|
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.fill_from_copy { |copy, into| copy.unpack_rle at: RLE_AT, into: into[:heights] }
      end
      heights = table :heights, pack[:heights]
      game_loop do
        clear_screen :black
        draw_rect_at heights[0], 40, 4, 4, :red
        after(BEEP_PASS - 1) { beep 440, decay: :none }
      end
    end
  end

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
