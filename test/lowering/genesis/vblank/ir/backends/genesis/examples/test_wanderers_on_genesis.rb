# frozen_string_literal: true

require "test_helper"
require "wanderers_tests"

# examples/wanderers.rb as the Sega Genesis cartridge builds it: four players, the second, third
# and fourth on a Team Player in the second port, which the checked run plugs into Genesis Plus GX
# for a game that reads one (Genesis::HeadlessRun#power_on). These are the tests the computer builds
# play (WanderersTests), held to the interpreter after every pass.
class TestWanderersOnGenesis < Minitest::Test
  include WanderersTests

  # The cartridge's own build, not a computer's.
  private def four_seat_program = Wanderers::GAME.checked_program(err: nil, console: :genesis, for_computer: false)
end
