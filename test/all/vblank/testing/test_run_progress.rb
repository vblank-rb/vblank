# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# What a stopped `rake test:all` keeps, and what a change since then undoes. test_game_suite.rb stops
# and resumes a real run; here a small project on disk stands in for one, to say which file undoes what.
class TestRunProgress < Minitest::Test
  # Dir.glob and git need the process's working folder and child processes.
  runs_on_the_main_ractor!

  Progress = VBlank::Testing::RunProgress
  PLAYS = [%i[gba gba], %i[native gba], %i[native gbc], %i[js gba], %i[gbc gbc]].freeze
  LOWERING_FOLDERS = { gba: ["test/lowering/gba"], native: ["test/lowering/native"] }.freeze
  CONSOLE_FOLDERS = { gbc: ["test/console/gbc"] }.freeze
  FILES = ["lib/vblank/dsl/value.rb", "lib/vblank/ir/backends/gbc/lowering.rb", "lib/vblank/ir/backends/native/c.rb",
           "test/all/test_walker.rb", "test/lowering/gba/support.rb", "test/console/gbc/support.rb", "NOTES.md"].freeze

  private def in_project
    Dir.mktmpdir do |root|
      FILES.each { |path| write(root, path, "one") }
      yield root
    end
  end

  private def write(root, path, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  private def progress_in(root)
    Progress.new(PLAYS, root: root, lowering_folders: LOWERING_FOLDERS, console_folders: CONSOLE_FOLDERS)
  end

  # A project whose every run finished, with the first left with one test passed and one failed.
  private def finished_project(root)
    progress = progress_in(root)
    progress.start
    PLAYS.each { |lowering, console| progress.mark_finished(lowering, console) }
    progress
  end

  private def still_to_play(progress) = PLAYS.reject { |lowering, console| progress.left_in(lowering, console).nil? }

  def test_nothing_changed_keeps_every_run
    in_project do |root|
      assert_empty finished_project(root).apply_changes
      assert_empty still_to_play(progress_in(root))
    end
  end

  def test_a_document_changes_nothing
    in_project do |root|
      progress = finished_project(root)
      write(root, "NOTES.md", "two")

      assert_empty progress.apply_changes
      assert_empty still_to_play(progress)
    end
  end

  def test_what_every_run_reads_starts_again_and_says_which_file
    in_project do |root|
      progress = finished_project(root)
      write(root, "lib/vblank/dsl/value.rb", "two")

      assert_match(%r{lib/vblank/dsl/value\.rb}, progress.apply_changes.join)
      assert_equal PLAYS, still_to_play(progress)
    end
  end

  def test_a_lowerings_own_code_redoes_its_run_alone
    in_project do |root|
      progress = finished_project(root)
      write(root, "lib/vblank/ir/backends/gbc/lowering.rb", "two")
      progress.apply_changes

      assert_equal [%i[gbc gbc]], still_to_play(progress)
    end
  end

  # The other runs are built over what the native lowering writes.
  def test_the_native_lowerings_code_redoes_every_run_that_builds_the_game
    in_project do |root|
      progress = finished_project(root)
      write(root, "lib/vblank/ir/backends/native/c.rb", "two")
      progress.apply_changes

      assert_equal PLAYS - [%i[gba gba]], still_to_play(progress)
    end
  end

  def test_a_helper_in_a_lowerings_folder_redoes_its_runs
    in_project do |root|
      progress = finished_project(root)
      write(root, "test/lowering/gba/support.rb", "two")
      progress.apply_changes

      assert_equal [%i[gba gba]], still_to_play(progress)
    end
  end

  def test_a_helper_in_a_consoles_folder_redoes_the_runs_of_that_console
    in_project do |root|
      progress = finished_project(root)
      write(root, "test/console/gbc/support.rb", "two")
      progress.apply_changes

      assert_equal [%i[native gbc], %i[gbc gbc]], still_to_play(progress)
    end
  end

  def test_a_changed_test_file_is_all_a_finished_run_plays_again
    in_project do |root|
      progress = finished_project(root)
      write(root, "test/all/test_walker.rb", "two")
      progress.apply_changes

      assert_equal PLAYS, still_to_play(progress)
      assert_equal ["test/all/test_walker.rb"], progress.left_in(:js, :gba).only
    end
  end

  def test_the_test_helper_is_read_by_every_test
    in_project do |root|
      write(root, "test/test_helper.rb", "one")
      progress = finished_project(root)
      write(root, "test/test_helper.rb", "two")
      progress.apply_changes

      assert_equal PLAYS, still_to_play(progress)
      assert_nil progress.left_in(:js, :gba).only
    end
  end

  def test_a_record_names_its_seed_and_the_failed_test
    in_project do |root|
      progress = finished_project(root)
      File.write(File.join(root, Progress::FOLDER, "js-gba.tests"), "seed 42\nfailed test/a.rb\tTestA#test_it\n")
      progress.apply_changes
      write(root, "test/all/test_walker.rb", "two")
      progress.apply_changes
      left = progress.left_in(:js, :gba)

      assert_equal 42, left.seed
      assert_equal "test/a.rb\tTestA#test_it", left.failed
    end
  end

  def test_a_failed_test_that_passed_since_is_no_longer_failed
    in_project do |root|
      progress = progress_in(root)
      progress.start
      File.write(File.join(root, Progress::FOLDER, "js-gba.tests"),
                 "seed 42\nfailed test/a.rb\tTestA#test_it\npassed test/a.rb\tTestA#test_it\n")

      assert_nil progress.left_in(:js, :gba).failed
    end
  end

  # A run that failed with no test named has nothing to pick up from.
  def test_a_run_that_failed_with_no_test_named_plays_again_from_the_start
    in_project do |root|
      progress = progress_in(root)
      progress.start
      File.write(File.join(root, Progress::FOLDER, "js-gba.tests"), "seed 42\npassed test/a.rb\tTestA#test_it\n")
      progress.mark_failed(:js, :gba)

      assert_nil progress.left_in(:js, :gba).seed
    end
  end

  def test_the_record_tells_git_to_leave_it_alone
    in_project do |root|
      progress_in(root).start

      assert_equal "*\n", File.read(File.join(root, Progress::FOLDER, ".gitignore"))
    end
  end
end
