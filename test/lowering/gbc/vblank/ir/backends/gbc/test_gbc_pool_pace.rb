# frozen_string_literal: true

require "test_helper"
require "stringio"

# WHAT DRAWING A BIG POOL COSTS A GAME BOY COLOR, measured in the emulator. Each of a pool's sprites
# is placed from the copy of the pool made in order every pass (DSL::Pool#stacked_list), read at a
# place in it written in the program; and thirty-two things of sixteen by sixteen are more pieces
# than the console's sprite table holds, so most of them find the table full.
class TestGBCPoolPace < Minitest::Test
  FRAMES = 30

  # A pool of +count+ squares +size+ pixels across, drawn, standing still or each moving down a
  # pixel a pass.
  def self.crowd_game(moving:, size:, count: 32)
    square = VBlank::Testing::InRactors.shareable(Array.new(size) { "#" * size }.join("\n"))
    VBlank.game("POOL PACE", consoles: %i[gbc]) do
      screen :tiled
      image(:square, "#" => :red) { square }
      crowd = pool :crowd, x: 0, y: 0, capacity: count, image: :square
      count.times { |i| crowd.spawn(x: (i * 13) % 200, y: (i * 37) % 120) }
      game_loop do
        crowd.each { |c| c.y = (c.y + 1) & 127 } if moving
      end
    end
  end

  # Thirty-two pieces, all of which the table holds: the picture the interpreter shows.
  SMALL_MOVING = crowd_game(moving: true, size: 8)
  BIG_STILL = crowd_game(moving: false, size: 16)

  def test_a_moving_crowd_shows_what_the_interpreter_shows
    game_player.run(SMALL_MOVING.program(console: :gbc), frames: 12)
  end

  # Measured: a pass took about 1.4 frames before. Now under one.
  def test_a_big_crowd_standing_still_keeps_a_pass_a_frame
    result = BIG_STILL.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
                      .profile(out: StringIO.new, frames: FRAMES)

    assert_equal result.frames, result.passes, "every pass fits in one frame"
  end
end
