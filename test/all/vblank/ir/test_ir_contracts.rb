# frozen_string_literal: true

require "test_helper"

# The cross-backend contracts that live in the IR core (peers of IR::Int32): the
# button vocabulary and the screen model. Every backend must agree on these, so
# these tests pin the single source of truth and guard the backends against
# quietly drifting from it.
class TestIRContracts < Minitest::Test
  Buttons = VBlank::IR::Buttons

  def test_the_button_vocabulary_is_every_button_of_any_console
    assert_equal %i[a b down l left r right select start up x y], Buttons::NAMES.sort
    assert Buttons.known?(:start)
    refute Buttons.known?(:turbo)
  end

  def test_the_gba_backend_maps_exactly_the_advances_buttons
    # The console's name -> key-bit mapping must cover every button it has and no
    # stragglers. If they drift, a valid button would fail to lower (or a bogus
    # one would sneak in a mapping) — this catches that at the seam.
    mapped = VBlank::IR::Backends::GBA::BUTTON_BIT.keys
    assert_equal VBlank::Console.described(:gba).buttons.sort, mapped.sort
  end

  def test_the_screen_size_has_a_single_source_of_truth
    advance = VBlank::Console::ADVANCE
    assert_equal [240, 160], advance.screen_size
    # The GBA hardware constants are an alias for the contract, not a second copy.
    assert_equal advance.screen_size, [VBlank::Console::Hardware::SCREEN_WIDTH, VBlank::Console::Hardware::SCREEN_HEIGHT]
  end

  # Before it plays a program, the interpreter has no console, so it has no screen of any size: the
  # program says which, and no console stands in for one a program does not name.
  def test_an_interpreter_that_has_played_nothing_has_no_screen
    screen = VBlank::IR::Backends::Reference.new.screen
    assert_equal [0, 0], [screen.width, screen.height]
  end
end
