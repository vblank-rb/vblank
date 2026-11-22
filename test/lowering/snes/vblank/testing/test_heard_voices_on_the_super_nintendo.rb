# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The Super Nintendo's sound chip mixes eight voices into the main output (fullsnes, "SNES APU DSP
# Voices"), and a reader can hear one of them alone: the others are silenced where each voice's
# sound is added to the mix, and go on running. So two cartridges are held alike voice by voice, and
# a failure names the voice that differs.
#
# The game is a tune on the first voice under an effect on the second (Runtime's music takes voice
# 0 for its first part and a beep the next voice), both cartridges written to files as an original is.
class TestHeardVoicesOnTheSuperNintendo < Minitest::Test
  include VBlank::Testing::HeardAlike

  TUNE_STARTS = 20
  BEEP_STARTS = 50
  TAPE_FRAMES = 160

  # Two builds of one game differ in nothing, as in HeardAlikeTests.
  STRICT = { heard_above: 400, first_heard_frames_apart: 0, level_share_apart: 0.01, ending_frames_apart: 0 }.freeze

  private def game(beep_volume: 12)
    VBlank.build("VOICES", console: :snes, out: nil, err: nil) do
      enable_sound
      song(:tune) do
        voice(:lead) do
          note :A4, :half
          8.times { rest :whole }
        end
      end
      define_sound :ping, frequency: 880, decay: :slow, volume: beep_volume
      pass = var :pass, 0
      game_loop do
        pass += 1
        play_song :tune if pass == TUNE_STARTS
        beep :ping if pass == BEEP_STARTS
      end
    end
  end

  private def listen = VBlank.playthrough("listen") { wait frames: TAPE_FRAMES }

  private def as_files(*cartridges)
    Dir.mktmpdir("cartridges") do |folder|
      yield(*cartridges.each_with_index.map { |cartridge, n| File.join(folder, "#{n}.sfc").tap { |path| cartridge.write(path) } })
    end
  end

  # The frame each voice is first heard on, played alone on a cartridge file.
  private def first_heard_alone(path, voice)
    reader = VBlank::Diagnostics::Verifier.new(VBlank::Diagnostics::CartridgeFile.new(path), frames: 0)
    reader.hearing(only: [voice]).step(TAPE_FRAMES)
    reader.loudest_by_frame.index { |loudest| loudest > STRICT.fetch(:heard_above) }
  ensure
    reader&.close
  end

  def test_the_eight_voices_are_named_and_each_is_heard_alone
    as_files(game) do |path|
      reader = VBlank::Diagnostics::Verifier.new(VBlank::Diagnostics::CartridgeFile.new(path), frames: 0)
      assert_equal (0..7).map { |n| :"voice#{n}" }, reader.channels
      reader.close

      tune = first_heard_alone(path, :voice0)
      beep = first_heard_alone(path, :voice1)

      refute_nil tune, "the tune is heard alone on the first voice"
      # A song's first note reaches the chip a frame after a beep named in the same pass would.
      assert_in_delta BEEP_STARTS - TUNE_STARTS, beep - tune, 1, "and the beep alone on the second, not the tune before it"
      assert_nil first_heard_alone(path, :voice5), "a voice nothing plays is silent"
    end
  end

  # Silencing a voice part way through leaves it running: heard again, it sounds as the same voice
  # never silenced, with its envelope where time has taken it.
  def test_a_voice_heard_again_sounds_as_if_never_silenced
    as_files(game) do |path|
      cartridge = VBlank::Diagnostics::CartridgeFile.new(path)
      interrupted = VBlank::Diagnostics::Verifier.new(cartridge, frames: 0)
      interrupted.hearing(only: [:voice1]).step(BEEP_STARTS + 4)
      interrupted.hearing(only: [:voice5]).step(4)
      interrupted.hearing(only: [:voice1]).step(4)
      unbroken = VBlank::Diagnostics::Verifier.new(cartridge, frames: 0)
      unbroken.hearing(only: [:voice1]).step(BEEP_STARTS + 12)

      # The first few samples of the frame a change is made in were made before it, as the chip runs a
      # little behind the processor: the window's first frame is not looked at.
      assert_operator interrupted.loudest_by_frame.last(8)[1, 3].max, :<=, STRICT.fetch(:heard_above),
                      "the beep is silent while a voice nothing plays is heard"
      assert_operator unbroken.loudest_by_frame.last(8)[1, 3].min, :>, STRICT.fetch(:heard_above),
                      "where it sounds unsilenced"
      assert_equal unbroken.last_frame_samples, interrupted.last_frame_samples
    ensure
      interrupted&.close
      unbroken&.close
    end
  end

  def test_two_files_of_one_game_are_heard_alike
    as_files(game, game) { |ours, theirs| assert_heard_alike ours, theirs, listen, **STRICT }
  end

  # The effect played quieter: the mix differs, and played a voice at a time the second voice, the
  # effect's, is named, and the tune's is alike.
  def test_a_wrong_effect_is_named_by_its_voice
    as_files(game, game(beep_volume: 5)) do |ours, theirs|
      failure = assert_raises(Minitest::Assertion) { assert_heard_alike ours, theirs, listen, **STRICT }

      assert_match(/Played alone, the voice1 voice differs:\n  The two cartridges are heard at different levels/, failure.message)
      assert_match(/Played alone, these voices are alike: [^\n]*voice0/, failure.message)
      refute_match "the voice0 voice differs", failure.message
    end
  end
end
