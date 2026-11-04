# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "timeout"
require "English"

# `vblank run GAME --host` IN ONE PROCESS AND `--join ADDRESS` IN ANOTHER, over a TCP port on this computer,
# the way two people would play: the match, the plain words it says, and what happens to one when the
# other is killed. They play with no window and hold buttons (--no-window, --keys), since a test has no one
# at the keyboard. The pieces under it are tested without processes in test_direct_connection.rb.
class TestDirectPlayCommand < Minitest::Test
  RUBY = RbConfig.ruby.freeze
  BIN = VBlank.root.join("bin/vblank").to_s
  GAME = VBlank.root.join("examples/wanderers.rb").to_s

  # Longest to wait for a line a process should have written. Nothing in a run depends on it: it only
  # stops a test that would otherwise wait for ever.
  FUSE_SECONDS = 120

  # One running `vblank run`: what it has said so far is read a line at a time.
  Run = Struct.new(:io, :lines, :pid) do
    def read_until(pattern)
      Timeout.timeout(FUSE_SECONDS) do
        while (line = io.gets)
          lines << line
          return line if line.match?(pattern)
        end
      end
      nil
    end

    def finish
      lines.concat(io.readlines)
      io.close
      $CHILD_STATUS
    end
  end

  private def start(*args)
    io = IO.popen([RUBY, BIN, "run", GAME, *args, { err: %i[child out] }])
    Run.new(io, [], io.pid)
  end

  private def host(*args) = start("--host", "0", "--no-window", *args)

  private def port_of(run) = run.read_until(/on port (\d+)/)[/on port (\d+)/, 1]

  def test_two_processes_play_one_match_and_agree
    hosting = host("--pictures", "80", "--keys", "right")
    port = port_of(hosting)
    joining = start("--join", "127.0.0.1:#{port}", "--no-window", "--pictures", "80", "--keys", "left")

    joined = joining.finish
    hosted = hosting.finish

    assert_predicate joined, :success?, joining.lines.join
    assert_predicate hosted, :success?, hosting.lines.join
    assert_includes hosting.lines.join, "You are player 1."
    assert_includes joining.lines.join, "You are player 2."
    [hosting, joining].each { |run| assert_match(/agreed on every checkpoint/, run.lines.join) }
  end

  def test_a_killed_process_is_a_player_who_left_and_the_other_goes_on
    hosting = host("--pictures", "3000", "--keys", "right")
    port = port_of(hosting)
    joining = start("--join", "127.0.0.1:#{port}", "--no-window", "--pictures", "100000", "--keys", "left")
    joining.read_until(/The match has begun/)
    Process.kill("KILL", joining.pid)
    Process.wait(joining.pid)

    said = hosting.read_until(/Player 2 left the match/)
    hosted = hosting.finish

    refute_nil said, "the host said a player left: #{hosting.lines.join}"
    assert_predicate hosted, :success?, hosting.lines.join
    assert_match(/The match is over/, hosting.lines.join)
  end

  def test_joining_an_address_where_nobody_hosts_says_so_in_plain_words
    unused = TCPServer.new("127.0.0.1", 0)
    port = unused.addr[1]
    unused.close
    joining = start("--join", "127.0.0.1:#{port}", "--no-window", "--pictures", "5")

    status = joining.finish

    refute_predicate status, :success?
    assert_match(/Nobody is hosting at 127\.0\.0\.1:#{port}/, joining.lines.join)
    refute_match(/\.rb:\d+:in/, joining.lines.join, "no backtrace")
  end

  def test_a_game_that_is_not_the_hosts_is_refused_in_plain_words
    hosting = host("--pictures", "40")
    port = port_of(hosting)
    other = IO.popen([RUBY, BIN, "run", VBlank.root.join("examples/wanderers.rb").to_s, "--join", "127.0.0.1:#{port}", "--console", "gbc",
                      "--no-window", "--pictures", "40", { err: %i[child out] }])
    refused = other.read
    other.close
    friend = start("--join", "127.0.0.1:#{port}", "--no-window", "--pictures", "40")

    friend.finish
    hosting.finish

    assert_match(/This match is for the Game Boy Advance, and your game is built for the Game Boy Color/, refused)
  end

  def test_options_that_do_not_belong_together_are_refused_before_anything_is_built
    {
      ["--host", "--join", "127.0.0.1"] => /--host and --join do not go together/,
      ["--players", "3"] => /--players is for the computer that hosts/,
      ["--join", "somewhere", "--tape", "x.tape"] => /does nothing in a match/,
      ["--host", "--no-window"] => /needs --pictures/,
      ["--keys", "right"] => /--keys is for a match with no window/,
      ["--join", "no:such:address"] => nil
    }.each do |args, says|
      out, status = Open3.capture2e(RUBY, BIN, "run", GAME, *args)

      refute_predicate status, :success?, args.inspect
      assert_match(says, out, args.inspect) if says
      refute_match(/\.rb:\d+:in/, out, "no backtrace for #{args.inspect}")
    end
  end
end
