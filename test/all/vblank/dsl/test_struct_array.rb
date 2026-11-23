# frozen_string_literal: true

require "test_helper"

VBlank.require_game_file "../../../struct_array_parts"
require "struct_array_plain_parts"
require "fixtures/own_struct_games"

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

  # `Spark = Struct.new(...)` in the game block makes a class for that build alone: building it
  # twice warns of no constant set twice, and leaves no constant behind.
  def test_a_struct_the_game_block_makes_is_its_own_on_every_build
    original = $stderr
    $stderr = StringIO.new
    falls = Array.new(2) do
      player = game_player
      player.run(OwnStructGames::FALLING.program(console: VBlank::Testing.console), frames: 3)
      player.pool(:sparks, :y).compact
    end
    warned = $stderr.string
    $stderr = original

    assert_equal [[3], [3]], falls
    refute_match(/already initialized/, warned)
    refute OwnStructGames.const_defined?(:Spark, false)
  end

  # Three things, the first and the third alike. Walked against each other, `==` and `eql?` hold
  # for two things whose fields are all equal, as a Struct's do, and `equal?` for a thing and itself.
  def test_things_compare_as_rubys_structs_do
    player = played(frames: 1) do
      sparks = Array.new(capacity: 4)
      same = 0
      alike = 0
      itself = 0
      game_loop do
        sparks << Spark.new(1, 2, 3)
        sparks << Spark.new(4, 5, 6)
        sparks << Spark.new(1, 2, 3)
        sparks.each { |a| sparks.each { |b| same += 1 if a == b } }
        sparks.each { |a| sparks.each { |b| alike += 1 if a.eql?(b) } }
        sparks.each { |a| sparks.each { |b| itself += 1 if a.equal?(b) } }
      end
    end

    assert_equal [5, 5, 3], %i[same alike itself].map { |name| player[name] }
  end

  # A thing kept past its walk is still that thing: `pick` is the spark at x 10, read after the
  # walk, and a change to it after the walk changes that spark.
  def test_a_thing_kept_past_its_walk_is_still_that_thing
    player = played(frames: 1) do
      sparks = Array.new(capacity: 4)
      picked = 0
      game_loop do
        sparks << Spark.new(10, 0, 0)
        sparks << Spark.new(20, 0, 0)
        pick = nil
        sparks.each { |s| pick = s if s.x == 10 }
        picked = pick.x
        pick.y = 7
      end
    end

    assert_equal 10, player[:picked]
    assert_equal [[10, 7, 0], [20, 0, 0]], live_sparks(player)
  end

  # The Struct's file is not read as game code, and its methods run as game code all the same:
  # Ruby's `?:` on a test the game makes picks a side as the game plays. From x 4: 5, 6, then 9.
  def test_a_structs_method_from_a_plain_file_asks_its_tests_as_the_game_plays
    player = played(frames: 3) do
      movers = Array.new(capacity: 2)
      started = 0
      game_loop do
        if started == 0
          movers << PlainMover.new(4)
          started = 1
        end
        movers.each(&:step)
      end
    end

    assert_equal [9], player.pool(:movers, :x).compact
  end

  def test_a_structs_method_made_with_define_method_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        movers = Array.new(capacity: 2)
        game_loop { movers << PlainBlockMover.new(4) }
      end
    end

    assert_match(/struct_array_plain_parts\.rb:\d+/, error.message)
    assert_match(/`def`/, error.message)
  end

  # Filled only while building, the Array stays Ruby's, and its `capacity:` is only room.
  def test_an_array_filled_only_while_building_stays_rubys
    player = played(frames: 1) do
      walls = Array.new(capacity: 4)
      walls << Spark.new(1, 2, 3)
      walls << Spark.new(4, 5, 6)
      total = 0
      game_loop { walls.each { |wall| total += wall.x } }
    end

    assert_equal 5, player[:total]
  end

  # A thing kept in a local first, or walked from another Array, makes an Array of Structs too.
  def test_a_thing_put_in_from_a_local_or_another_array_makes_an_array_of_structs
    player = played(frames: 1) do
      sparks = Array.new(capacity: 4)
      fallen = Array.new(capacity: 4)
      game_loop do
        spark = Spark.new(10, 0, 0)
        sparks << spark
        sparks << Spark.new(20, 9, 0)
        sparks.each { |s| fallen << s if s.y > 5 }
      end
    end

    assert_equal [[10, 0, 0], [20, 9, 0]], live_sparks(player)
    assert_equal [20], player.pool(:fallen, :x).compact
  end

  # A thing made and changed in one line with `tap` before it goes in is still a thing.
  def test_a_thing_changed_with_tap_as_it_goes_in_makes_an_array_of_structs
    player = played(frames: 1) do
      sparks = Array.new(capacity: 4)
      game_loop do
        sparks.clear
        sparks << Spark.new(1, 0, 0).tap { |s| s.x = 9 }
      end
    end

    assert_equal [[9, 0, 0]], live_sparks(player)
  end

  # A fraction given to a field in a walk makes that field hold fractions, as a fraction put into
  # an Array of numbers does.
  def test_a_fraction_given_to_a_field_in_a_walk_makes_it_hold_fractions
    player = played(frames: 2) do
      sparks = Array.new(capacity: 4)
      started = 0
      game_loop do
        if started == 0
          sparks << Spark.new(10, 0, 0)
          started = 1
        end
        sparks.each do |s|
          s.vy = 0.5
          s.y += 0.5
        end
      end
    end

    assert_equal [[10, 1.0, 0.5]], live_sparks(player)
  end

  # A fraction from a method's answer goes into a field the build saw only whole numbers for: the
  # advice is in Ruby's words, `.to_f` where the thing is made.
  def test_a_fraction_the_build_cannot_see_is_refused_with_plain_ruby_advice
    error = assert_raises(ArgumentError) do
      played(frames: 1) do
        sparks = Array.new(capacity: 4)
        game_loop { sparks << Spark.new(1, 2, PlainSpeeds.half(self)) }
      end
    end

    assert_match(/`vy`/, error.message)
    assert_match(/`\.to_f`/, error.message)
    refute_match(/pool/, error.message)
  end

  # Two `shift`s during a walk take out the two oldest, as two outside one do.
  def test_two_shifts_in_a_walk_take_out_two_things
    player = played(frames: 1) do
      sparks = Array.new(capacity: 4)
      left = 0
      game_loop do
        [1, 2, 3, 4].each { |x| sparks << Spark.new(x, 0, 0) }
        sparks.each do |s|
          if s.x == 1
            sparks.shift
            sparks.shift
          end
        end
        left = sparks.size
      end
    end

    assert_equal 2, player[:left]
    assert_equal [3, 4], live_sparks(player).map(&:first)
  end

  # An arrow whose picture faces right, turned left: the picture is mirrored, so its painted left
  # half shows on the right.
  def test_a_thing_drawn_facing_right_faces_left_as_its_picture_mirrored
    player = played(frames: 2) do
      screen :tiled
      image(:arrow, "#" => :green, "." => :transparent) { "####....\n" * 8 }
      arrows = Array.new(capacity: 2)
      started = 0
      game_loop do
        if started == 0
          arrows << Arrow.new(20, 0)
          started = 1
        end
        arrows.each { |arrow| arrow.face :left }
      end
    end

    green = Color.resolve(:green)
    assert_equal green, player.screen.pixel(27, 4)
    refute_equal green, player.screen.pixel(20, 4)
  end

  # Two tiles at one place, each in its Struct's layer: the one in the front layer shows, though
  # its Array is made last.
  def test_a_thing_drawn_in_a_layer_stands_at_that_layers_depth
    player = played(frames: 2) do
      screen :tiled
      layers :back, :front
      image(:green_tile, "#" => :green) { "########\n" * 8 }
      image(:red_tile, "#" => :red) { "########\n" * 8 }
      fronts = Array.new(capacity: 1)
      backs = Array.new(capacity: 1)
      started = 0
      game_loop do
        if started == 0
          backs << BackTile.new(20, 0)
          fronts << FrontTile.new(20, 0)
          started = 1
        end
      end
    end

    assert_equal Color.resolve(:red), player.screen.pixel(23, 4)
  end

  # A routine runs wherever it is called, so its `shift`, called twice in a walk, takes out two too.
  def test_two_shifts_by_a_routine_called_in_a_walk_take_out_two_things
    player = played(frames: 1) do
      sparks = Array.new(capacity: 4)
      func(:drop_oldest) { sparks.shift }
      game_loop do
        [1, 2, 3, 4].each { |x| sparks << Spark.new(x, 0, 0) }
        sparks.each do |s|
          if s.x == 1
            call :drop_oldest
            call :drop_oldest
          end
        end
      end
    end

    assert_equal [3, 4], live_sparks(player).map(&:first)
  end

  # Ruby would grow the Array, and a console cannot, so the push stops the game, as a push onto
  # a full Array of numbers does, in the same words.
  def test_a_push_onto_a_full_array_of_structs_stops_the_game_naming_it
    error = assert_raises(VBlank::IR::ProgramError) do
      played(frames: 2) do
        sparks = Array.new(capacity: 4)
        game_loop { 6.times { |n| sparks << Spark.new(n, 0, 0) } }
      end
    end

    assert_match(/`sparks` is full: it has room for 4/, error.message)
    refute_match(/\b(list|pool)\b/, error.message)
  end

  # The push that fits does what Ruby's does, and the game goes on.
  def test_a_push_tested_against_the_size_keeps_the_first_four
    player = played(frames: 2) do
      sparks = Array.new(capacity: 4)
      game_loop { 6.times { |n| sparks << Spark.new(n, 0, 0) if sparks.size < 4 } }
    end

    assert_equal [0, 1, 2, 3], live_sparks(player).map(&:first)
  end

  # A thing taken out inside a walk keeps its place until the walk ends, so a push after it in
  # the same walk finds no room where Ruby would. That stops the game saying so, never a push
  # that answers differently from Ruby.
  def test_a_push_in_a_walk_with_room_only_from_that_walk_stops_saying_so
    error = assert_raises(VBlank::IR::ProgramError) do
      played(frames: 1) do
        sparks = Array.new(capacity: 4)
        4.times { |n| sparks << Spark.new(n, 0, 0) } if sparks.empty?
        game_loop do
          sparks.each do |s|
            if s.x == 0
              sparks.shift
              sparks << Spark.new(9, 0, 0)
            end
          end
        end
      end
    end

    assert_match(/`sparks` has no room yet/, error.message)
    assert_match(/inside a walk/, error.message)
    assert_match(/after the walk/, error.message)
  end

  # A push in a walk of an Array with room joins it at once, as Ruby's does: the newest, seen
  # by every question after it, and by the walks that start after it; the walk it is in does
  # not visit it.
  def test_a_push_in_a_walk_with_room_is_one_of_the_things_at_once
    player = played(frames: 1) do
      sparks = Array.new(capacity: 4)
      visited = 0
      nines = 0
      newest = 0
      2.times { |n| sparks << Spark.new(n, 0, 0) } if sparks.empty?
      game_loop do
        sparks.each do |s|
          visited += 1
          if s.x == 0
            sparks << Spark.new(9, 0, 0)
            nines = sparks.count { |t| t.x == 9 }
            sparks.reverse_each { |t| newest = t.x if newest == 0 }
          end
        end
      end
    end

    assert_equal [0, 1, 9], live_sparks(player).map(&:first)
    assert_equal [2, 1, 9], [player[:visited], player[:nines], player[:newest]]
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
          sparks.rotate!
        end
      end
    end

    assert_match(/does not answer `rotate!`/, error.message)
  end

  # Four sparks put in out of order, sorted each pass by y: the smallest first, the biggest first
  # by minus the field, and the biggest first with `reverse!`. The walk after the sort reads them
  # in that order. Two have the same y, and keep the order they were put in.
  def test_sort_by_puts_the_things_in_order_of_a_field_as_ruby_does
    player = played(frames: 2) do
      up = Array.new(capacity: 4)
      down = Array.new(capacity: 4)
      turned = Array.new(capacity: 4)
      first_up = 0
      first_down = 0
      first_turned = 0
      second_up = 0
      started = 0
      game_loop do
        if started == 0
          [[1, 30], [2, 10], [3, 40], [4, 10]].each do |x, y|
            up << Spark.new(x, y, 0)
            down << Spark.new(x, y, 0)
            turned << Spark.new(x, y, 0)
          end
          started = 1
        end
        up.sort_by! { |s| s.y }
        down.sort_by! { |s| -s.y }
        turned.sort_by!(&:y).reverse!
        first_up = 0
        second_up = 0
        up.each_with_index do |s, at|
          first_up = s.x if at == 0
          second_up = s.x if at == 1
        end
        first_down = 0
        down.each { |s| first_down = s.x if first_down == 0 }
        first_turned = 0
        turned.each { |s| first_turned = s.x if first_turned == 0 }
      end
    end

    assert_equal [2, 4, 3, 3], %i[first_up second_up first_down first_turned].map { |name| player[name] }
  end

  def test_sort_by_on_an_empty_array_leaves_it_empty
    player = played(frames: 2) do
      sparks = Array.new(capacity: 4)
      many = -1
      game_loop do
        sparks << Spark.new(1, 2, 3) if many > 5 # never: the Array stays empty
        sparks.sort_by! { |s| s.y }
        many = sparks.size
      end
    end

    assert_equal 0, player[:many]
  end

  def test_sort_by_in_a_walk_of_the_same_array_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        sparks = Array.new(capacity: 4)
        game_loop do
          sparks << Spark.new(1, 2, 3)
          sparks.each { |_s| sparks.sort_by!(&:y) }
        end
      end
    end

    assert_match(/after the walk ends/, error.message)
  end

  def test_sort_by_a_block_that_is_not_one_field_is_refused
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        sparks = Array.new(capacity: 4)
        game_loop do
          sparks << Spark.new(1, 2, 3)
          sparks.sort_by! { |s| s.x + s.y }
        end
      end
    end

    assert_match(/sorts by one number/, error.message)
  end

  def test_sort_with_no_field_is_refused_naming_sort_by
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      played(frames: 1) do
        sparks = Array.new(capacity: 4)
        game_loop do
          sparks << Spark.new(1, 2, 3)
          sparks.sort!
        end
      end
    end

    assert_match(/`sort_by!`/, error.message)
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
