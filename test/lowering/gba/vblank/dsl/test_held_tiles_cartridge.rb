# frozen_string_literal: true

require "test_helper"
require "differential"
require "all/vblank/dsl/test_held_tiles"

# A held background on the Advance's cartridge, read off the emulator's picture frame by frame.
# What `held: true` means, and the same games on every run, is in
# test/all/vblank/dsl/test_held_tiles.rb.
#
# The pass first spends most of a frame counting, so its 240 cells are written while the display
# is drawing the box. Written where the game says, part of the box then shows the new size and part
# the old. Held, every frame shows the whole of one size: the size of the pass before.
class TestHeldTilesCartridge < Minitest::Test
  include HeldTilesGames
  include Differential

  # Counting passes that put the writes well down the frame on the console.
  BUSY = 12_000
  FRAMES = 10

  def test_a_busy_pass_held_shows_every_frame_whole_and_a_frame_behind
    readings(growing_box_game(held: true, busy: BUSY, rows: ROWS)).each do |size, rows|
      rows.each_with_index do |count, row|
        assert_equal size - 1, count, "pass #{size}, row #{row}: the box shows the size of the pass before"
      end
    end
  end

  # The same game not held is the failure this exists for: it proves the pass is late enough that
  # the writes land while the display draws the box.
  def test_the_same_busy_pass_not_held_shows_part_of_two_sizes
    torn = readings(growing_box_game(held: false, busy: BUSY, rows: ROWS)).count { |_, rows| rows.uniq.length > 1 }
    assert_operator torn, :>, 0, "some frame shows two sizes of the box at once"
  end

  # A scene putting its own background up keeps the change waiting for the box every screen shows.
  def test_a_scene_taking_over_keeps_a_held_change_to_another_background
    rom = VBlank.build("HELDSCENE", console: :gba, validate: false, out: nil, err: nil, &scene_change_game)
    verifier = assert_emulator_loads_rom(rom, frames: 1, vars: rom.var_addresses)
    shown = Array.new(FRAMES) do
      reading = [verifier.var(:frames), verifier.pixel_is?((3 * 8) + 4, (1 * 8) + 4, :blue)]
      verifier.step
      reading
    end
    shown.each { |frames, open| assert_equal frames - 1 >= OPEN_AT, open, "pass #{frames}: the cell shows open: #{open}" }
    assert(shown.any? { |_, open| open }, "the cell opened in the end")
  end

  # A painted scene arriving in the pass a held cell changed shows its picture clean: the change
  # waiting for the room it replaces is forgotten, as the interpreter forgets it. The picture is
  # painted once and then stands still, so any frame well after the change will do.
  def test_a_painted_scene_taking_over_forgets_the_held_changes
    assert_backends_agree(tree_of(painted_scene_game), frames: OPEN_AT + 4, console_frames: OPEN_AT + 6,
                                                       name: "HELDPAINT")
  end

  # A FRAME THAT WRITES 240 CELLS STILL FITS. The writes are in the gap between frames, which is
  # about a third of the frame; asserting under a tenth of the frame leaves the gap room for the
  # sprites, scroll and maps a game writes there too.
  def test_writing_240_held_cells_fits_well_inside_the_gap
    rom = VBlank.build("HELDCOST", console: :gba, validate: false, out: nil, err: nil, &growing_box_game(rows: ROWS))
    result = VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false)
    assert_in_delta 60.0, result.fps, 0.01, "the game keeps every frame"
    writing = result.lines.find { |line| line.name == :__show_held_tiles }
    refute_nil writing, "the profile names the routine that writes the held cells"
    share = writing.time_share / 100.0 * (1 - result.idle_share)
    assert_operator share, :<, 0.1, "writing 240 cells takes #{(share * 100).round(1)}% of a frame"
  end

  private

  # For each of FRAMES frames: the pass number, and how many blue cells each row of the box shows.
  def readings(source)
    rom = VBlank.build("HELDTILES", console: :gba, validate: false, out: nil, err: nil, &source)
    verifier = assert_emulator_loads_rom(rom, frames: 3, vars: rom.var_addresses)
    Array.new(FRAMES) do
      rows = (0...ROWS).map { |row| (0...COLS).count { |col| verifier.pixel_is?((col * 8) + 4, (row * 8) + 4, :blue) } }
      reading = [verifier.var(:size), rows]
      verifier.step
      reading
    end
  end
end
