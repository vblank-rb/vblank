# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "timeout"
require "English"

# `vblank run GAME --relay --host` AND `--relay --join CODE` THROUGH THE STAND-IN RELAY, which runs as a
# program of its own (tools/stand_in_relay.rb) so the three are three processes, as they would be with a
# person at each of two computers and the real relay between them.
class TestRelayPlayCommand < Minitest::Test
  RUBY = RbConfig.ruby.freeze
  BIN = VBlank.root.join("bin/vblank").to_s
  RELAY = VBlank.root.join("tools/stand_in_relay.rb").to_s
  GAME = VBlank.root.join("examples/wanderers.rb").to_s

  # A fuse so that a test that would wait for ever stops: nothing in a run depends on it.
  FUSE_SECONDS = 120

  Process_ = Struct.new(:io, :lines, :pid) do
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

    def stop
      Process.kill("TERM", pid)
      io.close
    rescue Errno::ESRCH
      nil
    end
  end

  private def start(*command, env: {})
    io = IO.popen(env, [RUBY, *command, { err: %i[child out] }])
    Process_.new(io, [], io.pid)
  end

  private def with_relay
    relay = start(RELAY)
    url = relay.read_until(/listening on/)[%r{ws://\S+}]
    yield url
  ensure
    relay&.stop
  end

  private def vblank(*args) = start(BIN, "run", GAME, *args)

  def test_two_processes_meet_through_the_relay_with_a_code_and_agree
    with_relay do |url|
      hosting = vblank("--relay", url, "--host", "--no-window", "--pictures", "80", "--keys", "right")
      code = hosting.read_until(/--relay --join (\w+)/)[/--join (\w+)/, 1]
      joining = vblank("--relay", url, "--join", code, "--no-window", "--pictures", "80", "--keys", "left")

      joined = joining.finish
      hosted = hosting.finish

      assert_predicate joined, :success?, joining.lines.join
      assert_predicate hosted, :success?, hosting.lines.join
      [hosting, joining].each { |run| assert_match(/agreed on every checkpoint/, run.lines.join) }
      assert_match(/You are player 2/, joining.lines.join)
    end
  end

  def test_the_relays_address_can_come_from_the_environment
    with_relay do |url|
      hosting = start(BIN, "run", GAME, "--relay", "--host", "--no-window", "--pictures", "40", env: { "VBLANK_RELAY_URL" => url })
      code = hosting.read_until(/--relay --join (\w+)/)[/--join (\w+)/, 1]
      joining = start(BIN, "run", GAME, "--relay", "--join", code, "--no-window", "--pictures", "40", env: { "VBLANK_RELAY_URL" => url })

      assert_predicate joining.finish, :success?, joining.lines.join
      assert_predicate hosting.finish, :success?, hosting.lines.join
    end
  end

  def test_a_wrong_code_is_said_in_plain_words
    with_relay do |url|
      joining = vblank("--relay", url, "--join", "ZZZZ", "--no-window", "--pictures", "5")

      refute_predicate joining.finish, :success?
      assert_match(/There is no room with the code ZZZZ/, joining.lines.join)
      refute_match(/\.rb:\d+:in/, joining.lines.join)
    end
  end

  def test_no_relay_address_is_said_in_plain_words
    out, status = Open3.capture2e({ "VBLANK_RELAY_URL" => nil }, RUBY, BIN, "run", GAME, "--relay", "--join", "AAAA", "--no-window", "--pictures", "5")

    refute_predicate status, :success?
    assert_match(/No relay address is set/, out)
    assert_match(/VBLANK_RELAY_URL/, out)
  end

  def test_a_relay_with_nobody_at_its_address_is_said_in_plain_words
    unused = TCPServer.new("127.0.0.1", 0)
    port = unused.addr[1]
    unused.close

    out, status = Open3.capture2e(RUBY, BIN, "run", GAME, "--relay", "ws://127.0.0.1:#{port}/", "--join", "AAAA", "--no-window", "--pictures", "5")

    refute_predicate status, :success?
    assert_match(/Nobody answers at the relay address/, out)
  end

  # With --relay, --host makes a room and listens on no port, so what follows it is not checked as one.
  def test_a_relay_host_is_not_held_to_a_port
    unused = TCPServer.new("127.0.0.1", 0)
    port = unused.addr[1]
    unused.close

    out, status = Open3.capture2e(RUBY, BIN, "run", GAME, "--relay", "ws://127.0.0.1:#{port}/", "--host", "70000", "--no-window", "--pictures", "5")

    refute_predicate status, :success?
    refute_match(/is not a port/, out)
    assert_match(/Nobody answers at the relay address/, out)
  end

  def test_relay_with_no_host_or_join_is_refused
    out, status = Open3.capture2e(RUBY, BIN, "run", GAME, "--relay", "ws://x/")

    refute_predicate status, :success?
    assert_match(/--relay is for a match through a relay/, out)
  end
end
