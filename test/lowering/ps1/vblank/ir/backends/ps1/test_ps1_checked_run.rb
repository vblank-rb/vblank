# frozen_string_literal: true

require "test_helper"
require "delegate"
require "no_frames_games"
require "ps1_pass_work"

# What only the PlayStation's own program can show, played in Beetle PSX and held to the interpreter
# pass for pass (PS1::CheckedRun). What a game does with its numbers, lists, scenes and routines is in
# test/all, where this run plays it too; here are the pad's wiring, the runtime's own fault words, the
# parts of the lowering a checked run cannot see through the interpreter, and the build's refusals.
class TestPS1CheckedRun < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1

  # The lowering stops the game with the runtime's own fault, which the reader turns into the
  # interpreter's words.
  def test_a_list_read_out_of_range_stops_the_game_in_the_interpreters_words
    error = assert_raises(VBlank::IR::ProgramError) do
      checked(frames: 5) do
        body = list :body, capacity: 4
        body.push 10
        x = 0
        game_loop { x = body[3] }
      end
    end

    assert_match(/index 3 is out of range for list :body \(valid indexes are 0\.\.0\)/, error.message)
  end

  # `&` and `|` work out both sides (TestDSLExpression): played through a checked run, the interpreter
  # stops first and hides whether the program did too, so the program is played alone here.
  def test_the_program_works_out_both_sides_of_and_and_or
    games = [
      proc do
        items = list :items, capacity: 4
        items.push 7
        hits = 0
        game_loop { hits += 1 if (hits > 100) & (items[3] > 0) }
      end,
      proc do
        items = list :items, capacity: 4
        items.push 7
        hits = 0
        game_loop { hits += 1 if (hits < 100) | (items[3] > 0) }
      end
    ]
    games.each do |game|
      error = assert_raises(VBlank::IR::ProgramError) { PS1::HeadlessRun.new.run(program_of(&game), frames: 3) }

      assert_match(/index 3 is out of range for list :items/, error.message)
    end
  end

  # Each of the twelve buttons a game names on the pad held alone for one frame, a frame apart: each is
  # counted once under its own name, so one wired to another's bit shows as a count in the wrong place.
  BUTTONS = %i[a b x y l r select start right left up down].freeze

  def test_every_button_reaches_the_game_under_its_own_name
    run = PS1::CheckedRun.new
    run.input_each_frame { |frame| frame.even? && frame.between?(2, 24) ? [BUTTONS[(frame - 2) / 2]] : [] }
    run.run(program_of do
      BUTTONS.each do |button|
        count = var :"#{button}_count", 0
        once_a_frame { count += 1 if pressed(button) }
      end
      game_loop {}
    end, frames: 30)

    assert_equal [1] * BUTTONS.size, BUTTONS.map { |button| run[:"#{button}_count"] }
  end

  # A pass too heavy for one frame spans several, and what keeps real time — `once_a_frame` — moves on
  # by every frame the pass took, on the interpreter too (it is told how many each pass took). The work
  # is PS1PassWork's loop, as many turns as end a pass well into its second frame, measured as the test
  # runs, since the lowering makes a turn quicker now and then.
  HEAVY_PASS_LINES = 60..200

  def test_a_pass_that_takes_several_frames_keeps_real_time_as_the_interpreter_does
    turns = PS1PassWork.turns_ending_within(HEAVY_PASS_LINES)
    run = checked(frames: 12) do
      total = 0
      frames = 0
      passes = 0
      once_a_frame { frames += 1 }
      game_loop do
        passes += 1
        repeat(turns) { total += 3 }
      end
    end

    # The pass the run ends in has counted itself as it began and spanned none of its frames yet, so
    # the passes that spanned their frames are one fewer than counted.
    assert_operator run[:frames], :>=, 2 * (run[:passes] - 1), "every pass spanned two frames or more"
  end

  # A byte read out of a block of data the program declares, built as IR since no verb says it alone.
  def test_a_byte_of_declared_data_is_read_as_the_interpreter_reads_it
    build = VBlank::IR::Build
    game = build.program(
      build.data(:bytes, "\x05\xFA\x07".b),
      build.set(:first, build.data_byte(:bytes, 0)),
      build.loop_(build.wait_vblank, build.set(:second, build.data_byte(:bytes, 1)),
                  build.set(:total, build.binop(:+, build.data_byte(:bytes, 2), build.var_ref(:second)))),
      console: :ps1
    )
    run = PS1::CheckedRun.new.run(game, frames: 4)

    assert_equal [5, 250, 257], [run[:first], run[:second], run[:total]]
  end

  def test_a_routine_that_can_call_itself_is_refused_in_plain_words
    program = VBlank::IR::Build.program(
      VBlank::IR::Build.func(:again, VBlank::IR::Build.call(:again)), VBlank::IR::Build.call(:again)
    )
    error = assert_raises(PS1::LoweringError) { PS1.new.build(program) }

    assert_match(/can call itself again/, error.message)
  end

  # A cell is changed only inside the row it is in (Reference#change_cell reads the row's own length),
  # and the program keeps one size for a background's map. Every map the builder makes is a rectangle,
  # so a map whose rows differ in length was built by hand, and is refused rather than changed past a
  # short row's end.
  def test_a_map_whose_rows_differ_in_length_is_refused
    program = program_of do
      screen :tiled
      image(:wall, "#" => :red) { SOLID_TILE }
      tiles :walls, "#" => :wall
      room = background :room, tiles: :walls, map: %w[## ##]
      game_loop { room.set_tile 1, 1, "#" }
    end
    declared = program.walk.find { |node| node.kind == :background }
    ragged = VBlank::IR::Build.background(:room, tiles: declared.tiles, map: [[0, 0], [0]], tile_w: 8, tile_h: 8)
    beside = declared.parent.children
    beside[beside.index(declared)] = ragged
    ragged.parent = declared.parent

    error = assert_raises(PS1::LoweringError) { PS1.new.build(program) }
    assert_match(/rows are of different lengths/, error.message)
  end

  # What the console can do and this build does not make yet is refused as not made yet, naming the
  # part, never in the words of hardware the console lacks (Console::PS1Answers).
  def test_what_the_build_does_not_make_yet_is_refused_as_not_made_yet
    games = {
      "the second pad" => proc { game_loop { wait_vblank if held(:a, player: 2) } },
      "fades, lights and screen effects" => proc { game_loop { fade :black, 50, inside: [0, 0, 16, 16] } }
    }
    games.each do |part, game|
      error = assert_raises(PS1::Lowering::NotMadeYet) { PS1.new.build(program_of(&game)) }

      assert_match(/#{part}/, error.part)
    end
  end

  # A run of no frames ends before the first pass is shown: the graphics chip still has its display
  # switched off, which the interpreter shows as its plain white picture of a display switched off,
  # and the game's numbers are the first pass's.
  def test_a_run_of_no_frames_ends_with_the_screen_still_off
    run = PS1::CheckedRun.new.run(NoFramesGames.room_counting_passes(:ps1), frames: 0)

    assert_equal Color.resolve(:white), run.screen.pixel(3, 3)
    assert_equal 0, run[:n]
  end

  # A stand-in for a runtime that lets the display come on while it sets up: the graphics chip reads
  # with its display on, where the real program still has it off. The run reports the picture
  # Beetle PSX holds where the chip shows it, not the interpreter's switched-off white, so a check
  # against the interpreter would fail.
  class DisplayOnWhileSettingUp < PS1::HeadlessRun
    # The emulator, but its graphics chip's display always on.
    class DisplayOnCore < SimpleDelegator
      def gpu_state = __getobj__.gpu_state.merge(display_off: 0)
    end

    private def power_on
      @core = DisplayOnCore.new(@core)
      super
    end
  end

  def test_a_run_of_no_frames_reports_the_picture_shown_when_the_display_is_on
    run = DisplayOnWhileSettingUp.new.run(NoFramesGames.room_counting_passes(:ps1), frames: 0)

    assert_equal [0], run.screen.to_a.uniq, "the picture Beetle PSX holds where the chip shows it: nothing drawn there yet"
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :ps1 }
  end

  def checked(frames: nil, &game)
    PS1::CheckedRun.new.run(program_of(&game), frames: frames)
  end
end
