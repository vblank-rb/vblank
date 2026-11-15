# frozen_string_literal: true

require "test_helper"

# The lists the Color's lowering keeps in narrower slots than declared (GBC::ListWidths): every
# number written to one is proven to fit, so the cartridge keeps it in a byte or two and reads it
# back with its sign, and the game's numbers are the interpreter's on every pass.
class TestGBCListWidths < Minitest::Test
  include VBlank::IR::Build

  GBC = VBlank::IR::Backends::GBC

  # A place across the screen, a place down it moved round by a mask, a copy of the first, a list
  # whose numbers each grow by one without end, one written past two bytes, and one a fill writes.
  def lists_program
    program(
      list_new(:across, 4, full_of: 0),
      list_new(:down, 4, full_of: 0),
      list_new(:copied, 4, full_of: 0),
      list_new(:growing, 4, full_of: 0),
      list_new(:wide, 4, full_of: 0),
      list_new(:filled, 4, full_of: 0),
      list_set(:across, 0, 200),
      list_set(:across, 1, -32_768),
      list_set(:down, 0, binop(:&, binop(:+, list_get(:down, 0), 1), 127)),
      list_set(:copied, 0, list_get(:across, 0)),
      list_set(:growing, 0, binop(:+, list_get(:growing, 0), 1)),
      list_set(:wide, 0, 40_000),
      list_fill(:filled, from: 0, count: 2, value: 1)
    )
  end

  def test_lists_proven_narrow_are_kept_in_the_slots_that_hold_their_numbers
    widths = GBC::ListWidths.new(lists_program).widths

    assert_equal({ across: :half, down: :byte, copied: :half }, widths)
  end

  # Kept narrower, the numbers at the ends of each slot read back as written, on every pass.
  def test_numbers_at_the_ends_of_a_narrow_slot_read_back_as_the_interpreter_reads_them
    game = VBlank.game("NARROW LISTS", consoles: %i[gbc]) do
      screen :tiled
      image(:dot, "#" => :red) { "#" }
      crowd = pool :crowd, x: 0, y: 0, capacity: 4, image: :dot
      crowd.spawn(x: -32_768, y: -128)
      crowd.spawn(x: 32_767, y: 127)
      game_loop do
        crowd.each { |thing| thing.y = (thing.y + 1) & 127 }
      end
    end
    game_player.run(game.program(console: :gbc), frames: 4)
  end
end
