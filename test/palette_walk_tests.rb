# frozen_string_literal: true

require "stringio"

# THE RULES OF A WALK OF THE COLOURS (Backends::PaletteWalk) that only a console's own build can
# show, played by each console that walks its colours for every fade: a test file in that
# lowering's folder includes this and says its console (CONSOLE) and the runtime routine that works
# a colour out (COLOR_ROUTINE). How far a walk goes is held to the interpreter for every console by
# test/all/vblank/ir/backends/test_palette_walk.rb.
module PaletteWalkTests
  PART_OF_THE_SCREEN = [{ under: :ui }, { inside: [0, 0, 40, 40] }].freeze

  # A GAME THAT SAYS ITS TINT EVERY PASS, the same tint each time, as `tint :red, hurt` in a game loop
  # does: the colours are worked out once, when it changes, and not again on every pass after.
  # Measured past the frames the game settles in, so the one change is behind it and the routine
  # that works a colour out is not run at all; the same game with a tint that moves every pass runs
  # it, so the routine named is the right one.
  def test_a_tint_said_the_same_every_pass_works_no_colour_out_again
    assert_nil colors_worked_out(moving: false), "no colour is worked out again"
    refute_nil colors_worked_out(moving: true), "a moving tint works its colours out"
  end

  # The share of the measured time COLOR_ROUTINE took, or nil where it never ran.
  private def colors_worked_out(moving:)
    console = self.class::CONSOLE
    step = moving ? 1 : 0
    game = VBlank.game("SAME TINT", consoles: [console]) do
      screen :tiled
      image(:wall, "#" => :red, "." => :blue) { "#######.\n" * 8 }
      tiles :set, "#" => :wall
      background :field, tiles: :set, map: Array.new(16) { "#" * 18 }
      level = var :level, 30
      game_loop do
        level = (level + step) % 100
        tint :red, level
      end
    end
    result = game.build_rom(console: console, out: StringIO.new, err: StringIO.new, profile: false)
                 .profile(out: StringIO.new, frames: 10)
    result.runtime.find { |spent| spent.routine == self.class::COLOR_ROUTINE }&.share
  end

  # A fade placed under a layer, or held to part of the screen, needs a blend. A console without one
  # refuses it in its answers' words (Console::Questions), the same words on every such console.
  def test_a_fade_of_part_of_the_screen_is_refused_in_the_answers_words
    kit = VBlank::Console.for(self.class::CONSOLE)
    PART_OF_THE_SCREEN.each do |where|
      error = assert_raises(VBlank::BuildError, where.keys.first.to_s) { kit.lowering.new.build(part_faded(where)) }

      assert_match(/fades part of the screen, and a #{kit.title} cannot/, error.message)
    end
  end

  private def part_faded(where)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      layers :world, :ui
      game_loop { fade :black, 50, **where }
    end
    b.finalize_program
    b.program.copy.tap { |program| program.console = self.class::CONSOLE }
  end
end
