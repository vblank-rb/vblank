# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "tmpdir"

# A film of one cartridge, or of two side by side: every frame of the parts asked for, doubled,
# over a strip naming each side, held at the end of each part and at the end of the film, and
# written as an MP4 at the console's sixty frames a second.
#
# The games here paint the whole screen one of four colours, a different one each frame, so which
# frame of which game a moment of the film shows can be read off one pixel of it. Their first frame
# is the console's blank white, before the game has painted anything, which is the second game's
# first colour too; so a test that tells the two apart starts on the second frame.
class TestFilm < Minitest::Test
  # A film is made by ImageMagick and ffmpeg, and its MP4 read back by ffprobe and ffmpeg: child
  # processes, which hang inside a Ractor.
  runs_on_the_main_ractor!

  Film = VBlank::Diagnostics::Film

  # The four colours as a decoded MP4 shows them, eight bits a channel.
  SHADES = { red: [255, 0, 0], green: [0, 255, 0], blue: [0, 0, 255], white: [255, 255, 255] }.freeze
  CYCLE = %i[red green blue white].freeze
  # The second game goes round the same colours the other way, so the two halves of the film
  # cannot be one game shown twice.
  CYCLE_BACKWARDS = CYCLE.reverse.freeze

  PART_END_HOLD = 48 # 0.8 s at sixty frames a second
  SHORTEST = 180 # 3 s
  STRIP = 28

  # The pixel of the game read throughout, on the cartridge and in the film (where it is at twice
  # these, below the strip). The same pixel both ways: on a game's first frame the screen can be
  # part painted, so two pixels of one frame need not agree.
  GAME_X = 60
  GAME_Y = 80

  def test_two_sides_are_doubled_side_by_side_over_a_strip
    film = make_film(parts: [1..3, 5..6])
    shape = video_shape(film)

    assert_equal [2 * 2 * 240, (2 * 160) + STRIP], [shape[:width], shape[:height]]
    assert_equal "60/1", shape[:rate]
    strip = decoded_frames(film, shape).first
    assert_in_delta 32, strip_pixel(strip, shape, 4, 1).max, 6, "the strip is dark grey"
    [0, 2 * 240].each do |side_left|
      assert(text_in_strip?(strip, shape, side_left), "the side starting at x=#{side_left} has a label")
    end
  end

  # Each part's last frame is held 0.8 s, and the film is made up to 3 s by holding its last frame.
  def test_each_part_ends_on_a_held_frame_and_the_film_lasts_three_seconds
    film = make_film(parts: [2..3, 5..6])
    shape = video_shape(film)
    reel = expected_reel([[2, 1], [3, PART_END_HOLD], [5, 1], [6, SHORTEST - 50]])

    assert_equal SHORTEST, shape[:frames]
    assert_in_delta 3.0, shape[:seconds], 0.02
    assert_equal reel.map { |frame| CYCLE[colour_index(frame)] }, colours_at(film, shape, x: GAME_X * 2)
    assert_equal reel.map { |frame| CYCLE_BACKWARDS[colour_index(frame)] }, colours_at(film, shape, x: 480 + (GAME_X * 2))
  end

  # Holds that come to more than three seconds are not made any longer.
  def test_a_film_longer_than_three_seconds_has_no_extra_hold
    film = make_film(parts: [1..2, 4..5, 7..8, 10..11], sides: 1)
    shape = video_shape(film)
    reel = expected_reel([2, 5, 8, 11].flat_map { |last| [[last - 1, 1], [last, PART_END_HOLD]] })

    assert_equal 4 * (PART_END_HOLD + 1), shape[:frames]
    assert_equal reel.map { |frame| CYCLE[colour_index(frame)] }, colours_at(film, shape, x: GAME_X * 2)
  end

  # A range that leaves out its end is held on the last frame it shows.
  def test_a_part_that_leaves_out_its_end_is_held_on_its_last_frame
    film = make_film(parts: [2...4, 5..6])
    shape = video_shape(film)
    reel = expected_reel([[2, 1], [3, PART_END_HOLD], [5, 1], [6, SHORTEST - 50]])

    assert_equal reel.map { |frame| CYCLE[colour_index(frame)] }, colours_at(film, shape, x: GAME_X * 2)
  end

  # ImageMagick reads `%` and a leading `@` in what it writes; a label is written as given.
  def test_a_label_with_percent_or_at_sign_is_written_as_given
    rom = game(CYCLE)
    film = File.join(scratch, "labels.mp4")
    sides = { "@home" => -> { opened(rom) }, "50% speed" => -> { opened(rom) } }

    assert_equal film, Film.make(film, sides: sides, parts: [1..2])
    assert_equal 2 * 2 * 240, video_shape(film)[:width]
  end

  def test_one_side_is_one_picture_wide
    film = make_film(parts: [1..2], sides: 1)
    shape = video_shape(film)

    assert_equal [2 * 240, (2 * 160) + STRIP], [shape[:width], shape[:height]]
    assert_equal SHORTEST, shape[:frames]
  end

  def test_buttons_are_held_on_the_frames_the_block_names
    rom = game(CYCLE, step_with: :a)
    film = File.join(scratch, "pressed.mp4")
    Film.make(film, sides: { "ours" => -> { opened(rom) } }, parts: [2..5],
                    keys: ->(frame) { :a if frame.between?(4, 5) })
    shape = video_shape(film)

    # The game moves on a colour only while A is down: frames two and three show the same colour,
    # and frame five the colour two on from it.
    shown = colours_at(film, shape, x: GAME_X * 2)
    assert_equal shown[0], shown[1]
    refute_equal shown[1], shown[3]
  end

  # A side that draws a 256 wide picture for its first two frames and a 320 wide one after.
  class GrowingScreen
    def initialize = @frames = 0

    def step(_count, keys: 0)
      @frames += 1
      self
    end

    def screenshot(path)
      width = @frames < 3 ? 256 : 320
      VBlank::Graphics::PNG.write(path, width: width, height: 240, pixels: Array.new(width * 240, 0))
    end
  end

  # A side whose screen changes size as it plays is refused, naming the side and the two sizes.
  def test_a_side_whose_screen_changes_size_is_refused
    growing = GrowingScreen.new

    error = assert_raises(ArgumentError) do
      Film.make(File.join(scratch, "never.mp4"), sides: { "program" => -> { growing } }, parts: [1..4])
    end
    assert_match(/"program"/, error.message)
    assert_match(/256×240 on frame 1 and 320×240 on frame 3/, error.message)
  end

  def test_missing_ffmpeg_is_named_with_how_to_install_it_before_anything_plays
    only_imagemagick = Dir.mktmpdir("film-path", scratch)
    File.symlink(program_path("magick"), File.join(only_imagemagick, "magick"))
    opened = false

    error = assert_raises(Film::MissingTool) do
      Film.make(File.join(scratch, "never.mp4"), sides: { "ours" => -> { opened = true } }, parts: [1..2],
                                                 search_path: only_imagemagick)
    end
    assert_match(/ffmpeg/, error.message)
    assert_match(/brew install ffmpeg/, error.message)
    assert_match(/apt install ffmpeg/, error.message)
    refute_match(/ImageMagick/, error.message)
    refute opened, "no cartridge was opened"
  end

  def test_missing_imagemagick_and_ffmpeg_are_both_named
    error = assert_raises(Film::MissingTool) do
      Film.make(File.join(scratch, "never.mp4"), sides: { "ours" => -> { flunk "opened" } }, parts: [1..2],
                                                 search_path: Dir.mktmpdir("film-path", scratch))
    end
    assert_match(/ImageMagick and ffmpeg/, error.message)
    assert_match(/brew install imagemagick/, error.message)
    assert_match(/brew install ffmpeg/, error.message)
  end

  private def scratch = @scratch ||= Dir.mktmpdir("film-test")

  def teardown
    FileUtils.rm_rf(@scratch) if @scratch
  end

  # A game that paints the whole screen the next colour of +cycle+ every frame, or, given
  # +step_with+, only on the frames that button is down.
  private def game(cycle, step_with: nil)
    VBlank.build("FILMED", console: :gba, out: StringIO.new, err: StringIO.new) do
      shade = var :shade, 0
      game_loop do
        if step_with
          shade += 1 if held(step_with)
        else
          shade += 1
        end
        phase = shade % 4
        cycle.each_with_index { |colour, index| clear_screen(colour) if phase == index }
      end
    end
  end

  # A cartridge in the emulator, its next frame its first.
  private def opened(rom) = VBlank::Diagnostics::Verifier.new(rom, frames: 0)

  private def make_film(parts:, sides: 2)
    roms = [game(CYCLE), game(CYCLE_BACKWARDS)].first(sides)
    path = File.join(scratch, "film.mp4")
    openers = roms.zip(%w[ours reference]).to_h { |rom, label| [label, -> { opened(rom) }] }
    assert_equal path, Film.make(path, sides: openers, parts: parts)
    path
  end

  # Which of the four colours the game shows on +frame+, counted from one: read off the cartridge
  # itself, so the test does not assume which frame the game first paints on.
  private def colour_index(frame)
    @colour_by_frame ||= begin
      verifier = opened(game(CYCLE))
      Array.new(16) do
        verifier.step(1, keys: 0)
        CYCLE.index(CYCLE.min_by { |name| distance(rgb_of(verifier.pixel(GAME_X, GAME_Y)), SHADES[name]) })
      end
    end
    @colour_by_frame.fetch(frame - 1)
  end

  # The game frame each frame of the MP4 shows, from [frame, frames held] pairs.
  private def expected_reel(holds) = holds.flat_map { |frame, held| [frame] * held }

  private def video_shape(path)
    json, status = Open3.capture2("ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
                                  "-show_entries", "stream=width,height,r_frame_rate,nb_read_frames,duration",
                                  "-of", "json", path)
    assert status.success?, "ffprobe read #{path}"
    stream = JSON.parse(json).fetch("streams").first
    { width: stream["width"], height: stream["height"], rate: stream["r_frame_rate"],
      frames: Integer(stream["nb_read_frames"]), seconds: Float(stream["duration"]) }
  end

  # Every frame of the MP4 as eight-bit red, green and blue.
  private def decoded_frames(path, shape)
    raw, status = Open3.capture2("ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
                                 binmode: true)
    assert status.success?, "ffmpeg decoded #{path}"
    raw.bytes.each_slice(shape[:width] * shape[:height] * 3).to_a
  end

  # The colour of the film's pixel at +x+, on the game's row GAME_Y, on every frame.
  private def colours_at(path, shape, x:)
    y = STRIP + (GAME_Y * 2)
    decoded_frames(path, shape).map do |frame|
      at = ((y * shape[:width]) + x) * 3
      SHADES.min_by { |_, shade| distance(frame[at, 3], shade) }.first
    end
  end

  private def strip_pixel(frame, shape, x, y)
    at = ((y * shape[:width]) + x) * 3
    frame[at, 3]
  end

  # Whether any pixel of the strip near the left of a side is light: the label written there.
  private def text_in_strip?(frame, shape, left)
    (2...(STRIP - 2)).any? { |y| (left...(left + 120)).any? { |x| strip_pixel(frame, shape, x, y).min > 160 } }
  end

  private def rgb_of(pixel) = [pixel[:r], pixel[:g], pixel[:b]]

  private def distance(one, other) = one.zip(other).sum { |a, b| (a - b)**2 }

  private def program_path(name)
    ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }
       .find { |path| File.executable?(path) } or flunk "this test needs #{name} on the PATH"
  end
end
