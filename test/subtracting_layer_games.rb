# frozen_string_literal: true

# A dark arena with a walker on it, under a light that takes away what is behind it
# (`layer ..., subtract: true`): for the Super Nintendo's test, whose colour maths subtracts, and
# for the refusal each other console gives.
#
# The light covers the left half of the screen and leaves the right half empty, so the arena shows
# plain there. Each channel under the light is the light's less what is behind it, and stops at
# nothing: the walker's green is more than the light's, so the light over the walker has no green.
module SubtractingLayerGames
  ARENA = [10, 6, 4].freeze
  WALKER = [4, 20, 2].freeze
  LIGHT = [28, 12, 31].freeze

  # Where to read the picture: the light over the arena, the light over the walker, and the arena
  # with no light over it.
  LIT_ARENA = [8, 8].freeze
  LIT_WALKER = [34, 66].freeze
  DARK_ARENA = [200, 100].freeze

  private def rgb5(red, green, blue) = red | (green << 5) | (blue << 10)

  # The arena, the walker and the light, the light seen through by +amounts+ (`shows:` and
  # `shows_behind:`, or `transparency:`) with what is behind it taken away.
  private def lit_arena(**amounts)
    arena = ARENA
    walker = WALKER
    light = LIGHT
    tile = Minitest::Test::SOLID_TILE
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      image(:sand, "#" => rgb(*arena)) { tile }
      image(:walker, "#" => rgb(*walker)) { tile }
      image(:glow, "#" => rgb(*light)) { tile }
      tiles :sands, "#" => :sand
      tiles :glows, "#" => :glow
      layers :arena, :walkers, :light
      layer(:arena) { background :floor, tiles: :sands, map: Array.new(32) { "#" * 32 } }
      layer(:walkers) { sprite :walker, at: [32, 64] }
      layer(:light, subtract: true, **amounts) do
        background :lamp, tiles: :glows, map: Array.new(32) { ("#" * 16) + (" " * 16) }
      end
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # The answers +console+ gives +program+ before anything is built (Checks::ConsoleAnswers),
  # raised as the build raises them.
  private def refuse_on!(console, program)
    for_console = program.copy.tap { |copy| copy.console = console }
    checks = [VBlank::IR::Guardrails::Checks::ConsoleAnswers.new]
    VBlank::IR::Guardrails::Validator.new(checks: checks).run(for_console, autofix: false).raise_on_error!
  end

  # The refusal +console+ gives the subtracting light, which must say what was asked for.
  private def assert_subtracting_refused_on(console, phrase)
    error = assert_raises(VBlank::IR::Guardrails::ValidationError) { refuse_on!(console, lit_arena(shows: 100, shows_behind: 100)) }

    assert_match(/`subtract: true`/, error.message)
    assert_match(phrase, error.message)
  end
end
