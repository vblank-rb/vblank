# frozen_string_literal: true

require "stringio"

# WHAT A DRAW ORDER COSTS A FRAME, for each console's own cost test: a game of seven things — four
# sprites walking up and down, passing each other, and a pool of three — put in order every pass
# by the bottom of each one's box, and the same game with no order. What the order costs is how
# much less of the frame the first leaves spare. A console's own games sort their sprites by
# height every frame for a few instructions a sprite, so the order must cost a few lines of the
# picture at most, not a tenth of the frame.
module DrawOrderCostGames
  BLOCK = VBlank::Testing::InRactors.shareable(Array.new(16) { "#" * 16 }.join("\n"))

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

  # A pool of +count+ for +console+, every one spawned, sorted by the bottom of each one's box, and
  # every one turned upside down on the screen each pass, so the whole order turns round: every
  # thing passes every other, the most work a sort that moves each thing back a place at a time
  # can be given.
  def self.reversed_pool_game(console, count)
    block = BLOCK
    VBlank.game("REVERSED POOL", consoles: [console]) do
      screen :tiled
      image(:block, "#" => :red) { block }
      crowd = pool :crowd, x: 0, y: 0, capacity: count, image: :block
      draw_in_order(crowd)
      count.times { |i| crowd.spawn(x: (i * 13) % 200, y: (i * 37) % 120) }
      game_loop do
        crowd.each { |thing| thing.y = 127 - thing.y }
      end
    end
  end

  # How many passes of +game+ took each number of frames, built for +console+ and played twenty.
  def self.passes_by_frames(console, game)
    game.build_rom(console: console, out: StringIO.new, err: StringIO.new, profile: false)
        .profile(out: StringIO.new, frames: 20).passes_by_frames
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

  # How many lines of the picture the order costs the tightest frame on +console+, one where two
  # things pass each other, so a move is in the cost: the lines that frame has to spare without the
  # order, less those with it, each with the part of a line kept. Two readings rounded down to whole
  # lines would each be up to a line under, and their difference move a line when the game without
  # the order got a little faster.
  def self.lines_off_tightest_frame(console, sprites: 4)
    spare = ->(ordered) { profile(console, ordered: ordered, sprites: sprites).fewest_lines_spare_unrounded }
    spare.call(false) - spare.call(true)
  end
end
