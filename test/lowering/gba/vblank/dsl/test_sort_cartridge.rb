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

  # Instructions a pass each sort spends, held to what they cost when written (2026-11-23: about
  # 1140 for the sixteen scores, one new each pass, and 855 for the eight sparks), with a little
  # room. A hand-written insertion sort of sixteen nearly sorted bytes in ARM is a few hundred,
  # so the scores' sort costs more than a careful game's would; that gap is tracked, and this
  # test only stops it growing.
  def test_each_sort_costs_no_more_than_when_it_was_written
    per_pass = profile_lines.select { |line| line.label.to_s.start_with?("sorting") }
                            .to_h { |line| [line.label[/`(\w+)`/, 1], line.samples / FRAMES] }

    assert_operator per_pass.fetch("scores"), :<, 1300
    assert_operator per_pass.fetch("sparks"), :<, 1000
  end
end
