# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "tmpdir"
require "heard_film"

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
  include HeardFilm

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

  # Parts are shown in the order given, a later part of the game before an earlier one.
  def test_parts_out_of_order_are_shown_in_the_order_given
    film = make_film(parts: [6..7, 2..3])
    shape = video_shape(film)
    reel = expected_reel([[6, 1], [7, PART_END_HOLD], [2, 1], [3, SHORTEST - 50]])

    assert_equal reel.map { |frame| CYCLE[colour_index(frame)] }, colours_at(film, shape, x: GAME_X * 2)
    assert_equal reel.map { |frame| CYCLE_BACKWARDS[colour_index(frame)] }, colours_at(film, shape, x: 480 + (GAME_X * 2))
  end

  # Parts that overlap show the frames they share in each.
  def test_overlapping_parts_show_the_frames_they_share_twice
    film = make_film(parts: [2..4, 3..5])
    shape = video_shape(film)
    reel = expected_reel([[2, 1], [3, 1], [4, PART_END_HOLD], [3, 1], [4, PART_END_HOLD], [5, SHORTEST - 99]])

    assert_equal reel.map { |frame| CYCLE[colour_index(frame)] }, colours_at(film, shape, x: GAME_X * 2)
    assert_equal reel.map { |frame| CYCLE_BACKWARDS[colour_index(frame)] }, colours_at(film, shape, x: 480 + (GAME_X * 2))
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

  # A PROBE A GAME HAS DRIVEN TO THE MOMENT WORTH FILMING is a side as it stands: the film's frame 1
  # is the frame after the probe's last, and closing the side closes the probe, its save folder too.
  def test_a_probe_driven_first_is_filmed_from_where_it_stands
    probe = VBlank::Playthroughs::Probe.open(game(CYCLE))
    probe.step(5)
    film = File.join(scratch, "probe.mp4")
    Film.make(film, sides: { "probe" => -> { probe } }, parts: [1..4])
    shape = video_shape(film)
    reel = expected_reel([[1, 1], [2, 1], [3, 1], [4, SHORTEST - 3]])

    assert_equal reel.map { |frame| CYCLE[colour_index(5 + frame)] }, colours_at(film, shape, x: GAME_X * 2)
    assert_equal 9, probe.frame
    refute Dir.exist?(probe.save_dir), "the probe's save folder is left behind"
  end

  # The film's buttons reach the probe, on the film's frames.
  def test_a_probe_side_is_stepped_with_the_films_buttons
    probe = VBlank::Playthroughs::Probe.open(game(CYCLE, step_with: :a))
    probe.step(3, holding: :a)
    film = File.join(scratch, "probe_pressed.mp4")
    Film.make(film, sides: { "probe" => -> { probe } }, parts: [1..4], keys: ->(frame) { :a if frame >= 3 })
    shown = colours_at(film, video_shape(film), x: GAME_X * 2)

    assert_equal shown[0], shown[1]
    refute_equal shown[1], shown[2]
  end

  # A probe heard: its sound is on the film's frames counted from where the probe stood.
  def test_a_probe_side_is_heard_from_where_it_stands
    rom = beeping_game(beep_on: 12)
    probe = VBlank::Playthroughs::Probe.open(rom)
    probe.step(4)
    film = File.join(scratch, "probe_heard.mp4")
    Film.make(film, sides: { "probe" => -> { probe } }, parts: [1..40], sound: "probe")
    left, = film_sound(film)

    assert_in_delta onset_frame(rom) - 1 - 4, onset(left), 1, "the sound is not on the frames that show it"
  end

  # A side that draws a 256 wide picture for its first two frames and a 320 wide one after.
  class GrowingScreen
    def initialize = @frames = 0

    def step(_count, keys: 0)
      @frames += 1
      self
    end

    # Two colours on every picture: a film rescales earlier pictures of one colour alone (a
    # console's blank first frame at its power-on size), so a real change of size has a picture.
    def screenshot(path)
      width = @frames < 3 ? 256 : 320
      VBlank::Graphics::PNG.write(path, width: width, height: 240, pixels: Array.new(width * 240) { |i| i.even? ? 0 : 0x7FFF })
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

  # A side showing one picture, +colour+ and black in a check, that notes in +log+ each frame it
  # plays, with how many sides were playing a frame as it began, and plays each long enough that
  # sides playing at once overlap.
  class LoggedScreen
    def initialize(colour, running, log)
      @colour = colour
      @running = running
      @log = log
    end

    def step(_count, keys: 0)
      marker = File.join(@running, "#{Process.pid}-#{object_id}")
      File.write(marker, "")
      File.write(@log, "step #{Dir.children(@running).size}\n", mode: "a")
      sleep 0.03
      File.delete(marker)
      self
    end

    def pixels = Array.new(240 * 160) { |i| i.even? ? 0 : @colour }
    def screen_picture = Film::Picture.new(pixels: pixels, width: 240, height: 160)
  end

  # A folder of tools for Film: ImageMagick noting in +log+ each time it runs, and ffmpeg noting
  # that it started, with its arguments, and keeping a copy of whatever it is handed on its input in
  # +handed+.
  private def logged_tools(log, handed)
    tools = Dir.mktmpdir("film-path", scratch)
    File.write(File.join(tools, "magick"), <<~SH)
      #!/bin/sh
      echo magick >> "#{log}"
      exec "#{program_path('magick')}" "$@"
    SH
    File.write(File.join(tools, "ffmpeg"), <<~SH)
      #!/bin/sh
      echo "ffmpeg $*" >> "#{log}"
      tee "#{handed}" | exec "#{program_path('ffmpeg')}" "$@"
    SH
    File.chmod(0o755, File.join(tools, "magick"))
    File.chmod(0o755, File.join(tools, "ffmpeg"))
    tools
  end

  private def logged_sides(log)
    running = Dir.mktmpdir("running", scratch)
    { "ours" => -> { LoggedScreen.new(0x001F, running, log) }, "theirs" => -> { LoggedScreen.new(0x7C00, running, log) } }
  end

  private def logged_film(frames, log, handed = File.join(scratch, "handed"))
    Film.make(File.join(scratch, "logged.mp4"), sides: logged_sides(log), parts: [1..frames],
                                                search_path: logged_tools(log, handed))
    File.readlines(log, chomp: true)
  end

  # The two sides are played at the same time, each in a process of its own.
  def test_the_sides_play_at_the_same_time
    steps = logged_film(6, File.join(scratch, "sides.log")).grep(/\Astep/)

    assert_equal 12, steps.size
    assert_operator steps.map { |line| line.split.last.to_i }.max, :>=, 2, "the sides were played one after the other"
  end

  # Frames go to ffmpeg as soon as every side has played them, not once every side has finished.
  def test_frames_reach_ffmpeg_while_the_sides_play_on
    lines = logged_film(20, File.join(scratch, "arrivals.log"))

    assert_operator lines.index { |line| line.start_with?("ffmpeg") }, :<, lines.rindex { |line| line.start_with?("step") },
                    "ffmpeg was started only once the sides had finished"
  end

  # A film whose second side's process cannot start, as when the computer has no room for another
  # process: it notes the process each side before it started.
  class SecondSideCannotStart < Film
    def started = @started ||= []

    private def start_side_process(running, side, shown, dir)
      raise Errno::EAGAIN, "no room for the second side's process" if side == 1

      super.tap { |pid, _pipe| started << pid }
    end
  end

  # A side whose process has started is stopped, and its process taken away, when a later side's
  # cannot start: nothing is left playing with nobody reading it.
  def test_a_side_left_playing_when_the_next_cannot_start_is_stopped
    film = SecondSideCannotStart.new(sides: logged_sides(File.join(scratch, "stopped.log")), parts: [1..200],
                                     keys: ->(_frame) {}, scale: 2, search_path: ENV.fetch("PATH"))

    assert_raises(Errno::EAGAIN) { film.write(File.join(scratch, "never.mp4")) }
    assert_equal 1, film.started.size
    assert_raises(Errno::ESRCH, "the first side's process is still there") { Process.kill(0, film.started.first) }
  end

  # An ffmpeg that stops before it has every frame is named, in words, not as a broken pipe.
  def test_an_ffmpeg_that_stops_early_is_named
    tools = Dir.mktmpdir("film-path", scratch)
    File.symlink(program_path("magick"), File.join(tools, "magick"))
    File.write(File.join(tools, "ffmpeg"), "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, File.join(tools, "ffmpeg"))

    error = assert_raises(ArgumentError) do
      Film.make(File.join(scratch, "never.mp4"), sides: logged_sides(File.join(scratch, "early.log")), parts: [1..20],
                                                 search_path: tools)
    end
    assert_match "ffmpeg could not write", error.message
  end

  # The frames are put together in Ruby: ImageMagick draws the words once, whatever the film's length.
  def test_imagemagick_draws_the_words_once_not_a_picture_a_frame
    runs = logged_film(40, File.join(scratch, "runs.log")).count("magick")

    assert_operator runs, :<, 20, "ImageMagick ran for each frame"
  end

  # Each side's pixels reach ffmpeg as the side showed them, doubled, under the strip: the answer key
  # is ImageMagick scaling the side's picture to twice its size, as Film's frames were made before.
  def test_ffmpeg_is_handed_each_sides_pixels_doubled_under_the_strip
    handed = File.join(scratch, "handed")
    log = File.join(scratch, "handed.log")
    arguments = logged_film(2, log, handed).find { |line| line.start_with?("ffmpeg") }.split
    width, height = arguments[arguments.index("-s") + 1].split("x").map(&:to_i)
    first = File.binread(handed, width * height * 3)

    assert_equal "rawvideo", arguments[arguments.index("-f") + 1]
    assert_equal doubled_answer_key([0x001F, 0x7C00]), first.byteslice(width * STRIP * 3..)
  end

  # Pictures of LoggedScreen in +colours+, each doubled by ImageMagick and put side by side.
  private def doubled_answer_key(colours)
    sides = colours.flat_map.with_index do |colour, side|
      path = File.join(scratch, "side#{side}.png")
      VBlank::Graphics::PNG.write(path, width: 240, height: 160, pixels: LoggedScreen.new(colour, scratch, File::NULL).pixels)
      ["(", path, "-scale", "200%", ")"]
    end
    IO.popen([program_path("magick"), *sides, "+append", "-depth", "8", "rgb:-"], "rb", &:read)
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

  # SOUND. A film asked for none has no sound in it, and is the same bytes each time it is made.
  def test_a_film_with_no_sound_asked_for_has_none
    one = make_film(parts: [1..3])
    first = File.binread(one)
    again = make_film(parts: [1..3])

    assert_empty audio_streams(one)
    assert_equal first, File.binread(again)
  end

  # A side heard alone: its sound is on the film frames that show the frames it made it on.
  def test_a_side_heard_alone_is_heard_on_the_frames_that_show_its_sound
    rom = beeping_game(beep_on: 12)
    film = File.join(scratch, "heard.mp4")
    Film.make(film, sides: { "ours" => -> { opened(rom) }, "quiet" => -> { opened(game(CYCLE)) } }, parts: [1..40],
                    sound: "ours")
    left, right = film_sound(film)

    assert_equal [2], audio_streams(film).map { |stream| stream["channels"] }
    assert_in_delta onset_frame(rom) - 1, onset(left), 1, "the sound is not on the frames that show it"
    assert_in_delta onset(left), onset(right), 0, "the side is heard as it made it, on both speakers"
  end

  # Two sides side by side, each on its own speaker: the first side's on the left.
  def test_two_sides_side_by_side_are_each_heard_on_their_own_speaker
    ours = beeping_game(beep_on: 8)
    theirs = beeping_game(beep_on: 24)
    film = File.join(scratch, "pair.mp4")
    Film.make(film, sides: { "ours" => -> { opened(ours) }, "reference" => -> { opened(theirs) } }, parts: [1..40],
                    sound: :side_by_side)
    left, right = film_sound(film)

    assert_in_delta onset_frame(ours) - 1, onset(left), 1
    assert_in_delta onset_frame(theirs) - 1, onset(right), 1
  end

  # In turn: the film is shown once for each side, and each time one side is heard.
  def test_sides_in_turn_show_the_film_once_for_each_side
    ours = beeping_game(beep_on: 8)
    theirs = beeping_game(beep_on: 24)
    film = File.join(scratch, "turns.mp4")
    Film.make(film, sides: { "ours" => -> { opened(ours) }, "reference" => -> { opened(theirs) } }, parts: [1..40],
                    sound: :in_turn)
    left, = film_sound(film)
    shape = video_shape(film)

    assert_equal 2 * SHORTEST, shape[:frames]
    assert_in_delta shape[:seconds], audio_seconds(film), 1.0 / 60, "the sound is not as long as the pictures"
    colours = colours_at(film, shape, x: GAME_X * 2)
    assert_equal colours.first(SHORTEST), colours.drop(SHORTEST), "the second showing is not the first again"
    assert_in_delta onset_frame(ours) - 1, onset(left.first(SHORTEST)), 1
    assert_in_delta onset_frame(theirs) - 1, onset(left.drop(SHORTEST)), 1
  end

  # The frames a part's end is held for are silent, and the next part is heard again.
  def test_the_held_frames_at_a_parts_end_are_silent
    rom = beeping_game(beep_on: 3)
    film = File.join(scratch, "held.mp4")
    Film.make(film, sides: { "ours" => -> { opened(rom) } }, parts: [2..10, 20..22], sound: "ours")
    left, = film_sound(film)
    loud = left.max

    held = left[(9 + 2)...(9 + PART_END_HOLD - 3)]
    assert(held.all? { |energy| energy < loud / 50 }, "a held frame is not silent")
    assert_operator left[9 + PART_END_HOLD], :>, loud / 4, "the next part is not heard"
  end

  def test_sound_of_a_side_the_film_does_not_have_is_refused
    error = assert_raises(ArgumentError) do
      Film.make(File.join(scratch, "never.mp4"), sides: { "ours" => -> { flunk "opened" } }, parts: [1..2], sound: "theirs")
    end
    assert_match(/"theirs"/, error.message)
    assert_match(/"ours"/, error.message)
  end

  def test_side_by_side_sound_of_one_side_is_refused
    error = assert_raises(ArgumentError) do
      Film.make(File.join(scratch, "never.mp4"), sides: { "ours" => -> { flunk "opened" } }, parts: [1..2],
                                                 sound: :side_by_side)
    end
    assert_match(/two sides/, error.message)
  end

  # A side that cannot hand its sound over is refused, naming it.
  def test_a_heard_side_that_gives_no_sound_is_refused
    error = assert_raises(ArgumentError) do
      Film.make(File.join(scratch, "never.mp4"), sides: { "program" => -> { GrowingScreen.new } }, parts: [1..2],
                                                 sound: "program")
    end
    assert_match(/"program"/, error.message)
    assert_match(/sound/, error.message)
  end

  private def scratch = @scratch ||= Dir.mktmpdir("film-test")

  # A game that paints red and blue by turns, and from pass +beep_on+ sounds a tone that does not fade.
  private def beeping_game(beep_on:)
    VBlank.build("FILMED", console: :gba, out: StringIO.new, err: StringIO.new, &beeping_game_source(beep_on))
  end

  # The first frame, counted from one, the cartridge itself puts its sound out on.
  private def onset_frame(rom)
    verifier = opened(rom)
    verifier.step(40, keys: 0)
    onset(verifier.audio_energy_by_frame) + 1
  end

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

  # How long the MP4's sound lasts, in seconds.
  private def audio_seconds(path)
    json, status = Open3.capture2("ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=duration",
                                  "-of", "json", path)
    assert status.success?, "ffprobe read #{path}"
    Float(JSON.parse(json).fetch("streams").first.fetch("duration"))
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
