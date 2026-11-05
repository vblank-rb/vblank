# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/original/data_guard_tasks"

# A port installs its data guard with one rake task, which makes the repository's pre-commit hook
# run the check, and keeps whatever else that hook already does.
class TestDataGuardTasks < Minitest::Test
  # Every test starts git, a child process, and defines rake tasks, which the whole process shares.
  runs_on_the_main_ractor!

  LINE = VBlank::Original::DataGuardTasks::HOOK_LINE

  private def tasks
    Rake.application = Rake::Application.new
    VBlank::Original::DataGuardTasks.new { |t| t.consoles = %i[gbc] }
  end

  private def git(folder, *arguments) = system("git", "-C", folder, *arguments, exception: true, out: File::NULL, err: File::NULL)

  private def repository(folder)
    git(folder, "init", "--quiet")
    folder
  end

  private def stage(folder, name, bytes = "bytes")
    File.write(File.join(folder, name), bytes)
    git(folder, "add", name)
  end

  private def hook_after_install(folder, text)
    FileUtils.mkdir_p(File.join(folder, ".githooks"))
    File.write(File.join(folder, ".githooks", "pre-commit"), text)
    File.read(tasks.install(folder))
  end

  def test_install_writes_a_hook_and_points_git_at_its_folder
    Dir.mktmpdir do |folder|
      hook = tasks.install(repository(folder))

      assert_match LINE, File.read(hook)
      assert File.executable?(hook)
      assert_equal ".githooks\n", IO.popen(["git", "-C", folder, "config", "core.hooksPath"], &:read)
    end
  end

  def test_install_keeps_a_hook_the_game_has_and_adds_the_check_once
    Dir.mktmpdir do |folder|
      repository(folder)
      hook_after_install(folder, "#!/bin/sh\necho the game's own check\n")

      assert_equal "#!/bin/sh\n#{LINE}\necho the game's own check\n", File.read(tasks.install(folder))
    end
  end

  def test_install_starts_a_hook_with_no_first_line_of_its_own
    Dir.mktmpdir do |folder|
      repository(folder)

      assert_equal "#!/bin/sh\n#{LINE}\necho mine\n", hook_after_install(folder, "echo mine\n")
      assert_match "#!/bin/sh", hook_after_install(folder, "")
    end
  end

  def test_install_refuses_a_repository_whose_hooks_are_elsewhere
    Dir.mktmpdir do |folder|
      git(repository(folder), "config", "core.hooksPath", ".husky")

      assert_match ".husky", assert_raises(ArgumentError) { tasks.install(folder) }.message
    end
  end

  def test_a_staged_cartridge_is_refused_saying_which
    Dir.mktmpdir do |folder|
      stage(repository(folder), "game.gbc")

      assert_match "game.gbc", tasks.staged_refusals(folder, env: {}).join
    end
  end

  def test_ordinary_files_and_a_skip_pass
    Dir.mktmpdir do |folder|
      stage(repository(folder), "game.rb")

      assert_empty tasks.staged_refusals(folder, env: {})
      stage(folder, "game.gbc")
      assert_empty tasks.staged_refusals(folder, env: { "SKIP_GAME_DATA_CHECK" => "1" })
    end
  end
end
