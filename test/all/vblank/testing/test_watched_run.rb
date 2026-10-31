# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/testing/watched_run"

# A RUN THAT CAN NO LONGER FINISH ENDS ANYWAY. Ruby crashing in a Ractor can stop every other
# Ractor and never exit, which leaves a whole run holding the machine's lock with nothing moving.
class TestWatchedRun < Minitest::Test
  # Each case starts a program of its own, which hangs inside a Ractor.
  runs_on_the_main_ractor!

  WatchedRun = VBlank::Testing::WatchedRun

  private def run_script(text, **limits)
    Dir.mktmpdir do |dir|
      script = File.join(dir, "child.rb")
      File.write(script, text)
      out = StringIO.new
      result = WatchedRun.new({}, "#{RbConfig.ruby} #{script}", out: out, keep_in: dir, sample_seconds: 0, **limits).call
      kept = result.report_path && File.read(result.report_path)
      yield result, out.string, kept
    end
  end

  def test_a_crash_that_hangs_ends_the_run_naming_the_test_file
    crash = <<~RUBY
      $stdout.sync = true
      puts "...."
      puts "test/all/vblank/ir/test_thing.rb:12: [BUG] Segmentation fault at 0x0"
      puts "-- Ruby level backtrace --"
      sleep
    RUBY
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    run_script(crash, crash_grace: 0.2, silence_limit: 60) do |result, out, kept|
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
      assert result.stopped?
      refute result.ok?
      assert_match(/test_thing\.rb:12/, result.message)
      assert_match(/Ruby crashed/, result.message)
      assert_match(/\[BUG\]/, out, "what the run printed is still shown")
      assert_match(/\[BUG\]/, kept)
    end
  end

  def test_a_crash_that_ends_by_itself_is_named_too
    crash = <<~RUBY
      $stdout.sync = true
      puts "test/all/vblank/ir/test_thing.rb:12: [BUG] Segmentation fault at 0x0"
      Process.kill("ABRT", Process.pid)
    RUBY

    run_script(crash, crash_grace: 5, silence_limit: 60) do |result, _out, _kept|
      assert result.stopped?
      assert_match(/test_thing\.rb:12/, result.message)
    end
  end

  def test_a_run_that_goes_silent_is_ended
    silent = <<~RUBY
      $stdout.sync = true
      puts "...."
      sleep
    RUBY

    run_script(silent, crash_grace: 5, silence_limit: 0.3) do |result, _out, kept|
      assert result.stopped?
      assert_match(/printed nothing/, result.message)
      assert_match(/\.\.\.\./, kept)
    end
  end

  def test_a_run_that_passes_is_left_alone
    run_script(%(puts "all good"), crash_grace: 5, silence_limit: 60) do |result, out, _kept|
      assert result.ok?
      refute result.stopped?
      assert_match(/all good/, out)
    end
  end

  def test_a_run_whose_tests_fail_is_an_ordinary_failure
    run_script("exit 1", crash_grace: 5, silence_limit: 60) do |result, _out, _kept|
      refute result.ok?
      refute result.stopped?
    end
  end
end
