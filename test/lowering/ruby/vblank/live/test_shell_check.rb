# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require "shell_tests"

# THE CHECK EVERY PORT RUNS ON ITS SHELL (Live::ShellCheck), on the made-up port the shell tests
# share. The answer key is the port's all-in-one build: its pack, and its play over the tape.
# On the Ruby run alone: the check plays the shell as Ruby whatever run it is in, so another run
# would play the same thing again.
class TestShellCheck < Minitest::Test
  include ShellTests

  ShellCheck = VBlank::Live::ShellCheck

  private def check(game, said = [], tape: nil) = ShellCheck.new(game, tape: tape, say: ->(line) { said << line }).run

  def test_a_port_whose_shell_plays_as_its_all_in_one_build_passes_every_step
    Dir.mktmpdir do |folder|
      said = []
      check(port(original(folder)), said)

      assert_match "plays as its all-in-one build does", said.last
    end
  end

  def test_the_check_plays_the_presses_of_a_tape
    Dir.mktmpdir do |folder|
      tape = VBlank::Playthroughs::Tape.parse("vblank tape 1\nrecorded on: MADE UP 0x00000000\nstarts from: power-on\n\n" \
                                              "5 -\n20 right a\n")
      said = []
      check(port(original(folder)), said, tape: tape)

      assert_match "Playing 25 passes", said.join("\n")
    end
  end

  # A port whose code reads its data from another place when no copy is in reach, as a shell is
  # built: the pack the shell makes is not the all-in-one build's.
  def test_a_shell_whose_pack_differs_from_the_all_in_one_builds_fails_naming_the_first_byte
    Dir.mktmpdir do |folder|
      from = original(folder)
      game = VBlank.game("MADE UP", consoles: %i[gba]) do
        data_pack(from: from, version: "1") do |slots|
          slots.colors :palette, at: from.copy_if_set ? PALETTE_AT : PALETTE_AT + 2, count: 16
        end
        game_loop { wait_vblank }
      end
      failed = assert_raises(ShellCheck::Failed) { check(game) }

      assert_match "not the all-in-one build's pack", failed.message
      assert_match "first at byte", failed.message
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
    refused = assert_raises(ArgumentError) { ShellCheck.new(port_without_copy(Dir.tmpdir), tape: tape) }

    assert_match "from power-on", refused.message
  end
end
