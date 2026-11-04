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

  private def scratch = @scratch ||= Dir.mktmpdir("ps1-film-test")

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
