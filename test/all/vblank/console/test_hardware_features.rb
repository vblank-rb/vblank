# frozen_string_literal: true

require "test_helper"

# Console::HardwareFeatures says which of each target's hardware VBlank drives. Where a driven
# feature names the verbs that drive it, the console's answers table must agree: each is a verb
# there, and the console does not refuse it.
class TestHardwareFeatures < Minitest::Test
  FEATURES = VBlank::Console::HardwareFeatures

  def test_every_console_has_a_list_and_so_do_the_two_computer_builds
    consoles = FEATURES::TARGETS.filter_map(&:console)

    assert_equal VBlank::Console::KITS.keys.sort, consoles.sort
    assert_equal ["Desktop program", "Web page"], FEATURES::TARGETS.reject(&:console).map(&:title)
  end

  def test_a_driven_features_verbs_work_on_its_console
    FEATURES::TARGETS.select(&:console).each do |target|
      answers = VBlank::Console.for(target.console).answers
      target.features.select(&:driven?).each do |feature|
        feature.verbs.each do |verb|
          answer = answers.answer(verb)
          refute_nil answer, "#{target.title}: #{feature.name} names #{verb}, which is not a verb"
          assert answer.works?, "#{target.title}: #{feature.name} is driven by #{verb}, which is refused there"
        end
      end
    end
  end

  def test_no_target_names_a_feature_twice
    FEATURES::TARGETS.each do |target|
      names = target.features.map(&:name)
      assert_equal names.uniq, names, "#{target.title} names a feature twice"
    end
  end

  def test_only_a_console_names_verbs
    FEATURES::TARGETS.reject(&:console).each do |target|
      assert(target.features.all? { |feature| feature.verbs.empty? }, "#{target.title} has no answers table to check verbs in")
    end
  end
end
