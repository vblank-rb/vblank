# frozen_string_literal: true

require "test_helper"

# WHICH SONG IS PLAYING, asked of a running game by the song's name (`music_playing`), nil for
# none. The player takes up what a pass named at the frame boundary after it, and pass N runs
# between boundaries N and N + 1: so a song pass 10 names is playing from frame 11, and frame
# 10 still has the song before. `stop_music`, and a song that plays once reaching its end, leave
# none.
class TestMusicPlaying < Minitest::Test
  Score = VBlank::Audio::Score

  # Two songs, :title and :level, each one long held note. The game names :title from its
  # first pass, :level from pass 10 and stops the music on pass 20.
  private def switching_game
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song :title do
        tempo 60
        note :C4, :whole
      end
      song :level do
        tempo 60
        note :E4, :whole
      end
      pass = 0
      game_loop do
        pass += 1
        play_song :title if pass < 10
        play_song :level if pass >= 10 && pass < 20
        stop_music if pass == 20
      end
    end
    b.finalize_program
    b.program
  end

  # The song playing at each frame boundary +at+, by the frame.
  private def playing_at(program, at)
    player = game_player
    seen = {}
    player.each_vblank { |frame| seen[frame] = player.music_playing if at.include?(frame) }
    player.run(program, frames: at.max + 1)
    seen
  end

  def test_the_song_named_plays_from_the_frame_after_and_none_once_stopped
    seen = playing_at(switching_game, [1, 2, 9, 10, 11, 19, 20, 21])

    assert_equal({ 1 => nil, 2 => :title, 9 => :title, 10 => :title, 11 => :level,
                   19 => :level, 20 => :level, 21 => nil }, seen)
  end

  # A song of a list is named by the list and its key. This one plays once and lasts ten frames,
  # named on every pass: it is playing for its ten frames, from frame 2, and none after though
  # the game goes on naming it.
  def test_a_song_that_plays_once_is_not_playing_after_its_end
    jingle = Score.new(tempo: 150, length: 10, plays_once: true,
                       parts: [Score::Part.new(notes: [Score::Note.new(at: 0, key: :C4)])])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      music = songs :music, { jingle: jingle }
      game_loop do
        music.play :jingle
      end
    end
    b.finalize_program
    seen = playing_at(b.program, [1, 2, 11, 12, 25])

    assert_equal({ 1 => nil, 2 => :"music.jingle", 11 => :"music.jingle", 12 => nil, 25 => nil }, seen)
  end

  def test_a_game_with_no_song_plays_none
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      game_loop { clear_screen :black }
    end
    b.finalize_program

    assert_nil game_player.run(b.program, frames: 2).music_playing
  end
end