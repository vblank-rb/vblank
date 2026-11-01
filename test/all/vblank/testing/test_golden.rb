# frozen_string_literal: true

require "test_helper"

# `rake test:golden` is for the day's work, so it has to stay short: test/golden.txt names real
# files, each run's share of them is at most a tenth of that run's tests, and every run plays some.
class TestGolden < Minitest::Test
  MOST_SHARE = 0.1

  private def golden = VBlank::Testing::Lowering.golden_files(VBlank.root.join("test/golden.txt").to_s)
  private def tests_in(files) = files.sum { |file| VBlank.root.join(file).read.scan(/^\s*def test_/).size }

  def test_every_file_named_is_there
    missing = golden.reject { |file| VBlank.root.join(file).file? }

    assert_empty missing
  end

  def test_each_run_plays_some_and_at_most_a_tenth_of_its_tests
    every_file = Dir[VBlank.root.join("test/**/test_*.rb").to_s].map { |path| path.delete_prefix("#{VBlank.root}/") }
    runs = VBlank::Testing::Lowering::RUNS.map { |run| [run.name, run.console] }
    runs.each do |lowering, console|
      all = VBlank::Testing::Lowering.files_for(lowering, console: console, files: every_file, folders: TestSuites::LOWERING_FOLDERS,
                                                          console_folders: TestSuites::CONSOLE_FOLDERS)
      chosen = golden & all

      refute_empty chosen, "#{lowering} plays nothing of the golden path"
      assert_operator tests_in(chosen), :<=, tests_in(all) * MOST_SHARE, "#{lowering}: move a file out of test/golden.txt"
    end
  end
end
