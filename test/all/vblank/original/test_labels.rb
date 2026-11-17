# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/original/labels"

# A port reads the original's labels (where each routine, table and variable is) from a file of
# VBlank's own, written once from the assembler's symbol file. These labels are made up: a cartridge
# of 16 KB banks, three ROM labels and three variables.
class TestLabels < Minitest::Test
  Label = VBlank::Original::Labels::Label

  LABELS = [Label.new(name: "Start", space: :rom, address: 0x0150, offset: 0x0150),
            Label.new(name: "Music_Title", space: :rom, address: 0x4000, offset: 0x4000),
            Label.new(name: "Music_Credits", space: :rom, address: 0x4010, offset: 0x4010),
            Label.new(name: "Pictures", space: :rom, address: 0x4000, offset: 0xC000),
            Label.new(name: "wScore", space: :ram, address: 0xC000, width: 2, size: 2),
            Label.new(name: "wBallStates", space: :ram, address: 0xC002),
            Label.new(name: "wLives", space: :ram, address: 0xC006, width: 1)].freeze

  private def labels = VBlank::Original::Labels.new(LABELS, rom_bank_bytes: 0x4000)

  def test_a_name_gives_its_offset_in_the_copy_and_its_address_on_the_console
    assert_equal 0xC000, labels.offset("Pictures")
    assert_equal 0x4000, labels.address("Pictures")
    assert_equal 0xC000, labels.address("wScore")
  end

  def test_a_name_and_a_number_of_bytes_is_that_far_into_the_label
    assert_equal 0xC003, labels.address("wBallStates+1")
    assert_equal 0x4012, labels.offset("Music_Credits+2")
  end

  def test_a_variable_keeps_its_width_and_size
    score = labels.fetch("wScore")

    assert_equal :ram, score.space
    assert_equal [2, 2], [score.width, score.size]
  end

  def test_an_unknown_name_is_refused_naming_what_is_near
    error = assert_raises(VBlank::Original::UnknownLabel) { labels.address("wScroe") }

    assert_match "wScore", error.message
    assert_kind_of KeyError, error
  end

  def test_a_ram_address_is_not_a_place_in_the_copy
    assert_raises(ArgumentError) { labels.offset("wScore") }
  end

  def test_names_are_found_by_where_they_are
    assert_equal ["Music_Title"], labels.names_at(offset: 0x4000)
    assert_equal ["wLives"], labels.names_at(address: 0xC006)
    assert_equal %w[Music_Title Pictures], labels.names_at(address: 0x4000)
    assert_empty labels.names_at(offset: 0x4001)
  end

  # How many bytes a label runs: its size where the file gives one, else up to the next label, and
  # never past the end of its bank, where the next bank's bytes are something else.
  def test_a_span_runs_to_the_next_label_and_stops_at_its_bank_s_end
    assert_equal 0x10, labels.span("Music_Title")
    assert_equal 0x3FF0, labels.span("Music_Credits")
    assert_equal 2, labels.span("wScore")
    assert_equal 4, labels.span("wBallStates")
  end

  def test_the_last_label_with_no_bank_and_no_size_has_no_span
    error = assert_raises(ArgumentError) { VBlank::Original::Labels.new(LABELS).span("wLives") }

    assert_match "wLives", error.message
  end

  def test_saved_labels_read_back_the_same_one_to_a_line
    Dir.mktmpdir do |folder|
      path = File.join(folder, "labels.json")
      labels.write(path)
      text = File.read(path)
      read = VBlank::Original::Labels.read(path)

      assert_equal labels.to_a, read.to_a
      assert_equal 0x10, read.span("Music_Title")
      assert_equal 1, text.lines.count { it.include?("\"Music_Title\"") }
      assert_operator text.lines.size, :>, LABELS.size
    end
  end

  def test_a_saved_file_is_stale_once_the_labels_differ
    Dir.mktmpdir do |folder|
      path = File.join(folder, "labels.json")
      labels.write(path)
      moved = VBlank::Original::Labels.new(LABELS.map { it.name == "Start" ? it.with(address: 0x0151, offset: 0x0151) : it },
                                           rom_bank_bytes: 0x4000)

      refute labels.stale?(path)
      assert moved.stale?(path)
      assert labels.stale?(File.join(folder, "none.json"))
    end
  end

  def test_a_folder_of_saved_files_reads_as_one
    Dir.mktmpdir do |folder|
      VBlank::Original::Labels.new(LABELS.first(4), rom_bank_bytes: 0x4000).write(File.join(folder, "rom.json"))
      VBlank::Original::Labels.new(LABELS.drop(4), rom_bank_bytes: 0x4000).write(File.join(folder, "ram.json"))

      assert_equal labels.to_a.sort_by(&:name), VBlank::Original::Labels.read(folder).to_a.sort_by(&:name)
    end
  end

  def test_a_file_that_is_not_saved_labels_is_refused
    Dir.mktmpdir do |folder|
      path = File.join(folder, "labels.json")
      File.write(path, "{\"something\": 1}\n")

      assert_match "labels", assert_raises(ArgumentError) { VBlank::Original::Labels.read(path) }.message
      assert_match "no saved labels", assert_raises(ArgumentError) { VBlank::Original::Labels.read(File.join(folder, "none")) }.message
    end
  end
end
