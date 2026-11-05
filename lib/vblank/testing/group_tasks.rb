# frozen_string_literal: true

require "rake"
require "rake/tasklib"
require_relative "suite_groups"
require_relative "test_task"

module VBlank
  module Testing
    # A TEST TASK FOR EACH FOLDER OF A GAME'S TESTS, for a game that keeps its own test tasks rather
    # than RakeTasks (whose `t.groups` plays each group on every lowering). In the game's Rakefile:
    #
    #   require "vblank/testing/group_tasks"
    #
    #   VBlank::Testing::GroupTasks.new(root: "games/rocket/test", prefix: "rocket:test", lowerings: %i[gba native]) do |t|
    #     t.libs = %w[lib games/rocket/lib games/rocket/test]
    #   end
    #
    # That makes `rake rocket:test:enemies` for the tests beneath games/rocket/test/enemies/, played on
    # the GBA lowering (the interpreter), and `rake rocket:test:native:enemies` for the same tests
    # built as C, one task for each group (SuiteGroups) and each lowering after the first. The block
    # is handed each TestTask, to set what any test task takes. +broad+ is SuiteGroups' broad groups.
    #
    # Every test beneath a folder is in its group, whether or not the game's whole run plays it, so a
    # folder of tests the whole run leaves out is played by its group's task.
    class GroupTasks < Rake::TaskLib
      def initialize(root:, prefix:, lowerings: %i[gba], broad: {}, &configure)
        super()
        @groups = SuiteGroups.new(root, broad: broad).to_a
        @prefix = prefix
        @lowerings = lowerings
        @configure = configure
        @lowerings.each { |lowering| define_group_tasks(lowering) }
      end

      # The tasks' names, as rake is asked for them.
      def task_names = @lowerings.flat_map { |lowering| @groups.map { |group| task_name(lowering, group) } }

      private

      def task_name(lowering, group)
        lowering == @lowerings.first ? "#{@prefix}:#{group.name}" : "#{@prefix}:#{lowering}:#{group.name}"
      end

      def define_group_tasks(lowering)
        @groups.each do |group|
          TestTask.new(task_name(lowering, group)) do |t|
            t.lowering = lowering
            t.test_files = group.files
            t.description = "Run the tests of #{group.name.tr(':', '/')} on the #{Lowering.run_named(lowering).title} lowering"
            @configure&.call(t)
          end
        end
      end
    end
  end
end
