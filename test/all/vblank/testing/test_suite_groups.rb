# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "vblank/testing/suite_groups"

# A game's tests are grouped by the folders they sit in (Testing::SuiteGroups), so a person can play
# one part of the game: each folder holding tests is a group of every test beneath it.
class TestSuiteGroups < Minitest::Test
  private def tests_in(root, *paths)
    paths.each do |path|
      FileUtils.mkdir_p(File.join(root, File.dirname(path)))
      File.write(File.join(root, path), "")
    end
  end

  private def groups(root, **how) = VBlank::Testing::SuiteGroups.new(root, **how).to_h { [it.name, it.files.map { |f| f.delete_prefix("#{root}/") }] }

  def test_each_folder_of_tests_is_a_group_of_everything_beneath_it
    Dir.mktmpdir do |root|
      tests_in(root, "enemies/test_bat.rb", "enemies/octorok/test_spit.rb", "support/test_helpers.rb", "plans/.gitkeep", "test_loose.rb")

      assert_equal({ "enemies" => %w[enemies/octorok/test_spit.rb enemies/test_bat.rb], "enemies:octorok" => %w[enemies/octorok/test_spit.rb] },
                   groups(root))
    end
  end

  def test_a_broad_group_gathers_folders_and_files
    Dir.mktmpdir do |root|
      tests_in(root, "enemies/test_bat.rb", "rooms/test_door.rb", "rooms/test_wall.rb")

      found = groups(root, broad: { "doors" => %w[enemies rooms/test_door*.rb] })

      assert_equal %w[enemies/test_bat.rb rooms/test_door.rb], found["doors"]
    end
  end

  def test_a_pattern_stays_in_its_folder_and_a_root_is_read_however_it_is_written
    Dir.mktmpdir do |root|
      tests_in(root, "rooms/test_door.rb", "rooms/inner/test_deep.rb")

      found = VBlank::Testing::SuiteGroups.new("#{root}/./", broad: { "doors" => %w[rooms/test_*.rb] }).to_h { [it.name, it.files] }

      assert_equal ["#{root}/rooms/test_door.rb"], found["doors"]
    end
  end

  def test_a_broad_entry_that_finds_no_test_is_refused
    Dir.mktmpdir do |root|
      tests_in(root, "rooms/test_door.rb")

      assert_match "gone", assert_raises(ArgumentError) { groups(root, broad: { "doors" => %w[gone] }) }.message
      assert_raises(ArgumentError) { groups(root, broad: { "rooms" => %w[rooms] }) }
    end
  end
end
