# frozen_string_literal: true

require "test_helper"
require "objspace"

# NO OBJECT THE RUBY BUILD MAKES HOLDS MORE INSTANCE VARIABLES THAN RUBY KEEPS AT FIXED PLACES
# (Ruby::FieldHolders::FIELDS_KEPT_IN_PLACE). Past that, a Ruby newer than 4.0 keeps an object's
# variables in a hash, and every read and write of them costs about twice what it did under a
# compiler. A game of several hundred variables is the case: with the runtime's own, one object
# holding them all is well past it. Counted after the game has set itself up and played some passes,
# since the runtime sets some of its fields only once a feature is first used.
class TestRubyFieldsKeptInPlace < Minitest::Test
  VARIABLES = 300

  private def many_variables
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval do
      screen :bitmap
      counts = Array.new(VARIABLES) { |i| var :"count_#{i}", i }
      game_loop do
        counts.each { |count| count.increase!(1) }
        fill_rect 0, 0, 8, 8, :green
      end
    end
    b.finalize_program
    b.program
  end

  # Every object reachable from +root+ but classes and modules, each once.
  private def objects_reachable_from(root)
    seen = {}.compare_by_identity
    waiting = [root]
    until waiting.empty?
      object = waiting.pop
      next if seen.key?(object) || object.is_a?(Module)

      seen[object] = true
      waiting.concat(ObjectSpace.reachable_objects_from(object) || [])
    end
    seen.keys
  end

  def test_no_object_of_a_game_of_many_variables_holds_more_than_ruby_keeps_in_place
    source = VBlank::IR::Backends::Ruby.new.live_source(many_variables)
    game = VBlank::IR::Backends::Ruby::LiveGame.new(source)
    game.play(VBlank::Original::Unpacking::FrameLimitedPlayer.new(5, picture_and_sound: true))

    objects = objects_reachable_from(game)
    largest = objects.max_by { |object| object.instance_variables.size }
    most = VBlank::IR::Backends::Ruby::FieldHolders::FIELDS_KEPT_IN_PLACE

    assert_operator objects.sum { |object| object.instance_variables.size }, :>, VARIABLES, "the game's variables were walked"
    assert_operator largest.instance_variables.size, :<=, most, "instance variables of one #{largest.class}"
  end

  # The Ruby run's player checks every pass against the interpreter as it plays.
  def test_a_game_of_many_variables_plays_as_the_interpreter_does
    played = game_player.run(many_variables, frames: 3)

    assert_equal Reference.new.run(many_variables, frames: 3)[:count_299], played[:count_299]
  end
end
