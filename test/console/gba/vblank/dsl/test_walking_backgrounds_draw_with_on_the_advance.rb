# frozen_string_literal: true

require "test_helper"
require "differential"

# TWO LAYERS THAT WALK BETWEEN AREAS TOGETHER, EACH TOLD draw_with: two backgrounds at once, which
# the Color cannot show (the one-layer games are in
# test/all/vblank/dsl/test_walking_background_draws_with.rb).
#
# Each area hands its groups of colours out again, so a group one layer's list is in, in one area,
# can be the other layer's in the next. The ground covers the left half and the scenery the right.
# In the shrine the ground draws from two lists and the scenery from one; in the clearing each
# draws from one. In the clearing the scenery borrows a list first and the ground after, and the
# scenery keeps the list it borrowed.
class TestWalkingBackgroundsDrawWithOnTheAdvance < Minitest::Test
  include Differential

  STRIPE = Array.new(64) { |i| (i % 8) < 4 ? 1 : 2 }.freeze

  private def two_layers_walking
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      { x_shrine_a: %i[red green], x_shrine_b: %i[blue white], x_clearing: %i[red blue],
        y_shrine: %i[green white], y_clearing: %i[yellow cyan], y_dark: %i[magenta orange],
        x_dark: %i[white green] }.each { |name, two| colors name, [:transparent, *two] }
      %i[x_shrine_a x_shrine_b x_clearing y_shrine y_clearing].each do |list|
        image list, width: 8, height: 8, colors: list, places: STRIPE
      end
      tiles :ground_shrine, "a" => :x_shrine_a, "b" => :x_shrine_b
      tiles :ground_clearing, "a" => :x_clearing
      tiles :scenery_shrine, "#" => :y_shrine
      tiles :scenery_clearing, "#" => :y_clearing
      left = Array.new(20) { ("a" * 14) + "b" + (" " * 15) }
      left_clearing = Array.new(20) { ("a" * 15) + (" " * 15) }
      right = Array.new(20) { (" " * 15) + ("#" * 15) }
      ground = background :ground, tiles: { shrine: :ground_shrine, clearing: :ground_clearing },
                                   map: { shrine: { hall: left }, clearing: { glade: left_clearing } }
      scenery = background :scenery, tiles: { shrine: :scenery_shrine, clearing: :scenery_clearing },
                                     map: { shrine: { arch: right }, clearing: { trees: right } }
      tick = var :tick, 0
      room = var :room, 0
      game_loop do
        tick += 1
        room = 1 if tick == 3
        scenery.draw_with({ y_clearing: :y_dark }) if tick == 5
        ground.draw_with({ x_clearing: :x_dark }) if tick == 8
        ground.show_map room
        scenery.show_map room
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_two_walking_layers_each_keep_the_list_they_borrowed
    screen = game_player.run(two_layers_walking, frames: 11).screen

    assert_equal shown(:white), screen.pixel(1, 1), "the ground, with :x_dark"
    assert_equal shown(:magenta), screen.pixel(121, 1), "the scenery, still with :y_dark"
  end

  def test_the_console_keeps_two_walking_layers_borrowed_lists_apart
    assert_backends_agree(two_layers_walking, frames: [4, 7, 11], name: "AREADW2")
  end

  # A FIELD OF MANY SMALL LISTS AND A HOUSE THAT BORROWS ONE. The field's sixteen lists of two
  # colours each share groups of sixteen between them, and only fit the console that way: a group
  # each would be more groups than there are. Only the house's list is ever drawn with another, so
  # only it needs a group to itself. The Color holds fewer lists at once than the field has, so
  # this is the Advance's.
  FIELD_LISTS = 16

  private def a_field_and_a_house
    count = FIELD_LISTS
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      field = (0...count).to_h do |n|
        name = :"field#{n}"
        colors name, [:transparent, Color.rgb(n + 1, 0, 31 - n), Color.rgb(0, n + 1, 10)]
        image name, width: 8, height: 8, colors: name, places: STRIPE
        [(n + 65).chr, name]
      end
      colors :house_own, %i[transparent red green]
      colors :house_dark, %i[transparent yellow cyan]
      image :house_floor, width: 8, height: 8, colors: :house_own, places: STRIPE
      tiles :field_tiles, field
      tiles :house_tiles, "#" => :house_floor
      meadow = Array.new(20) { field.keys.join + field.keys.first(10).join }
      grid = Array.new(20) { "#" * 30 }
      ground = background :ground, tiles: { field: :field_tiles, house: :house_tiles },
                                   map: { field: { meadow: meadow }, house: { hall: grid } }
      tick = var :tick, 0
      room = var :room, 0
      game_loop do
        tick += 1
        room = 1 if tick == 3
        ground.draw_with({ house_own: :house_dark }) if tick == 5
        ground.draw_with :own if tick == 8
        ground.show_map room
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_a_house_borrows_a_list_beside_a_field_of_many_lists
    seen = ->(frames) { game_player.run(a_field_and_a_house, frames: frames).screen.then { |s| [s.pixel(1, 1), s.pixel(5, 1)] } }

    assert_equal [shown(:yellow), shown(:cyan)], seen.call(7), "the house with :house_dark"
    assert_equal [shown(:red), shown(:green)], seen.call(11), "the house's own colours again"
  end

  def test_the_console_draws_the_field_and_the_borrowing_house_the_same_way
    assert_backends_agree(a_field_and_a_house, frames: [2, 7, 11], name: "AREADWF")
  end
end
