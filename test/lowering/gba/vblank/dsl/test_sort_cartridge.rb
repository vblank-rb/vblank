# frozen_string_literal: true

require "test_helper"
require "struct_array_parts"

# What `sort!` and `sort_by!` cost on the Advance's cartridge, read by `rom.profile`: each line
# that sorts is a routine of its own, named for the Array and the line, with what it costs.
class TestSortCartridge < Minitest::Test
  # Sixteen scores, one replaced each pass by a number that moves round, sorted biggest first;
  # and eight sparks falling at their own speeds, sorted by height.
  private def sorting_game
    builder = Builder.new
    builder.instance_eval do
      scores = Array.new(16, 0)
      sparks = Array.new(capacity: 8)
      t = 0
      8.times { |n| sparks << Spark.new(n * 10, 0, 1 + (n % 3)) }
      game_loop do
        t += 1
        scores[t % 16] = (t * 37) % 100
        scores.sort! { |a, b| b <=> a }
        sparks.each { |s| s.y = (s.y + s.vy) % 150 }
        sparks.sort_by! { |s| s.y }
      end
    end
    builder.finalize_program
    builder.program
  end

  private def profile_lines
    rom = assemble_rom(sorting_game, name: "SORTS")
    VBlank::Diagnostics::Profiler.run(rom, frames: FRAMES, picture: false).lines
  end

  FRAMES = 30

  def test_the_profile_names_each_sorting_line_and_what_it_costs
    lines = profile_lines
    sorts = lines.select { |line| line.label.to_s.start_with?("sorting") }

    assert_equal ["sorting `scores` at line 21", "sorting `sparks` at line 23"],
                 sorts.map { |line| line.label[/\Asorting `\w+` at line \d+/] }.sort
    sorts.each { |line| assert_operator line.samples, :>, 0 }
  end

  # Instructions a pass each sort spends, held to what they cost when written (2026-11-24: about
  # 685 for the sixteen scores, one new each pass, and 835 for the eight sparks), with a little room.
  # The scores were 1120 until an item already in its place cost one read and one compare, which is
  # how an insertion sort pays for a list that changes little from frame to frame: the habit of a
  # short list sorted each frame, kept in order by moving only what moved. A hand-written insertion
  # sort of sixteen nearly sorted words in ARM is a few hundred, so this is still above a careful
  # game's; that gap is tracked, and this test only stops it growing.
  def test_each_sort_costs_no_more_than_when_it_was_written
    per_pass = profile_lines.select { |line| line.label.to_s.start_with?("sorting") }
                            .to_h { |line| [line.label[/`(\w+)`/, 1], line.samples / FRAMES] }

    assert_operator per_pass.fetch("scores"), :<, 760
    assert_operator per_pass.fetch("sparks"), :<, 950
  end

  # Every shape of sixteen numbers an Array can be in when it is sorted — in order, backwards, all
  # level, one out of place at each end, and a pseudo-random scramble — ascending and descending, put
  # in order on the cartridge as Ruby's own sort puts it. The answer key is Ruby.
  SHAPES = {
    in_order: (1..16).to_a,
    backwards: (1..16).to_a.reverse,
    level: [5] * 16,
    first_is_last: (2..16).to_a + [1],
    last_is_first: [16] + (1..15).to_a,
    pairs_swapped: [2, 1, 4, 3, 6, 5, 8, 7, 10, 9, 12, 11, 14, 13, 16, 15],
    with_repeats: [4, 9, 4, 2, 9, 2, 7, 7, 1, 1, 8, 3, 8, 3, 6, 6],
    negatives: [3, -7, 0, -1, 9, -12, 4, 4, -7, 2, 100, -100, 0, 5, -5, 1],
    scrambled: [0, 63, 29, 92, 58, 24, 87, 53, 19, 82, 48, 14, 77, 43, 9, 72]
  }.freeze

  # The Arrays are written out here, as a game writes them, and SHAPES is what they must come to.
  private def shapes_game
    builder = Builder.new
    builder.instance_eval do
      in_order = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
      backwards = [16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]
      level = [5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5]
      first_is_last = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 1]
      last_is_first = [16, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
      pairs_swapped = [2, 1, 4, 3, 6, 5, 8, 7, 10, 9, 12, 11, 14, 13, 16, 15]
      with_repeats = [4, 9, 4, 2, 9, 2, 7, 7, 1, 1, 8, 3, 8, 3, 6, 6]
      negatives = [3, -7, 0, -1, 9, -12, 4, 4, -7, 2, 100, -100, 0, 5, -5, 1]
      scrambled = [0, 63, 29, 92, 58, 24, 87, 53, 19, 82, 48, 14, 77, 43, 9, 72]
      down_scrambled = [0, 63, 29, 92, 58, 24, 87, 53, 19, 82, 48, 14, 77, 43, 9, 72]
      down_repeats = [4, 9, 4, 2, 9, 2, 7, 7, 1, 1, 8, 3, 8, 3, 6, 6]
      down_last = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 1]
      game_loop do
        in_order.sort!
        backwards.sort!
        level.sort!
        first_is_last.sort!
        last_is_first.sort!
        pairs_swapped.sort!
        with_repeats.sort!
        negatives.sort!
        scrambled.sort!
        down_scrambled.sort! { |a, b| b <=> a }
        down_repeats.sort! { |a, b| b <=> a }
        down_last.sort! { |a, b| b <=> a }
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_sixteen_numbers_in_every_shape_are_put_in_order_as_ruby_does
    ascending = SHAPES.keys
    v = assert_emulator_loads_rom(assemble_rom(shapes_game, name: "SORTSHAPES"), frames: 3)

    ascending.each { |name| assert_equal SHAPES.fetch(name).sort, v.list(name), "#{name}, smallest first" }
    assert_equal SHAPES.fetch(:scrambled).sort.reverse, v.list(:down_scrambled)
    assert_equal SHAPES.fetch(:with_repeats).sort.reverse, v.list(:down_repeats)
    assert_equal SHAPES.fetch(:first_is_last).sort.reverse, v.list(:down_last)
  end
end
