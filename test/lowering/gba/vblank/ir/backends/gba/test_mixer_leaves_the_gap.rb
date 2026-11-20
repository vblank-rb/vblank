# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# THE GAP BETWEEN FRAMES BELONGS TO THE PICTURE. It is the only time the sprite table can be
# written without the screen catching it half done, and mixing a heavy song can take longer than
# the whole gap. When the sound was built there, the game's sprite writes landed after the next
# picture had started, so its top rows showed last frame's sprites. A console test only: the
# interpreter has no gap and no clock.
class TestMixerLeavesTheGap < Minitest::Test
  # A screen of 228 lines, 68 of them the gap: a frame busier than this share is busier than
  # the gap alone could hold, so the mixing cannot have fitted inside it.
  GAP_SHARE = 68.0 / 228

  # ...and the mix has to be done two thirds of a frame after it starts.
  MIX_ROOM = 160.0 / 228

  VOICES = 10

  # Looping voices at a high rate: more mixing than the gap holds, and well inside the two
  # thirds of a frame the mix has once it waits for the first line.
  def self.heavy_game
    VBlank.build("GAP", console: :gba, out: StringIO.new, err: StringIO.new, profile: false) do
      screen :tiled
      image(:top, "#" => :white) { "########\n" * 8 }
      image(:low, "#" => :white) { "########\n" * 8 }
      top = sprite :top, at: [0, 0]
      low = sprite :low, at: [0, 140]
      pcm = Array.new(4096) { |i| ((i * 7) % 200) - 100 }
      clips = Array.new(VOICES) { |n| sample :"clip#{n}", pcm: pcm, rate: 32_768 }
      x = 0
      started = 0
      game_loop do
        if started == 0
          clips.each { |clip| clip.play(loop: true) }
          started = 1
        end
        x += 2
        x = 0 if x > 200
        top.move_to x, 0
        low.move_to x, 140
      end
    end
  end

  private def white_column(verifier, row)
    (0...240).find { |col| verifier.white?(col, row) }
  end

  # Two sprites moved together, one in the top rows and one near the bottom, stand at the same
  # place in every picture.
  def test_sprites_at_the_top_move_on_the_frame_the_rest_do
    rom = self.class.heavy_game
    busy = 1 - VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false).idle_share
    assert_operator busy, :>, GAP_SHARE, "the song must be heavier than the gap, or this tests nothing"
    assert_operator busy, :<, MIX_ROOM, "the song must fit the room the mix has"

    v = VBlank::Diagnostics::Verifier.new(rom, frames: 20)
    places = Array.new(6) do
      v.step
      [white_column(v, 3), white_column(v, 143)]
    end
    refute_includes places.flatten, nil, "both sprites must be on screen: #{places.inspect}"
    places.each { |top, low| assert_equal low, top, "the top sprite is a frame behind: #{places.inspect}" }
    assert_predicate v, :sound?, "the song still plays"
  end

  # A GAP THAT RUNS PAST THE BLANK, and a mix waiting at the first line. The sprite table must be
  # written while nothing is drawn (GBATEK, OAM), so a gap that runs a few rows into the picture
  # tears those rows already; a mix that cuts in at the first line would hold the rest of the
  # table off for as long as the mix lasts, and tear most of the picture. So the table's last
  # write lands as far into the picture on a frame the recordings sound as on a quiet one.
  #
  # The gap is made long by the game itself: a body run in it waits for the display to reach
  # LATE_LINE, wherever the lowering's own work in the gap ended, and the sprite table is
  # written after it.
  LATE_LINE = 226
  SOUND_STARTS = 10 # the pass the recordings start on; the passes before it are quiet
  THINGS = 64

  private def gap_past_the_blank
    builder = Builder.new
    builder.extend(VBlank::Builder::Debug) # read_scanline
    builder.instance_eval do
      screen :tiled
      image(:dot, "#" => :yellow) { (["#" * 8] * 8).join("\n") }
      things = pool :thing, x: 0, y: 0, capacity: THINGS, facing: { still: :dot }
      THINGS.times { |n| things.spawn(x: (n * 13) % 230, y: (n * 7) % 150) }
      pcm = Array.new(4096) { |i| ((i * 7) % 200) - 100 }
      clips = Array.new(VOICES) { |n| sample :"clip#{n}", pcm: pcm, rate: 32_768 }
      passes = 0
      waited = 0
      # The lines of the blank counted from its first, 0 to 67, and the picture's after them.
      once_a_frame do
        waited += 1 while ((read_scanline + 68) % 228) < LATE_LINE - 160
      end
      game_loop do
        passes += 1
        clips.each { |clip| clip.play(loop: true) } if passes == SOUND_STARTS
        things.each { |thing| thing.x = (thing.x + 1) % 230 }
      end
    end
    builder.finalize_program
    assemble_rom(builder.program, name: "LATE")
  end

  def test_the_sprite_table_is_written_before_the_mix_cuts_in
    rows = sprite_table_rows_by_frame(gap_past_the_blank, frames: SOUND_STARTS + 12)
    last_rows = rows.map { |frame| frame.max_by { |row| row < 160 ? row + 228 : row } }
    quiet = last_rows[4...SOUND_STARTS]
    loud = last_rows[(SOUND_STARTS + 2)..]

    assert_operator quiet.max, :<, 20, "the gap must reach a few rows past the blank, or this tests nothing: #{last_rows}"
    assert_operator loud.max, :<=, quiet.max + 1, "the last row a write to the sprite table landed on, by frame: #{last_rows}"
  end

  # The rows each frame's writes to the sprite table landed on, a list a frame from power-on.
  private def sprite_table_rows_by_frame(rom, frames:)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "late.gba")
      rom.write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      begin
        probe.watch_display
        rows = Array.new(frames) do
          probe.display_writes.clear
          probe.step(1)
          probe.display_writes.select { |write| write.kind == :sprite }.map(&:row)
        end
        refute_predicate probe, :silent?, "the recordings are mixed all the same"
        rows
      ensure
        probe.close
      end
    end
  end
end
