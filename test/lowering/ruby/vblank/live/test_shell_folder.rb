# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "vblank/live"
require "folder_original"

# A SHELL OF A PORT WHOSE ORIGINAL IS A FOLDER OF FILES (FolderOriginal's fixture), played as Ruby.
# LOAD ROM takes the folder, finds each file the release names in any case, checks each by its size
# and SHA-1, and leaves the other files in it alone. The answer key is the all-in-one build from the
# same folder: the check every port runs (Live::ShellCheck) holds the kept pack and the play to it.
class TestShellFolder < Minitest::Test
  include FolderOriginal

  Headless = VBlank::Live::Headless

  private def shell = VBlank::Live::Shell.from(VBlank::Original::Shell.build(folder_port(folder_original(nil)), err: nil))

  # The shell started once with LOAD ROM picking +picked+: the words of each refusal.
  private def refusals_picking(picked)
    refusals = []
    Dir.mktmpdir do |kept|
      shell.play(Headless.new(frames: 400, buttons: { 2 => [:a] }), folder_path: kept, choose_copy: -> { picked },
                                                                     refused: ->(words) { refusals << words },
                                                                     play_game: ->(_game) {})
    end
    refusals
  end

  def test_the_shell_of_a_folder_port_plays_as_its_all_in_one_build
    said = []
    VBlank::Live::ShellCheck.new(folder_port(folder_original), say: ->(line) { said << line }).run

    assert_match "plays as its all-in-one build does", said.last
  end

  def test_load_rom_asks_for_a_folder
    assert_predicate shell, :copy_is_folder?
  end

  def test_a_folder_without_a_file_of_the_release_is_refused_naming_it
    Dir.mktmpdir do |dir|
      copy = fixture_copy_in(dir)
      File.delete(File.join(copy, "INDEX.MU1"))

      assert_match "lacks INDEX.MU1", refusals_picking(copy).first
    end
  end

  def test_a_changed_file_is_refused_naming_it
    Dir.mktmpdir do |dir|
      copy = fixture_copy_in(dir)
      File.binwrite(File.join(copy, "INDEX.MU1"), "MUIX".b + ("\x00".b * 14))

      assert_match "INDEX.MU1 is not the file of the MU1 release", refusals_picking(copy).first
    end
  end

  def test_one_file_picked_is_refused
    assert_match "is one file. A copy of Folder Game is a folder", refusals_picking(File.join(FOLDER, "data.mu1")).first
  end
end
