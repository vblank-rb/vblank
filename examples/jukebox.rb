#!/usr/bin/env ruby
# frozen_string_literal: true

# Jukebox — a tiny music player with three classical tunes and a piano.
#
# The screen lists four pieces; press UP or DOWN to move the cursor, and the
# highlighted tune plays and loops on the music channel — the selection you can
# hear. A row of little blocks bobs along underneath so you can see that
# something is playing. The three melodies are written with the note/tempo DSL
# (see `song` below) — no hardware, no registers, just notes and durations.
#
# The fourth, PIANO CHORDS, is music handed over as data (a Score) and played on
# a recording, the way a game's decoded music is. Over whatever is playing, A
# plays the sound effect HOORAY and B plays BLIP, both on the same recording. The
# piano tune alternates a small chord with a big one that uses every one of the
# mixer's sixteen voices, which is where priority decides who is heard: HOORAY
# ranks above the tune, BLIP below it. R plays a clack, a recording made of numbers rather
# than read from a file. Under the heading, a clock says how long the tune has been playing.
#
# What to listen for (on PIANO CHORDS):
#   1. Press A: HOORAY plays over the tune, and the tune never stops or slips.
#   2. Press A twice quickly: HOORAY starts again from its first note.
#   3. Press A on the big chord: one of the chord's notes drops out while HOORAY
#      plays, and comes back with the tune's next big chord.
#   4. Press B on the big chord: nothing is heard, and the chord is untouched.
#      Press B on the small chord: the blip is heard.
#   5. Press A, then move the cursor: the tune fades, and HOORAY does not.
#
# SELECT stops the tune where it is and lets it go on again, which is `hold_music` and
# `release_music`: the notes sounding ring on, and it carries on from the next note with
# nothing lost. START plays a low hum under everything on the console's wave voice, a voice
# none of these tunes uses, and START again stops it with `stop_wave`.
#
# Run it to build examples/jukebox.gba:
#   ruby examples/jukebox.rb

require_relative "../lib/vblank"

