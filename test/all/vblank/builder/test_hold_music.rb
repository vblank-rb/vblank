# frozen_string_literal: true

require "test_helper"

# THE MUSIC HELD WHERE IT IS, and let go again. While the next screen loads a game can hold the
# tune: the notes sounding ring on, nothing new starts, and `release_music` carries on from the
# note it stopped before. The log says a note as [:voice, voice, tune, pitch, volume, ...].
#
# The Advance's cartridge playing these games, read in the emulator, is in
# test/lowering/gba/vblank/builder/test_hold_music_cartridge.rb.
module HoldMusicGames
  include SharedConstants # Builder, which the games below name from inside the module

  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note
  # Each note at a volume of its own, so a cartridge's voice says which note it is on.
  NOTES = Ractor.make_shareable({ C4: 12, E4: 8, G4: 4, C5: 15 })

  # A tune of a note every 24 frames, four C4 E4 G4 C5, played from the start, and a game that
  # runs +body+ on each pass with the pass number.
  private def held_game(lead: nil, also: nil, &body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song :tune do
        tempo 150
        voice :lead do
          instance_eval(&lead) if lead
          NOTES.each { |pitch, loudness| note pitch, :quarter, volume: loudness }
        end
      end
      instance_eval(&also) if also
      play_song :tune
      pass = 0
      game_loop do
        pass += 1
        instance_exec(pass, &body)
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  # The music held from pass 30, and sound effect +effect+ played on the pass the block says.
  private def held_with_effect(effect, &asked_on)
    list = nil
    held_game(also: proc { list = sound_effects :sfx, { ding: effect } }) do |pass|
      hold_music if pass == 30
      list.play :ding if asked_on.call(pass)
    end
  end
end

class TestHoldMusic < Minitest::Test
  include HoldMusicGames

  EVENTS = %i[voice wobble duty].freeze

  # What the run logged, as [frame, kind, voice, *rest], of the kinds named.
  private def moves(program, frames:, kinds: EVENTS)
    player = game_player
    seen = []
    logged = 0
    player.each_vblank do |frame|
      player.audio.drop(logged).each { |entry| seen << [frame, *entry] if kinds.include?(entry.first) }
      logged = player.audio.size
    end
    player.run(program, frames: frames)
    seen
  end

  # The pitches voice +number+ was set to, with the frame each was set on.
  private def pitches_on(seen, number)
    seen.select { |_, kind, voice, _, pitch| kind == :voice && voice == number && pitch.positive? }
        .map { |frame, _, _, _, pitch| [frame, pitch] }
  end

  private def gaps(notes) = notes.each_cons(2).map { |(was, _), (now, _)| now - was }

  def test_nothing_new_starts_while_the_music_is_held
    game = held_game { |pass| hold_music if pass == 30 }

    assert_equal 2, pitches_on(moves(game, frames: 130), 1).size, "the first two notes, and no more"
  end

  def test_released_music_carries_on_from_the_note_it_stopped_before
    game = held_game do |pass|
      hold_music if pass == 30
      release_music if pass == 40
    end
    notes = pitches_on(moves(game, frames: 130), 1)

    assert_equal [262, 330, 392, 523], notes.first(4).map(&:last), "no note lost"
    assert_equal [24, 24 + 10, 24], gaps(notes.first(4)), "the note after the hold comes that much later"
  end

  def test_saying_the_tune_held_does_not_let_it_go
    game = held_game do |pass|
      hold_music if pass == 30
      play_song :tune
    end

    assert_equal 2, pitches_on(moves(game, frames: 130), 1).size
  end

  def test_another_tune_named_lets_it_go
    other = proc do
      song :other do
        tempo 150
        note :A4, :whole
      end
    end
    game = held_game(also: other) do |pass|
      hold_music if pass == 30
      play_song :other if pass == 40
    end

    assert_includes pitches_on(moves(game, frames: 60), 1).map(&:last), 440
  end

  def test_a_stop_while_held_stops_it_and_the_next_tune_plays
    game = held_game do |pass|
      hold_music if pass == 30
      stop_music if pass == 40
      play_song :tune if pass == 50
    end

    assert_equal [262, 330, 262, 330], pitches_on(moves(game, frames: 110), 1).map(&:last).first(4)
  end

  def test_a_sound_effect_still_plays_while_the_music_is_held
    effect = Score.new(tempo: 150, parts: [Part.new(notes: [Note.new(at: 0, key: :A5)])])
    game = held_with_effect(effect) { |pass| pass == 40 }

    assert_equal [:sound_effect, :"sfx.ding"], moves(game, frames: 60, kinds: %i[sound_effect]).first&.drop(1)
  end

  def test_a_sound_effect_keeps_wobbling_while_the_music_is_held
    effect = Score.new(tempo: 150, priority: 1, parts: [Part.new(notes: [Note.new(at: 0, key: :A5), Note.new(at: 20, key: 0)],
                                                                 vibrato: { depth: 4, speed: 2 })])
    game = held_with_effect(effect) { |pass| pass == 40 }
    wobbled = moves(game, frames: 60).select { |_, kind| kind == :wobble }.map(&:first)

    assert_operator wobbled.max, :>, 42, "the effect's note goes on wobbling"
  end

  def test_the_music_volume_still_reaches_a_held_note
    game = held_game do |pass|
      hold_music if pass == 30
      music_volume 50 if pass == 40
    end
    struck = moves(game, frames: 50, kinds: %i[loudness]).select { |frame, *| frame > 40 }

    assert_equal [[:loudness, 1, 4]], struck.map { |entry| entry.drop(1) }.uniq
  end

  def test_a_held_note_stops_wobbling
    game = held_game(lead: proc { vibrato depth: 4, speed: 2 }) { |pass| hold_music if pass == 30 }

    wobbled = moves(game, frames: 60).select { |_, kind| kind == :wobble }.map(&:first)
    assert_operator wobbled.size, :>, 2
    assert_operator wobbled.max, :<=, 31, "no wobble once held"
  end

  def test_a_held_note_stops_stepping_its_shapes
    game = held_game(lead: proc { duty %i[eighth half] }) { |pass| hold_music if pass == 30 }

    stepped = moves(game, frames: 60).select { |_, kind| kind == :duty }.map(&:first)
    assert_operator stepped.size, :>, 2
    assert_operator stepped.max, :<=, 31, "no new shape once held"
  end

  def test_a_game_with_nothing_playing_may_hold_and_a_tune_named_after_plays
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song :tune do
        tempo 150
        note :C4, :quarter
        note :E4, :quarter
      end
      hold_music
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program

    assert_equal [262, 330], pitches_on(moves(b.program, frames: 40), 1).map(&:last)
  end
end
