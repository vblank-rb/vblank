# frozen_string_literal: true

require "test_helper"

# Two ways the Super Nintendo build works a number's sides out in another order than the
# interpreter's, the left first, where neither side changes anything so the order cannot be told.
# A field of two bytes combined with a table's entry has the entry worked out first and the field
# read where it is (SNES::Lowering#emit_low_half_with_slot_last), for an AND, an OR and an XOR as
# for a sum. A comparison whose left side is a variable and whose right must be worked out has the
# right worked out first and the left loaded after it (SNES::Lowering#compare_within_halves). Each
# game plays on the Super Nintendo and is held to the interpreter on every pass.
class TestSNESLowHalfOrder < Minitest::Test
  # Each thing's bits combined every pass with the mask for its way, the way turning each pass.
  def self.masked_fields_game
    VBlank.game("MASKED FIELDS", consoles: %i[snes]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      things = pool :thing, kept: 0, joined: 0, flipped: 0, total: 0, way: 0, capacity: 4,
                            widths: { kept: :half, joined: :half, flipped: :half, total: :half, way: :byte }
      masks = table :masks, [0x0F0F, -4096, 0x00FF, 0x7001], width: :half
      things.spawn(kept: -1, joined: 0, flipped: 0x1234, total: 7, way: 0)
      things.spawn(kept: 0x5A5A, joined: 0x0101, flipped: -2, total: -300, way: 2)
      things.spawn(kept: 0x7FFF, joined: -32_768, flipped: 0, total: 32_000, way: 3)
      game_loop do
        things.each do |t|
          t.kept = t.kept & masks[t.way]
          t.joined = t.joined | masks[t.way]
          t.flipped = t.flipped ^ masks[t.way]
          t.total = t.total + masks[t.way]
          t.way = (t.way + 1) & 3
          t.kept = t.kept | (t.way + 0x0300)
        end
      end
    end
  end

  def test_and_or_and_xor_of_a_field_and_a_table_entry_are_the_interpreters
    run = game_player.run(self.class.masked_fields_game.program(console: :snes), frames: 12)

    refute_equal [-1, 0x5A5A, 0x7FFF], run.pool(:thing, :kept).compact, "the masks changed the fields"
  end

  # A variable compared with a table's entry by each of the six tests, the left side the variable
  # for four and the entry for the two whose sides the build turns round, so the variable is always
  # the side loaded last. The entries run below and above every number the variables take, a small
  # one and one wide enough that their difference passes 16 bits, and one of positive entries alone.
  # Each variable sweeps sixteen numbers for each entry in turn and meets the entry on one of them,
  # so a side loaded one off, or the two sides swapped, changes a count.
  def self.compared_entries_game
    VBlank.game("COMPARED ENTRIES", consoles: %i[snes]) do
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      signed = table :signed, [-3, 5, 0, -7], width: :half
      wide = table :wide, [-14_000, 12_000, 0, 32_000], width: :half
      positive = table :positive, [17, 102, 255, 0], width: :half
      below = var :below, 0
      at_least = var :at_least, 0
      same = var :same, 0
      differ = var :differ, 0
      above = var :above, 0
      at_most = var :at_most, 0
      wide_below = var :wide_below, 0
      wide_above = var :wide_above, 0
      positive_below = var :positive_below, 0
      positive_above = var :positive_above, 0
      pass = var :pass, 0
      small = var :small, 0
      broad = var :broad, 0
      low = var :low, 0
      at = var :at, 0
      game_loop do
        pass += 1
        small = (pass & 15) - 8
        broad = ((pass & 15) * 2000) - 16_000
        low = (pass & 15) * 17
        at = (pass >> 4) & 3
        below += 1 if small < signed[at]
        at_least += 1 if small >= signed[at]
        same += 1 if small == signed[at]
        differ += 1 if small != signed[at]
        above += 1 if signed[at] > small
        at_most += 1 if signed[at] <= small
        wide_below += 1 if broad < wide[at]
        wide_above += 1 if wide[at] > broad
        positive_below += 1 if low < positive[at]
        positive_above += 1 if positive[at] > low
      end
    end
  end

  def test_a_variable_compared_with_a_worked_out_side_is_the_interpreters
    run = game_player.run(self.class.compared_entries_game.program(console: :snes), frames: 70)

    assert_operator run[:same], :>, 0, "a variable met an entry"
    assert_operator run[:below], :>, 0
    assert_operator run[:at_least], :>, 0
    assert_operator run[:wide_below], :>, 0
  end
end
