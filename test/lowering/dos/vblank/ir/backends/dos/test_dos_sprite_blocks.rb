# frozen_string_literal: true

require "test_helper"

# SPRITES IN BLOCKS ON A PC, in DOSBox, held to the interpreter on every pass (DOS::CheckedRun). The rule is a
# console display's, which puts each box a sprite is drawn as into blocks by itself (Reference::SpriteBlocks), and
# the processor draws it so (Runtime::SpriteBlocks): a block left of a box or above it reads the box's first column
# or row, the last block across runs on past the box's edge, and nothing is drawn below it. These are what is DOS's
# own: sprites cut into several boxes, half off each edge of the screen, drawn over the picture and into the view
# at their levels, in sizes that change pass by pass, and a layer left as drawn.
class TestDOSSpriteBlocks < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  # A picture whose every pixel differs from its neighbours, some see-through, so a block reading a column or a row
  # off shows: 24 wide, which a console draws as more than one box, and 12 tall.
  PATCH = (0...12).map { |row| (0...24).map { |col| ((col * 3) + row) % 7 == 6 ? "." : "RGBW"[(col + (row * 2)) % 4] }.join }.join("\n").freeze
  KEY = { "." => :transparent, "R" => :red, "G" => :green, "B" => :blue, "W" => :white }.freeze
  SQUARE = ("########\n" * 8).freeze

  private def program_of(&game) = VBlank.game("DOSGAME", consoles: %i[dos], &game).program(console: :dos)
  private def checked(frames:, &game) = DOS::CheckedRun.new.run(program_of(&game), frames: frames)

  # The tiles every game here stands its sprites on. Public, as the games call back through it.
  def field(game)
    game.instance_eval do
      image(:dark, "#" => :gray) { SQUARE }
      image(:light, "#" => :cyan) { SQUARE }
      tiles :ground, "a" => :dark, "b" => :light
      background :floor, tiles: :ground, map: Array.new(32) { |r| (r.even? ? "ab" : "ba") * 16 }
    end
  end

  # Sprites over the picture, one partly off each edge, and the size growing a pixel a pass past the biggest.
  def test_sprites_over_the_picture_in_every_size_and_off_every_edge
    test = self
    checked(frames: 20) do
      screen :tiled
      test.field(self)
      image(:patch, KEY) { PATCH }
      places = [[33, 21], [-7, 50], [300, 90], [140, -5], [200, 193]]
      sprites = places.each_with_index.map { |(x, y), i| sprite :"thing#{i}", at: [x, y], facing: { right: :patch } }
      size = var :size, 0
      game_loop do
        size += 1
        pixelate size
        sprites.first.x += 3
      end
    end
  end

  # A background in front of a sprite puts the sprites into the view at their levels; the top layer, left as
  # drawn, keeps its sprite sharp while the rest is in blocks.
  def test_sprites_at_their_levels_and_a_layer_left_as_drawn
    test = self
    checked(frames: 12) do
      screen :tiled
      layers :ground, :walkers, :fence, :labels
      image(:patch, KEY) { PATCH }
      image(:post, "#" => :yellow, "." => :transparent) { "#.......\n" * 8 }
      layer(:ground) { test.field(self) }
      walker = layer(:walkers) { sprite :walker, at: [50, 40], facing: { right: :patch } }
      layer(:fence) do
        tiles :posts, "p" => :post, "." => :post
        background :fence, tiles: :posts, map: Array.new(32) { "p" * 32 }
      end
      layer(:labels) { sprite :label, at: [90, 60], facing: { right: :patch } }
      size = var :size, 1
      game_loop do
        size += 1 if size < 9
        walker.x += 2
        pixelate size, under: :labels
      end
    end
  end
end
