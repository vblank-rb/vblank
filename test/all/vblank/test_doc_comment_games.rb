# frozen_string_literal: true

require "test_helper"
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
class TestDocCommentGames < Minitest::Test
  # Each example is loaded as a file of its own, which declares its modules and constants in the
  # whole process, as a game file does; a test in a Ractor cannot declare them.
  runs_on_the_main_ractor!

  LIBRARY = VBlank.root.join("lib")

  # One ```ruby block of a doc comment: its code, the file it is in (from the repository's root),
  # and the line its code starts on.
  Example = Data.define(:code, :file, :line)

  # A line of a comment, with the `#` and the one space after it taken off.
  COMMENT_LINE = /\A\s*#(?: |$)(.*)\z/m

  # What makes a block a whole game.
  WHOLE_GAME = [/^\s*VBlank\.game[ (]/, /VBlank\.build\(\s*"[^"]*",\s*console:\s*:\w+\s*\)\s*do/].freeze

  # How many frames the docs play an example for before they take its picture.
  FRAMES_PLAYED = 120

  private def examples
    Dir.glob(LIBRARY.join("**/*.rb").to_s).sort.flat_map { |path| examples_in(path) }
       .select { |example| WHOLE_GAME.any? { |shape| example.code.match?(shape) } }
  end

  private def examples_in(path)
    file = Pathname(path).relative_path_from(VBlank.root).to_s
    found = []
    code = nil
    start = nil
    File.foreach(path).with_index(1) do |text, number|
      comment = text.match(COMMENT_LINE)&.[](1)&.chomp
      if code.nil?
        if comment&.strip == "```ruby"
          code = []
          start = number + 1
        end
      elsif comment.nil? || comment.strip == "```"
        found << Example.new(code: code.join("\n") + "\n", file: file, line: start)
        code = nil
      else
        code << comment
      end
    end
    found
  end

  # The game +example+ declares, loaded from a file of its own inside a module of its own, as a
  # game file is loaded. A `VBlank.build` example is declared as the same game with `VBlank.game`,
  # so it is built and played as the others are.
  private def declared_game(example, folder, index)
    code = example.code.sub(/VBlank\.build\(\s*("[^"]*"),\s*console:\s*(:\w+)\s*\)\s*do/,
                            'VBlank.game(\1, consoles: [\2]) do')
    path = File.join(folder, "example_#{index}.rb")
    File.write(path, "module TestDocCommentGames::Example#{index}\n#{code}end\n")
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

    game_player.run(game.program(console: game_console, for_computer: computer_run?), frames: FRAMES_PLAYED)
  end

  # What is wrong with +example+, or nil.
  private def example_problem(example, folder, index)
    build_and_play(declared_game(example, folder, index))
    nil
  rescue StandardError, SyntaxError => e
    "does not build and play: #{e.class}: #{e.message}"
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
end
