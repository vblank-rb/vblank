# frozen_string_literal: true

require "stringio"

# A small tiled game whose slow pass finishes on its second frame, built for any console a
# comparison lines up, for each console's test of `passes_compared_at: :end`. A box steps one pixel
# right a pass, and the game counts its passes. On the slow build every fourth pass has much to do
# between counting itself and moving the box, more than a frame's worth, so it takes two frames and
# on the first of them its count shows the pass while the box has not moved: its work is half done.
# That is what an original does on a heavy pass, and the quick build is the port that finishes every
# pass in one frame.
#
# The slow pass's turns are measured, not written down. Its work is a busy loop, so it is still at
# work when the frame ends, wherever the console's emulator reads the frame. How many turns take a
# frame is the lowering's, and it gets quicker, so a count written in a test stopped making a pass of
# two frames at a speed-up of the lowering (the Super Nintendo's was moved from 700 to 1400 to 2100).
# The turns a frame takes are read off a calibrating game played in the console's emulator as the
# test runs, and the slow pass is given half as many again: a pass that ends in the middle of its
# second frame, however quick the lowering is. (Working until the frame count moves on is not
# enough: every console but the Advance moves frames_since_power_on on only where the pass waits,
# and a second wait in the pass lets the emulator read the frame after the box has moved.)
module SlowPassGames
  # The map's width in cells on each console: the Genesis shows forty cells across.
  MAP_COLUMNS = { gba: 32, gbc: 32, snes: 32, genesis: 40 }.freeze

  # How many frames each lead-in is: the same on both leaves the quick build passes ahead of the
  # slow one, and the short one leaves the quick build behind the slow one's long one.
  LEAD_IN_FRAMES = { long: 40, short: 30 }.freeze

  # The calibrating game's passes are counted from the first of these frames to the second: after
  # the Genesis's start-up, which shows nothing for its first frames, and long enough for many passes.
  CALIBRATING_FRAMES = [60, 420].freeze

  # The fewest frames a calibrating pass takes before the turns a frame are read from it: a pass
  # takes a whole number of frames, so its turns a frame are known to within one part in this many.
  LEAST_CALIBRATING_FRAMES = 10

  # The turns the calibrating game's pass starts from, and the most tries it makes.
  FIRST_CALIBRATING_TURNS = 1_024
  MOST_CALIBRATING_TRIES = 8

  # The turns of the slow pass's busy loop on +console+: half as many again as a frame takes, so the
  # pass runs half way into its second frame. Worked out once a process for each console (each Ractor
  # keeps its own), since every slow build asks.
  def self.slow_pass_turns(console)
    found = (Ractor.current[:slow_pass_turns] ||= {})
    found[console] ||= (turns_a_frame(console) * 3 / 2).round
  end

  # The turns of the busy loop that take one of +console+'s frames, from a pass that takes at least
  # LEAST_CALIBRATING_FRAMES: a pass of +turns+ that takes +frames+ whole frames has more than
  # frames - 1 frames' worth of turns and no more than +frames+, so the middle of the two is taken.
  def self.turns_a_frame(console)
    turns = FIRST_CALIBRATING_TURNS
    MOST_CALIBRATING_TRIES.times do
      frames = frames_a_pass(console, turns)
      return turns / (frames - 0.5) if frames >= LEAST_CALIBRATING_FRAMES

      turns = frames <= 1 ? turns * 8 : turns * (LEAST_CALIBRATING_FRAMES + 2) / (frames - 1)
    end
    raise "no number of turns made a pass of #{LEAST_CALIBRATING_FRAMES} frames on #{console}, up to #{turns}"
  end

  # How many frames a pass of +turns+ turns of the busy loop takes on +console+'s cartridge, read
  # from the passes counted over CALIBRATING_FRAMES.
  def self.frames_a_pass(console, turns)
    cartridge = box_game(console, busy: turns, busy_every: 1)
    first, last = CALIBRATING_FRAMES.map do |frames|
      lead_in = VBlank.playthrough("calibrate #{frames}") { wait frames: frames }
      VBlank::Playthroughs::Playthrough.power_on_and_lead_in(cartridge, lead_in: lead_in).game.var(:passes)
    end
    return CALIBRATING_FRAMES.last if last == first

    ((CALIBRATING_FRAMES.last - CALIBRATING_FRAMES.first).to_f / (last - first)).round
  end
  private_class_method :turns_a_frame, :frames_a_pass

  # The box stepping a pixel a pass on +console+, every +busy_every+th pass going round the busy loop
  # +busy+ times (none when nought) between counting itself and moving the box. +jump_on+ and
  # +right_jumps+ are #stepping_box's.
  def self.box_game(console, busy: 0, busy_every: 4, jump_on: nil, right_jumps: false)
    columns = MAP_COLUMNS.fetch(console)
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
        if busy.positive?
          repeat(busy) { work += 3 } if passes % busy_every == 0 # counted already, and the box not moved yet
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

  # +slow+ makes every fourth pass take two frames; +jump_on+ moves the box four pixels further on
  # that pass alone, a real difference for a comparison to find. +right_jumps+ moves it four pixels
  # further on each pass RIGHT is down.
  private def stepping_box(console:, slow: false, jump_on: nil, right_jumps: false)
    busy = slow ? SlowPassGames.slow_pass_turns(console) : 0
    SlowPassGames.box_game(console, busy: busy, jump_on: jump_on, right_jumps: right_jumps)
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

  # After lead-ins of the same frames the slow build is passes behind the quick one, as an original
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

  # A press while the second catches up. The first's lead-in taps RIGHT on the frame after the short
  # lead-in ends, and the quick second, led in by the short one or not at all, is still behind the
  # slow first there: it plays that frame while it catches up, and is held what the first's lead-in
  # held on it, so the tap moves its box too. The answer key is the second led in as far as the tap.
  # Compared at each pass's end, since read on a slow pass's first frame its box has not moved yet.
  # A second lead-in that tapped on a frame of its own is not the first's cut short, and is not
  # held the first's tap again.
  #
  # The tap goes on a frame the slow first build reads: one held during the second frame of a slow
  # pass is read by no pass of the first, which read its buttons as the pass began, while the quick
  # second reads it, so the two would part for a reason of their own. Which frames those are moves
  # with how long the cartridge takes to set up, so the tap is put on the first frame after the short
  # lead-in that the slow build's box answers.
  private def assert_catch_up_press_reaches_second(console)
    slow = stepping_box(console: console, slow: true, right_jumps: true)
    quick = stepping_box(console: console, right_jumps: true)
    long_frames = LEAD_IN_FRAMES.fetch(:long)
    tap_on = ((LEAD_IN_FRAMES.fetch(:short) + 1)...long_frames).find { |frame| tap_answered?(slow, frame, long_frames) }
    refute_nil tap_on, "the slow build answers a tap on some frame between the lead-ins"
    long = tapping_lead_in(tap_on, long_frames)
    short = lead_in_of(LEAD_IN_FRAMES.fetch(:short))
    through_tap = tapping_lead_in(tap_on, tap_on)
    assert_operator pass_after(stepping_box(console: console), through_tap), :<, pass_after(slow, long),
                    "the quick build is still behind the slow one's lead-in after the tap"

    own_tap = tapping_lead_in(LEAD_IN_FRAMES.fetch(:short) - 1, LEAD_IN_FRAMES.fetch(:short))
    [through_tap, short, nil, own_tap].each do |second_lead_in|
      assert_plays_alike slow, quick, watch_steps, by_passes: :passes, passes_compared_at: :end,
                                                   lead_ins: [long, second_lead_in], readings: { x: :x }
    end
  end

  # Whether +cartridge+'s box is somewhere else after a lead-in of +frames+ that taps RIGHT on frame
  # +tap_on+ than after one that taps nothing: whether a pass of it read the tap.
  private def tap_answered?(cartridge, tap_on, frames)
    box_after = lambda do |lead_in|
      VBlank::Playthroughs::Playthrough.power_on_and_lead_in(cartridge, lead_in: lead_in).game.var(:x)
    end
    box_after.call(tapping_lead_in(tap_on, frames)) != box_after.call(lead_in_of(frames))
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
