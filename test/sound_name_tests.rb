# frozen_string_literal: true

# Which sound effects a cartridge started on each frame, and which song was playing, read off the
# running cartridge by the names the game gave them, the way the interpreter's audio log says them.
# Played by each console whose reader can say them. Each including test says +console+.
#
# The game starts its song on its first pass and another, at once, on a later one; and asks for
# sound effects in each of the ways a reading taken once a frame could get wrong: twice in one
# pass, one replaced by another of its group in the same pass, one asked for on the frame another
# ends, and one started where it is asked rather than at the next frame.
module SoundNameTests
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  # The frames the interpreter and the cartridge are held together over: past the last pass the
  # game asks for anything on.
  FRAMES = 40

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame. The hit's last note is due
  # ten frames in and lasts a frame, so the hit is over at its eleventh.
  private def effects
    {
      hit: Score.new(tempo: 150, parts: [Part.new(notes: [Note.new(at: 0, key: :C5), Note.new(at: 10, key: :E5)])],
                     length: 11),
      spark: Score.new(tempo: 150, parts: [Part.new(notes: [Note.new(at: 0, key: :G5)])], length: 4),
      cry: Score.new(tempo: 150, group: :voice, parts: [Part.new(notes: [Note.new(at: 0, key: :A5)])], length: 6),
      hurt: Score.new(tempo: 150, group: :voice, parts: [Part.new(notes: [Note.new(at: 0, key: :B5)])], length: 6),
    }
  end

  private def named_sound_game
    sounds = effects
    VBlank.build("SOUNDNAMES", console: console, out: nil, err: nil) do
      screen :bitmap
      enable_sound
      song(:theme) { voice(:lead) { note :A4, :quarter; rest :whole } }
      song(:boss) { voice(:lead) { note :C4, :quarter; rest :whole } }
      sfx = sound_effects :sfx, sounds
      pass = 0
      game_loop do
        pass += 1
        play_song :theme if pass == 1
        sfx.play :hit if pass == 3
        if pass == 6
          sfx.play :spark
          sfx.play :spark
        end
        if pass == 9
          sfx.play :cry
          sfx.play :hurt
        end
        sfx.play :spark if pass == 14
        sfx.play :hit, this_frame: true if pass == 20
        play_song :boss, this_frame: true if pass == 24
        stop_music if pass == 30
      end
    end
  end

  # What the interpreter says of +built+, frame by frame: the effects its log says started, in
  # order, and the song it was on.
  private def interpreted(built)
    frames = []
    player = VBlank::IR::Backends::Reference.new
    player.each_vblank do |frame|
      started = player.audio.select { |entry| entry[0] == :sound_effect }.map { |entry| entry[1] }
      player.audio.clear
      frames << [frame, started, player.music_playing]
    end
    player.run(built.source_program, frames: FRAMES)
    frames
  end

  # ...and what the cartridge says, played a frame past them, since the cartridge's sound player
  # does a frame's work as the next starts.
  private def cartridge(built)
    reader = VBlank::Diagnostics::Verifier.new(built, frames: FRAMES + 1)
    reader.watch_sound_names
    reader.sound_names_by_frame.map { |heard| [heard.frame, heard.effects, heard.song] }
  end

  def test_the_cartridge_starts_each_sound_on_the_frame_the_interpreter_does
    built = named_sound_game
    want = interpreted(built)
    got = cartridge(built)

    assert_equal want, got.first(FRAMES)
  end

  def test_each_effect_is_named_on_the_frame_after_the_pass_that_asked
    started = cartridge(named_sound_game).reject { |_, effects, _| effects.empty? }.to_h { |frame, effects, _| [frame, effects] }

    assert_equal({ 4 => [:"sfx.hit"], 7 => [:"sfx.spark"], 10 => [:"sfx.hurt"], 15 => [:"sfx.spark"],
                   21 => [:"sfx.hit"] }, started,
                 "asked twice, one start; cut off by its group as it was asked, the second alone; " \
                 "this_frame, the same frame as asked for at the next")
  end

  def test_the_song_is_named_while_it_plays
    songs = cartridge(named_sound_game).to_h { |frame, _, song| [frame, song] }

    assert_equal [nil, :theme], [songs[1], songs[2]]
    assert_equal [:theme, :boss], [songs[24], songs[25]], "this_frame"
    assert_equal [:boss, nil], [songs[30], songs[31]]
  end
end
