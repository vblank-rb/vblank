# frozen_string_literal: true

require "test_helper"
require "differential"
require "all/vblank/dsl/test_sprite_borrowed_colors"

# The Advance's cartridge lending its groups of sprite colours: that the lowering takes twenty
# kinds a few at a time, the colours read off the console's own sprite table in the emulator, and
# the count of things it had no group for. What each thing wears on every run is in
# test/all/vblank/dsl/test_sprite_borrowed_colors.rb.
class TestSpriteBorrowedColorsCartridge < Minitest::Test
  include Differential
  include SpriteBorrowedColorsGames

  def test_twenty_kinds_a_few_at_a_time_fit_the_console
    GBA.new.lower(things_coming_and_going)
  end

  # Read off the console's own table rather than compared with the interpreter: every thing
  # on screen wears the list of the kind its place says it is, frame after frame, as things
  # of new kinds keep arriving.
  def test_the_console_lends_each_thing_its_kinds_colors
    v = assert_emulator_loads_rom(assemble_rom(things_coming_and_going, name: "LENT"), frames: 10)
    seen = 0
    12.times do
      v.step(5)
      v.sprites(:thing).each do |row|
        kind = (((row.y - 40) / 20) * 10) + ((row.x - 10) / 20)
        assert_equal SpriteBorrowedColorsGames.colors_of_kind(kind)[1, 2], row.colors[1, 2],
                     "kind #{kind} at #{row.x}, #{row.y}"
        seen += 1
      end
    end
    assert_operator seen, :>, 30
  end

  # More lists worn at once than there are groups to lend: the console draws the extra
  # things from a group another list holds, as the console's own games do, and counts it.
  def test_more_lists_worn_at_once_than_groups_are_counted
    crowded = built do
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: KINDS, image: :ship
      KINDS.times { |n| things.spawn x: ((n % 10) * 20) + 10, y: ((n / 10) * 20) + 40, kind: n }
      game_loop { things.each { |thing| thing.draw_with KIND_LISTS, showing: thing.kind } }
    end
    rom = assemble_rom(crowded, name: "CROWDED")
    v = assert_emulator_loads_rom(rom, frames: 6, vars: rom.var_addresses)

    assert_operator v.borrowed_colors_missed, :>, 0
  end

  # Where the things wholly off the screen stand: past each edge, and far enough right that the
  # table's column, nine bits, would wrap it round to the left edge were it kept as put.
  OFF_SCREEN = [[300, 40], [-40, 40], [100, 170], [100, -20], [500, 40]].freeze

  # The ship's own colours take one of the sixteen groups, which leaves fifteen to lend.
  GROUPS_LENT = 15

  # Things wholly off the screen wear no group: as many lists on the screen as there are groups
  # to lend, one of them only partly on it, each wears its own colours, though the things off
  # the screen wear lists of their own and are written into the table before them. The count
  # of things that found no group, which the profile reports, stays at nought.
  def test_things_off_the_screen_borrow_no_group
    shown = GROUPS_LENT
    parked = built do
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: KINDS, image: :ship
      shown.times do |n|
        x = n.zero? ? -4 : ((n % 10) * 20) + 10
        things.spawn x: x, y: ((n / 10) * 20) + 40, kind: OFF_SCREEN.size + n
      end
      OFF_SCREEN.each_with_index { |(x, y), n| things.spawn x: x, y: y, kind: n }
      game_loop { things.each { |thing| thing.draw_with KIND_LISTS, showing: thing.kind } }
    end

    assert_each_on_screen_wears_its_own(parked)
  end

  # Places one pixel apart at the edges: an 8x8 thing at column 239 or row 159 shows a line of
  # itself, and at column 240 or row 160 none. Rows 200 to 255 are below the screen, though the
  # table counts its rows in eight bits. Each thing on the screen at the edge is one of the lists
  # worn there, so a group lent to the wrong one shows as a wrong colour on that line.
  ON_THE_EDGE = [[239, 40], [100, 159]].freeze
  PAST_THE_EDGE = [[240, 40], [100, 160], [100, 200], [100, 255]].freeze

  # A thing that turns is drawn in a box twice its size, standing half the picture before its
  # place, so its corners reach before its place when it is turned. Turned an eighth of the way
  # round at column 240, where an upright thing shows nothing, a corner reaches back onto the
  # screen; at column 260 none of the box does.
  TURNED_ON_THE_EDGE = [240, 60].freeze
  TURNED_PAST_THE_EDGE = [260, 60].freeze

  def test_things_at_the_edge_borrow_only_while_on_the_screen
    edge_kinds = ON_THE_EDGE.size + PAST_THE_EDGE.size
    plain = GROUPS_LENT - ON_THE_EDGE.size - 1 # ...and one turned thing on the screen
    edges = built do
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: KINDS, image: :ship
      plain.times { |n| things.spawn x: ((n % 10) * 20) + 10, y: ((n / 10) * 20) + 80, kind: edge_kinds + 2 + n }
      (ON_THE_EDGE + PAST_THE_EDGE).each_with_index { |(x, y), n| things.spawn x: x, y: y, kind: n }
      turned = [TURNED_ON_THE_EDGE, TURNED_PAST_THE_EDGE].each_with_index.map do |(x, y), n|
        sprite(:ship, at: [x, y]).tap { |ship| ship.face_angle(45) }.then { |ship| [ship, :"kind#{edge_kinds + n}"] }
      end
      game_loop do
        things.each { |thing| thing.draw_with KIND_LISTS, showing: thing.kind }
        turned.each { |ship, list| ship.draw_with list }
      end
    end

    assert_each_on_screen_wears_its_own(edges)
  end

  # Every thing on the screen wears its own colours, as the interpreter draws it, and no list
  # found no group.
  private def assert_each_on_screen_wears_its_own(program)
    assert_backends_agree(program, frames: 6)
    rom = assemble_rom(program, name: "PARKED")
    v = assert_emulator_loads_rom(rom, frames: 6, vars: rom.var_addresses)

    assert_equal 0, v.borrowed_colors_missed
  end
end
