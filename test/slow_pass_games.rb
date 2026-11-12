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

  # +slow+ makes every fourth pass take two frames; +jump_on+ moves the box four pixels further on
  # that pass alone, a real difference for a comparison to find.
  private def stepping_box(console:, slow: false, jump_on: nil)
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
end