module Jukebox
  # --- Layout (pixels; the screen is 240x160, origin top-left) ---
  SCREEN_W   = 240
  CLOCK_ROW  = 42
  FIRST_ROW  = 50
  ROW_GAP    = 14
  EFFECTS_ROW = 116
  HELD_ROW   = 132

  # The bobbing "it's playing" blocks along the bottom: five 8x8 blocks that
  # bounce between BAR_TOP and BAR_BOTTOM at their own speeds, so they dance a
  # little out of step. Each is [x, start_y, speed].
  BARS       = Ractor.make_shareable([[84, 124, 2], [100, 148, 3], [116, 132, 2], [132, 146, 3], [148, 128, 2]])
  BAR_TOP    = 124
  BAR_BOTTOM = 148

  # How long a tune takes to fade out when the cursor moves, and the next to fade in.
  FADE_FRAMES = 12

  # The clack R plays: a wave flipping up and down every six samples, dying away to nothing
  # over a twentieth of a second.
  CLACK_RATE = 8192
  CLACK_LENGTH = CLACK_RATE / 20
  CLACK = Ractor.make_shareable(
    (0...CLACK_LENGTH).map { |n| ((n / 6).even? ? 1 : -1) * (100 * (CLACK_LENGTH - n) / CLACK_LENGTH) }
  )

  # Each song gets an accent color, so moving the cursor recolors the screen as
  # well as changing the tune.
  SONGS = Ractor.make_shareable([
    { name: :ode_to_joy, label: "ODE TO JOY",   color: :yellow },
    { name: :fur_elise,  label: "FUR ELISE",    color: :cyan },
    { name: :minuet,     label: "MINUET IN G",  color: :magenta },
    { name: :chorale,    label: "PIANO CHORDS", color: :green },
  ])

  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  # PIANO CHORDS: two measures of C major, round and round. The first measure is a small
  # chord of four notes, the second a big one of sixteen — as many notes as the mixer has
  # voices, so while it sounds there is not one to spare. Each note is its own part, since a
  # part plays one note at a time. At 120 beats a minute a measure is 96 ticks, two seconds.
  SMALL_CHORD = Ractor.make_shareable(%i[C3 E3 G3 C4])
  BIG_CHORD = Ractor.make_shareable(SMALL_CHORD + %i[C2 G2 E4 G4 C5 D5 E5 G5 A4 B4 D4 C6])
  MEASURE = 96

  CHORALE = Ractor.make_shareable(Score.new(tempo: 120, priority: 40, length: MEASURE * 2, parts: BIG_CHORD.each_with_index.map do |key, n|
    small = n < SMALL_CHORD.size ? [Note.new(at: 0, key: key, length: MEASURE)] : []
    Part.new(plays: :piano, volume: 4, notes: small + [Note.new(at: MEASURE, key: key, length: MEASURE)])
  end))

  # The two sound effects, on the same piano. HOORAY is a rising figure ranked above the tune,
  # so it is heard even on the big chord; BLIP is two quick notes ranked below it, so on the big
  # chord there is no voice for it.
  HOORAY = Ractor.make_shareable(Score.new(tempo: 120, priority: 68, parts: [Part.new(plays: :piano, volume: 15, notes: %i[C5 E5 G5 C6].each_with_index.map do |key, n|
    Note.new(at: n * 8, key: key, length: 8)
  end)]))
  BLIP = Ractor.make_shareable(Score.new(tempo: 120, priority: 20, parts: [Part.new(plays: :piano, volume: 12, notes: [
    Note.new(at: 0, key: :G5, length: 4), Note.new(at: 4, key: :C6, length: 4),
  ])]))

  GAME = Ractor.make_shareable(VBlank.game("JUKEBOX", consoles: %i[gba]) do
    # Double-buffered so the full repaint each frame can't tear: we draw the whole
    # menu to a hidden screen and show it all at once.
    screen :bitmap, tear_free: true
    enable_sound

    # --- The three tunes, each a plain note/tempo score ---

    # Beethoven, "Ode to Joy" (Symphony No. 9) — stepwise and instantly familiar.
    # Played two-handed: the tune up top over a simple tonic/dominant (C/G) bass,
    # one whole note a measure. The two parts share the tempo and stay in step.
    song :ode_to_joy do
      tempo 100
      voice :melody do
        duty :half
        volume 12
        note :E4, :quarter; note :E4, :quarter; note :F4, :quarter; note :G4, :quarter
        note :G4, :quarter; note :F4, :quarter; note :E4, :quarter; note :D4, :quarter
        note :C4, :quarter; note :C4, :quarter; note :D4, :quarter; note :E4, :quarter
        note :E4, :dotted_quarter; note :D4, :eighth; note :D4, :half
        note :E4, :quarter; note :E4, :quarter; note :F4, :quarter; note :G4, :quarter
        note :G4, :quarter; note :F4, :quarter; note :E4, :quarter; note :D4, :quarter
        note :C4, :quarter; note :C4, :quarter; note :D4, :quarter; note :E4, :quarter
        note :D4, :dotted_quarter; note :C4, :eighth; note :C4, :half
      end
      voice :bass do
        duty :half
        volume 7
        note :C3, :whole; note :G2, :whole; note :C3, :whole; note :G2, :whole
        note :C3, :whole; note :G2, :whole; note :C3, :whole; note :C3, :whole
      end
    end

    # Beethoven, "Für Elise" — the famous rocking opening in A minor.
    song :fur_elise do
      tempo 120
      duty :quarter
      note :E5, :eighth; note :Ds5, :eighth; note :E5, :eighth; note :Ds5, :eighth
      note :E5, :eighth; note :B4, :eighth;  note :D5, :eighth; note :C5, :eighth
      note :A4, :quarter; rest :eighth
      note :C4, :eighth; note :E4, :eighth; note :A4, :eighth
      note :B4, :quarter; rest :eighth
      note :E4, :eighth; note :Gs4, :eighth; note :B4, :eighth
      note :C5, :quarter; rest :eighth
      note :E4, :eighth
      note :E5, :eighth; note :Ds5, :eighth; note :E5, :eighth; note :Ds5, :eighth
      note :E5, :eighth; note :B4, :eighth;  note :D5, :eighth; note :C5, :eighth
      note :A4, :quarter; rest :quarter
    end

    # Petzold's "Minuet in G" (long attributed to J.S. Bach) — a courtly dance.
    song :minuet do
      tempo 120
      duty :half
      note :D5, :quarter
      note :G4, :eighth; note :A4, :eighth; note :B4, :eighth; note :C5, :eighth
      note :D5, :quarter; note :G4, :quarter; note :G4, :quarter
      note :E5, :quarter
      note :C5, :eighth; note :D5, :eighth; note :E5, :eighth; note :Fs5, :eighth
      note :G5, :quarter; note :G4, :quarter; note :G4, :quarter
    end

    # --- The piano, and what plays on it ---
    #
    # One recorded note, pitched across the keyboard. The recording is shorter than a measure,
    # so it says where a held note reads back to, and a chord lasts as long as the tune holds it.
    instrument :piano, from: "assets/piano.wav", note: :C4, holds_from: 0.3
    chorale = songs :chorale, [CHORALE]
    sfx = sound_effects :sfx, { hooray: HOORAY, blip: BLIP }

    # A recording played as it was made, once through, is a `sample`, where `instrument` above
    # is a voice the tunes play their notes on. It need not come from a file: `pcm:` takes the
    # samples as numbers, -128 to 127, at `rate:` a second (CLACK, built in Ruby above).
    clack = sample :clack, pcm: CLACK, rate: CLACK_RATE

    # --- Layout the font works out ---
    #
    # The rows are a left-aligned column so the cursor lines up under itself, and the
    # column is centred on the widest song name. Ask the font how wide the names come
    # out and nothing here is a number counted by eye: reword a song and the menu
    # moves with it.
    widest  = SONGS.map { |s| text_width(s[:label]) }.max
    label_x = (SCREEN_W - widest) / 2

    # --- State ---
    # A bobbing block's position (bar_y#) and signed speed (bar_v#), one pair each.
    bar_y = BARS.each_index.map { |i| var :"bar_y#{i}", BARS[i][1] }
    bar_v = BARS.each_index.map { |i| var :"bar_v#{i}", BARS[i][2] }

    # The tune actually playing, which is not always the one the cursor is on: when the cursor
    # moves, the old tune fades out first, and only once nobody can hear it does this catch up
    # and the new one fade in. `switching` says a switch is waiting for that silence.
    playing   = 0
    switching = false # Which sound effect was asked for last (1 HOORAY, 2 BLIP), whose name is lit.
    asked = 0
    holding = false # true while SELECT is holding the tune
    humming = false # true while START has the hum on

    # How long the tune has been playing, in seconds, shown under the heading. Counting frames
    # would not do: the screen shows a little under sixty a second, so a clock that takes sixty
    # frames for a second falls behind, by about a second every few minutes. `timer` is a
    # counter on the console's own clock, ticking as many times a second as it is asked for
    # whatever the game is doing, and `ticks` reads how many so far. Starting it again under
    # the same name, below, puts it back to nought for the next tune.
    tune_clock = timer :tune_clock, per_second: 1
    elapsed = 0 # this frame's reading of it
    clock_x = (SCREEN_W - text_width("0:00")) / 2 # 0:07, centred: a figure in each of four places
    place = VBlank::Graphics::Fonts.default.cell_w

    # --- Advance the bobbing blocks: move each by its speed, and reverse (snap
    # to the edge, flip the sign) whenever it reaches the top or bottom. ---
    #
    # `once_a_frame` runs this once for every frame the screen really shows. The music keeps
    # that time too, whatever the game is doing, so the blocks dance on with the tune on a
    # busy frame where a step in the loop below would fall behind it.
    once_a_frame do
      BARS.each_with_index do |(_x, _y0, spd), i|
        bar_y[i] += bar_v[i]
        if bar_y[i] >= BAR_BOTTOM
          bar_y[i] = BAR_BOTTOM
          bar_v[i] = -spd
        end
        if bar_y[i] <= BAR_TOP
          bar_y[i] = BAR_TOP
          bar_v[i] = spd
        end
      end
    end

    game_loop do
      # --- Draw the screen fresh each frame ---
      clear_screen :black
      draw_text "JUKEBOX", :center, 14, :white
      draw_rect_at label_x, 26, widest, 2, :gray
      draw_text "PRESS UP OR DOWN", :center, 34, :gray
      draw_text "NOW PLAYING", :center, 108, :gray

      # The list of tunes. Each row lights up in its own accent color when the cursor
      # reaches it; the cursor, the wrapping and the held-button walk come with the
      # verb. There is no block per row because on this screen MOVING is the choice —
      # whichever row the cursor is on is the tune that plays.
      songs = menu :songs, at: [label_x, FIRST_ROW], spacing: ROW_GAP, color: :gray do |m|
        SONGS.each { |s| m.item s[:label], picked: s[:color] }
      end

      # --- Switching tunes, with a fade rather than a cut ---
      # Moving the cursor fades the music out. A faded-out tune goes on playing silently, so
      # the switch waits until the volume reads nothing, names the new tune while nobody can
      # hear it, and fades that one in. Move again part way and the fade simply turns round.
      if songs.moved
        switching = true
        fade_music_out frames: FADE_FRAMES
      end
      if switching && music_volume == 0
        switching = false
        playing = songs.picked
        fade_music_in
        timer :tune_clock, per_second: 1 # the new tune's time starts at 0:00
      end

      # The minutes (round again after nine), then the seconds as two figures, 0:07 as a clock
      # writes it.
      elapsed = tune_clock.ticks
      draw_number (elapsed / 60) % 10, clock_x, CLOCK_ROW, :gray, digits: 1
      draw_text ":", clock_x + place, CLOCK_ROW, :gray
      draw_number elapsed % 60, clock_x + (2 * place), CLOCK_ROW, :gray, digits: 2, leading_zeros: true

      # The picked row tints the bobbing blocks straight away; the tune follows once it has
      # faded. Naming the tune every frame is fine — it is the tune playing now — and naming a
      # different one starts that one from its first note.
      SONGS.each_with_index do |s, i|
        if songs.picked == i
          BARS.each_with_index { |(bx, _y0, _spd), j| draw_rect_at bx, :"bar_y#{j}", 8, 8, s[:color] }
        end
        if playing == i
          s[:name] == :chorale ? chorale.play(0) : play_song(s[:name])
        end
      end

      # --- The sound effects, over whatever is playing ---
      # Each plays once from the frame after it is asked for. Who is heard when the piano is
      # already using every voice is the priorities' to say, not this code's.
      if pressed(:a)
        sfx.play :hooray
        asked = 1
      end
      if pressed(:b)
        sfx.play :blip
        asked = 2
      end
      clack.play if pressed(:r)
      draw_text "A HOORAY", 64, EFFECTS_ROW, [:gray, :white], showing: asked == 1
      draw_text "B BLIP", 136, EFFECTS_ROW, [:gray, :white], showing: asked == 2

      # --- Holding the tune, and the hum under it ---
      # A held tune stays held while `play_song` goes on naming it above, since naming the song
      # already playing changes nothing. Each press turns its word's light on or off.
      if pressed(:select)
        if holding
          release_music
          holding = false
        else
          hold_music
          holding = true
        end
      end
      if pressed(:start)
        if humming
          stop_wave
          humming = false
        else
          wave :triangle, :C3, volume: :quarter
          humming = true
        end
      end
      draw_text "SELECT HOLD", 8, HELD_ROW, [:gray, :white], showing: holding
      draw_text "START HUM", 170, HELD_ROW, [:gray, :white], showing: humming
    end
  end)

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Jukebox::GAME.write_if_main
