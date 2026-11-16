# frozen_string_literal: true

require "test_helper"

VBlank.require_game_file "../../../fixtures/game_with_working_variables/screen_flash"

# A `saved: false` MARK IN A CLASS REOPENED WHILE THE GAME BUILDS. Too late once the variable has
# its first number, since the variable is made already as one a save keeps: the build stops at the
# mark. In time before that, and kept. The tests beside test_saves_keep_everything.rb's.
class TestSavesKeepEverythingReopenedClass < Minitest::Test
  # Reopens LateScreenFlash, which the whole process shares, and adds to the names it keeps in
  # its constants.
  runs_on_the_main_ractor!

  # A game file reopening LateScreenFlash, read as VBlank.require_game_file reads one, but on
  # every call: each test reopens the class in a build of its own. Public: the game block calls it.
  def reopen_late_screen_flash(name)
    path = VBlank.root.join("test", "fixtures", "game_with_working_variables", "#{name}.rb").to_s
    text = VBlank::DSL::PlainRuby.rewritten_file(path, loaded_from: File.dirname(path))
    RubyVM::InstructionSequence.compile(text, path, nil, 1).eval
  end

  def test_a_mark_in_a_class_reopened_after_its_variable_has_its_first_number_is_refused
    test = self
    builder = Builder.new
    error = assert_raises(VBlank::DSL::PlainRuby::Refused) do
      builder.instance_eval do
        LateScreenFlash.new
        test.reopen_late_screen_flash("late_damage_mark")
      end
    end

    assert_match(/@damage.*first number/, error.message)
    assert_match(/late_damage_mark\.rb:6/, error.message)
  end

  def test_a_mark_in_a_class_reopened_before_its_variable_has_its_first_number_is_kept
    test = self
    builder = Builder.new
    builder.instance_eval do
      hearts = var :hearts, 3
      flash = LateScreenFlash.new
      test.reopen_late_screen_flash("late_bonus_mark")
      func(:start_bonus) { flash.start_bonus }
      save_data(:file) { keep hearts }
      saves_keep_everything except: [:late_screen_flash_damage]
      game_loop { call :start_bonus }
    end
    builder.finalize_program
    player = game_player
    player.run(builder.program, frames: 2)

    assert_equal 5, player[:late_screen_flash_bonus]
  end
end
