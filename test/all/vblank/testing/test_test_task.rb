# frozen_string_literal: true

require "test_helper"
require "vblank/testing/test_task"

# What a game's Rakefile is told when it asks a test task for something it cannot be. Each case
# makes its task in a rake application of its own, so nothing reaches any other.
class TestTestTask < Minitest::Test
  # Rake keeps the application tasks are defined in as one value for the whole process, and a
  # case here puts its own in place for a moment; the YJIT cases also change the process's
  # environment and start a run of their own. So on the main Ractor, not in the pool.
  runs_on_the_main_ractor!

  TestTask = VBlank::Testing::TestTask

  private def made_alone(&)
    task = nil
    Rake.with_application(Rake::Application.new) { task = TestTask.new(:walking, &) }
    task
  end

  def test_a_lowering_there_is_not_is_refused_naming_the_ones_there_are
    error = assert_raises(ArgumentError) { made_alone { |t| t.lowering = "native" } }

    assert_match(/was given "native"/, error.message)
    assert_match(/:gba, :native, :js, :ruby, :gbc, :snes, :genesis or :ps1/, error.message)
  end

  # The process runner is loaded into a native run as the task is made, so a lowering said
  # afterwards would make a run that is neither.
  def test_a_lowering_said_after_the_task_is_made_is_refused
    task = made_alone { |t| t.test_files = [] }

    error = assert_raises(ArgumentError) { task.lowering = :native }

    assert_match(/inside the block/, error.message)
  end

  def test_a_task_is_for_the_gba_lowering_unless_told
    assert_equal :gba, made_alone { |t| t.test_files = [] }.lowering
  end

  # YJIT slows a run in Ractors down rather than speeding it up, so such a run is played without
  # it even when the Ruby options ask for it.
  def test_a_run_in_ractors_is_played_without_yjit_even_when_asked_for
    assert_equal "false", yjit_enabled_in_run(:gba, test_options: "--ractor", ruby_options: "--yjit")
  end

  def test_a_gba_run_without_ractors_is_played_with_yjit
    assert_equal "true", yjit_enabled_in_run(:gba, test_options: nil)
  end

  def test_a_run_yjit_speeds_up_is_played_with_it
    assert_equal "true", yjit_enabled_in_run(:js, test_options: nil)
  end

  def test_a_run_yjit_slows_down_is_played_without_it
    assert_equal "false", yjit_enabled_in_run(:gbc, test_options: nil, ruby_options: "--yjit")
  end

  # A run whose record plays it in Ractors, started without --ractor (a suite that never applies
  # RactorSettings, or TESTOPTS=--no-ractor), is spread over processes rather than played in one.
  def test_a_ractor_run_started_without_ractor_is_played_in_processes
    played = record_from_run(:snes, test_options: nil) do |record|
      "File.write(#{record.inspect}, defined?(VBlank::Testing::Processes).inspect)\n"
    end

    assert_equal '"constant"', played
  end

  def test_a_ractor_run_started_with_ractor_is_not_played_in_processes
    played = record_from_run(:snes, test_options: "--ractor") do |record|
      "File.write(#{record.inspect}, defined?(VBlank::Testing::Processes).inspect)\n"
    end

    assert_equal "nil", played
  end

  # The GBA run plays the interpreter alone, and outside Ractors it is plain minitest in one
  # process, as it was before any run could choose: --no-ractor is how one failure is chased.
  def test_a_gba_run_started_without_ractor_is_played_in_one_process
    played = record_from_run(:gba, test_options: nil) do |record|
      "File.write(#{record.inspect}, defined?(VBlank::Testing::Processes).inspect)\n"
    end

    assert_equal "nil", played
  end

  # Every Ractor shares one heap, so a run in Ractors whose record asks for it is handed the roomy
  # heap, and no other run is.
  def test_a_run_in_ractors_that_asks_for_the_roomy_heap_is_given_it
    assert_equal "4000000", heap_slots_in_run(:snes, test_options: "--ractor")
  end

  def test_a_run_that_does_not_ask_for_the_roomy_heap_keeps_the_default
    assert_equal "", heap_slots_in_run(:gba, test_options: "--ractor")
  end

  # A Ruby started with -w prints each RUBY_GC_ setting as it boots, so a run handed the roomy heap
  # turns its warnings on after the boot: on all the same, and nothing printed.
  def test_a_run_given_the_roomy_heap_warns_and_prints_no_heap_settings
    err = nil
    warns = nil
    with_environment("RUBY_GC_HEAP_0_INIT_SLOTS" => nil) do
      _out, err = capture_subprocess_io do
        warns = record_from_run(:snes, test_options: "--ractor") do |record|
          "File.write(#{record.inspect}, [$VERBOSE, Warning[:deprecated]].inspect)\n"
        end
      end
    end

    assert_equal "[true, true]", warns
    refute_match(/RUBY_GC_/, err)
  end

  # A checked run's processes, the one rake starts and the ones it plays its tests in, require
  # the process runner, which requires minitest, from Ruby's command line. Ruby 4.1 no longer
  # sets bundler up while RubyGems loads, so that line runs before RUBYOPT's bundler/setup, and
  # minitest would be the newest one installed, not the Gemfile's: bundler then stops the
  # process before a test plays. The probe is a test, so it is played in one of those processes.
  # It can only fail where a minitest newer than the Gemfile's is installed, as Ruby 4.1 brings.
  def test_a_checked_run_plays_with_the_minitest_this_process_has
    written = record_from_run(:js, test_options: nil) do |record|
      <<~RUBY
        require "minitest/autorun"
        class TestProbe < Minitest::Test
          def test_minitest_version = File.write(#{record.inspect}, Gem.loaded_specs["minitest"].version.to_s)
        end
      RUBY
    end

    assert_equal Gem.loaded_specs["minitest"].version.to_s, written
  end

  # A game that holds its cartridge to something other than the interpreter, the retail original
  # it ports, says so in its run's heading.
  def test_a_run_given_a_heading_prints_it
    heading = heading_of_run { |t| t.heading = "the game held to the retail original" }

    assert_match(/GBA lowering: the game held to the retail original$/, heading)
  end

  def test_a_run_given_no_heading_prints_what_its_lowering_does
    assert_match(/GBA lowering: the game on the interpreter$/, heading_of_run { nil })
  end

  # What a run over one empty file prints before its tests, the block setting up its task.
  private def heading_of_run
    Dir.mktmpdir do |dir|
      probe = File.join(dir, "probe.rb")
      File.write(probe, "")
      out, = capture_io do
        with_environment("TEST" => nil, "TESTOPTS" => nil) do
          Rake.with_application(Rake::Application.new) do
            TestTask.new(:walking) do |t|
              t.test_files = [probe]
              yield t
            end
            Rake::Task[:walking].invoke
          end
        end
      end
      out
    end
  end

  private def yjit_enabled_in_run(lowering, test_options:, ruby_options: nil)
    record_from_run(lowering, test_options: test_options, ruby_options: ruby_options) do |record|
      "File.write(#{record.inspect}, RubyVM::YJIT.enabled?.to_s)\n"
    end
  end

  private def heap_slots_in_run(lowering, test_options:)
    with_environment("RUBY_GC_HEAP_0_INIT_SLOTS" => nil) do
      record_from_run(lowering, test_options: test_options) do |record|
        "File.write(#{record.inspect}, ENV.fetch('RUBY_GC_HEAP_0_INIT_SLOTS', ''))\n"
      end
    end
  end

  # Plays a run of +lowering+ over one file, the source the block gives for the path it is handed,
  # which writes down something about the Ruby playing it at that path, and returns what it wrote.
  # +ruby_options+ stands for whatever YJIT switch the caller's RUBYOPT has.
  private def record_from_run(lowering, test_options:, ruby_options: nil)
    Dir.mktmpdir do |dir|
      record = File.join(dir, "written")
      probe = File.join(dir, "probe.rb")
      File.write(probe, yield(record))
      # TEST and TESTOPTS name the outer run's files and options, which rake's task would take
      # over its own.
      their_options = ENV.fetch("RUBYOPT", "").split.grep_v(/yjit/)
      with_environment("TEST" => nil, "TESTOPTS" => test_options, "RUBY_YJIT_ENABLE" => nil,
                       "RUBYOPT" => [*their_options, ruby_options].compact.join(" ")) do
        Rake.with_application(Rake::Application.new) do
          TestTask.new(:walking) do |t|
            t.lowering = lowering
            t.test_files = [probe]
          end
          Rake::Task[:walking].invoke
        end
      end
      File.read(record)
    end
  end

  private def with_environment(settings)
    was = settings.keys.to_h { |name| [name, ENV.fetch(name, nil)] }
    settings.each { |name, value| ENV[name] = value }
    yield
  ensure
    was.each { |name, value| ENV[name] = value }
  end
end
