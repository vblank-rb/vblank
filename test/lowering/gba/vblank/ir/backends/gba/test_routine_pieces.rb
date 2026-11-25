# frozen_string_literal: true

require "test_helper"
require "screen_backdrop_games"

# A routine too big for the quick memory, cut into pieces that fit (GBA::RoutinePieces).
#
# Code in the cartridge runs at well under half the speed of the same code in the console's quick
# memory, and a routine goes there whole or not at all. So a routine that grew past the room ran
# all of its busy part from the cartridge, however small that part was. Cut into pieces, its busy
# part goes in alone.
class TestRoutinePieces < Minitest::Test
  include VBlank::Testing::Pictures
  # Additions a frame in the busy part, and in each of the parts that never run.
  BUSY_ADDS = 800
  IDLE_ADDS = 150
  IDLE_PARTS = 16

  # A game whose one routine does BUSY_ADDS additions a frame, and, with +idle_parts+, holds that
  # many parts more of IDLE_ADDS additions each under tests that never hold: with all sixteen, the
  # routine is bigger than the quick memory could ever give it.
  private def adding_game(name, idle_parts:)
    busy = BUSY_ADDS
    idle = IDLE_ADDS
    VBlank.build(name, console: :gba, out: StringIO.new, err: StringIO.new) do
      a = 0
      b = 0
      t = 0
      func(:work) do
        if t >= 0
          busy.times { |n| a += 1 + (n.even? ? 5 : -5) }
        end
        idle_parts.times do |part|
          if t == -1 - (part ^ 1)
            idle.times { |n| b += 1 + (n.even? ? 5 : -5) }
          end
        end
      end
      game_loop do
        t += 1
        call :work
        wait_vblank
      end
    end
  end

  # What a frame keeps the console busy for, in cycles.
  private def busy_cycles(rom)
    result = VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false)
    (1.0 - result.idle_share) * VBlank::Console::ADVANCE.cycles_a_frame
  end

  # The cost: the frame of the game with the big routine is as busy as the frame of the same work
  # in a routine that fits, since the parts that never run are the only difference. Before the
  # routine was cut, its busy additions ran from the cartridge and the frame was about twice as
  # busy (measured in the emulator: the cartridge's ARM code against the same code in the quick
  # memory, GBATEK "GBA Memory Map").
  def test_a_routine_too_big_for_the_quick_memory_runs_its_busy_part_there
    big = adding_game("BIGROUTINE", idle_parts: IDLE_PARTS)
    small = adding_game("SMALLROUTINE", idle_parts: 0)
    sizes = big.built.placement.sizes
    work_bytes = sizes.values_at(*sizes.keys.grep(/work/)).sum

    assert_operator work_bytes, :>, 32 * 1024, "the big routine and its pieces come to more than the quick memory holds"
    # A tenth over: the big routine's tests of the parts that never run, and its call into the
    # busy piece, are the only work the small one does not do. Uncut, it was twice as busy.
    assert_operator busy_cycles(big), :<=, busy_cycles(small) * 1.1,
                    "the big routine's busy part costs what the same work costs in a routine that fits"
  end

  # Turns of the busy loop a frame.
  BUSY_TURNS = 100
  # How many parts of IDLE_ADDS additions, that never run, sit inside the loop's body and outside it.
  LOOP_IDLE_PARTS = 16

  # A routine whose busy part is a counted loop of three lines. Its loop also holds +inside+ parts of
  # +idle+ additions that never run, and +outside+ parts more follow the loop, so with sixteen of
  # each the loop alone is bigger than the quick memory's room.
  private def looping_game(name, inside:, outside:, idle: IDLE_ADDS)
    turns = BUSY_TURNS
    VBlank.build(name, console: :gba, out: StringIO.new, err: StringIO.new) do
      a = 0
      b = 0
      c = 0
      t = 0
      func(:work) do
        repeat(turns) do
          a += 1
          b += 2
          c += 3
          inside.times do |part|
            if t == -1 - (part ^ 1)
              idle.times { |n| b += 1 + (n.even? ? 5 : -5) }
            end
          end
        end
        outside.times do |part|
          if t == -100 - (part ^ 1)
            idle.times { |n| b += 1 + (n.even? ? 5 : -5) }
          end
        end
      end
      game_loop do
        t += 1
        call :work
        wait_vblank
      end
    end
  end

  # A busy loop of three lines holding parts that never run, so that it is bigger than the quick
  # memory's room itself: the loop stays in its routine and its big statements are pieces, so its
  # three busy lines are all that is left of it and the frame costs about what it does in a routine
  # that fits. Left whole, its busy lines ran from the cartridge.
  def test_a_busy_loop_bigger_than_the_quick_memory_runs_its_busy_lines_there
    big = looping_game("BIGLOOP", inside: LOOP_IDLE_PARTS, outside: IDLE_PARTS)
    small = looping_game("SMALLLOOP", inside: LOOP_IDLE_PARTS, outside: IDLE_PARTS, idle: 1)

    assert_operator busy_cycles(big), :<=, busy_cycles(small) * 1.1,
                    "the big routine's busy loop costs what the same loop costs in a routine that fits"
  end

  # The loop's body in pieces still counts its turns: each pass runs the loop BUSY_TURNS times, and the
  # parts that never run add nothing.
  def test_the_loop_cut_in_pieces_runs_every_turn
    rom = looping_game("BIGLOOP", inside: LOOP_IDLE_PARTS, outside: IDLE_PARTS)
    v = assert_emulator_loads_rom(rom, frames: 20, vars: rom.var_addresses)

    assert rom.built.placement.sizes.keys.any? { |name| name.to_s.include?("_loop_") }, "the loop's body was cut"
    assert_equal BUSY_TURNS * v.var(:t), v.var(:a)
    assert_equal BUSY_TURNS * v.var(:t) * 2, v.var(:b), "the parts that never run added nothing to b"
    assert_equal BUSY_TURNS * v.var(:t) * 3, v.var(:c)
  end

  # The pieces do what the routine did: every frame adds BUSY_ADDS, and the parts that never run
  # add nothing.
  def test_the_cut_routine_does_what_it_did
    rom = adding_game("BIGROUTINE", idle_parts: IDLE_PARTS)
    v = assert_emulator_loads_rom(rom, frames: 20, vars: rom.var_addresses)

    assert_equal BUSY_ADDS * v.var(:t), v.var(:a), "every pass ran the busy part once"
    assert_equal 0, v.var(:b), "no part that never runs ran"
  end

  # A sky-blue title that runs the big routine, then a board that says no backdrop of its own
  # (ScreenBackdropGames). The cut lowers a copy of the program, so what the screen's plan knows
  # by its nodes (a scene's own `screen` line) has to be planned from the copy.
  private def sky_title_running_big_routine
    busy = BUSY_ADDS
    idle = IDLE_ADDS
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      ScreenBackdropGames.declare_corner_tile(self)
      state = var :state, 0
      tick = 0
      a = 0
      c = 0
      func(:work) do
        if tick >= 0
          busy.times { |n| a += 1 + (n.even? ? 5 : -5) }
        end
        IDLE_PARTS.times do |part|
          if tick == -1 - (part ^ 1)
            idle.times { |n| c += 1 + (n.even? ? 5 : -5) }
          end
        end
      end
      scene(:title) do
        screen :tiled, backdrop: ScreenBackdropGames::SKY
        background :title, tiles: :corner_set, map: ["c"]
        call :work
      end
      scene(:board) { background :board, tiles: :corner_set, map: ["c"] }
      game_loop do
        tick += 1
        state = 1 if tick == 6
        call({ 0 => :title, 1 => :board }, number: :state)
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_cut_game_shows_each_scenes_backdrop_as_the_interpreter_does
    program = sky_title_running_big_routine
    backend = GBA.new
    backend.lower(program)

    refute_empty backend.func_ranges.keys.grep(/piece/), "the big routine was cut"
    assert_backends_agree(program, frames: [3, 12], name: "CUTDROPS")
  end

  # A build whose cut plan cannot hold what the author insisted on lowers the program whole, and
  # then builds exactly as a build that never cut. These two stand in for those builds: one whose
  # cut plan is refused as such a plan is, once it is made, and one that cuts nothing.
  class RefusingCutPlan < GBA
    def measure_and_choose(program, insisted)
      chosen = super
      raise QuickMemoryFull, "the cut plan is refused" if program.walk.any? { |node| node.kind == :func && node.name.to_s.start_with?("__piece_") }

      chosen
    end
  end

  class NeverCutting < GBA
    def cut_into_pieces(*) = nil
  end

  # The adding game's routine beside a list of +slots+ a frame writes once, built as a game (not
  # a cartridge) so a backend of either kind above can lower it. Measured, the busy piece is worth
  # more than the list, so the cut plan moves the list to the roomy memory; the plan whole keeps it.
  private def adding_game_with_list(slots:)
    busy = BUSY_ADDS
    idle = IDLE_ADDS
    VBlank.game("CUTLIST", consoles: %i[gba]) do
      a = 0
      b = 0
      t = 0
      hoard = list :hoard, capacity: slots, full_of: 0
      func(:work) do
        if t >= 0
          busy.times { |n| a += 1 + (n.even? ? 5 : -5) }
        end
        IDLE_PARTS.times do |part|
          if t == -1 - (part ^ 1)
            idle.times { |n| b += 1 + (n.even? ? 5 : -5) }
          end
        end
      end
      game_loop do
        t += 1
        hoard[t % slots] = t
        call :work
        wait_vblank
      end
    end
  end

  # What the build measured of the adding game, each piece by its own count.
  MEASURED_PIECES = VBlank::Diagnostics::RoutineProfile.new(
    work: { __frame: 40, work: 60, __piece_0_then__of_work: BUSY_ADDS * 3 }, touches: { hoard: 1 }
  )

  def test_a_build_whose_cut_plan_is_refused_builds_as_one_that_never_cut
    program = adding_game_with_list(slots: 5000).program
    cutting = GBA.new(routine_profile: MEASURED_PIECES)
    cutting.lower(program)
    refute_nil cutting.build_record(program).roomy_memory, "cut, the plan gives the list's room to the busy piece"

    fallen_back = RefusingCutPlan.new(routine_profile: MEASURED_PIECES).lower(program)
    uncut = NeverCutting.new(routine_profile: MEASURED_PIECES).lower(program)

    assert uncut == fallen_back, "the program lowered whole is the build that never cut, byte for byte " \
                                 "(#{fallen_back.bytesize} bytes against #{uncut.bytesize})"
  end

  # A measurement of a cut build gives the routine only what was not cut, and each piece its own
  # count. Built from it, the next build weighs the program whole with the pieces counted back in
  # the routine, so it cuts the same pieces again: a routine whose remainder alone is not worth the
  # room is not left whole one build and cut the next. Two parts that never run, so the remainder is
  # a few tests a frame.
  private def adding_game_of_two_idle_parts
    busy = BUSY_ADDS
    VBlank.game("CUTAGAIN", consoles: %i[gba]) do
      a = 0
      b = 0
      t = 0
      func(:work) do
        if t >= 0
          busy.times { |n| a += 1 + (n.even? ? 5 : -5) }
        end
        if t == -1
          900.times { |n| b += 1 + (n.even? ? 5 : -5) }
        end
        if t == -2
          900.times { |n| b += 1 + (n.even? ? 5 : -5) }
        end
      end
      game_loop do
        t += 1
        call :work
        wait_vblank
      end
    end
  end

  private def measured(rom) = VBlank::Diagnostics::RoutineProfile.from_survey(VBlank::Diagnostics::Profiler.survey_scenes(rom))
  private def pieces_of(rom) = rom.built.routines.keys.grep(/__piece_/).sort

  def test_measure_build_measure_build_cuts_the_same_pieces_twice
    game = adding_game_of_two_idle_parts
    first = game.build_rom(out: StringIO.new, err: StringIO.new, profile: measured(game.build_rom(out: StringIO.new, err: StringIO.new, profile: false)))
    second = game.build_rom(out: StringIO.new, err: StringIO.new, profile: measured(first))

    refute_empty pieces_of(first), "the first measured build cut the routine"
    assert_equal pieces_of(first), pieces_of(second), "the build after cut it the same way"
  end
end
