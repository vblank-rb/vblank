# frozen_string_literal: true

require "test_helper"
require "ripper"
require "stringio"
require "tmpdir"

# Every whole game shown in a doc comment under lib/ builds and plays. The docs play a page's
# first such example and show its picture beside the code, so an example that stopped building
# would leave a page with no picture and a reader copying a game that does not work.
#
# A whole game is a fenced ```ruby block in a comment whose code declares one: `VBlank.game
# "NAME", consoles: ...` (perhaps after a module or a constant of its own), or `VBlank.build("NAME",
# console: :x) do`. Each is built for every console it names as `vblank build` builds it, with the
# build's checks on, then played on this run's player where the run plays as one of its consoles.
# Fragments of a game are not checked here.
#
# The first ```ruby block of a file may carry a marker on its fence, which tells the docs what
# picture to take: `picture=still` (the screen at one frame), `picture=once` (a video of the
# frames, played once) or `picture=loop` (a video played round and round), with `frames=N` for how
# many frames, 120 when left out and 360 at most. A block with no marker gets no picture. Each
# marker is held to its promise here: a still is not one colour, a video changes as it plays, and
# a loop's last frame leads back into its first. A fence may also say `sound=play` (beside a
# picture= or alone), which asks the docs to play the game with no buttons for `frames=N` frames,
# 900 at most, and record what it plays: that recording is held to not being silence.
class TestDocCommentGames < Minitest::Test
  # Each example is loaded as a file of its own, which declares its modules and constants in the
  # whole process, as a game file does; a test in a Ractor cannot declare them.
  runs_on_the_main_ractor!

  LIBRARY = VBlank.root.join("lib")

  # One ```ruby block of a doc comment: its code, the file it is in (from the repository's root),
  # the line its code starts on, the words on its fence after `ruby`, and whether it is the
  # file's first ```ruby block.
  Example = Data.define(:code, :file, :line, :fence, :first)

  # What a fence's marker asks the docs for: the kind of picture and how many frames.
  Picture = Data.define(:kind, :frames)

  # A fence's `sound=play`: the docs play the game for this many frames and record what it plays.
  Sound = Data.define(:frames)

  # A line of a comment, with the `#` and the one space after it taken off.
  COMMENT_LINE = /\A\s*#(?: |$)(.*)\z/m

  # A fence that opens a block of Ruby, and the words after `ruby` on it.
  RUBY_FENCE = /\A```ruby(?:\s+(.*))?\z/

  # What makes a block a whole game.
  WHOLE_GAME = [/^\s*VBlank\.game[ (]/, /VBlank\.build\(\s*"[^"]*",\s*console:\s*:\w+\s*\)\s*do/].freeze

  # How many frames the docs play an example for before they take its picture.
  FRAMES_PLAYED = 120

  # The kinds of picture a marker can ask for, and the most frames it can ask for.
  PICTURE_KINDS = %w[still once loop].freeze
  MOST_FRAMES = 360

  # The settings a marker can carry, and the most frames a recording can ask for.
  MARKER_SETTINGS = %w[picture sound frames].freeze
  MOST_SOUND_FRAMES = 900

  # The runtime the docs record an example's sound on (Diagnostics::SoundRecording.of).
  SOUND_RUNTIME = :js

  # The widest line of a file's first whole game: the docs show its picture at the console's own
  # width beside it, which leaves the code about this many characters.
  WIDEST_LINE = 44

  # How many pixels a loop's last frame may differ from its first by and still lead back into it
  # smoothly: a pixel or two of a circle's edge, not a thing out of place.
  LOOP_SEAM_PIXELS = 64

  private def examples
    all_examples.select { |example| whole_game?(example) }
  end

  private def all_examples
    Dir.glob(LIBRARY.join("**/*.rb").to_s).sort.flat_map { |path| examples_in(path) }
  end

  private def whole_game?(example) = WHOLE_GAME.any? { |shape| example.code.match?(shape) }

  private def examples_in(path)
    file = Pathname(path).relative_path_from(VBlank.root).to_s
    found = []
    code = nil
    start = nil
    fence = nil
    File.foreach(path).with_index(1) do |text, number|
      comment = text.match(COMMENT_LINE)&.[](1)&.chomp
      if code.nil?
        opening = comment&.strip&.match(RUBY_FENCE)
        if opening
          code = []
          start = number + 1
          fence = opening[1].to_s.strip
        end
      elsif comment.nil? || comment.strip == "```"
        found << Example.new(code: code.join("\n") + "\n", file: file, line: start, fence: fence,
                             first: found.empty?)
        code = nil
      else
        code << comment
      end
    end
    found
  end

  # The picture +example+'s fence asks for, nil where it asks for none. Raises ArgumentError,
  # saying what is wrong, for a marker the docs cannot read.
  private def picture_of(example)
    settings = marker_settings(example)
    return nil unless settings.key?("picture")

    kind = settings["picture"]
    raise ArgumentError, "picture=#{kind} is not one of #{PICTURE_KINDS.join(', ')}" unless PICTURE_KINDS.include?(kind)

    Picture.new(kind: kind, frames: marker_frames(settings, MOST_FRAMES))
  end

  # The recording +example+'s fence asks for, nil where it asks for none. Raises ArgumentError,
  # saying what is wrong, for a marker the docs cannot read.
  private def sound_of(example)
    settings = marker_settings(example)
    return nil unless settings.key?("sound")
    raise ArgumentError, "sound=#{settings['sound']} is not sound=play" unless settings["sound"] == "play"

    Sound.new(frames: marker_frames(settings, MOST_SOUND_FRAMES))
  end

  # The settings on +example+'s fence, by name. Raises ArgumentError for a word that is not a
  # setting, or a marker that asks for neither a picture nor a sound.
  private def marker_settings(example)
    settings = example.fence.split.to_h do |word|
      key, value = word.split("=", 2)
      raise ArgumentError, "`#{word}` is not a setting the docs read (#{settings_named})" unless value

      [key, value]
    end
    unknown = settings.keys - MARKER_SETTINGS
    raise ArgumentError, "`#{unknown.first}=` is not a setting the docs read (#{settings_named})" if unknown.any?
    if settings.any? && !settings.key?("picture") && !settings.key?("sound")
      raise ArgumentError, "the marker asks for no picture= and no sound="
    end

    settings
  end

  private def settings_named = MARKER_SETTINGS.map { |name| "#{name}=" }.join(", ")

  # The marker's frames=, FRAMES_PLAYED where it gives none, from 1 to +most+.
  private def marker_frames(settings, most)
    frames = Integer(settings.fetch("frames", FRAMES_PLAYED.to_s), exception: false)
    return frames if frames&.between?(1, most)

    raise ArgumentError, "frames=#{settings['frames']} is not a number of frames from 1 to #{most}"
  end

  # The game +example+ declares, loaded from a file of its own inside a module of its own, as a
  # game file is loaded. A `VBlank.build` example is declared as the same game with `VBlank.game`,
  # so it is built and played as the others are.
  private def declared_game(example, folder, index, module_name: "Example")
    code = example.code.sub(/VBlank\.build\(\s*("[^"]*"),\s*console:\s*(:\w+)\s*\)\s*do/,
                            'VBlank.game(\1, consoles: [\2]) do')
    path = File.join(folder, "#{module_name.downcase}_#{index}.rb")
    File.write(path, "module TestDocCommentGames::#{module_name}#{index}\n#{code}end\n")
    VBlank.forget_registered_games!
    quietly { RubyVM::InstructionSequence.compile_file(path).eval }
    VBlank.registered_games.last or raise ArgumentError, "declares no game"
  end

  # Ruby's warnings off while +block+ runs: an example may keep a value it never reads (`rom =
  # VBlank.build ...`), which is fine in a page and only noise in the run's output.
  private def quietly
    verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = verbose
  end

  # Builds +game+ for each of its consoles with the build's checks on, then plays it here where
  # this run plays as one of them.
  private def build_and_play(game)
    game.consoles.each do |console|
      err = StringIO.new
      begin
        game.build_rom(out: nil, err: err, profile: false, console: console, from_cache: false)
      rescue StandardError => e
        raise e.class, "#{e.message}\n#{err.string}".strip
      end
    end
    return unless game.consoles.include?(game_console)

    game_player.run(played_program(game), frames: FRAMES_PLAYED)
  end

  private def played_program(game) = game.program(console: game_console, for_computer: computer_run?)

  # What is wrong with +example+, or nil.
  private def example_problem(example, folder, index)
    build_and_play(declared_game(example, folder, index))
    nil
  rescue StandardError, SyntaxError => e
    "does not build and play: #{e.class}: #{e.message}"
  end

  # Every pixel of the screen after +frames+ frames of +game+, row by row.
  private def screen_after(game, frames)
    screen = game_player.run(played_program(game), frames: frames).screen
    (0...screen_height).flat_map { |y| (0...screen_width).map { |x| screen.pixel(x, y) } }
  end

  private def screen_width = VBlank::Console.described(game_console).screen_width
  private def screen_height = VBlank::Console.described(game_console).screen_height

  private def pixels_apart(one, other) = one.zip(other).count { |a, b| a != b }

  # What is wrong with the picture +example+'s marker promises, or nil.
  private def picture_problem(example, picture, folder, index)
    game = declared_game(example, folder, index, module_name: "Pictured")
    return nil unless game.consoles.include?(game_console)

    case picture.kind
    when "still" then still_problem(game, picture)
    when "once" then video_problem(game, picture)
    when "loop" then video_problem(game, picture) || seam_problem(game, picture)
    end
  rescue StandardError, SyntaxError => e
    "does not play: #{e.class}: #{e.message}"
  end

  private def still_problem(game, picture)
    return nil if screen_after(game, picture.frames).uniq.length > 1

    "is one colour at frame #{picture.frames}, so its still shows nothing"
  end

  # A video changes as it plays: a `once` from its first frame to its last, a `loop`, which comes
  # back to where it started, by its middle.
  private def video_problem(game, picture)
    compared = picture.kind == "loop" ? [picture.frames / 2, 1].max : picture.frames
    return nil if screen_after(game, 1) != screen_after(game, compared)

    "shows the same screen at frames 1 and #{compared}, so its video shows nothing moving"
  end

  # A loop of N frames is seamless when the frame after its last is its first again: the game
  # played N + 1 frames shows what it showed after 1.
  private def seam_problem(game, picture)
    apart = pixels_apart(screen_after(game, 1), screen_after(game, picture.frames + 1))
    return nil if apart <= LOOP_SEAM_PIXELS

    "does not loop: frame #{picture.frames + 1} differs from frame 1 in #{apart} pixels, so " \
      "frame #{picture.frames} does not lead back into frame 1"
  end

  # The lines of +example+ wider than the docs leave room for, and those with a comment after
  # code, each as "line N: why".
  private def line_problems(example)
    wide = example.code.lines.each_with_index.filter_map do |text, at|
      width = text.chomp.length
      "line #{example.line + at}: #{width} characters, more than #{WIDEST_LINE}" if width > WIDEST_LINE
    end
    wide + end_of_line_comments(example)
  end

  # A comment explaining a line goes on a line of its own above it, so the code stays narrow.
  private def end_of_line_comments(example)
    tokens = Ripper.lex(example.code)
    tokens.filter_map do |(row, column), type, _text, _state|
      next unless type == :on_comment

      before = tokens.any? do |(other_row, other_column), other_type, _, _|
        other_row == row && other_column < column && other_type != :on_sp
      end
      "line #{example.line + row - 1}: a comment at the end of a line; put it on its own line above" if before
    end
  end

  def test_every_whole_game_in_a_doc_comment_builds_and_plays
    checked = examples
    problems = Dir.mktmpdir do |folder|
      checked.each_with_index.filter_map do |example, index|
        problem = example_problem(example, folder, index)
        "#{example.file}:#{example.line} #{problem}" if problem
      end
    end
    VBlank.forget_registered_games!

    assert_empty problems, problems.join("\n\n")
    assert_operator checked.length, :>=, 20
  end

  def test_first_whole_game_of_each_file_is_narrow
    firsts = examples.group_by(&:file).values.map(&:first)
    problems = firsts.flat_map do |example|
      line_problems(example).map { |problem| "#{example.file}:#{problem.delete_prefix('line ')}" }
    end

    assert_empty problems, problems.join("\n")
    assert_operator firsts.length, :>=, 20
  end

  def test_picture_markers_are_read_by_the_docs
    problems = all_examples.filter_map do |example|
      next if example.fence.empty?

      picture_of(example)
      sound_of(example)
      next "#{example.file}:#{example.line} has a marker on a block the docs do not picture (not the file's first)" unless example.first
      next "#{example.file}:#{example.line} has a marker on a block that is not a whole game" unless whole_game?(example)

      nil
    rescue ArgumentError => e
      "#{example.file}:#{example.line} #{e.message}"
    end

    assert_empty problems, problems.join("\n")
    assert_operator all_examples.count { |example| !example.fence.empty? }, :>=, 27
  end

  # The first whole games of each file whose fence carries a marker.
  private def marked_examples
    all_examples.select { |example| example.first && whole_game?(example) && !example.fence.empty? }
  end

  def test_every_marked_picture_shows_what_its_marker_promises
    marked = marked_examples.select { |example| picture_of(example) }
    problems = Dir.mktmpdir do |folder|
      marked.each_with_index.filter_map do |example, index|
        problem = picture_problem(example, picture_of(example), folder, index)
        "#{example.file}:#{example.line} #{problem}" if problem
      end
    end
    VBlank.forget_registered_games!

    assert_empty problems, problems.join("\n")
  end

  # What is wrong with the recording +example+'s marker promises, or nil: recorded as the docs
  # record it, it is not silence from start to end.
  private def sound_problem(example, sound, folder, index)
    game = declared_game(example, folder, index, module_name: "Heard")
    return nil unless game.consoles.include?(game_console)

    program = game.program(console: game_console, for_computer: true)
    heard = VBlank::Diagnostics::SoundRecording.of(program, on: SOUND_RUNTIME, frames: sound.frames)
    return nil unless heard.samples.all?(&:zero?)

    "is silent over its #{sound.frames} frames, so its recording plays nothing"
  rescue StandardError, SyntaxError => e
    "does not play: #{e.class}: #{e.message}"
  end

  def test_every_marked_sound_is_heard
    marked = marked_examples.select { |example| sound_of(example) }
    problems = Dir.mktmpdir do |folder|
      marked.each_with_index.filter_map do |example, index|
        problem = sound_problem(example, sound_of(example), folder, index)
        "#{example.file}:#{example.line} #{problem}" if problem
      end
    end
    VBlank.forget_registered_games!

    assert_empty problems, problems.join("\n")
    assert_operator marked.length, :>=, 4
  end
end
