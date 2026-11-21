# frozen_string_literal: true

require "test_helper"

# Where the time went inside any routine, line by line.
#
# The split hints name a part only of a routine the quick memory passed over. A routine that is
# kept there, or that the author put in the cartridge, has a cost too, and an author whose pass is
# slow asks which of its lines holds that cost. `rom.profile(lines: :name)` answers for the routine
# named, and `lines: true` for the busiest routines of the measured frames.
class TestRoutineLines < Minitest::Test
  # A func the author keeps in the cartridge (`fast: false`), so the quick memory never weighs it,
  # with one heavy statement among light ones. Answers the program and the heavy statement's line.
  private def routine_with_one_heavy_line
    heavy = nil
    builder = Builder.new
    builder.instance_eval do
      x = var :x, 0
      y = var :y, 0
      func :spin, fast: false do
        x += 1
        heavy = __LINE__ + 1
        repeat(300) { y += 1 }
        x += 2
      end
      game_loop { call :spin }
    end
    builder.finalize_program
    [builder.program, heavy]
  end

  def test_the_profile_names_the_heavy_line_of_a_routine_the_quick_memory_never_weighed
    program, heavy = routine_with_one_heavy_line
    rom = assemble_rom(program, name: "LINES")
    result = VBlank::Diagnostics::Profiler.run(rom, frames: 10, picture: false, lines: :spin)

    assert_empty result.split_hints, "the routine never missed the quick memory, so no split hint names it"
    spin = result.routine_lines.find { |routine| routine.routine == :spin }
    refute_nil spin, "the routine asked for has its lines"
    top = spin.lines.first
    assert top.source.end_with?("test_routine_lines.rb:#{heavy}"), "the heavy line comes first, not #{top.source}"
    assert_operator top.share, :>, 80, "and holds most of the routine's time"
    assert_operator top.instructions, :>, 300, "it runs its loop's 300 turns a frame"
  end

  # `lines: true` asks for the busiest routines of the frames measured, whatever they are named.
  def test_lines_true_gives_the_busiest_routines
    program, heavy = routine_with_one_heavy_line
    result = VBlank::Diagnostics::Profiler.run(assemble_rom(program, name: "LINES"), frames: 10, picture: false,
                                               lines: true)

    assert_equal :spin, result.routine_lines.first.routine
    assert result.routine_lines.first.lines.first.source.end_with?(":#{heavy}")
  end

  # The game loop has no name an author wrote, so it is asked for as :game_loop, and a scene by
  # the scene's own name.
  def test_the_game_loop_and_a_scene_are_asked_for_by_the_names_an_author_knows
    builder = Builder.new
    builder.instance_eval do
      y = var :y, 0
      var :state, 0
      scene(:play) { repeat(50) { y += 1 } }
      game_loop { call({ 0 => :play }, number: :state) }
    end
    builder.finalize_program
    result = VBlank::Diagnostics::Profiler.run(assemble_rom(builder.program, name: "LOOPED"), frames: 5, picture: false,
                                               lines: %i[game_loop play])

    assert_equal [VBlank::Cartridge::BuildRecord::FRAME_ROUTINE, :_scene_play], result.routine_lines.map(&:routine)
  end

  def test_the_printed_profile_lists_the_routine_lines
    program, heavy = routine_with_one_heavy_line
    rom = assemble_rom(program, name: "LINES")
    out = StringIO.new
    VBlank::Diagnostics::Profiler.render(VBlank::Diagnostics::Profiler.run(rom, frames: 10, picture: false, lines: :spin),
                                         out: out)

    assert_match(/func :spin, by line/, out.string)
    assert_match(/test_routine_lines\.rb:#{heavy} +\d+(\.\d)?% of its time/, out.string)
  end

  # A name the game has no routine of is a friendly error, naming the routines it has.
  def test_an_unknown_routine_is_refused_naming_the_ones_there_are
    program, = routine_with_one_heavy_line
    error = assert_raises(ArgumentError) do
      VBlank::Diagnostics::Profiler.run(assemble_rom(program, name: "LINES"), frames: 1, picture: false, lines: :spun)
    end
    assert_match(/no routine called :spun/, error.message)
    assert_match(/spin/, error.message)
  end

  # A piece cut from a routine is the routine's own code, so its lines are the routine's: asked
  # for by the routine's name, the piece's statements are among its lines, and the piece is
  # never a routine of its own in the answer.
  def test_a_piece_cut_from_a_routine_counts_in_its_routine
    cartridge = 0x0800_0000
    piece = VBlank::Messages::MadeNames.make(:routine_piece, place: "1", routine: :play)
    statements = { play: [{ source: "game.rb:10", within: 0...16 }],
                   piece => [{ source: "game.rb:12", within: 0...0x40 }] }
    built = Struct.new(:routine_statements, :routines)
                  .new(statements, { play: cartridge...(cartridge + 32), piece => 0x0300_0000...0x0300_0040 })
    profile = Struct.new(:cycles, :pc, :frames, :cycles_per_frame)
                    .new({ cartridge => 100, cartridge + 20 => 10, 0x0300_0010 => 900 },
                         { cartridge => 10, cartridge + 20 => 1, 0x0300_0010 => 90 }, 1, 280_896)
    answer = VBlank::Diagnostics::RoutineLines.of(profile, Struct.new(:built).new(built), true)

    assert_equal [:play], answer.map(&:routine)
    assert_equal ["game.rb:12", "game.rb:10"], answer.first.lines.map(&:source)
    assert_in_delta 89.1, answer.first.lines.first.share, 0.1, "900 of the 1010 cycles the routine and its piece took"
    assert_in_delta 1.0, answer.first.outside_lines_share, 0.1, "the call and return are outside every line"
  end
end
