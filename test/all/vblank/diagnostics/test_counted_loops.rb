# frozen_string_literal: true

require "test_helper"
require "stringio"

# The counted loops report (Diagnostics::CountedLoops): every counted Ruby loop of game code whose
# count is known while building, its line, and whether the build wrote its rounds out or made
# them one loop, and why.
class TestCountedLoops < Minitest::Test
  REPORT = VBlank::Diagnostics::CountedLoops

  private def loops_rom
    VBlank.build("LOOPS", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      colors = %i[red green blue white]
      game_loop do
        clear_screen :black
        16.times { |i| draw_rect_at i * 14, 10, 4, 4, :red; draw_rect_at i * 14, 20, 4, 4, :green; draw_rect_at i * 14, 30, 4, 4, :blue }
        4.times { |i| draw_rect_at i * 20, 60, 8, 8, :blue }
        16.times { |i| draw_rect_at i * 14, 90, 4, 4, colors[i % 4]; draw_rect_at i * 14, 100, 4, 4, colors[(i + 1) % 4] }
      end
    end
  end

  def test_each_counted_line_is_told_with_what_the_build_chose
    rom = loops_rom
    out = StringIO.new
    REPORT.render(rom, VBlank::IR::Printer.for(out, color: false))
    lines = out.string.lines

    assert_equal %i[loop written_out rounds_differ], rom.counted_loops.map(&:choice)
    assert_includes lines.first, "counted loops: 3"
    [["16.times { |i| draw_rect_at i * 14, 10", REPORT::WORDS.fetch(:loop)],
     ["4.times { |i| draw_rect_at i * 20", REPORT::WORDS.fetch(:written_out)],
     ["colors[i % 4]", REPORT::WORDS.fetch(:rounds_differ)]].each do |code, words|
      line = lines.find { |each_line| each_line.include?(code) }
      assert line, "a line for #{code}"
      assert_includes line, words
    end
    loop_line = lines.index { |each_line| each_line.include?("16.times { |i| draw_rect_at i * 14, 10") }
    assert_includes lines[loop_line + 1], "Each round costs time"
    assert_includes lines[loop_line + 1], "works out 3 numbers"
    REPORT.as_json(rom).dig(:counted_loops, :lines).each { |line| refute_empty line[:says] }
  end

  # A loop inside a loop is chosen in every outer round, and the rounds the build drops take their
  # choices with them: the report counts the lines of the game.
  def test_a_loop_inside_a_loop_counts_as_its_own_line
    rom = VBlank.build("NESTED", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      total = 0
      game_loop do
        total = 0
        8.times do |r|
          r.upto(r + 15) { |c| total += c; total -= 1; total += 1 }
        end
      end
    end

    assert_equal 2, REPORT.as_json(rom).dig(:counted_loops, :count)
    assert_equal 2, rom.counted_loops.size, "the dropped rounds' inner loops are not kept"
  end
end
