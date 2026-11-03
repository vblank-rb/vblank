# frozen_string_literal: true

require "test_helper"

# MORE NUMBERS THAN THE FIRST 8K OF WORK RAM HOLDS. The code reaches that part quickly, and a game
# with many numbers keeps the ones it names most there and the rest further on, every one still a
# number the game can do anything with.
class TestSNESManyVariables < Minitest::Test
  MANY = 2600

  private def many_numbers
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      names = Array.new(MANY) { |number| var :"number#{number}", number }
      busy = var :busy, 0
      total = var :total, 0
      pass = var :pass, 0
      game_loop do
        pass += 1
        4.times { busy += 1 }
        names[0] += 1
        names[MANY - 1] += names[0] + busy
        names[MANY - 2] = 0 if pass == 3
        total = names[MANY - 1] - names[MANY - 3]
      end
    end
    b.finalize_program
    b.program
  end

  def test_they_play_as_the_interpreter_plays_them
    game_player.run(many_numbers, frames: 8)
    pass
  end

  def test_the_ones_named_most_stay_near
    built = VBlank::IR::Backends::SNES.new.build(many_numbers).built

    assert_operator built.variables.fetch(:busy), :<, 0x10000
    assert_operator built.variables.fetch(:number1500), :>, 0xFFFF
  end
end
