# frozen_string_literal: true

require "stringio"

# WHAT A TURN OF A LOOP COSTS, for each console's own cost test. A routine called once a pass goes
# round a loop of 64 turns, against the same routine going round 32, so what the two differ by is 32
# turns and nothing else: the call, the setting up and the end are the same in both. The loop is a
# `repeat` or a game's `while i < n` with `i += 1` last (a counted while, LoopForm#counted_while),
# and its body sets a variable (:set) or reads a list at the loop's count into one (:read).
module LoopCostGames
  # The loops measured: how each is written, and what its body does.
  LOOPS = %i[repeat_set repeat_read while_set while_read].freeze

  # The turns of the longer loop and of the shorter.
  MORE_TURNS = 64
  FEWER_TURNS = 32

  # The game for +console+ whose loop is +loop+, going round +turns+ times a pass.
  def self.game(console, loop, turns)
    VBlank.game("LOOP #{loop} #{turns}", consoles: [console]) do
      words = list :words, capacity: 64, full_of: 1
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      i = 0
      s = 0
      c = 0
      func(:go_round) do
        case loop
        when :repeat_set then repeat(turns) { c = 1 }
        when :repeat_read then repeat(turns) { |k| s = words[k] }
        when :while_set
          i = 0
          while i < turns
            c = 1
            i += 1
          end
        when :while_read
          i = 0
          while i < turns
            s = words[i]
            i += 1
          end
        end
      end
      game_loop do
        call :go_round
        c += s
      end
    end
  end

  # The share of a frame +console+ spends awake running +game+.
  def self.awake_share(console, game)
    rom = game.build_rom(console: console, out: StringIO.new, err: StringIO.new, profile: false)
    1 - rom.profile(out: StringIO.new, settle: 10, frames: 30).idle_share
  end

  # What one turn of +loop+ costs on +console+, in the console's +frame_cycles+ a frame.
  def self.cycles_a_turn(console, loop, frame_cycles)
    more = awake_share(console, game(console, loop, MORE_TURNS))
    fewer = awake_share(console, game(console, loop, FEWER_TURNS))
    (more - fewer) * frame_cycles / (MORE_TURNS - FEWER_TURNS)
  end
end
