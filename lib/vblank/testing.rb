# frozen_string_literal: true

# A GAME'S OWN TESTS, PLAYED ON EITHER LOWERING. The one require a game's test suite needs:
#
#   require "vblank/testing"
#
#   class WalkerTest < Minitest::Test
#     include VBlank::Testing
#
#     def test_holding_right_walks
#       assert_equal 6, game_player.hold(:right).run(game.program, frames: 6)[:x]
#     end
#   end
#
# `game_player` is the interpreter on the GBA lowering's run, the game built as C, checked
# against the interpreter on every frame, on the native lowering's, and the game built as
# JavaScript, checked the same way, on the JavaScript lowering's — the same calls every way, so a
# test is written once and plays on all three. Which run it is comes from one setting
# (Lowering::SETTING), which the rake tasks set (vblank/testing/rake_tasks); a plain run is the
# GBA lowering's.
#
# A test that asks whether the CARTRIDGE draws what the interpreter draws includes Pictures as
# well (`include VBlank::Testing::Pictures`, for `assert_backends_agree`). That one plays the
# cartridge in the emulator, so it needs the ruby-gba-emulator gem in the game's test group.
#
# It is not part of `require "vblank"`, because it loads minitest, which a game needs only for
# its tests: a game's Gemfile names minitest in its test group. The native lowering's run needs
# zig as well, as every native build does, and the JavaScript lowering's needs node.
require "minitest/autorun"
require_relative "../vblank"
require_relative "testing/lowering"
require_relative "testing/checked_player"
require_relative "testing/pictures"
require_relative "testing/rewritten_blocks"

