# frozen_string_literal: true

require "test_helper"

# A game that keeps up until its collections fill, said at build time from a measurement.
#
# A list or a pool is sized for the worst moment of a game and walked item by item every frame,
# so it keeps up through development and falls behind in the one session that fills it. The
# build runs each scene again with every collection held at its capacity and says which ones
# that run walked most, with the frame rate it measured.
class TestFullCollections < Minitest::Test
  def setup = require_emulator!

  private def build(&block) = VBlank.build("FULL", console: :gba, out: nil, err: nil, &block)

  private def growths(rom) = VBlank::Diagnostics::Profiler.survey_scenes(rom, frames: 10).growths

  # A list of four that can hold 448, each item +divides+ divides.
  def heavy_list(game, name = :xs, divides: 12)
    game.instance_eval do
      xs = list name, capacity: 448
      total = 0
      4.times { |i| xs.push i }
      -> { xs.each { |x| repeat(divides) { total += (x * 7) / (total + 3) } } }
    end
  end

  def test_two_that_fall_behind_only_together_are_named_and_one_never_walked_is_not
    helper = self
    rom = build do
      screen :bitmap
      left = helper.heavy_list(self, :left, divides: 5)
      right = helper.heavy_list(self, :right, divides: 5)
      list :idle, capacity: 448
      game_loop do
        left.call
        right.call
      end
    end

    assert_equal [["list :left", "list :right"]], growths(rom).map { |growth| growth.collections.map(&:label).sort }
  end

  def test_a_list_walked_every_frame_is_named_with_its_measured_frame_rate
    err = StringIO.new
    helper = self
    VBlank.build("FULL", console: :gba, out: nil, err: err, profile: true) do
      screen :bitmap
      walk = helper.heavy_list(self)
      game_loop { walk.call }
    end

    assert_match(/keeps up at 60 frames a second now/, err.string)
    assert_match(/list :xs, which can hold 448/, err.string)
    assert_match(/runs at about \d+ frames a second/, err.string)
  end

  def test_a_pool_walked_every_frame_is_named
    rom = build do
      screen :bitmap
      sparks = pool :spark, x: 0, capacity: 64
      total = 0
      2.times { sparks.spawn(x: 1) }
      game_loop { sparks.each { |s| repeat(60) { total += (s.x * 7) / (total + 3) } } }
    end

    assert_equal [["pool :spark"]], growths(rom).map { |growth| growth.collections.map(&:label) }
  end

  def test_a_list_read_once_a_frame_beside_the_walk_is_not_named
    helper = self
    rom = build do
      screen :bitmap
      walk = helper.heavy_list(self)
      ys = list :ys, capacity: 448
      count = 0
      game_loop do
        walk.call
        count = ys.length
      end
    end

    assert_equal [["list :xs"]], growths(rom).map { |growth| growth.collections.map(&:label) }
  end

  def test_a_pool_held_full_and_never_walked_is_not_named
    helper = self
    rom = build do
      screen :bitmap
      left = helper.heavy_list(self, :left, divides: 5)
      right = helper.heavy_list(self, :right, divides: 5)
      pool :idle, x: 0, capacity: 64
      game_loop do
        left.call
        right.call
      end
    end

    assert_equal [["list :left", "list :right"]], growths(rom).map { |growth| growth.collections.map(&:label).sort }
  end

  def test_a_warning_with_nothing_to_name_still_gives_the_frame_rate
    err = StringIO.new
    VBlank.build("FULL", console: :gba, out: nil, err: err, profile: true) do
      screen :bitmap
      xs = list :xs, capacity: 448
      ys = list :ys, capacity: 448
      total = 0
      left = 0
      game_loop do
        left = xs.length + ys.length
        while left > 0
          repeat(12) { total += (left * 7) / (total + 3) }
          left -= 1
        end
      end
    end

    assert_match(/runs at about \d+ frames a second/, err.string)
    assert_match(/give the lists and pools a smaller capacity/, err.string)
    refute_match(/uses most/, err.string)
  end

  def test_no_more_than_a_few_collections_are_named
    rom = build do
      screen :bitmap
      lists = Array.new(8) { |i| list :"walked_#{i}", capacity: 448 }
      total = 0
      lists.each { |xs| xs.push 1 }
      game_loop { lists.each { |xs| xs.each { |x| total += (x * 7) / (total + 3) } } }
    end

    assert_equal 1, growths(rom).size
    assert_equal VBlank::Diagnostics::Profiler::COLLECTIONS_NAMED, growths(rom).first.collections.size
  end

  def test_a_scene_is_named_and_a_scene_without_the_walk_is_not
    helper = self
    rom = build do
      total = 0
      screen :bitmap
      walk = helper.heavy_list(self)
      var :state, 0
      scene(:title) { total += 1 }
      scene(:playing) { walk.call }
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end

    assert_equal [:playing], growths(rom).map(&:scene)
  end

  def test_a_walk_that_keeps_up_full_says_nothing
    rom = build do
      screen :bitmap
      xs = list :xs, capacity: 16
      total = 0
      game_loop { xs.each { |x| total += x } }
    end

    assert_empty growths(rom)
  end
end
