# frozen_string_literal: true

require "test_helper"
require "differential"

# A background on a painted screen, on the cartridge: black means what the interpreter says it means.
class TestStampedBlack < Minitest::Test
  include Differential

  private def stamped_game(**says)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:half, "#" => :black, "." => :white) { (["####...."] * 8).join("\n") }
      tiles :walls, "#" => :half, **says
      clear_screen :red
      background :room, tiles: :walls, map: "#"
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  def test_black_is_see_through_on_the_cartridge
    assert_backends_agree(stamped_game, frames: [4], name: "STAMPED")
  end

  def test_solid_black_stays_on_the_cartridge
    assert_backends_agree(stamped_game(black: :solid), frames: [4], name: "STAMPSOLID")
  end
end
