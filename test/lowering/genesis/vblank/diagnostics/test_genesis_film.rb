# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "stringio"
require "tmpdir"
require "vblank/diagnostics/film_tasks"

# A GENESIS CARTRIDGE THROUGH THE ONE READER: it names its sprites as the interpreter does, and it is
# filmed as any console's cartridge is, a built one beside its file, at the Genesis's 320 x 224. The
# game is a small one of this repository's own: a white box that walks right while right is down, and
# a red mark that stays where it is, on a blue field.
class TestGenesisFilm < Minitest::Test
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

  # The reader's rows are the interpreter's after as many passes with right held: the walked box, and
  # the mark where it stays. Asked by name, each sprite's rows alone.
  def test_the_reader_names_each_sprite_as_the_interpreter_does
    reader = Verifier.new(game, frames: 0).step(20, keys: RIGHT)
    interpreter = VBlank::IR::Backends::Reference.new
    interpreter.hold(:right)
    interpreter.run(game.source_program, frames: reader.passes)

    assert_operator reader.var(:x), :>, 16, "right held walked the box"
    assert_equal interpreter.sprites, reader.sprites
    assert_equal interpreter.sprites(:box), reader.sprites(:box)
    assert_equal [[100, 80]], reader.sprites(:mark).map { |row| [row.x, row.y] }
  ensure
    reader&.close
  end

  # A side made from the built cartridge and one from its file show the same picture, at the Genesis's size.
  def test_a_side_from_the_file_shows_what_the_built_cartridge_shows
    path = File.join(scratch, "walk.md")
    game.write(path)
    built = picture_after(FilmCartridge.open(game), 12, "built")

    assert_equal [320, 224], png_size(File.join(scratch, "built.png"))
    assert_equal built, picture_after(FilmCartridge.open(path), 12, "file")
  end

  # `rake film` with two Genesis sides, the built cartridge and a cartridge file VBlank only reads: an
  # MP4 twice the Genesis's screen on each side.
  def test_rake_film_films_a_built_genesis_cartridge_beside_a_cartridge_file
    built = game
    path = File.join(scratch, "walk.md")
    built.write(path)
    FileUtils.mkdir_p(File.join(scratch, "films"))
    File.write(File.join(scratch, "films", "walk.rb"), "parts 1..3\nhold :right, on: 2..3\n")
    tasks = VBlank::Diagnostics::FilmTasks.new do |t|
      t.films = File.join(scratch, "films")
      t.out = File.join(scratch, "out")
      t.sides = { "built" => -> { built }, "file" => path }
    end

    film = tasks.make_film("walk")

    assert_equal [2 * 2 * 320, (2 * 224) + STRIP], video_size(film)
  end

  private def scratch = @scratch ||= Dir.mktmpdir("genesis-film-test")

  private def game
    @game ||= VBlank.build("FILMED", console: :genesis, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:mark, "#" => :red) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(32) { "." * 40 }
      box = sprite :box, at: [16, 40]
      sprite :mark, at: [100, 80]
      x = var :x, 16
      game_loop do
        x += 1 if held(:right)
        box.x = x
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
