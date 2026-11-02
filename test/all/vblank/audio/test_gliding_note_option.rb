# frozen_string_literal: true

require "test_helper"

# `glides:` as far as every console agrees: which notes can say it, and what a console that cannot do
# it says. What it does is test/console/snes/vblank/audio/test_gliding_notes_on_the_super_nintendo.rb.
class TestGlidingNoteOption < Minitest::Test
  Score = VBlank::Audio::Score

  private def gliding_game(console, err: StringIO.new)
    VBlank.build("GLIDE", console: console, out: StringIO.new, err: err) do
      enable_sound
      instrument :tone, pcm: [60, -60] * 400, rate: 8000, note: :C4
      score = Score.new(parts: [Score::Part.new(plays: :tone, notes: [Score::Note.new(at: 0, key: :C4),
                                                                      Score::Note.new(at: 24, key: :C5, glides: true)])])
      music = songs :music, [score]
      music.play 0
      game_loop { nil }
    end
  end

  def test_a_console_that_cannot_do_it_refuses_in_plain_words
    %i[gba gbc genesis].each do |console|
      said = StringIO.new
      assert_raises(VBlank::BuildError, console.to_s) { gliding_game(console, err: said) }

      assert_match(/glides/, said.string)
    end
  end

  def test_only_true_or_false_is_taken
    error = assert_raises(ArgumentError) do
      Score.new(parts: [Score::Part.new(plays: :tone, notes: [Score::Note.new(at: 0, key: :C4, glides: :yes)])]).to_song
    end

    assert_match(/true or false/, error.message)
  end

  def test_a_square_part_cannot_glide
    error = assert_raises(ArgumentError) do
      Score.new(parts: [Score::Part.new(notes: [Score::Note.new(at: 0, key: :C4, glides: true)])]).to_song
    end

    assert_match(/plays a recording/, error.message)
  end
end
