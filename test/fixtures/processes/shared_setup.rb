# frozen_string_literal: true

require "test_helper"

# A small suite for test/all/vblank/testing/test_processes.rb: classes whose tests share something
# made once for the class, as a game's tests share one long recording (`@@runs ||= ...`), and a
# class far slower than the rest. Not named test_*.rb, so the suite itself never loads it.
#
# Each class's shared setup adds a line naming its class to the file PROCESSES_FIXTURE_SETUPS
# names, each time it runs. Each test adds a line to the file PROCESSES_FIXTURE_PLAYED names:
# its process, its class, the seed it was given, and when it started and ended (the computer's
# clock, compared only for which came first). With PROCESSES_FIXTURE_FAIL set, every test of the
# shared classes fails.
#
# Which process asks for work first depends on how quickly each loads, so a test of how work is
# spread waits for every process to be loaded before it plays: each process that loads this file
# adds a line to the file PROCESSES_FIXTURE_LOADED names, and a test waits until it holds
# PROCESSES_FIXTURE_LOADED_COUNT lines (the parent and each child).
if (loaded = ENV.fetch("PROCESSES_FIXTURE_LOADED", nil))
  File.open(loaded, "a") { |file| file.puts(Process.pid) }
end

module ProcessesSharedFixture
  private

  def note_played
    wait_for_every_process
    started = Process.clock_gettime(Process::CLOCK_REALTIME)
    yield
  ensure
    if (played = ENV.fetch("PROCESSES_FIXTURE_PLAYED", nil))
      line = [Process.pid, self.class.name, name, Minitest.seed, started,
              Process.clock_gettime(Process::CLOCK_REALTIME)].join("\t")
      File.open(played, "a") { |file| file.puts(line) }
    end
  end

  def wait_for_every_process
    loaded = ENV.fetch("PROCESSES_FIXTURE_LOADED", nil) or return
    count = Integer(ENV.fetch("PROCESSES_FIXTURE_LOADED_COUNT"))
    wait_until { File.readlines(loaded).size >= count }
  end

  # With PROCESSES_FIXTURE_SLOW_WAITS_FOR set, a slow test waits until that many tests of other
  # classes have been played: slow by construction, so it is the last to end however busy the
  # machine is, where a slow test that only slept could end first on a machine that slowed the rest.
  def wait_for_other_classes
    count = ENV.fetch("PROCESSES_FIXTURE_SLOW_WAITS_FOR", nil) or return
    played = ENV.fetch("PROCESSES_FIXTURE_PLAYED")
    wait_until { File.file?(played) && File.readlines(played).count { |line| !line.include?("\tProcessesFixtureSlow\t") } >= Integer(count) }
  end

  # Waits until the block is true. The clock only catches a wait that never ends: a test whose
  # wait is never met fails the test asking, not the run, after this many seconds.
  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    sleep 0.02 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  # The class's shared recording, made the slow way: noted, and a pause.
  def make_recording
    setups = ENV.fetch("PROCESSES_FIXTURE_SETUPS", nil)
    File.open(setups, "a") { |file| file.puts(self.class.name) } if setups
    sleep 0.1
    :recording
  end
end

class ProcessesFixtureSharedFirst < Minitest::Test
  include ProcessesSharedFixture

  private def recording = @@recording ||= make_recording # rubocop:disable Style/ClassVars

  5.times do |i|
    define_method(:"test_reads_part_#{i}") do
      note_played do
        flunk "every one fails on purpose" if ENV["PROCESSES_FIXTURE_FAIL"]
        assert_equal :recording, recording
      end
    end
  end

  # With PROCESSES_FIXTURE_DIE naming a file, takes its own process down, having written there
  # when it did.
  def test_dies_when_asked
    note_played do
      if (died = ENV.fetch("PROCESSES_FIXTURE_DIE", nil))
        File.write(died, Process.clock_gettime(Process::CLOCK_REALTIME).to_s)
        Process.kill(:KILL, Process.pid)
      end
    end
  end
end

class ProcessesFixtureSharedSecond < Minitest::Test
  include ProcessesSharedFixture

  private def recording = @@recording ||= make_recording # rubocop:disable Style/ClassVars

  5.times do |i|
    define_method(:"test_reads_part_#{i}") do
      note_played do
        flunk "every one fails on purpose" if ENV["PROCESSES_FIXTURE_FAIL"]
        assert_equal :recording, recording
      end
    end
  end
end

class ProcessesFixtureSlow < Minitest::Test
  include ProcessesSharedFixture

  3.times do |i|
    define_method(:"test_slow_#{i}") do
      note_played do
        wait_for_other_classes
        sleep 0.5
      end
    end
  end
end

class ProcessesFixtureQuickOne < Minitest::Test
  include ProcessesSharedFixture

  def test_quick = note_played { sleep 0.02 }
end

class ProcessesFixtureQuickTwo < Minitest::Test
  include ProcessesSharedFixture

  def test_quick = note_played { sleep 0.02 }
  def test_quick_again = note_played { sleep 0.02 }
end
