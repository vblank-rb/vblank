# frozen_string_literal: true

require "test_helper"

# Tables grouped by level. A game whose data is more than the console can hold at once keeps each
# level's tables in a group of their own and loads one group at a time, as the console's own games
# loaded a level's data from the disc when the level began. Here: that a game reads what it loaded,
# whichever group a number worked out as it runs names, and that reading a table whose group is not
# loaded stops the game in plain words, since on a console holding one group at a time it would read
# another group's numbers.
class TestTableGroups < Minitest::Test
  FOREST = [11, 12, 13, 14].freeze
  CAVE = [-21, 22, -23, 24, 25, 26].freeze
  SKY = [31, 32].freeze

  # A game with the forest and cave tables in groups 0 and 1 of :levels, the sky in both, and a
  # table in no group. Each pass loads the group the variable +level+ starts at, then reads one entry of each table
  # its group holds into +seen+ and copies the whole of its map into a list.
  private def levels_game(level:, reads: %i[forest sky])
    b = Builder.new
    b.instance_eval do
      forest = table :forest, FOREST
      cave = table :cave, CAVE
      sky = table :sky, SKY
      always = table :always, [7, 8], width: :byte
      tables = { forest: forest, cave: cave, sky: sky }
      levels = table_groups :levels, { 0 => %i[forest sky], 1 => %i[cave sky] }
      at = var :level, level
      passes = var :passes, 0
      seen = reads.to_h { |name| [name, var(:"seen_#{name}", 0)] }
      kept = var :kept, 0
      map = list :map, capacity: 6, width: :half
      game_loop do
        passes.increase!(1)
        levels.load at
        seen.each { |name, number| number.store!(tables.fetch(name)[passes]) }
        kept.store!(always[passes])
        map.copy_from(tables.fetch(reads.first), at: 0, count: 2)
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_game_reads_the_tables_of_the_group_it_loaded
    run = game_player.run(levels_game(level: 0), frames: 3)

    assert_equal FOREST[3], run[:seen_forest]
    assert_equal SKY[1], run[:seen_sky], "the sky is in both groups, so it is in with either"
    assert_equal 8, run[:kept], "a table in no group is always there"
    assert_equal FOREST.first(2), run.list(:map)
  end

  def test_the_group_loaded_is_the_one_a_number_worked_out_names
    run = game_player.run(levels_game(level: 1, reads: %i[cave sky]), frames: 3)

    assert_equal CAVE[3], run[:seen_cave]
    assert_equal SKY[1], run[:seen_sky]
    assert_equal CAVE.first(2), run.list(:map)
  end

  # On a console that holds one group at a time, the cave's place holds the forest's numbers.
  def test_reading_a_table_whose_group_is_not_loaded_stops_the_game
    error = assert_raises(Reference::ProgramError) { game_player.run(levels_game(level: 0, reads: %i[cave]), frames: 3) }

    assert_match(/:cave/, error.message)
    assert_match(/group 1 of :levels/, error.message)
    assert_match(/load/, error.message)
  end

  def test_a_number_naming_no_group_loads_nothing
    error = assert_raises(Reference::ProgramError) { game_player.run(levels_game(level: 5), frames: 3) }

    assert_match(/:forest/, error.message)
  end

  def test_a_group_naming_a_table_that_is_not_there_is_refused
    b = Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        table :forest, FOREST
        table_groups :levels, { 0 => %i[forest swamp] }
        game_loop { wait_vblank }
      end
      b.finalize_program
    end

    assert_match(/:swamp/, error.message)
    assert_match(/table_groups :levels/, error.message)
  end

  def test_a_table_in_two_sets_of_groups_is_refused
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        table :forest, FOREST
        table_groups :levels, { 0 => %i[forest] }
        table_groups :music, { 0 => %i[forest] }
      end
    end

    assert_match(/:forest/, error.message)
    assert_match(/:levels/, error.message)
  end

  def test_loading_with_a_fraction_is_refused
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        table :forest, FOREST
        levels = table_groups :levels, { 0 => %i[forest] }
        half = var :half, 0.5
        levels.load half
      end
    end

    assert_match(/whole number/, error.message)
  end
end
