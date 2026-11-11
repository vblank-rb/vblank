# frozen_string_literal: true

require "test_helper"

# A SPRITE WHOSE NUMBERS HAVE TO BE WORKED OUT. The Genesis places a pass's sprites in one walk
# that keeps its place in registers, and a game's sprites give their place, their picture and
# whether they show as variables, read where they live. A program built by hand can give any of
# them as a sum, a product or an item of a list, which calls the runtime between two sprites of
# the walk: the sprites after it must still land in the rows after it.
class TestGenesisSpriteNumbers < Minitest::Test
  CLEAR = VBlank::Graphics::Color.rgb(0, 0, 1)
  INKS = [VBlank::Graphics::Color.rgb(31, 0, 0), VBlank::Graphics::Color.rgb(0, 31, 0),
          VBlank::Graphics::Color.rgb(0, 0, 31), VBlank::Graphics::Color.rgb(31, 31, 31)].freeze

  def test_sprites_after_one_whose_numbers_are_worked_out_stand_where_the_interpreter_puts_them
    b = VBlank::IR::Build
    t = b.var_ref(:t)
    program = b.program(
      b.screen(:tiled),
      b.bitmap(:p0, width: 8, height: 8, pixels: block(0).pack("v*"), transparent: CLEAR),
      b.bitmap(:p1, width: 8, height: 8, pixels: block(2).pack("v*"), transparent: CLEAR),
      b.set(:t, b.int(0)),
      b.list_new(:places, 4),
      *[50, 60, 70, 80].map { |place| b.list_push(:places, b.int(place)) },
      b.list_drop(:places, from: :front),
      b.object(:behind, poses: %i[p0 p1], pose: b.int(0), x: b.int(20), y: b.int(20), active: b.int(1)),
      b.object(:worked_out, poses: %i[p0 p1], pose: b.binop(:%, t, b.int(2)),
                            x: b.binop(:+, b.list_get(:places, b.int(1)), b.binop(:*, t, b.int(7))),
                            y: b.binop(:+, b.binop(:/, t, b.int(3)), b.int(40)),
                            active: b.binop(:<, b.binop(:%, t, b.int(5)), b.int(4))),
      b.object(:in_front, poses: %i[p0 p1], pose: b.int(1), x: b.int(100), y: b.int(60), active: b.int(1)),
      b.loop_(b.wait_vblank, b.add(:t, b.int(1)), b.present_objects(%i[behind worked_out in_front]))
    )

    game_player.run(program, frames: 12)
  end

  # An 8 by 8 picture of four inks in columns, starting at ink +from+, its corners left clear.
  private def block(from)
    (0...64).map do |at|
      x = at % 8
      y = at / 8
      next CLEAR if [0, 7].include?(x) && [0, 7].include?(y)

      INKS[(from + (x / 2)) % INKS.length]
    end
  end
end
