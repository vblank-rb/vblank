# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("tools/rubocop/reach_around").to_s

# A CALL MADE AROUND AN OBJECT STOPS A COMMIT: the project's cop, which the pre-commit hook runs on
# the Ruby files being committed, flags each way of calling a method without writing its name, and
# leaves a call written out alone.
class TestReachAround < Minitest::Test
  runs_on_the_main_ractor! # RuboCop keeps its registry of cops in the process

  def test_a_send_planted_in_a_library_file_is_flagged
    assert_equal ["send"], flagged("object.send(:x)\n", "lib/vblank/planted.rb")
  end

  def test_a_method_object_planted_in_a_test_file_is_flagged
    assert_equal ["method"], flagged("helper = method(:x)\n", "test/all/test_planted.rb")
  end

  def test_every_way_round_an_object_is_flagged
    source = "a.public_send(:x)\na.__send__(:x)\na.instance_variable_get(:@x)\na.instance_variable_set(:@x, 1)\n" \
             "send(:x)\na&.send(:x)\n"

    assert_equal %w[public_send __send__ instance_variable_get instance_variable_set send send],
                 flagged(source, "lib/vblank/planted.rb")
  end

  def test_a_call_written_out_is_left_alone
    source = "object.x\nmethod_name = :x\nsocket.send\nmethod\nobject.method(name)\n"

    assert_empty flagged(source, "lib/vblank/planted.rb")
  end

  private

  # The calls the cop flags in +source+, read as the file at +path+, by the word each one flags. The
  # settings are made each time: a test class's constants are frozen, and RuboCop fills its own in.
  def flagged(source, path)
    settings = RuboCop::Config.new({ "VBlank/ReachAround" => { "Enabled" => true } }, "/project/.rubocop.yml")
    processed = RuboCop::ProcessedSource.new(source, 3.4, path)
    report = RuboCop::Cop::Commissioner.new([RuboCop::Cop::VBlank::ReachAround.new(settings)]).investigate(processed)
    assert_empty report.errors
    report.offenses.map { |offense| offense.location.source }
  end
end
