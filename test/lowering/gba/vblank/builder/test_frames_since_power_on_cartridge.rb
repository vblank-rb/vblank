# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_frames_since_power_on"

# `frames_since_power_on` on the Advance's cartridge, read back in the emulator. What every run
# reads is in test/all/vblank/builder/test_frames_since_power_on.rb.
class TestFramesSincePowerOnCartridge < Minitest::Test
  include FramesSincePowerOnGames

  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  # The reading the screen-changing game waits for before it paints green.
  GREEN_FROM_FRAME = 10

  # THE ONE THAT MATTERS. On the console, setting up takes frames, and the reading counts them:
  # the first pass's change is first seen on frame F, so it ran after F - 1 frames had been
  # shown, and that is what it read. Spinning before the loop makes setting up take several.
  # Answers that frame and that reading.
  private def first_pass_frame_and_reading(program)
    gba = GBA.new
    v = assert_emulator_loads_rom(ROM.assemble(gba.lower(program), title: "POWERON"), frames: 1, vars: gba.var_addresses)
    frame = 1
    until v.var(:passes).positive?
      flunk "no pass ran in 20 frames" if frame == 20
      v.step
      frame += 1
    end
    [frame, v.var(:first)]
  end

  def test_the_console_counts_the_frames_spent_setting_up
    quick_frame, quick = first_pass_frame_and_reading(counting_game(0))
    slow_frame, slow = first_pass_frame_and_reading(counting_game(30_000))

    assert_equal quick_frame - 1, quick, "a game that sets up at once reads the frames before its first pass"
    assert_operator slow_frame, :>, quick_frame, "spinning first should make setting up take longer"
    assert_equal slow_frame - 1, slow, "and the frames spent setting up are counted"
  end

  # A SONG WITH A RECORDED PART starts the sound mixer at power-on, and the mixer takes most of a
  # frame to find its footing before the screen's interrupt is armed. Those frames are shown too.
  def test_the_frames_the_mixer_takes_to_start_are_counted
    frame, read = first_pass_frame_and_reading(screen_waiting_game(song: true))

    assert_equal frame - 1, read, "a game playing a recording reads the frames before its first pass"
  end

  # A screen held until a frame since power-on changes on that frame whatever the cartridge holds:
  # no song, a song played on a recording, a song beside a routine kept in the quick memory, or a
  # long wait before the game loop, with a song or without.
  def test_a_screen_held_to_a_frame_changes_on_it_with_or_without_songs
    builds = {
      "no song" => screen_waiting_game,
      "a song with a recorded part" => screen_waiting_game(song: true),
      "a song and a routine in the quick memory" => screen_waiting_game(song: true, quick_lines: 1000),
      "a long wait before the loop" => screen_waiting_game(busy: 30_000),
      "a song and a long wait before the loop" => screen_waiting_game(song: true, busy: 30_000),
    }
    changed = builds.transform_values { |program| first_green_frame(program) }

    assert_equal [GREEN_FROM_FRAME + 1], changed.values.uniq,
                 "the frame each build's screen changed on, counted from power-on: #{changed}"
  end

  # A bitmap screen, red until frames_since_power_on reaches GREEN_FROM_FRAME, then green: the pass
  # that reads it paints green, and the frame after shows it. +song+ plays a song with a recorded
  # part from the start, +quick_lines+ keeps a routine that long in the quick memory, and +busy+
  # spins before the loop.
  private def screen_waiting_game(song: false, quick_lines: 0, busy: 0)
    notes = [Note.new(at: 0, key: :C4), Note.new(at: 10, key: :E4)]
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      if song
        enable_sound
        instrument :piano, pcm: [60, -60] * 400, rate: 8000, note: :C4
        songs(:music, [Score.new(tempo: 150, parts: [Part.new(notes: notes), Part.new(plays: :piano, notes: notes)])]).play(0)
      end
      sum = 0
      func(:quick, fast: true) { quick_lines.times { |k| sum += k } } if quick_lines.positive?
      spin = 0
      repeat(busy) { spin += 1 } if busy.positive?
      first = -1
      passes = 0
      clear_screen :red
      game_loop do
        first = frames_since_power_on if passes == 0
        passes += 1
        call :quick if quick_lines.positive?
        clear_screen :green if frames_since_power_on >= GREEN_FROM_FRAME
      end
    end
    b.finalize_program
    b.program
  end

  # The emulator frame, counted from power-on, on which the screen first shows green.
  private def first_green_frame(program)
    v = assert_emulator_loads_rom(ROM.assemble(GBA.new.lower(program), title: "POWERON"), frames: 1)
    (1..(GREEN_FROM_FRAME * 3)).each do |frame|
      return frame if v.green?(120, 80)

      v.step
    end
    flunk "the screen never turned green"
  end
end
