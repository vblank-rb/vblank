# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A port's suite holds its facts files to their three rules with one assertion,
# `assert_facts_kept`: each file is as its tool writes it, every key has a comment, and every
# measured fact names its source and a test that is there. A port whose facts a person writes
# (`written_by: :hand`) is held to the rules that fit: no layout, a comment above every top-level
# key, and the same of every measured fact.
class TestFactsKept < Minitest::Test
  include VBlank::Testing

  KEPT = <<~YAML
    # The ball.

    # How fast.
    speed: 3

    # Measured.
    measured:
      # The frames.
      frames:
        value: 4
        source: probe
        test: test/test_frames.rb
  YAML

  # A file a person wrote from reading the original's source: numbers in the base the source writes
  # them in, a list down the page, a mapping whose one comment covers its keys, and a measured
  # section under a bare key.
  HAND_WRITTEN = <<~YAML
    # The ball. Read from ball.c.

    # The bits of a flag byte that are the spin. ball.c, spin_of
    spin_mask: 0x7f

    # Where each bounce is decided. ball.c
    readers:
    - wall.c reads the low bit
    - bat.c reads the whole byte

    # The field's edges, in pixels. field.c, field_edges
    edges:
      left: 0x10
      right: 224
      rows:
        top: 8

    measured:
      frames:
        value: 4
        source: the original, counted on a film of it
        test: test/test_frames.rb
  YAML

  private def facts_in(root, text, **settings)
    Dir.mkdir(File.join(root, "facts"))
    Dir.mkdir(File.join(root, "test"))
    File.write(File.join(root, "test", "test_frames.rb"), "")
    File.write(File.join(root, "facts", "ball.yml"), text)
    VBlank::Original::Facts.new(File.join(root, "facts"), **settings)
  end

  private def hand_written_failure(text)
    Dir.mktmpdir do |root|
      assert_raises(Minitest::Assertion) { assert_facts_kept(facts_in(root, text, written_by: :hand), root: root) }.message
    end
  end

  def test_hand_written_files_pass_with_their_numbers_and_lists_as_written
    Dir.mktmpdir do |root|
      facts = facts_in(root, HAND_WRITTEN, written_by: :hand)

      assert_facts_kept(facts, root: root)
      assert_equal 0x7f, facts.of(:ball, :spin_mask)
      assert_equal HAND_WRITTEN, File.read(facts.path(:ball))
    end
  end

  def test_the_same_files_fail_the_check_for_a_tool
    Dir.mktmpdir do |root|
      failure = assert_raises(Minitest::Assertion) { assert_facts_kept(facts_in(root, HAND_WRITTEN), root: root) }

      assert_match "not laid out as its tool writes it", failure.message
    end
  end

  def test_a_hand_written_top_level_key_without_a_comment_fails
    message = hand_written_failure(HAND_WRITTEN.sub("# The field's edges, in pixels. field.c, field_edges\n", ""))

    assert_match "ball.yml", message
    assert_match "edges", message
    refute_match "spin_mask", message
  end

  def test_a_comment_with_a_blank_line_below_it_is_not_its_key_s_comment
    message = hand_written_failure(HAND_WRITTEN.sub("spin_of\n", "spin_of\n\n"))

    assert_match "spin_mask", message
  end

  def test_a_hand_written_measured_fact_without_its_source_fails
    message = hand_written_failure(HAND_WRITTEN.sub("    source: the original, counted on a film of it\n", ""))

    assert_match "frames", message
    assert_match "no source", message
    assert_match "no source", hand_written_failure(HAND_WRITTEN.sub("source: the original, counted on a film of it", "source:"))
  end

  def test_a_hand_written_measured_fact_naming_no_test_that_is_there_fails
    message = hand_written_failure(HAND_WRITTEN.sub("test_frames", "test_gone"))

    assert_match "frames", message
    assert_match "test/test_gone.rb", message
  end

  def test_every_mistake_in_hand_written_files_is_named_at_once
    message = hand_written_failure(HAND_WRITTEN.sub("# Where each bounce is decided. ball.c\n", "").sub("test_frames", "test_gone"))

    assert_match "readers", message
    assert_match "test_gone", message
  end

  def test_a_file_just_written_is_kept
    Dir.mktmpdir do |root|
      facts = facts_in(root, KEPT)
      facts.write(:ball, { "speed" => 4 })

      assert_facts_kept(facts, root: root)
    end
  end

  def test_kept_files_pass
    Dir.mktmpdir { |root| assert_facts_kept(facts_in(root, KEPT), root: root) }
  end

  def test_a_key_without_a_comment_fails
    Dir.mktmpdir do |root|
      failure = assert_raises(Minitest::Assertion) { assert_facts_kept(facts_in(root, KEPT.sub("# How fast.\n", "")), root: root) }

      assert_match "speed", failure.message
    end
  end

  def test_a_file_edited_out_of_its_layout_fails
    Dir.mktmpdir do |root|
      failure = assert_raises(Minitest::Assertion) { assert_facts_kept(facts_in(root, KEPT.sub("speed: 3", "speed:   3")), root: root) }

      assert_match "ball.yml", failure.message
    end
  end

  def test_a_measured_fact_naming_no_test_that_is_there_fails
    Dir.mktmpdir do |root|
      failure = assert_raises(Minitest::Assertion) { assert_facts_kept(facts_in(root, KEPT.sub("test_frames", "test_gone")), root: root) }

      assert_match "test_gone", failure.message
    end
  end

  def test_a_measured_fact_without_its_source_fails
    Dir.mktmpdir do |root|
      failure = assert_raises(Minitest::Assertion) { assert_facts_kept(facts_in(root, KEPT.sub("    source: probe\n", "")), root: root) }

      assert_match "frames", failure.message
    end
  end
end
