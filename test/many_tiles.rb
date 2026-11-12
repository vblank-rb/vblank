# frozen_string_literal: true

require "test_helper"

# Backgrounds of many different tiles, or of many lists of colours, for the tests of what a console
# does when a game's tiles or colours together are more than it holds at once
# (test/all/vblank/builder/test_scene_backgrounds.rb, test/all/vblank/builder/test_background_tile_sets.rb).
module ManyTiles
  # Tiles a row of such a map holds, and so how wide it is.
  ACROSS = 20

  # An 8×8 tile drawn in all four places of its list: a quarter of the tile each.
  QUARTERS = Array.new(64) { |i| 1 + ((i % 8) / 4) + (2 * ((i / 8) / 4)) }.freeze

  # THE CORNER THAT TELLS A TILE FROM ANOTHER ONE TURNED ROUND: three pixels at the bottom left,
  # [column, row] each, drawn in every tile. A console that turns a tile as it draws it keeps one
  # tile for two that are each other mirrored or upside down, and a number in binary read backwards
  # is another number. With this corner, a tile turned any way has it in another corner, where no
  # other tile here has it unless the two are the same tile.
  CORNER = Ractor.make_shareable([[0, 7], [1, 7], [0, 6]])

  module_function

  # Whether the pixel at +col+, +row+ of the tile numbered +bits+ is drawn: a bit of the number,
  # along its first rows, or the corner.
  def drawn?(bits, col, row) = bits[(row * 8) + col] == 1 || CORNER.include?([col, row])

  # Declare +count+ tiles in +builder+, as images named +prefix+ and a number and a tileset named
  # +prefix+, each one +color+ on black in a pattern no other tile numbered +from+ to +from+ +
  # +count+ has, however either is turned: its number in binary, a pixel a bit, along its first
  # rows, and CORNER. Hands back the map that shows each of them once, ACROSS to a row, keyed by its
  # number in the set.
  def declare(builder, prefix, count, color, from: 0)
    keys = (0...count).to_h do |k|
      name = :"#{prefix}_#{k}"
      bits = from + k
      art = (0...8).map { |row| (0...8).map { |col| ManyTiles.drawn?(bits, col, row) ? "#" : "." }.join }.join("\n")
      builder.image(name, "#" => color, "." => :black) { art }
      [k, name]
    end
    builder.tiles(prefix, keys)
    (0...count).each_slice(ACROSS).map { |row| row + ([nil] * (ACROSS - row.length)) }
  end

  # The squares across and down a picture of #declare_sprite_pictures, a hundred tiles in all.
  PICTURE_SQUARES = 10

  # Declare in +builder+ +pictures+ sprite pictures of PICTURE_SQUARES × PICTURE_SQUARES tiles each,
  # named +prefix+ and a number, every tile +color+ on black in the pattern #declare gives tile
  # +from+ and on: no two tiles alike across pictures declared from places that do not overlap.
  # Hands back their names, for a sprite's `frames:`.
  def declare_sprite_pictures(builder, prefix, pictures, color, from: 0)
    across = PICTURE_SQUARES * 8
    Array.new(pictures) do |which|
      first = from + (which * PICTURE_SQUARES * PICTURE_SQUARES)
      art = (0...across).map do |y|
        (0...across).map do |x|
          bits = first + ((y / 8) * PICTURE_SQUARES) + (x / 8)
          ManyTiles.drawn?(bits, x % 8, y % 8) ? "#" : "."
        end.join
      end.join("\n")
      name = :"#{prefix}_#{which}"
      builder.image(name, "#" => color, "." => :black) { art }
      name
    end
  end

  # Declare in +builder+ a tile for each of +lists+ — four colours each, place 0 see-through — drawn
  # by place in all four of its list's places (QUARTERS), for the tests of what a console does when
  # a game draws from more lists of colours than it holds at once. The lists and images are named
  # +prefix+ and a number, the tileset +prefix+. Hands back a row of a map showing each tile once.
  def declare_listed(builder, prefix, lists)
    lists.each_with_index do |list, n|
      builder.colors(:"#{prefix}_list#{n}", list)
      builder.image(:"#{prefix}_tile#{n}", width: 8, height: 8, colors: :"#{prefix}_list#{n}", places: QUARTERS)
    end
    builder.tiles(prefix, lists.each_index.to_h { |n| [n.to_s, :"#{prefix}_tile#{n}"] })
    lists.each_index.map(&:to_s).join
  end
end
