# frozen_string_literal: true

require "test_helper"

# The buttons only a PlayStation pad has, L2 and R2, and the pad's own names for the buttons it
# shares (Cross is :a). What every console's buttons do is test/all/vblank/builder/test_input.rb.
# L2 and R2 are the last of IR::Buttons::NAMES, so they are the buttons a build loses when it keeps
# fewer bits of a player's buttons than that list has.
class TestInputOnThePlayStation < Minitest::Test
  # Counts of the passes L2 and R2 were held, the times each went down, the presses of any button,
  # and of Cross and Triangle by the pad's own names; and the second player's L2.
  private def counting_game
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :ps1))
    builder.instance_eval do
      held_l2 = var :held_l2, 0
      pressed_l2 = var :pressed_l2, 0
      held_r2 = var :held_r2, 0
      any = var :any, 0
      cross = var :cross, 0
      triangle = var :triangle, 0
      second_l2 = var :second_l2, 0
      game_loop do
        held_l2 += 1 if held(:l2)
        pressed_l2 += 1 if pressed(:l2)
        held_r2 += 1 if held(:r2)
        any += 1 if pressed(:any)
        cross += 1 if pressed(:cross)
        triangle += 1 if held(:triangle)
        second_l2 += 1 if pressed(:l2, player: 2)
      end
    end
    builder.finalize_program
    builder.program
  end

  private def played(frames, &buttons) = game_player.input_each_frame(&buttons).run(counting_game, frames: frames)

  def test_l2_and_r2_are_held_for_as_long_as_they_are_down
    run = played(10) { |frame| [(:l2 if frame.between?(2, 4)), (:r2 if frame.between?(3, 4))].compact }

    assert_equal [3, 1, 2], [run[:held_l2], run[:pressed_l2], run[:held_r2]]
  end

  def test_l2_and_r2_are_any_button
    run = played(10) { |frame| { 2 => [:l2], 6 => [:r2] }.fetch(frame, []) }

    assert_equal 2, run[:any]
  end

  # :cross is :a and :triangle is :x: a test holds the shared names, which are the same buttons.
  def test_the_pads_own_names_are_the_shared_buttons
    run = played(10) { |frame| frame.between?(2, 3) ? %i[a x] : [] }

    assert_equal [1, 2], [run[:cross], run[:triangle]]
  end

  # The pad's L2 is on or off (psx-spx, Controllers): held part of the way it reads all of the way,
  # and touched less than IR::Buttons::HELD_FROM it is not held.
  def test_l2_reads_all_or_nothing_however_far_it_is_held
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :ps1))
    builder.instance_eval do
      total = var :total, 0
      game_loop { total += pulled(:l2) }
    end
    builder.finalize_program
    pulls = { 2 => 40, 3 => 40, 4 => VBlank::IR::Buttons::HELD_FROM - 1 }
    run = game_player.input_each_frame { |frame| [{ l2: pulls.fetch(frame, 0) }] }.run(builder.program, frames: 8)

    assert_equal 200, run[:total]
  end

  def test_the_second_players_l2_is_theirs
    run = played(10) { |frame| frame == 3 ? [:p2_l2] : [] }

    assert_equal [1, 0], [run[:second_l2], run[:pressed_l2]]
  end
end
