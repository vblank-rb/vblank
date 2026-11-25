# frozen_string_literal: true

require "test_helper"

# What a checked run says when two sides disagree, with no emulator: a stand-in for a console's run that
# plays the program on the interpreter too, and changes what the test tells it to.
class TestCartridgeCheck < Minitest::Test
  Comparison = VBlank::IR::Backends::RunComparison

  # Everything CartridgeCheck asks of a console's run.
  class StandIn
    attr_reader :screen, :moments

    def initialize(save:)
      @save = save
      @held = []
    end

    def input_each_frame(&script) = tap { @script = script }
    def each_vblank = self
    def hold(*buttons) = tap { @held = buttons }
    def build(_program) = nil
    def frames_took(_pass) = 1
    def passes_missed = [] # every pass is read
    def setting_up_counted = 0 # no frames pass before the game's first line
    def [](name) = @run[name]

    # The run the moments are read from, with :n one bigger from the pass +self.class.wrong_from+ on.
    def run(program, frames:)
      @moments = []
      @run = VBlank::IR::Backends::Reference.new
      @run.input_each_frame { |frame| buttons_sent(frame) }
          .each_vblank { |frame| @moments << moment(frame) }
          .run(program, frames: frames)
      @moments << moment(:end)
      @screen = @run.screen
      self
    end

    def self.wrong_from = nil

    private

    def kit = VBlank::Console.for(:snes)
    def scripted_buttons(frame) = @script ? Array(@script.call(frame)) : @held
    def buttons_sent(frame) = scripted_buttons(frame)

    def moment(frame)
      shown = Comparison.pixels_over(@run.screen, @run.screen.width, @run.screen.height)
      wrong = self.class.wrong_from && frame.is_a?(Integer) && frame >= self.class.wrong_from
      variables = @run.vars.dup
      variables[:n] += 1 if wrong
      Comparison::Moment.new(frame: frame, variables: altered(variables), picture: Comparison.picture_check(shown),
                             sounds: @run.audio.size, sprites: @run.sprites_by_depth,
                             collections: altered_collections(@run.game_state.except(:vars)), sounding: [])
    end

    # The variables and the lists and pools as a moment holds them, changed by a stand-in told to.
    def altered(variables) = variables
    def altered_collections(collections) = collections
  end

  # The stand-in checked against the interpreter.
  class CheckedStandIn < StandIn
    include VBlank::IR::Backends::CartridgeCheck
  end

  # The same, with :n one bigger on the stand-in's side from pass three on.
  class WrongFromPassThree < CheckedStandIn
    def self.wrong_from = 3
  end

  # The same, never finding the game waiting at the end of pass three, which the interpreter reports.
  class MissingPassThree < CheckedStandIn
    def passes_missed = [3]
    def moments = super.reject { |moment| moment.frame == 3 }
  end

  # The same, with every variable a walk of a pool keeps of its own (its thing, the next, the
  # last and its count of turns, read off the walk's repeat) holding a number of its own.
  class WrongWalkNumbers < CheckedStandIn
    def run(program, frames:)
      @walk_numbers = program.walk.select { |node| node.kind == :repeat && node.pool_walk }
                             .flat_map { |node| [*node.pool_walk.own_variables, node.index] }
      super
    end

    private

    def altered(variables) = variables.merge(@walk_numbers.to_h { |name| [name, 77] })
  end

  # The same, with the game's own variable :total one bigger.
  class WrongTotal < CheckedStandIn
    private def altered(variables) = variables.merge(total: variables.fetch(:total) + 1)
  end

  # The same, with the field :x of the pool's things one bigger.
  class WrongField < CheckedStandIn
    private def altered_collections(collections)
      fields = collections[:pools][:guard].merge(x: collections[:pools][:guard][:x].map { |x| x && (x + 1) })
      collections.merge(pools: collections[:pools].merge(guard: fields))
    end
  end

  private def counting
    b = Builder.new
    b.instance_eval do
      n = 0
      game_loop { n += 1 }
    end
    b.finalize_program
    b.program
  end

  # Two things of a pool walked every pass, each adding its place to a variable of the game's.
  private def walking
    b = Builder.new
    b.instance_eval do
      total = var :total, 0
      guards = pool :guard, x: 0, capacity: 4
      guards.spawn(x: 3)
      guards.spawn(x: 5)
      game_loop do
        guards.each do |guard|
          guard.x += 1
          total += guard.x
        end
      end
    end
    b.finalize_program
    b.program
  end

  # A pool walk's own numbers are the build's, made for the walk: no game names them, and every walk
  # sets them before it reads them. So a cartridge that keeps them its own way agrees.
  def test_the_numbers_a_walk_keeps_of_its_own_are_not_compared
    run = WrongWalkNumbers.new(save: SaveImage.new).run(walking, frames: 4)

    assert_equal Reference.new.run(walking, frames: 4)[:total], run[:total]
  end

  def test_a_variable_of_the_game_changed_in_a_walk_is_still_compared
    error = assert_raises(Comparison::Disagreement) { WrongTotal.new(save: SaveImage.new).run(walking, frames: 4) }

    assert_match(/total: cartridge has \d+, Reference \d+/, error.message)
  end

  def test_a_field_of_the_walked_pool_is_still_compared
    error = assert_raises(Comparison::Disagreement) { WrongField.new(save: SaveImage.new).run(walking, frames: 4) }

    assert_match(/pool :guard field :x/, error.message)
  end

  def test_two_sides_that_agree_say_nothing
    run = CheckedStandIn.new(save: SaveImage.new).run(counting, frames: 6)

    assert_equal 6, run[:n]
  end

  def test_two_sides_that_differ_stop_saying_the_console_and_the_frame
    error = assert_raises(Comparison::Disagreement) { WrongFromPassThree.new(save: SaveImage.new).run(counting, frames: 6) }

    assert_match(/Super Nintendo lowering and the interpreter disagree at frame 3/, error.message)
    assert_match(/n: cartridge has 3, Reference 2/, error.message)
  end

  # A pass the interpreter reports and the cartridge never read is a fault of the cartridge's. One the
  # interpreter skips too, the boundary a waiting tick handler ends, is not
  # (TestTimer#test_a_handler_waiting_inside_a_repeat_keeps_its_turn).
  def test_a_pass_never_read_that_the_interpreter_reports_is_refused_by_number
    error = assert_raises(Comparison::Disagreement) { MissingPassThree.new(save: SaveImage.new).run(counting, frames: 6) }

    assert_match(/went on from pass 3 without waiting/, error.message)
  end
end
