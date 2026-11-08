# frozen_string_literal: true

require "test_helper"

# Defined by a file of this project outside the part's folder and outside the folder that loads it.
PART_REFUSALS_PROJECT_NUMBER = 7

# A FILE OF A GAME IS CHECKED AS A GAME BLOCK IS. A part brought in by `VBlank.require_game_file`
# that calls outside the game, or uses a constant from outside it, is refused with the words the
# same line in a game block gets.
class TestPlainRubyPartRefusals < Minitest::Test
  # Brings game files into the whole process: it adds to $LOADED_FEATURES and declares the
  # fixtures' modules, which a test in a Ractor cannot do.
  runs_on_the_main_ractor!

  Refused = VBlank::DSL::PlainRuby::Refused

  private def bring_in(name) = VBlank.require_game_file("../../../fixtures/game_parts_refused/#{name}")

  def test_a_part_calling_outside_the_game_is_refused
    error = assert_raises(Refused) { bring_in("calls_system") }

    assert_includes error.message, "`system`"
    assert_includes error.message, "calls_system.rb:5"
  end

  def test_a_part_using_a_constant_from_outside_the_game_is_refused
    error = assert_raises(Refused) { bring_in("uses_outside_constant") }

    assert_includes error.message, "`File`"
  end

  def test_a_part_in_a_folder_of_its_own_naming_a_constant_of_the_games_project_is_brought_in
    bring_in("deep/names_project_constant")

    assert_equal 7, PartNamingProjectConstant.value
  end

  # Ruby's own errors reach nothing outside the game, so a method raising one is plain Ruby.
  def test_a_part_raising_one_of_rubys_errors_is_brought_in
    bring_in("raises_friendly_error")

    assert_raises(ArgumentError) { PartRaisingFriendlyError.checked(9) }
  end

  def test_a_part_naming_its_own_constants_and_a_later_parts_is_brought_in
    bring_in("own_constants")

    assert_equal 3, PartWithOwnConstants.speed
  end
end
