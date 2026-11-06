# frozen_string_literal: true

require "rake"
require "rake/tasklib"
require_relative "golden_sample"
require_relative "lowering"
require_relative "test_task"

module VBlank
  module Testing
    # `rake test:golden` FOR A GAME THAT KEEPS ITS OWN TEST TASKS rather than RakeTasks (which makes
    # one of its own from t.golden_list). The golden path is the short run before a commit: the test
    # files a list names, and a share of the game's other test files drawn at random (GoldenSample).
    # In the game's Rakefile:
    #
    #   require "vblank/testing/golden_task"
    #
    #   VBlank::Testing::GoldenTask.new(list: "games/rocket/test/golden.txt", from: "games/rocket") do |t|
    #     t.libs = %w[lib games/rocket/lib games/rocket/test]
    #   end
    #
    # The list is a test file a line, blank lines and lines starting # left out, each read from the
    # folder +from+ (the folder rake runs in unless said). It is read when the task runs, so a clone
    # without the list still has every other task. The rest are drawn from +test_files+, the test
    # files beneath the list's own folder unless said (`test_*.rb` and `*_test.rb`), and +sample+ is
    # the share drawn. The block is handed the TestTask that plays the files, the GBA lowering's run,
    # to set what any test task takes. The task is `test:golden` unless +name+ says otherwise.
    class GoldenTask < Rake::TaskLib
      def initialize(list:, from: ".", name: "test:golden", test_files: nil, sample: GoldenSample::SHARE, &configure)
        super()
        @list = list
        @from = from
        @name = name
        @test_files = test_files
        @sample = sample
        @configure = configure
        define_golden_task
      end

      # The test files the list names, as paths from the folder rake runs in.
      def files = Lowering.golden_files(@list).map { |file| @from == "." ? file : File.join(@from, file) }

      # Every test file the random part draws from, the list's own included.
      def test_files
        @test_files || Rake::FileList[File.join(File.dirname(@list), "**", "{test_*,*_test}.rb")].to_a
      end

      private

      def define_golden_task
        desc "Run the golden path: the files #{@list} names and a few more at random"
        task(@name) do
          abort "There is no golden list at #{@list}. Make it, with a test file a line." unless File.file?(@list)

          play_golden_files
        end
      end

      def play_golden_files
        listed = files
        draw = GoldenSample.draw(test_files.to_a - listed, share: @sample)
        puts draw.message
        files_task(listed + draw.files).invoke
      ensure
        puts draw.message if draw
      end

      # The test task over +chosen+, made the first time the golden path runs.
      def files_task(chosen)
        name = "#{@name}:files"
        return Rake::Task[name] if Rake::Task.task_defined?(name)

        TestTask.new(name) do |t|
          t.test_files = chosen
          @configure&.call(t)
        end
        Rake::Task[name]
      end
    end
  end
end
