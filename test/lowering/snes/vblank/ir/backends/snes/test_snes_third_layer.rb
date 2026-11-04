# frozen_string_literal: true

require "test_helper"

# A STATUS BAR ON THE THIRD LAYER, beside two backgrounds (SNES::Lowering::Picture
# .status_bar_on_third_layer?): its tiles are four-colour, from eight lists of three colours, and
# a bar whose art does not fit that is refused by name. A bar of many lists, its cells changed as
# a score's are, is drawn as the interpreter draws it on every pass.
class TestSNESThirdLayer < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  # Five tiles of three colours each, none shared, so the bar takes five of its eight lists and
  # two of the backgrounds' lists hold them.
  BAR_COLORS = [
    [0x001F, 0x03E0, 0x7C00], [0x7FFF, 0x03FF, 0x7C1F], [0x7FE0, 0x0010, 0x0200],
    [0x4000, 0x4210, 0x0210], [0x4010, 0x2108, 0x5294]
  ].freeze
  PIXEL_KEYS = %w[x y z w].freeze

  def test_a_bar_of_five_lists_and_a_changing_cell_is_drawn_as_the_interpreter_draws_it
    run = SNES::CheckedRun.new.run(game_with_bar(BAR_COLORS), frames: 12)

    assert_operator run[:tick], :>=, 10
  end

  def test_a_bar_tile_of_four_colours_is_refused_naming_the_bar_and_the_tile
    colors = [[0x001F, 0x03E0, 0x7C00, 0x7FFF]]
    error = assert_raises(SNES::Art::BarArtTooColorful) { SNES.new.build(game_with_bar(colors)) }

    assert_match(/:score/, error.message)
    assert_match(/:bar_art_0/, error.message)
    assert_match(/four colours/, error.message)
  end

  def test_a_bar_of_more_colours_than_eight_lists_hold_is_refused
    colors = Array.new(9) { |n| [(n + 1) * 0x0421, (n + 1) * 0x0401, (n + 1) * 0x0021] }
    error = assert_raises(SNES::Art::BarArtTooColorful) { SNES.new.build(game_with_bar(colors)) }

    assert_match(/8 lists of 3 colours/, error.message)
  end

  # An arena of two colours, a cloud layer over it, and a bar of one tile for each list of colours
  # in +bar_colors+, each tile those colours in stripes. One of the bar's cells takes the last tile
  # on the fifth pass.
  private def game_with_bar(bar_colors)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:ground, "a" => 0x0118, "b" => 0x0231) { "abababab\n" * 8 }
      image(:cloud, "." => :transparent, "w" => :white) { "ww....ww\n" * 8 }
      bar_colors.each_with_index do |colors, n|
        keys = PIXEL_KEYS.first(colors.length)
        image(:"bar_art_#{n}", keys.zip(colors).to_h) { "#{(keys * 8).join[0, 8]}\n" * 8 }
      end
      tiles :arena_tiles, "#" => :ground
      tiles :cloud_tiles, "o" => :cloud
      tiles :bar_tiles, bar_colors.each_index.to_h { |n| [n.to_s, :"bar_art_#{n}"] }
      background :arena, tiles: :arena_tiles, map: Array.new(32) { "#" * 32 }
      clouds = background :clouds, tiles: :cloud_tiles, map: Array.new(32) { "o   " * 8 }
      row = bar_colors.each_index.map(&:to_s).join
      bar = status_bar :score, tiles: :bar_tiles, map: [(row * 32)[0, 32], (row * 32)[0, 32]], top: 208
      tick = var :tick, 0
      game_loop do
        tick += 1
        clouds.scroll_by 1, 1
        bar.set_tile 3, 1, (bar_colors.length - 1).to_s if tick == 5
      end
    end
    b.finalize_program
    b.program.copy.tap { |program| program.console = :snes }
  end
end
