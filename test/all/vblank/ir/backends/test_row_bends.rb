# frozen_string_literal: true

require "test_helper"

# Which row-by-row bends a game has, and what a build can tell of each block before the game runs
# (Backends::RowBends), read off hand-built programs. That each console feeds the rows it is told of
# to its display is each console's checked run's to hold (test/all/vblank/dsl/test_row_bend.rb).
class TestRowBends < Minitest::Test
  include VBlank::IR::Build

  RowBends = VBlank::IR::Backends::RowBends
  HEIGHT = 160

  private def water(name) = background(name, tiles: :t, map: [[0]], tile_w: 8, tile_h: 8)

  private def bends_of(*statements) = RowBends.new(program(*statements))

  # Reference#collect_definitions: the last bend a background is given stands, in the place the
  # background was first bent.
  def test_the_last_bend_of_a_background_stands_in_the_order_backgrounds_were_first_bent
    first = scroll_rows(:sea, row: :sea_row, offset: 1)
    shore = scroll_rows(:shore, row: :shore_row, offset: 2)
    last = scroll_rows(:sea, row: :sea_row, offset: 3)
    bends = bends_of(water(:sea), water(:shore), first, shore, last)

    assert_equal %i[sea shore], bends.bends.map(&:background)
    assert_same last, bends.bend_for(:sea).node
    assert_equal [last, shore], bends.nodes
  end

  # Reference#work_out_bends asks only the bends of backgrounds the game declares.
  def test_a_bend_of_a_background_never_declared_is_not_a_bend
    bends = bends_of(water(:sea), scroll_rows(:ghost, row: :ghost_row, offset: 1))

    assert_empty bends
    assert_nil bends.bend_for(:ghost)
  end

  def test_a_bend_carries_its_row_its_offset_and_its_block
    body = [set(:a, 1)]
    bend = bends_of(water(:sea), scroll_rows(:sea, row: :sea_row, offset: var_ref(:a), body: body)).bends.first

    assert_equal :sea_row, bend.row
    assert_equal :a, bend.offset.name
    assert_equal body, bend.body
  end

  private def bands_of(offset, body: [], also: [])
    bends = bends_of(water(:sea), water(:shore), *also, scroll_rows(:sea, row: :r, offset: offset, body: body))
    bends.bands(bends.bend_for(:sea), HEIGHT)
  end

  # A block that compares its row with numbers turns only where the row crosses one.
  def test_a_block_comparing_its_row_has_a_band_from_each_number_it_crosses
    assert_equal [0, 10], bands_of(binop(:>=, var_ref(:r), 10))
    assert_equal [0, 4, 5], bands_of(binop(:==, var_ref(:r), 4))
    assert_equal [0, 11], bands_of(binop(:<=, var_ref(:r), 10))
    assert_equal [0, 11], bands_of(binop(:>, 11, var_ref(:r)))
    assert_equal [0], bands_of(int(3)), "a block that never reads its row is one band"
  end

  def test_a_number_off_the_screen_makes_no_band
    assert_equal [0], bands_of(binop(:>=, var_ref(:r), HEIGHT + 5))
  end

  # Asked once a band, a block that worked on the row itself, or did more than work a number out,
  # would give another game.
  def test_a_block_working_on_its_row_or_changing_the_game_is_asked_every_row
    assert_nil bands_of(binop(:%, var_ref(:r), 8))
    assert_nil bands_of(int(0), body: [set(:counted, binop(:+, var_ref(:counted), 1))])
    assert_nil bands_of(list_get(:items, 0))
  end

  # Another bend's row is worked out in an order the bands do not keep.
  def test_a_block_reading_another_bends_row_is_asked_every_row
    shore = scroll_rows(:shore, row: :shore_row, offset: 0)

    assert_nil bands_of(binop(:>=, var_ref(:shore_row), 10), also: [shore])
  end

  # Whether a build can leave a bend's block out while its background is not up.
  def test_a_block_that_only_works_a_number_out_changes_nothing_while_away
    bends = bends_of(water(:sea), water(:shore), water(:lake),
                     scroll_rows(:sea, row: :a, offset: binop(:%, var_ref(:a), 8)),
                     scroll_rows(:shore, row: :b, offset: 0, body: [set(:counted, 1)]),
                     scroll_rows(:lake, row: :c, offset: list_get(:items, var_ref(:c))))

    refute bends.observable_while_away?(bends.bend_for(:sea))
    assert bends.observable_while_away?(bends.bend_for(:shore)), "a statement changes the game"
    assert bends.observable_while_away?(bends.bend_for(:lake)), "a list read out of range stops it"
  end
end
