# frozen_string_literal: true

require "rake"
require "rake/tasklib"
require_relative "golden_limit"
require_relative "lowering"
require_relative "test_task"

module VBlank
  module Testing
    # `rake test:golden` FOR A GAME THAT KEEPS ITS OWN TEST TASKS rather than RakeTasks (which makes
    # one of its own from t.golden_list). The golden path is the short run before a commit: the test
    # files a list names, failing past GoldenLimit's time. In the game's Rakefile:
    #
    #   require "vblank/testing/golden_task"
    #
    #   VBlank::Testing::GoldenTask.new(list: "games/rocket/test/golden.txt", from: "games/rocket") do |t|
    #     t.libs = %w[lib games/rocket/lib games/rocket/test]
    #   end
    #
    # The list is a test file a line, blank lines and lines starting # left out, each read from the
    # folder +from+ (the folder rake runs in unless said). It is read when the task runs, so a clone
    # without the list still has every other task. The block is handed the TestTask that plays the
    # files, the GBA lowering's run, to set what any test task takes. The task is `test:golden`
    # unless +name+ says otherwise; it plays the files and nothing else.
    class GoldenTask < Rake::TaskLib
      def initialize(list:, from: ".", name: "test:golden", most_seconds: GoldenLimit::MOST_SECONDS, &configure)
        super()
        @list = list
        @from = from
        @name = name
        @most_seconds = most_seconds
        @configure = configure
        define_golden_task
      end

      # The test files the list names, as paths from the folder rake runs in.
      def files = Lowering.golden_files(@list).map { |file| @from == "." ? file : File.join(@from, file) }

      private

      def define_golden_task
        desc "Run the golden path, the files #{@list} names, and fail past #{@most_seconds} seconds"
        task(@name) do
          abort "There is no golden list at #{@list}. Make it, with a test file a line." unless File.file?(@list)

          GoldenLimit.hold(list: @list, most_seconds: @most_seconds) { files_task.invoke }
        end
      end

      # The test task over the list's files, made the first time the golden path runs.
      def files_task
        name = "#{@name}:files"
        return Rake::Task[name] if Rake::Task.task_defined?(name)

        TestTask.new(name) do |t|
          t.test_files = files
          @configure&.call(t)
        end
        Rake::Task[name]
      end
    end
  end
end
