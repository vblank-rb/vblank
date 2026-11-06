# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest"
require_relative "lowering"

module VBlank
  module Testing
    # HOW FAR `rake test:all` GOT, so a run stopped at a failure can pick up there. A whole run takes
    # most of an hour, and a fault found near the end used to cost the hour again. FAIL_FAST=1 keeps
    # this record and RESUME=1 reads it. A plain `rake test:all` neither writes nor reads it.
    #
    # WHAT IS KEPT, in a folder that tells git to leave it alone: a digest of each file of the
    # project, which runs finished, and for each run a file of lines its test process adds to as
    # results come in. Lines rather than a count, because a run in several processes finishes its
    # tests in no fixed order, and written at once, because FailFast can end the process at any moment.
    #
    # WHAT A RESUME KEEPS depends on what changed since, the rules `.claude/CLAUDE.md` gives for which
    # run a change needs. A file every run reads starts everything again and says which file. A file
    # one lowering owns redoes that lowering's runs. A test file is played again, alone, on each run
    # that had finished. A document changes nothing. So a resumed pass is good evidence and not
    # proof, which is why its last line says it does not stand in for one clean run.
    class RunProgress
      FOLDER = ".test_progress"
      STATE_FILE = "state.json"
      # A test file, not a helper the tests share: `test_helper.rb` is read by all of them.
      TEST_FILE = /\A(?:test_.*|.*_test)\.rb\z/
      SHARED_TEST_HELPER = "test_helper.rb"
      UNREAD_BY_TESTS = %r{\A\.(?:claude|github)/|\.md\z}
      BACKENDS = "lib/vblank/ir/backends"

      # What is left of one run: where its results go, the seed it first played with, the test that
      # failed ("file\tClass#test_name", or nil), and the files it is left to play (nil for all).
      Left = Data.define(:record, :seed, :failed, :only)

      # +plays+ is each run as RakeTasks lists them, `[lowering, console]`.
      def initialize(plays, root: Dir.pwd, lowering_folders: {}, console_folders: {})
        @plays = plays
        @root = root
        @lowering_folders = lowering_folders
        @console_folders = console_folders
        @state = File.file?(state_path) ? JSON.parse(File.read(state_path)) : nil
      end

      def stored? = !@state.nil?

      # Forgets any earlier run and records the project's files as they are now.
      def start
        FileUtils.rm_rf(folder)
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, ".gitignore"), "*\n")
        @state = { "files" => digests, "runs" => {} }
        save
      end

      # Applies what changed since the record was made, and returns sentences saying what that undid.
      def apply_changes
        changed = changed_files
        shared = changed.find { |path| reach(path) == :every_run }
        if shared
          start
          return ["#{shared} changed, and every run reads it, so nothing is kept."]
        end

        said = changed.filter_map { |path| undo_for(path, reach(path)) }
        @state["files"] = digests
        save
        said
      end

      # What is left of the run, or nil if it finished.
      def left_in(lowering, console)
        key = key_for(lowering, console)
        run = @state["runs"].fetch(key, {})
        return if run["finished"]

        Left.new(record: record_path(key), seed: seed_in(key), failed: failed_in(key), only: run["only"])
      end

      def mark_finished(lowering, console)
        @state["runs"][key_for(lowering, console)] = { "finished" => true }
        save
      end

      # A run that failed with no test named has nothing to pick up from (a crash, or what the
      # Ractor runner found at the end), so all of it is played again.
      def mark_failed(lowering, console)
        key = key_for(lowering, console)
        FileUtils.rm_f(record_path(key)) if failed_in(key).nil?
      end

      def finish = FileUtils.rm_rf(folder)

      # The result lines of a run's record, added by a test process.
      class Recorder < Minitest::AbstractReporter
        def initialize(path, seed)
          super()
          @path = path
          add("seed #{seed}") unless File.file?(path)
        end

        def record(result)
          return if result.skipped?

          add("#{result.passed? ? 'passed' : 'failed'} #{RunProgress.test_line(result)}")
        end

        private

        def add(line) = File.open(@path, "a") { |file| file.puts(line) }
      end

      # Puts the tests a record marks as passed out of the run, keeping the order of the rest.
      module LeaveOutPassed
        def filter_runnable_methods(options = {})
          super.reject { |name| RunProgress.passed_tests.include?("#{self.name}##{name}") }
        end
      end

      class << self
        attr_reader :record, :passed_tests

        # What a run's test process does with the record it is told of: reads what passed, and
        # leaves that out of the run.
        def leave_out_passed_tests(path)
          @record = path
          @passed_tests = passed_in(path)
          Minitest::Runnable.singleton_class.prepend(LeaveOutPassed)
        end

        def passed_in(path)
          lines_of(path).filter_map { |line| line.split("\t", 2).last if line.start_with?("passed ") }.to_set
        end

        def lines_of(path) = File.file?(path) ? File.readlines(path, chomp: true) : []

        def test_line(result)
          file = File.expand_path(result.source_location.first).delete_prefix("#{Dir.pwd}/")
          "#{file}\t#{result.class_name}##{result.name}"
        end
      end

      private

      def folder = File.join(@root, FOLDER)
      def state_path = File.join(folder, STATE_FILE)
      def save = File.write(state_path, JSON.generate(@state))
      def key_for(lowering, console) = "#{lowering}-#{console}"
      def record_path(key) = File.join(folder, "#{key}.tests")

      def seed_in(key)
        line = self.class.lines_of(record_path(key)).find { |text| text.start_with?("seed ") }
        line && Integer(line.delete_prefix("seed "))
      end

      def failed_in(key)
        line = self.class.lines_of(record_path(key)).reverse.find { |text| text.start_with?("failed ") }
        return if line.nil?

        test = line.delete_prefix("failed ")
        test unless self.class.passed_in(record_path(key)).include?(test.split("\t", 2).last)
      end

      # Every file of the project: the ones git knows of, which leaves out what a build makes.
      def project_files
        listed = IO.popen(%w[git ls-files --cached --others --exclude-standard], chdir: @root, err: File::NULL, &:readlines)
        return listed.map(&:chomp) if Process.last_status.success?

        Dir.glob("**/*", base: @root)
      rescue Errno::ENOENT # no git on this machine
        Dir.glob("**/*", base: @root)
      end

      def digests
        project_files.select { |path| File.file?(File.join(@root, path)) }.to_h do |path|
          [path, Digest::MD5.file(File.join(@root, path)).hexdigest]
        end
      end

      def changed_files
        now = digests
        was = @state["files"]
        (now.keys | was.keys).select { |path| now[path] != was[path] }.sort
      end

      # What a change to +path+ undoes: nothing, one test file, some runs (a list of keys), or
      # :every_run.
      def reach(path)
        return :nothing if path.match?(UNREAD_BY_TESTS)

        name = File.basename(path)
        return :test_file if name.match?(TEST_FILE) && name != SHARED_TEST_HELPER

        keys = plays_owning(path).map { |lowering, console| key_for(lowering, console) }
        keys.empty? ? :every_run : keys
      end

      def plays_owning(path)
        lowering = run_whose_code_holds(path)
        # Every run that builds the game is written over the native lowering's statements, or near enough.
        return @plays.select { |name, _| Lowering.run_named(name).checked? } if lowering&.name == :native
        return @plays.select { |name, _| name == lowering.name } if lowering

        @plays.select do |name, console|
          inside?(path, @lowering_folders.fetch(name, [])) || inside?(path, @console_folders.fetch(console, []))
        end
      end

      def run_whose_code_holds(path)
        Lowering::RUNS.find { |run| path.start_with?("#{BACKENDS}/#{run.name}/") || path == "#{BACKENDS}/#{run.name}.rb" }
      end

      def inside?(path, folders) = folders.any? { |dir| path.start_with?("#{dir}/") }

      def undo_for(path, reached)
        case reached
        when :nothing then nil
        when :test_file then replay_test_file(path)
        else redo_runs(path, reached)
        end
      end

      # The tests of +path+ are played again, wherever they had passed.
      def replay_test_file(path)
        @state["runs"].each_value do |run|
          next unless run["finished"] || run["only"]

          run.delete("finished")
          run["only"] = [*run["only"], path].uniq
        end
        forget_tests_of(path)
        "#{path} changed, so its tests are played again."
      end

      def forget_tests_of(path)
        Dir.glob(File.join(folder, "*.tests")).each do |record|
          kept = self.class.lines_of(record).reject { |line| line.split(" ", 2).last.start_with?("#{path}\t") }
          File.write(record, kept.map { |line| "#{line}\n" }.join)
        end
      end

      def redo_runs(path, keys)
        keys.each do |key|
          @state["runs"].delete(key)
          FileUtils.rm_f(record_path(key))
        end
        "#{path} changed, so #{keys.join(', ')} #{keys.size == 1 ? 'is' : 'are'} played again."
      end
    end
  end
end
