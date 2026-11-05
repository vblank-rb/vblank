# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A port's suite holds its facts files to their three rules with one assertion,
# `assert_facts_kept`: each file is as its tool writes it, every key has a comment, and every
# measured fact names its source and a test that is there.
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

  private def facts_in(root, text)
    Dir.mkdir(File.join(root, "facts"))
    Dir.mkdir(File.join(root, "test"))
    File.write(File.join(root, "test", "test_frames.rb"), "")
    File.write(File.join(root, "facts", "ball.yml"), text)
    VBlank::Original::Facts.new(File.join(root, "facts"))
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
