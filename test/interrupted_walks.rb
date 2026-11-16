# frozen_string_literal: true

require "differential"

# Small tiled games in which code the game did not call (a timer's handler, a bend's steps) calls
# a routine the game is part way through, for the Advance cartridge's tests of what each call keeps
# to itself (GBA::FrameBoundaryCalls). Each shows what it found as how far the screen is moved:
# four across for each of its own calls that was cut short, and two once it has finished.
module InterruptedWalks
  include Differential

  RED = VBlank::Graphics::Color.resolve(:red)

  private

  # The cartridge's picture after 100 frames is the interpreter's after as many passes, and that is
  # the picture of a game that has finished: moved two across, so the bars drawn at the left edge
  # and at 8 stand at -2 and 6. The first assertion makes sure the second is not two games that
  # never got going, which show a screen with no bars at all.
  def assert_finished_like_interpreter(program, name:)
    oracle, console, ran = backend_pictures(program, frames: 100, name: name)
    assert_equal [false, true], [pixel_at(oracle, 0, 0), pixel_at(oracle, 6, 0)].map { |color| color == RED },
                 "the interpreter, #{ran} frames in, has finished"
    assert_empty mismatched_pixels(oracle, console).first(3), "the cartridge shows what the interpreter shows"
  end

  # test_timer.rb's test_a_call_a_handler_interrupted_carries_on_where_it_was, as a picture: the
  # game walks four steps, waiting after each, and code it did not call walks again without
  # waiting: a timer's handler, 30 times a second, for +again_from+ :tick, or the bend's steps for
  # its first row, for :bend. :short counts the game's walks that took fewer than four steps of
  # its own, and :done is 2 once three walks are finished. +calls_in_body+ gives the walk's loop
  # two calls, so the cartridge keeps its count in memory rather than in registers (GBA::LoopForm).
  def interrupted_walk_program(again_from:, calls_in_body:)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(frame_sync: :manual))
    b.instance_eval do
      screen :tiled
      image(:bar, "." => :transparent, "#" => :red) { (["##......"] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      water = background :water, tiles: :stripes, map: Array.new(20) { "#" * 30 }
      waiting = var :waiting, 0
      mine = var :mine, 0
      steps = var :steps, 0
      walks = var :walks, 0
      short = var :short, 0
      done = var :done, 0
      func(:own_step) { mine += 1 if waiting == 1 }
      func(:any_step) { steps += 1 }
      func(:walk) do
        repeat(4) do
          if calls_in_body
            call :own_step
            call :any_step
          else
            mine += 1 if waiting == 1
            steps += 1
          end
          wait_vblank if waiting == 1
        end
      end
      if again_from == :tick
        timer(:beat, per_second: 30).on_tick do
          waiting = 0
          call :walk
          waiting = 1
        end
      else
        water.scroll_each_row do |row|
          if row == 0
            waiting = 0
            call :walk
            waiting = 1
          end
          (short * 4) + done
        end
      end
      game_loop do
        waiting = 1
        mine = 0
        call :walk
        short += 1 if mine != 4
        walks += 1
        done = 2 if walks >= 3
        water.scroll_to((short * 4) + done, 0) if again_from == :tick
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end
end
