# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# A GAME PLAYED AS RUBY IN THIS PROCESS PLAYS WITH YJIT (Live.turn_on_yjit), as `vblank run` plays
# it, wherever the process was started: the shell check and a film of a shell turn it on in a Ruby
# started without it, as a port's rake task or film script starts one. Each is played in a Ruby of
# its own, started with YJIT off, which reports whether YJIT was on once the play was over.
class TestYJIT < Minitest::Test
  # Every test starts a Ruby of its own, which hangs inside a Ractor.
  runs_on_the_main_ractor!

  # A port of the made-up original, small enough to declare here: its colours from the copy.
  PORT = <<~RUBY
    require "vblank/testing"
    require "vblank/testing/in_ractors"
    require "vblank/live"
    require "made_up_original"
    extend MadeUpOriginal
    from = original(Dir.mktmpdir)
    GAME = VBlank.game("MADE UP", consoles: %i[gba]) do
      data_pack(from: from, version: "1") { |slots| slots.colors :palette, at: MadeUpOriginal::PALETTE_AT, count: 16 }
      game_loop { wait_vblank }
    end
  RUBY

  # +play+, Ruby run after PORT, in a Ruby started with YJIT off and +env+ set: whether YJIT was on
  # after it.
  private def yjit_after(play, env: {})
    Dir.mktmpdir do |folder|
      script = File.join(folder, "play.rb")
      File.write(script, "#{PORT}\n#{play}\nputs \"yjit \#{RubyVM::YJIT.enabled?}\"\n")
      out, err, status = Open3.capture3({ "RUBY_YJIT_ENABLE" => nil, **env }, Gem.ruby, "--disable-yjit",
                                        "-I", VBlank.root.join("lib").to_s, "-I", VBlank.root.join("test").to_s, script)
      assert status.success?, "the play failed: #{err}"
      out[/^yjit (\w+)$/, 1]
    end
  end

  private def skip_without_yjit = (skip_on_this_machine("this Ruby is built without YJIT") unless defined?(RubyVM::YJIT))

  def test_the_shell_check_plays_with_yjit
    skip_without_yjit

    assert_equal "true", yjit_after("VBlank::Live::ShellCheck.new(GAME, say: ->(_line) {}).run")
  end

  def test_a_film_of_a_shell_plays_with_yjit
    skip_without_yjit

    assert_equal "true", yjit_after("VBlank::Diagnostics::FilmShell.new(GAME).open(from: :game).close")
  end

  # RUBY_YJIT_ENABLE=0 is the person asking for none, to measure the play without it.
  def test_a_play_asked_to_go_without_yjit_keeps_it_off
    skip_without_yjit

    assert_equal "false", yjit_after("VBlank::Live::ShellCheck.new(GAME, say: ->(_line) {}).run",
                                     env: { "RUBY_YJIT_ENABLE" => "0" })
  end
end
