# frozen_string_literal: true

require "test_helper"

# A sprite whose pictures were given different lists of colors, on a console whose build keeps
# one list for a whole sprite.
#
# The Advance's build draws every picture of one sprite from one list of sixteen colors, so
# pictures that each came with a list of their own cannot all be shown by one sprite there. The
# cartridge build always refused that. The interpreter drew it, each picture in its own colors, so
# a game's own tests were green for a game that could not be built. Every program here is built
# for a console by name, since what is refused is that console's build's to say
# (Console::Description#pose_lists).
class TestIRGuardrailPosesWithDifferentColors < Minitest::Test
  Guardrails = VBlank::IR::Guardrails

  WARM = [:transparent, :red, :orange].freeze
  COLD = [:transparent, :blue, :white].freeze
  BOTH = [:transparent, :red, :blue].freeze

  WARM_ART = Array.new(64, :red).freeze
  COLD_ART = Array.new(64, :blue).freeze

  private def validator
    Guardrails::Validator.new(checks: [Guardrails::Checks::PosesWithDifferentColors.new])
  end

  private def program(console: :gba, &game)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      instance_eval(&game)
      game_loop {}
    end
    builder.finalize_program
    builder.program.copy.tap { |copy| copy.console = console }
  end

  # One sprite that faces two ways, each way a picture with its own list.
  private def sprite_game(left: WARM, right: COLD, console: :gba)
    program(console: console) do
      image :left, width: 8, height: 8, data: WARM_ART, colors: left
      image :right, width: 8, height: 8, data: COLD_ART, colors: right
      sprite :ship, at: [40, 40], facing: { left: :left, right: :right }
    end
  end

  # The same sprite, its pictures drawn from two lists by name and told to follow both, which the
  # game changes.
  private def following_game(console:)
    program(console: console) do
      colors :warm, WARM
      colors :cold, COLD
      colors :dusk, BOTH
      image :left, width: 8, height: 8, data: WARM_ART, colors: :warm
      image :right, width: 8, height: 8, data: COLD_ART, colors: :cold
      ship = sprite :ship, at: [40, 40], facing: { left: :left, right: :right }
      ship.draw_with({ warm: :warm, cold: :cold })
      recolor :warm, :dusk
      recolor :cold, :dusk
    end
  end

  private def pool_game
    program do
      image :left, width: 8, height: 8, data: WARM_ART, colors: WARM
      image :right, width: 8, height: 8, data: COLD_ART, colors: COLD
      guards = pool :guard, x: 0, y: 0, capacity: 4, facing: { left: :left, right: :right }
      guards.spawn x: 40, y: 40
    end
  end

  private def refusals(program) = validator.run(program, autofix: false).errors.map(&:message)

  private def refusal(program) = refusals(program).first

  def test_a_sprite_whose_pictures_have_different_lists_is_refused
    message = refusal(sprite_game)

    assert_match(/sprite :ship/, message, "it names the sprite")
    assert_match(/different `colors:` lists/, message, "...and what is wrong with its pictures")
    assert_match(/:left and :right/, message, "...and which pictures disagree")
    assert_match(/draw_with/, message, "...and the way to recolor one thing that both backends draw")
    assert_match(/The Game Boy Advance build draws/, message, "...and the console whose build keeps one list for a sprite")
  end

  # A console's sprite table names the list of each entry beside its tile, and a build that writes
  # the two together shows each pose in its own list's colors: nothing to refuse.
  def test_a_console_whose_build_draws_each_pose_from_its_own_list_says_nothing
    %i[gbc snes genesis].each { |console| assert_nil refusal(sprite_game(console: console)), "on #{console}" }
  end

  def test_a_picture_with_no_list_beside_one_with_a_list_says_nothing_there
    assert_nil refusal(sprite_game(right: nil, console: :genesis))
  end

  # A sprite told to follow the lists its poses are drawn from: made on the Genesis, and refused,
  # naming the console, where the build draws each pose from its own list and no more.
  def test_a_sprite_that_follows_its_lists_is_refused_where_the_build_does_not_follow_yet
    assert_nil refusal(following_game(console: :genesis))
    { gbc: "Game Boy Color", snes: "Super Nintendo" }.each do |console, title|
      message = refusal(following_game(console: console))

      assert_match(/sprite :ship/, message)
      assert_match(/The #{title} build does not make that yet/, message)
      assert_match(/warm: :warm, cold: :cold/, message, "it names what the game wrote")
    end
  end

  # A pool is a sprite a slot, all showing the same pictures, so it is refused one time and
  # by the name the game gave it.
  def test_a_pool_is_refused_one_time_by_its_own_name
    messages = refusals(pool_game)

    assert_equal 1, messages.size
    assert_match(/pool :guard/, messages.first)
  end

  # A picture with a list beside one with none is the same mistake: the framework would have
  # to work a list out for one picture and keep the given list for the other.
  def test_a_picture_with_a_list_beside_one_with_none_is_refused
    message = refusal(sprite_game(right: nil))

    assert_match(/sprite :ship/, message)
    assert_match(/none \(:right\)/, message, "it says which picture has no list, rather than calling it a different one")
  end

  def test_pictures_given_the_same_list_say_nothing
    assert_nil refusal(sprite_game(left: BOTH, right: BOTH))
  end

  def test_pictures_given_no_list_say_nothing
    assert_nil refusal(sprite_game(left: nil, right: nil))
  end

  # The interpreter is the answer key a game's own tests run against, so it refuses the
  # same programs in the same words rather than drawing what the console cannot.
  def test_the_interpreter_refuses_in_the_same_words
    error = assert_raises(Reference::ProgramError) { Reference.new.run(pool_game) }

    assert_equal refusal(pool_game), error.message
  end

  # Every run that plays games as the Advance refuses it too, in the same words:
  # test/console/gba/vblank/builder/test_pose_color_lists_on_the_advance.rb.

  def test_the_lowering_refuses_in_the_same_words
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(pool_game) }

    assert_equal refusal(pool_game), error.message
  end

  # The whole build, on the pool the interpreter refuses above: the game hears of it from the
  # build's own checks, in those words, before any cartridge is made.
  def test_build_stops_with_the_explanation
    err = StringIO.new
    assert_raises(VBlank::ROMError) do
      VBlank.build("COLORS", console: :gba, out: StringIO.new, err: err) do
        screen :tiled
        image :left, width: 8, height: 8, data: WARM_ART, colors: WARM
        image :right, width: 8, height: 8, data: COLD_ART, colors: COLD
        guards = pool :guard, x: 0, y: 0, capacity: 4, facing: { left: :left, right: :right }
        guards.spawn x: 40, y: 40
        game_loop {}
      end
    end
    assert_includes err.string, refusal(pool_game)
  end
end
