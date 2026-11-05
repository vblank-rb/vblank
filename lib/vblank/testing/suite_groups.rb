# frozen_string_literal: true

require "pathname"

module VBlank
  module Testing
    # A GAME'S TESTS BY FOLDER, read off the folders they sit in. A folder under the tests' root that
    # holds tests is a group, named by its path with the slashes turned into colons, and it holds
    # every test beneath it: `enemies` is all the enemies and `enemies:bat` is one of them.
    # RakeTasks makes a task for each (`t.groups = "test"`), which lets a person play the part of the
    # game they are working on without the rest.
    #
    # Read rather than listed by hand, so a new folder is a new task and nothing can drift.
    #
    # A BROAD GROUP is a part of the game whose tests sit in several folders, which no one folder's
    # group covers: a name and a list of folders and files from the tests' root, a folder bringing
    # every test beneath it and a file allowed to be a pattern. An entry that finds no test is
    # refused, so a test moved or renamed cannot drop out of a broad group while the group goes on
    # passing; and a broad group may not take a folder's name.
    class SuiteGroups
      include Enumerable

      # The folder of helpers several groups share: not tests, so never a group.
      SUPPORT = "support"

      # A group's name and its test files, in order of path.
      Group = Data.define(:name, :files)

      # +files+ are the test files (every test_*.rb beneath +root+ unless said), as paths from the same
      # folder +root+ is named from ("./test" and "test" are one root).
      def initialize(root, files: nil, broad: {})
        @root = Pathname(root.to_s).cleanpath.to_s
        @files = (files || Dir.glob(File.join(@root, "**", "test_*.rb"))).map { Pathname(it.to_s).cleanpath.to_s }.sort
        @broad = broad
      end

      # Each folder's group in order of name, then each broad group. A folder with no tests in or
      # beneath it is left out.
      def each(&)
        return enum_for(:each) unless block_given?

        by_folder = folder_groups
        (by_folder + broad_groups(by_folder.map(&:name))).each(&)
      end

      private

      def folder_groups
        folders.map { |folder| Group.new(name: folder.tr("/", ":"), files: beneath(folder)) }
      end

      def broad_groups(names)
        @broad.map do |name, entries|
          raise ArgumentError, "The broad group #{name} has the name of a folder of tests. Give it another name." if names.include?(name.to_s)

          Group.new(name: name.to_s, files: entries.flat_map { |entry| files_of_entry(name, entry) }.uniq.sort)
        end
      end

      def files_of_entry(name, entry)
        found = beneath(entry.chomp("/"))
        found = @files.select { |file| File.fnmatch(File.join(@root, entry), file, File::FNM_PATHNAME) } if found.empty?
        raise ArgumentError, "The broad group #{name} names #{entry}, and no test is there. Correct the entry or remove it." if found.empty?

        found
      end

      def beneath(folder) = @files.select { |file| file.start_with?("#{@root}/#{folder}/") }

      # Every folder some test sits in or beneath, from the root, the support folder left out.
      def folders
        @files.flat_map do |file|
          parts = File.dirname(file.delete_prefix("#{@root}/")).split("/")
          parts.first == "." ? [] : Array.new(parts.size) { |depth| parts[0..depth].join("/") }
        end.uniq.reject { |folder| folder == SUPPORT || folder.start_with?("#{SUPPORT}/") }.sort
      end
    end
  end
end
