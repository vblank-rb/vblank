# frozen_string_literal: true

require "test_helper"

# Lists of fifteen colours no other list can share a set with, for the tests of each screen of a
# Super Nintendo game keeping its own eight sets of background colours.
module SceneColorLists
  module_function

  # Fifteen colours and see-through, numbered +n+.
  def full_list(n) = [:transparent, *(1..15).map { |place| VBlank::Graphics::Color.rgb(n, place * 2, 31 - place) }]

  # The first colour of list +n+, which the top left pixel of its tile shows.
  def first_color(n) = full_list(n)[1]

  # Declare in +builder+ a tile for each list of +numbers+, drawn in all fifteen of its colours, named
  # +prefix+ and a number; the tileset is +prefix+. Hands back a row of a map showing each tile once.
  def declare(builder, prefix, numbers)
    numbers.each do |n|
      builder.colors(:"#{prefix}_list#{n}", full_list(n))
      builder.image(:"#{prefix}_tile#{n}", width: 8, height: 8, colors: :"#{prefix}_list#{n}",
                                           places: Array.new(64) { |i| 1 + (i % 15) })
    end
    keys = numbers.each_index.map { |at| (at + 97).chr }
    builder.tiles(prefix, keys.zip(numbers).to_h { |key, n| [key, :"#{prefix}_tile#{n}"] })
    keys.join
  end
end
