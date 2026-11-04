# frozen_string_literal: true

# A BOT FOR WANDERERS (examples/wanderers.rb): a player with no window and no person. It joins a match as a
# player of its own and walks its walker toward the other player's, a person at another computer, or
# another bot. With more than two players it chases the first (or the second, if it is the first).
#
# A bot plays through the same match as everybody: every computer runs the whole game, so the bot has its own
# copy to read, and the first player's place is in it as much as its own. All it does about what it reads is
# choose which buttons its player holds. It cannot write to the game, and it does not need to: the buttons
# are sent to the other computers, which play them as they play a person's.
#
# Run a match with a person as the host, and the bot joining:
#   vblank run examples/wanderers.rb --host
#   vblank bot examples/chaser_bot.rb --join 127.0.0.1:7777
# or the bot hosts, and a person joins:
#   vblank bot examples/chaser_bot.rb --host
#   vblank run examples/wanderers.rb --join 127.0.0.1:7777
#
# Wanderers keeps each walker's place in the variables of its sprite. The sprites are made in player order,
# so `__obj1_x` and `__obj1_y` are the first player's walker, `__obj2_x` and `__obj2_y` the second's, and so on. A game that keeps
# the places in variables of its own names is easier to read; this one keeps them where the sprites do.

require_relative "../lib/vblank"

VBlank.bot "chaser", plays: "wanderers.rb" do |game|
  here = ->(axis) { game.var(:"__obj#{game.player}_#{axis}") }
  chased = game.player == 1 ? 2 : 1
  there = ->(axis) { game.var(:"__obj#{chased}_#{axis}") }

  buttons = []
  buttons << :left if here.call(:x) > there.call(:x)
  buttons << :right if here.call(:x) < there.call(:x)
  buttons << :up if here.call(:y) > there.call(:y)
  buttons << :down if here.call(:y) < there.call(:y)
  buttons
end
