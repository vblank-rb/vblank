# frozen_string_literal: true

require "stringio"

# WHAT A DRAW ORDER COSTS A FRAME, for each console's own cost test: a game of seven things — four
# sprites walking up and down, passing each other, and a pool of three — put in order every pass
# by the bottom of each one's box, and the same game with no order. What the order costs is how
# much less of the frame the first leaves spare. A console's own games sort their sprites by
# height every frame for a few instructions a sprite, so the order must cost a few lines of the
# picture at most, not a tenth of the frame.
module DrawOrderCostGames
  BLOCK = Ractor.make_shareable(Array.new(16) { "#" * 16 }.join("\n"))

  # The game for +console+, with its order or without. +sprites+ walk; the pool's three stand.
  def self.game(console, ordered:, sprites: 4)
    block = BLOCK
    VBlank.game("ORDER COST", consoles: [console]) do
      screen :tiled
      image(:block, "#" => :red) { block }
      things = Array.new(sprites) { |i| sprite :"thing_#{i}", at: [(i * 29) % 200, (i * 17) % 120], facing: { down: :block } }
      crowd = pool :crowd, x: 0, y: 0, capacity: 3, image: :block
      draw_in_order(*things, crowd) if ordered
      3.times { |i| crowd.spawn(x: 30 + (i * 40), y: 100 - (i * 30)) }
      t = var :t, 0
      game_loop do
        t += 1
        things.each_with_index { |thing, i| thing.y = (t + (i * 23)) & 127 }
      end
    end
  end

  # The profile of the game for +console+ over twenty passes.
  def self.profile(console, ordered:, sprites: 4)
    rom = game(console, ordered: ordered, sprites: sprites)
          .build_rom(console: console, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, frames: 20)
  end

  # How much of a frame the order costs on +console+, from 0 to 1: the share of the frame the game
  # without it leaves spare, less the share the game with it does.
  def self.share_of_frame(console, sprites: 4)
    profile(console, ordered: false, sprites: sprites).idle_share - profile(console, ordered: true, sprites: sprites).idle_share
  end
end
