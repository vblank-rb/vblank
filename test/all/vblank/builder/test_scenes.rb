# frozen_string_literal: true

require "test_helper"

# Scenes, the dispatch that picks one (`case_var`), and routines declared from inside another
# routine's body, played on every run. That each of them builds into the Advance's cartridge and
# does the same on its console, read in the emulator, is in
# test/lowering/gba/vblank/builder/test_scenes_cartridge.rb, which plays the games kept here in
# ScenesGames.
module ScenesGames
  include SharedConstants # Builder, which the game below names from inside the module

  # The same guarantee where it is hardest to keep: the scene that runs changes the
  # state, which is what a scene ordinarily does on its last line. Scenes are numbered
  # in the order a player meets them, so an ordinary transition goes FORWARD — to a
  # clause the dispatch has not reached yet. Each scene here hands on to the next, so a
  # dispatch that answered the new value would run the whole table in one pass.
  #
  # One pass, one scene body: nothing but the first counter moves.
  private def handing_on_game(builder)
    builder.instance_eval do
      screen :bitmap
      state = var :state, 0
      ran_first = 0
      ran_second = 0
      ran_third = 0
      scene(:first)  { ran_first += 1;  state = 1 }
      scene(:second) { ran_second += 1; state = 2 }
      scene(:third)  { ran_third += 1 }

      case_var :state do
        when_val 0, :first
        when_val 1, :second
        when_val 2, :third
      end
      halt
    end
  end

  OVER = 2 # The state the last of #three_screens is up for

  # Three screens picked by a number, each handing on to the next on a pass the loop counts, the
  # last named by a constant. +plain_case+ picks with a plain Ruby `case`, and
  # otherwise with `case_var`. The title has a sprite of its own, shown only while it is up.
  private def three_screens(plain_case:)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:block, "#" => :red) { "########\n" * 8 }
      state = 0
      step = 0
      ran_title = 0
      ran_play = 0
      ran_over = 0
      scene(:title) do
        sprite :block, at: [40, 40]
        ran_title += 1
        state = 1 if step == 2
      end
      scene(:play) do
        ran_play += 1
        state = OVER if step == 5
      end
      scene(:over) do
        ran_over += 1
        state = 0 if step == 8
      end
      if plain_case
        game_loop do
          case state
          when 0 then call :title
          when 1 then call :play
          when OVER then call :over
          end
          step += 1
        end
      else
        game_loop do
          case_var :state do
            when_val 0, :title
            when_val 1, :play
            when_val OVER, :over
          end
          step += 1
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # A routine declared the first time something asks for it: the outer one declares the
  # middle one inside its own body, and the middle one declares the inner one. Bodies are
  # built after the program block, so these declarations happen while other bodies are
  # being built — and each must still be built, or the call to it goes nowhere.
  private def declared_inside_game(builder)
    builder.instance_eval do
      ran_outer = 0
      ran_middle = 0
      ran_inner = 0
      func(:outer) do
        ran_outer += 1
        func(:middle) do
          ran_middle += 1
          func(:inner) { ran_inner += 1 }
          call :inner
        end
        call :middle
      end
      call :outer
      halt
    end
  end

  # A title that hands over on its third pass to :play, on a tiled screen. :play has a sprite
  # of its own, whose picture is copied into video memory as it takes over, and notes the
  # pass it first ran on.
  private def handing_over(loads_first:, first: 0)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:block, "#" => :red) { "########\n" * 8 }
      state = var :state, first
      step = 0
      began = -1
      scene(:title) { state = 1 if step == 2 }
      scene(:play, loads_first: loads_first) do
        sprite :block, at: [40, 40]
        began = step if began == -1
      end
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
        step += 1
      end
    end
    builder.finalize_program
    builder.program
  end
end

