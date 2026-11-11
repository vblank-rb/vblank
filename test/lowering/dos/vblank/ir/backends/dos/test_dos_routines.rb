# frozen_string_literal: true

require "test_helper"

# ROUTINES AND SCENES ON A PC, in DOSBox, held to the interpreter on every pass (DOS::CheckedRun). What `func`,
# `scene` and `case_var` do is in test/all/vblank/builder/test_scenes.rb and its neighbours, which this run
# plays too; these are what is DOS's own: a routine is a near call in the one code segment, its numbers are
# kept in the data segment, and a wait or a stop can come in the middle of one.
class TestDOSRoutines < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  private def checked(frames: nil, &game)
    DOS::CheckedRun.new.run(VBlank.game("DOSGAME", consoles: %i[dos], &game).program(console: :dos), frames: frames)
  end

  # Routines that call routines, each with a loop of its own, so the numbers each keeps for its loop are
  # its own, and a routine that waits a frame in the middle and is come back to.
  def test_routines_call_routines_and_wait_in_the_middle
    run = checked(frames: 12) do
      screen :bitmap
      total = var :total, 0
      waits = var :waits, 0
      func :inner do
        repeat(3) { total += 1 }
      end
      func :outer do
        repeat(4) { call :inner }
        waits += 1
        wait_vblank
        total += 100
      end
      game_loop { call :outer }
    end

    assert_operator run[:waits], :>=, 5
    assert_includes [run[:waits] * 112, (run[:waits] * 112) - 100], run[:total], "twelve a call, and a hundred for each wait come back from"
  end

  # A stop inside a routine, three calls down, ends the game there.
  def test_a_stop_inside_a_routine_ends_the_game
    run = checked do
      screen :bitmap
      reached = var :reached, 0
      func :last do
        reached += 1
        halt
      end
      func :middle do
        call :last
        reached += 10
      end
      func :first do
        call :middle
        reached += 100
      end
      call :first
      reached += 1000
    end

    assert_equal 1, run[:reached]
  end

  # Scenes that hand on to each other, one a pass, with a picture each paints as it arrives.
  def test_scenes_take_turns_and_each_paints_as_it_runs
    run = checked(frames: 9) do
      screen :bitmap
      state = var :state, 0
      turns = var :turns, 0
      scene(:title) do
        fill_rect 0, 0, 20, 20, :red
        state = 1
      end
      scene(:play) do
        fill_rect 30, 0, 20, 20, :green
        turns += 1
        state = 2 if turns == 3
      end
      scene(:over) { fill_rect 60, 0, 20, 20, :blue }
      game_loop do
        case_var :state do
          when_val 0, :title
          when_val 1, :play
          when_val 2, :over
        end
      end
    end

    assert_equal [3, 2], [run[:turns], run[:state]]
    assert_equal VBlank::Graphics::Color.resolve(:blue), run.screen.pixel(70, 10)
  end

  # Something every few frames and something once after a while, counted in a game that never stops.
  def test_steps_that_come_round_every_few_frames_and_once_after_some
    run = checked(frames: 40) do
      screen :bitmap
      beats = var :beats, 0
      late = var :late, 0
      game_loop do
        every(6) { beats += 1 }
        after(25) { late += 1 }
      end
    end

    assert_equal 1, run[:late]
    assert_operator run[:beats], :>=, 6
  end
end
