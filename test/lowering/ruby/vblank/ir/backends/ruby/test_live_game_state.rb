# frozen_string_literal: true

require "test_helper"

# A game built as Ruby and played in this process gives its state by name (LiveGame#state). A list
# of bytes, asked for packed, comes back as its bytes oldest first, the way a data pack's build
# reads its pack.
class TestLiveGameState < Minitest::Test
  # Pushed four, shifted two and pushed two more, so the ring has come round: its oldest item sits
  # in the third slot and its newest in the second.
  private def ring_game
    builder = Builder.new
    builder.instance_eval do
      ring = list :ring, capacity: 4, width: :byte
      [1, 200, 3, 4].each { |value| ring.push value }
      ring.shift
      ring.shift
      ring.push 130
      ring.push 6
      game_loop { wait_vblank }
    end
    builder.finalize_program
    builder.program
  end

  private def played(program)
    game = VBlank::IR::Backends::Ruby.new.live_game(program)
    game.play(VBlank::Original::Unpacking::FrameLimitedPlayer.new(2))
    game
  end

  def test_a_list_of_bytes_that_has_come_round_is_given_oldest_first_as_numbers_and_as_bytes
    game = played(ring_game)

    assert_equal [3, 4, -126, 6], game.state.lists.fetch("ring")
    assert_equal [3, 4, 130, 6], game.state(byte_lists_packed: true).lists.fetch("ring").bytes
  end
end
