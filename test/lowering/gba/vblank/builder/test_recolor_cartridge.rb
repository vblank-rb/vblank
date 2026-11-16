# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_recolor"

# A RECOLORED SPRITE ON THE ADVANCE'S CARTRIDGE, read in the emulator. What `recolor` does on
# every run is in test/all/vblank/builder/test_recolor.rb.
class TestRecolorCartridge < Minitest::Test
  include RecolorGames

  # The console's own pixels, read off the cartridge rather than compared with the
  # interpreter's, so the two cannot agree on showing nothing.
  def test_the_console_shows_the_colors_the_list_holds_now
    recolored = program { |_ship| recolor :slot, :warm }
    v = assert_emulator_loads_rom(assemble_rom(recolored, name: "RECOLOR"), frames: 6)

    assert v.pixel_is?(41, 41, :yellow), "the left half is #{v.pixel_gba(41, 41)}"
    assert v.pixel_is?(45, 41, :orange), "the right half is #{v.pixel_gba(45, 41)}"
  end

  # --- a picture stored the big way takes groups too ---

  # Twenty colours: more than one group holds, so the console reads it across the whole table.
  BIG = Array.new(64) { |i| VBlank::Graphics::Color.rgb(i % 20, 3, (i % 20) + 4) }.freeze

  # Set number +n+: two colours no other set has.
  def self.set(n) = [:transparent, VBlank::Graphics::Color.rgb(n, 31 - n, 5), VBlank::Graphics::Color.rgb(31 - n, n, 9)]

  # The ship drawn with +lists+ lists, each of which the game recolors so each keeps a group of
  # its own, beside a sprite of the twenty-colour picture when +big+.
  private def ship_with_changing_lists(lists, big:)
    klass = self.class
    built do
      image :big, width: 8, height: 8, data: BIG
      names = (0...lists).map { |n| colors :"set#{n}", klass.set(n) }
      sprite :wide, image: :big, at: [10, 10] if big
      ship = sprite :ship, at: [40, 40]
      game_loop do
        ship.x += 1
        ship.draw_with names, showing: ship.x - 41
        names.each { |name| recolor name, names, showing: ship.x - 41 }
      end
    end
  end

  private def lowered(program) = GBA.new.lower(program.copy.tap { |copy| copy.console = :gba })

  def test_the_refusal_for_too_many_groups_names_the_big_picture_that_took_two
    lowered(ship_with_changing_lists(14, big: false))
    message = assert_raises(GBA::LoweringError) { lowered(ship_with_changing_lists(14, big: true)) }.message

    assert_match(/16 groups/, message)
    assert_match(/:big/, message)
    assert_match(/2 of these groups/, message)
  end
end
