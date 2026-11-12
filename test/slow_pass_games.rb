# frozen_string_literal: true

require "stringio"

# A SMALL TILED GAME WHOSE SLOW PASS FINISHES ON ITS SECOND FRAME, built for any console a
# comparison lines up, for each console's test of `passes_compared_at: :end`. A box steps one pixel
# right a pass, and the game counts its passes. On the slow build every fourth pass has much to do
# between counting itself and moving the box, more than a frame's worth, so it takes two frames and
# on the first of them its count shows the pass while the box has not moved: its work is half done.
# That is what an original does on a heavy pass, and the quick build is the port that finishes every
# pass in one frame.
module SlowPassGames
  # The map's width in cells on each console: the Genesis shows forty cells across.
  MAP_COLUMNS = { gba: 32, gbc: 32, snes: 32, genesis: 40 }.freeze

  # How many times the slow pass goes round its busy loop on each console: enough to run over one
  # frame and not two, measured on each console's cartridge in its emulator.
  BUSY_STEPS = { gba: 35_000, gbc: 700, snes: 700, genesis: 3_500 }.freeze

  # How many frames each lead-in is: the same on both leaves the quick build passes ahead of the
  # slow one, and the short one leaves the quick build behind the slow one's long one.
  LEAD_IN_FRAMES = { long: 40, short: 30 }.freeze

  # +slow+ makes every fourth pass take two frames; +jump_on+ moves the box four pixels further on
  # that pass alone, a real difference for a comparison to find. +right_jumps+ moves it four pixels
  # further on each pass RIGHT is down.
  private def stepping_box(console:, slow: false, jump_on: nil, right_jumps: false)
    columns = MAP_COLUMNS.fetch(console)
    busy = BUSY_STEPS.fetch(console)
    VBlank.build("STEPPING", console: console, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(32) { "." * columns }
      passes = var :passes, 0
      x = var :x, 20
      work = var :work, 0
      box = sprite :box, at: [20, 60]
      game_loop do
        passes += 1
        if slow
          repeat(busy) { work += 3 } if passes % 4 == 0 # counted already, and the box not moved yet
        end
        x += 1
        x += 4 if jump_on && passes == jump_on
        if right_jumps
          x += 4 if held(:right)
        end
        x = 20 if x > 100
        box.x = x
      end
    end
  end

  # Long enough for the Genesis's start-up, which shows nothing for its first frames.
  private def watch_steps = VBlank.playthrough("watch") { wait frames: 60 }

  # Read on the first frame each shows a pass, the slow build's box has not moved yet; read on the
  # last, it has, and the picture after it shows it where the quick build's does.
  private def assert_slow_pass_compared_at_its_end(console)
    quick = stepping_box(console: console)
    slow = stepping_box(console: console, slow: true)

    assert_raises(Minitest::Assertion) { assert_plays_alike quick, slow, watch_steps, by_passes: :passes, readings: { x: :x } }
    assert_plays_alike quick, slow, watch_steps, by_passes: :passes, passes_compared_at: :end, readings: { x: :x }
    assert_plays_alike slow, quick, watch_steps, by_passes: :passes, passes_compared_at: :end, readings: { x: :x }
  end

  # A pass that does differ is still found, on that pass.
  private def assert_difference_found_at_pass_end(console)
    drift = watch_steps.compare(stepping_box(console: console), stepping_box(console: console, slow: true, jump_on: 12),
                                by_passes: :passes, passes_compared_at: :end, readings: { x: :x }).drift

    refute_nil drift
    assert_equal 12, drift.pass
    assert_includes drift.differed, :x
  end

  # A lead-in that waits +frames+ frames.
  private def lead_in_of(frames) = VBlank.playthrough("lead #{frames}") { wait frames: frames }

  # The pass +cartridge+'s count shows once +lead_in+ has been played on it.
  private def pass_after(cartridge, lead_in)
    VBlank::Playthroughs::Playthrough.power_on_and_lead_in(cartridge, lead_in: lead_in).game.var(:passes)
  end

  # AFTER LEAD-INS OF THE SAME FRAMES the slow build is passes behind the quick one, as an original
  # that runs late now and then is behind its port. The comparison starts on the first cartridge's
  # pass, whichever is ahead. Here the quick second build is past it, and its passes before that
  # cannot be compared: an error naming both passes, not a pass between the two silently left out.
  private def assert_second_ahead_refused(console)
    slow = stepping_box(console: console, slow: true)
    lead_in = lead_in_of(LEAD_IN_FRAMES.fetch(:long))
    behind = pass_after(slow, lead_in)
    ahead = pass_after(stepping_box(console: console), lead_in)
    assert_operator ahead - behind, :>=, 3, "the quick build is passes ahead after the same lead-in"

    quick = stepping_box(console: console, jump_on: behind + 2)
    %i[start end].each do |place|
      error = assert_raises(VBlank::Playthroughs::Comparison::SecondAheadAfterLeadIns) do
        assert_plays_alike slow, quick, watch_steps, by_passes: :passes, passes_compared_at: place,
                                                     lead_ins: [lead_in, lead_in], readings: { x: :x }
      end
      assert_match "pass #{behind}", error.message
      assert_match "pass #{ahead}", error.message
      assert_match "lead_ins:", error.message
    end
  end

  # Led in for fewer frames, or not at all, the quick second build is behind, plays on to the slow
  # first one's pass, and a difference on the very first pass compared is found there: the pass the
  # lead-in left the first on, compared at its end, or the pass after it, compared on its first frame.
  private def assert_second_behind_catches_up(console)
    slow = stepping_box(console: console, slow: true)
    long = lead_in_of(LEAD_IN_FRAMES.fetch(:long))
    short = lead_in_of(LEAD_IN_FRAMES.fetch(:short))
    first_pass = pass_after(slow, long)
    assert_operator pass_after(stepping_box(console: console), short), :<, first_pass

    { start: first_pass + 1, end: first_pass }.each do |place, first_compared|
      quick = stepping_box(console: console, jump_on: first_compared)
      [short, nil].each do |second_lead_in|
        drift = watch_steps.compare(slow, quick, by_passes: :passes, passes_compared_at: place,
                                                 lead_ins: [long, second_lead_in], readings: { x: :x }).drift
        refute_nil drift, "#{place}, second led in by #{second_lead_in&.name || 'nothing'}"
        assert_equal first_compared, drift.pass
      end
    end
    assert_plays_alike slow, stepping_box(console: console), watch_steps, by_passes: :passes, passes_compared_at: :end,
                                                                         lead_ins: [long, short], readings: { x: :x }
  end

  # A PRESS WHILE THE SECOND CATCHES UP. The first's lead-in taps RIGHT on the frame after the short
  # lead-in ends, and the quick second, led in by the short one or not at all, is still behind the
  # slow first there: it plays that frame while it catches up, and is held what the first's lead-in
  # held on it, so the tap moves its box too. The answer key is the second led in as far as the tap.
  # Compared at each pass's end, since read on a slow pass's first frame its box has not moved yet.
  # A second lead-in that tapped on a frame of its own is not the first's cut short, and is not
  # held the first's tap again.
  private def assert_catch_up_press_reaches_second(console)
    slow = stepping_box(console: console, slow: true, right_jumps: true)
    quick = stepping_box(console: console, right_jumps: true)
    tap_on = LEAD_IN_FRAMES.fetch(:short) + 1
    long = tapping_lead_in(tap_on, LEAD_IN_FRAMES.fetch(:long))
    short = lead_in_of(LEAD_IN_FRAMES.fetch(:short))
    through_tap = tapping_lead_in(tap_on, tap_on)
    assert_operator pass_after(stepping_box(console: console), through_tap), :<, pass_after(slow, long),
                    "the quick build is still behind the slow one's lead-in after the tap"

    own_tap = tapping_lead_in(tap_on - 2, LEAD_IN_FRAMES.fetch(:short))
    [through_tap, short, nil, own_tap].each do |second_lead_in|
      assert_plays_alike slow, quick, watch_steps, by_passes: :passes, passes_compared_at: :end,
                                                   lead_ins: [long, second_lead_in], readings: { x: :x }
    end
  end

  # A lead-in of +frames+ frames that holds RIGHT on frame +tap_on+ alone.
  private def tapping_lead_in(tap_on, frames)
    VBlank.playthrough("tap #{tap_on} of #{frames}") do
      wait frames: tap_on - 1
      hold :right, frames: 1
      wait frames: frames - tap_on if frames > tap_on
    end
  end
end
