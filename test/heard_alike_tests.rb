# frozen_string_literal: true

require "tmpdir"

# A PORT HOLDS WHAT ITS CARTRIDGE PUTS OUT OF THE SPEAKERS TO ITS ORIGINAL'S with one assertion,
# assert_heard_alike, and a probe says what any cartridge put out on a frame. Played by each console
# whose emulator hands its sound over. Each including test says +console+.
#
# The cartridges are builds of one small game: a tune of two notes on a square voice, started on
# pass START, then a rest as long as the rest of the tape. The "original" is another build of it,
# written to a file as an original is, with one thing changed: started a pass late, played quieter,
# or its last note held longer.
module HeardAlikeTests
  include VBlank::Testing::HeardAlike

  # The pass the tune starts on, and the frames the tape lasts: past the end of the longest tune.
  START = 20
  TAPE_FRAMES = 200

  # What the game gives a comparison of two builds that should be the same build. The emulator's
  # silence between notes is not exactly nought on every console, so a frame is heard above a level
  # far under a note's. Two builds of one game differ in nothing, so no frame and a hundredth of
  # the level is all they may be apart.
  STRICT = { heard_above: 400, first_heard_frames_apart: 0, level_share_apart: 0.01, ending_frames_apart: 0 }.freeze

  # What each test gives the comparison. A console whose speaker is heard settling as it is
  # switched on gives a lead-in as well, which plays those frames before the counted ones.
  private def alike_settings = STRICT

  # What a test gives where the second tune is a frame later or a note longer, and the level is
  # not what the test is about: the same, on a console whose notes are as loud on every frame.
  private def moved_tune_settings = alike_settings

  # A lead-in for a console whose emulator puts out a click on the first frames after power-on,
  # the speaker settling: the game is silent then, and both cartridges click alike.
  private def past_the_power_on_click = VBlank.playthrough("past the power-on click") { wait frames: 10 }

  private def tune_game(starts: START, loudness: 15, last: :quarter)
    VBlank.build("HEARD", console: console, out: nil, err: nil) do
      enable_sound
      song(:tune) do
        voice(:lead) do
          volume loudness
          note :A4, :quarter
          note :C5, last
          8.times { rest :whole }
        end
      end
      pass = var :pass, 0
      game_loop do
        pass += 1
        play_song :tune if pass == starts
      end
    end
  end

  private def listen = VBlank.playthrough("listen") { wait frames: TAPE_FRAMES }

  # +cartridge+ written to a file, as an original is: nothing of its build beside it.
  private def as_a_file(cartridge)
    Dir.mktmpdir("cartridges") do |folder|
      extension = VBlank::Console.for(console).description.extension
      yield File.join(folder, "original#{extension}").tap { |path| cartridge.write(path) }
    end
  end

  private def failure_against(original, **settings)
    as_a_file(original) do |path|
      return assert_raises(Minitest::Assertion) { assert_heard_alike tune_game, path, listen, **alike_settings, **settings }.message
    end
  end

  def test_a_probe_says_the_samples_of_the_last_frame_and_the_loudest_of_them
    as_a_file(tune_game) do |path|
      VBlank::Playthroughs::Probe.open(path) do |probe|
        probe.step(START + 30)
        sound = probe.last_frame_sound

        assert_operator sound.samples.size, :>, 500, "a frame of samples for each speaker"
        assert(sound.samples.all? { |sample| sample.between?(-32_768, 32_767) })
        assert_equal sound.samples.map(&:abs).max, sound.loudest
        assert_operator sound.loudest, :>, STRICT.fetch(:heard_above), "the tune is sounding"
        assert_equal sound.samples.size, sound.left.size + sound.right.size
        probe.step(TAPE_FRAMES)

        assert_operator probe.last_frame_sound.loudest, :<=, STRICT.fetch(:heard_above), "and has ended"
      end
    end
  end

  def test_two_builds_of_one_game_are_heard_alike
    as_a_file(tune_game) { |path| assert_heard_alike tune_game, path, listen, **alike_settings }
  end

  def test_a_tape_is_played_on_both_as_it_stands
    built = tune_game
    tape = listen.play(built).tape

    as_a_file(tune_game(loudness: 7)) do |path|
      compared = VBlank::Playthroughs::HeardComparison.play(tape, built, path, **alike_settings)

      assert_equal :level, compared.difference.what
      assert_equal TAPE_FRAMES, compared.second.frames
    end
  end

  def test_a_tune_a_frame_late_fails_naming_the_frame_it_is_first_heard_on
    as_a_file(tune_game(starts: START + 1)) do |path|
      compared = VBlank::Playthroughs::HeardComparison.play(listen, tune_game, path, **alike_settings)
      ours, theirs = compared.difference.measured

      assert_equal :first_heard, compared.difference.what
      assert_equal ours + 1, theirs
      assert_equal ours, compared.difference.frame
      assert_operator compared.difference.loudest.first, :>, STRICT.fetch(:heard_above), "ours is heard on that frame"
      assert_operator compared.difference.loudest.last, :<=, STRICT.fetch(:heard_above), "and the late one is still silent"
      message = failure_against(tune_game(starts: START + 1))

      assert_match "first heard on different frames", message
      assert_match "frame #{ours} on the first and frame #{theirs} on the second", message
      assert_match "They first differ on frame #{ours}", message
    end
  end

  def test_a_frame_late_passes_where_the_game_allows_a_frame
    as_a_file(tune_game(starts: START + 1)) do |path|
      assert_heard_alike tune_game, path, listen, **moved_tune_settings, first_heard_frames_apart: 1, ending_frames_apart: 1
    end
  end

  def test_a_quieter_tune_fails_naming_each_level
    message = failure_against(tune_game(loudness: 7))

    assert_match "heard at different levels", message
    assert_match(/They first differ on frame \d+: the loudest sample is \d+ on the first and \d+ on the second/, message)
  end

  def test_a_last_note_that_rings_longer_fails_naming_the_frame_one_falls_silent
    as_a_file(tune_game(last: :half)) do |path|
      compared = VBlank::Playthroughs::HeardComparison.play(listen, tune_game, path, **moved_tune_settings)
      ours, theirs = compared.difference.measured

      assert_equal :last_heard, compared.difference.what
      assert_in_delta 30, theirs - ours, 4, "a half note is thirty frames longer than a quarter, and each falls away over a few"
      assert_equal ours + 1, compared.difference.frame
      assert_match "last heard on different frames", failure_against(tune_game(last: :half), **moved_tune_settings)
    end
  end

  def test_a_silent_cartridge_fails_saying_which_is_never_heard
    message = failure_against(tune_game(starts: TAPE_FRAMES * 2))

    assert_match "The second cartridge is never heard", message
    assert_match "The first is first heard on frame", message
  end
end
