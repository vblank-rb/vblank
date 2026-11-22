# frozen_string_literal: true

require "test_helper"

# The order every lowering works a game's bends out in (Backends::BendSchedule), walked over a lowering
# that writes nothing: it keeps a list of the rows, bands and row variables it was asked for, in order.
# So the order is read straight off the list for every lowering at once. That each lowering works those
# rows out rightly in its own instructions is its checked run's to hold.
class TestBendSchedule < Minitest::Test
  include VBlank::IR::Build

  Backends = VBlank::IR::Backends

  # A lowering's part of the schedule (BendSchedule's own comment lists it), each call written down.
  class RecordingLowering
    include VBlank::IR::Backends::BendSchedule

    attr_reader :bends

    def initialize(program, bands: false)
      @row_bends = VBlank::IR::Backends::RowBends.new(program)
      @bends = @row_bends.bends
      @bands = bands
    end

    def bend_screen_height = 160
    def emit_bend_rows(bend, first, past) = [:rows, bend.background, first, past]
    def emit_bend_bands(bend, bands) = [:bands, bend.background, bands]
    def emit_row_variable_set(bend, height) = [:row_at, bend.background, height]
    def bend_bands_taken(bend) = @bands ? @row_bends.bands(bend, bend_screen_height) : nil
  end

  private def water(name) = background(name, tiles: :t, map: [[0]], tile_w: 8, tile_h: 8)

  private def two_bends(sea_offset: binop(:%, var_ref(:a), 8), shore_offset: binop(:%, var_ref(:b), 4))
    program(water(:sea), water(:shore), scroll_rows(:sea, row: :a, offset: sea_offset), scroll_rows(:shore, row: :b, offset: shore_offset))
  end

  # Reference#work_out_bends: every bend's top row, then each bend's other rows and its row variable left
  # at the height.
  def test_every_bends_top_row_comes_before_any_bends_other_rows
    written = RecordingLowering.new(two_bends).emit_bends_worked_out

    assert_equal [[:rows, :sea, 0, 1], [:rows, :shore, 0, 1], [:rows, :sea, 1, 160], [:row_at, :sea, 160],
                  [:rows, :shore, 1, 160], [:row_at, :shore, 160]], written
  end

  # What a lowering feeds with the top rows goes after them and before the rest.
  def test_what_goes_with_the_top_rows_comes_between
    written = RecordingLowering.new(two_bends).emit_bends_worked_out { :fed }

    assert_equal [:rows, :shore, 0, 1], written[1]
    assert_equal :fed, written[2]
    assert_equal [:rows, :sea, 1, 160], written[3]
  end

  # ...and a game with no bend still feeds what goes with them, the Advance's light among them.
  def test_a_game_with_no_bend_works_nothing_out
    lowering = RecordingLowering.new(program(water(:sea)))

    assert_empty lowering.emit_bends_worked_out
    assert_equal [:fed], lowering.emit_bends_worked_out { :fed }
  end

  # A lowering taking bands works each bend whole, since no block in bands can tell the order.
  def test_bends_all_in_bands_are_each_worked_whole
    program = two_bends(sea_offset: binop(:>=, var_ref(:a), 10), shore_offset: int(3))
    written = RecordingLowering.new(program, bands: true).emit_bends_worked_out

    assert_equal [[:bands, :sea, [0, 10]], [:row_at, :sea, 160], [:bands, :shore, [0]], [:row_at, :shore, 160]], written
  end

  # One bend asked every row can change what another reads, so then no bend is worked in bands.
  def test_one_bend_asked_every_row_has_every_bend_asked_every_row
    program = two_bends(sea_offset: binop(:>=, var_ref(:a), 10))
    written = RecordingLowering.new(program, bands: true).emit_bends_worked_out

    assert_equal [:rows, :sea, 0, 1], written.first
    refute_includes written.map(&:first), :bands
  end

  private def lowerings
    { "Computer" => Backends::Computer::Lowering, "GBA" => Backends::GBA::Raster, "GBC" => Backends::GBC::Lowering }
  end

  # Every lowering that works bends out ahead of the picture takes this schedule.
  def test_every_lowering_working_bends_out_takes_this_schedule
    lowerings.each do |name, lowering|
      assert_includes lowering.ancestors, Backends::BendSchedule, name
      assert_equal Backends::BendSchedule, lowering.instance_method(:emit_bends_worked_out).owner, name
    end
  end

  # A lowering that writes a step of the schedule its own way is named for it in BendSchedule::OWN_WAYS,
  # with why; and nothing is named there that a lowering does not write.
  def test_every_step_a_lowering_writes_its_own_way_is_listed_with_its_reason
    schedule = Backends::BendSchedule
    steps = schedule.instance_methods(false) + schedule.private_instance_methods(false)
    lowerings.each do |name, lowering|
      own = steps.reject { |step| lowering.instance_method(step).owner == schedule }
      listed = schedule::OWN_WAYS.select { |_step, by| by.key?(name) }.keys

      assert_equal listed.sort, own.sort, "#{name}'s own ways of the schedule, against BendSchedule::OWN_WAYS"
    end
    schedule::OWN_WAYS.each_value { |by| by.each_value { |why| refute_empty why } }
  end
end
