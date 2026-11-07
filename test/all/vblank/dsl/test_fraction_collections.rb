# frozen_string_literal: true

require "test_helper"

# MANY OF SOMETHING THAT HOLDS A FRACTION.
#
# A variable takes a Float and carries the scale through every piece of arithmetic, so a game
# writes halves and quarters and never mentions fixed point. A list and a pool field are where
# a game keeps MANY of something, and they have to do the same — otherwise the moment a game
# needs sixty particles drifting at fractional speeds it has to pick a scale and carry it by
# hand, which is the exact bookkeeping the fraction support exists to remove.
#
# The Advance's cartridge is held to the interpreter's picture in the emulator in
# test/lowering/gba/vblank/dsl/test_fraction_collections_cartridge.rb.
class TestFractionCollections < Minitest::Test
  private def run_program(&block)
    prog = VBlank.game("FRAC", consoles: %i[gba], code: "ZFRC", maker: "01") do
      screen :bitmap
      instance_eval(&block)
    end.program
    game_player.run(prog, frames: 2)
  end

  # --- a list ---

  def test_a_list_hands_back_what_was_put_into_it_fraction_and_all
    run = run_program do
      speeds = list :speeds, capacity: 8, holds: 0.0
      total = var :total, 0.0
      game_loop do
        speeds << 1.5
        speeds << 0.25
        total = speeds[0] + speeds[1]
        halt
      end
    end

    assert_equal 1.75, run[:total]
  end

  # The scale is declared once, on the list, and arithmetic carries it from there — so a value
  # read out of a list drops straight into the expression DSL beside a variable that holds one.
  def test_a_value_from_a_list_meets_a_variable_that_holds_a_fraction
    run = run_program do
      speeds = list :speeds, capacity: 4, holds: 0.0
      here = var :here, 10.0
      game_loop do
        speeds << 0.5
        here += speeds[0]
        halt
      end
    end

    assert_equal 10.5, run[:here]
  end

  # How MANY items is a count, whatever the items are. Half an item is not a thing.
  def test_the_length_of_a_list_of_fractions_is_still_a_plain_count
    run = run_program do
      speeds = list :speeds, capacity: 4, holds: 0.0
      many = var :many, 0
      game_loop do
        speeds << 1.5
        speeds << 2.5
        many = speeds.length
        halt
      end
    end

    assert_equal 2, run[:many]
  end

  def test_a_list_of_whole_numbers_refuses_a_fraction_and_says_how_to_change_it
    err = assert_raises(ArgumentError) do
      run_program do
        counts = list :counts, capacity: 4
        game_loop { counts << 1.5 }
      end
    end

    assert_match(/holds: 1.5/, err.message)
    assert_match(/list :counts/, err.message)
  end

  # The mismatch that cannot be fixed for free: the list holds fractions and the number is a
  # whole one the game worked out, so nothing can say what it counts.
  def test_a_list_of_fractions_refuses_a_whole_number_the_game_works_out
    err = assert_raises(ArgumentError) do
      run_program do
        speeds = list :speeds, capacity: 4, holds: 0.0
        n = var :n, 0
        game_loop { speeds << n }
      end
    end

    assert_match(/list :speeds/, err.message)
    assert_match(/to_f/, err.message)
  end

  def test_holds_wants_an_example_number
    err = assert_raises(ArgumentError) do
      run_program { list :speeds, capacity: 4, holds: :fractions }
    end

    assert_match(/holds:/, err.message)
  end

  # --- a pool field ---

  def test_a_pool_field_declared_with_a_fraction_keeps_one
    run = run_program do
      sparks = pool :spark, x: 0.0, vy: 0.0, capacity: 8
      seen = var :seen, 0.0
      game_loop do
        sparks.spawn(x: 10.0, vy: 0.5)
        sparks.each do |s|
          s.x += s.vy
          seen = s.x
        end
        halt
      end
    end

    assert_equal 10.5, run[:seen]
  end

  # A pool keeps whole numbers and fractions side by side, and each field follows its own
  # declaration — a life counter counts, a speed does not.
  def test_a_pools_whole_field_and_its_fraction_field_do_not_get_confused
    run = run_program do
      sparks = pool :spark, x: 0.0, life: 0, capacity: 8
      left = var :left, 0
      where = var :where, 0.0
      game_loop do
        sparks.spawn(x: 4.0, life: 3)
        sparks.each do |s|
          s.life -= 1
          s.x += 0.5
          left = s.life
          where = s.x
        end
        halt
      end
    end

    assert_equal 2, run[:left]
    assert_equal 4.5, run[:where]
  end

  def test_a_whole_pool_field_refuses_a_fraction_and_names_the_field
    err = assert_raises(ArgumentError) do
      run_program do
        sparks = pool :spark, hp: 0, capacity: 4
        game_loop { sparks.spawn(hp: 1.5) }
      end
    end

    assert_match(/pool :spark/, err.message)
    assert_match(/hp: 1.5/, err.message)
  end

  # The read-modify-write mutators go through a scratch variable, so they are the ones that
  # could quietly lose a field's scale.
  def test_a_fraction_field_still_holds_its_scale_through_clamp_and_approach
    run = run_program do
      movers = pool :mover, x: 0.0, capacity: 4
      seen = var :seen, 0.0
      game_loop do
        movers.spawn(x: 9.0)
        movers.each do |m|
          m.x.approach! 10.0, 0.25
          m.x.clamp! 0.0, 20.0
          seen = m.x
        end
        halt
      end
    end

    assert_equal 9.25, run[:seen]
  end
end
