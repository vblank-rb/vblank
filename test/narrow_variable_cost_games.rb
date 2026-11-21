# frozen_string_literal: true

require "stringio"

# What a turn of work on small variables costs, for each console's own cost test. A routine called
# once a pass goes round a loop of 64 turns, against the same routine going round 32, so the two
# differ by 32 turns and nothing else. Each turn works three variables the build can prove stay in
# 16 bits (Backends::NumberRanges): a place stepped and masked to ten bits, a second masked to
# eleven, and their sum masked to twelve. A console's own games keep such numbers in 16 bits or
# less; kept in 32, each is twice the reads and writes.
module NarrowVariableCostGames
  # The turns of the longer loop and of the shorter.
  MORE_TURNS = 64
  FEWER_TURNS = 32

  # The game for +console+ whose loop goes round +turns+ times a pass.
  def self.game(console, turns)
    VBlank.game("NARROW #{turns}", consoles: [console]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      x = 0
      y = 0
      d = 0
      func(:work) do
        repeat(turns) do
          x = (x + 3) & 1023
          y = (y + x) & 2047
          d = (x + y) & 4095
        end
      end
      game_loop { call :work }
    end
  end

  # The share of a frame +console+ spends awake running +game+.
  def self.awake_share(console, game)
    rom = game.build_rom(console: console, out: StringIO.new, err: StringIO.new, profile: false)
    1 - rom.profile(out: StringIO.new, settle: 10, frames: 30).idle_share
  end

  # What one turn costs on +console+, in the console's +frame_cycles+ a frame.
  def self.cycles_a_turn(console, frame_cycles)
    more = awake_share(console, game(console, MORE_TURNS))
    fewer = awake_share(console, game(console, FEWER_TURNS))
    (more - fewer) * frame_cycles / (MORE_TURNS - FEWER_TURNS)
  end
end
