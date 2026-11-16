# frozen_string_literal: true

require "test_helper"

# A POOL KEPT EACH WAY THE SUPER NINTENDO CAN KEEP ONE (Backends::PoolLayout): as lists, as tables
# side by side, as a record for each thing. Each game is played on the cartridge and checked against
# the interpreter on every pass, so a slot read, written, filled or walked at the wrong place, or a
# walk that leaves its variables otherwise than the tree does, fails at the pass it shows.
class TestSNESPoolLayouts < Minitest::Test
  LAYOUTS = %i[lists tables records].freeze

  # Things of mixed widths that move, meet, are removed and spawned again, walked both ways, with a
  # routine checking each against the others, then finding itself among them to turn it back, and a
  # field read by an index the game kept.
  def self.game(layout)
    VBlank.game("LAYOUT #{layout}", consoles: %i[snes]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      things = pool :thing, x: 0, y: 0, dx: 0, hits: 0, capacity: 6, widths: { y: :half, dx: :byte, hits: :byte },
                            layout: layout
      fired = var :fired, 0
      last = var :last, 0
      oldest_x = var :oldest_x, 0
      things.func(:step) do |e|
        e.x += e.dx
        things.each do |other|
          e.hits += 1 if other.index != e.index && (other.x - e.x).abs < 12 && (other.y - e.y).abs < 40
        end
        things.each do |other|
          other.dx = 0 - other.dx if other.index == e.index && other.hits > 20 && other.hits < 23
        end
      end
      game_loop do
        things.each do |t|
          call :step
          t.remove if t.x > 200 || t.x < -20 || t.hits > 30
        end
        things.each(newest_first: true) { |t| last = t.index }
        oldest_x = things.field_ref(:x, last)
        if things.count < 5
          fired += 1
          things.spawn(x: (fired * 53) % 180, y: (fired * 7) % 60, dx: (fired % 5) - 2)
        end
      end
    end
  end

  LAYOUTS.each do |layout|
    define_method(:"test_a_pool_kept_as_#{layout}_plays_as_on_the_interpreter") do
      run = game_player.run(self.class.game(layout).program(console: :snes), frames: 90)

      assert_operator run[:fired], :>=, 5, "things were fired again after some were removed"
    end
  end
end
