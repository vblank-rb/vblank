# frozen_string_literal: true

require "stringio"

# WHAT A SPRITE NOT SHOWING COSTS A FRAME, for each console's own cost test: a game of many sprites
# declared and four showing, each of the four moving, against the same game with only the four
# declared; and a pool of many places holding four things, against a pool of four. A game keeps
# sprites declared for what may show later — the actors of a scene, the places of a pool — and
# one not showing must cost the frame a test of whether it shows, not the work of one that does.
module SpriteCountCostGames
  BLOCK = VBlank::Testing::InRactors.shareable(Array.new(16) { "#" * 16 }.join("\n"))
  SHOWING = 4

  # +declared+ sprites for +console+, all but the first four hidden as the game starts; with
  # +ordered+, every one of them in one draw_in_order.
  def self.sprites_game(console, declared, ordered: false)
    block = BLOCK
    VBlank.game("SPRITE COUNT", consoles: [console]) do
      screen :tiled
      image(:block, "#" => :red) { block }
      things = Array.new(declared) { |i| sprite :"thing_#{i}", at: [(i * 29) % 200, (i * 17) % 120], facing: { down: :block } }
      draw_in_order(*things) if ordered
      things.drop(SHOWING).each(&:hide)
      t = var :t, 0
      game_loop do
        t += 1
        things.first(SHOWING).each_with_index { |thing, i| thing.y = (t + (i * 23)) & 127 }
      end
    end
  end

  # A pool of +capacity+ places for +console+ holding four things, each moving down a pixel a pass;
  # with +ordered+, its things in a draw_in_order.
  def self.pool_game(console, capacity, ordered: false)
    block = BLOCK
    VBlank.game("POOL COUNT", consoles: [console]) do
      screen :tiled
      image(:block, "#" => :red) { block }
      crowd = pool :crowd, x: 0, y: 0, capacity: capacity, image: :block
      draw_in_order(crowd) if ordered
      SHOWING.times { |i| crowd.spawn(x: (i * 13) % 200, y: (i * 37) % 120) }
      game_loop { crowd.each { |thing| thing.y = (thing.y + 1) & 127 } }
    end
  end

  # The profile of +game+ on +console+ over twenty passes.
  def self.profile(console, game)
    game.build_rom(console: console, out: StringIO.new, err: StringIO.new, profile: false)
        .profile(out: StringIO.new, frames: 20)
  end

  # The share of a frame +big+ costs beyond +small+, the same game with only the four declared.
  def self.share_beyond(console, big, small)
    profile(console, small).idle_share - profile(console, big).idle_share
  end
end
