# frozen_string_literal: true

require "test_helper"

# The song these tests play, shared with the Advance cartridge's own tests of the same sides
# (test/lowering/gba/vblank/audio/test_song_pan_cartridge.rb).
module SongPanGames
  private def song_game(&parts)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        tempo 150 # a quarter is 24 frames
        instance_eval(&parts)
      end
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end
end

# A SONG'S PARTS THAT PLAY FROM ONE SPEAKER — the left, the right, or both, which is what every
# part does when it says nothing, or a shade between. A part says its side (`v.pan :left`,
# `v.pan -0.7`), and a note can say its own (`pan: :right`), so a part can move from side to side as
# the song goes. Where a recorded part sits is heard on the Super Nintendo
# (test/lowering/snes/vblank/ir/backends/snes/test_snes_recorded_pan.rb).
#
# The log names the side each note plays from at the end of its [:voice] entry, after its fade,
# slide and wobble, and says nothing for both sides. What the Advance's cartridge plays from each
# speaker, heard in the emulator, is in test/lowering/gba/vblank/audio/test_song_pan_cartridge.rb.
class TestSongPan < Minitest::Test
  include SongPanGames

  # Each note's [:voice] entry, as [voice, pitch, side], the side nil for both.
  private def sides_logged(program, frames:)
    game_player.run(program, frames: frames).audio.filter_map do |kind, voice, _who, pitch, _volume, *said|
      [voice, pitch, said[3]] if kind == :voice && pitch.positive?
    end
  end

  def test_a_left_part_and_a_right_part_each_play_from_their_side
    played = sides_logged(song_game do
      voice(:lead) { |v| v.pan :left; v.note :C5, :whole }
      voice(:harmony) { |v| v.pan :right; v.note :E4, :whole }
      voice(:bass, plays: :wave) { |v| v.note :C3, :whole }
    end, frames: 4)

    assert_equal [[1, :left], [2, :right], [3, nil]], played.map { |voice, _, side| [voice, side] }.sort_by(&:first)
  end

  # A note says its own side, and :center plays one from both in a part that pans.
  def test_a_note_says_its_own_side
    played = sides_logged(song_game do
      voice :lead do |v|
        v.pan :left
        v.note :C5, :quarter
        v.note :D5, :quarter, pan: :right
        v.note :E5, :quarter, pan: :center
        v.note :F5, :quarter
      end
    end, frames: 100)

    assert_equal %i[left right] + [nil] + %i[left], played.first(4).map(&:last)
  end

  def test_the_drums_can_pan
    played = sides_logged(song_game { voice(:drums, plays: :noise) { |v| v.pan :right; v.note :C2, :quarter } }, frames: 4)

    assert_equal [[4, :right]], played.map { |voice, _, side| [voice, side] }
  end

  # A SCORE SAYS IT THE SAME WAY: a part's `pan:` and a note's own.
  def test_a_score_says_which_side_its_notes_play_from
    score = VBlank::Audio::Score
    lead = score::Part.new(pan: :left, notes: [score::Note.new(at: 0, key: 72, length: 24),
                                               score::Note.new(at: 24, key: 74, length: 24, pan: :right)])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      songs(:music, [score.new(parts: [lead], tempo: 150)]).play 0
      game_loop { wait_vblank }
    end
    b.finalize_program

    assert_equal %i[left right], sides_logged(b.program, frames: 30).map(&:last)
  end

  # A SHADE BETWEEN THE SPEAKERS, on a voice that only switches between them, plays from the nearest
  # of the three: one side alone where that side is at least twice the other, both otherwise.
  def test_a_shade_plays_a_square_part_from_the_nearest_side
    played = sides_logged(song_game do
      voice :lead do |v|
        v.pan(-0.7)
        v.note :C5, :quarter
        v.note :D5, :quarter, pan: 0.3
        v.note :E5, :quarter, pan: 0.5
        v.note :F5, :quarter, pan: -0.49
      end
    end, frames: 100)

    assert_equal [:left, nil, :right, nil], played.first(4).map(&:last)
  end

  def test_a_shade_of_nought_or_a_whole_side_is_the_same_as_its_name
    pan = VBlank::Audio::Pan
    assert_equal [pan::LEFT, pan::CENTER, pan::RIGHT], [-1, 0, 1.0].map { |shade| pan.said(shade, where: "A part") }
  end

  # A console game's tune heard with a voice at 38 on the left and 12 on the right, and one at 8 and
  # 30, is a shade a game can give: each far side's share, in 64ths, times its near side's loudness
  # comes to the far side's volume.
  def test_a_shade_reaches_the_left_and_right_volumes_of_a_console_game
    shares = [-0.6875, 0.734375].map { |shade| VBlank::Audio::Pan.said(shade, where: "A part") }

    assert_equal [[64, 20], [17, 64]], shares.map { |pan| [pan.left, pan.right] }
    assert_equal [12, 8], [(38 * 20 / 64.0).round, (30 * 17 / 64.0).round]
  end

  # --- what a side cannot be said of ---

  def test_a_side_that_is_not_one_says_what_it_can_be
    error = assert_raises(ArgumentError) { song_game { voice(:lead) { |v| v.note :C5, :quarter, pan: :up } } }

    assert_match(/:left, :right/, error.message)
  end

  def test_a_shade_past_a_speaker_says_how_far_it_can_go
    error = assert_raises(ArgumentError) { song_game { voice(:lead) { |v| v.pan 1.5 } } }

    assert_match(/-1\.0/, error.message)
  end
end
