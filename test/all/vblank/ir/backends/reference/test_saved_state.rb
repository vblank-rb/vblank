# frozen_string_literal: true

require "test_helper"
require "first_pass_presses"

# WHAT THE GAME'S SAVES KEEP, READ IN ONE PIECE. A game that saves in the middle of play wants a
# test that loads and asks "did everything come back?". `game_state` holds every variable,
# including working room no save keeps (a scratch name starting with _, a part's variable marked
# `game_variables ..., saved: false`), so the test reads `saved_state` instead: the same shape,
# holding only what some save_data record keeps.
class TestSavedState < Minitest::Test
  include FirstPassPresses

  # The presses, counted from the game's first pass: save; and save, change, load.
  SAVED = { 1 => :a }.freeze
  SAVED_CHANGED_LOADED = { 1 => :a, 4 => :b, 7 => :start }.freeze

  # A record keeping the hearts, a list and a pool, beside a working variable marked
  # `saved: false`, a scratch variable and a mode no record keeps. A saves; B changes all of
  # them; START loads. +whole+ adds saves_keep_everything, leaving the mode out. +load_drops+
  # sets the hearts again straight after the load, as a load that left them out would leave them.
  private def kept_game(whole: false, load_drops: false)
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(proc do
      game_variables :hearts, :mode
      game_variables :flash, saved: false
      @hearts = 3
      @mode = 0
      @flash = 0
      _scratch = 0
      items = list :items, capacity: 4
      guards = pool :guard, x: 0, capacity: 2
      files = save_data(:file)
      files.keep @hearts, items, guards
      saves_keep_everything(except: [:mode]) if whole
      game_loop do
        if pressed(:a)
          items.push 5
          guards.spawn(x: 7)
          files[0].save
        end
        if pressed(:b)
          @hearts = 9
          items.push 6
          guards.each { |guard| guard.x = 8 }
          @mode = 2
          @flash = 4
          _scratch = 5
        end
        if pressed(:start)
          files[0].load
          @hearts = 9 if load_drops
        end
      end
    end))
    builder.finalize_program
    builder.program
  end

  private def played(program, pressing)
    game_player.input_each_frame(&presses_from_first_pass(pressing)).run(program, frames: 12)
  end

  def test_the_saved_state_holds_only_what_a_record_keeps
    run = played(kept_game, SAVED)

    assert_equal({ vars: { hearts: 3 }, lists: { items: [5] }, pools: { guard: { x: [nil, 7] } } },
                 run.saved_state)
  end

  def test_a_load_matches_the_saved_moment_where_the_game_state_does_not
    saved = played(kept_game, SAVED)
    loaded = played(kept_game, SAVED_CHANGED_LOADED)

    assert_equal saved.saved_state, loaded.saved_state
    refute_equal saved.game_state, loaded.game_state, "the working variables the load leaves alone differ"
  end

  def test_saves_keep_everything_leaves_out_its_except_names_and_the_working_room
    saved = played(kept_game(whole: true), SAVED)
    loaded = played(kept_game(whole: true), SAVED_CHANGED_LOADED)

    assert_equal [:hearts], saved.saved_state[:vars].keys
    assert_equal saved.saved_state, loaded.saved_state
  end

  def test_a_load_that_leaves_out_something_a_record_keeps_shows
    saved = played(kept_game(load_drops: true), SAVED)
    loaded = played(kept_game(load_drops: true), SAVED_CHANGED_LOADED)

    refute_equal saved.saved_state, loaded.saved_state
    assert_equal 9, loaded.saved_state[:vars][:hearts]
  end

  # A load puts back the one field and leaves the rest of the pool as the game has it, so the
  # field alone is what the save keeps.
  def test_a_pool_kept_one_field_at_a_time_holds_that_field_alone
    builder = Builder.new
    builder.instance_eval do
      guards = pool :guard, x: 0, hp: 3, capacity: 2
      guards.spawn(x: 7)
      save_data(:file) { keep guards.field(:hp) }
      game_loop { wait_vblank }
    end
    builder.finalize_program
    run = game_player.run(builder.program, frames: 2)

    assert_equal({ vars: {}, lists: {}, pools: { guard: { hp: [nil, 3] } } }, run.saved_state)
  end

  def test_a_game_with_no_save_data_record_is_a_friendly_error
    builder = Builder.new
    builder.instance_eval { var :hearts, 3; game_loop { wait_vblank } }
    builder.finalize_program
    run = game_player.run(builder.program, frames: 1)

    assert_match(/no save_data record/, assert_raises(ArgumentError) { run.saved_state }.message)
  end
end