module VBlank
  module Testing
    # The lowering this run tests, read once when the suite loads, and its record (Lowering::Run).
    LOWERING = Lowering.from(ENV)
    RUN = Lowering.run_named(LOWERING)

    def self.lowering = LOWERING
    def self.native? = LOWERING == :native
    def self.javascript? = LOWERING == :js
    def self.gbc? = LOWERING == :gbc

    # The console this run plays a game built for (Lowering::Run#console): the Game Boy Color on
    # its run, the Advance on the native, JavaScript and Ruby ones unless their task names another
    # (Lowering.console_from). A game for both builds its tree for the run's
    # (`game.program(console: game_console)`), so its tests play on the Color too.
    CONSOLE = Lowering.console_from(ENV, RUN)

    def self.console = CONSOLE
    def game_console = Testing.console

    # A TEST'S PROGRAM THAT NAMES NO CONSOLE is laid out as the Advance while its block runs, which
    # is the screen those tests were written for, and is played as its run's console
    # (PlaysRunConsole). The library assumes none, so a game's build that names none stops and says
    # so; only a test suite has this. Laying such a test out as its run's console is the better
    # answer, and fails every test that says a place on the Advance's screen.
    module LaidOutForTheAdvance
      def described_console = console ? super : Console::ADVANCE
    end
    IR::Nodes::Program.prepend(LaidOutForTheAdvance)

    # THE COLOUR +color+ (a name, a hex string or a 15-bit number) LOOKS LIKE on this run's console,
    # which keeps fewer bits of each channel than a game names a colour in on some (the Genesis keeps
    # three of five): what a test compares a pixel of the picture to.
    def self.shown(color) = Console.described(CONSOLE).shown(Graphics::Color.resolve(color))
    def shown(color) = Testing.shown(color)

    # HOW MANY PASSES BEHIND THE GAME'S NUMBERS what the framework draws for it is — its sprites,
    # its tiled text, its scroll — read at a frame boundary on this run's console. One on the
    # Advance, which places them in the gap after the boundary from the pass before; none on the
    # Color, which places them before it from the pass just ended
    # (Console::Description#sprites_placed_before_wait). What the game draws itself is never behind.
    def framework_drawing_lag = Console.described(game_console).sprites_placed_before_wait ? 0 : 1

    # THE EMULATOR, IF THE GAME HAS IT, LOADED NOW rather than by the first test that wants it.
    # A suite may play its tests in Ractors, and loading it writes globals only the main Ractor
    # may touch (see Diagnostics::Emulator.load!). A game without it in its test group loses
    # only the tests that play the cartridge, which say so when they run.
    Diagnostics::Emulator.available?

    # STANDARD OUTPUT UNBUFFERED, so a test in a Ractor can start a program. In Ruby 4.0, before
    # it starts one it flushes the process's standard output, and if words are waiting it takes the
    # lock of an object the main Ractor owns. When the main Ractor is writing the run's progress
    # at that moment, the test waits on a lock no thread of its own can release, and Ruby stops
    # it as a deadlock (or, now and then, the whole process crashes). With nothing ever left
    # waiting in the buffer, the flush has nothing to do and takes no lock. Building a game whose
    # art is read from a file starts ImageMagick, so this reaches far more tests than it sounds.
    $stdout.sync = true

    # Whether this run plays the game built for another machine (as C, as JavaScript, or as a Game
    # Boy Color cartridge) and checks it against the interpreter, rather than playing the
    # interpreter alone. Such a run has no Advance cartridge to check.
    def self.checked? = RUN.checked?

    # What plays a game in this run: the interpreter on the GBA lowering's run; on the native
    # lowering's the game built as C, driven through the same calls and checked against the
    # interpreter frame by frame (CheckedPlayer); and on the JavaScript lowering's the game built
    # as JavaScript, checked the same way (JSCheckedPlayer). +save+ is the save memory the game
    # starts with, as the interpreter takes it.
    def game_player(save: nil)
      player = Testing.player_class
      save ? player.new(save: save) : player.new
    end

    # +program+ as game_player plays it on this run: the same program, except on the Game Boy
    # Color's run, where a program that names no console is played as a Color program. A test
    # that asks a build check about the program it played asks it of this.
    def program_played(program)
      player = Testing.player_class
      player.respond_to?(:program_played) ? player.program_played(program) : program
    end

    # The class game_player makes one of, for this run (Lowering::Run#player).
    def self.player_class = RUN.player_class

    # A test the native lowering cannot play yet skips itself on a native run, saying +why+
    # (skip_on_native) — and a checked run ends by counting its skips by reason, so these cannot
    # pile up unseen. On the GBA lowering's run it does nothing. There is one for every checked
    # run in Lowering::RUNS, by its name: skip_on_native, skip_on_js, skip_on_ruby, skip_on_gbc,
    # skip_on_snes. Each is written out as a plain method, not made from a block, so a test in a
    # Ractor can call it.
    Lowering::RUNS.select(&:checked?).each do |run|
      module_eval("def skip_on_#{run.name}(why) = skip_on_lowering(:#{run.name}, why)", __FILE__, __LINE__)
    end

    # The same, for the run of the lowering named +lowering+.
    # A name no lowering has is refused on every run, so a misspelt one cannot quietly never skip.
    def skip_on_lowering(lowering, why)
      run = Lowering.run_named(lowering)
      raise MissingFeature, "#{run.title} cannot play this yet: #{why}" if Testing.lowering == lowering
    end

    # A test of something a console's HARDWARE cannot do has no skip: it lives in the folders of the
    # consoles that can (test/console/<console>/), and every run playing as a console refuses a game
    # that console's build refuses, before playing it (BuildChecks), so a game it cannot play never
    # passes there unseen.

    # This test cannot play on the machine running the suite, saying +why+: something that is not
    # installed, another operating system, a copy of a game's data it cannot ship. It says nothing
    # about a lowering, so it is no test in the wrong place (see SkipsByReason).
    def skip_on_this_machine(why) = raise(NotOnThisMachine, why)

    # THE PLAYER'S COPY OF THE ORIGINAL +game+ (an Original::Game) IS MADE FROM, for a test that reads
    # it. A machine where nothing says where one is stops the test (Original::NotSet), saying what to
    # set, and a copy that is named and wrong stops it too (Original::WrongCopy). Nothing skips: the
    # games' shared rule is that a suite without the copy stops, because a suite that skipped would
    # pass having checked nothing of the game.
    #
    # It is the one choice for every game, so no game makes its own.
    def original_copy(game) = game.copy

    # EVERY FILE OF +facts+ (an Original::Facts) KEPT TO ITS THREE RULES: it is laid out as its tool
    # writes it, so nobody edited a value by hand; every key has a comment written above it; and
    # every measured fact has a value, a source and a test, a file under +root+ (the folder the
    # game's tests are named from) that is there.
    def assert_facts_kept(facts, root:)
      facts.files.each do |file|
        name = File.basename(facts.path(file))
        assert facts.kept?(file), "#{name} is not laid out as its tool writes it. Run the tool again to write its values."
        assert_empty facts.uncommented(file), "#{name} has keys with no comment directly above them. Write a comment above each."
        facts.measured_entries(file).each do |path, entry|
          assert_equal %w[source test value], entry.is_a?(Hash) ? entry.keys.sort : [],
                       "#{name}'s measured #{path} must have a value, a source and a test."
          assert_path_exists File.join(root, entry.fetch("test")), "#{name}'s measured #{path} names a test that is not there."
        end
      end
    end

    # A test of an example +game+ (a VBlank.game) skips on a console the game does not name yet: it is
    # laid out for its own consoles, so there is nothing to play.
    def skip_unless_written_for(game)
      return if game.consoles.include?(Testing.console)

      raise MissingFeature, "#{Console.for(Testing.console).title} cannot play this yet: #{game.title} is not written for it"
    end

    # THE TWO KINDS OF SKIP A RUN TAKES. The first: its lowering lacks the feature the test plays —
    # its build does not make it yet, or its hardware cannot. A checked player raises it for what
    # its lowering does not make or answer, and skip_on_<run> for what a test says it cannot play.
    # The second is NotOnThisMachine, below. Any other skip is a test in the wrong place, and fails
    # the run (SkipsByReason).
    #
    # It is a plain Minitest::Skip with a mark on it, not a kind of its own: minitest counts a
    # run's skips by the exact class of each, so one of its own would go uncounted. The mark is an
    # instance variable, which Marshal carries from the process that played the test to the one
    # that reports it (Testing::Processes). `raise MissingFeature, "why"` raises one.
    module MissingFeature
      def self.exception(message) = Minitest::Skip.new(message).tap { |skip| skip.instance_variable_set(:@missing_feature, true) }

      # Whether +failure+ is one.
      def self.===(failure) = failure.is_a?(Minitest::Skip) && failure.instance_variable_get(:@missing_feature) == true
    end

    # What this machine lacks, marked as MissingFeature is. `skip_on_this_machine "why"` raises one.
    module NotOnThisMachine
      def self.exception(message)
        Minitest::Skip.new(message).tap { |skip| skip.instance_variable_set(:@not_on_this_machine, true) }
      end

      # Whether +failure+ is one.
      def self.===(failure) = failure.is_a?(Minitest::Skip) && failure.instance_variable_get(:@not_on_this_machine) == true
    end
  end
