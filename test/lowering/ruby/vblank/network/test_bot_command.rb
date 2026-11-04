# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"
require "English"

# `vblank bot BOT_FILE` AS A PROGRAM: a bot joins a match with a person (here a `vblank run` with no window,
# holding a key) through an address and through the stand-in relay, and what it says when it cannot. The bot is
# examples/chaser_bot.rb. The bot's own reading of the game, and what it does about it, is test_bots.rb.
class TestBotCommand < Minitest::Test
  RUBY = RbConfig.ruby.freeze
  BIN = VBlank.root.join("bin/vblank").to_s
  RELAY = VBlank.root.join("tools/stand_in_relay.rb").to_s
  BOT = VBlank.root.join("examples/chaser_bot.rb").to_s
  GAME = VBlank.root.join("examples/wanderers.rb").to_s

  # A fuse so that a test that would wait for ever stops: nothing in a run depends on it.
  FUSE_SECONDS = 120

  Running = Struct.new(:io, :lines, :pid) do
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

  private def start(*command)
    io = IO.popen([RUBY, *command, { err: %i[child out] }])
    Running.new(io, [], io.pid)
  end

  def test_a_bot_hosts_and_a_person_joins_and_they_agree_on_every_checkpoint
    hosting = start(BIN, "bot", BOT, "--host", "0", "--pictures", "100")
    port = hosting.read_until(/on port (\d+)/)[/on port (\d+)/, 1]
    person = start(BIN, "run", GAME, "--join", "127.0.0.1:#{port}", "--no-window", "--pictures", "100", "--keys", "up")

    joined = person.finish
    hosted = hosting.finish

    assert_predicate joined, :success?, person.lines.join
    assert_predicate hosted, :success?, hosting.lines.join
    assert_match(/agreed on every checkpoint/, hosting.lines.join)
    assert_match(/You are player 1/, hosting.lines.join)
  end

  def test_a_bot_joins_through_the_relay_and_a_person_hosts
    relay = start(RELAY)
    url = relay.read_until(/listening on/)[%r{ws://\S+}]
    hosting = start(BIN, "run", GAME, "--relay", url, "--host", "--no-window", "--pictures", "100", "--keys", "up")
    code = hosting.read_until(/--relay --join (\w+)/)[/--join (\w+)/, 1]
    bot = start(BIN, "bot", BOT, "--relay", url, "--join", code, "--pictures", "100")

    assert_predicate bot.finish, :success?, bot.lines.join
    assert_predicate hosting.finish, :success?, hosting.lines.join
    assert_match(/You are player 2/, bot.lines.join)
  ensure
    relay&.stop
  end

  # A tape a match kept, played back by one bot for each of its two players.
  def test_bots_that_play_a_tape_make_the_match_it_was_made_of
    Dir.mktmpdir do |dir|
      tape = File.join(dir, "match.tape")
      File.write(tape, "vblank tape 1\nrecorded on: WANDERERS 0x00000001\nstarts from: power-on\ncounts: passes\n\n3 -\n30 right p2_left\n")
      hosting = start(BIN, "bot", tape, "--game", GAME, "--host", "0", "--tape-player", "1", "--pictures", "40")
      port = hosting.read_until(/on port (\d+)/)[/on port (\d+)/, 1]
      joining = start(BIN, "bot", tape, "--game", GAME, "--join", "127.0.0.1:#{port}", "--tape-player", "2", "--pictures", "40")

      assert_predicate joining.finish, :success?, joining.lines.join
      assert_predicate hosting.finish, :success?, hosting.lines.join
      assert_match(/agreed on every checkpoint/, hosting.lines.join)
    end
  end

  def test_a_tape_with_no_game_is_told_to_give_one
    Dir.mktmpdir do |dir|
      tape = File.join(dir, "match.tape")
      File.write(tape, "vblank tape 1\nrecorded on: WANDERERS 0x00000001\nstarts from: power-on\ncounts: passes\n\n3 -\n")
      out, status = Open3.capture2e(RUBY, BIN, "bot", tape, "--join", "127.0.0.1:1")

      refute_predicate status, :success?
      assert_match(/A tape does not say which game it is for/, out)
    end
  end

  def test_a_bot_with_no_match_to_join_is_told_to_make_one
    out, status = Open3.capture2e(RUBY, BIN, "bot", BOT)

    refute_predicate status, :success?
    assert_match(/A bot plays in a match/, out)
    assert_match(/--join ADDRESS/, out)
  end

  def test_a_file_that_says_no_bot_or_no_game_is_said_in_plain_words
    Dir.mktmpdir do |dir|
      none = File.join(dir, "none.rb")
      File.write(none, "# nothing here\n")
      lost = File.join(dir, "lost.rb")
      File.write(lost, "VBlank.bot(\"lost\") { |_game| [] }\n")
      {
        none => [/says 0 bots/, ["--join", "127.0.0.1:1"]],
        lost => [/does not say which game it plays/, ["--join", "127.0.0.1:1"]],
        File.join(dir, "missing.rb") => [/cannot find the bot file/, ["--join", "127.0.0.1:1"]]
      }.each do |file, (says, args)|
        out, status = Open3.capture2e(RUBY, BIN, "bot", file, *args)

        refute_predicate status, :success?, file
        assert_match(says, out, file)
        refute_match(/\.rb:\d+:in/, out, "no backtrace for #{file}")
      end
    end
  end
end
