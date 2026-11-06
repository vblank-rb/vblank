# frozen_string_literal: true

require "rake"
require "rake/tasklib"
require_relative "../console/description"
require_relative "../console/kit" # which names its parts and loads none of them
require_relative "golden_sample"
require_relative "lowering"
require_relative "run_progress"
require_relative "suite_groups"
require_relative "test_task"

module VBlank
  module Testing
    # A GAME'S RAKE TASKS FOR ITS OWN TESTS, one run for each lowering. In the game's Rakefile:
    #
    #   require "vblank/testing/rake_tasks"
    #
    #   VBlank::Testing::RakeTasks.new do |t|
    #     t.consoles = %i[gba]                           # the consoles the game is for
    #     t.test_files = FileList["test/**/test_*.rb"]   # the default
    #   end
    #
    # That defines these tasks:
    #
    #   rake test:all                every lowering, one after the other, ending with a line each
    #   rake test:lowering:gba       the game on the interpreter, which the cartridge is checked against
    #   rake test:lowering:native    the game built as C, checked against the interpreter (needs zig)
    #   rake test:lowering:js        the game built as JavaScript, checked the same way (needs node)
    #   rake test:lowering:ruby      the game built as Ruby, checked the same way
    #   rake test TEST=<file>        one file, on each lowering whose run loads it
    #
    # FAIL_FAST=1 rake test:all stops at the first failing test and keeps a record of what passed.
    # With the fault fixed, RESUME=1 rake test:all plays that test, then the rest (RunProgress).
    #
    # Each lowering's run starts with a heading naming it. `rake test` with no TEST= plays nothing
    # and lists these, since the whole suite is long and should be asked for by name.
    #
    # The Rakefile names the consoles the game is for, as the game does where it is named:
    # `t.consoles = %i[gba]` for the Advance alone, `t.consoles = %i[gba gbc]` for the Game Boy Color
    # too. The Color adds a task of its own, `rake test:lowering:gbc`, the game built as a Color cartridge
    # and checked against the interpreter, and `rake test:all` plays it too; a game for the Advance alone
    # gets no Color run it could never pass. The Rakefile cannot see which games its tests build, so
    # it is told the same list the games are, and it takes and refuses exactly what `consoles:` does,
    # a Rakefile that names none included.
    #
    # A GAME FOR SEVERAL CONSOLES IS PLAYED AS EACH OF THEM on the native, JavaScript and Ruby
    # lowerings, whose builds are told the console when they are made: `rake test:lowering:native`
    # then plays the suite once per console, one after the other, and each is a task of its own
    # too (`rake test:lowering:native:gbc`). CONSOLE=gbc, before any of these or `rake test:all`,
    # plays only the runs that play games as that console, for a quicker look at one.
    #
    # The GBA lowering's run is a plain test run, so a suite that puts its tests in Ractors
    # (RactorSettings in the Rakefile, InRactors in the test helper) keeps doing so there. The native lowering's run cannot, and spreads
    # its tests over several processes instead (TestTask says how). The runs go one after the
    # other so they never compete for a core.
    #
    # A test about one lowering's own output — the C the game is built as, say — goes in a folder
    # that lowering owns, and the other lowerings' runs never load it:
    # `t.lowering_folders = { native: ["test/native"] }`. A test of what only one console's
    # hardware can do goes in a folder that console owns, and only the runs playing games as that
    # console load it: `t.console_folders = { gbc: ["test/gbc"] }`. Every other test plays on all.
    #
    # THE GOLDEN PATH, `rake test:golden`, is the files a list names (t.golden_list, test/golden.txt
    # unless said; a test file a line, from the folder t.golden_from names, the one rake runs in
    # unless said), and a share of the other test files drawn at random on each run (t.golden_sample,
    # GoldenSample::SHARE unless said), on every lowering that plays each. A game that keeps no such
    # file has no such task.
    #
    # A TASK FOR EACH FOLDER OF TESTS, with `t.groups = "test"`: `rake test:group:enemies` plays every
    # test beneath test/enemies/ on every lowering that plays each, and `rake test:group:enemies:bat`
    # those beneath test/enemies/bat/ (SuiteGroups). `t.broad_groups = { "doors" => %w[rooms
    # enemies/test_door*.rb] }` adds a group of tests from several folders.
    #
    # A game whose Rakefile keeps its own rake test does not want this whole set: it makes the runs
    # it wants out of TestTask, which defines nothing but the task it is asked for, its golden path
    # out of GoldenTask, and a task for each folder of its tests out of GroupTasks.
    class RakeTasks < Rake::TaskLib
      OUTCOMES = { passed: "passed", failed: "FAILED", not_played: "does not play this file",
                   passed_earlier: "passed earlier" }.freeze
      RESUMED_NOTE = "This run was resumed, so it does not stand in for one clean rake test:all."
      # The list `rake test:golden` plays unless t.golden_list names another.
      GOLDEN_LIST = "test/golden.txt"

      # The test files; the folders a test file can require from by bare name (the game's own code
      # and its tests, lib and test unless told); the folders each lowering owns, and each console;
      # the consoles the game is for, which every Rakefile names; the golden path's list, and the
      # share of the other files it draws, if not GoldenSample::SHARE; and the folder whose folders
      # of tests are groups, with any broad groups.
      attr_accessor :test_files, :libs, :lowering_folders, :console_folders, :consoles, :golden_sample,
                    :golden_list, :golden_from, :groups, :broad_groups

      def initialize
        super
        @test_files = Rake::FileList["test/**/test_*.rb"]
        @libs = %w[lib test]
        @lowering_folders = {}
        @console_folders = {}
        @consoles = nil
        @golden_sample = GoldenSample::SHARE
        @golden_list = GOLDEN_LIST
        @golden_from = "."
        @groups = nil
        @broad_groups = {}
        yield self if block_given?
        @consoles = Console.refuse_unknown_consoles!(consoles, setting: "t.consoles")
        @lowerings = Lowering.lowerings_for(@consoles)
        define_lowering_tasks
        define_test_task
        define_group_tasks if groups
      end

      # The test files +lowering+'s run loads, playing games as +console+.
      def files(lowering, console = Lowering.run_named(lowering).console)
        Lowering.files_for(lowering, console: console, files: test_files.to_a, folders: lowering_folders,
                                     console_folders: console_folders)
      end

      private

      # Every run of the suite, as a lowering and the console it plays games as, in the order
      # `rake test:all` plays them.
      def plays = @lowerings.flat_map { |lowering| plays_of(lowering) }

      def plays_of(lowering)
        Lowering.consoles_for(Lowering.run_named(lowering), @consoles).map { |console| [lowering, console] }
      end

      def several_consoles?(lowering) = plays_of(lowering).size > 1

      # The task one run is played by: the lowering's own name when it plays a single console, and
      # the console's under it when it plays several.
      def task_name(lowering, console)
        several_consoles?(lowering) ? "test:lowering:#{lowering}:#{console}" : "test:lowering:#{lowering}"
      end

      # What `rake test:all` calls a run in the lines it ends with: the console too, where its
      # lowering plays several or plays another than its own (a runtime's, for a game for the Color alone).
      def label(lowering, console) = "#{Lowering.run_named(lowering).title} lowering#{as_console(lowering, console)}"

      def as_console(lowering, console)
        named = several_consoles?(lowering) || console != Lowering.run_named(lowering).console
        named ? " as the #{Console.for(console).title}" : ""
      end

      # `rake test:all` plays every lowering, which is long; `rake test` on its own plays nothing
      # and says what to type instead, so the long run is always chosen and never an accident.
      # With TEST= it plays that one file on every lowering whose run loads it, which is short.
      def define_test_task
        namespace :test do
          desc "Run the tests on every lowering, one after the other (CONSOLE= for one console)"
          task(:all) { play_all_runs }
          desc "Run the golden path: the files #{golden_list} names and a few more at random, on every lowering"
          task(:golden) { play_golden_runs } if File.file?(golden_list.to_s)
        end

        desc "Run one file on every lowering that plays it (TEST=test/test_foo.rb); see test:all"
        task :test do
          ENV["TEST"] ? play_runs(plays) : abort(choices_message)
        end
      end

      # The list's files and a draw of the rest. The draw's seed is said first and again last, so
      # it is on screen after a failure however long the run's output.
      def play_golden_runs
        listed = golden_files
        draw = GoldenSample.draw(test_files.to_a - listed, share: golden_sample)
        puts draw.message
        play_runs(plays, golden: listed + draw.files)
      ensure
        puts draw.message if draw
      end

      # The test files the golden list names, as paths from the folder rake runs in.
      def golden_files = Lowering.golden_files(golden_list).map { |file| golden_from == "." ? file : File.join(golden_from, file) }

      # A task for each group of tests (SuiteGroups), playing its files as the golden path plays its
      # list: on every lowering that plays each.
      def define_group_tasks
        namespace :test do
          namespace :group do
            SuiteGroups.new(groups, files: test_files.to_a, broad: broad_groups).each do |group|
              desc "Run the tests of #{group.name.tr(':', '/')} on every lowering that plays each"
              task(group.name) { play_runs(plays, golden: group.files) }
            end
          end
        end
      end

      def choices_message
        tasks = @lowerings.map { |lowering| "  rake test:lowering:#{lowering}" }
        ["`rake test` on its own runs no tests. Type one of these:", "",
         "  rake test:golden                    a few tests chosen by hand and some at random",
         "  rake test:all                       every lowering, one after the other",
         *tasks.map { |line| format("%-37s one lowering", line) },
         "  rake test TEST=test/test_thing.rb   one file, on every lowering that plays it",
         "  CONSOLE=gbc rake test:all           only the runs that play games as one console"].join("\n")
      end

      # `rake test:all`, which FAIL_FAST and RESUME turn into a run that keeps a record. Without
      # either it keeps none. RESUME stops at a failure too, so the record stays good for the next.
      def play_all_runs
        resuming = ENV[Lowering::RESUME_SETTING]
        return play_runs(plays) unless resuming || ENV[Lowering::FAIL_FAST_SETTING]

        ENV[Lowering::FAIL_FAST_SETTING] ||= "1"
        progress = RunProgress.new(plays, lowering_folders: lowering_folders, console_folders: console_folders)
        resumed = resuming && progress.stored?
        resumed ? progress.apply_changes.each { |line| puts line } : progress.start
        puts "There is no stopped run to pick up, so every run is played." if resuming && !resumed
        play_runs(plays, progress: progress)
        progress.finish
        puts RESUMED_NOTE if resumed
      end

      # The runs of +chosen+ that CONSOLE leaves, one after the other, ending with a line for each.
      # With +golden+, a list of files, each run plays those of them it loads. With +progress+, a
      # run plays what that record says is left of it.
      def play_runs(chosen, golden: nil, progress: nil)
        chosen = chosen_by_console(chosen)
        labels = chosen.map { |lowering, console| label(lowering, console) }
        results = []
        chosen.zip(labels).each do |(lowering, console), name|
          ENV["TEST"] = (golden & files(lowering, console)).join(",") if golden
          results << if progress then play_recorded_run(progress, lowering, console, name)
                     else play_run(lowering, console, name, listed: !golden.nil?)
                     end
          break if ENV[Lowering::FAIL_FAST_SETTING] && results.last[1] == :failed
        end
        puts
        results.each do |name, outcome, seconds|
          puts format("%-*s %s%s", labels.map(&:length).max, name, OUTCOMES.fetch(outcome),
                      %i[not_played passed_earlier].include?(outcome) ? "" : format(" in %ds", seconds))
        end
        abort "rake test: a lowering's run failed" if results.any? { |_, outcome| outcome == :failed }
      end

      # What the record says is left of one run. The test that stopped it is played first and alone,
      # which starts in seconds where the whole run takes minutes to load, and then the rest.
      def play_recorded_run(progress, lowering, console, name)
        left = progress.left_in(lowering, console)
        return [name, :passed_earlier, 0] if left.nil?

        only = left.only && (left.only & files(lowering, console))
        return finish_recorded_run(progress, lowering, console, [name, :passed_earlier, 0]) if only&.empty?

        with_settings(Lowering::RECORD_SETTING => left.record, "TESTOPTS" => seeded_options(left.seed), "TEST" => nil) do
          first = play_failed_test_alone(left, lowering, console, name)
          next finish_recorded_run(progress, lowering, console, first) if first && first[1] == :failed

          ENV["TEST"] = only.join(",") if only
          finish_recorded_run(progress, lowering, console, play_run(lowering, console, name, listed: !only.nil?))
        end
      end

      def finish_recorded_run(progress, lowering, console, result)
        result[1] == :failed ? progress.mark_failed(lowering, console) : progress.mark_finished(lowering, console)
        result
      end

      # Nil when the test's file has gone, or its name would not survive a shell.
      def play_failed_test_alone(left, lowering, console, name)
        file, test = left.failed&.split("\t", 2)
        return unless file && File.file?(file) && test.match?(/\A[\w:]+#\w+\z/)

        options = "#{ENV.fetch('TESTOPTS', nil)} --name=/#{test}$/".strip
        result = with_settings("TEST" => file, "TESTOPTS" => options) do
          play_run(lowering, console, name, listed: true)
        end
        Rake::Task[task_name(lowering, console)].reenable
        result
      end

      # The test options with the seed added. Nil when there are none, since rake reads an empty
      # TESTOPTS in place of the options a task was given.
      def seeded_options(seed)
        given = ENV.fetch("TESTOPTS", nil)
        seed ? "#{given} --seed=#{seed}".strip : given
      end

      # Runs the block with +settings+ in the environment (nil takes one out), and puts them back.
      def with_settings(settings)
        before = settings.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
        ENV.update(settings)
        yield
      ensure
        ENV.update(before)
      end

      # Of +chosen+, the runs playing games as the console CONSOLE names; all of them when it names none.
      def chosen_by_console(chosen)
        console = Lowering.named_console(ENV)
        return chosen if console.nil?

        left = chosen.select { |_, played_as| played_as == console }
        return left unless left.empty?

        abort "#{Lowering::CONSOLE_SETTING} is #{console}, and no run here plays games as the " \
              "#{Console.for(console).title}. Leave #{Lowering::CONSOLE_SETTING} out, or set it to " \
              "#{Lowering.in_words(chosen.map(&:last).uniq)}."
      end

      # One run: whether it passed and how long it took. Every one is played whatever the one
      # before found, unless FAIL_FAST says otherwise (#play_runs).
      def play_run(lowering, console, name, listed: false)
        named = ENV["TEST"]&.delete_prefix("./")
        return [name, :not_played, 0] if listed ? named.to_s.empty? : named && !files(lowering, console).include?(named)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        passed = begin
          Rake::Task[task_name(lowering, console)].invoke
          true
        rescue RuntimeError # a test task whose tests failed says so by raising
          false
        end
        [name, passed ? :passed : :failed, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
      end

      # Each run is a TestTask, which says how a run for that lowering is played: one for each of
      # Lowering::RUNS that plays the game's consoles, and for each console it plays them as, so a
      # new lowering is a record there and not a task written here. A lowering playing several
      # consoles has a task of its own besides, playing them one after the other.
      def define_lowering_tasks
        namespace :test do
          namespace :lowering do
            @lowerings.each do |lowering|
              run = Lowering.run_named(lowering)
              runs = plays_of(lowering)
              several_consoles?(lowering) ? define_runs_task(run, runs) : define_run_task(run, *runs.first, lowering)
            end
          end
        end
      end

      def define_runs_task(run, runs)
        namespace run.name do
          runs.each { |_, console| define_run_task(run, run.name, console, console) }
        end
        desc "Run the tests on the #{run.title} lowering as each console, one after the other (CONSOLE= for one)"
        task(run.name) { play_runs(runs) }
      end

      def define_run_task(run, lowering, console, name)
        TestTask.new(name) do |t|
          t.lowering = lowering
          t.console = console
          t.libs = libs.dup
          t.test_files = files(lowering, console)
          needs = run.needs&.then { |tool| "needs #{tool}; " }
          t.description = "Run the tests on the #{run.title} lowering#{as_console(lowering, console)}: " \
                          "#{run.does} (#{needs}one file with TEST=)"
        end
      end
    end
  end
end