end

require_relative "testing/skips_by_reason"

# On a CI machine, whose log shows a line only once it ends, a line every hundred tests.
require_relative "testing/progress_lines"
if ENV["CI"]
  module Minitest
    def self.plugin_progress_lines_init(options) = reporter << VBlank::Testing::ProgressLines.for_run(options)
  end
  Minitest.extensions << "progress_lines"
end

# FAIL_FAST=1 and RESUME=1: a run keeps a record of what passed, and leaves that out when it picks up.
# Ahead of the stop below, since FailFast can end the process and the failure must be in the record.
require_relative "testing/run_progress"
if (run_record = ENV.delete(VBlank::Testing::Lowering::RECORD_SETTING))
  VBlank::Testing::RunProgress.leave_out_passed_tests(run_record)
  module Minitest
    def self.plugin_run_record_init(options)
      reporter << VBlank::Testing::RunProgress::Recorder.new(VBlank::Testing::RunProgress.record, options[:seed])
    end
  end
  Minitest.extensions << "run_record"
end

# FAIL_FAST=1: stop at the first failing test.
require_relative "testing/fail_fast"
# Taken out of the environment as it is read: it is for this process, and a test that starts a run
# of its own, to watch that run fail, must not stop at the failure it is there to see.
if ENV.delete(VBlank::Testing::Lowering::STOPS_AT_FAILURE_SETTING)
  module Minitest
    def self.plugin_fail_fast_init(options)
      children = defined?(VBlank::Testing::Processes) ? VBlank::Testing::Processes.running : nil
      stop = children ? -> { children.stop_handing_out } : -> { exit!(1) }
      reporter << VBlank::Testing::FailFast.new(options[:io], stop: stop)
    end
  end
  Minitest.extensions << "fail_fast"
end
