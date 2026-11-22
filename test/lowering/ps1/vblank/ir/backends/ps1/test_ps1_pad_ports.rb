# frozen_string_literal: true

require "test_helper"
require "stringio"

# What is in each port as the PlayStation reads its pads (PS1::Runtime::Pads): nothing in the first port,
# whose exchange no answer ever comes to, and an analog pad there, whose exchange is longer than a
# digital pad's. In each the second player's buttons still reach the game on the frame the interpreter
# has them, and the checked run holds every pass to it.
class TestPS1PadPorts < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1

  # A checked run with +kind+ (RubyPS1Emulator::Core::PLUGGED) in the first port.
  class FirstPortHolding < PS1::CheckedRun
    def initialize(kind)
      super()
      @kind = kind
    end

    def power_on
      super
      @core.plug(0, @kind)
    end
  end

  # Each player's steps counted while they hold right.
  def self.game
    VBlank.game("PORTS", consoles: %i[ps1], players: 2) do
      steps = (1..2).map { |player| var(:"steps#{player}", 0) }
      game_loop do
        steps.each.with_index(1) { |count, player| count.store!(count + 1) if held(:right, player: player) }
      end
    end
  end

  private def played(kind)
    run = FirstPortHolding.new(kind)
    run.input_each_frame { |frame| frame.between?(3, 6) ? %i[p2_right] : [] }
    run.run(self.class.game.program(console: :ps1), frames: 10)
  end

  def test_the_second_port_is_read_with_nothing_in_the_first
    assert_equal [0, 4], [played(:nothing)[:steps1], played(:nothing)[:steps2]]
  end

  # An analog pad answers kind 73h and four bytes of sticks after its buttons, nine bytes in all; read
  # to its end, its last byte unacknowledged, its exchange leaves the second port's alone.
  def test_the_second_port_is_read_after_an_analog_pad_in_the_first
    assert_equal 4, played(:analog)[:steps2]
  end
end
