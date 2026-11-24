# frozen_string_literal: true

require "tmpdir"
require "probe_snapshot_tests"

# A tape played on a cartridge, and a film's cartridge side, started part way through the tape
# (`starting_after:`) from a snapshot of the console kept on disk (Playthroughs::SnapshotCache), held
# to the same playing from power-on. Each including test says +console+.
module TapeSnapshotTests
  include SnapshotWalker

  # How many frames a film's side is stepped after its start.
  FILMED_FRAMES = 20

  # What +tape+ played on +cartridge+ came to, with what a test compares: the tape it made, the
  # moments and the pictures at them, the moments whose block was handed the game, the picture at
  # the end, and how many frames the emulator stepped.
  private def played(cartridge, tape, **settings)
    handed = []
    result = tape.play(cartridge, **settings) { |moment, _game| handed << moment }
    { tape: result.tape.to_s, moments: result.moments, frames: result.frames, pictures: result.pictures,
      handed: handed, last_picture: result.game.screen_picture.pixels, stepped: result.game.frames_played }
  ensure
    result&.game&.close
  end

  private def without_start_work(seen) = seen.except(:stepped, :pictures, :handed)

  def test_a_warm_tape_play_steps_only_the_frames_after_its_start
    game = walker
    from_power_on = played(game, tape)
    with_snapshots do |snapshots|
      cold = played(game, tape, starting_after: START_AFTER, snapshots: snapshots)
      warm = played(game, tape, starting_after: START_AFTER, snapshots: snapshots)

      assert_equal TAPE_FRAMES, from_power_on[:stepped]
      assert_equal TAPE_FRAMES, cold[:stepped]
      assert_equal TAPE_FRAMES - START_AFTER, warm[:stepped]
      assert_equal without_start_work(from_power_on), without_start_work(cold)
      assert_equal without_start_work(from_power_on), without_start_work(warm)
    end
  end

  # A moment at or before the start is on the tape that comes back, and its block is not handed the
  # game: :at_300 is the start's own frame, which a console put back from a snapshot has not drawn
  # yet, and a start played to cold is treated the same. A moment after it is handed the game, with
  # its picture kept.
  def test_moments_at_or_before_the_start_are_not_handed_the_game
    game = walker
    from_power_on = played(game, tape)
    with_snapshots do |snapshots|
      cold, warm = Array.new(2) { played(game, tape, starting_after: :at_300, snapshots: snapshots) }

      assert_equal %i[at_100 at_200 at_300 at_400], from_power_on[:handed]
      [cold, warm].each do |started|
        assert_equal %i[at_400], started[:handed]
        assert_equal %i[at_400], started[:pictures].keys
        assert_equal from_power_on[:pictures][:at_400], started[:pictures][:at_400]
        assert_equal from_power_on[:moments], started[:moments]
      end
    end
  end

  def test_a_tape_play_without_snapshots_plays_to_its_start
    game = walker
    from_start = played(game, tape, starting_after: START_AFTER)

    assert_equal without_start_work(played(game, tape)), without_start_work(from_start)
    assert_equal TAPE_FRAMES, from_start[:stepped]
  end

  def test_a_start_the_tape_play_cannot_use_is_refused
    game = walker
    past = assert_raises(ArgumentError) { tape.play(game, starting_after: TAPE_FRAMES + 1) }
    no_moment = assert_raises(ArgumentError) { tape.play(game, starting_after: :nowhere) }
    elsewhere = assert_raises(ArgumentError) { tape.play(game, starting_after: START_AFTER, on: "interpreter") }
    led_in = assert_raises(ArgumentError) do
      tape.play(game, starting_after: START_AFTER, lead_in: VBlank::Playthroughs::Playthrough.new("wait") { wait frames: 1 })
    end
    no_start = with_snapshots { |snapshots| assert_raises(ArgumentError) { tape.play(game, snapshots: snapshots) } }

    assert_match "starting_after", past.message
    assert_match "nowhere", no_moment.message
    assert_match "emulator", elsewhere.message
    assert_match "lead_in", led_in.message
    assert_match "starting_after", no_start.message
  end

  # A film's side opened after a frame of a tape, from a snapshot, shows what the side opened after
  # the tape cut at that frame shows, frame for frame.
  def test_a_film_side_from_a_snapshot_shows_what_one_played_there_shows
    game = walker
    Dir.mktmpdir("tape") do |dir|
      whole = File.join(dir, "whole.tape")
      cut = File.join(dir, "cut.tape")
      tape.write(whole)
      tape.up_to(START_AFTER).write(cut)
      played_there = filmed(game, tape: cut)
      with_snapshots do |snapshots, folder|
        cold = filmed(game, tape: whole, starting_after: START_AFTER, snapshots: snapshots)
        warm = filmed(game, tape: whole, starting_after: :at_300, snapshots: snapshots)

        assert_equal 1, snapshot_files(folder).size
        assert_equal played_there, cold
        assert_equal played_there, warm
      end
    end
  end

  # The pictures of FILMED_FRAMES frames of a film's side opened with +opened+, holding RIGHT.
  private def filmed(cartridge, **opened)
    side = VBlank::Diagnostics::FilmCartridge.open(cartridge, **opened)
    Array.new(FILMED_FRAMES) { side.step(1, keys: VBlank::IR::Buttons.mask([:right])).screen_picture.pixels }
  ensure
    side&.close
  end
end
