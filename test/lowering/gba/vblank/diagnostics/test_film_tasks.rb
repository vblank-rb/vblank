# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "stringio"
require "tmpdir"
require "vblank/diagnostics/film_tasks"

# A GAME'S `rake film NAME=...`: the film files in its folder, each a few lines naming frames and
# buttons, made into MP4s of the sides its Rakefile names. The games here are small ones of this
# repository's own, filmed beside themselves.
class TestFilmTasks < Minitest::Test
  # A film is made by ImageMagick and ffmpeg and read back by ffprobe: child processes, which hang
  # inside a Ractor. And the task is defined in a rake application of the test's own.
  runs_on_the_main_ractor!

  STRIP = 28

  def setup
    require_emulator!
    @rake_before = Rake.application
    Rake.application = Rake::Application.new
  end

  def teardown
    Rake.application = @rake_before
    FileUtils.rm_rf(@scratch) if @scratch
  end

  # One side a built cartridge and the other the same game's file: two sides, twice the Advance's
  # screen each, written where the task says under the film's name.
  def test_rake_film_writes_the_named_film_of_both_sides
    rom = dot_game(:gba)
    path = File.join(scratch, "dot.gba")
    rom.write(path)
    film_file("walk", "parts 1..3, 6..7\nhold :right, on: 2..6\n")
    tasks(sides: { "ours" => -> { rom }, "from its file" => path })

    said = with_name("walk") { capture_io { Rake::Task["film"].invoke }.first }

    film = File.join(scratch, "out", "walk.mp4")
    assert_match(/The film is at .*walk\.mp4/, said)
    assert_equal [2 * 2 * 240, (2 * 160) + STRIP], video_size(film)
  end

  # The screen's size is the console's: a Color cartridge, at the scale the film asks, on a side the
  # film names itself.
  def test_a_color_game_is_filmed_at_its_own_screens_size
    path = File.join(scratch, "dot.gbc")
    dot_game(:gbc).write(path)
    film_file("color", "parts 1..2\nscale 3\nside \"color\", #{path.inspect}\n")

    film = tasks.make_film("color")

    assert_equal [3 * 160, (3 * 144) + STRIP], video_size(film)
  end

  # `LOWERING=ruby` films the game built as Ruby: a side whose game the task can reach. A side the
  # film file names with a lowering of its own keeps it.
  def test_rake_film_plays_the_lowering_named_on_the_command_line
    rom = dot_game(:gba)
    film_file("walk", "parts 1..2\nside(\"interpreted\", lowering: \"interpreter\") do\n  " \
                      "VBlank.build(\"FILMED\", console: :gba, out: nil, err: nil) { game_loop { clear_screen :red } }\nend\n")
    tasks(sides: { "ours" => -> { rom } })

    with_name("walk") { with_env("LOWERING", "ruby") { capture_io { Rake::Task["film"].invoke } } }

    assert_equal [2 * 2 * 240, (2 * 160) + STRIP], video_size(File.join(scratch, "out", "walk.mp4"))
  end

  # The lowering reaches the Rakefile's sides: a cartridge file has no game to play another way.
  def test_the_command_lines_lowering_reaches_the_rakefiles_sides
    path = File.join(scratch, "dot.gba")
    dot_game(:gba).write(path)
    film_file("walk", "parts 1..2\n")
    tasks(sides: { "file" => path })

    error = assert_raises(ArgumentError) do
      with_name("walk") { with_env("LOWERING", "ruby") { Rake::Task["film"].invoke } }
    end
    assert_match(/only in the emulator/, error.message)
  end

  # `rake film LOWERING= CONSOLE=`, empty, says nothing: the Rakefile's still hold.
  def test_an_empty_setting_on_the_command_line_keeps_the_rakefiles
    path = File.join(scratch, "dot.gba")
    dot_game(:gba).write(path)
    film_file("walk", "parts 1..2\n")
    rakefile = tasks(sides: { "file" => path })
    rakefile.lowering = "ruby"
    rakefile.console = :gbc

    error = assert_raises(ArgumentError) do
      with_name("walk") { with_env("CONSOLE", "") { Rake::Task["film"].invoke } }
    end
    assert_match(/console: :gbc/, error.message, "the Rakefile's console")

    rakefile.console = nil
    Rake::Task["film"].reenable
    error = assert_raises(ArgumentError) do
      with_name("walk") { with_env("LOWERING", "") { Rake::Task["film"].invoke } }
    end
    assert_match(/only in the emulator/, error.message, "the Rakefile's lowering")
  end

  def test_an_unknown_lowering_on_the_command_line_is_refused_before_any_side_opens
    film_file("walk", "parts 1..2\nside(\"ours\") { raise \"opened\" }\n")
    tasks

    error = assert_raises(ArgumentError) do
      with_name("walk") { with_env("LOWERING", "gameboy") { Rake::Task["film"].invoke } }
    end
    assert_match(/"gameboy"/, error.message)
  end

  def test_an_unknown_console_on_the_command_line_is_refused_before_any_side_opens
    film_file("walk", "parts 1..2\nside(\"ours\") { raise \"opened\" }\n")
    tasks

    error = assert_raises(ArgumentError) do
      with_name("walk") { with_env("CONSOLE", "xbox") { Rake::Task["film"].invoke } }
    end
    assert_match(/"xbox"/, error.message)
  end

  def test_without_a_name_the_films_there_are_are_listed
    film_file("walk", "parts 1..2\n")
    film_file("door", "parts 1..2\n")

    error = assert_raises(SystemExit) { capture_io { tasks.make_film(nil) } }
    assert_match(/NAME=door/, error.message)
    assert_match(/door, walk/, error.message)
  end

  def test_a_film_that_is_not_there_is_named
    film_file("walk", "parts 1..2\n")

    error = assert_raises(SystemExit) { capture_io { tasks.make_film("door") } }
    assert_match(/no film called door/, error.message)
  end

  def test_missing_ffmpeg_says_what_to_install_before_any_cartridge_opens
    film_file("walk", "parts 1..2\nside(\"ours\") { raise \"opened\" }\n")

    error = assert_raises(VBlank::Diagnostics::Film::MissingTool) do
      tasks.make_film("walk", search_path: Dir.mktmpdir("film-path", scratch))
    end
    assert_match(/brew install ffmpeg/, error.message)
  end

  def test_a_film_with_no_frames_to_show_says_how_to_name_them
    film_file("walk", "hold :a, on: 2\n")

    error = assert_raises(ArgumentError) { tasks(sides: { "ours" => "x.gba" }).make_film("walk") }
    assert_match(/parts 1\.\.90/, error.message)
  end

  private def scratch = @scratch ||= Dir.mktmpdir("film-tasks-test")

  private def tasks(sides: {})
    VBlank::Diagnostics::FilmTasks.new do |t|
      t.films = File.join(scratch, "films")
      t.out = File.join(scratch, "out")
      t.sides = sides
    end
  end

  private def film_file(name, text)
    FileUtils.mkdir_p(File.join(scratch, "films"))
    File.write(File.join(scratch, "films", "#{name}.rb"), text)
  end

  private def with_name(name, &) = with_env("NAME", name, &)

  private def with_env(key, value)
    before = ENV.fetch(key, nil)
    ENV[key] = value
    yield
  ensure
    ENV[key] = before
  end

  # A square that walks right while the right button is down.
  private def dot_game(console)
    VBlank.build("FILMED", console: console, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :red) { "########\n" * 8 }
      dot = sprite :dot, at: [16, 24]
      game_loop { dot.x += 1 if held(:right) }
    end
  end

  private def video_size(path)
    json, status = Open3.capture2("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                  "stream=width,height", "-of", "json", path)
    assert status.success?, "ffprobe read #{path}"
    stream = JSON.parse(json).fetch("streams").first
    [stream["width"], stream["height"]]
  end
end
