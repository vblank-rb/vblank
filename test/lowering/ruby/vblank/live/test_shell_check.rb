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

  # A shell's unpacking plays in a Ractor, whose stack is small. LONG_ROUTINE_COPIES frame copies
  # written out, each a word read whose answer places a byte read, a test and a slot write, and
  # every eighth a copy of bytes, are thousands of statements, and a loop of copy reads ends it.
  LONG_ROUTINE_COPIES = 500

  private def long_routine_port(from)
    VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      clear_screen :black
      pack = data_pack(from: from, version: "1") do |slots|
        slots.numbers :frames, count: 64, width: :byte, signed: false
        slots.fill_from_copy do |copy, into|
          LONG_ROUTINE_COPIES.times do |n|
            at = copy.word(0x10 + ((n * 4) % 0x100))
            count = copy.byte((at & 0xFF) + (n % 64))
            count = 12 if count > 12
            into[:frames][n % 64] = count
            copy.copy_bytes at: TILES_AT, count: 4, into: into[:frames], start: n % 60 if (n % 8).zero?
          end
          repeat(4) { |k| copy.copy_bytes at: copy.byte(k) & 0xFF, count: 4, into: into[:frames], start: k * 4 }
        end
      end
      frames = table :frames, pack[:frames]
      step = var :step, 0
      game_loop do
        draw_rect_at frames[step] * 4, 40, 4, 4, :white
        step = (step + 1) & 63
      end
    end
  end

  def test_a_port_whose_unpacking_routine_is_long_passes_every_step
    Dir.mktmpdir do |folder|
      said = []
      check(long_routine_port(original(folder)), said)

      assert_match "plays as its all-in-one build does", said.last
    end
  end

  # A pack bigger than the Color's 8K of work memory: the unpacking keeps the whole pack in one list
  # as it writes it, so a cartridge could never hold it. The unpacking runs only on a computer.
  BIG_PACK_BYTES = 9_000
  BIG_PACK_PIECE = 500

  private def color_port_of_big_pack(from)
    VBlank.game("MADE UP", consoles: %i[gbc]) do
      screen :bitmap
      clear_screen :black
      pack = data_pack(from: from, version: "1") do |slots|
        slots.numbers :big, count: BIG_PACK_BYTES, width: :byte, signed: false
        slots.fill_from_copy do |copy, into|
          (BIG_PACK_BYTES / BIG_PACK_PIECE).times do |n|
            copy.copy_bytes at: 0, count: BIG_PACK_PIECE, into: into[:big], start: n * BIG_PACK_PIECE
          end
        end
      end
      big = table :big, pack[:big]
      step = var :step, 0
      game_loop do
        draw_rect_at big[step] & 127, 40, 4, 4, :white
        step = (step + 1) & 63
      end
    end
  end

  def test_a_color_port_whose_pack_is_more_than_the_colors_work_memory_passes_every_step
    Dir.mktmpdir do |folder|
      said = []
      check(color_port_of_big_pack(original(folder)), said)

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
