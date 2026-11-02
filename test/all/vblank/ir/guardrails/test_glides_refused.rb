# frozen_string_literal: true

require "test_helper"

# `glides: true` on a console that cannot do it yet stops the build in plain words.
class TestGlidesRefused < Minitest::Test
  Score = VBlank::Audio::Score

  private def gliding_game(console, err:)
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
end
