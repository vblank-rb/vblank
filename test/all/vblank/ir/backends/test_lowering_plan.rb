# frozen_string_literal: true

require "test_helper"

# A GAME WITH MORE THAN ONE FAULT IS REFUSED FOR THE SAME ONE ON EVERY CONSOLE: every cartridge
# lowering makes the shared refusals in the plan's one order (LoweringPlan#refuse_unbuildable!)
# before any of its own. Each console's build is asked here directly, since no run's player plays a
# refused game.
class TestLoweringPlan < Minitest::Test
  Backends = VBlank::IR::Backends
  BUILD = VBlank::IR::Build
  BACKENDS = { gbc: Backends::GBC, snes: Backends::SNES, genesis: Backends::Genesis, ps1: Backends::PS1 }.freeze

  # A step each console cannot do at all (Console::Answers): the Color has a clock and no light, the
  # others no clock.
  LACKED_STEP_BY_CONSOLE = { gbc: -> { BUILD.shade_outside(row: 0, left: 0, right: 10, amount: 4) } }.freeze
  CLOCK_STEP = -> { BUILD.set(:hour, BUILD.clock(:hour)) }

  private def lacked_step(console) = LACKED_STEP_BY_CONSOLE.fetch(console, CLOCK_STEP).call

  private def calls_itself = [BUILD.func(:again, BUILD.call(:again)), BUILD.call(:again)]

  private def refusal(console, *statements)
    program = BUILD.program(*statements, BUILD.halt)
    program.console = console
    assert_raises(BACKENDS.fetch(console)::LoweringError) { BACKENDS.fetch(console).new.build(program) }
  end

  def test_what_the_console_lacks_is_refused_before_a_routine_that_calls_itself
    BACKENDS.each_key do |console|
      error = refusal(console, *calls_itself, lacked_step(console))

      assert_match(/cannot:/, error.message, "#{console}: what the console lacks comes first")
    end
  end

  def test_a_step_only_the_advance_has_is_refused_before_what_the_console_lacks
    BACKENDS.each_key do |console|
      error = refusal(console, *calls_itself, lacked_step(console), BUILD.set(:line, BUILD.read_scanline))

      assert_match(/only means something on the Game Boy Advance/, error.message, console.to_s)
    end
  end

  # A crowd of sprites one more than +console+ keeps places for: a pool of all but one, and two
  # sprites ordered with it, one of them moving, so the order is worked out on every pass.
  private def crowded_game(console)
    crowd = VBlank::Console.described(console).sprite_places - 1
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: console))
    b.instance_eval do
      screen :tiled
      image(:speck, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:hero, "#" => :green) { (["#" * 16] * 16).join("\n") }
      specks = pool :crowd, x: 0, y: 0, capacity: crowd, image: :speck
      enemy = sprite :hero, at: [60, 60]
      hero = sprite :hero, at: [68, 54]
      draw_in_order(specks, enemy, hero)
      game_loop { hero.move(0, 1) }
    end
    b.finalize_program
    b.program
  end

  # The interpreter refuses a game with more sprites than its console keeps places for
  # (Reference#refuse_too_many_sprites!), so each console's build refuses it in the same words
  # before it lowers anything.
  def test_more_sprites_than_the_console_keeps_are_refused_in_the_interpreters_words
    BACKENDS.each do |console, backend|
      program = crowded_game(console)
      interpreter_message = assert_raises(VBlank::IR::ProgramError) { Backends::Reference.new.run(program, frames: 1) }.message
      error = assert_raises(backend::LoweringError, console.to_s) { backend.new.build(program) }

      assert_match(/A game can keep places for #{VBlank::Console.described(console).sprite_places} sprites/,
                   error.message, console.to_s)
      assert_equal interpreter_message, error.message, "#{console}: the interpreter's words"
    end
  end

  # The whole order on the plan, every console alike: each fault is refused only once every fault
  # before it in the order is gone. The first is a file handed to the game as it starts, which no
  # cartridge is; the rest are steps.
  def test_the_plan_refuses_faults_in_one_order_on_every_console
    BACKENDS.each do |console, backend|
      faults = [[[], /cartridge holds/],
                [BUILD.set(:line, BUILD.read_scanline), /only means something on the Game Boy Advance/],
                [BUILD.wait_vblank, /does not make that yet/],
                [lacked_step(console), /cannot:/],
                [calls_itself, /can call itself again/]]
      faults.each_index do |first|
        program = BUILD.program(*faults.drop(first).flat_map { |step, _| Array(step) }, BUILD.halt)
        program.console = console
        program.start_file = VBlank::IR::StartFile.new(called: "data pack", size: 64, checks: []) if first.zero?
        plan = Backends::LoweringPlan.new(program, console: VBlank::Console.described(console), error: backend::LoweringError)
        error = assert_raises(backend::LoweringError) do
          plan.refuse_unbuildable!(not_lowered_yet: { "the wait" => %i[wait_vblank] }, not_made_yet: backend::Lowering::NotMadeYet)
        end

        assert_match faults[first].last, error.message, "#{console}, fault #{first + 1} of #{faults.length}"
      end
    end
  end
end
