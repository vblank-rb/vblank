# frozen_string_literal: true

require "test_helper"
require "objspace"

# WHAT A FULL COLLECTION WALKS OF A GAME'S PICTURES AND SOUND. Ruby's garbage collector, when it
# marks everything, visits every slot of every Array it can reach, a number in each. A big game's
# pictures, tiles, maps, songs and recordings are millions of numbers, so held as Arrays they made
# each full collection several frames long, however little the game was doing. Held as binary
# Strings they are one object each, which the collector passes over without reading. So the slots a
# collection walks must not grow with the size of a game's art and sound.
#
# The game is made from its Ruby alone, as a written-out game is played: a game made with its
# program keeps the program, which holds the art as the build made it.
class TestRubyFrozenTables < Minitest::Test
  # The most more Array slots the big game may hold than the small one: its few tables of where each
  # picture starts and how big it is, and nothing that grows with the pixels and samples.
  MOST_MORE_SLOTS = 2_000

  private def built(&game)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval(&game)
    b.finalize_program
    b.program
  end

  # A picture +side+ pixels square drawn every pass, over a tune on a recorded instrument of
  # +samples+ samples.
  private def picture_and_recording(side, samples)
    built do
      screen :bitmap
      enable_sound
      image(:art, "#" => :green, "." => :blue, " " => :red) { Array.new(side) { |row| (row.even? ? "#. " : ".# ") * (side / 3) }.join("\n") }
      instrument :piano, pcm: [60, -60] * (samples / 2), rate: 8000, note: :C4
      song :tune do
        tempo 60
        voice(:lead, plays: :piano) { note :C4, :whole }
      end
      play_song :tune
      game_loop { blit :art, 4, 4 }
    end
  end

  # A background of +kinds+ different tiles over a map +cells+ cells square, scrolling every pass.
  private def tiled_field(kinds, cells)
    built do
      screen :tiled
      names = Array.new(kinds) { |k| :"tile_#{k}" }
      names.each_with_index do |name, k|
        image(name, "#" => :green, "." => :blue) { Array.new(8) { |row| (row + k).odd? ? "#......." : ".#######" }.join("\n") }
      end
      letters = (("a".."z").to_a + ("A".."Z").to_a).first(kinds)
      tiles :field_tiles, letters.zip(names).to_h
      field = background :field, tiles: :field_tiles, map: Array.new(cells) { |row| Array.new(cells) { |col| letters[(row + col) % kinds] }.join }
      across = var :across, 0
      game_loop do
        across += 1
        field.scroll_to across, 0
      end
    end
  end

  # Every Array slot reachable from the playing game, after two passes: what a full collection
  # visits of it, besides one visit for each object. Named classes and modules are not followed,
  # since the library is not the game's.
  private def array_slots_reachable(program)
    game = VBlank::IR::Backends::Ruby::LiveGame.new(VBlank::IR::Backends::Ruby.new.live_source(program))
    game.play(VBlank::Original::Unpacking::FrameLimitedPlayer.new(2))
    seen = {}.compare_by_identity
    stack = [game]
    slots = 0
    until stack.empty?
      object = stack.pop
      next if seen.key?(object)

      seen[object] = true
      slots += object.size if object.is_a?(Array)
      ObjectSpace.reachable_objects_from(object)&.each do |to|
        next if to.is_a?(ObjectSpace::InternalObjectWrapper) || (to.is_a?(Module) && to.name)

        stack << to
      end
    end
    slots
  end

  def test_a_bigger_picture_and_recording_add_no_slots_a_collection_walks
    small = array_slots_reachable(picture_and_recording(12, 200))
    big = array_slots_reachable(picture_and_recording(150, 40_000))

    assert_operator big - small, :<, MOST_MORE_SLOTS, "Array slots a full collection walks, big game over small"
  end

  def test_more_tiles_and_a_bigger_map_add_no_slots_a_collection_walks
    small = array_slots_reachable(tiled_field(2, 32))
    big = array_slots_reachable(tiled_field(40, 128))

    assert_operator big - small, :<, MOST_MORE_SLOTS, "Array slots a full collection walks, big game over small"
  end
end
