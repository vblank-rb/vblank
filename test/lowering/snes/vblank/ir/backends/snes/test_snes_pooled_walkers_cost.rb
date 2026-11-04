# frozen_string_literal: true

require "test_helper"
require "stringio"

# THREE POOLED WALKERS BESIDE HEAVY TILE WORK KEEP ROOM IN THE FRAME, as three enemies do in a
# console's own games. Each pass each walker tests the square ahead in a list of walls, steps its
# place (kept in 256ths of a pixel), walks the pool from inside a routine of the pool's to compare
# its place with the others' (each place shifted down to pixels, an abs on each axis), faces one of
# 16 poses by a number it works out, and sets its x and y; and twenty-four cells of the background
# change. Read off the console with the profiler.
class TestSNESPooledWalkersCost < Minitest::Test
  # A 16×16 pose with a cross at +n+, so each of the 16 is a picture of its own.
  def self.pose_art(n)
    Array.new(16) { |row| (0...16).map { |col| (col == n || row == n) && row < 14 ? "#" : "." }.join }.join("\n")
  end

  # The game, with its walkers or without.
  def self.game(walkers:)
    VBlank.game("WALKERS", consoles: %i[snes]) do
      screen :tiled
      image(:wall, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:fire, "#" => :yellow) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :wall, "." => :floor, "*" => :fire
      field = background :field, tiles: :set, map: Array.new(28) { |r| r.zero? || r == 27 ? "#" * 32 : "##{'.' * 30}#" }
      walls = list :walls, capacity: 256, width: :byte, full_of: 0
      16.times do |c|
        walls[c] = 1
        walls[(13 * 16) + c] = 1
      end
      14.times do |r|
        walls[r * 16] = 1
        walls[(r * 16) + 15] = 1
      end

      if walkers
        poses = (0...16).map do |n|
          image(:"pose#{n}", "." => :transparent, "#" => :green) { TestSNESPooledWalkersCost.pose_art(n) }
          :"pose#{n}"
        end
        walking = pool :walker, x: 0, y: 0, px: 0, py: 0, dir: 0, walk: 0, near: 0, capacity: 3,
                                widths: { dir: :byte, walk: :byte, near: :byte }, facing: poses.to_h { |n| [n, n] }
        [[40, 40, 0], [120, 72, 1], [72, 120, 2]].each do |x, y, d|
          walking.spawn(x: x, y: y, px: x * 256, py: y * 256, dir: d)
        end
        me_x = var :me_x, 0
        me_y = var :me_y, 0
        me = var :me, 0
        bumped = var :bumped, 0
        col = var :col, 0
        row = var :row, 0

        walking.func(:step_straight) do |e|
          col = (e.px >> 8) >> 4
          row = (e.py >> 8) >> 4
          if e.dir == 0
            col += 1
          elsif e.dir == 1
            col -= 1
          elsif e.dir == 2
            row += 1
          else
            row -= 1
          end
          if walls[(row * 16) + col] == 0
            if e.dir == 0
              e.px += 128
            elsif e.dir == 1
              e.px -= 128
            elsif e.dir == 2
              e.py += 128
            else
              e.py -= 128
            end
          else
            e.dir = (e.dir + 1) & 3
          end
          me_x = e.px >> 8
          me_y = e.py >> 8
          me = e.index
          bumped = 0
          walking.each do |o|
            bumped = 1 if o.index != me && ((o.px >> 8) - me_x).abs < 16 && ((o.py >> 8) - me_y).abs < 16
          end
          e.near = bumped
          e.walk = (e.walk + 1) & 3
          e.face poses, showing: (e.dir * 4) + e.walk
          e.x = e.px >> 8
          e.y = e.py >> 8
        end
      end

      t = var :t, 0
      reach = var :reach, 0
      game_loop do
        t += 1
        reach = (t & 7) * 6
        walking.each { |_e| call :step_straight } if walkers
        repeat(24) do |i|
          if (t & 1) == 0
            field.set_tile i + 2, (t & 15) + 4, "*"
          else
            field.set_tile i + 2, (t & 15) + 4, "."
          end
        end
      end
    end
  end

  # One sprite standing still, or none, over a background that does nothing else.
  def self.still(sprites:)
    VBlank.game("STILL", consoles: %i[snes]) do
      screen :tiled
      image(:dot, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      sprite :dot, at: [40, 40] if sprites
      t = var :t, 0
      game_loop { t += 1 }
    end
  end

  private def lines_spare(game)
    rom = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, settle: 10, frames: 20).fewest_lines_spare
  end

  # Of the frame's 262 lines, the walkers and the cells leave well over a third.
  def test_three_pooled_walkers_beside_tile_work_leave_room
    assert_operator lines_spare(self.class.game(walkers: true)), :>=, 100
  end

  # The console's sprite table has 128 rows. Putting them all away every pass, for one sprite
  # shown, would cost the frame a fifteenth of itself.
  def test_one_sprite_costs_a_frame_what_it_shows
    without = lines_spare(self.class.still(sprites: false))
    with = lines_spare(self.class.still(sprites: true))

    assert_operator without - with, :<, 8
  end
end
