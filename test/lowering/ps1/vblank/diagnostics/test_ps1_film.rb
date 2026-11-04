# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "stringio"
require "tmpdir"
require "vblank/diagnostics/film_tasks"

# A FILM OF A PLAYSTATION PROGRAM: a side naming a PS-X EXE opens in Beetle PSX, the PlayStation's
# emulator, and not in the Advance's, and plays and shows frames as any console's side does. The game
# is a small one of this repository's own: a red square on blue that walks right while right is down.
class TestPS1Film < Minitest::Test
  # A film is made by ImageMagick and ffmpeg and read back by ffprobe: child processes, which hang
  # inside a Ractor. And the task is defined in a rake application of the test's own.
  runs_on_the_main_ractor!

  FilmCartridge = VBlank::Diagnostics::FilmCartridge
  Verifier = VBlank::Diagnostics::Verifier
  RIGHT = VBlank::IR::Buttons.mask(:right)
  STRIP = 28

  def setup
    @rake_before = Rake.application
    Rake.application = Rake::Application.new
  end

  def teardown
    Rake.application = @rake_before
    FileUtils.rm_rf(@scratch) if @scratch
  end

  # The picture is the size the PlayStation's graphics chip shows, written as a PNG.
  def test_a_side_shows_the_picture_at_the_playstations_size
    side = FilmCartridge.open(game)
    side.step(4)
    shot = side.screenshot(File.join(scratch, "shot.png"))

    assert_equal [320, 240], png_size(shot)
  ensure
    side&.close
  end

  # The picture is the size the program set its graphics chip to: a program made by hand that shows a
  # screen 256 across is filmed 256 across, not cut to 320 or read past.
  def test_a_program_in_another_display_mode_is_filmed_at_its_own_size
    path = File.join(scratch, "narrow.exe")
    File.binwrite(path, narrow_program)
    side = FilmCartridge.open(path)
    side.step(3)

    assert_equal [256, 240], png_size(side.screenshot(File.join(scratch, "narrow.png")))
  ensure
    side&.close
  end

  # The cartridge and the game played as a lowering, filmed side by side, show the same pass on every
  # frame from the program's first picture, with right held on some frames.
  def test_the_program_and_a_lowering_show_the_same_frame
    %w[interpreter ruby].each do |lowering|
      program = FilmCartridge.open(game)
      lowered = FilmCartridge.open(game, lowering: lowering)
      (1..12).each do |frame|
        keys = frame.between?(4, 8) ? RIGHT : 0
        shown = [program, lowered].map do |side|
          File.binread(side.step(1, keys: keys).screenshot(File.join(scratch, "side.png")))
        end
        # Frame 1 is the console's own start, before the program's first picture.
        assert_equal shown.first, shown.last, "on #{lowering}, frame #{frame}" if frame > 1
      end
    ensure
      program&.close
      lowered&.close
    end
  end

  # A side opened from the program's file plays the same picture as one opened from the built program.
  def test_a_side_from_the_programs_file_shows_what_the_built_program_shows
    path = File.join(scratch, "walk.exe")
    game.write(path)

    assert_equal picture_after(FilmCartridge.open(game), 6, "built"),
                 picture_after(FilmCartridge.open(path), 6, "file")
  end

  # The shared button names reach the pad: right held walks the square, read back by the one reader.
  def test_a_step_holds_the_buttons_by_their_shared_names
    still = Verifier.new(game, frames: 0).step(10)
    walked = Verifier.new(game, frames: 0).step(10, keys: RIGHT)

    assert still.pixel_is?(20, 20, :red), "the square starts at 16"
    assert still.pixel_is?(14, 20, :blue)
    refute walked.pixel_is?(20, 20, :red), "right held walked the square away"
    assert walked.pixel_is?(30, 20, :red)
  ensure
    [still, walked].each { |reader| reader&.close }
  end

  # `rake film` with a PlayStation side, one a lambda answering the built program and one the program's
  # file: an MP4 twice the PlayStation's screen on each side.
  def test_rake_film_films_a_playstation_program
    built = game
    path = File.join(scratch, "walk.exe")
    built.write(path)
    FileUtils.mkdir_p(File.join(scratch, "films"))
    File.write(File.join(scratch, "films", "walk.rb"), "parts 1..3\nhold :right, on: 2..3\n")
    tasks = VBlank::Diagnostics::FilmTasks.new do |t|
      t.films = File.join(scratch, "films")
      t.out = File.join(scratch, "out")
      t.sides = { "built" => -> { built }, "file" => path }
    end

    film = tasks.make_film("walk")

    assert_equal [2 * 2 * 320, (2 * 240) + STRIP], video_size(film)
  end

  # A side that is a game to build is built for the console the side names: a game for the Advance and
  # the PlayStation, filmed at the PlayStation's size.
  def test_a_game_is_built_for_the_console_the_side_names
    side = FilmCartridge.open(two_console_game, console: :ps1)
    side.step(2)

    assert_equal [320, 240], png_size(side.screenshot(File.join(scratch, "ps1.png")))
  ensure
    side&.close
  end

  # `rake film CONSOLE=ps1` builds the Rakefile's game for the PlayStation.
  def test_rake_film_builds_the_game_for_the_console_named_on_the_command_line
    game = two_console_game
    FileUtils.mkdir_p(File.join(scratch, "films"))
    File.write(File.join(scratch, "films", "walk.rb"), "parts 1..2\n")
    tasks = VBlank::Diagnostics::FilmTasks.new do |t|
      t.films = File.join(scratch, "films")
      t.out = File.join(scratch, "out")
      t.sides = { "ours" => game }
    end

    with_env("CONSOLE" => "ps1", "NAME" => "walk") { capture_io { Rake::Task["film"].invoke } }
    film = File.join(scratch, "out", "walk.mp4")

    assert_equal [2 * 320, (2 * 240) + STRIP], video_size(film)
  end

  # A finished program opens in its own console's emulator: a side that names another console is
  # refused, saying what the file is.
  def test_a_program_file_named_as_another_console_is_refused
    path = File.join(scratch, "walk.exe")
    game.write(path)

    error = assert_raises(ArgumentError) { FilmCartridge.open(path, console: :gba) }
    assert_match(/PlayStation/, error.message)
    assert_match(/console: :ps1/, error.message)
  end

  private def scratch = @scratch ||= Dir.mktmpdir("ps1-film-test")

  # A PS-X EXE made by hand (psx-spx, "CDROM File Formats" and the CPU and GPU chapters): it sets the
  # graphics chip to show 256 × 240, turns the display on, and loops. t0 holds the ports' page, t1 the
  # command on its way to GP1.
  private def narrow_program
    load_at = 0x8001_0000
    gp1 = ->(command) { [0x3C09_0000 | (command >> 16), 0x3529_0000 | (command & 0xFFFF), 0xAD09_1814] }
    words = [0x3C08_1F80] + # LUI t0, 1F80h
            gp1.call(0x0800_0000) + # display mode: 256 across, 240 down
            gp1.call(0x0300_0000) # display on
    loop_at = load_at + (words.size * 4)
    words += [0x0800_0000 | ((loop_at >> 2) & 0x3FF_FFFF), 0] # J to itself, NOP
    code = words.pack("V*")
    code += "\0".b * ((-code.bytesize) % 0x800)
    header = "\0".b * 0x800
    header[0, 8] = "PS-X EXE"
    header[0x10, 4] = [load_at].pack("V")
    header[0x18, 8] = [load_at, code.bytesize].pack("V2")
    header[0x30, 4] = [0x801F_FFF0].pack("V")
    header + code
  end

  # The square game written once for two consoles, as a game file names them.
  private def two_console_game
    VBlank.game("FILMED", consoles: %i[gba ps1]) do
      x = var :x, 16
      game_loop do
        x += 1 if held(:right)
        clear_screen :blue
        draw_rect_at x, 16, 8, 8, :red
      end
    end
  end

  private def with_env(pairs)
    before = pairs.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    pairs.each { |key, value| ENV[key] = value }
    yield
  ensure
    before.each { |key, value| ENV[key] = value }
  end

  private def game
    @game ||= VBlank.build("FILMED", console: :ps1, out: StringIO.new, err: StringIO.new) do
      x = var :x, 16
      game_loop do
        x += 1 if held(:right)
        clear_screen :blue
        draw_rect_at x, 16, 8, 8, :red
      end
    end
  end

  # The PNG's bytes after +frames+ frames with nothing down.
  private def picture_after(side, frames, name)
    side.step(frames)
    File.binread(side.screenshot(File.join(scratch, "#{name}.png")))
  ensure
    side.close
  end

  # A PNG's width and height, from its header.
  private def png_size(path) = File.binread(path, 8, 16).unpack("N2")

  private def video_size(path)
    json, status = Open3.capture2("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                  "stream=width,height", "-of", "json", path)
    assert status.success?, "ffprobe read #{path}"
    stream = JSON.parse(json).fetch("streams").first
    [stream["width"], stream["height"]]
  end
end
