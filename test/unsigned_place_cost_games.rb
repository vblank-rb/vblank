# frozen_string_literal: true

require "stringio"

# WHAT A THING OF A POOL COSTS TO STEP WHEN ITS PLACE IS KEPT IN 256THS OF A PIXEL, for each
# console's own cost test: places from 0 to 65535, kept with `& 0xFFFF`, as a game whose things
# move a fraction of a pixel a frame keeps them. A routine walks the pool once a pass, stepping
# each thing's place across and down and testing whether it has passed a line; eight things against
# four, so the two differ by four things' steps and nothing else.
module UnsignedPlaceCostGames
  # The things of the bigger game and of the smaller.
  MORE = 8
  FEWER = 4

  # The game for +console+ walking +things+ things a pass.
  def self.game(console, things)
    VBlank.game("PLACES #{things}", consoles: [console]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      walkers = pool :walker, place_x: 0, place_y: 0, capacity: 8
      things.times { |i| walkers.spawn(place_x: 40_000 + (i * 3000), place_y: 1000 * i) }
      past = var :past, 0
      func(:step_all) do
        walkers.each do |w|
          w.place_x = (w.place_x + 96) & 0xFFFF
          w.place_y = (w.place_y + 40) & 0xFFFF
          past += 1 if w.place_x > 61_440
        end
      end
      game_loop { call :step_all }
    end
  end

  # The share of a frame +console+ spends awake running +game+.
  def self.awake_share(console, game)
    rom = game.build_rom(console: console, out: StringIO.new, err: StringIO.new, profile: false)
    1 - rom.profile(out: StringIO.new, settle: 10, frames: 30).idle_share
  end

  # What one thing's step costs on +console+, in the console's +frame_cycles+ a frame.
  def self.cycles_a_thing(console, frame_cycles)
    more = awake_share(console, game(console, MORE))
    fewer = awake_share(console, game(console, FEWER))
    (more - fewer) * frame_cycles / (MORE - FEWER)
  end
end
