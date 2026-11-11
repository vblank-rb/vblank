# frozen_string_literal: true

require "test_helper"
require "differential"
require "console/gba/vblank/builder/test_spotlight_outside_nothing_on_the_advance"

# A light that shows nothing outside it over a see-through layer, on the Advance's cartridge:
# the picture the emulator draws, and what the cartridge left in the display's registers. What
# such a light shows on every run that plays the Advance's games is in
# test/console/gba/vblank/builder/test_spotlight_outside_nothing_on_the_advance.rb.
class TestSpotlightOutsideNothingCartridge < Minitest::Test
  include Differential
  include SpotlightOutsideNothingGames

  BLACK = Color.rgb(0, 0, 0)

  # The cartridge's picture after the interpreter's +frames+, as a list of colours.
  private def cartridge_picture(frames)
    _, console, = backend_pictures(clouds_under_a_closing_circle, frames: frames, name: "SHUTCART")
    console
  end

  private def at(picture, x, y) = pixel_at(picture, x, y)

  def test_the_cartridge_mixes_the_layer_inside_a_closing_circle_and_draws_nothing_outside
    mixed = at(cartridge_picture(BEFORE), 5, 5)
    closing = cartridge_picture(CLOSING)

    refute_includes [Color.resolve(:white), Color.resolve(:red), BLACK], mixed, "the layer is mixed with the room"
    assert_equal mixed, at(closing, 120, 80), "inside the circle the layer goes on mixing"
    assert_equal BLACK, at(closing, 5, 5), "outside it nothing is drawn"
  end

  def test_the_cartridge_shows_nothing_when_shut_and_the_mixed_layer_again_as_it_opens
    mixed = at(cartridge_picture(BEFORE), 5, 5)
    opening = cartridge_picture(OPENING)

    assert_equal [BLACK], cartridge_picture(SHUT).uniq
    assert_equal mixed, at(opening, 120, 80)
    assert_equal BLACK, at(opening, 5, 5)
    assert_equal [mixed], cartridge_picture(OPEN).uniq
  end

  # THE CIRCLE IS THE WINDOW ALONE. The part of the display that mixes the picture holds the
  # see-through layer's mix while the circle closes, never a darkening, and outside the window
  # no layer is switched on.
  def test_the_closing_circle_leaves_the_mixing_to_the_layer
    rom = assemble_rom(clouds_under_a_closing_circle, name: "SHUTREGS")
    console = assert_emulator_loads_rom(rom, frames: SHUT)
    hardware = VBlank::Console::Hardware

    assert_equal hardware::BLD_ALPHA, console.mem16(hardware::REG_BLDCNT) & hardware::BLD_DARKEN,
                 "the blend unit mixes two layers"
    assert_equal 0, console.mem16(hardware::REG_WINOUT) & 0xFF, "nothing is switched on outside the window"
  end
end
