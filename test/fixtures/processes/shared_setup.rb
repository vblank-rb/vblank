# frozen_string_literal: true

require "test_helper"

# A small suite for test/all/vblank/testing/test_processes.rb: classes whose tests share something
# made once for the class, as a game's tests share one long recording (`@@runs ||= ...`), and a
# class far slower than the rest. Not named test_*.rb, so the suite itself never loads it.
#
# Each class's shared setup adds a line naming its class to the file PROCESSES_FIXTURE_SETUPS
# names, each time it runs. Each test adds a line to the file PROCESSES_FIXTURE_PLAYED names:
# its process, its class, the seed it was given, and when it started and ended. With
# PROCESSES_FIXTURE_FAIL set, every test of the shared classes fails.
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
    # Seconds to wait at most: a process that never loads fails the test asking, not the run.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    sleep 0.02 until File.readlines(loaded).size >= count || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
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
    define_method(:"test_slow_#{i}") { note_played { sleep 0.5 } }
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
