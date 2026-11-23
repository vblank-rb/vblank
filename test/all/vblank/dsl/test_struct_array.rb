# frozen_string_literal: true

require "test_helper"

VBlank.require_game_file "../../../struct_array_parts"
require "struct_array_plain_parts"

# An Array of Structs that game code changes is a pool (DSL::StructArray), and plays as the same
# game written with `pool`. Each test plays a tiny game and reads what it leaves, on every lowering.
class TestStructArray < Minitest::Test
  private def played(frames:, &block)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(block, checked: false))
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: frames)
    player
  end

  # The live things' fields, each as [x, y, vy], in no order a slot would give.
  private def live_sparks(player)
    xs, ys, vys = %i[x y vy].map { |field| player.pool(:sparks, field) }
    xs.zip(ys, vys).reject { |x, _, _| x.nil? }.sort
  end

  # A spark a pass, at 10 pixels a pass across, falling 1.5 a pass; the oldest goes when four
  # are up, and one past 5 goes too.
  def test_an_array_of_structs_plays_as_the_same_game_written_with_pool
    structs = played(frames: 6) do
      sparks = Array.new(capacity: 4)
      frame = 0
      game_loop do
        frame += 1
        sparks.shift if sparks.size == 4
        sparks << Spark.new(frame * 10, 0.0, 1.5)
        sparks.each { |s| s.y += s.vy }
        sparks.delete_if { |s| s.y > 5 }
      end
    end
    pooled = played(frames: 6) do
      sparks = pool :sparks, x: 0, y: 0.0, vy: 0.0, capacity: 4, on_full: :recycle_oldest
      frame = 0
      game_loop do
        frame += 1
        sparks.spawn x: frame * 10, y: 0.0, vy: 1.5
        sparks.each { |s| s.y += s.vy }
        sparks.each { |s| s.remove if s.y > 5 }
      end
    end

    assert_equal live_sparks(pooled), live_sparks(structs)
    assert_equal [[40, 4.5, 1.5], [50, 3.0, 1.5], [60, 1.5, 1.5]], live_sparks(structs)
  end

  # Drops fall by their own method, two pixels a pass, drawn as 8x8 green squares. Two are
  # added on the first pass, so the picture shows them at y 6 after three passes
  # (a pass behind on the Advance, `framework_drawing_lag`).
  def test_a_struct_drawn_as_a_picture_shows_each_thing_and_runs_its_own_methods
    player = played(frames: 3 + framework_drawing_lag) do
      screen :tiled
      image(:drop, "#" => :green) { "########\n" * 8 }
      drops = Array.new(capacity: 4)
      started = 0
      game_loop do
        if started == 0
          drops << Drop.new(20, 0)
          drops << Drop.new(60, 0)
          started = 1
        end
        drops.each(&:fall)
      end
    end

    assert_equal [2 * (3 + framework_drawing_lag)] * 2, player.pool(:drops, :y).compact
    green = Color.resolve(:green)
    assert_equal green, player.screen.pixel(20, 6)
    assert_equal green, player.screen.pixel(67, 13)
    refute_equal green, player.screen.pixel(40, 6)
  end

  # The other verbs, each into a variable of its own: how many, how many past 25, whether any,
  # the position in the walk of the one at x 30, and the oldest left after one shift.
  def test_an_array_of_structs_counts_walks_and_empties_as_ruby_does
    player = played(frames: 1) do
      coins = Array.new(capacity: 8)
      many = 0
      past = 0
      some = 0
      none = 0
      at = -1
      oldest = 0
      newest = 0
      game_loop do
        [10, 20, 30, 40].each { |x| coins << Coin.new(x: x, worth: 1) }
        coins.shift
        many = coins.size
        past = coins.count { |coin| coin.x > 25 }
        some = 1 if coins.any?
        coins.each_with_index { |coin, position| at = position if coin.x == 30 }
        coins.each { |coin| oldest = coin.x if oldest == 0 }
        coins.reverse_each { |coin| newest = coin.x if newest == 0 }
        coins.clear
        none = 1 if coins.empty?
      end
    end

    assert_equal [3, 2, 1, 1, 20, 40, 1],
                 %i[many past some at oldest newest none].map { |name| player[name] }
  end

  # A part's Array in an instance variable, filled by another of its methods, named after the
  # part and the variable. Each bird falls by its own speed: 1, 2 and 3 a pass.
  def test_a_parts_array_of_structs_in_an_instance_variable_is_a_pool
    builder = Builder.new
    FlockPart.new(builder)
    builder.game_loop { builder.call(:flock_tick) }
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 3)

    birds = player.pool(:flock_part_birds, :x).zip(player.pool(:flock_part_birds, :y))

    assert_equal [[0, 3], [10, 6], [20, 9]], birds.reject { |x, _| x.nil? }.sort
  end

  # The Struct's file is not read as game code, so its `self.y += 2` is Ruby's own setter, which
  # the walk's object answers by changing the field.
  def test_a_structs_method_from_a_plain_file_changes_its_field
    player = played(frames: 3) do
      drops = Array.new(capacity: 2)
      started = 0
      game_loop do
        if started == 0
          drops << PlainDrop.new(5, 0)
          started = 1
        end
        drops.each(&:fall)
      end
    end

    assert_equal [6], player.pool(:drops, :y).compact
  end

  def test_an_array_of_structs_with_no_capacity_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        sparks = Array.new
        game_loop { sparks << Spark.new(1, 2, 3) }
      end
    end

    assert_match(/fixed number of things/, error.message)
  end

  def test_an_array_of_data_things_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        stones = Array.new(capacity: 4)
        game_loop { stones << Stone.new(x: 1) }
      end
    end

    assert_match(/cannot change its fields/, error.message)
  end

  def test_a_struct_put_in_with_a_field_left_empty_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        sparks = Array.new(capacity: 4)
        game_loop { sparks << Spark.new(1, 2) }
      end
    end

    assert_match(/no value for `vy`/, error.message)
  end

  def test_an_array_method_a_pool_has_no_meaning_for_is_refused_by_name
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        sparks = Array.new(capacity: 4)
        game_loop do
          sparks << Spark.new(1, 2, 3)
          sparks.sort_by!(&:x)
        end
      end
    end

    assert_match(/does not answer `sort_by!`/, error.message)
  end

  def test_drawn_as_on_a_struct_with_no_place_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        Flag.class_eval { drawn_as :drop }
      end
    end

    assert_match(/has no `x` or `y`/, error.message)
  end
end
