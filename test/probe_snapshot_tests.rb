# frozen_string_literal: true

require "stringio"
require "tmpdir"

# A probe opened part way through a tape (`starting_after:`), from a snapshot of the console kept on
# disk (Playthroughs::SnapshotCache), held to a probe stepped there from power-on. Each including
# test says +console+.
#
# The game is a white box on a blue field that walks right a pixel a pass while RIGHT is down and
# left while LEFT is, so where it stands shows the presses that came before.
module ProbeSnapshotTests
  # How far the tape plays, where the probe opens, and how many frames it is stepped after.
  TAPE_FRAMES = 400
  START_AFTER = 300
  STEPPED_AFTER = 30

  private def walker(from: 20)
    VBlank.build("WALKER", console: console, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(32) { "." * 32 }
      box = sprite :box, at: [from, 60]
      game_loop do
        box.x += 1 if held(:right)
        box.x -= 1 if held(:left)
      end
    end
  end

  # +first_press+ for fifty frames, then right and left by turns, fifty frames each, with a moment
  # every hundred frames. +last_press+ is what the last fifty hold, after the start. By the start the
  # box stands a hundred pixels right of where it began, or where it began if the first press is left.
  private def tape(first_press: :right, last_press: :left)
    lines = ["vblank tape 1", "recorded on: WALKER 0x00000000", "starts from: power-on", ""]
    turns = TAPE_FRAMES / 50
    turns.times do |turn|
      held = %i[left right][turn % 2]
      held = first_press if turn.zero?
      held = last_press if turn == turns - 1
      lines << "50 #{held}"
      lines << "moment at_#{(turn + 1) * 50}" if ((turn + 1) * 50 % 100).zero?
    end
    VBlank::Playthroughs::Tape.parse("#{lines.join("\n")}\n")
  end

  private def with_snapshots(env: {})
    Dir.mktmpdir("vblank-snapshots") { |folder| yield VBlank::Playthroughs::SnapshotCache.new(folder, env: env), folder }
  end

  private def snapshot_files(folder) = Dir.glob(File.join(folder, "**", "*.state"))

  # What a probe opened on +cartridge+ with +opened+ shows STEPPED_AFTER frames on, its
  # frame counter then, and how many frames its emulator stepped.
  private def seen(cartridge, **opened)
    VBlank::Playthroughs::Probe.open(cartridge, **opened) do |probe|
      opened_on = probe.frame
      probe.step(STEPPED_AFTER, holding: :right)
      { opened_on: opened_on, picture: probe.screen_picture.pixels, frame: probe.frame,
        stepped: probe.reader.frames_played }
    end
  end

  # From power-on, stepped through the tape's presses by hand, as a test does without the cache.
  private def seen_from_power_on(cartridge, tape)
    VBlank::Playthroughs::Probe.open(cartridge) do |probe|
      tape.presses_within(1..START_AFTER).each { |stretch| probe.step(stretch.frames.size, holding: stretch.buttons) }
      opened_on = probe.frame
      probe.step(STEPPED_AFTER, holding: :right)
      { opened_on: opened_on, picture: probe.screen_picture.pixels, frame: probe.frame,
        stepped: probe.reader.frames_played }
    end
  end

  private def without_work(seen) = seen.except(:stepped)

  def test_a_probe_opened_from_a_snapshot_reads_what_power_on_reads
    game = walker
    from_power_on = seen_from_power_on(game, tape)
    with_snapshots do |snapshots|
      cold = seen(game, tape: tape, starting_after: START_AFTER, snapshots: snapshots)
      warm = seen(game, tape: tape, starting_after: START_AFTER, snapshots: snapshots)

      refute_equal from_power_on[:picture], seen_from_power_on(game, tape(first_press: :left))[:picture],
                   "the presses before the start move the box"
      assert_equal START_AFTER, warm[:opened_on], "frames count from power-on"
      assert_equal START_AFTER + STEPPED_AFTER, warm[:frame]
      assert_equal without_work(from_power_on), without_work(cold)
      assert_equal without_work(from_power_on), without_work(warm)
    end
  end

  # Made once, the snapshot is loaded, and the probe steps only the frames asked of it after.
  def test_a_warm_probe_steps_only_the_frames_after_its_start
    game = walker
    with_snapshots do |snapshots|
      cold = seen(game, tape: tape, starting_after: START_AFTER, snapshots: snapshots)
      warm = seen(game, tape: tape, starting_after: START_AFTER, snapshots: snapshots)

      assert_equal START_AFTER + STEPPED_AFTER, cold[:stepped]
      assert_equal STEPPED_AFTER, warm[:stepped]
    end
  end

  # Another build, or another press before the start, makes a snapshot of its own; a press after
  # the start does not.
  def test_a_changed_cartridge_or_tape_misses
    with_snapshots do |snapshots, folder|
      seen(walker, tape: tape, starting_after: START_AFTER, snapshots: snapshots)
      assert_equal 1, snapshot_files(folder).size

      other_build = seen(walker(from: 24), tape: tape, starting_after: START_AFTER, snapshots: snapshots)
      assert_equal 2, snapshot_files(folder).size, "another build"
      assert_equal START_AFTER + STEPPED_AFTER, other_build[:stepped]

      later = seen(walker, tape: tape(last_press: :right), starting_after: START_AFTER, snapshots: snapshots)
      assert_equal 2, snapshot_files(folder).size, "a press after the start only"
      assert_equal STEPPED_AFTER, later[:stepped]

      earlier = seen(walker, tape: tape(first_press: :left), starting_after: START_AFTER, snapshots: snapshots)
      assert_equal 3, snapshot_files(folder).size, "a press before the start"
      assert_equal START_AFTER + STEPPED_AFTER, earlier[:stepped]
    end
  end

  # NO_SNAPSHOT_CACHE plays every start from power-on, and the two agree.
  def test_a_run_can_turn_snapshots_off
    game = walker
    with_snapshots do |kept|
      warm = Array.new(2) { seen(game, tape: tape, starting_after: START_AFTER, snapshots: kept) }.last
      with_snapshots(env: { "NO_SNAPSHOT_CACHE" => "1" }) do |fresh|
        2.times do
          played = seen(game, tape: tape, starting_after: START_AFTER, snapshots: fresh)

          assert_equal START_AFTER + STEPPED_AFTER, played[:stepped]
          assert_equal without_work(warm), without_work(played)
        end
      end
    end
  end

  # Without a cache the probe is stepped to the start from power-on.
  def test_a_probe_without_snapshots_plays_to_its_start
    game = walker
    played = seen(game, tape: tape, starting_after: START_AFTER)

    assert_equal without_work(seen_from_power_on(game, tape)), without_work(played)
    assert_equal START_AFTER + STEPPED_AFTER, played[:stepped]
  end

  def test_a_start_can_be_a_moment
    game = walker
    with_snapshots do |snapshots|
      by_moment = seen(game, tape: tape, starting_after: :at_300, snapshots: snapshots)

      assert_equal without_work(seen_from_power_on(game, tape)), without_work(by_moment)
    end
  end

  def test_a_start_the_tape_cannot_give_is_refused
    game = walker
    past = assert_raises(ArgumentError) { VBlank::Playthroughs::Probe.open(game, tape: tape, starting_after: TAPE_FRAMES + 1) }
    no_tape = assert_raises(ArgumentError) { VBlank::Playthroughs::Probe.open(game, starting_after: START_AFTER) }
    no_start = with_snapshots do |snapshots|
      assert_raises(ArgumentError) { VBlank::Playthroughs::Probe.open(game, tape: tape, snapshots: snapshots) }
    end
    no_moment = assert_raises(ArgumentError) { VBlank::Playthroughs::Probe.open(game, tape: tape, starting_after: :nowhere) }

    assert_match "starting_after", past.message
    assert_match "tape:", no_tape.message
    assert_match "starting_after", no_start.message
    assert_match "nowhere", no_moment.message
  end
end
