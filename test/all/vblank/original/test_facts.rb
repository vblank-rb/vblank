# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# What a port measured from its original lives in commented YAML files (Original::Facts): the values
# a tool reads off the copy, each key with a comment written by hand above it, and a `measured:`
# section written by hand. A tool writes new values in and every comment stays where it was.
class TestOriginalFacts < Minitest::Test
  FILE = <<~YAML
    # A header.

    # How fast.
    speed: 3

    # Gone soon.
    old: 1

    # Where.
    place: [1, 2]

    # Measured.
    measured:
      # Kept as it is.
      frames:
        value: 4
        source: probe
        test: test/test_frames.rb
  YAML

  private def facts_in(folder, files = { "ball" => FILE })
    files.each { |name, text| File.write(File.join(folder, "#{name}.yml"), text) }
    VBlank::Original::Facts.new(folder)
  end

  def test_a_fact_is_read_by_its_file_and_path
    Dir.mktmpdir do |folder|
      facts = facts_in(folder)

      assert_equal 3, facts.of(:ball, :speed)
      assert_equal 4, facts.measured(:ball, :frames)
      assert_equal({ speed: 3, old: 1, place: [1, 2] }, facts.of(:ball))
    end
  end

  def test_a_fact_that_is_not_there_is_an_error_naming_the_file
    Dir.mktmpdir do |folder|
      facts = facts_in(folder)

      assert_match "ball.yml", assert_raises(KeyError) { facts.of(:ball, :spin) }.message
      assert_match "ball", assert_raises(KeyError) { facts.of(:bat, :speed) }.message
    end
  end

  def test_files_are_found_in_each_folder_named
    Dir.mktmpdir do |folder|
      Dir.mkdir(File.join(folder, "stages"))
      File.write(File.join(folder, "stages", "stage_1.yml"), "# The first.\nbombs: 2\n")
      File.write(File.join(folder, "screens.yml"), "# The title.\ntitle: 7\n")

      facts = VBlank::Original::Facts.new(folder, File.join(folder, "stages"))

      assert_equal 2, facts.of(:stage_1, :bombs)
      assert_equal %i[screens stage_1], facts.files.sort
    end
  end

  def test_a_record_reads_as_a_data_class
    Dir.mktmpdir do |folder|
      facts = facts_in(folder, { "ball" => "# Its walls.\nwalls:\n  # Left.\n  left: 1\n  # Right.\n  right: 9\n" })
      walls = Data.define(:left, :right)

      assert_equal walls.new(left: 1, right: 9), facts.record(walls, :ball, :walls)
    end
  end

  def test_writing_new_values_keeps_every_comment_and_the_measured_section
    Dir.mktmpdir do |folder|
      facts = facts_in(folder)

      facts.write(:ball, { "speed" => 5, "place" => [1, 9], "new" => "x", "none" => nil })

      assert_equal <<~YAML, File.read(File.join(folder, "ball.yml"))
        # A header.

        # How fast.
        speed: 5

        # Where.
        place: [1, 9]

        new: x

        none: null

        # Measured.
        measured:
          # Kept as it is.
          frames:
            value: 4
            source: probe
            test: test/test_frames.rb
      YAML
    end
  end

  def test_keys_without_a_comment_are_named
    Dir.mktmpdir do |folder|
      facts = facts_in(folder, { "ball" => "# Fast.\nspeed: 3\nspin: 2\nmeasured:\n  frames:\n    value: 4\n    source: probe\n    test: x\n" })

      assert_equal %w[spin measured measured.frames], facts.uncommented(:ball)
    end
  end

  def test_hand_written_facts_need_a_comment_above_each_top_level_key_only
    Dir.mktmpdir do |folder|
      text = "# A header.\n\n# Fast. ball.c\nspeed: 0x10\nspin: 2\n# Edges. field.c\nedges:\n  left: 1\n\n\"odd key\": 3\n" \
             "measured:\n  frames:\n    value: 4\n    source: probe\n    test: x\n"
      File.write(File.join(folder, "ball.yml"), text)

      facts = VBlank::Original::Facts.new(folder, written_by: :hand)

      assert_predicate facts, :written_by_hand?
      assert_equal ["spin", "odd key"], facts.uncommented(:ball)
    end
  end

  def test_facts_are_written_by_a_tool_unless_set
    Dir.mktmpdir do |folder|
      refute_predicate facts_in(folder), :written_by_hand?
      assert_match "written_by", assert_raises(ArgumentError) { VBlank::Original::Facts.new(folder, written_by: :nobody) }.message
    end
  end

  def test_hand_written_facts_refuse_a_tool_s_write
    Dir.mktmpdir do |folder|
      File.write(File.join(folder, "ball.yml"), "# Fast.\nspeed: 0x10\n")
      facts = VBlank::Original::Facts.new(folder, written_by: :hand)

      assert_match "by hand", assert_raises(ArgumentError) { facts.write(:ball, { "speed" => 5 }) }.message
      assert_equal "# Fast.\nspeed: 0x10\n", File.read(File.join(folder, "ball.yml"))
    end
  end

  def test_a_nested_measured_fact_is_read_and_one_without_a_value_refused
    Dir.mktmpdir do |folder|
      facts = facts_in(folder, { "field" => "# Cuts.\nmeasured:\n  # The cut.\n  cut:\n    # White.\n    white_frame:\n      value: 6\n" \
                                            "      source: probe\n      test: x\n    # Half done.\n    black_frame:\n      source: probe\n" })

      assert_equal 6, facts.measured(:field, :cut, :white_frame)
      assert_raises(KeyError) { facts.measured(:field, :cut, :black_frame) }
      assert_equal %w[cut.white_frame cut.black_frame], facts.measured_entries(:field).keys
    end
  end

  def test_a_file_with_an_empty_measured_section_has_no_entries
    Dir.mktmpdir do |folder|
      assert_empty facts_in(folder, { "ball" => "# Fast.\nspeed: 3\n\n# None yet.\nmeasured:\n" }).measured_entries(:ball)
    end
  end

  def test_records_and_list_items_are_read
    Dir.mktmpdir do |folder|
      facts = facts_in(folder, { "ball" => "# Walls.\nwalls:\n  - left: 1\n    right: 9\n  - left: 2\n    right: 8\n" })
      wall = Data.define(:left, :right)

      assert_equal [wall.new(left: 1, right: 9), wall.new(left: 2, right: 8)], facts.records(wall, :ball, :walls)
      assert_equal 8, facts.of(:ball, :walls, 1, :right)
    end
  end

  def test_a_name_in_two_folders_is_refused
    Dir.mktmpdir do |folder|
      %w[one two].each do |inner|
        Dir.mkdir(File.join(folder, inner))
        File.write(File.join(folder, inner, "ball.yml"), "# Fast.\nspeed: 3\n")
      end

      assert_match "ball.yml", assert_raises(ArgumentError) { VBlank::Original::Facts.new(File.join(folder, "one"), File.join(folder, "two")) }.message
    end
  end

  def test_a_facts_can_be_shared_with_every_ractor
    Dir.mktmpdir { |folder| assert Ractor.shareable?(facts_in(folder)) }
  end

  def test_a_new_file_is_written_into_the_folder_named
    Dir.mktmpdir do |folder|
      facts = facts_in(folder)

      facts.write(:stage_1, { "bombs" => 2 }, folder: File.join(folder, "stages"))

      assert_equal "bombs: 2\n", File.read(File.join(folder, "stages", "stage_1.yml"))
    end
  end

  def test_what_is_written_reads_back_the_same
    Dir.mktmpdir do |folder|
      facts = facts_in(folder, { "ball" => "" })
      values = { "text" => 'a #{b} "c" \e', "yes" => "no", "Label_One" => [{ "x" => 1, "y" => nil }], "list" => [[1, 2], "three"] }

      facts.write(:ball, values)

      assert_equal values, YAML.safe_load_file(File.join(folder, "ball.yml"))
      assert VBlank::Original::Facts.new(folder).kept?(:ball)
    end
  end

  def test_a_file_that_is_as_the_tool_writes_it_is_kept
    Dir.mktmpdir do |folder|
      facts = facts_in(folder, { "ball" => FILE, "loose" => "# Fast.\nspeed:   3\n" })

      assert facts.kept?(:ball)
      refute facts.kept?(:loose)
    end
  end
end
