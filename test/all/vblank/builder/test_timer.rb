# frozen_string_literal: true

require "test_helper"

# The games with tick handlers, kept once for this file and for the tests of the same games on
# the Advance's cartridge (test/lowering/gba/vblank/builder/test_timer_cartridge.rb).
module TimerGames
  # A timer whose handler is written inside a routine nothing calls, counting into :hits.
  private def handler_in_uncalled_routine_program
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      hits = 0
      beat = timer :beat, per_second: 60
      func(:setup) { beat.on_tick { hits += 1 } }
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # A timer given two handlers, the first counting into :first and the second into :second.
  private def two_handlers_program
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      first = 0
      second = 0
      beat = timer :beat, per_second: 60
      beat.on_tick { first += 1 }
      beat.on_tick { second += 1 }
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end
end

# A hardware timer: `timer :beat, per_second: N` starts a counter that ticks N times a
# second; `beat.ticks` reads how many ticks have elapsed (a Value), `beat.stop` freezes
# it. The rate is a prescaler + reload on the GBA, and a frame-clock model on the
# interpreter — both agree on the elapsed-tick count. Pinned here on every run, and on the
# Advance's cartridge in test/lowering/gba/vblank/builder/test_timer_cartridge.rb.
class TestTimer < Minitest::Test
  include TimerGames

  # Run a program that samples `beat.ticks` into :snap every frame and halts at
  # `stop_frame`; returns the interpreter so a test can read :snap. `per_second` sets the
  # rate; if `stop_at` is given, the timer is stopped at that frame.
  private def run_ticks(per_second:, stop_frame:, stop_at: nil)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      beat = timer :beat, per_second: per_second
      fc = 0
      snap = 0
      game_loop do
        wait_vblank
        fc += 1
        beat.stop if stop_at && fc == stop_at
        snap = beat.ticks
        halt if fc == stop_frame
      end
    end
    game_player.run(b.program, frames: stop_frame + 1)
  end

  # At 60/sec on a 60fps model, the timer ticks once per frame — so after N frames it
  # reads N.
  def test_ticks_climb_one_per_frame_at_sixty_per_second
    assert_equal 10, run_ticks(per_second: 60, stop_frame: 10)[:snap]
  end

  # Half the rate, half the ticks: 30/sec accrues one tick every two frames.
  def test_a_slower_timer_ticks_proportionally
    assert_equal 5, run_ticks(per_second: 30, stop_frame: 10)[:snap]
  end

  # A faster timer accrues more than one tick per frame.
  def test_a_faster_timer_ticks_faster
    assert_equal 20, run_ticks(per_second: 120, stop_frame: 10)[:snap]
  end

  # A whole tick counts on the frame it falls due, at any rate. Ten a second is a tick every six
  # frames, so six frames in it reads 1; three a second reads 3 a second in. Counted by adding a
  # tenth of a tick a frame as a fraction, the sum lands a hair under the whole tick, and the
  # count read one short on exactly those frames.
  def test_a_tick_counts_on_the_frame_it_falls_due
    assert_equal 1, run_ticks(per_second: 10, stop_frame: 6)[:snap]
    assert_equal 3, run_ticks(per_second: 3, stop_frame: 60)[:snap]
    assert_equal 2, run_ticks(per_second: 1, stop_frame: 120)[:snap]
  end

  # Stopping freezes the count: stopped at frame 5, it reads 5 even after ten frames.
  def test_stop_freezes_the_count
    assert_equal 5, run_ticks(per_second: 60, stop_frame: 10, stop_at: 5)[:snap]
  end

  # An unstarted timer reads zero rather than erroring.
  def test_reading_an_unstarted_timer_is_zero
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      snap = var :snap, 0
      snap = VBlank::DSL::Timer.new(self, :ghost).ticks
      halt
    end
    assert_equal 0, game_player.run(b.program)[:snap]
  end

  # --- validation ---

  def test_per_second_must_be_a_positive_whole_number
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :bitmap
        timer :beat, per_second: 0
      end
    end
    assert_match(/per_second/, err.message)
  end

  def test_reading_ticks_of_a_third_counted_timer_is_a_friendly_error
    # Each read timer costs two hardware timers; the GBA has four, so a third counted
    # timer overruns and the lowering says so plainly.
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      %i[a b c].each do |name|
        t = timer name, per_second: 60
        snap = var :"snap_#{name}", 0
        snap = t.ticks
      end
      halt
    end
    err = assert_raises(VBlank::IR::Backends::GBA::LoweringError) { GBA.new.lower(b.program) }
    assert_match(/hardware timers/i, err.message)
  end

  # Sampled sound takes two of the four for itself, which nothing in the program says — so a
  # program that runs out because of it is told so.
  def test_running_out_of_timers_beside_sampled_sound_says_the_sound_took_two
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      tone = sample :tone, pcm: [0, 50, 100, 50], rate: 8192
      counted = timer :counted, per_second: 60
      timer :plain, per_second: 60
      snap = 0
      game_loop do
        tone.play
        snap = counted.ticks
      end
    end
    err = assert_raises(VBlank::IR::Backends::GBA::LoweringError) { GBA.new.lower(b.program) }
    assert_match(/hardware timers/i, err.message)
    assert_match(/sampled sound uses two/i, err.message)
  end

  # --- on_tick: a handler driven by the timer's overflow ---

  # Runs `beat.on_tick { hits += 1 }` at the given rate and halts at `stop_frame`;
  # returns the interpreter so a test can read :hits.
  private def run_on_tick(per_second:, stop_frame:, stop_at: nil)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      hits = 0
      beat = timer :beat, per_second: per_second
      beat.on_tick { hits += 1 }
      fc = 0
      game_loop do
        wait_vblank
        fc += 1
        beat.stop if stop_at && fc == stop_at
        halt if fc == stop_frame
      end
    end
    game_player.run(b.program)
  end

  # At 60/sec on a 60fps model the handler runs once per frame — so after N frames it has
  # run N times.
  def test_on_tick_runs_the_handler_on_each_overflow
    assert_equal 10, run_on_tick(per_second: 60, stop_frame: 10)[:hits]
  end

  # A faster timer runs the handler more often — twice a frame at 120/sec.
  def test_on_tick_runs_more_often_for_a_faster_timer
    assert_equal 20, run_on_tick(per_second: 120, stop_frame: 10)[:hits]
  end

  # Stopping the timer stops its handler: stopped at frame 5, the count freezes at 5.
  def test_on_tick_stops_with_the_timer
    assert_equal 5, run_on_tick(per_second: 60, stop_frame: 10, stop_at: 5)[:hits]
  end

  # A handler is the timer's, not the line's. `on_tick` says what a timer does when it
  # ticks, the way `once_a_frame` says what happens each frame, so a handler written inside
  # a routine nothing calls still answers every tick once the timer runs — on both runners.
  def test_a_handler_inside_a_routine_nothing_calls_still_runs
    assert_equal 10, game_player.run(handler_in_uncalled_routine_program, frames: 10)[:hits]
  end

  # A handler can call the routine it interrupted. The handler runs at the frame boundary, which here is
  # inside :step's own wait, so :step runs again while the first call is still going: the first call's
  # first item writes 0, then the tick's call writes 5, 6 and 7 (it waits for nothing), so the first
  # frame ends on 567. A cartridge keeps a routine's own numbers (its loop's count) at fixed places,
  # and a call like this one shares them.
  def test_a_handler_can_call_the_routine_whose_wait_it_runs_in
    b = Builder.new
    b.instance_eval do
      seen = 0
      depth = 0
      beat = timer :beat, per_second: 60
      func(:step) do
        repeat(3) do |i|
          seen = (seen * 10) + i + (depth * 5)
          wait_vblank if depth.zero?
        end
      end
      beat.on_tick do
        depth += 1
        call :step
        depth -= 1
      end
      game_loop do
        seen = 0
        call :step
      end
    end
    b.finalize_program
    seen = {}
    run = game_player
    run.each_vblank { |frame| seen[frame] = run[:seen] }.run(b.program, frames: 3)

    assert_equal 567, seen.fetch(1)
  end

  # ...AND the interrupted call carries on where it was. The game waits inside :walk, four steps a
  # walk, and every other frame the tick runs :walk again from its start, to its end without
  # waiting. The game's own walk then goes on from the step it had reached, so a walk takes the
  # game four of its frames however often the tick walks too. A build that runs the game's routines
  # a step at a time keeps the routine's place and count for the tick's call and puts them back
  # after; one that did not would carry on from where the tick's walk ended.
  def test_a_call_a_handler_interrupted_carries_on_where_it_was
    b = Builder.new(options: VBlank::Cartridge::Options.new(frame_sync: :manual))
    b.instance_eval do
      screen :bitmap
      waiting = var :waiting, 0
      steps = var :steps, 0
      walks = var :walks, 0
      answered = var :answered, 0
      func(:walk) do
        repeat(4) do
          steps += 1
          wait_vblank if waiting == 1
        end
      end
      beat = timer :beat, per_second: 30
      beat.on_tick do
        waiting = 0
        call :walk
        waiting = 1
        answered += 1
      end
      game_loop do
        waiting = 1
        call :walk
        walks += 1
        wait_vblank
      end
    end
    b.finalize_program
    seen = {}
    run = game_player
    run.each_vblank { |frame| seen[frame] = [run[:steps], run[:walks], run[:answered]] }.run(b.program, frames: 14)

    # The interpreter's answer, frame by frame: steps the game and the tick took, walks the game
    # finished, ticks answered.
    assert_equal [[1, 0, 0], [6, 0, 1], [7, 0, 1], [12, 0, 2], [12, 1, 2], [17, 1, 3], [18, 1, 3], [23, 1, 4], [24, 1, 4],
                  [28, 2, 5], [29, 2, 5], [34, 2, 6], [35, 2, 6], [40, 2, 7]], (1..14).map { |frame| seen.fetch(frame) }
  end

  # A handler that waits inside its own loop keeps its place in it. Its wait is a frame boundary too, so the
  # handler runs again inside it, to its end without waiting, and the first run then goes on from the turn it
  # had reached: a run that waits takes three frames, and the runs inside it walk three turns each. A
  # cartridge keeps a loop's count at a fixed place, which the inner run would leave finished.
  #
  # The interpreter reports no moment for the frame whose handler waits, and two for the frame its last wait
  # ends: the first as that wait ends, the second as the boundary that ran the handler does. The first is
  # the one read here.
  def test_a_handler_waiting_inside_a_repeat_keeps_its_turn
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      depth = var :depth, 0
      outer = var :outer, 0
      inner = var :inner, 0
      finished = var :finished, 0
      beat = timer :beat, per_second: 60
      beat.on_tick do
        depth += 1
        repeat(3) do
          if depth == 1
            outer += 1
            wait_vblank
          else
            inner += 1
          end
        end
        finished += 1 if depth == 1
        depth -= 1
      end
      game_loop { wait_vblank }
    end
    b.finalize_program
    reads = %i[outer inner finished depth]
    seen = {}
    run = game_player
    run.each_vblank { |frame| seen[frame] ||= reads.map { |name| run[name] } }.run(b.program, frames: 9)

    assert_equal({ 2 => [1, 3, 0, 1], 3 => [2, 6, 0, 1], 4 => [3, 9, 0, 1], 6 => [4, 12, 1, 1], 7 => [5, 15, 1, 1],
                   8 => [6, 18, 1, 1] }, seen)
    assert_equal [7, 18, 2, 1], reads.map { |name| run[name] }
  end

  # ...AND the same when the wait is in a routine it calls. Two turns here, each waiting in :breather. The
  # game's waits are its own (`frame_sync: :manual`), so the routine's is not taken as the game loop's.
  def test_a_handler_waiting_in_a_routine_inside_a_repeat_keeps_its_turn
    b = Builder.new(options: VBlank::Cartridge::Options.new(frame_sync: :manual))
    b.instance_eval do
      screen :bitmap
      depth = var :depth, 0
      outer = var :outer, 0
      inner = var :inner, 0
      func(:breather) do
        wait_vblank
      end
      beat = timer :beat, per_second: 60
      beat.on_tick do
        depth += 1
        repeat(2) do
          if depth == 1
            outer += 1
            call :breather
          else
            inner += 1
          end
        end
        depth -= 1
      end
      game_loop { wait_vblank }
    end
    b.finalize_program
    reads = %i[outer inner depth]
    seen = {}
    run = game_player
    run.each_vblank { |frame| seen[frame] ||= reads.map { |name| run[name] } }.run(b.program, frames: 8)

    assert_equal({ 2 => [1, 2, 1], 3 => [2, 4, 1], 5 => [3, 6, 1], 6 => [4, 8, 1], 8 => [5, 10, 1] }, seen)
  end

  # A handler can draw. On a painted screen it draws what the game's own lines draw, a number
  # here; on a tear-free one what it draws goes on the page being drawn, so the loop's next
  # clear takes it away before that page is shown and the screen stays blue. (A Color keeps one
  # page, the one being drawn, so there too the clear covers it before the run ends.) Every lowering
  # plays these against the interpreter, picture and all.
  def test_a_handler_draws_on_a_painted_screen
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      hits = var :hits, 0
      beat = timer :beat, per_second: 30
      beat.on_tick do
        hits += 1
        draw_number :hits, 8, 8, :white, digits: 2
      end
      game_loop { wait_vblank }
    end

    played = game_player.run(b.program, frames: 10)
    assert_equal 5, played[:hits]
    refute_equal played.screen.pixel(0, 0), played.screen.pixel(8 + 6, 8 + 3), "the number is drawn"
  end

  def test_a_handler_draws_on_the_page_being_drawn_on_a_tear_free_screen
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      beat = timer :beat, per_second: 60
      beat.on_tick { draw_rect_at 40, 40, 16, 16, :red }
      game_loop { clear_screen :blue }
    end

    assert_equal Color.resolve(:blue), game_player.run(b.program, frames: 6).screen.pixel(44, 44)
  end

  # ...AND what it draws waits for the page after, however much it draws: a hundred and fifty squares are more
  # than a console keeps waiting at once, and none of them shows over the blue. The squares read are the first
  # and one inside the smallest screen, the Color's.
  def test_a_handler_drawing_much_on_a_tear_free_screen_draws_on_the_page_being_drawn
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      beat = timer :beat, per_second: 60
      beat.on_tick do
        repeat(150) { |i| draw_rect_at (i % 15) * 16, (i / 15) * 16, 8, 8, :red }
      end
      game_loop { clear_screen :blue }
    end

    screen = game_player.run(b.program, frames: 6).screen
    assert_equal [Color.resolve(:blue)] * 2, [screen.pixel(2, 2), screen.pixel(130, 130)]
  end

  # A sprite over a tear-free picture that a handler moves shows where the pass left it, on that pass's
  # frame: the frame boundary places it before the handler runs, and the handler's move shows a frame later.
  # The first frame is not read: a console that keeps two pages places the sprite as the boundary trades
  # them, and one that keeps one (the Color, the Super Nintendo, the Genesis) has placed nothing before the
  # first pass's sprites, which come after its first wait.
  def test_a_handler_moving_a_sprite_over_a_tear_free_picture
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      image(:dot, "R" => :red) { "RRRR\nRRRR\nRRRR\nRRRR" }
      dot = sprite :dot, at: [20, 60], over_picture: true
      beat = timer :beat, per_second: 60
      beat.on_tick { dot.x += 8 }
      game_loop { clear_screen :blue }
    end
    b.finalize_program

    seen = []
    run = game_player
    run.each_vblank { (seen << (0...240).find { |x| run.screen.pixel(x, 61) == Color.resolve(:red) }) }
       .run(b.program, frames: 6)
    assert_equal [28, 36, 44, 52, 60], seen.drop(1)
  end

  # A handler reads the buttons of the frame it ticks on: A held for three frames is three ticks
  # holding it and one press, and a tap later is one more of each.
  def test_a_handler_reads_the_buttons_of_its_frame
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      downs = 0
      presses = 0
      beat = timer :beat, per_second: 60
      beat.on_tick do
        downs += 1 if held(:a)
        presses += 1 if pressed(:a)
      end
      game_loop { wait_vblank }
    end
    played = game_player.input_each_frame { |frame| (4..6).cover?(frame) || frame == 9 ? [:a] : [] }
                        .run(b.program, frames: 12)

    assert_equal [4, 2], [played[:downs], played[:presses]]
  end

  # The fastest rate a timer can be given counts as the interpreter counts it, with nothing
  # going round in the sum of a frame's sixtieths.
  def test_the_fastest_rate_counts_every_tick
    assert_equal (2_147_483_647 * 3 / 60) % 65_536, run_ticks(per_second: 2_147_483_647, stop_frame: 3)[:snap]
  end

  # A second handler for the same timer replaces the first rather than running beside it,
  # on both runners.
  def test_a_second_handler_for_a_timer_replaces_the_first
    i = game_player.run(two_handlers_program, frames: 10)

    assert_equal [0, 10], [i[:first], i[:second]]
  end
end
