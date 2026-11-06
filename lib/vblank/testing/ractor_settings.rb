# frozen_string_literal: true

require "etc"

module VBlank
  module Testing
    # A GAME'S SUITE PLAYED IN RACTORS, set up from its Rakefile in one line, before its test tasks:
    #
    #   require "vblank/testing/ractor_settings"
    #   VBlank::Testing::RactorSettings.apply(ENV, roomy_heap: true)
    #
    # Ractors are Ruby's way of using every core in one process. minitest-ractor plays each test in
    # one, and a test that reaches state the whole process shares is reported rather than
    # tolerated. The game's test helper does its half (Testing::InRactors). This is the Rakefile's:
    #
    # --ractor GOES INTO TESTOPTS rather than a task's own options, because rake reads TESTOPTS IN
    # PLACE OF those options when it is set: `TESTOPTS="--name=/x/"` would play that one test without
    # Ractors, and a test could pass alone that the suite would refuse. Options that already name
    # --ractor or --no-ractor (for chasing one failure the plain way) are left as they are, matched as
    # whole words, so a pattern that happens to contain "ractor" is not taken for the flag. The native
    # and other checked runs take it out again themselves (TestTask), since they cannot play in
    # Ractors.
    #
    # HALF THE MACHINE'S CORES, unless MT_RACTOR_WORKERS asks otherwise. A run on every core holds the
    # whole machine for its length, and is not much quicker: so much of a test run waits on things
    # other than arithmetic that half the workers finish in about the time all of them do.
    #
    # +roomy_heap+ gives the test process room to allocate before Ruby collects its garbage. Every
    # Ractor shares one heap, and a collection any of them starts stops all of them until it is done;
    # Ruby's defaults collect after every 16 MB allocated, which many cores building cartridges use
    # up many times a second. It is paid for in memory. A value already in the environment wins. The
    # settings go in +env+, so every program rake starts after them has them too: a Rakefile that
    # wants them for its test runs alone applies them in a task its test tasks depend on.
    module RactorSettings
      FLAGS = %w[--ractor --no-ractor].freeze
      WORKERS_SETTING = "MT_RACTOR_WORKERS"

      # Room for objects of each of Ruby's five slot sizes before the first collection, and how much
      # memory outside them may be taken between collections.
      ROOMY_HEAP = Ractor.make_shareable({
        "RUBY_GC_HEAP_0_INIT_SLOTS" => "4000000",
        "RUBY_GC_HEAP_1_INIT_SLOTS" => "2000000",
        "RUBY_GC_HEAP_2_INIT_SLOTS" => "1000000",
        "RUBY_GC_HEAP_3_INIT_SLOTS" => "250000",
        "RUBY_GC_HEAP_4_INIT_SLOTS" => "125000",
        "RUBY_GC_MALLOC_LIMIT" => (256 << 20).to_s,
        "RUBY_GC_MALLOC_LIMIT_MAX" => (1 << 30).to_s,
        "RUBY_GC_OLDMALLOC_LIMIT" => (256 << 20).to_s,
        "RUBY_GC_OLDMALLOC_LIMIT_MAX" => (1 << 30).to_s
      })

      module_function

      # Put the settings in +env+ (ENV, or a Hash in a test).
      def apply(env, roomy_heap: false)
        options = env.fetch("TESTOPTS", "").to_s
        env["TESTOPTS"] = "--ractor #{options}".strip unless options.split.intersect?(FLAGS)
        env[WORKERS_SETTING] ||= default_workers.to_s
        ROOMY_HEAP.each { |name, value| env[name] ||= value } if roomy_heap
        env
      end

      # Half the machine's cores, and one at least: how many test workers a run has unless told.
      def default_workers = [Etc.nprocessors / 2, 1].max
    end
  end
end
