# frozen_string_literal: true

require "test_helper"
require "interrupted_walks"
require "all/vblank/builder/test_timer"

# A hardware timer on the Advance's cartridge: the timer really runs, and its handlers really
# answer its interrupt, read back in the emulator. How a timer counts on every run is in
# test/all/vblank/builder/test_timer.rb.
class TestTimerCartridge < Minitest::Test
  include InterruptedWalks
  include TimerGames

  # A handler is the timer's, not the line's. `on_tick` says what a timer does when it
  # ticks, the way `once_a_frame` says what happens each frame, so a handler written inside
  # a routine nothing calls still answers every tick once the timer runs.
  def test_a_handler_inside_a_routine_nothing_calls_still_runs
    backend = GBA.new
    rom = ROM.assemble(backend.lower(handler_in_uncalled_routine_program), title: "TICKU", maker: "01")
    console = assert_emulator_loads_rom(rom, frames: 20, vars: backend.var_addresses).var(:hits)

    assert console.between?(10, 30), "the handler should have run ~20 times over 20 frames, got #{console}"
  end

  # A second handler for the same timer replaces the first rather than running beside it.
  def test_a_second_handler_for_a_timer_replaces_the_first
    backend = GBA.new
    rom = ROM.assemble(backend.lower(two_handlers_program), title: "TICKTWO", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 20, vars: backend.var_addresses)

    assert_equal 0, v.var(:first), "the replaced handler never runs on the console"
    assert v.var(:second).between?(10, 30), "the second handler runs, got #{v.var(:second)}"
  end

  # --- hardware: the timer really runs on the console ---

  def test_the_timer_counts_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      beat = timer :beat, per_second: 60
      seen = 0
      game_loop do
        wait_vblank
        seen = beat.ticks
      end
    end
    b.finalize_program
    backend = GBA.new
    rom = ROM.assemble(backend.lower(b.program), title: "TIMR", code: "BTMR", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 20, vars: backend.var_addresses)
    seen = v.var(:seen)
    # ~20 overflows after 20 frames at 60/sec (allowing for real ~59.7fps + startup);
    # the wide window still catches a timer that never ran (0) or counted raw ticks (huge).
    assert seen.between?(10, 30), "the timer should have counted ~20 ticks over 20 frames, got #{seen}"
  end

  # An on_tick handler really runs off the timer interrupt on the console: it increments
  # a variable each overflow, alongside the VBlank the game loop sleeps on (so the
  # dispatcher is servicing two sources).
  def test_on_tick_handler_runs_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      hits = 0
      timer(:beat, per_second: 60).on_tick { hits += 1 }
      game_loop { wait_vblank }
    end
    b.finalize_program
    backend = GBA.new
    rom = ROM.assemble(backend.lower(b.program), title: "TICK", code: "BTCK", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 20, vars: backend.var_addresses)
    hits = v.var(:hits)
    assert hits.between?(10, 30), "the on_tick handler should have run ~20 times over 20 frames, got #{hits}"
  end

  # A number drawn only from a tick is drawn: the routine that draws a font's digits is shared,
  # and it used to be laid out before the tick's code asked for it, so the game did not build.
  def test_a_number_drawn_only_from_a_tick_is_drawn_on_the_console
    rom = VBlank.build("TICKNUM", console: :gba, out: nil, err: nil) do
      screen :bitmap
      clear_screen :black
      shown = var :shown, 7
      timer(:beat, per_second: 60).on_tick { draw_number shown, 8, 8, :white, digits: 1 }
      game_loop {}
    end
    v = assert_emulator_loads_rom(rom, frames: 10)
    lit = (8...13).to_a.product((8...15).to_a).count { |x, y| v.white?(x, y) }

    assert_operator lit, :>, 0, "the 7 is on screen"
  end

  # A timer fast enough to be worth it has its handler kept in the console's quick memory,
  # which means the handler is copied bytes running from a different address than the ones the
  # build laid out (see Backends::GBA::Placement#IRQ_ROUTINE). It has to count exactly the
  # same either way, so this counts the same ticks with the handler in both places.
  private def ticks_counted_on_the_console(fast_code:)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      hits = 0
      timer(:beat, per_second: 1200).on_tick { hits += 1 }
      game_loop { wait_vblank }
    end
    b.finalize_program
    backend = GBA.new(fast_code: fast_code)
    rom = ROM.assemble(backend.lower(b.program), title: "TICKF", code: "BTKF", maker: "01")
    [assert_emulator_loads_rom(rom, frames: 12, vars: backend.var_addresses).var(:hits),
     backend.iwram_report.funcs]
  end

  # --- a handler that calls a routine the game is part way through ---

  # The interrupted walk carries on where it was, as on the interpreter (test_timer.rb's
  # test_a_call_a_handler_interrupted_carries_on_where_it_was). The handler calls :walk, which can
  # wait, so it runs as the game wakes, which here is inside the game's own walk, and walks again
  # from the start without waiting. The game's own walk then finishes its four steps.
  def test_a_call_a_handler_interrupted_carries_on_where_it_was
    assert_finished_like_interpreter(interrupted_walk_program(again_from: :tick, calls_in_body: false), name: "TWALK")
  end

  # ...and a walk whose count is kept in memory, since its body calls two routines.
  def test_a_call_a_handler_interrupted_keeps_a_count_in_memory
    assert_finished_like_interpreter(interrupted_walk_program(again_from: :tick, calls_in_body: true), name: "TWALKM")
  end

  # A handler run from the interrupt, which comes between any two instructions of the game, calls a
  # routine the game is part way through: :tally, which never waits. The interpreter runs a handler
  # only as a frame ends, so there every tally the game makes counts all its turns; so it does on
  # the cartridge, whose interrupt saves the loop's count around its own tally.
  def test_a_handler_interrupting_a_routine_leaves_its_count
    assert_finished_like_interpreter(interrupted_tally_program, name: "TTALLY")
  end

  # A handler that waits inside its own loop keeps its place in it (on the PlayStation,
  # test_ps1_tick_handlers.rb). Its wait is a frame boundary, so the handler runs again inside it,
  # to its end without waiting, and the first run goes on from the turn it had reached. A run whose
  # loop ended early moves the screen four across; it moves two once three runs are finished.
  def test_a_handler_waiting_inside_a_repeat_keeps_its_turn
    assert_finished_like_interpreter(waiting_handler_program(calls_in_body: false), name: "TWAIT")
  end

  # ...and one whose loop keeps its count in memory, since its body calls two routines.
  def test_a_handler_waiting_inside_a_repeat_keeps_a_count_in_memory
    assert_finished_like_interpreter(waiting_handler_program(calls_in_body: true), name: "TWAITM")
  end

  # A handler that waits reads what the pass before read, as the interpreter runs the handlers before
  # it counts the frame and reads the buttons (Reference#advance_frame): the frames since power-on
  # and whether A was pressed are the numbers the game's last pass read, at every run of the handler,
  # the ones inside its own wait too. A is tapped two frames in every seven. :late_count and
  # :late_press count the runs that read otherwise; the interpreter's are nought, and so are the
  # cartridge's, which saw the presses and ran the handler as often.
  def test_a_handler_that_waits_reads_the_last_pass_frame_and_presses
    program = handler_reading_last_pass_program
    interpreter = Reference.new.input_each_frame { |frame| tapped_a?(frame) ? [:a] : [] }.run(program, frames: 120)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "TLAST", maker: "01")
    cartridge = assert_emulator_loads_rom(rom, frames: 120, vars: backend.var_addresses,
                                               keys: ->(frame) { tapped_a?(frame) ? VBlank::Console::Hardware::KEY_A : 0 })
    reads = %i[late_count late_press]

    assert_equal [0, 0], reads.map { |name| interpreter[name] }, "the interpreter's answer"
    assert_operator interpreter[:presses], :>, 4, "the interpreter saw the taps"
    assert_equal [0, 0], reads.map { |name| cartridge.var(name) }, "the cartridge's handler read the last pass"
    assert_operator cartridge.var(:presses), :>, 4, "the cartridge saw the taps"
    assert_operator cartridge.var(:runs), :>, 20, "the cartridge's handler ran"
  end

  private def tapped_a?(frame) = frame % 7 < 2

  # A handler, 60 times a second, that compares the frames since power-on and a press of A with
  # what the game's pass read, then waits once if it is not inside its own wait already.
  private def handler_reading_last_pass_program
    b = Builder.new(options: VBlank::Cartridge::Options.new(frame_sync: :manual))
    b.instance_eval do
      screen :tiled
      last_count = var :last_count, 0
      last_press = var :last_press, 0
      now_press = var :now_press, 0
      presses = var :presses, 0
      depth = var :depth, 0
      runs = var :runs, 0
      late_count = var :late_count, 0
      late_press = var :late_press, 0
      timer(:beat, per_second: 60).on_tick do
        late_count += 1 if frames_since_power_on != last_count
        now_press = 0
        now_press = 1 if pressed(:a)
        late_press += 1 if now_press != last_press
        if depth == 0
          depth = 1
          wait_vblank
          depth = 0
          runs += 1
        end
      end
      game_loop do
        last_count = frames_since_power_on
        last_press = 0
        last_press = 1 if pressed(:a)
        presses += last_press
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  # The game tallies 50 turns twenty times a pass, and a timer 1200 times a second tallies too,
  # from its interrupt. :short counts the game's tallies that took fewer than 50 turns of its own,
  # and :done is 2 once three passes are finished. The loop calls two routines, so the cartridge
  # keeps its count in memory.
  private def interrupted_tally_program
    b = Builder.new(options: VBlank::Cartridge::Options.new(frame_sync: :manual))
    b.instance_eval do
      screen :tiled
      image(:bar, "." => :transparent, "#" => :red) { (["##......"] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      water = background :water, tiles: :stripes, map: Array.new(20) { "#" * 30 }
      ticking = var :ticking, 0
      mine = var :mine, 0
      turns = var :turns, 0
      passes = var :passes, 0
      short = var :short, 0
      done = var :done, 0
      func(:own_turn) { mine += 1 if ticking == 0 }
      func(:any_turn) { turns += 1 }
      func(:tally) do
        repeat(50) do
          call :own_turn
          call :any_turn
        end
      end
      timer(:beat, per_second: 1200).on_tick do
        ticking = 1
        call :tally
        ticking = 0
      end
      game_loop do
        repeat(20) do
          mine = 0
          call :tally
          short += 1 if mine != 50
        end
        passes += 1
        done = 2 if passes >= 3
        water.scroll_to((short * 4) + done, 0)
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  # A handler that, on the run the timer starts, counts three turns of a loop with a wait in each,
  # and on a run inside one of those waits counts three turns without waiting. :bad counts the first
  # runs that did not count three turns of their own. +calls_in_body+ counts the turns in routines,
  # so the cartridge keeps the loop's count in memory.
  private def waiting_handler_program(calls_in_body:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(frame_sync: :manual))
    b.instance_eval do
      screen :tiled
      image(:bar, "." => :transparent, "#" => :red) { (["##......"] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      water = background :water, tiles: :stripes, map: Array.new(20) { "#" * 30 }
      depth = var :depth, 0
      outer = var :outer, 0
      inner = var :inner, 0
      finished = var :finished, 0
      bad = var :bad, 0
      done = var :done, 0
      func(:outer_turn) { outer += 1 if depth == 1 }
      func(:inner_turn) { inner += 1 if depth > 1 }
      beat = timer :beat, per_second: 60
      beat.on_tick do
        depth += 1
        repeat(3) do
          if calls_in_body
            call :outer_turn
            call :inner_turn
          else
            outer += 1 if depth == 1
            inner += 1 if depth > 1
          end
          wait_vblank if depth == 1
        end
        if depth == 1
          bad += 1 if outer != (finished + 1) * 3
          finished += 1
        end
        depth -= 1
      end
      game_loop do
        done = 2 if finished >= 3
        water.scroll_to((bad * 4) + done, 0)
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_moved_tick_handler_counts_the_same_ticks
    quick, moved = ticks_counted_on_the_console(fast_code: true)
    cart, left = ticks_counted_on_the_console(fast_code: false)

    assert_includes moved, VBlank::IR::Backends::GBA::Placement::IRQ_ROUTINE,
                    "a timer at 1200 a second is worth keeping in the quick memory"
    refute_includes left, VBlank::IR::Backends::GBA::Placement::IRQ_ROUTINE

    # 1200 a second over 12 frames is ~240 ticks. Where the handler runs cannot change that.
    assert_equal cart, quick, "the moved handler counted a different number of ticks"
    assert_operator quick, :>, 100, "the handler really ran (#{quick} ticks)"
  end
end
