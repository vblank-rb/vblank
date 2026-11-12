# frozen_string_literal: true

require "test_helper"
require "stringio"
require "comparison_games"
require "slow_pass_games"

# TWO CARTRIDGES LINED UP BY THE GAME'S OWN PASSES (`by_passes:`), not by frames. A pass is one
# run of the game's loop, and on either cartridge one may take a frame or several: an original
# too busy for a frame now and then, a port that is quicker. Frame by frame such a pair drifts
# at the first slow pass and never comes back; pass by pass it is compared like with like, on
# the first frame each cartridge shows each pass.
#
# The cartridges are one small game built twice, the "late" one spending two frames on every
# fifth pass. Each counts its passes in a variable, moves a box while RIGHT is down, and moves a
# marker every pass, so every pass has a picture of its own.
class TestComparisonByPasses < Minitest::Test
  include ComparisonGames
  include SlowPassGames
  include VBlank::Testing::PlaysAlike

  # +late+ makes every fifth pass take two frames; +speck_on+ draws one white pixel on that pass
  # alone; +stops_at+ is the pass the count stops at, for a cartridge that never gets further.
  private def passing(late: false, speck_on: nil, stops_at: nil)
    VBlank.build("PASSING", console: :gba, frame_sync: :manual, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      passes = var :passes, 0
      x = var :x, 20
      frames_into = var :frames_into, 0 # which frame of its pass the game waits on: 0, or 1 on a slow pass's second
      game_loop do
        wait_vblank
        if late
          if passes % 5 == 4
            frames_into = 1
            wait_vblank
          end
        end
        frames_into = 0
        if stops_at
          passes += 1 if passes < stops_at
        else
          passes += 1
        end
        x += 2 if held(:right)
        clear_screen :blue
        draw_rect_at x, 60, 8, 8, :white
        draw_rect_at passes % 200, 100, 4, 4, :green
        pixel 120, 130, :white if speck_on && passes == speck_on
      end
    end
  end

  private def walk
    VBlank.playthrough "walk" do
      wait frames: 6
      moment :standing
      hold :right, frames: 12
      moment :walked
      wait frames: 20
    end
  end

  private def watch = VBlank.playthrough("watch") { wait frames: 40 }

  def test_a_slow_pass_drifts_frame_by_frame_and_not_pass_by_pass
    assert_raises(Minitest::Assertion) { assert_plays_alike passing, passing(late: true), watch }
    assert_plays_alike passing, passing(late: true), watch, by_passes: :passes
    assert_plays_alike passing(late: true), passing, watch, by_passes: :passes
  end

  # The second cartridge is held each pass's buttons, the ones the first held on the frame it
  # showed that pass, so a press lands on the same pass on both though not on the same frame.
  def test_presses_land_on_the_same_pass_on_both
    assert_raises(Minitest::Assertion) { assert_plays_alike passing, passing(late: true), walk, readings: { x: :x } }
    assert_plays_alike passing, passing(late: true), walk, by_passes: :passes, readings: { x: :x }
    assert_plays_alike passing(late: true), passing, walk, by_passes: :passes, readings: { x: :x }
  end

  def test_a_difference_on_one_pass_is_found_on_that_pass
    first = passing
    second = passing(late: true, speck_on: 12)
    tape = watch.play(first).tape
    drift = watch.compare(first, second, by_passes: :passes).drift

    assert_equal 12, drift.pass
    assert_equal [:picture], drift.differed
    assert_equal first_frame(first, tape) { |game| game.var(:passes) == 12 }, drift.frame
    assert_equal first_frame(second, tape) { |game| game.var(:passes) == 12 }, drift.second_frame
    refute_equal drift.frame, drift.second_frame, "the late cartridge reaches pass 12 frames later"
  end

  def test_a_failure_says_the_pass
    error = assert_raises(Minitest::Assertion) do
      assert_plays_alike passing, passing(late: true, speck_on: 12), watch, by_passes: :passes
    end

    assert_match "pass 12", error.message
  end

  # Each pass is the first frame its cartridge shows it, so the moments say each one's frame.
  def test_the_moments_are_each_cartridges_own_frames
    result = walk.compare(passing, passing(late: true), by_passes: :passes)

    first, second = result.moments.fetch(:walked)
    assert_operator second, :>, first
  end

  # A count read as a byte comes round to nought, and is counted on past it.
  def test_a_count_that_wraps_is_counted_on_past_it
    eighths = ->(game) { game.var(:passes) % 8 }

    assert_plays_alike passing, passing(late: true), watch, by_passes: eighths, pass_count_wraps_at: 8
    drift = watch.compare(passing, passing(late: true, speck_on: 12), by_passes: eighths, pass_count_wraps_at: 8).drift
    assert_equal 12, drift.pass
  end

  def test_a_count_that_falls_with_no_wrap_said_is_refused
    error = assert_raises(VBlank::Playthroughs::Comparison::PassCountFell) do
      watch.compare(passing, passing(late: true), by_passes: ->(game) { game.var(:passes) % 8 })
    end

    assert_match "pass_count_wraps_at:", error.message
  end

  # The game loop's own count, which the framework keeps on a cartridge built here.
  def test_the_game_loops_own_count_lines_the_two_up
    assert_plays_alike passing, passing(late: true), watch, by_passes: true
  end

  # One way of reading the count for each cartridge, as `readings:` takes.
  def test_a_way_for_each_cartridge
    assert_plays_alike passing, passing(late: true), watch, by_passes: [:passes, ->(game) { game.var(:passes) }]
  end

  def test_a_second_cartridge_that_never_reaches_a_pass_is_an_error
    error = assert_raises(VBlank::Playthroughs::Comparison::PassNotReached) do
      watch.compare(passing, passing(stops_at: 10), by_passes: :passes)
    end

    assert_match "pass 11", error.message
  end

  # Two counts that never show the same pass compare nothing, which is not a pass.
  def test_counts_that_share_no_pass_are_an_error
    error = assert_raises(VBlank::Playthroughs::Comparison::PassNotReached) do
      watch.compare(passing, passing, by_passes: [:passes, ->(game) { game.var(:passes) + 1000 }])
    end

    assert_match "nothing was compared", error.message
  end

  def test_settings_that_need_frames_are_refused
    { forgiving_torn_frames_of: :second, reports_in: "drift", same: :script }.each do |setting, value|
      error = assert_raises(ArgumentError) { watch.compare(nil, nil, by_passes: :passes, setting => value) }

      assert_match "`by_passes:`", error.message, setting
    end
  end

  # A GAME THAT READS ITS BUTTONS EVERY FRAME, as one reading them in its frame interrupt does: a
  # tap on a slow pass's later frame is caught, and counted on the pass. +late+ as `passing`.
  private def tapping(late: false)
    VBlank.build("TAPPING", console: :gba, frame_sync: :manual, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      passes = var :passes, 0
      caught = var :caught, 0
      taps = var :taps, 0
      game_loop do
        wait_vblank
        caught = 1 if held(:a)
        if late
          if passes % 5 == 4
            wait_vblank
            caught = 1 if held(:a)
          end
        end
        passes += 1
        if caught == 1
          taps += 1
          caught = 0
        end
      end
    end
  end

  # A one-frame tap after +frames+ frames.
  private def tap_after(frames)
    VBlank.playthrough("tap") do
      wait frames: frames
      hold :a, frames: 1
      wait frames: 20
    end
  end

  # Given only each pass's first frame's buttons, the second never sees a tap that fell on a
  # later frame of one of the first's slow passes; told the game reads them every frame, it is
  # given every frame's buttons in turn and catches every tap the first did.
  def test_a_game_that_reads_buttons_every_frame_is_given_every_frames_buttons
    taps = (10..22).map { |frames| tap_after(frames) }
    late = tapping(late: true)
    quick = tapping

    dropped = taps.count { |tap| tap.compare(late, quick, by_passes: :passes, readings: { taps: :taps }).drift }
    assert_operator dropped, :>, 0, "a tap on a slow pass's later frame should reach the second only every frame"
    taps.each do |tap|
      assert_plays_alike late, quick, tap, by_passes: :passes, reads_buttons_every_frame: true, readings: { taps: :taps }
    end
  end

  # AFTER A LEAD-IN a pass can be under way on either cartridge, and its first frame is behind
  # it, so it is not compared: comparing starts at the first cartridge's next pass, each on its
  # first frame, the second played on to it.
  def test_a_pass_under_way_when_the_lead_ins_end_is_not_compared
    quick = passing
    late = passing(late: true)
    long = VBlank.playthrough("long") { wait frames: 60 }
    slow_begins = first_frame(late, long.play(late).tape) { |game| game.var(:passes) == 4 } # pass 4 takes two frames
    begins_there = first_frame(quick, long.play(quick).tape) { |game| game.var(:passes) == 4 }
    into_first = ->(game) { game.var(:frames_into) }
    leads = [VBlank.playthrough("late lead") { wait frames: slow_begins },
             VBlank.playthrough("quick lead") { wait frames: begins_there - 1 }]

    assert_plays_alike late, quick, watch, by_passes: :passes, lead_ins: leads, readings: { into: into_first }
  end

  # After lead-ins the comparison starts on the first cartridge's pass (SlowPassGames).
  def test_lead_ins_start_the_comparison_on_the_first_s_pass
    assert_second_ahead_refused(:gba)
    assert_second_behind_catches_up(:gba)
  end

  # The frames the second plays to catch up are held what the first's lead-in held on them.
  def test_a_press_while_the_second_catches_up_reaches_it
    assert_catch_up_press_reaches_second(:gba)
  end

  # A second with no lead-in plays on from power-on, and one whose count already shows a pass past
  # the first's on its first frame would go past the passes before without showing them.
  def test_a_second_from_power_on_already_past_the_first_is_refused
    slow = stepping_box(console: :gba, slow: true)
    lead_in = lead_in_of(LEAD_IN_FRAMES.fetch(:long))

    error = assert_raises(VBlank::Playthroughs::Comparison::SecondAheadAfterLeadIns) do
      watch_steps.compare(slow, stepping_box(console: :gba), by_passes: [:passes, ->(game) { game.var(:passes) + 1000 }],
                                                             lead_ins: [lead_in, nil])
    end
    assert_match "pass #{pass_after(slow, lead_in)}", error.message
    assert_match "from power-on", error.message
  end

  # A COUNT THAT WRAPS: which cartridge is ahead after the lead-ins is the nearer way round. Here
  # the quick build's count has come round and the slow first one's has not, so the quick one reads
  # lower and is ahead.
  def test_a_second_ahead_past_a_wrap_is_refused
    slow = stepping_box(console: :gba, slow: true)
    lead_in = lead_in_of(LEAD_IN_FRAMES.fetch(:long))
    first_pass = pass_after(slow, lead_in)
    second_pass = pass_after(stepping_box(console: :gba), lead_in)
    shift = 15 - (first_pass % 16) # the slow build's count reads 15, the last before it comes round
    sixteenths = ->(game) { (game.var(:passes) + shift) % 16 }
    assert_operator (second_pass + shift) % 16, :<, 15 / 2

    error = assert_raises(VBlank::Playthroughs::Comparison::SecondAheadAfterLeadIns) do
      watch_steps.compare(slow, stepping_box(console: :gba), by_passes: sixteenths, pass_count_wraps_at: 16,
                                                             lead_ins: [lead_in, lead_in])
    end
    assert_match "pass 15", error.message
    assert_match "pass #{(second_pass + shift) % 16}", error.message
  end

  # Here the slow first build's count has come round and the quick one's has not: the quick one
  # reads higher and is behind, so it plays on to the slow one's pass and every pass is compared.
  def test_a_second_behind_past_a_wrap_plays_on_to_the_first
    slow = stepping_box(console: :gba, slow: true)
    long = lead_in_of(LEAD_IN_FRAMES.fetch(:long))
    short = lead_in_of(LEAD_IN_FRAMES.fetch(:short))
    first_pass = pass_after(slow, long)
    shift = 8 - (first_pass % 8) # the slow build's count reads 0, just come round
    eighths = ->(game) { (game.var(:passes) + shift) % 8 }
    assert_operator (pass_after(stepping_box(console: :gba), short) + shift) % 8, :>, 8 / 2

    drift = watch_steps.compare(slow, stepping_box(console: :gba, jump_on: first_pass + 2), by_passes: eighths,
                                                                                           pass_count_wraps_at: 8,
                                                                                           lead_ins: [long, short],
                                                                                           readings: { x: :x }).drift
    refute_nil drift
    assert_equal 2, drift.pass
  end

  # A PASS THAT FINISHES ON ITS SECOND FRAME (SlowPassGames): read on its first frame its work is
  # half done, so the two are compared at each pass's end, the readings on its last frame and the
  # picture on the frame after it.
  def test_a_slow_pass_is_compared_at_its_end
    assert_slow_pass_compared_at_its_end(:gba)
  end

  def test_a_difference_is_found_on_its_pass_at_the_pass_end
    assert_difference_found_at_pass_end(:gba)
  end

  # The picture of the frame after each pass's end, without its sprites or of the sprites alone.
  def test_pass_ends_compare_the_layers_asked_for
    quick = stepping_box(console: :gba)
    slow = stepping_box(console: :gba, slow: true)

    %i[backgrounds sprites].each do |layers|
      assert_plays_alike quick, slow, watch_steps, by_passes: :passes, passes_compared_at: :end, layers: layers
    end
  end

  # Compared at the end of each pass, the second has to go past the pass the first went past.
  def test_a_second_cartridge_that_never_goes_past_a_pass_says_so
    error = assert_raises(VBlank::Playthroughs::Comparison::PassNotReached) do
      watch.compare(passing, passing(stops_at: 10), by_passes: :passes, passes_compared_at: :end)
    end

    assert_match "went past pass 10", error.message
  end

  # The call shape of a port held to its original: a count kept in a byte, buttons read every
  # frame, lead-ins that end part way through a slow pass, and the sprites left out.
  def test_pass_ends_go_with_a_port_s_other_settings
    quick = stepping_box(console: :gba)
    slow = stepping_box(console: :gba, slow: true)
    leads = [VBlank.playthrough("slow lead") { wait frames: 9 }, VBlank.playthrough("quick lead") { wait frames: 7 }]
    settings = { by_passes: [->(game) { game.var(:passes) % 8 }, :passes], pass_count_wraps_at: 8,
                 reads_buttons_every_frame: true, lead_ins: leads, ignoring_sprites: true, readings: { x: :x } }

    assert_raises(Minitest::Assertion) { assert_plays_alike slow, quick, watch_steps, **settings }
    assert_plays_alike slow, quick, watch_steps, **settings, passes_compared_at: :end
  end

  def test_pass_ends_with_no_count_and_an_unknown_place_are_refused
    assert_match "`by_passes:`", assert_raises(ArgumentError) { watch.compare(nil, nil, passes_compared_at: :end) }.message
    assert_match "`passes_compared_at:`",
                 assert_raises(ArgumentError) { watch.compare(nil, nil, by_passes: :passes, passes_compared_at: :middle) }.message
  end

  def test_a_wrap_with_no_count_and_a_count_that_is_no_way_are_refused
    assert_match "`by_passes:`", assert_raises(ArgumentError) { watch.compare(nil, nil, pass_count_wraps_at: 8) }.message
    assert_match "`by_passes:`", assert_raises(ArgumentError) { watch.compare(nil, nil, reads_buttons_every_frame: true) }.message
    assert_match "`by_passes:`", assert_raises(ArgumentError) { watch.compare(nil, nil, by_passes: 3) }.message
    assert_match "`pass_count_wraps_at:`",
                 assert_raises(ArgumentError) { watch.compare(nil, nil, by_passes: :passes, pass_count_wraps_at: 1) }.message
  end
end
