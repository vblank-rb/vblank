# frozen_string_literal: true

require "test_helper"
require "differential"

# WHAT A SCENE'S ARRIVAL COPY SENDS INTO VIDEO MEMORY, on the console. A scene's own tile pictures
# go in as it takes over, and on a scene that loads first that copy has one pass to itself. Two
# stretches of the room its pictures sit in hold none of them:
#
# - the room a background walking between areas keeps for its biggest area, past the end of the
#   first area's tiles, which are the only ones in place as the scene arrives; and
# - the gap left behind a layer that counts its tiles from the next of the four 16K marks.
#
# Copying nothing into those stretches is time the pass gets back, and the way to see that the
# copy left them alone is that they still hold what the scene before put there.
class TestSceneArrivalCopy < Minitest::Test
  include Differential

  NEAR = 16   # the first area's tiles
  FAR = 900   # the other area's: the room the walking background keeps is this many
  TOP = 650   # the layer over it, too many to count from the mark below where it lands
  COLUMNS = 32
  HANDED_OVER_AT = 4

  # Inside the room kept for the far area, and past the near area's tiles.
  KEPT_FOR_ANOTHER_AREA = 0x0600_4000
  # Past the far area's room, and below the 16K mark the top layer counts from, at 32K; the
  # title's tiles reach a little further than this.
  BEHIND_A_MARK = 0x0600_7C00

  # Tile +n+ of a set, which no other tile of the game is, nor any of them mirrored: its top-left
  # corner is +mark+ and the rest of it is +n+ in binary, in white on black.
  def numbered_tile(n, mark)
    (0...64).map do |at|
      next mark if at.zero?

      n[(at - 1) % 16].zero? ? :black : :white
    end
  end

  # A map showing each of +count+ tiles once, COLUMNS to a row, and starting +blank_rows+ down.
  def every_tile(count, blank_rows: 0)
    rows = (0...count).each_slice(COLUMNS).map { |row| row + ([nil] * (COLUMNS - row.length)) }
    ([[nil] * COLUMNS] * blank_rows) + rows
  end

  # A title whose one background fills the bottom 32K of tile memory, handed over to a scene that
  # loads first: a ground walking between a near area of few tiles and a far one of many, and a
  # layer over its bottom half whose tiles have to count from the 16K mark at 32K.
  private def hand_over
    test = self
    b = Builder.new
    b.instance_eval do
      screen :tiled
      { near: [NEAR, :green, 0], far: [FAR, :red, 1000], top: [TOP, :blue, 2000] }.each do |set, (count, mark, from)|
        count.times { |n| image(:"#{set}_#{n}", width: 8, height: 8, data: test.numbered_tile(from + n, mark)) }
        tiles set, (0...count).to_h { |n| [n, :"#{set}_#{n}"] }
      end
      cover = (0...FAR).map { |n| :"far_#{n}" } + (0...(1000 - FAR)).map { |n| :"top_#{n}" }
      tiles :cover, cover.each_with_index.to_h { |name, n| [n, name] }

      state = var :state, 0
      pass = var :pass, 0
      scene(:title) { background :cover, tiles: :cover, map: test.every_tile(1000) }
      scene(:play, loads_first: true) do
        background :ground, tiles: { near: :near, far: :far },
                            map: { near: { room: test.every_tile(NEAR) }, far: { field: test.every_tile(FAR) } }
        background :top, tiles: :top, map: test.every_tile(TOP, blank_rows: 10)
      end
      game_loop do
        pass += 1
        state = 1 if pass == test.class::HANDED_OVER_AT
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_the_arrival_copy_leaves_the_stretches_no_tile_of_the_scene_is_in
    rom = assemble_rom(hand_over, name: "ARRIVE")
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 1, vars: rom.var_addresses)
    seen = (1..(HANDED_OVER_AT + 4)).map do
      reader.step
      [reader.var(:state), reader.mem16(KEPT_FOR_ANOTHER_AREA), reader.mem16(BEHIND_A_MARK)]
    end
    title = seen.reverse.find { |state, *| state.zero? }
    play = seen.last

    refute_includes title.drop(1), 0, "the title's tiles are in both stretches: #{seen}"
    assert_equal 1, play.first, "the play scene took over: #{seen}"
    assert_equal title.drop(1), play.drop(1), "the arrival copy sent nothing into either stretch: #{seen}"
  end

  def test_the_scene_arrives_whole
    assert_backends_agree(hand_over, frames: [HANDED_OVER_AT + 2, HANDED_OVER_AT + 4], name: "ARRIVE")
  end
end
