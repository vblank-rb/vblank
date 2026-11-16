# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require "shell_tests"
require "all/vblank/builder/test_pack_tile_poses"
require "all/vblank/dsl/test_pack_background_set_cell"

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

  # A shell's unpacking plays in a Ractor, whose stack is small (ShellTests#long_routine_port).
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

  # A Color port whose ball's poses are pieces of a set of sprite tiles read from the original's
  # frames (PackTilePoseGames): the shell writes the frames' pieces in as it starts.
  def test_a_port_whose_tile_poses_are_frames_of_the_pack_passes_every_step
    Dir.mktmpdir do |folder|
      said = []
      made = PackTilePoseGames.ball_game(PackTilePoseGames.original_in(folder)) do |pack, at|
        PackTilePoseGames.frame_pose(pack, at, size: PackTilePoseGames::SIZE)
      end
      check(VBlank.game("MADE UP", consoles: %i[gbc], &made), said)

      assert_match "plays as its all-in-one build does", said.last
    end
  end

  # A Color port whose screen is told the cells it changes to by a slot its unpacking fills
  # (PackBackgroundSetCellGames' map-cells original), writing them by place as it plays: the shell
  # paints the told cells from the file as it starts.
  def test_a_port_whose_cells_are_told_by_a_slot_of_the_pack_passes_every_step
    Dir.mktmpdir do |folder|
      said = []
      check(cells_told_by_a_slot_port(folder), said)

      assert_match "plays as its all-in-one build does", said.last
    end
  end

  private def cells_told_by_a_slot_port(folder)
    games = PackBackgroundSetCellGames
    from = games.map_cells_original_in(folder, :gbc)
    cells = games::MAP_TILES.flatten.length
    VBlank.game("MADE UP", consoles: %i[gbc]) do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: games::TILES_AT, count: games::MAP_CELLS_VIDEO.length
        slots.colors :palette, at: games::COLORS_AT, count: games::MAP_CELLS_PALETTE.length
        slots.map_cells :map, count: cells
        slots.map_cells :changes, count: 3
        slots.fill_from_copy do |copy, filled|
          repeat(cells) { |at| filled[:map].write_cell(at, tile: copy.byte(games::MAP_CELLS_TILE_MAP_AT + at)) }
          3.times { |at| filled[:changes].write_cell(at, tile: games::MAP_CELLS_BANK_TILES + at, bank: 1) }
        end
      end
      world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 4, set_cells: pack[:changes]
      place = var :place, 0
      game_loop do
        world.set_cell place, 1, place
        place += 1
        place.store!(0) if place >= 3
      end
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
