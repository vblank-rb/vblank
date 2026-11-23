# frozen_string_literal: true

require "stringio"
require "tmpdir"

# A comparison told to start after a frame of its tape (`starting_after:`), from a snapshot of each
# console kept on disk (Playthroughs::SnapshotCache), on every console whose emulator saves its whole
# state. Each including test says +console+.
#
# The games are a white box on a blue field that walks right a pixel a pass while RIGHT is down and
# left while LEFT is, with a count of passes. The late build jumps the box four pixels on when the
# count reaches LATE_PASS, so the two differ from a frame well past where the comparison starts.
module SnapshotStartTests
  # How far the tape plays, where the comparison starts, and the pass the late build jumps on.
  TAPE_FRAMES = 400
  START_AFTER = 300
  LATE_PASS = 340

  private def walker(late: false, from: 20)
    turn = LATE_PASS
    VBlank.build("WALKER", console: console, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(32) { "." * 32 }
      box = sprite :box, at: [from, 60]
      passes = var :passes, 0
      game_loop do
        passes += 1
        box.x += 1 if held(:right)
        box.x -= 1 if held(:left)
        box.x += 4 if late && passes == turn
      end
    end
  end

  # Right and left by turns, fifty frames each, with a moment every hundred frames. +last_press+ is
  # what the last fifty hold, after the start.
  private def tape(last_press: :left)
    lines = ["vblank tape 1", "recorded on: WALKER 0x00000000", "starts from: power-on", ""]
    turns = TAPE_FRAMES / 50
    turns.times do |turn|
      held = turn == turns - 1 ? last_press : %i[right left][turn % 2]
      lines << "50 #{held}"
      lines << "moment at_#{(turn + 1) * 50}" if ((turn + 1) * 50 % 100).zero?
    end
    VBlank::Playthroughs::Tape.parse("#{lines.join("\n")}\n")
  end

  private def with_snapshots(env: {})
    Dir.mktmpdir("vblank-snapshots") { |folder| yield VBlank::Playthroughs::SnapshotCache.new(folder, env: env), folder }
  end

  private def snapshot_files(folder) = Dir.glob(File.join(folder, "**", "*.state"))

  # What a person reads of a result: where each drift began, what differed, and the moments.
  private def outcome(result) = [result.drifts.map { |drift| [drift.frame, drift.moment, drift.differed] }, result.moments]

  def test_a_start_from_a_snapshot_finds_what_power_on_finds
    ours = walker
    late = walker(late: true)
    from_power_on = tape.compare(ours, late)
    with_snapshots do |snapshots|
      cold = tape.compare(ours, late, starting_after: START_AFTER, snapshots: snapshots)
      warm = tape.compare(ours, late, starting_after: START_AFTER, snapshots: snapshots)

      assert from_power_on.drift?, "the late build differs from the frame it turns red"
      assert_operator from_power_on.drift.frame, :>, START_AFTER
      assert_equal outcome(from_power_on), outcome(cold)
      assert_equal outcome(from_power_on), outcome(warm)
    end
  end

  def test_two_alike_cartridges_stay_alike_from_a_snapshot
    with_snapshots do |snapshots|
      2.times { refute tape.compare(walker, walker, starting_after: START_AFTER, snapshots: snapshots).drift? }
    end
  end

  # Made once, a snapshot is loaded, and each cartridge plays only the frames after the start.
  def test_a_warm_start_steps_only_the_frames_after_it
    ours = walker
    late = walker(late: true)
    with_snapshots do |snapshots|
      cold = tape.compare(ours, late, starting_after: START_AFTER, snapshots: snapshots, carrying_on: true)
      warm = tape.compare(ours, late, starting_after: START_AFTER, snapshots: snapshots, carrying_on: true)

      assert_equal [TAPE_FRAMES, TAPE_FRAMES], cold.frames_stepped
      assert_equal [TAPE_FRAMES - START_AFTER, TAPE_FRAMES - START_AFTER], warm.frames_stepped
    end
  end

  # The key is the cartridge's bytes and the presses up to the start: another build, or another
  # press before the start, makes a snapshot of its own; a press after the start does not.
  def test_a_changed_cartridge_or_tape_makes_a_snapshot_of_its_own
    with_snapshots do |snapshots, folder|
      tape.compare(walker, walker, starting_after: START_AFTER, snapshots: snapshots)
      assert_equal 1, snapshot_files(folder).size, "one cartridge on both sides is one snapshot"

      tape.compare(walker, walker(from: 24), starting_after: START_AFTER, snapshots: snapshots)
      assert_equal 2, snapshot_files(folder).size, "another build"

      tape(last_press: :right).compare(walker, walker, starting_after: START_AFTER, snapshots: snapshots)
      assert_equal 2, snapshot_files(folder).size, "a press after the start only"

      tape.compare(walker, walker, starting_after: START_AFTER - 40, snapshots: snapshots)
      assert_equal 3, snapshot_files(folder).size, "another start"
    end
  end

  # A probe opened on the same cartridge after the same presses loads the comparison's snapshot.
  def test_a_probe_opens_from_the_snapshot_a_comparison_made
    game = walker
    with_snapshots do |snapshots, folder|
      tape.compare(game, game, starting_after: START_AFTER, snapshots: snapshots)
      stepped = VBlank::Playthroughs::Probe.open(game, tape: tape, starting_after: START_AFTER, snapshots: snapshots) do |probe|
        probe.step(10)
        probe.reader.frames_played
      end

      assert_equal 1, snapshot_files(folder).size
      assert_equal 10, stepped
    end
  end

  # A snapshot the emulator will not take is played to again from power-on, and made again.
  def test_a_snapshot_that_fails_to_load_is_played_to_again
    ours = walker
    late = walker(late: true)
    with_snapshots do |snapshots, folder|
      cold = tape.compare(ours, late, starting_after: START_AFTER, snapshots: snapshots)
      snapshot_files(folder).each { |path| File.binwrite(path, "not a state") }
      said = StringIO.new
      kept = VBlank.logger
      VBlank.logger = VBlank::Logger.new(said)
      replayed = begin
        tape.compare(ours, late, starting_after: START_AFTER, snapshots: snapshots)
      ensure
        VBlank.logger = kept
      end

      assert_equal outcome(cold), outcome(replayed)
      assert_equal cold.frames_stepped, replayed.frames_stepped, "played from power-on again"
      assert_equal 2, said.string.lines.grep(/snapshot/).size, "a line for each cartridge's snapshot: #{said.string}"
      warm = tape.compare(ours, late, starting_after: START_AFTER, snapshots: snapshots)
      assert_equal outcome(cold), outcome(warm)
    end
  end

  # NO_SNAPSHOT_CACHE plays every start from power-on, to check that a run from snapshots agrees.
  def test_a_run_can_turn_snapshots_off
    with_snapshots(env: { "NO_SNAPSHOT_CACHE" => "1" }) do |snapshots|
      2.times do
        result = tape.compare(walker, walker(late: true), starting_after: START_AFTER, snapshots: snapshots)
        assert_operator result.frames_stepped.first, :>, START_AFTER
      end
    end
  end

  # A moment of the tape names the frame to start after.
  def test_a_start_can_be_a_moment
    ours = walker
    late = walker(late: true)
    with_snapshots do |snapshots|
      by_moment = tape.compare(ours, late, starting_after: :at_300, snapshots: snapshots)

      assert_equal outcome(tape.compare(ours, late)), outcome(by_moment)
    end
  end

  def test_a_start_past_the_tape_is_refused
    error = assert_raises(ArgumentError) { tape.compare(walker, walker, starting_after: TAPE_FRAMES) }

    assert_match "starting_after", error.message
  end

  # A part of the screen given as rectangles, for stretches of frames, or by a block that reads the
  # running cartridges, finds from a start what it finds from power-on with the frames before the
  # start left out. The block is asked from the frame after the start.
  def test_a_start_looks_at_the_parts_it_is_given
    ours = walker
    late = walker(late: true)
    by_block = ->(first, _second) { first.var(:passes).even? ? [[0, 0, 240, 160]] : [[0, 0, 120, 160]] }
    with_snapshots do |snapshots|
      [{ looking_at: [[0, 40, 240, 40]] }, { looking_at: { 1..350 => [[0, 0, 120, 160]] } },
       { looking_at: by_block }, { ignoring_rectangles: ->(_first, _second, frame) { frame.odd? ? [[200, 0, 40, 160]] : [] } }]
        .each do |part|
          from_power_on = tape.compare(ours, late, ignoring_frames: [1..START_AFTER], **part)
          started = tape.compare(ours, late, starting_after: START_AFTER, snapshots: snapshots, **part)

          assert from_power_on.drift?, "the late build differs inside #{part.keys.first}"
          assert_equal outcome(from_power_on), outcome(started), part.keys.first.to_s
        end
    end
  end

  # The strict rule for torn frames looks at the frames before one, which a start does not.
  def test_a_start_with_settings_that_look_back_is_refused
    torn = assert_raises(ArgumentError) do
      tape.compare(walker, walker, starting_after: START_AFTER, forgiving_torn_frames_of: :second)
    end

    assert_match "forgiving_torn_frames_of", torn.message
  end

  def test_a_start_with_lead_ins_is_refused
    lead_in = VBlank.playthrough("wait") { wait frames: 2 }
    error = assert_raises(ArgumentError) do
      tape.compare(walker, walker, starting_after: START_AFTER, lead_ins: [lead_in, lead_in])
    end

    assert_match "lead_ins", error.message
  end
end
