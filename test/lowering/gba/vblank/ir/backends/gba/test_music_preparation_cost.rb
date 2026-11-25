# frozen_string_literal: true

require "test_helper"

# What getting a game's music ready costs the build, counted in walks of the whole program. Each
# walk visits every node, so on a big game each one is a cost a build pays on every lowering, and
# a game with no sound used to pay for many of them to learn that it plays nothing.
class TestMusicPreparationCost < Minitest::Test
  Score = VBlank::Audio::Score

  private def quiet_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      x = 0
      game_loop do
        wait_vblank
        x += 1
        fill_rect 0, 0, 8, 8, :green
      end
    end
    b.finalize_program
    b.program
  end

  private def program_with_a_song
    notes = [Score::Note.new(at: 0, key: :C4), Score::Note.new(at: 10, key: :E4)]
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      music = songs :music, [Score.new(tempo: 150, parts: [Score::Part.new(notes: notes)])]
      pass = var :pass, 0
      game_loop do
        pass += 1
        music.play 0 if pass == 3
      end
    end
    b.finalize_program
    b.program
  end

  # How many times getting the music ready walks +program+, as the game's lowering runs. The
  # count is kept on the program the test made, and a walk is counted when the music's
  # preparation is among its callers. A walk asked for with no block hands back an enumerator that
  # calls it again with one, so only the call with a block is a walk.
  private def music_walks(program)
    walks = 0
    program.define_singleton_method(:walk) do |&visit|
      walks += 1 if visit && caller_locations.any? { |place| place.label.end_with?("prepare_music") }
      super(&visit)
    end
    GBA.new(fast_code: false).lower(program)
    walks
  end

  # One walk to find that nothing names a song, and none to ask which songs play. Asked a
  # question at a time, as it once was, a game with no sound was walked 75 times here.
  def test_a_game_with_no_sound_is_walked_once_for_its_music
    assert_equal 1, music_walks(quiet_program)
  end

  # A game with a song asks which songs it plays once, not once a question. 24 is what the
  # preparation came to when this was written (its own walk, the songs played and playable, the
  # numbering, the effects and the most recorded parts), against 75 a question at a time.
  MOST_WALKS_WITH_A_SONG = 24

  def test_a_game_with_a_song_asks_which_songs_play_once
    assert_operator music_walks(program_with_a_song), :<=, MOST_WALKS_WITH_A_SONG
  end
end
