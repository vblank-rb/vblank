# frozen_string_literal: true

require "test_helper"
require "vblank/testing/golden_sample"

# The golden path's random part: a share of the files off the list, drawn from a seed the run says,
# so a draw that found a fault is played again by naming its seed.
class TestGoldenSample < Minitest::Test
  FILES = (1..40).map { |n| format("test/test_%02d.rb", n) }.freeze

  def test_a_share_of_the_files_is_drawn
    draw = VBlank::Testing::GoldenSample.draw(FILES, share: 0.05, env: {})

    assert_equal 2, draw.files.size
    assert_equal 40, draw.drawn_from
    assert_empty draw.files - FILES
  end

  def test_the_same_seed_draws_the_same_files
    first = VBlank::Testing::GoldenSample.draw(FILES, share: 0.25, env: { "GOLDEN_SEED" => "1234" })
    again = VBlank::Testing::GoldenSample.draw(FILES.reverse, share: 0.25, env: { "GOLDEN_SEED" => "1234" })

    assert_equal 1234, first.seed
    assert_equal first.files, again.files
  end

  def test_the_message_names_the_seed_to_play_again
    draw = VBlank::Testing::GoldenSample.draw(FILES, env: { "GOLDEN_SEED" => "77" })

    assert_match "GOLDEN_SEED=77", draw.message
  end

  def test_a_small_share_of_a_few_files_still_draws_one
    assert_equal 1, VBlank::Testing::GoldenSample.draw(FILES.first(3), share: 0.05, env: {}).files.size
  end
end
