# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "cli_playing"

# `vblank compare --sound`: two cartridges heard side by side from the command line, by the
# measures assert_heard_alike holds them to (Playthroughs::HeardComparison). It ends 0 when they
# sound alike and 1 when they do not, saying every measure out, as the comparison of pictures does.
#
# The cartridges are builds of one small game: a tune of two notes on a square voice, started on
# pass 20, then a rest as long as the rest of the tape. Settings make a second game of it that
# differs in one thing: quieter, three frames late, or its second note an E where the game plays a C.
class TestCommandLineCompareSound < Minitest::Test
  include CLIPlaying

  AGREED = 0
  DIFFERED = 1
  NOT_COMPARED = 2

  TUNE = <<~RUBY
    require "vblank"

    VBlank.game "TUNE", consoles: %i[gba] do
      loudness = setting :loudness, 15
      starts = setting :starts, 20
      wrong_note = setting :wrong_note, 0
      enable_sound
      song(:tune) do
        voice(:lead) do
          volume loudness
          note :A4, :quarter
          note(wrong_note == 1 ? :E5 : :C5, :quarter)
          8.times { rest :whole }
        end
      end
      pass = var :pass, 0
      game_loop do
        pass += 1
        play_song :tune if pass == starts
      end
    end
  RUBY

  # Past the end of the tune, with a moment while it plays.
  LISTEN = <<~RUBY
    VBlank.playthrough "listen" do
      wait frames: 30
      moment :tune_playing
      wait frames: 170
    end
  RUBY

  # What the two builds of one game may be apart: nothing. The Advance's silence is exactly nought.
  STRICT = %w[--sound --heard-above 0 --first-heard-frames-apart 0 --level-share-apart 0.01 --ending-frames-apart 0].freeze

  private def with_tunes
    Dir.mktmpdir("compare-sound") do |dir|
      File.write(File.join(dir, "tune.rb"), TUNE)
      File.write(File.join(dir, "listen.rb"), LISTEN)
      cli("build", "tune.rb", "-o", "tune.gba", dir: dir)
      cli("build", "tune.rb", "--set", "loudness=7", "-o", "quiet.gba", dir: dir)
      cli("build", "tune.rb", "--set", "starts=23", "-o", "late.gba", dir: dir)
      cli("build", "tune.rb", "--set", "wrong_note=1", "-o", "wrong.gba", dir: dir)
      yield dir
    end
  end

  def test_two_builds_that_sound_alike_end_with_nought
    with_tunes do |dir|
      out, status = cli("compare", "tune.rb", "tune.gba", "--script", "listen.rb", *STRICT, dir: dir)

      assert_equal AGREED, status.exitstatus, out
      assert_match(/The two cartridges sound alike\. 200 frames were heard\./, out)
    end
  end

  def test_a_quieter_one_ends_with_one_and_says_each_level
    with_tunes do |dir|
      out, status = cli("compare", "tune.gba", "quiet.gba", "--script", "listen.rb", *STRICT, dir: dir)

      assert_equal DIFFERED, status.exitstatus, out
      assert_match(/The two cartridges sound different\./, out)
      assert_match(/heard at different levels/, out)
      assert_match(/Played alone, the square1 voice differs/, out)
    end
  end

  # --line-up-within-frames moves the late one back in line, and says how far.
  def test_a_late_one_lined_up_ends_with_nought_and_says_how_far_it_was_moved
    with_tunes do |dir|
      unmoved, unmoved_status = cli("compare", "tune.gba", "late.gba", "--tape", tape(dir), *STRICT, dir: dir)
      out, status = cli("compare", "tune.gba", "late.gba", "--tape", tape(dir), *STRICT, "--line-up-within-frames", "4",
                        dir: dir)

      assert_equal DIFFERED, unmoved_status.exitstatus, unmoved
      assert_equal AGREED, status.exitstatus, out
      assert_match(/The second cartridge's sound was moved 3 frames earlier/, out)
    end
  end

  # --pitch-cents-apart holds each voice's pitch, so a wrong note as loud as the right one is found.
  def test_a_wrong_note_is_found_by_its_pitch
    with_tunes do |dir|
      loud_alike, loud_status = cli("compare", "tune.gba", "wrong.gba", "--script", "listen.rb", *STRICT,
                                    "--ending-frames-apart", "2", dir: dir)
      out, status = cli("compare", "tune.gba", "wrong.gba", "--script", "listen.rb", *STRICT, "--ending-frames-apart", "2",
                        "--pitch-cents-apart", "25", dir: dir)

      refute_match(/pitch/, loud_alike, "#{loud_status.exitstatus}: the loudest sample a frame cannot hear it")
      assert_equal DIFFERED, status.exitstatus, out
      assert_match(/On the square1 voice alone: The two cartridges are heard at different pitches/, out)
    end
  end

  # --starting-after and --snapshots start both late in the tape, as for pictures: the difference is
  # found after the start, and a snapshot of each console is kept for the next run.
  def test_starting_after_hears_from_late_in_the_tape_from_kept_snapshots
    with_tunes do |dir|
      out, status = cli("compare", "tune.gba", "quiet.gba", "--tape", tape(dir), *STRICT, "--starting-after", "tune_playing",
                        "--snapshots", "snaps", dir: dir)
      again, again_status = cli("compare", "tune.gba", "quiet.gba", "--tape", tape(dir), *STRICT, "--starting-after", "30",
                                "--snapshots", "snaps", dir: dir)

      assert_equal DIFFERED, status.exitstatus, out
      assert_operator out[/They first differ on frame (\d+)/, 1].to_i, :>, 30
      refute_empty Dir.glob(File.join(dir, "snaps", "*.state")), "a snapshot of each console"
      assert_equal DIFFERED, again_status.exitstatus, again
      assert_equal out[/They first differ on frame (\d+)/, 1], again[/They first differ on frame (\d+)/, 1]
    end
  end

  # --wav writes both sounds for a person to hear, one after the other.
  def test_wav_writes_both_sounds
    with_tunes do |dir|
      out, status = cli("compare", "tune.gba", "quiet.gba", "--script", "listen.rb", *STRICT, "--wav", "both.wav", dir: dir)

      assert_equal DIFFERED, status.exitstatus, out
      assert_match(/Wrote both sounds to both\.wav\./, out)
      assert_operator File.size(File.join(dir, "both.wav")), :>, 44
    end
  end

  # What cannot go with --sound, or is missing from it, ends with 2 and says which flag.
  def test_flags_written_wrongly_end_with_two_and_are_said_plainly
    with_tunes do |dir|
      {
        %w[--sound] => /--heard-above/,
        [*STRICT, "--share-may-differ", "0.5"] => /--share-may-differ.*--sound/,
        %w[--heard-above 0] => /--heard-above.*--sound/,
        [*STRICT, "--level-share-apart", "3"] => /--level-share-apart/,
        [*STRICT, "--hearing", "square1"] => /--hearing needs two/,
      }.each do |wrong, says|
        out, status = cli("compare", "tune.gba", "quiet.gba", "--script", "listen.rb", *wrong, dir: dir)

        assert_equal NOT_COMPARED, status.exitstatus, "#{wrong.join(' ')}: #{out}"
        assert_match(says, out)
        refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
      end
    end
  end

  # --hearing chooses each side's voices, comma between voices and a space between the sides.
  def test_hearing_chooses_the_voices_heard_on_each_side
    with_tunes do |dir|
      out, status = cli("compare", "tune.gba", "quiet.gba", "--script", "listen.rb", *STRICT, "--hearing", "square1",
                        "square1,square2", dir: dir)

      assert_equal DIFFERED, status.exitstatus, out
      assert_match(/Heard alone: the square1 voice on the first cartridge and the square1 and square2 voices on the second/, out)
    end
  end

  # The tune's tape, recorded once from the script, for the flags a playthrough cannot take.
  private def tape(dir)
    path = File.join(dir, "listen.tape")
    cli("run", "tune.rb", "--script", "listen.rb", "--write-tape", "listen.tape", dir: dir) unless File.exist?(path)
    "listen.tape"
  end
end
