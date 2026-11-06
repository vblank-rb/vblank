# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/testing/golden_task"

# A game that keeps its own test tasks gets `rake test:golden` from GoldenTask: the files its list
# names, read from the game's folder, and a draw of the game's other test files.
class TestGoldenTask < Minitest::Test
  # It defines rake tasks, which the whole process shares.
  runs_on_the_main_ractor!

  def test_the_list_is_read_from_the_game_s_folder
    Dir.mktmpdir do |folder|
      list = File.join(folder, "golden.txt")
      File.write(list, "# the core of each part\ntest/test_ship.rb\n\ntest/test_door.rb\n")
      Rake.application = Rake::Application.new

      golden = VBlank::Testing::GoldenTask.new(list: list, from: "games/rocket") { |t| t.libs = %w[lib] }

      assert_equal %w[games/rocket/test/test_ship.rb games/rocket/test/test_door.rb], golden.files
      assert Rake::Task.task_defined?("test:golden")
    end
  end

  def test_the_draw_is_from_the_test_files_beside_the_list
    Dir.mktmpdir do |folder|
      list = File.join(folder, "golden.txt")
      File.write(list, "test_ship.rb\n")
      %w[test_ship.rb door_test.rb helper.rb].each { |file| File.write(File.join(folder, file), "") }
      Rake.application = Rake::Application.new

      golden = VBlank::Testing::GoldenTask.new(list: list)

      assert_equal %w[door_test.rb test_ship.rb].map { |file| File.join(folder, file) }, golden.test_files.sort
    end
  end

  def test_a_clone_without_the_list_still_has_its_tasks
    Dir.mktmpdir do |folder|
      Rake.application = Rake::Application.new

      VBlank::Testing::GoldenTask.new(list: File.join(folder, "missing.txt"))

      assert Rake::Task.task_defined?("test:golden")
    end
  end
end
