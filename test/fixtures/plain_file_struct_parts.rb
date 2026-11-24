# frozen_string_literal: true

# A part of a game, brought in by `VBlank.require_game_file` for
# test/all/vblank/dsl/test_plain_file_structs.rb, whose method is handed an object a plain file made.

# A tally that reads a point's field after it changes the number the point was made from.
class PlainFileTally
  def initialize
    @score = 0
  end

  def point_now = PlainFilePoints.argument_at(@score)

  def read_after_bump(point)
    @score += 1
    point.x
  end
end
