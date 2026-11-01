# frozen_string_literal: true

require "test_helper"

# NOTES THAT CHANGE AS THEY PLAY, IN A GAME WITH SOUND EFFECTS, on the voices the two share. Played
# through `game_player`, so every run's build is held to the interpreter's sound log frame by frame.
class TestChangingNotesBesideEffects < Minitest::Test
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  # A wobbling lead, and effect +ding+ on the same square voice, asked for on pass 10. The block
  # runs on each pass with the pass number.
  private def shared_voice_game(ding, lead: {}, &each_pass)
    b = Builder.new
    list = nil
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song :tune do
        tempo 150
        voice(:bass) { note :C3, :whole }
        voice(:lead) do
          lead.each { |word, said| public_send(word, *Array(said)) }
          note :E4, :whole
          note :G4, :whole
        end
      end
      list = sound_effects :sfx, { ding: ding }
      play_song :tune
      pass = 0
      game_loop do
        pass += 1
        list.play :ding if pass == 10
        instance_exec(pass, &each_pass) if each_pass
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  private def effect(**part)
    Score.new(tempo: 150, priority: 1, parts: [Part.new(notes: [Note.new(at: 0, key: :A5, length: 24)], **part)])
  end

  private def logged(program, kind, frames: 80) = game_player.run(program, frames: frames).audio.select { |entry| entry.first == kind }

  def test_an_effect_taking_a_voice_stops_the_tunes_wobble_and_its_own_ends_with_it
    wobbling = effect(vibrato: { depth: 4, speed: 2 })

    refute_empty logged(shared_voice_game(wobbling, lead: { vibrato: [{ depth: 2, speed: 3 }] }), :wobble)
  end

  def test_an_effects_note_steps_its_shapes
    stepping = effect(duty: %i[eighth half])

    refute_empty logged(shared_voice_game(stepping), :duty)
  end

  def test_a_tune_stopping_leaves_an_effects_wobble_going
    wobbling = effect(vibrato: { depth: 4, speed: 2 })
    entries = game_player.run(shared_voice_game(wobbling) { |pass| stop_music if pass == 14 }, frames: 40).audio
    stopped = entries.index([:stop_music])

    assert stopped, "the tune stopped"
    assert_includes entries.drop(stopped).map(&:first), :wobble, "and the effect's note goes on"
  end

  def test_an_effects_note_can_slide
    sliding = effect(slide_down: :slow)

    assert_includes logged(shared_voice_game(sliding), :voice).map { |entry| entry[6] }, VBlank::Audio::PitchSlide.downward(every: 7, shift: 5)
  end

  def test_a_note_can_slide_while_its_shapes_step
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) { voice(:lead) { |v| v.duty %i[eighth half]; v.note :C4, :whole, slide_down: :fast } }
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program

    refute_empty logged(b.program, :duty, frames: 12)
  end

  def test_a_swelling_note_beside_effects_is_held_at_the_music_volume
    entries = logged(shared_voice_game(effect, lead: { volume: 0, swell: :fast }) { |pass| music_volume 50 if pass == 1 }, :loudness)

    assert_includes entries.map(&:last), 7
  end
end
