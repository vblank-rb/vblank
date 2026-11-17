# frozen_string_literal: true

require "test_helper"
require "stringio"

# A ROUTINE OF A POOL THAT WALKS ITS OWN POOL knows which thing it runs for at no cost. Its thing
# is kept for the walk by the store every walk makes before it starts (DSL::Pool#build_routine_body),
# so a routine called many times a pass pays nothing for it, and reads its own thing's fields inside
# the walk as cheaply as a routine reading the pool's current thing does.
#
# The pool holds one thing, so the routine's thing and the walk's are the same, and the game does
# the same work on the same numbers whichever thing a read of `e` finds. Read off the console with
# the profiler.
class TestSNESPoolRoutineWalkCost < Minitest::Test
  GAME = VBlank.game("SELFWALK", consoles: %i[snes]) do
    screen :tiled
    image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
    tiles :set, "#" => :floor
    background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
    enemies = pool :enemy, place_x: 0, place_y: 0, near: 0, capacity: 4
    enemies.spawn(place_x: 40, place_y: 40)
    bumped = var :bumped, 0
    enemies.func(:step_straight) do |e|
      e.place_x += 1
      bumped = 0
      enemies.each do |other|
        bumped += 1 if (other.place_x - e.place_x).abs < 16 && (other.place_y - e.place_y).abs < 16
      end
      e.near = bumped
    end
    game_loop do
      repeat(12) { enemies.each { |_e| call :step_straight } }
    end
  end

  # The tightest frame keeps the lines it kept when a routine read the pool's current thing
  # throughout, before a routine walking its pool kept its thing apart: twelve calls a pass, each
  # copying its thing as it started, took more than a line of it.
  def test_twelve_calls_of_a_routine_walking_its_pool_cost_no_more_than_reading_the_current_thing
    rom = GAME.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    lines = rom.profile(out: StringIO.new, settle: 10, frames: 20).fewest_lines_spare_unrounded

    assert_operator lines, :>=, 174.2
  end

  # The routine finds its own thing near itself on every pass, as the interpreter does.
  def test_the_routine_reads_its_own_thing_as_the_interpreter_does
    game_player.run(GAME.program(console: :snes), frames: 20)
  end
end