class TestScenes < Minitest::Test
  include ScenesGames

  # ========================================================================
  # case_var
  # ========================================================================

  def test_a_scene_that_hands_on_does_not_run_the_scene_it_hands_to
    builder = Builder.new
    handing_on_game(builder)
    builder.finalize_program
    ran = game_player.run(builder.program)

    assert_equal [1, 0, 0], [ran[:ran_first], ran[:ran_second], ran[:ran_third]],
                 "one pass should run one scene body, whatever that scene sets the state to"
    assert_equal 1, ran[:state], "the scene it handed on to runs on the NEXT pass"
  end

  # ========================================================================
  # A plain Ruby case that picks a scene
  # ========================================================================

  def test_scenes_picked_by_a_plain_case_play_as_with_case_var
    counts = ->(ran) { %i[ran_title ran_play ran_over state].map { |name| ran[name] } }
    by_case_var = game_player.run(three_screens(plain_case: false), frames: 12)
    by_plain_case = game_player.run(three_screens(plain_case: true), frames: 12)

    assert_equal [6, 3, 3, 0], counts.call(by_case_var)
    assert_equal counts.call(by_case_var), counts.call(by_plain_case)
  end

  def test_a_scenes_sprite_shows_only_while_a_plain_case_has_it_up
    shown = lambda do |plain_case, frames|
      player = game_player
      player.run(three_screens(plain_case: plain_case), frames: frames)
      player.screen.pixel(44, 44)
    end

    refute_equal shown.call(false, 2), shown.call(false, 6), "the title's sprite goes when play takes over"
    assert_equal [shown.call(false, 2), shown.call(false, 6)], [shown.call(true, 2), shown.call(true, 6)]
  end

  # A `case` whose arms call funcs is the chain of tests it always was: one arm a pass, though
  # the func that runs hands on to the next value.
  def test_a_plain_case_that_calls_funcs_runs_one_arm_a_pass
    builder = Builder.new
    builder.instance_eval do
      state = 0
      ran_first = 0
      ran_second = 0
      func(:first) { ran_first += 1; state = 1 }
      func(:second) { ran_second += 1 }
      game_loop do
        case state
        when 0 then call :first
        when 1 then call :second
        end
      end
    end
    builder.finalize_program
    ran = game_player.run(builder.program, frames: 3)

    assert_equal [1, 2], [ran[:ran_first], ran[:ran_second]]
  end

  # What a scene shows is held to the one number that picks it, so a second is refused.
  def test_a_plain_case_that_picks_one_scene_with_two_numbers_is_a_friendly_error
    builder = Builder.new
    error = assert_raises(ArgumentError) do
      builder.instance_eval do
        state = 0
        scene(:title) { state = 1 }
        game_loop do
          case state
          when 0, 1 then call :title
          end
        end
      end
    end

    assert_match(/:title with more than one number/, error.message)
  end

  # A scene is picked by a game variable. A `case` on a working-out is a chain of tests, and a
  # scene named there is a friendly error saying what to write.
  def test_a_scene_called_from_a_case_on_a_working_out_is_a_friendly_error
    builder = Builder.new
    builder.instance_eval do
      state = 0
      scene(:title) { state = 1 }
      game_loop do
        case state + 1
        when 1 then call :title
        end
      end
    end
    error = assert_raises(ArgumentError) { builder.finalize_program }

    assert_match(/names a scene/, error.message)
    assert_match(/case state/, error.message)
  end

  # ========================================================================
  # scene loads_first: its pictures go up on a pass of their own
  # ========================================================================

  # The title hands over on pass 2, so :play takes over on pass 3. Its pictures are copied
  # on that pass, and its own work starts on pass 4, in a frame the copy has no part of.
  def test_a_scene_that_loads_first_starts_its_work_on_the_pass_after_it_takes_over
    assert_equal 4, game_player.run(handing_over(loads_first: true), frames: 8)[:began]
  end

  def test_a_scene_starts_its_work_on_the_pass_it_takes_over_unless_it_loads_first
    assert_equal 3, game_player.run(handing_over(loads_first: false), frames: 8)[:began]
  end

  # Up at power-on, nothing handed over to :play, and its copy is part of starting up: a game
  # counting frames from power-on has no hand-over it could move to make up a pass.
  def test_a_scene_that_loads_first_and_is_up_at_power_on_starts_its_work_on_the_first_pass
    assert_equal 0, game_player.run(handing_over(loads_first: true, first: 1), frames: 4)[:began]
  end

  def test_loads_first_that_is_not_true_or_false_is_a_friendly_error
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { scene(:play, loads_first: 1) {} } }

    assert_match(/must be true or false/, error.message)
  end

  # ========================================================================
  # scene measure_holding: what the build holds while it measures the scene
  # ========================================================================

  def test_measure_holding_a_button_the_advance_does_not_have_is_a_friendly_error
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { scene(:play, measure_holding: %i[b x]) {} } }

    assert_match(/:x/, error.message)
    assert_match(/buttons/, error.message)
  end

  def test_measure_holding_something_that_is_not_buttons_or_a_tape_is_a_friendly_error
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { scene(:play, measure_holding: 3) {} } }

    assert_match(/tape/, error.message)
  end

  def test_measure_holding_a_tape_that_counts_passes_is_a_friendly_error
    tape = VBlank::Playthroughs::Tape.parse("vblank tape 1\nrecorded on: PASS 0x00000000\nstarts from: power-on\n" \
                                             "counts: passes\n\n2 b\n")
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { scene(:play, measure_holding: tape) {} } }

    assert_match(/passes/, error.message)
  end

  # Nothing the game does changes: the word is about how the build measures it.
  def test_a_scene_measured_holding_a_button_plays_as_it_did
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      var :state, 0
      n = 0
      scene(:play, measure_holding: %i[b]) { n += 1 }
      game_loop do
        case_var(:state) { when_val 0, :play }
      end
    end
    builder.finalize_program

    assert_equal 3, game_player.run(builder.program, frames: 3)[:n]
  end

  # ========================================================================
  # func declared from inside another func's body
  # ========================================================================

  def test_a_func_declared_inside_another_func_body_is_built_however_deep
    builder = Builder.new
    declared_inside_game(builder)
    builder.finalize_program
    ran = game_player.run(builder.program)

    assert_equal [1, 1, 1], [ran[:ran_outer], ran[:ran_middle], ran[:ran_inner]]
  end
end
