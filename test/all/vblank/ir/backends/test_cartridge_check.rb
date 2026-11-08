# frozen_string_literal: true

require "test_helper"

# WHAT A CHECKED RUN SAYS WHEN TWO SIDES DISAGREE, with no emulator: a stand-in for a console's run that
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
      Comparison::Moment.new(frame: frame, variables: variables, picture: Comparison.picture_check(shown),
                             sounds: @run.audio.size, sprites: @run.sprites_by_depth,
                             collections: @run.game_state.except(:vars), sounding: [])
    end
  end

  # The stand-in checked against the interpreter.
  class CheckedStandIn < StandIn
    include VBlank::IR::Backends::CartridgeCheck
  end

  # The same, with :n one bigger on the stand-in's side from pass three on.
  class WrongFromPassThree < CheckedStandIn
    def self.wrong_from = 3
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

  def test_two_sides_that_agree_say_nothing
    run = CheckedStandIn.new(save: SaveImage.new).run(counting, frames: 6)

    assert_equal 6, run[:n]
  end

  def test_two_sides_that_differ_stop_saying_the_console_and_the_frame
    error = assert_raises(Comparison::Disagreement) { WrongFromPassThree.new(save: SaveImage.new).run(counting, frames: 6) }

    assert_match(/Super Nintendo lowering and the interpreter disagree at frame 3/, error.message)
    assert_match(/n: cartridge has 3, Reference 2/, error.message)
  end
end
