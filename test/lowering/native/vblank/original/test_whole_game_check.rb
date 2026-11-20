# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require "shell_tests"

# THE WHOLE GAME, THE SHELL'S AGAINST THE ALL-IN-ONE BUILD'S, AS C (Original::WholeGameCheck), on
# the made-up port the shell tests share. The answer key is the all-in-one build: its pack, and its
# play over the whole tape. On the native run alone: the check builds both as C whatever run it is
# in.
class TestWholeGameCheck < Minitest::Test
  # One test makes the windowless run of a game as C stop as no StandardError does, for the whole process.
  runs_on_the_main_ractor!

  include ShellTests

  WholeGameCheck = VBlank::Original::WholeGameCheck

  # Set in the environment while a test wants every windowless run as C to stop as it starts.
  STOP_SETTING = "VBLANK_TEST_WHOLE_GAME_PLAY_STOPS"

  # A windowless run of a game as C that, while STOP_SETTING is set, stops with an error that is
  # not a StandardError, as a run that runs out of memory or meets a Ruby fault does.
  module StopsAsItStarts
    # The interpreter's words written out, since every player is held to them (TestSuitesSplit) and
    # a prepended (...) would hide them for the rest of the process.
    def run(program, max_steps: nil, frames: nil)
      raise NotImplementedError, "made-up stop of the play" if ENV.key?(TestWholeGameCheck::STOP_SETTING)

      super
    end
  end
  VBlank::IR::Backends::Native::HeadlessRun.prepend(StopsAsItStarts)

  # Past the shell check's stretch (Live::ShellCheck::STRETCH_PASSES), where only this check looks.
  LATE_PASS = 400
  TAPE_PASSES = 500

  TAPE = VBlank::Playthroughs::Tape.parse("vblank tape 1\nrecorded on: MADE UP 0x00000000\nstarts from: power-on\n\n" \
                                          "#{TAPE_PASSES / 2} -\n#{TAPE_PASSES / 2} right a\n")

  private def check(game, said = [], tape: TAPE) = WholeGameCheck.new(game, tape: tape, say: ->(line) { said << line }).run

  def test_a_port_whose_shell_plays_as_its_all_in_one_build_passes
    Dir.mktmpdir do |folder|
      said = []
      check(port(original(folder)), said)

      assert_match "plays the whole tape as its all-in-one build does", said.last
      assert_match "#{TAPE_PASSES} passes", said.join("\n")
    end
  end

  # A port whose game takes another way as it is built when no copy is in reach (as a shell is
  # built), seen only on LATE_PASS: past the stretch the shell check plays, so that check passes
  # it, and this one names the pass.
  private def late_difference_port(from)
    VBlank.game("MADE UP", consoles: %i[gba]) do
      late = from.copy_if_set ? :white : :red
      screen :bitmap
      data_pack(from: from, version: "1") { |slots| slots.colors :palette, at: PALETTE_AT, count: 16 }
      step = var :step, 0
      game_loop do
        clear_screen :black
        step += 1
        draw_rect_at 10, 10, 4, 4, late if step >= LATE_PASS
      end
    end
  end

  def test_a_difference_past_the_shell_checks_stretch_fails_naming_its_pass
    Dir.mktmpdir do |folder|
      game = late_difference_port(original(folder))
      VBlank::Live::ShellCheck.new(game, tape: TAPE, say: ->(_line) {}).run
      failed = assert_raises(WholeGameCheck::Failed) { check(game) }

      assert_match "different picture", failed.message
      assert_match "after pass #{LATE_PASS},", failed.message
    end
  end

  # The same, heard: a beep on LATE_PASS at another pitch, the picture alike throughout.
  private def late_sound_port(from)
    VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      enable_sound
      define_sound :late, frequency: from.copy_if_set ? 440 : 880
      data_pack(from: from, version: "1") { |slots| slots.colors :palette, at: PALETTE_AT, count: 16 }
      step = var :step, 0
      game_loop do
        clear_screen :black
        step += 1
        beep :late if step == LATE_PASS
      end
    end
  end

  def test_a_sound_heard_differently_past_the_shell_checks_stretch_fails_naming_its_pass
    Dir.mktmpdir do |folder|
      failed = assert_raises(WholeGameCheck::Failed) { check(late_sound_port(original(folder))) }

      assert_match "sounds different", failed.message
      assert_match(/after pass 40\d\b/, failed.message)
    end
  end

  # A play that stops with an error of any kind is raised as itself, and the comparison waiting on
  # its passes does not wait for ever.
  def test_a_play_that_stops_with_any_error_raises_it
    Dir.mktmpdir do |folder|
      game = port(original(folder))
      ENV[STOP_SETTING] = "1"
      stopped = assert_raises(NotImplementedError) { check(game) }

      assert_match "made-up stop", stopped.message
    ensure
      ENV.delete(STOP_SETTING)
    end
  end

  def test_a_machine_that_names_no_copy_stops_saying_how_to_name_one
    Dir.mktmpdir do |folder|
      not_set = assert_raises(VBlank::Original::NotSet) { check(port_without_copy(folder)) }

      assert_match "MADE_UP_ROM", not_set.message
    end
  end

  def test_a_tape_recorded_after_a_lead_in_is_refused
    tape = VBlank::Playthroughs::Tape.parse("vblank tape 1\nrecorded on: MADE UP 0x00000000\n" \
                                            "starts from: power-on after a lead-in\n\n5 -\n")
    refused = assert_raises(ArgumentError) { WholeGameCheck.new(port_without_copy(Dir.tmpdir), tape: tape) }

    assert_match "from power-on", refused.message
  end
end
