# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# The gap between frames belongs to the picture. It is the only time the sprite table can be
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

  # A gap that runs past the blank, and a mix waiting at the first line. The sprite table must be
  # written while nothing is drawn (GBATEK, OAM), so a gap that runs a few rows into the picture
  # tears those rows already; a mix that cuts in at the first line would hold the rest of the
  # table off for as long as the mix lasts, and tear most of the picture. So the table's last
  # write lands as far into the picture on a frame the recordings sound as on a quiet one.
  #
  # The gap is made long by the game itself: a body run in it waits for the display to reach
  # +late_line+, wherever the lowering's own work in the gap ended, and the sprite table is
  # written after it.
  THINGS = 64

  # +sound_starts+ is the pass the recordings start on; the passes before it are quiet.
  # +waiting_beat+ adds a timer whose handler waits a frame, four times a second: it runs as the
  # game wakes, so its own gap comes inside the frame's, and the frame's gap writes go on after it.
  private def gap_past_the_blank(sound_starts:, late_line:, waiting_beat: false)
    builder = Builder.new
    builder.extend(VBlank::Builder::Debug) # read_scanline
    builder.instance_eval do
      screen :tiled
      image(:dot, "#" => :yellow) { (["#" * 8] * 8).join("\n") }
      things = pool :thing, x: 0, y: 0, capacity: THINGS, facing: { still: :dot }
      THINGS.times { |n| things.spawn(x: (n * 13) % 230, y: (n * 7) % 150) }
      if waiting_beat
        marker = sprite :marker, at: [0, 150], facing: { still: :dot }
        steps = 0
        beat = timer :beat, per_second: 4
        beat.on_tick do
          wait_vblank
          steps += 1
          marker.move_to steps % 200, 150 # so the frame's own table has a row to write
        end
      end
      pcm = Array.new(4096) { |i| ((i * 7) % 200) - 100 }
      clips = Array.new(VOICES) { |n| sample :"clip#{n}", pcm: pcm, rate: 32_768 }
      passes = 0
      waited = 0
      # The lines of the blank counted from its first, 0 to 67, and the picture's after them.
      once_a_frame do
        waited += 1 while ((read_scanline + 68) % 228) < late_line - 160
      end
      game_loop do
        passes += 1
        clips.each { |clip| clip.play(loop: true) } if passes == sound_starts
        things.each { |thing| thing.x = (thing.x + 1) % 230 }
      end
    end
    builder.finalize_program
    assemble_rom(builder.program, name: "LATE")
  end

  def test_the_sprite_table_is_written_before_the_mix_cuts_in
    game = gap_past_the_blank(sound_starts: 10, late_line: 226)
    assert_table_written_as_on_quiet_frames(game, sound_starts: 10, frames: 24)
  end

  # A handler's gap ends inside the frame's: the frame's own writes still come before the mix. The
  # quiet frames take in two of the handler's, and so do the loud ones. The handler's gap and the
  # frame's run on after each other, so the wait ends earlier, and the frame's writes still end
  # before the mix's last line (Mixer::MIX_LATEST_LINE).
  def test_a_handler_that_waits_leaves_the_frame_its_gap
    game = gap_past_the_blank(sound_starts: 40, late_line: 200, waiting_beat: true)
    assert_table_written_as_on_quiet_frames(game, sound_starts: 40, frames: 80)
  end

  # The last row each frame's writes to the sprite table landed on is no further into the picture
  # once the recordings sound than on the quiet frames before them. A pass that took two frames
  # starts the sound a frame or two after its pass number, so the loud frames start a little later.
  # Rows are counted from the blank's first (160 is 0), the picture's rows after its 68.
  private def assert_table_written_as_on_quiet_frames(rom, sound_starts:, frames:)
    rows = sprite_table_rows_by_frame(rom, frames: frames)
    last_rows = rows.map { |frame| frame.map { |row| (row + 68) % 228 }.max }
    quiet = last_rows[4...sound_starts].compact
    loud = last_rows[(sound_starts + 6)..].compact

    assert_operator quiet.max, :>, 68, "the gap must reach past the blank, or this tests nothing: #{last_rows}"
    assert_operator quiet.max, :<, 68 + GBA::Mixer::MIX_LATEST_LINE, "...and end before the mix's last line: #{last_rows}"
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
