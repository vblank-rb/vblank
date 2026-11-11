# frozen_string_literal: true

require "test_helper"

# TABLES, CHANCE AND TIMERS ON A PC, in DOSBox, held to the interpreter on every pass (DOS::CheckedRun). What a
# timer does is in test/all/vblank/builder/test_timer.rb, which this run plays; these are what is DOS's own:
# a table is kept in the segment the pictures are in, at the width its numbers fit, and read through DS; and
# a timer's handler runs inside the wait, from the runtime.
class TestDOSTablesTimers < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  private def checked(frames: nil, &game)
    DOS::CheckedRun.new.run(VBlank.game("DOSGAME", consoles: %i[dos], &game).program(console: :dos), frames: frames)
  end

  # Tables of every width, with and without a sign, read at every place and well past both ends: a table
  # whose length is a power of two comes round, and any other is held to its ends.
  def test_tables_of_every_width_read_at_and_past_their_ends
    run = checked(frames: 24) do
      screen :bitmap
      bytes = table :bytes, [0, 1, 200, 255, 17, 90, 3, 128], width: :byte
      small = table :small, [-128, -1, 0, 127, 5], width: :byte
      halves = table :halves, [-32_768, 32_767, -2, 300, 7, 9, 11], width: :half
      words = table :words, [2_000_000_000, -2_000_000_000, 65_536, -65_537], width: :word
      at = var :at, -9
      sum = var :sum, 0
      last = var :last, 0
      game_loop do
        last = bytes[at] + small[at] + halves[at] + words[at]
        sum += last
        at += 1
      end
    end

    assert_equal 15, run[:at]
    assert_equal 3 + 5 + 11 + 65_536, run[:last], "at 14: places 6 of eight and 2 of four, coming round, and the last of the other two"
  end

  # A picture, a table and a sprite's table all in the one segment: each is found where it was put.
  def test_a_table_beside_pictures_in_the_art_segment
    run = checked(frames: 6) do
      screen :bitmap
      image :dot, width: 2, height: 2, data: %i[red red red red]
      places = table :places, [10, 60, 110, 160, 210, 260], width: :half
      at = var :at, 0
      clear_screen :blue
      game_loop do
        blit :dot, places[at], 50
        at += 1
      end
    end

    assert_equal [VBlank::Graphics::Color.resolve(:red)] * 2, [run.screen.pixel(10, 50), run.screen.pixel(261, 51)]
  end

  # A chance in a hundred, drawn from the game's stream of random numbers, counted over many passes.
  def test_a_chance_comes_up_about_as_often_as_it_says
    run = checked(frames: 200) do
      screen :bitmap
      seed 12_345
      often = var :often, 0
      never = var :never, 0
      always = var :always, 0
      game_loop do
        often += 1 if chance(25)
        never += 1 if chance(0)
        always += 1 if chance(100)
      end
    end

    assert_equal [0, 200], [run[:never], run[:always]]
    assert_includes 25..75, run[:often]
  end

  # Two timers at rates that are not a whole number of ticks a frame, one stopped part way, each with a
  # handler that paints and counts, in the order they were first started.
  def test_two_timers_tick_at_their_own_rates_and_run_their_handlers
    run = checked(frames: 90) do
      screen :bitmap
      fast = timer :fast, per_second: 45
      slow = timer :slow, per_second: 7
      fast_ticks = var :fast_ticks, 0
      slow_ticks = var :slow_ticks, 0
      order = var :order, 0
      passes = var :passes, 0
      slow.on_tick do
        slow_ticks += 1
        order = (order * 3) + 1
        draw_rect_at slow_ticks * 6, 20, 4, 4, :green
      end
      fast.on_tick do
        fast_ticks += 1
        order = (order * 3) + 2
      end
      game_loop do
        passes += 1
        fast.stop if passes == 30
      end
    end

    assert_equal 10, run[:slow_ticks]
    assert_includes 20..24, run[:fast_ticks], "three ticks every four frames, for the thirty passes before it was stopped"
  end

  # A handler that waits a frame is in the middle of its own loop, and of the frame's ticks, when the next
  # frame's ticks run it again: its loop's count and the ticks still to answer are its own each time.
  def test_a_handler_that_waits_a_frame_carries_on_where_it_was
    in_a_loop = checked(frames: 6) do
      screen :bitmap
      beat = timer :beat, per_second: 60
      n = var :n, 0
      beat.on_tick do
        repeat(3) do
          n += 1
          wait_vblank if n == 2
        end
      end
      game_loop {}
    end
    many_a_frame = checked(frames: 5) do
      screen :bitmap
      beat = timer :beat, per_second: 150
      n = var :n, 0
      k = var :k, 0
      busy = var :busy, 0
      beat.on_tick do
        n += 1
        if busy == 0 && n % 4 == 1
          busy = 1
          wait_vblank
          k += 7
          busy = 0
        end
      end
      game_loop {}
    end

    assert_operator in_a_loop[:n], :>=, 6
    assert_operator many_a_frame[:k], :>=, 7
  end
end
