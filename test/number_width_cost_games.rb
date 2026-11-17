# frozen_string_literal: true

require "stringio"

# WHAT A TEST OF SMALL NUMBERS COSTS, for each console's own cost test: four tests a pass of one
# shape, against the same game counting the same hits with no test. Every number in these tests
# stays small, and the build can tell: a byte or half slot of a list, a variable masked into ten
# bits, a table of bytes. A console's own games keep such numbers in 8 or 16 bits and test them with
# one compare; VBlank's numbers are 32 bits, so a test the build cannot see is small is two halves
# compared (the Super Nintendo) or four bytes through a runtime routine (the Color).
#
# - :pair, how far apart two byte fields are, `(xs[i] - ys[j]).abs < 16`: a thing checking another
#   is near, every pair every pass;
# - :number, a variable tested against a number written in the program, `v < 600`;
# - :shift, a half slot shifted down, `(hs[i] >> 4) < 5`: a place kept in sixteenths made a cell;
# - :table, a table of signed bytes against a variable, `steps[i] < w`.
module NumberWidthCostGames
  # The shapes, and how many tests a pass each makes.
  TESTS_A_PASS = { pair: 4, number: 4, shift: 4, table: 4 }.freeze

  STEPS = [3, -2, 7, -8, 1, 0, -1, 5].freeze

  # The game for +console+ testing +shape+ four times a pass or, with +tests+ false, counting the
  # same hits with no test.
  def self.game(console, shape, tests: true)
    VBlank.game("NUMBER WIDTH #{shape} #{tests}", consoles: [console]) do
      xs = list :xs, capacity: 32, width: :byte, full_of: 3
      ys = list :ys, capacity: 32, width: :byte, full_of: 9
      hs = list :hs, capacity: 32, width: :half, full_of: 200
      steps = table :steps, STEPS, width: :byte
      screen :tiled
      image(:floor, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :floor
      background :field, tiles: :set, map: Array.new(28) { "#" * 32 }
      t = 0
      v = 0
      w = 0
      hits = 0
      i = 0
      j = 0
      game_loop do
        t = (t + 1) & 31
        i = t
        j = (t + 3) & 31
        v = (v + 17) & 1023
        w = (w + 1) & 7
        4.times do |n|
          next hits += 1 unless tests

          held = case shape
                 when :pair then (xs[(i + n) & 31] - ys[(j + n) & 31]).abs < 16
                 when :number then v < 600 + n
                 when :shift then (hs[(i + n) & 31] >> 4) < 5 + n
                 when :table then steps[(i + n) & 7] < w
                 end
          hits += 1 if held
        end
      end
    end
  end

  # The share of a frame +console+ spends awake running +game+.
  def self.awake_share(console, game)
    rom = game.build_rom(console: console, out: StringIO.new, err: StringIO.new, profile: false)
    1 - rom.profile(out: StringIO.new, settle: 10, frames: 30).idle_share
  end

  # What one test of +shape+ costs on +console+, in the console's +frame_cycles+ a frame.
  def self.cycles_a_test(console, shape, frame_cycles)
    testing = awake_share(console, game(console, shape))
    not_testing = awake_share(console, game(console, shape, tests: false))
    (testing - not_testing) * frame_cycles / TESTS_A_PASS.fetch(shape)
  end
end
