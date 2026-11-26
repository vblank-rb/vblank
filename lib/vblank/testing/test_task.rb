# frozen_string_literal: true

require "etc"
require "rake"
require "rake/testtask"
require_relative "../console/description"
require_relative "../console/kit" # which names its parts and loads none of them
require_relative "lowering"
require_relative "ractor_settings"
require_relative "watched_run"

module VBlank
  module Testing
    # One test task, for one lowering, under a name and over files the game chooses — for a game
    # whose Rakefile keeps its own rake test and a task for each group of its tests, and wants a
    # native twin of a group without the rest of RakeTasks:
    #
    #   require "vblank/testing/test_task"
    #
    #   namespace :test do
    #     namespace :native do
    #       VBlank::Testing::TestTask.new(:items) do |t|
    #         t.lowering = :native
    #         t.libs = %w[games/minish_cap/lib test]
    #         t.test_files = FileList["test/items/**/test_*.rb"]
    #       end
    #     end
    #   end
    #
    # It is rake's own test task (everything Rake::TestTask takes, it takes), told which lowering
    # its run is for. RakeTasks makes its two runs out of two of these, so a twin a game makes is
    # the run `rake test:lowering:native` is, and how a native run is started lives here alone.
    #
    # A run is played in Ractors or in processes, as its record says (Lowering::Run#ractors). A run
    # in Ractors takes the game's Ractor settings as they are, so long as they give it --ractor; one
    # not given it (a suite that never applies RactorSettings, or --no-ractor) is played as it was
    # before any run could choose: the GBA run plain in one process, a checked run as below. Each
    # other checked run is
    # plain minitest's whatever the game sets for Ractors (no --ractor, no MT_RACTOR); its tests
    # are spread over several processes instead (Processes) — TEST_PROCESSES of them, or as many
    # as the Ractor run has workers, or half the machine's cores — each playing one test at a time
    # (MT_CPU=1). That is not because a test starts programs: one in a Ractor can (zig, node, the
    # program a build makes), as Testing's unbuffered standard output lets it. Those runs have
    # not been moved and measured yet.
    #
    # A native run asks for zig before any test is played, so a missing or wrong one stops the
    # run with one plain line rather than failing every test in turn; a JavaScript run asks for
    # node the same way.
    #
    # None of that is written into the settings of the rake process: it is handed to the run this
    # task starts and to nothing else, so a GBA run after it in the same rake call is played as the
    # game set it up.
    #
    # The name is required, since rake's own test task left without one is `rake test` — the
    # one task a game that keeps its own was making this to stay clear of.
    class TestTask < Rake::TestTask
      # The lowering this task's run is for, :gba unless told; and the console it plays games as.
      # Left untold, that is the one console names, or the lowering's own: a runtime's run can play
      # as any (Lowering::Run#plays_any_console?), and the rest refuse another.
      attr_reader :lowering
      attr_writer :console

      # What the run's heading says it plays, after the lowering's name: what the lowering's run
      # does unless told (Lowering::Run#does, which checks against the interpreter). A game that
      # holds its cartridge to something else, the retail original it ports, names that here:
      #
      #   t.heading = "the game built as a Sega Genesis cartridge, checked against the original"
      attr_writer :heading

      def initialize(name)
        @lowering = :gba
        @console = nil
        @heading = nil
        super
      end

      def console
        run = Lowering.run_named(lowering)
        @console || (run.plays_any_console? && Lowering.named_console(ENV)) || run.console
      end

      # Set inside the block, where the task is being made: a native run is made with the
      # process runner loaded, which is settled as the task is defined.
      def lowering=(lowering)
        refuse_lowering_after_definition!
        unless Lowering::NAMES.include?(lowering)
          raise ArgumentError, "This test task was given #{lowering.inspect} as its lowering. " \
                               "Give it #{Lowering.in_words(Lowering::NAMES.map(&:inspect))}."
        end

        @lowering = lowering
      end

      def define
        @ruby_opts << "-r#{bundler_setup_path}" if bundler_setup_path
        @ruby_opts << "-r#{File.expand_path('quiet_warnings.rb', __dir__)}"
        warnings_after_boot! if warning
        @ruby_opts << "-r#{File.expand_path('processes.rb', __dir__)}" if in_processes?
        @defined = true
        super
      end

      # The test options as rake reads them (TESTOPTS, or the task's own), before this task takes
      # anything out.
      alias_method :given_options, :option_list
      private :given_options

      # The test options this run is played with. A run played in processes leaves out --ractor.
      def option_list(...)
        in_processes? ? without_ractor(super) : super
      end

      private

      # Rake's test task plays its run through here, so this is where the run is handed what
      # it is for: the lowering, and on a native run the rest of how it is played. The program the
      # run needs (Lowering::Run#needs) is asked for first.
      def ruby(*args, **options, &block)
        run = Lowering.run_named(lowering)
        refuse_native_run_without_zig! if run.needs == "zig"
        refuse_js_run_without_node! if run.needs == "node"
        return say_nothing_played(run) if other_console_named?

        print_heading(run)
        command = [FileUtils::RUBY, *yjit_switch, *args].join(" ")
        return sh(run_settings, command, **options, &block) unless in_ractors?

        play_watched(command, &block)
      end

      # A run in Ractors can crash and never exit, so it is watched (WatchedRun). A crash fails the
      # run the way failing tests do, so a whole run goes on to the next lowering's.
      def play_watched(command)
        result = WatchedRun.new(run_settings, command).call
        raise result.message if result.stopped?

        yield(result.ok?, result.status)
      end

      # A ruled-off line naming the run and what it plays, so a glance at a long output says which
      # lowering's tests are going.
      def print_heading(run)
        rule = "=" * 92
        as = console == run.console ? "" : " as the #{Console.for(console).title}"
        $stdout.puts "", rule, " #{run.title} lowering#{as}: #{@heading || run.does}", rule
        $stdout.flush
      end

      # The bundler/setup RUBYOPT names, or nil where this rake process runs without bundler.
      # Bundler puts it there for every process started after it is set up, whether by
      # `bundle exec`, `require "bundler/setup"` or `Bundler.setup`.
      #
      # It goes first on the run's command line, ahead of the files below. Ruby reads the `-r`
      # files on its command line before the ones in RUBYOPT. Up to Ruby 4.0 that did not matter:
      # RubyGems set bundler up itself as it loaded, before either. Ruby 4.1 stopped doing that,
      # so processes.rb's `require "minitest"` would take the newest minitest installed, and
      # bundler, coming after, would refuse it as not the Gemfile's and stop the run before a
      # test played. Every run gets it, so each sets bundler up at the same point; the file
      # RUBYOPT names then loads nothing a second time.
      def bundler_setup_path = ENV.fetch("RUBYOPT", "")[%r{-r(\S*bundler/setup)(?:\.rb)?(?=\s|\z)}, 1]

      # A run whose tests are played in Ractors: one whose record allows it (Lowering::Run#ractors),
      # given --ractor. Asked of the options as given, since #option_list takes the flag out of a
      # run in processes.
      def in_ractors? = Lowering.run_named(lowering).ractors? && given_options.split.include?("--ractor")

      # A run whose tests are spread over processes (Processes): a checked run not played in
      # Ractors, one whose record allows them included when it is not given --ractor. A game's
      # suite that never applies RactorSettings, or TESTOPTS=--no-ractor, would otherwise play a
      # whole checked run in one process. The GBA run, which plays the interpreter alone, is plain
      # minitest in one process outside Ractors, as it always was.
      def in_processes? = Lowering.run_named(lowering).checked? && !in_ractors?

      # Is the run played with YJIT, Ruby's compiler of hot methods to machine code? Where its
      # record shows YJIT makes it faster (Lowering::Run#yjit), and never in Ractors: with several
      # running at once it makes a run many times slower. Off is set on Ruby's command line,
      # which wins over a --yjit in RUBYOPT; on is set in the environment (#run_settings), which
      # the processes a run in processes starts for its tests inherit. A Ruby built without YJIT takes
      # both and ignores them.
      def yjit? = Lowering.run_named(lowering).yjit? && !in_ractors?

      def yjit_switch = yjit? ? [] : ["--disable-yjit"]

      def without_ractor(options) = (options.split - %w[--ractor]).join(" ")

      # What the run is handed. A run in processes has its own copy of TESTOPTS lose --ractor
      # too, since a test that starts a run of its own hands that copy on. YJIT as #yjit? returns.
      # The console is always set, as VBLANK_CONSOLE, and console is not handed on
      # (Lowering::PLAYED_AS_SETTING says why).
      def run_settings
        shared = { "RUBY_YJIT_ENABLE" => yjit? ? "1" : nil, Lowering::PLAYED_AS_SETTING => console.to_s,
                   Lowering::CONSOLE_SETTING => nil, Lowering::FAIL_FAST_SETTING => nil,
                   Lowering::RESUME_SETTING => nil, Lowering::STOPS_AT_FAILURE_SETTING => ENV.fetch(Lowering::FAIL_FAST_SETTING, nil) }
        return { Lowering::SETTING => lowering.to_s, **roomy_heap_settings, **shared } unless in_processes?

        { Lowering::SETTING => lowering.to_s, "MT_RACTOR" => nil, "MT_CPU" => "1", **shared,
          "TESTOPTS" => ENV["TESTOPTS"] && without_ractor(ENV["TESTOPTS"]),
          "TEST_PROCESSES" => ENV.fetch("TEST_PROCESSES") { ENV.fetch("MT_RACTOR_WORKERS") { RactorSettings.default_workers.to_s } } }
      end

      # Warnings asked for (`t.warning`, on unless a game turns it off) are turned on by a file the
      # run loads first (warnings_on.rb says why) rather than by `ruby -w`.
      def warnings_after_boot!
        self.warning = false
        @ruby_opts << "-r#{File.expand_path('warnings_on.rb', __dir__)}"
      end

      # RactorSettings' roomy heap, for a run in Ractors whose record asks for it
      # (Lowering::Run#roomy_heap), with any of its settings already in the environment left as
      # they are. Handed to that run alone, so a run after it in the same rake call keeps its own.
      def roomy_heap_settings
        return {} unless in_ractors? && Lowering.run_named(lowering).roomy_heap?

        RactorSettings::ROOMY_HEAP.to_h { |name, value| [name, ENV.fetch(name, value)] }
      end

      def refuse_lowering_after_definition!
        return unless @defined

        raise ArgumentError, "This test task is already made, so its lowering cannot change. " \
                             "Say the lowering inside the block that makes it."
      end

      # Does CONSOLE name a console other than the one this run plays games as? Then the run plays
      # nothing, as `rake test:all` leaves out every run that does not play as that console.
      def other_console_named?
        named = Lowering.named_console(ENV)
        !named.nil? && named != console
      end

      def say_nothing_played(run)
        named = Console.for(Lowering.named_console(ENV)).title
        $stdout.puts "The #{run.title} run plays games as the #{Console.for(console).title}. " \
                     "#{Lowering::CONSOLE_SETTING} names the #{named}, so this run plays no tests."
      end

      def refuse_native_run_without_zig!
        require_relative "../ir/backends/native/zig"
        IR::Backends::Native::Zig.version
      rescue IR::Backends::Computer::Error => e
        abort "The native lowering's run needs zig, and #{e.message}"
      end

      def refuse_js_run_without_node!
        require_relative "../ir/backends/js/node"
        IR::Backends::JS::Node.version
      rescue IR::Backends::JS::Node::Error => e
        abort "The JavaScript lowering's run needs node, and #{e.message}"
      end
    end
  end
end
