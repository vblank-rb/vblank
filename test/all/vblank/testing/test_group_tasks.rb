# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "vblank/testing/group_tasks"

# A game that keeps its own test tasks gets a task for each folder of its tests from GroupTasks, on
# the lowerings it names: the first under the prefix, each other under its own name.
class TestGroupTasks < Minitest::Test
  # It defines rake tasks, which the whole process shares.
  runs_on_the_main_ractor!

  def test_each_folder_has_a_task_on_each_lowering
    Dir.mktmpdir do |root|
      %w[enemies/test_bat.rb enemies/bat/test_swoop.rb rooms/test_door.rb].each do |path|
        FileUtils.mkdir_p(File.join(root, File.dirname(path)))
        File.write(File.join(root, path), "")
      end
      Rake.application = Rake::Application.new

      tasks = VBlank::Testing::GroupTasks.new(root: root, prefix: "rocket:test", lowerings: %i[gba native]) { |t| t.libs = %w[lib] }

      assert_equal %w[rocket:test:enemies rocket:test:enemies:bat rocket:test:rooms
                      rocket:test:native:enemies rocket:test:native:enemies:bat rocket:test:native:rooms], tasks.task_names
      assert(tasks.task_names.all? { Rake::Task.task_defined?(it) })
    end
  end
end
