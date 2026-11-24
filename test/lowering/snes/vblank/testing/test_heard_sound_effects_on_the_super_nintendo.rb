# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A Super Nintendo build's sound effects heard alone while its tune plays on under them.
#
# The build's sound player puts each recorded note in whichever place is free or ranks lowest
# (Runtime::Recordings), and each place sounds on a voice of its own, so an effect struck again
# lands on another voice, and the tune's next notes take the voices between. No list of voices hears
# the effect without some of the tune. `hearing: :sound_effects` follows the voices the effects hold,
# frame by frame, read off the sound player as the cartridge runs.
#
# The game is a tune whose eight recorded parts take every voice in turn, under an effect of one
# recorded note, ranked above it and struck four times. Its answer key is the same game with the
# tune never started, where the effect is the only sound.
class TestHeardSoundEffectsOnTheSuperNintendo < Minitest::Test
  include VBlank::Testing::HeardAlike

  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  STRIKES = [40, 77, 113, 151].freeze
  TAPE_FRAMES = 230

  # The tolerances a port holds one effect to its original's by: first heard on the same frame or
  # one after, a level within a tenth, and an end within two frames.
  EFFECT_HELD = { heard_above: 0, first_heard_frames_apart: 1, level_share_apart: 0.1, ending_frames_apart: 2 }.freeze

  # +tune+ starts the tune on the second pass; +volume+ is the effect's note's.
  private def game(tune: true, volume: 12)
    VBlank.build("EFFECTS", console: :snes, out: nil, err: nil) do
      enable_sound
      instrument :piano, pcm: [60, -60] * 16_000, rate: 8000, note: :C4
      parts = Array.new(8) do |k|
        Part.new(plays: :piano, notes: Array.new(12) { |n| Note.new(at: (n * 24) + (k * 3), key: :C3, length: 16) })
      end
      music = songs :music, [Score.new(tempo: 150, parts: parts)]
      strike = Score.new(tempo: 150, priority: 1, length: 14,
                         parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: :G5, length: 10, volume: volume)])])
      sfx = sound_effects :sfx, [strike]
      pass = var :pass, 0
      game_loop do
        pass += 1
        music.play 0 if tune && pass == 2
        STRIKES.each { |at| sfx.play 0 if pass == at }
      end
    end
  end

  private def listen = VBlank.playthrough("listen") { wait frames: TAPE_FRAMES }

  private def every_voice = VBlank::Diagnostics::SNESProbe::VOICE_NAMES.to_a

  # The voices the effects hold on each frame where they hold any.
  private def effect_voices_by_frame(cartridge)
    reader = VBlank::Playthroughs::Playthrough.power_on(cartridge)
    Array.new(TAPE_FRAMES) { reader.step(1).sound_effect_voices }.reject(&:empty?)
  ensure
    reader&.close
  end

  def test_the_effect_lands_on_voices_the_tune_plays_on
    held = effect_voices_by_frame(game)

    assert_operator held.uniq.size, :>=, 3, "the four strikes take at least three voices"
    assert_equal [[:voice4]], effect_voices_by_frame(game(tune: false)).uniq, "with no tune, the first place every time"
  end

  # Every voice heard, the tune is under the effect, and the two builds differ.
  def test_every_voice_hears_the_tune_too
    compared = VBlank::Playthroughs::HeardComparison.play(listen, game, game(tune: false), hearing: [every_voice, every_voice],
                                                                                          **EFFECT_HELD)

    refute compared.alike?
  end

  def test_the_effects_alone_sound_as_the_effect_with_no_tune
    assert_heard_alike game, game(tune: false), listen, hearing: [:sound_effects, every_voice], **EFFECT_HELD
  end

  # Each frame is heard on the voices held at its end, read a frame ahead, so the effect alone is
  # first and last heard on the frames the effect with no tune is. Its level is a little under,
  # where the chip plays the first samples of a strike's last frame before the change reaches it.
  def test_the_effects_alone_start_and_end_on_the_effects_own_frames
    assert_heard_alike game, game(tune: false), listen, hearing: [:sound_effects, every_voice],
                       **EFFECT_HELD, first_heard_frames_apart: 0, ending_frames_apart: 0, level_share_apart: 0.05
  end

  def test_a_wrong_effect_is_named
    failure = assert_raises(Minitest::Assertion) do
      assert_heard_alike game, game(tune: false, volume: 6), listen, hearing: [:sound_effects, every_voice], **EFFECT_HELD
    end

    assert_match(/Heard alone: the sound effects, on the voices they held on the first cartridge/, failure.message)
    assert_match(/heard at different levels/, failure.message)
  end

  # From a snapshot of a frame between two strikes, the effects alone are heard as from power-on: the
  # console a frame ahead opens from the same snapshot and plays each frame first, as it does there.
  def test_the_effects_alone_are_heard_from_a_snapshot_as_from_power_on
    ours = game
    original = game(tune: false)
    tape = listen.play(ours).tape
    Dir.mktmpdir("vblank-snapshots") do |folder|
      snapshots = VBlank::Playthroughs::SnapshotCache.new(folder)
      heard = lambda do |**kept|
        VBlank::Playthroughs::HeardComparison.play(tape, ours, original, hearing: [:sound_effects, every_voice], starting_after: 95,
                                                                         **EFFECT_HELD, **kept)
      end
      cold = heard.call
      heard.call(snapshots: snapshots)
      warm = heard.call(snapshots: snapshots)

      assert_predicate cold, :alike?
      assert_predicate warm, :alike?
      assert_operator cold.first.first_heard, :>, 95, "frames are counted from power-on"
      # bsnes's sound after a load is within a few thousandths of the console's (SNESKit#frames_sound_settles_after_load).
      [[cold.first, warm.first], [cold.second, warm.second]].each do |from_power_on, from_snapshot|
        assert_equal [from_power_on.first_heard, from_power_on.last_heard], [from_snapshot.first_heard, from_snapshot.last_heard]
        assert_in_delta from_power_on.level, from_snapshot.level, from_power_on.level * 0.005
      end
      settle = VBlank::Console.for(:snes).frames_sound_settles_after_load
      assert_equal [TAPE_FRAMES - 95 + settle] * 2, warm.frames_stepped
    end
  end

  # A cartridge file is only its bytes: nothing says where its sound player keeps who holds a voice.
  def test_a_cartridge_file_cannot_be_asked_for_its_sound_effects
    Dir.mktmpdir("cartridges") do |folder|
      path = File.join(folder, "original.sfc")
      game(tune: false).write(path)

      error = assert_raises(ArgumentError) do
        VBlank::Playthroughs::HeardComparison.play(listen, game, path, hearing: [:sound_effects, :sound_effects], **EFFECT_HELD)
      end
      assert_match(/not built here/, error.message)
    end
  end
end
