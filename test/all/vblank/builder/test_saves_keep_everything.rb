# frozen_string_literal: true

require "test_helper"

VBlank.require_game_file "../../../fixtures/game_with_working_variables/screen_flash"

# SAVES KEEP EVERYTHING: a game that saves in the middle of play says so once, and the build
# refuses a cartridge where some of the game's own state is kept by no save_data record — a
# forgotten `keep` becomes a friendly error at build time instead of a load that quietly puts
# back only part of the game.
class TestSavesKeepEverything < Minitest::Test
  private def built(&block)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :guard, width: 8, height: 8, data: [1] * 64
      instance_eval(&block)
    end
    builder.finalize_program
    builder.program
  end

  private def refused(&block) = assert_raises(ArgumentError) { built(&block) }.message

  def test_a_game_whose_records_keep_all_its_state_builds
    built do
      hearts = var :hearts, 3
      var :_scratch, 0 # scratch, never needed after a load
      save_var :best, 0 # saves itself
      var :mode, :title
      doors = list :doors, capacity: 8, width: :byte
      guards = pool :guard, x: 0, y: 0, capacity: 4, image: :guard
      save_data(:settings) { keep hearts }
      save_data(:file) { keep doors, guards, random_numbers }
      saves_keep_everything except: [:mode]
      game_loop { roll :_roll, 1..6 }
    end
  end

  def test_state_no_record_keeps_is_a_friendly_error_naming_each_thing
    message = refused do
      hearts = var :hearts, 3
      var :ammo, 10
      list :doors, capacity: 8
      pool :guard, x: 0, y: 0, capacity: 4, image: :guard
      save_data(:file) { keep hearts }
      saves_keep_everything
      game_loop { roll :hearts, 1..6 }
    end
    assert_match(/no save_data record keeps/, message)
    assert_match(/the variable :ammo/, message)
    assert_match(/the list :doors/, message)
    assert_match(/the pool :guard/, message)
    assert_match(/the random numbers/, message)
    refute_match(/:hearts/, message)
    assert_match(/except:/, message)
  end

  # What a routine keeps or declares is only built at the end, and still counts.
  def test_a_keep_written_inside_a_routine_counts
    built do
      files = save_data :file
      saves_keep_everything
      func(:start_level) { files.keep var(:level, 1) }
      game_loop { call :start_level }
    end

    message = refused do
      hearts = var :hearts, 3
      files = save_data(:file) { keep hearts }
      saves_keep_everything
      func(:start_level) { var :level, 1 }
      game_loop { call :start_level; files[0].save }
    end
    assert_match(/the variable :level/, message)
  end

  # A pool comes back whole only when it is kept whole: one field on its own leaves which
  # slots are live behind.
  def test_a_pool_kept_one_field_at_a_time_is_not_kept
    message = refused do
      guards = pool :guard, x: 0, y: 0, capacity: 4, image: :guard
      save_data(:file) { keep guards.field(:x), guards.field(:y) }
      saves_keep_everything
    end
    assert_match(/the pool :guard/, message)
  end

  def test_leaving_out_a_name_the_game_does_not_declare_is_a_friendly_error
    message = refused do
      hearts = var :hearts, 3
      save_data(:file) { keep hearts }
      saves_keep_everything except: [:heart]
    end
    assert_match(/leaves out :heart/, message)
    assert_match(/no variable, list or pool/, message)

    scratch = refused do
      var :_scratch, 0
      hearts = var :hearts, 3
      save_data(:file) { keep hearts }
      saves_keep_everything except: [:_scratch]
    end
    assert_match(/starts with _/, scratch)

    saves_itself = refused do
      save_var :best, 0
      hearts = var :hearts, 3
      save_data(:file) { keep hearts }
      saves_keep_everything except: [:best]
    end
    assert_match(/:best is a `save_var`, which saves itself/, saves_itself)

    no_rolls = refused do
      hearts = var :hearts, 3
      save_data(:file) { keep hearts }
      saves_keep_everything except: [:random_numbers]
    end
    assert_match(/rolls no random numbers/, no_rolls)
  end

  def test_leaving_out_something_that_is_not_a_name_is_a_friendly_error
    message = refused do
      mode = var :mode, :title
      hearts = var :hearts, 3
      save_data(:file) { keep hearts }
      saves_keep_everything except: [mode]
    end
    assert_match(/takes names in except:/, message)
    assert_match(/To fix this/, message)
  end

  def test_leaving_out_a_thing_a_record_keeps_is_a_friendly_error
    message = refused do
      hearts = var :hearts, 3
      save_data(:file) { keep hearts }
      saves_keep_everything except: [:hearts]
    end
    assert_match(/leaves out :hearts, but save_data :file keeps it/, message)
  end

  def test_a_game_with_no_record_is_a_friendly_error
    assert_match(/declares no save_data record/, refused { var :hearts, 3; saves_keep_everything })
  end

  # WORKING ROOM A PART MARKS. `game_variables ..., saved: false` says a save never keeps those
  # instance variables, so the check passes them over, with no name of their own starting _.
  private def flash_game(part, tick, except: [])
    builder = Builder.new
    builder.instance_eval do
      hearts = var :hearts, 3
      part.new(self)
      save_data(:file) { keep hearts }
      saves_keep_everything(except:)
      game_loop { call tick }
    end
    builder.finalize_program
    builder.program
  end

  def test_working_variables_a_part_marks_unsaved_build_and_are_read_by_their_usual_names
    player = game_player
    player.run(flash_game(ScreenFlash, :screen_flash_tick), frames: 3)

    assert_equal [3, 4], [player[:screen_flash_damage], player[:flash_bonus]]
  end

  # The game block names its own instance variables the same way, and marks them the same way.
  def test_working_variables_the_game_block_marks_unsaved_build
    builder = Builder.new
    builder.instance_eval(&VBlank::DSL::PlainRuby.rewrite(proc do
      game_variables :hearts
      game_variables :flash, saved: false
      @hearts = 3
      @flash = 0
      save_data(:file).keep(@hearts)
      saves_keep_everything
      game_loop { @flash += 1 }
    end))
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 2)

    assert_equal [3, 2], [player[:hearts], player[:flash]]
  end

  def test_the_same_working_variables_unmarked_are_refused
    message = assert_raises(ArgumentError) { flash_game(UnmarkedScreenFlash, :unmarked_screen_flash_tick) }.message

    assert_match(/no save_data record keeps/, message)
    assert_match(/:unmarked_screen_flash_damage/, message)
  end

  def test_a_record_keeping_a_variable_marked_unsaved_is_a_friendly_error
    message = assert_raises(ArgumentError) { flash_game(KeptScreenFlash, :kept_screen_flash_tick) }.message

    assert_match(/save_data :flash keeps :kept_screen_flash_damage/, message)
    assert_match(/saved: false/, message)
  end

  def test_leaving_out_a_variable_marked_unsaved_is_a_friendly_error
    message = assert_raises(ArgumentError) do
      flash_game(ScreenFlash, :screen_flash_tick, except: [:flash_bonus])
    end.message

    assert_match(/leaves out :flash_bonus/, message)
    assert_match(/saved: false/, message)
  end

  def test_saying_it_twice_is_a_friendly_error
    message = refused do
      hearts = var :hearts, 3
      save_data(:file) { keep hearts }
      saves_keep_everything
      saves_keep_everything except: [:mode]
    end
    assert_match(/two times/, message)
  end
end
