# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "stringio"
require "tmpdir"
require "vblank/live"

# THE WINDOW WAITING WHILE A HELPER PROCESS BUILDS ITS GAME (Live::BuildWatch). The helper here is
# a small Ruby that says what a build's helper says, a line at a time, so each way a build can end
# is played without building anything: the window shows the build's progress, then where the game
# is written; or the refusal, on the terminal and in the window, in plain words. However the watch
# ends, the helper does not outlive it.
class TestBuildWatch < Minitest::Test
  # Each test starts a helper process, which hangs inside a Ractor.
  runs_on_the_main_ractor!

  BuildWatch = VBlank::Live::BuildWatch
  Headless = VBlank::Live::Headless

  # Says each of its lines as the helper says them, +gap+ seconds apart, then works on for
  # +wait_seconds+, holding its end of the pipe open, and ends with +exit_status+. With +deaf+ it
  # does not end when asked (TERM). A gap only lets the window draw between two lines: a window
  # that draws sooner passes the same.
  HELPER = <<~RUBY
    lines, wait_seconds, exit_status, deaf, gap = Marshal.load(ARGV[0].unpack1("m0"))
    trap(:TERM) {} if deaf
    lines.each { |line| $stdout.write(line); $stdout.flush; sleep gap }
    sleep wait_seconds
    exit exit_status
  RUBY

  # A device that notes what the terminal held when the window first showed the refusal.
  class RefusalWatcher < Headless
    attr_reader :terminal_when_shown

    def initialize(terminal, **)
      super(**)
      @terminal = terminal
    end

    def show_waiting(lines)
      @terminal_when_shown ||= @terminal.string.dup if lines.first.end_with?("cannot play")
      super
    end
  end

  # The outcome of watching a helper that says +messages+ ([kind, value] pairs, or a line as it
  # is), and the helper's pid.
  private def watch(messages, device:, wait_seconds: 0, exit_status: 0, deaf: false, gap: 0, refusal_frames: nil, terminal: nil)
    lines = messages.map { |message| message.is_a?(String) ? message : BuildWatch.message_line(*message) }
    reader, writer = IO.pipe
    pid = Process.spawn(RbConfig.ruby, "-e", HELPER, [Marshal.dump([lines, wait_seconds, exit_status, deaf, gap])].pack("m0"),
                        out: writer)
    writer.close
    watch = BuildWatch.new(reader, pid: pid, title: "DEMO")
    [watch.watch(device, refusal_frames: refusal_frames, terminal: terminal), pid]
  end

  private def assert_ended(pid)
    assert_raises(Errno::ESRCH, Errno::ECHILD) { Process.kill(0, pid) }
  end

  def test_the_window_shows_the_build_then_gives_where_the_game_is_written
    device = Headless.new(frames: 1_000_000)
    outcome, pid = watch([["step", "Checking for mistakes"], ["count", [3, 9]], ["written", "/made/up/demo-ruby.rb"]],
                         device: device, gap: 0.2)

    assert_equal "/made/up/demo-ruby.rb", outcome.written
    assert_nil outcome.refusal
    assert_equal ["Building DEMO", "Checking for mistakes  3/9"], device.waiting.last
    assert_ended pid
  end

  # "written" ends the watch though the pipe stays open (something the build started may hold it):
  # the helper, still working, is ended rather than waited on for ever.
  def test_written_ends_the_watch_though_the_helper_holds_the_pipe_open
    device = Headless.new(frames: 1_000_000)
    outcome, pid = watch([["written", "/made/up/demo-ruby.rb"]], device: device, wait_seconds: 600)

    assert_equal "/made/up/demo-ruby.rb", outcome.written
    assert_ended pid
  end

  def test_a_build_that_cannot_play_says_why_on_the_terminal_then_in_the_window
    terminal = StringIO.new
    device = RefusalWatcher.new(terminal, frames: 1_000_000)
    words = "DEMO uses a part of VBlank that does not work in Ruby yet: rumble."
    outcome, = watch([["step", "Checking for mistakes"], ["refused", words]], device: device, exit_status: 1,
                                                                                 refusal_frames: 3, terminal: terminal)

    assert_equal words, outcome.refusal
    assert_includes device.terminal_when_shown, words
    assert_equal [["DEMO cannot play", words]] * 3, device.waiting.last(3)
  end

  def test_a_helper_that_ends_saying_nothing_is_a_refusal
    device = Headless.new(frames: 1_000_000)
    outcome, = watch([["step", "Checking for mistakes"]], device: device, exit_status: 3, refusal_frames: 1)

    assert_match(/build of DEMO stopped before it ended \(exit status 3\)/, outcome.refusal)
  end

  # A line that is none of the helper's messages is a refusal in plain words, not an error in the
  # window's process, and the helper is ended.
  def test_a_line_the_window_cannot_read_is_a_refusal
    device = Headless.new(frames: 1_000_000)
    outcome, pid = watch(["Checking for mistakes\n", ["written", "/made/up/demo-ruby.rb"]], device: device,
                                                                                         wait_seconds: 600, refusal_frames: 1)

    assert_match(/build of DEMO sent a line the window cannot read: Checking for mistakes/, outcome.refusal)
    assert_nil outcome.written
    assert_ended pid
  end

  # A device closed by its player once the window has shown a phase of the build.
  class ClosedDuringBuild < Headless
    def stop? = waiting.any? { |lines| lines.size == 2 }
  end

  # The player closed the window while the build went on: the helper is stopped, even one that does
  # not end when asked, and nothing is played.
  def test_a_window_closed_while_the_build_works_stops_the_helper
    device = ClosedDuringBuild.new(frames: 1_000_000)
    outcome, pid = watch([["step", "Checking for mistakes"]], device: device, wait_seconds: 600, deaf: true)

    assert_predicate outcome, :stopped?
    assert_ended pid
  end
end
