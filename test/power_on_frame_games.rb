# frozen_string_literal: true

require "all/vblank/builder/test_frames_since_power_on"

# `frames_since_power_on` ON A CARTRIDGE, read back in its console's emulator, for each console's test
# that the cartridge counts the frames it spends setting up: the Advance's, the Super Nintendo's, the
# Genesis's and the PlayStation's. What every run reads is in
# test/all/vblank/builder/test_frames_since_power_on.rb.
#
# The answer key is the emulator's own count of frames from power-on. A screen held until the reading
# reaches a number changes on the same emulator frame however long the cartridge took to set up: it
# spun first, or started a song, whose recordings are sent to the sound chip before the game's first
# line.
module PowerOnFrameGames
  include FramesSincePowerOnGames

  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  # The cartridge of +program+ for +console+, as a test that plays a cartridge builds it.
  private def power_on_cartridge(console, program)
    VBlank::Console.for(console).builder.cartridge_for(program, title: "POWERON")
  end

  # THE ONE THAT MATTERS. On the console, setting up takes frames, and the reading counts them: the
  # first pass's change is first seen on frame F, so it ran after F - 1 frames had been shown, and
  # that is what it read. Spinning before the loop makes setting up take several. Answers that
  # frame and that reading, for +program+ built for +console+.
  private def first_pass_frame_and_reading(console, program)
    rom = power_on_cartridge(console, program)
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 1, vars: rom.var_addresses)
    frame = 1
    until reader.var(:passes).positive?
      flunk "no pass ran in 60 frames" if frame == 60
      reader.step
      frame += 1
    end
    [frame, reader.var(:first)]
  end

  # The frame the first pass is seen on and its reading, for the counting game set up at once and
  # after spinning +busy+ times: each reads one fewer than the frame it is seen on.
  private def assert_frames_setting_up_counted(console, busy:)
    quick_frame, quick = first_pass_frame_and_reading(console, counting_game(0))
    slow_frame, slow = first_pass_frame_and_reading(console, counting_game(busy))

    assert_equal quick_frame - 1, quick, "a game that sets up at once reads the frames before its first pass"
    assert_operator slow_frame, :>, quick_frame, "spinning first should make setting up take longer"
    assert_equal slow_frame - 1, slow, "and the frames spent setting up are counted"
  end

  # The emulator frame each build of the screen-waiting game first shows green on, by name: no song,
  # a song with a recorded part, a long wait before the loop, and both. +hold+ is the reading the
  # screen waits for, and +busy+ how long the wait spins. +songs_in_every_build+ puts the song in the
  # builds that do not play it too, so every build is as long (PS1's tests say why).
  private def green_frames(console, hold:, busy:, songs_in_every_build: false)
    builds = {
      "no song" => { song: false, busy: 0 },
      "a song with a recorded part" => { song: true, busy: 0 },
      "a long wait before the loop" => { song: false, busy: busy },
      "a song and a long wait before the loop" => { song: true, busy: busy },
    }
    builds.transform_values do |settings|
      program = screen_waiting_game(hold: hold, songs_kept: songs_in_every_build, **settings)
      first_green_frame(console, program, hold)
    end
  end

  # A bitmap screen, red until frames_since_power_on reaches +hold+, then a green square in its
  # middle: the pass that reads it paints the square, and the frame that shows the pass shows it.
  # +song+ plays a song with a recorded part from the start, and +songs_kept+ has the song without
  # playing it. +quick_lines+ keeps a routine that long in the quick memory, and +busy+ spins before
  # the loop.
  private def screen_waiting_game(hold:, song: false, songs_kept: false, quick_lines: 0, busy: 0)
    notes = [Note.new(at: 0, key: :C4), Note.new(at: 10, key: :E4)]
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      if song || songs_kept
        enable_sound
        instrument :piano, pcm: [60, -60] * 400, rate: 8000, note: :C4
        tunes = songs(:music, [Score.new(tempo: 150, parts: [Part.new(notes: notes), Part.new(plays: :piano, notes: notes)])])
        tunes.play(0) if song
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
        fill_rect 112, 72, 16, 16, :green if frames_since_power_on >= hold
      end
    end
    b.finalize_program
    b.program
  end

  # The emulator frame, counted from power-on, on which the screen first shows green.
  private def first_green_frame(console, program, hold)
    reader = VBlank::Diagnostics::Verifier.new(power_on_cartridge(console, program), frames: 1)
    (1..(hold * 3)).each do |frame|
      return frame if reader.green?(120, 80)

      reader.step
    end
    flunk "the screen never turned green"
  end
end
