# frozen_string_literal: true

require "test_helper"

# THE MUSIC VOLUME REACHING A RECORDED PART, on the Super Nintendo. A recording's loudness runs 0..512
# rather than 0..15, so volume 12 is 410 of those, and a new level moves it while the note plays.
class TestMusicVolumeOnTheSuperNintendo < Minitest::Test
  private def recorded_game(&body)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4, holds_from: 100
      song :hold do
        tempo 60
        voice(:held, plays: :piano) do
          volume 12
          note :C4, :whole
          rest :whole
          note :E4, :whole
        end
      end
      play_song :hold
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

  private def loudness(program, frames) = game_player.run(program, frames: frames).audio.select { |entry| entry.first == :loudness }

  def test_a_new_level_moves_a_recorded_note_while_it_plays
    entries = loudness(recorded_game { |pass| music_volume 50 if pass == 5 }, 10)

    assert_equal [[:loudness, [:mixer, 0], 410], [:loudness, [:mixer, 0], 205]], entries
  end

  def test_a_note_starts_at_the_level_of_the_moment
    entries = loudness(recorded_game { |pass| music_volume 25 if pass == 1 }, 300)

    assert_includes entries, [:loudness, [:mixer, 0], 102], "the note after the rest starts quiet"
  end

  def test_the_music_fading_out_takes_a_recorded_note_to_nothing
    entries = loudness(recorded_game { |pass| fade_music_out frames: 8 if pass == 4 }, 20)

    assert_equal [:loudness, [:mixer, 0], 0], entries.last
  end
end
