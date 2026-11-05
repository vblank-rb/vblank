# frozen_string_literal: true

require "test_helper"
require "vblank/testing/ractor_settings"

# A game's Rakefile plays its suite in Ractors with one line, RactorSettings.apply: --ractor goes
# into TESTOPTS itself, since rake reads TESTOPTS in place of a task's own options, and the run
# takes half the machine's cores unless told how many.
class TestRactorSettings < Minitest::Test
  private def applied(env, **how)
    env.dup.tap { |settings| VBlank::Testing::RactorSettings.apply(settings, **how) }
  end

  def test_ractors_are_asked_for_in_the_test_options
    assert_equal "--ractor", applied({})["TESTOPTS"]
    assert_equal "--ractor --name=/door/", applied({ "TESTOPTS" => "--name=/door/" })["TESTOPTS"]
  end

  def test_options_that_say_either_way_are_kept
    assert_equal "--no-ractor -v", applied({ "TESTOPTS" => "--no-ractor -v" })["TESTOPTS"]
    assert_equal "-v --ractor", applied({ "TESTOPTS" => "-v --ractor" })["TESTOPTS"]
  end

  def test_a_pattern_that_says_ractor_is_not_the_flag
    assert_equal "--ractor --name=/--ractor-ish/", applied({ "TESTOPTS" => "--name=/--ractor-ish/" })["TESTOPTS"]
  end

  def test_the_workers_are_half_the_cores_unless_said
    assert_equal VBlank::Testing::RactorSettings.default_workers.to_s, applied({})["MT_RACTOR_WORKERS"]
    assert_equal "3", applied({ "MT_RACTOR_WORKERS" => "3" })["MT_RACTOR_WORKERS"]
  end

  def test_the_heap_settings_are_given_where_the_shell_gives_none
    settings = applied({ "RUBY_GC_MALLOC_LIMIT" => "1" }, roomy_heap: true)

    assert_equal "1", settings["RUBY_GC_MALLOC_LIMIT"]
    assert settings.key?("RUBY_GC_HEAP_0_INIT_SLOTS")
    refute applied({}).key?("RUBY_GC_HEAP_0_INIT_SLOTS")
  end
end
