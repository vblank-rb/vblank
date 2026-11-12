# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# THE NATIVE RUN SPREADS ITS TESTS OVER PROCESSES, and has to report them as one run: the same
# totals, the same failures, the same skips by reason and the same class counts as one process
# playing every test itself. Each case runs a small fixture suite both ways and compares what
# they print.
class TestProcesses < Minitest::Test
  # Starts child processes, which Ruby cannot do from inside a Ractor — the spawn waits for
  # ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  ROOT = VBlank.root.to_s
  FIXTURE = File.join(ROOT, "test/fixtures/processes/mixed_results.rb")
  SHARED_FIXTURE = File.join(ROOT, "test/fixtures/processes/shared_setup.rb")
  RUNNER = File.join(ROOT, "lib/vblank/testing/processes.rb")

  # Rake's own loader, which `rake test:lowering:native` starts the suite with: it takes every argument
  # that does not start with a dash for a file to load.
  LOADER = File.join(Gem::Specification.find_by_name("rake").full_gem_path, "lib/rake/rake_test_loader.rb")

  # The fixture suite played the way `rake test:lowering:native` plays the suite: by one process when
  # +processes+ is nil, else by that many. What it printed, and whether it passed.
  private def run_fixture(processes: nil, env: {}, seed: 7, fixture: FIXTURE, args: [])
    command = [RbConfig.ruby, "-rbundler/setup", "-Itest", "-Ilib"]
    command << "-r#{RUNNER}" if processes
    command += [LOADER, fixture, "--no-ractor", *args]
    command << "--seed=#{seed}" if seed
    # The fixture is a native run of its own, whichever console the run that plays this test is playing as:
    # the console settings are left out of what it inherits, since a native run plays a Genesis as nothing.
    settings = { "VBLANK_LOWERING" => "native", "MT_CPU" => "1", "TEST_PROCESSES" => processes&.to_s,
                 "CONSOLE" => nil, "VBLANK_CONSOLE" => nil }
    out, status = Open3.capture2e(settings.merge(env), *command, chdir: ROOT)
    [out, status.success?]
  end

  # Everything a run prints from the end of its timing line on: the failures, the totals, and
  # what the suite's own reporters say about skips.
  private def report_of(out)
    out[/^Finished in .*?\n(.*)\z/m, 1] or flunk("the run printed no report:\n#{out}")
  end

  def test_a_run_across_processes_reports_what_one_process_reports
    alone, alone_passed = run_fixture
    spread, spread_passed = run_fixture(processes: 2)

    assert_equal report_of(alone), report_of(spread)
    assert_match(/18 runs, \d+ assertions, 1 failures, 0 errors, 3 skips/, report_of(spread))
    refute alone_passed
    refute spread_passed, "a run with a failure has to fail across processes too"
  end

  # A skip about the machine is counted with the rest, and neither way of playing calls it a test in
  # the wrong place, however it reached the process that reports.
  def test_a_skip_about_the_machine_is_counted_and_is_no_test_in_the_wrong_place
    alone, = run_fixture
    spread, = run_fixture(processes: 2)

    [alone, spread].each do |out|
      assert_match(/1  cannot yet: the second reason/, out)
      refute_match(/test_skips_three/, report_of(out))
    end
  end

  # How many tests the mixed fixture played: each leaves a file named for the process that played it.
  private def count_tests_played(processes, env = {})
    Dir.mktmpdir do |folder|
      out, = run_fixture(processes: processes, env: env.merge("PROCESSES_FIXTURE_PIDS" => folder))
      [out, Dir.children(folder).size]
    end
  end

  # A process that dies under a test costs that test, said as an error; a new process takes
  # its place, and every other test is still played. One process, so nobody else would.
  def test_a_process_that_dies_costs_only_the_test_it_was_playing
    out, tests = count_tests_played(1, { "PROCESSES_FIXTURE_DIE" => "1" })

    assert_equal 18, tests
    assert_match(/18 runs, \d+ assertions, 1 failures, 1 errors, 3 skips/, out)
    assert_match(/ProcessesFixturePasses#test_dies_when_asked:\nRuntimeError: .*killed by SIGKILL/, out)
  end

  # A result the reporting process cannot rebuild is still an error of that test, and keeps the
  # message the test failed with.
  def test_an_error_only_the_playing_process_knows_keeps_its_message
    out, = run_fixture(processes: 2, env: { "PROCESSES_FIXTURE_STRANGE_ERROR" => "1" })

    assert_match(/ProcessesFixturePasses#test_raises_what_only_its_process_knows_when_asked:\n.*could not be read back/, out)
    assert_includes out, "ProcessesFixtureStrangeError: a message worth keeping"
  end

  # One test of the shared-setup fixture, as the fixture wrote it down.
  Played = Data.define(:pid, :klass, :name, :seed, :started, :ended)
  # A run of the shared-setup fixture: what it printed, the class each setup ran for, every test
  # played, and when the test that kills its process did so (nil unless asked to).
  SharedRun = Data.define(:out, :setups, :played, :died_at)

  # The shared-setup fixture played by +processes+, each test waiting until the parent and every
  # child have loaded. With +die+, one test kills the process playing it.
  private def play_shared_fixture(processes, env = {}, seed: 7, die: false, args: [])
    Dir.mktmpdir do |folder|
      path = ->(name) { File.join(folder, name) }
      files = { "PROCESSES_FIXTURE_SETUPS" => path["setups"], "PROCESSES_FIXTURE_PLAYED" => path["played"],
                "PROCESSES_FIXTURE_LOADED" => path["loaded"],
                "PROCESSES_FIXTURE_LOADED_COUNT" => (processes + 1).to_s,
                "PROCESSES_FIXTURE_DIE" => die ? path["died"] : nil }
      out, = run_fixture(processes: processes, fixture: SHARED_FIXTURE, env: env.merge(files), seed: seed, args: args)
      lines = ->(name) { File.file?(path[name]) ? File.readlines(path[name], chomp: true) : [] }
      played = lines["played"].map do |line|
        pid, klass, name, played_seed, started, ended = line.split("\t")
        Played.new(pid, klass, name, played_seed, Float(started), Float(ended))
      end
      SharedRun.new(out, lines["setups"], played, lines["died"].first&.then { Float(it) })
    end
  end

  # One seed for the run, the one it prints, so a test that rolls random numbers can be played
  # again — including when the run picked the seed itself.
  def test_every_process_plays_with_the_seed_the_run_prints
    run = play_shared_fixture(3, seed: nil)

    assert_operator run.played.map(&:pid).uniq.size, :>, 1
    assert_equal [run.out[/--seed (\d+)/, 1]], run.played.map(&:seed).uniq
  end

  def test_the_tests_are_played_in_more_than_one_process
    run = play_shared_fixture(3)

    assert_equal 17, run.played.size
    assert_operator run.played.map(&:pid).uniq.size, :>, 1
  end

  # A game's test class may make one long recording and share it across its tests. All of a
  # class's tests are played by one process, so the recording is made once in the run, not once
  # in each process that played one of them. Two processes: the slow class is the last to finish
  # whoever takes it, so a process with nothing left to do takes tests from it and from no other.
  def test_what_a_class_sets_up_once_is_set_up_once_per_run
    run = play_shared_fixture(2)

    assert_match(/17 runs, \d+ assertions, 0 failures, 0 errors, 0 skips/, run.out)
    assert_equal %w[ProcessesFixtureSharedFirst ProcessesFixtureSharedSecond], run.setups.sort
    run.played.group_by(&:klass).except("ProcessesFixtureSlow").each do |klass, tests|
      assert_equal 1, tests.map(&:pid).uniq.size, "#{klass}'s tests were played by more than one process"
    end
  end

  # A slow class holds up no other: nothing starts after it ends, since every other class was
  # played by the other process meanwhile.
  def test_a_slow_class_holds_up_no_other_class
    slow, others = play_shared_fixture(2).played.partition { |test| test.klass == "ProcessesFixtureSlow" }

    assert_equal 3, slow.size
    assert_empty others.select { |test| test.started > slow.map(&:ended).max }, "a test waited for the slow class to finish"
  end

  # A class alone in the run, with processes that have nothing else to play: they take the back
  # half of what it has waiting, so its tests are spread as a run of separate tests would be.
  def test_a_class_is_spread_over_processes_that_have_nothing_else
    run = play_shared_fixture(3, args: ["--name=/test_slow/"])

    assert_equal 3, run.played.size
    assert_operator run.played.map(&:pid).uniq.size, :>, 1
  end

  # A process that dies in the middle of a class costs that one test: a new process plays the
  # rest of the class.
  def test_the_rest_of_a_class_is_played_after_its_process_dies
    run = play_shared_fixture(1, die: true)

    assert_match(/17 runs, \d+ assertions, 0 failures, 1 errors, 0 skips/, run.out)
    first = run.played.select { |test| test.klass == "ProcessesFixtureSharedFirst" }
    assert_equal 5, first.size
    refute_empty first.select { |test| test.started > run.died_at }, "the test that dies was its class's last"
  end

  # The same when the class was split over three processes: whichever piece the dying process
  # held, the rest of it is played.
  def test_the_rest_of_a_split_class_is_played_after_its_process_dies
    run = play_shared_fixture(3, die: true, args: ["--name=/ProcessesFixtureSharedFirst/"])

    assert_match(/6 runs, \d+ assertions, 0 failures, 1 errors, 0 skips/, run.out)
    assert_equal 5, run.played.size
  end

  # FAIL_FAST stops at the first failure, even in the middle of a class a process is playing.
  def test_a_run_that_stops_at_a_failure_plays_no_more_of_the_class
    run = play_shared_fixture(1, { "PROCESSES_FIXTURE_FAIL" => "1", "VBLANK_STOPS_AT_FAILURE" => "1" })

    assert_includes run.out, "Stopped at the first failure"
    assert_equal 1, run.played.count { |test| test.name.start_with?("test_reads_part") }
  end

  # And a process that dies is a failure it stops at: no new process plays the rest of the class.
  def test_a_run_that_stops_at_a_failure_stops_when_a_process_dies
    run = play_shared_fixture(1, { "VBLANK_STOPS_AT_FAILURE" => "1" }, die: true)

    assert_includes run.out, "Stopped at the first failure"
    refute_nil run.died_at
    assert_empty run.played.select { |test| test.started > run.died_at }
  end

  # A class split over three processes stops at a failure too: each process finishes at most the
  # test it was playing, and no piece of the class is played on.
  def test_a_run_that_stops_at_a_failure_plays_no_more_of_a_split_class
    run = play_shared_fixture(3, { "PROCESSES_FIXTURE_FAIL" => "1", "VBLANK_STOPS_AT_FAILURE" => "1" },
                              args: ["--name=/ProcessesFixtureSharedFirst/"])

    assert_includes run.out, "Stopped at the first failure"
    assert_operator run.played.count { |test| test.name.start_with?("test_reads_part") }, :<=, 3
  end
end
