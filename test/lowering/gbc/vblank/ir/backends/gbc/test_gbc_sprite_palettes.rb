# frozen_string_literal: true

require "test_helper"

# The color's eight sprite palettes, shared between pictures (GBC::SpriteSlots). A sprite palette
# holds three colours and see-through, and a sprite's pixels name a slot in it. Two pictures drawn
# from the same colours in different pixel orders share one palette where that costs no tile, and,
# where the game's sprites need more than the eight palettes, where it costs a few. A game with
# palettes to spare keeps its pictures as they are.
class TestGBCSpritePalettes < Minitest::Test
  WARM = %i[transparent red orange].freeze
  COLD = %i[transparent blue white].freeze

  # An 8x8 picture: its left half +first+ and its right half +second+. Mirrored, one order of the
  # colours is the other's tile.
  HALVES = ->(first, second) { Array.new(64) { |at| (at % 8) < 4 ? first : second } }

  # An 8x8 picture: its top left pixel +first+ and the rest +second+. No turn of it puts the one
  # pixel anywhere else, so it and the same shape in the other order share a tile only in their own
  # orders, each in a palette of its own.
  CORNER = ->(first, second) { Array.new(64) { |at| at.zero? ? first : second } }

  # The colours of pair +n+: :warm for the first, and others of their own after it.
  private def pair_colors(n) = n.zero? ? WARM : [:transparent, Color.rgb(31, n * 6, 0), Color.rgb(0, n * 6, 31)]

  # Where pair +n+'s two sprites stand, the first of them first: a row each.
  private def pair_spots(n) = [[40, 24 + (n * 20)], [80, 24 + (n * 20)]]

  # +pairs+ pairs of 8x8 sprites in +shape+, each pair drawn from a list of its own (#pair_colors):
  # one sprite its first colour then its second, the other the second then the first, so their
  # pixels use the list's colours in the two orders. +drawn_with+ is a list every sprite is drawn
  # with instead, or nil for their own colours.
  private def two_orders_game(shape: HALVES, pairs: 1, drawn_with: nil)
    lists = (0...pairs).map { |n| pair_colors(n) }
    spots = (0...pairs).map { |n| pair_spots(n) }
    # Named for the Color, since its cartridge is made from the program as well as played.
    builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    builder.instance_eval do
      screen :tiled
      colors :cold, COLD
      sprites = lists.each_with_index.flat_map do |list, n|
        colors :"pair#{n}", list
        image :"first#{n}", width: 8, height: 8, data: shape.(list[1], list[2]), colors: :"pair#{n}"
        image :"second#{n}", width: 8, height: 8, data: shape.(list[2], list[1]), colors: :"pair#{n}"
        [sprite(:"one#{n}", at: spots[n][0], facing: { first: :"first#{n}" }),
         sprite(:"two#{n}", at: spots[n][1], facing: { second: :"second#{n}" })]
      end
      game_loop { sprites.each { |drawn| drawn.draw_with [drawn_with], showing: 0 } if drawn_with }
    end
    builder.finalize_program
    builder.program
  end

  # How many of the eight sprite palettes hold any colour, and how many the sprites on the screen
  # are drawn from.
  Palettes = Data.define(:holding_colors, :drawn_from)

  # A sprite table entry's down and across, which the Color keeps 16 and 8 past the screen's top
  # left: an entry outside these is off the screen, where the runtime puts a piece it hides.
  ON_SCREEN_DOWN = (1..159)
  ON_SCREEN_ACROSS = (1..167)

  # The low three bits of an entry's settings byte: which of the eight sprite palettes it draws from.
  PALETTE_BITS = 0x07

  # The Palettes after +frames+ of +program+, read in the emulator's colour memory (every palette the
  # game does not use is left all nought) and sprite table (four bytes an entry: down, across, tile,
  # settings).
  private def palettes_after(program, frames: 10)
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(program, title: "PALETTES")
    v = VBlank::Diagnostics::Verifier.new(rom, frames: frames)
    holding = v.palette(:sprites).each_slice(4).count { |list| list.any?(&:nonzero?) }
    entries = v.video_memories.fetch(:sprite_table).values.each_slice(4)
    on_screen = entries.select { |down, across, _, _| ON_SCREEN_DOWN.cover?(down) && ON_SCREEN_ACROSS.cover?(across) }
    Palettes.new(holding_colors: holding, drawn_from: on_screen.map { |*, settings| settings & PALETTE_BITS }.uniq.length)
  end

  # A pair's two pixels of each colour, the first sprite's then the second's, as the screen shows
  # them and as its list says they are.
  PairPixels = Data.define(:on_screen, :listed)

  # The PairPixels of each pair after +frames+ of +program+, read at +shape_pixels+ of each sprite.
  private def pair_pixels(program, pairs:, shape_pixels:, frames: 3)
    screen = game_player.run(program, frames: frames).screen
    (0...pairs).map do |n|
      list = pair_colors(n)
      on_screen = pair_spots(n).flat_map { |x, y| shape_pixels.map { |dx, dy| screen.pixel(x + dx, y + dy) } }
      PairPixels.new(on_screen: on_screen, listed: [list[1], list[2], list[2], list[1]].map { |color| shown(color) })
    end
  end

  # A pixel of each colour of a halves picture, and of a corner picture, from its top left.
  HALVES_PIXELS = [[1, 1], [6, 1]].freeze
  CORNER_PIXELS = [[0, 0], [6, 1]].freeze

  def test_two_pictures_of_one_list_in_different_pixel_orders_share_one_palette
    program = two_orders_game

    pair_pixels(program, pairs: 1, shape_pixels: HALVES_PIXELS).each { |pair| assert_equal pair.listed, pair.on_screen }
    assert_equal Palettes.new(holding_colors: 1, drawn_from: 1), palettes_after(program)
  end

  # Drawn with another list, each picture's own colours and that list's are a palette each, shared.
  def test_two_pictures_drawn_with_one_other_list_share_its_palette
    program = two_orders_game(drawn_with: :cold)
    screen = game_player.run(program, frames: 3).screen

    assert_equal [shown(:blue), shown(:white)], [screen.pixel(41, 25), screen.pixel(46, 25)], "the first sprite"
    assert_equal [shown(:white), shown(:blue)], [screen.pixel(81, 25), screen.pixel(86, 25)], "the second sprite"
    assert_equal Palettes.new(holding_colors: 2, drawn_from: 1), palettes_after(program), "their own colours, and :cold"
  end

  # Five pairs in their own orders need ten palettes, more than the eight, and all ten sprites are
  # on the screen at once, so lending the eight cannot draw them all in their colours. Shared, a
  # palette a pair, they fit in five, for a tile more each.
  def test_pictures_past_the_eight_palettes_in_their_own_orders_share_them_and_fit
    program = two_orders_game(shape: CORNER, pairs: 5)

    pair_pixels(program, pairs: 5, shape_pixels: CORNER_PIXELS).each_with_index do |pair, n|
      assert_equal pair.listed, pair.on_screen, "pair #{n}"
    end
    assert_equal Palettes.new(holding_colors: 5, drawn_from: 5), palettes_after(program)
  end

  # One pair has palettes to spare, so sharing one would spend a tile and buy nothing: each picture
  # keeps its own order, and its own palette.
  def test_pictures_with_palettes_to_spare_keep_their_own_orders
    program = two_orders_game(shape: CORNER)

    pair_pixels(program, pairs: 1, shape_pixels: CORNER_PIXELS).each { |pair| assert_equal pair.listed, pair.on_screen }
    assert_equal Palettes.new(holding_colors: 2, drawn_from: 2), palettes_after(program)
  end
end
